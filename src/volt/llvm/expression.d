/*#D*/
// Copyright 2012-2017, Jakob Bornecrantz.
// SPDX-License-Identifier: BSL-1.0
/*!
 * Most of the expression to llvmbitcode generation code is in this module.
 *
 * @ingroup backend llvmbackend
 */
module volt.llvm.expression;

import watt.text.format : format;
import watt.conv : toString;

static import volta.util.util;

import volta.ir.location : Location;
import volt.errors;
import ir = volta.ir;
import volta.util.util;

import volt.llvm.common;
import volt.llvm.interfaces;
import volt.llvm.abi.base;	
static import volt.semantic.mangle;
static import volt.semantic.classify;


/*!
 * Returns the value, without doing any checking if it is
 * in reference form or not.
 */
void getValueAnyForm(State state, ir.Exp exp, Value result)
{
	switch(exp.nodeType) with (ir.NodeType) {
	case AccessExp:
		auto ae = cast(ir.AccessExp)exp;
		handleAccessExp(state, ae, result);
		break;
	case Ternary:
		auto ternary = cast(ir.Ternary)exp;
		handleTernary(state, ternary, result);
		break;
	case BinOp:
		auto bin = cast(ir.BinOp)exp;
		handleBinOp(state, bin, result);
		break;
	case Unary:
		auto unary = cast(ir.Unary)exp;
		handleUnary(state, unary, result);
		break;
	case Postfix:
		auto postfix = cast(ir.Postfix)exp;
		handlePostfix(state, postfix, result);
		break;
	case ExpReference:
		auto expRef = cast(ir.ExpReference)exp;
		handleExpReference(state, expRef, result);
		break;
	case Constant:
		auto cnst = cast(ir.Constant)exp;
		handleConstant(state, cnst, result);
		break;
	case StructLiteral:
		auto sl = cast(ir.StructLiteral)exp;
		handleStructLiteral(state, sl, result);
		break;
	case UnionLiteral:
		auto ul = cast(ir.UnionLiteral)exp;
		handleUnionLiteral(state, ul, result);
		break;
	case ArrayLiteral:
		auto al = cast(ir.ArrayLiteral)exp;
		handleArrayLiteral(state, al, result);
		break;
	case ClassLiteral:
		auto cl = cast(ir.ClassLiteral)exp;
		handleClassLiteral(state, cl, result);
		break;
	case StatementExp:
		auto cl = cast(ir.StatementExp)exp;
		handleStatementExp(state, cl, result);
		break;
	case VaArgExp:
		auto ve = cast(ir.VaArgExp)exp;
		handleVaArgExp(state, ve, result);
		break;
	case BuiltinExp:
		auto ie = cast(ir.BuiltinExp)exp;
		handleBuiltinExp(state, ie, result);
		break;
	default:
		throw panicUnhandled(exp, ir.nodeToString(exp));
	}

	// We unset the position here so we don't leak the wrong position
	// to following instruction, easier to find unset instructions then
	// some with wrong position.
	diUnsetPosition(state);
}

private:
/*
 *
 * Ternary function.
 *
 */


void handleTernary(State state, ir.Ternary t, Value result)
{
	Value ifTrue = result;
	Value ifFalse = new Value();
	Value condition =  new Value();
	LLVMBasicBlockRef trueBlock, falseBlock, endBlock;

	// @todo this function could in theory figure out if
	// values are constant and emit their blocks.

	trueBlock = LLVMAppendBasicBlockInContext(
			state.context, state.func, "ternTrueBlock");
	falseBlock = LLVMAppendBasicBlockInContext(
		state.context, state.func, "ternFalseBlock");
	endBlock = LLVMAppendBasicBlockInContext(
			state.context, state.func, "ternEndBlock");

	state.getValue(t.condition, condition);
	LLVMBuildCondBr(state.builder, condition.value, trueBlock, falseBlock);

	LLVMMoveBasicBlockAfter(trueBlock, state.block);
	state.startBlock(trueBlock);
	state.getValue(t.ifTrue, ifTrue);
	LLVMBuildBr(state.builder, endBlock);
	trueBlock = state.block; // Need to update the block


	LLVMMoveBasicBlockAfter(falseBlock, state.block);
	state.startBlock(falseBlock);
	state.getValue(t.ifFalse, ifFalse);
	LLVMBuildBr(state.builder, endBlock);
	falseBlock = state.block; // Need to update the block

	LLVMMoveBasicBlockAfter(endBlock, falseBlock);
	state.startBlock(endBlock);

	// Using ternary to select between two void returning functions?
	if (result.type is state.voidType) {
		// Better hope that the frontend knows what it is doing.
		result.value = null;
		return;
	}
	auto phi = LLVMBuildPhi(state.builder, ifFalse.type.llvmType, "");
	LLVMAddIncoming(
		phi, [ifTrue.value, ifFalse.value], [trueBlock, falseBlock]);
	result.value = phi;
}


/*
 *
 * BinOp functions.
 *
 */


void handleBinOp(State state, ir.BinOp bin, Value result)
{
	switch(bin.op) with (ir.BinOp.Op) {
	case Assign:
		handleAssign(state, bin, result);
		break;
	case AndAnd:
	case OrOr:
	//case XorXor:
		handleBoolCompare(state, bin, result);
		break;
	case AddAssign:
	case SubAssign:
	case MulAssign:
	case DivAssign:
	case ModAssign:
	case AndAssign:
	case OrAssign:
	case XorAssign:
	case LSAssign:
	case SRSAssign:
	case RSAssign:
	case PowAssign:
		handleBinOpAssign(state, bin, result);
		break;
	case Is:
	case NotIs:
		handleIs(state, bin, result);
		break;
	case Equal:
	case NotEqual:
	case Less:
	case LessEqual:
	case GreaterEqual:
	case Greater:
		handleCompare(state, bin, result);
		break;
	default:
		handleBinOpNonAssign(state, bin, result);
	}
}

void handleAssign(State state, ir.BinOp bin, Value result)
{
	// Returns the right value instead.
	Value left = new Value();
	Value right = result;

	state.getValue(bin.right, right);
	state.getValueRef(bin.left, left);

	// Set debug info location, getValue will have reset it.
	diSetPosition(state, /*#ref*/bin.loc);

	// Not returned.
	LLVMBuildStore(state.builder, right.value, left.value);
}

void handleBoolCompare(State state, ir.BinOp bin, Value result)
{
	assert(bin.op == ir.BinOp.Op.AndAnd || bin.op == ir.BinOp.Op.OrOr);
	Value left = result;
	Value right = new Value();
	bool and = bin.op == ir.BinOp.Op.AndAnd;

	LLVMBasicBlockRef oldBlock, rightBlock, endBlock;
	rightBlock = LLVMAppendBasicBlockInContext(
			state.context, state.func, "compRight");
	endBlock = LLVMAppendBasicBlockInContext(
			state.context, state.func, "compDone");

	state.getValue(bin.left, left);

	// Set debug info location, getValue(left) will have reset it.
	diSetPosition(state, /*#ref*/bin.loc);

	LLVMBuildCondBr(state.builder, left.value,
		and ? rightBlock : endBlock,
		and ? endBlock : rightBlock);
	oldBlock = state.block; // Need the block for phi.

	LLVMMoveBasicBlockAfter(rightBlock, state.block);
	state.startBlock(rightBlock);
	state.getValue(bin.right, right);
	LLVMBuildBr(state.builder, endBlock);
	rightBlock = state.block; // Need to update the block for phi.

	LLVMMoveBasicBlockAfter(endBlock, rightBlock);
	state.startBlock(endBlock);

	// Set debug info location, getValue(right) will have reset it.
	diSetPosition(state, /*#ref*/bin.loc);

	auto v = LLVMConstInt(state.boolType.llvmType, !and, false);
	auto phi = LLVMBuildPhi(state.builder, left.type.llvmType, "");
	LLVMAddIncoming(
		phi, [v, right.value], [oldBlock, rightBlock]);
	result.value = phi;
}

void handleIs(State state, ir.BinOp bin, Value result)
{
	Value left = result;
	Value right = new Value();

	state.getValueAnyForm(bin.left, left);
	state.getValueAnyForm(bin.right, right);

	auto pr = bin.op == ir.BinOp.Op.Is ?
		LLVMIntPredicate.EQ :
		LLVMIntPredicate.NE;

	auto logic = bin.op == ir.BinOp.Op.Is ?
		LLVMOpcode.And :
		LLVMOpcode.Or;

	auto loc = bin.loc;

	// This debug info location is set on all following instructions.
	diSetPosition(state, /*#ref*/bin.loc);

	auto dgt = cast(DelegateType)result.type;
	if (dgt !is null) {
		auto lInstance = getValueFromAggregate(state, /*#ref*/loc, left, DelegateType.voidPtrIndex);
		auto lFunc = getValueFromAggregate(state, /*#ref*/loc, left, DelegateType.funcIndex);
		auto rInstance = getValueFromAggregate(state, /*#ref*/loc, right, DelegateType.voidPtrIndex);
		auto rFunc = getValueFromAggregate(state, /*#ref*/loc, right, DelegateType.funcIndex);

		auto instance = LLVMBuildICmp(state.builder, pr, lInstance, rInstance, "");
		auto func     = LLVMBuildICmp(state.builder, pr, lFunc, rFunc, "");

		result.type = state.boolType;
		result.isPointer = false;
		result.value = LLVMBuildBinOp(state.builder, logic, instance, func, "");
		return;
	}

	auto at = cast(ArrayType)result.type;
	if (at is null) {
		makeNonPointer(state, left);
		makeNonPointer(state, right);

		result.type = state.boolType;
		result.isPointer = false;
		result.value = LLVMBuildICmp(state.builder, pr, left.value, right.value, "");
		return;
	}

	// Deal with arrays.
	auto lPtr = getValueFromAggregate(state, /*#ref*/loc, left, ArrayType.ptrIndex);
	auto lLen = getValueFromAggregate(state, /*#ref*/loc, left, ArrayType.lengthIndex);
	auto rPtr = getValueFromAggregate(state, /*#ref*/loc, right, ArrayType.ptrIndex);
	auto rLen = getValueFromAggregate(state, /*#ref*/loc, right, ArrayType.lengthIndex);

	auto ptr = LLVMBuildICmp(state.builder, pr, lPtr, rPtr, "");
	auto len = LLVMBuildICmp(state.builder, pr, lLen, rLen, "");

	result.type = state.boolType;
	result.isPointer = false;
	result.value = LLVMBuildBinOp(state.builder, logic, ptr, len, "");
}

void handleCompare(State state, ir.BinOp bin, Value result)
{
	Value left = result;
	Value right = new Value();

	state.getValue(bin.left, left);
	state.getValue(bin.right, right);

	auto pt = cast(PrimitiveType)result.type;
	if (pt is null) {
		throw panic(/*#ref*/bin.loc, "can only compare primitive types");
	}

	LLVMIntPredicate pr;
	LLVMRealPredicate fpr;
	switch(bin.op) with (ir.BinOp.Op) {
	case Equal:
		if (pt.floating) {
			fpr = LLVMRealPredicate.OEQ;
		} else {
			pr = LLVMIntPredicate.EQ;
		}
		break;
	case NotEqual:
		if (pt.floating) {
			fpr = LLVMRealPredicate.ONE;
		} else {
			pr = LLVMIntPredicate.NE;
		}
		break;
	case Less:
		if (pt.floating) {
			fpr = LLVMRealPredicate.OLT;
		} else if (pt.signed) {
			pr = LLVMIntPredicate.SLT;
		} else {
			pr = LLVMIntPredicate.ULT;
		}
		break;
	case LessEqual:
		if (pt.floating) {
			fpr = LLVMRealPredicate.OLE;
		} else if (pt.signed) {
			pr = LLVMIntPredicate.SLE;
		} else {
			pr = LLVMIntPredicate.ULE;
		}
		break;
	case GreaterEqual:
		if (pt.floating) {
			fpr = LLVMRealPredicate.OGE;
		} else if (pt.signed) {
			pr = LLVMIntPredicate.SGE;
		} else {
			pr = LLVMIntPredicate.UGE;
		}
		break;
	case Greater:
		if (pt.floating) {
			fpr = LLVMRealPredicate.OGT;
		} else if (pt.signed) {
			pr = LLVMIntPredicate.SGT;
		} else {
			pr = LLVMIntPredicate.UGT;
		}
		break;
	default:
		throw panic(/*#ref*/bin.loc, "error");
	}

	// Debug info
	diSetPosition(state, /*#ref*/bin.loc);

	LLVMValueRef v;
	if (pt.floating) {
		v = LLVMBuildFCmp(state.builder, fpr, left.value, right.value, "");
	} else {
		v = LLVMBuildICmp(state.builder, pr, left.value, right.value, "");
	}

	result.type = state.boolType;
	result.value = v;
}

void handleBinOpAssign(State state, ir.BinOp bin, Value result)
{
	// We return the left value.
	Value left = result;
	Value right = new Value();
	Value opResult = right;

	state.getValueRef(bin.left, left);
	state.getValueAnyForm(bin.right, right);

	// Copy the left value since the handleBinOpNonAssign
	// function will turn it into a value, and we return
	// it as a lvalue/reference.
	left = new Value(left);

	ir.BinOp.Op op;
	switch (bin.op) with (ir.BinOp.Op) {
	case AddAssign: op = Add; break;
	case SubAssign: op = Sub; break;
	case MulAssign: op = Mul; break;
	case DivAssign: op = Div; break;
	case ModAssign: op = Mod; break;
	case AndAssign: op = And; break;
	case OrAssign: op = Or; break;
	case XorAssign: op = Xor; break;
	case LSAssign: op = LS; break;
	case SRSAssign: op = SRS; break;
	case RSAssign: op = RS; break;
	default:
		throw panicUnhandled(bin, toString(bin.op));
	}

	auto pt = cast(PrimitiveType)right.type;
	if (pt is null)
		throw panic(bin, "right hand value must be of primitive type");

	// Set debug info location, helper needs this.
	diSetPosition(state, /*#ref*/bin.loc);

	handleBinOpNonAssignHelper(state, /*#ref*/bin.loc, op,
	                           left, right, right);

	// Not returned.
	LLVMBuildStore(state.builder, right.value, result.value);
}

/*!
 * Sets up values and calls helper functions to handle BinOp, will leave
 * debug info location set on builder.
 */
void handleBinOpNonAssign(State state, ir.BinOp bin, Value result)
{
	Value left = new Value();
	Value right = result;

	state.getValueAnyForm(bin.left, left);
	state.getValueAnyForm(bin.right, right);

	handleBinOpNonAssignHelper(state, /*#ref*/bin.loc, bin.op,
	                           left, right, result);
}

/*!
 * Helper function that does the bin operation, sets debug info location on
 * builder and will not unset it.
 */
void handleBinOpNonAssignHelper(State state, ref Location loc, ir.BinOp.Op binOp,
                                Value left, Value right, Value result)
{
	diSetPosition(state, /*#ref*/loc);

	makeNonPointer(state, left);
	makeNonPointer(state, right);

	// Check for pointer math.
	auto ptrType = cast(PointerType)left.type;
	if (ptrType !is null)
		return handleBinOpPointer(state, /*#ref*/loc, binOp, left, right, result);

	// Note the flipping of args.
	ptrType = cast(PointerType)right.type;
	if (ptrType !is null)
		return handleBinOpPointer(state, /*#ref*/loc, binOp, right, left, result);

	auto pt = cast(PrimitiveType)right.type;
	if (pt is null)
		throw panic(/*#ref*/loc, "can only binop on primitive types");

	handleBinOpPrimitive(state, /*#ref*/loc, binOp, pt, left, right, result);
}

/*!
 * Pointer artithmetic, caller have to flip left and right. Assumes debug
 * info location already set.
 */
void handleBinOpPointer(State state, ref in Location loc, ir.BinOp.Op binOp,
                        Value ptr, Value other, Value result)
{
	auto ptrType = cast(PointerType)ptr.type;
	auto primType = cast(PrimitiveType)other.type;

	if (ptrType is null)
		throw panic(/*#ref*/loc, "left value must be of pointer type");
	if (primType is null)
		throw panic(/*#ref*/loc, "can only do pointer math with non-pointer");
	if (primType.floating)
		throw panic(/*#ref*/loc, "can't do pointer math with floating value");
	if (binOp != ir.BinOp.Op.Add && binOp != ir.BinOp.Op.Sub)
		throw panic(/*#ref*/loc, "can only add or subtract to pointers");

	LLVMValueRef val = other.value;
	if (binOp == ir.BinOp.Op.Sub) {
		val = LLVMBuildNeg(state.builder, val, "");
	}

	// Either ptr or other could be result, keep that in mind.
	result.type = ptr.type;
	result.value = LLVMBuildGEP(state.builder, ptr.value, [val], "");
}

/*!
 * Primitive artithmetic, assumes debug info location already set.
 */
void handleBinOpPrimitive(State state, ref in Location loc, ir.BinOp.Op binOp,
                          PrimitiveType pt,
	                      Value left, Value right, Value result)
{
	LLVMOpcode op;
	switch(binOp) with (ir.BinOp.Op) {
	case Add:
		op = pt.floating ? LLVMOpcode.FAdd : LLVMOpcode.Add;
		break;
	case Sub:
		op = pt.floating ? LLVMOpcode.FSub : LLVMOpcode.Sub;
		break;
	case Mul:
		op = pt.floating ? LLVMOpcode.FMul : LLVMOpcode.Mul;
		break;
	case Div:
		if (pt.floating)
			op = LLVMOpcode.FDiv;
		else if (pt.signed)
			op = LLVMOpcode.SDiv;
		else
			op = LLVMOpcode.UDiv;
		break;
	case Mod:
		if (pt.floating)
			op = LLVMOpcode.FRem;
		else if (pt.signed)
			op = LLVMOpcode.SRem;
		else
			op = LLVMOpcode.URem;
		break;
	case LS:
		assert(!pt.floating);
		op = LLVMOpcode.Shl;
		break;
	case SRS:
		assert(!pt.floating);
		if (pt.signed) {
			op = LLVMOpcode.AShr;
		} else {
			op = LLVMOpcode.LShr;
		}
		break;
	case RS:
		assert(!pt.floating);
		op = LLVMOpcode.LShr;
		break;
	case And:
		assert(!pt.floating);
		op = LLVMOpcode.And;
		break;
	case Or:
		assert(!pt.floating);
		op = LLVMOpcode.Or;
		break;
	case Xor:
		assert(!pt.floating);
		op = LLVMOpcode.Xor;
		break;
	default:
		throw panicUnhandled(/*#ref*/loc, toString(binOp));
	}

	// Either right or left could be result, keep that in mind.
	result.type = right.type;
	result.value = LLVMBuildBinOp(state.builder, op, left.value, right.value, "");
}


/*
 *
 * Unary functions.
 *
 */


void handleUnary(State state, ir.Unary unary, Value result)
{
	switch(unary.op) with (ir.Unary.Op) {
	case Cast:
		handleCast(state, unary, result);
		break;
	case Dereference:
		handleDereference(state, unary, result);
		break;
	case AddrOf:
		handleAddrOf(state, unary, result);
		break;
	case Plus:
	case Minus:
		handlePlusMinus(state, unary, result);
		break;
	case Not:
		handleNot(state, unary, result);
		break;
	case Complement:
		handleComplement(state, unary, result);
		break;
	case Increment:
	case Decrement:
		handleIncDec(state, unary, result);
		break;
	default:
		throw panicUnhandled(/*#ref*/unary.loc, toString(unary.op));
	}
}

void handleCast(State state, ir.Unary cst, Value result)
{
	// Start by getting the value.
	state.getValueAnyForm(cst.value, result);

	auto newType = state.fromIr(cst.type);
	handleCast(state, cst.loc, newType, result);
}

void handleCast(State state, Location loc, Type newType, Value result)
{
	auto oldType = result.type;

	auto newTypeArray = cast(ArrayType)newType;
	auto oldTypeArray = cast(ArrayType)oldType;
	if (newTypeArray !is null && oldTypeArray !is null) {
		return handleCastArray(state, loc, newTypeArray, result);
	}

	makeNonPointer(state, result);

	assert(newType !is null);
	assert(oldType !is null);

	//! @todo types are not cached yet.
	if (oldType is newType) {
		return;
	}

	auto newTypePrim = cast(PrimitiveType)newType;
	auto oldTypePrim = cast(PrimitiveType)oldType;
	if (newTypePrim !is null &&
	    oldTypePrim !is null) {
		return handleCastPrimitive(state, loc, newTypePrim, oldTypePrim, result);
	}

	auto newTypePtr = cast(PointerType)newType;
	auto oldTypePtr = cast(PointerType)oldType;
	auto newTypeFn = cast(FunctionType)newType;
	auto oldTypeFn = cast(FunctionType)oldType;
	if ((newTypePtr !is null || newTypeFn !is null) &&
	    (oldTypePtr !is null || oldTypeFn !is null)) {
		return handleCastPointer(state, loc, newType, result);
	}

	if ((newTypePrim !is null && (oldTypeFn !is null || oldTypePtr !is null)) ||
	    (oldTypePrim !is null && (newTypeFn !is null || newTypePtr !is null))) {
		auto t = newTypePtr is null ? newTypeFn : newTypePtr;
		return handleCastPointerPrim(state, loc, t, newTypePrim, result);
	}

	throw panicUnhandled(/*#ref*/loc,
		format("%s -> %s",
		ir.nodeToString(oldType.irType),
		ir.nodeToString(newType.irType)));
}

/*!
 * Handle primitive casts, the value to cast is stored in result already.
 */
void handleCastPrimitive(State state, Location loc, PrimitiveType newType,
                         PrimitiveType oldType, Value result)
{
	assert(!result.isPointer);

	// No op it.
	if (newType is oldType)
		return;

	void error() {
		throw panic(/*#ref*/loc, "invalid cast");
	}

	result.type = newType;

	LLVMOpcode op;
	if (newType.boolean) {
		if (oldType.floating) {
			result.value = LLVMBuildFCmp(state.builder,
				LLVMRealPredicate.ONE,
				result.value,
				LLVMConstNull(oldType.llvmType), "");
		} else {
			// Need to insert a test here.
			result.value = LLVMBuildICmp(state.builder,
				LLVMIntPredicate.NE,
				result.value,
				LLVMConstNull(oldType.llvmType), "");
		}
		return; // No fallthrough.
	} else if (newType.floating) {
		if (oldType.floating) {
			if (newType.bits < oldType.bits) {
				op = LLVMOpcode.FPTrunc;
			} else if (newType.bits > oldType.bits) {
				op = LLVMOpcode.FPExt;
			} else {
				error(); // Type are the same?
			}
		} else if (oldType.signed) {
			op = LLVMOpcode.SIToFP;
		} else {
			op = LLVMOpcode.UIToFP;
		}
	} else if (oldType.floating) {
		if (newType.signed) {
			op = LLVMOpcode.FPToSI;
		} else {
			op = LLVMOpcode.FPToUI;
		}
	} else {
		if (newType.bits < oldType.bits) {
			// Truncate is easy, since it doesn't care about signedness.
			op = LLVMOpcode.Trunc;
		} else if (newType.bits > oldType.bits) {
			// Extend care about signedness of the target type.
			// But only if both are signed, since "cast(int)cast(ubyte)0xff" should yeild 255 not -1.
			if (!oldType.signed) {
				op = LLVMOpcode.ZExt;
			} else {
				op = LLVMOpcode.SExt;
			}
		} else if (newType.signed != oldType.signed) {
			// Just bitcast this.
			op = LLVMOpcode.BitCast;
		} else {
			// The types have the same size, but may be semantically distinct (char => ubyte, for example).
			return;
		}
	}

	result.value = LLVMBuildCast(state.builder, op, result.value, newType.llvmType, "");
}

/*!
 * Handle pointer casts. 
 * This is really easy.
 * Also casts between function pointers and pointers.
 */
void handleCastPointer(State state, Location loc, Type newType, Value result)
{
	assert(!result.isPointer);

	result.type = newType;
	result.value = LLVMBuildBitCast(state.builder, result.value, newType.llvmType, "");
}

/*!
 * Handle pointer <-> integer casts.
 */
void handleCastPointerPrim(State state, Location loc, Type newTypePtr, Type newTypePrim, Value result)
{
	assert(!result.isPointer);

	if (newTypePtr !is null) {
		result.type = newTypePtr;
		result.value = LLVMBuildIntToPtr(state.builder, result.value, newTypePtr.llvmType, "");
	} else {
		assert(newTypePrim !is null);
		result.type = newTypePrim;
		result.value = LLVMBuildPtrToInt(state.builder, result.value, newTypePrim.llvmType, "");
	}
}

/*!
 * Handle all Array casts as bit casts
 */
void handleCastArray(State state, Location loc, ArrayType newType, Value result)
{
	auto ptr = getValueFromAggregate(state, /*#ref*/loc, result, ArrayType.ptrIndex);
	auto len = getValueFromAggregate(state, /*#ref*/loc, result, ArrayType.lengthIndex);
	auto casted = LLVMBuildBitCast(state.builder, ptr,
		newType.ptrType.llvmType, "");

	// Value returned from casts are not LValues.
	makeArrayValue(state, loc, newType, casted, len, result);
}


/*!
 * Handles bitwise not, the ~ operator.
 */
void handleComplement(State state, ir.Unary comp, Value result)
{
	state.getValue(comp.value, result);
	auto neg = LLVMBuildNeg(state.builder, result.value, "");
	auto one = LLVMConstInt(result.type.llvmType, 1, true);
	result.value = LLVMBuildSub(state.builder, neg, one, "");
}


/*!
 * Handles '*' dereferences.
 */
void handleDereference(State state, ir.Unary de, Value result)
{
	state.getValue(de.value, result);

	auto pt = cast(PointerType)result.type;
	assert(pt !is null);

	result.type = pt.base;
	result.isPointer = true;
}

/*!
 * Handles '&' referencing.
 */
void handleAddrOf(State state, ir.Unary de, Value result)
{
	state.getValueRef(de.value, result);

	auto pt = new ir.PointerType();
	pt.loc = de.loc;
	pt.base = result.type.irType;
	assert(pt.base !is null);
	pt.mangledName = volt.semantic.mangle.mangle(pt);

	result.type = state.fromIr(pt);
	result.isPointer = false;
}

void handlePlusMinus(State state, ir.Unary unary, Value result)
{
	state.getValue(unary.value, result);

	auto primType = cast(PrimitiveType)result.type;
	if (primType is null)
		throw panic(/*#ref*/unary.loc, "must be primitive type");

	// No-op plus
	if (unary.op == ir.Unary.Op.Plus)
		return;

	if (primType.floating)
		result.value = LLVMBuildFNeg(state.builder, result.value, "");
	else
		result.value = LLVMBuildNeg(state.builder, result.value, "");
}

void handleNot(State state, ir.Unary unary, Value result)
{
	state.getValue(unary.value, result);

	if (result.type !is state.boolType) {
		handleCast(state, unary.loc, state.boolType, result);
	}

	result.value = LLVMBuildNot(state.builder, result.value, "");
}

void handleIncDec(State state, ir.Unary unary, Value result)
{
	LLVMValueRef ptr, read, value;
	LLVMTypeRef type;
	bool isInc = unary.op == ir.Unary.Op.Increment;

	state.getValueRef(unary.value, result);

	diSetPosition(state, /*#ref*/unary.loc);

	ptr = result.value;
	type = result.type.llvmType;
	read = LLVMBuildLoad2(state.builder, type, ptr);

	auto ptrType = cast(PointerType)result.type;
	auto primType = cast(PrimitiveType)result.type;
	if (ptrType !is null) {
		auto v = isInc ? 1 : -1;
		auto c = LLVMConstInt(LLVMInt32TypeInContext(state.context), cast(uint)v, true);
		value = LLVMBuildGEP(state.builder, read, [c], "");
	} else if (primType !is null) {
		auto op = isInc ? LLVMOpcode.Add : LLVMOpcode.Sub;
		auto c = primType.fromNumber(state, 1);
		value = LLVMBuildBinOp(state.builder, op, read, c, "");
	} else {
		throw makeExpected(unary, "primitive or pointer");
	}

	LLVMBuildStore(state.builder, value, ptr);

	diUnsetPosition(state);

	result.isPointer = false;
	result.value = value;
}


/*
 *
 * Postfix functions.
 *
 */


void handlePostfix(State state, ir.Postfix postfix, Value result)
{
	switch(postfix.op) with (ir.Postfix.Op) {
	case Index:
		handleIndex(state, postfix, result);
		break;
	case Slice:
		handleSlice(state, postfix, result);
		break;
	case Call:
		handleCall(state, postfix, result);
		break;
	case CreateDelegate:
		handleCreateDelegate(state, postfix, result);
		break;
	case Decrement:
	case Increment:
		handleIncDec(state, postfix, result);
		break;
	default:
		throw panicUnhandled(/*#ref*/postfix.loc, toString(postfix.op));
	}
}

void handleIndex(State state, ir.Postfix postfix, Value result)
{
	Value left = result;
	Value right = new Value();

	assert(postfix.arguments.length == 1);

	state.getValueAnyForm(postfix.child, left);
	state.getValue(postfix.arguments[0], right);


	// Turn arr[index] into arr.ptr[index]
	auto at = cast(ArrayType)left.type;
	if (at !is null)
		getPointerFromArray(state, /*#ref*/postfix.loc, left);

	auto sat = cast(StaticArrayType)left.type;
	if (sat !is null)
		getPointerFromStaticArray(state, /*#ref*/postfix.loc, left);

	auto pt = cast(PointerType)left.type;
	if (pt is null)
		throw panic(/*#ref*/postfix.loc, "can not index non-array or pointer type");

	makeNonPointer(state, left);

	result.value = LLVMBuildGEP(state.builder, left.value, [right.value], "");
	result.type = pt.base;
	result.isPointer = true;
}

void handleSlice(State state, ir.Postfix postfix, Value result)
{
	if (postfix.arguments.length == 0)
		handleSliceNone(state, postfix, result);
	else if (postfix.arguments.length == 2)
		handleSliceTwo(state, postfix, result);
	else
		throw panic(/*#ref*/postfix.loc, "wrong number of arguments to slice");
}

void handleSliceNone(State state, ir.Postfix postfix, Value result)
{
	assert(postfix.arguments.length == 0);

	state.getValueAnyForm(postfix.child, result);

	auto at = cast(ArrayType)result.type;
	auto sat = cast(StaticArrayType)result.type;
	if (at !is null) {
		// Nothing todo.
	} else if (sat !is null) {
		getArrayFromStaticArray(state, /*#ref*/postfix.loc, result);
	} else {
		throw panic(/*#ref*/postfix.loc, "unhandled type in slice (none)");
	}
}

void handleSliceTwo(State state, ir.Postfix postfix, Value result)
{
	assert(postfix.arguments.length == 2);

	Value left = new Value();
	Value start = new Value();
	Value end = new Value();

	state.getValueAnyForm(postfix.child, left);

	auto pt = cast(PointerType)left.type;
	auto at = cast(ArrayType)left.type;
	auto sat = cast(StaticArrayType)left.type;
	if (pt !is null) {

		makeNonPointer(state, left);
		auto irPt = cast(ir.PointerType)pt.irType;
		assert(irPt !is null);
		auto irAt = new ir.ArrayType(/*#ref*/postfix.loc, irPt.base);
		addMangledName(irAt);
		at = cast(ArrayType)state.fromIr(irAt);
		assert(at !is null);

		makeNonPointer(state, left);

	} else if (at !is null) {

		getPointerFromArray(state, /*#ref*/postfix.loc, left);
		makeNonPointer(state, left);

	} else if (sat !is null) {

		getPointerFromStaticArray(state, /*#ref*/postfix.loc, left);
		at = sat.arrayType;

	} else {
		throw panicUnhandled(postfix, ir.nodeToString(left.type.irType));
	}

	state.getValueAnyForm(postfix.arguments[0], start);
	state.getValueAnyForm(postfix.arguments[1], end);

	handleCast(state, postfix.loc, state.sizeType, start);
	handleCast(state, postfix.loc, state.sizeType, end);

	LLVMValueRef ptr, len;

	ptr = LLVMBuildGEP(state.builder, left.value, [start.value], "");

	// Subtract start from end to get the length, which returned in end.
	// Will set and leave debug info location and we want that.
	handleBinOpNonAssignHelper(state, /*#ref*/postfix.loc,
	                           ir.BinOp.Op.Sub,
	                           end, start, end);
	len = end.value;

	makeArrayValue(state, postfix.loc, at, ptr, len, result);
}

void handleCreateDelegate(State state, ir.Postfix postfix, Value result)
{
	Value instance = result;
	Value func = new Value();

	getCreateDelegateValues(state, postfix, instance, func);

	auto funcType = cast(FunctionType)func.type;
	if (funcType is null) {
		throw panic(postfix, "func isn't FunctionType");
	}

	auto irFn = cast(ir.FunctionType)funcType.irType;
	auto irDg = new ir.DelegateType(irFn);
	irDg.mangledName = volt.semantic.mangle.mangle(irDg);

	auto dgt = cast(DelegateType)state.fromIr(irDg);
	assert(dgt !is null);

	auto voidPtr = LLVMBuildBitCast(
		state.builder, instance.value, state.voidPtrType.llvmType, "");
	auto funcPtr = LLVMBuildBitCast(
		state.builder, func.value, dgt.llvmCallPtrType, "");

	makeDelegateValue(state, /*#ref*/postfix.loc, dgt,
	                  voidPtr, funcPtr, result);
}

void handleCall(State state, ir.Postfix postfix, Value result)
{
	LLVMValueRef llvmExtraArg;

	size_t offset;

	// Special case create delegate children to save
	// a bunch of created delegates in the LLVM IR.
	auto childAsPostfix = cast(ir.Postfix)postfix.child;
	if (childAsPostfix !is null &&
	    childAsPostfix.op == ir.Postfix.Op.CreateDelegate) {

		auto instance = new Value();
		getCreateDelegateValues(state, childAsPostfix, instance, result);

		llvmExtraArg = LLVMBuildBitCast(state.builder, instance.value, state.voidPtrType.llvmType, "");
		offset = 1;

	} else {
		state.getValueAnyForm(postfix.child, result);
	}

	auto ct = cast(CallableType)result.type;
	auto ft = cast(FunctionType)result.type;
	auto dt = cast(DelegateType)result.type;
	auto irc = cast(ir.CallableType) result.type.irType;

	Type ret;
	if (ft !is null) {
		ret = ft.ret;
		makeNonPointer(state, result);
		if (ft.hasStructRet) {
			llvmExtraArg = state.buildAlloca(ft.ret.llvmType, "sretArg");
			offset = 1;
		}
	} else if (dt !is null) {

		ret = dt.ret;

		auto func = getValueFromAggregate(state, /*#ref*/postfix.loc,
			result, DelegateType.funcIndex);
		llvmExtraArg = getValueFromAggregate(state, /*#ref*/postfix.loc,
			result, DelegateType.voidPtrIndex);

		offset = 1;
		result.value = func;
	} else {
		throw panic(/*#ref*/postfix.loc, "can not call this thing");
	}
	assert(ct !is null);

	// Argument arrays
	auto numArgs = postfix.arguments.length+offset;
	auto args = new Value[](numArgs);
	auto llvmArgs = new LLVMValueRef[](numArgs);
	if (offset) {
		llvmArgs[0] = llvmExtraArg;
	}

	foreach (i, arg; postfix.arguments) {
		auto v = args[i+offset] = new Value();
		state.getValueAnyForm(postfix.arguments[i], v);

		bool isInBounds = i < ct.ct.params.length;
		bool isRefOut = isInBounds && (ct.ct.isArgRef[i] || ct.ct.isArgOut[i]);
		bool isByValAttr = v.type.passByValAttr;
		bool isByValPtr = v.type.passByValPtr;

		if (isRefOut || isByValAttr) {
			makePointer(state, v);
			llvmArgs[i+offset] = LLVMBuildBitCast(state.builder, v.value,
				LLVMPointerType(ct.params[i].llvmType, 0), "");
		} else if (!isRefOut && isByValPtr) {
			makeByValPtrTemp(state, v);
			llvmArgs[i+offset] = v.value;
		} else {
			makeNonPointer(state, v);
			llvmArgs[i+offset] = v.value;
		}
	}

	abiCoerceArguments(state, /*can be null*/irc, /*#ref*/llvmArgs);

	result.value = state.buildCallOrInvoke(/*#ref*/postfix.loc, result.value, llvmArgs);

	// Yes its the same loop again.
	size_t abiOffset = 0;
	for (size_t i = 0; i < postfix.arguments.length; ++i) {
		auto t = args[i+offset].type;
		bool isInBounds = i < ct.ct.params.length;
		bool isRefOut = isInBounds && (ct.ct.isArgRef[i] || ct.ct.isArgOut[i]);
		bool isByValAttr = t.passByValAttr;
		if (!isRefOut && isByValAttr) {
			auto index = cast(LLVMAttributeIndex)(i+offset+1+abiOffset);
			version (LLVMVersion12AndAbove) {
				LLVMAddCallSiteAttribute(result.value, index, t.byValTypeAttr);
			} else {
				LLVMAddCallSiteAttribute(result.value, index, state.attrByVal);
			}
		}
		if (irc !is null && irc.abiModified && irc.abiData[i+abiOffset].length == 2) {
			abiOffset++;
		}
	}

	if (irc !is null) switch (irc.linkage) {
	case ir.Linkage.Windows:
		LLVMSetInstructionCallConv(result.value, LLVMCallConv.X86Stdcall);
		break;
	case ir.Linkage.C, ir.Linkage.Volt:
		break;
	default:
		throw panicUnhandled(/*#ref*/postfix.loc, "call site linkage");
	}

	// If we return a struct via a argument, return that alloca instead.
	if (ft !is null && ft.hasStructRet) {
		result.value = llvmExtraArg;
		result.isPointer = true;
		result.type = ret;
	} else {
		result.isPointer = false;
		result.type = ret;
	}
}

void handleIncDec(State state, ir.Postfix postfix, Value result)
{
	LLVMValueRef ptr, store, value;
	LLVMTypeRef type;
	bool isInc = postfix.op == ir.Postfix.Op.Increment;

	state.getValueRef(postfix.child, result);

	diSetPosition(state, /*#ref*/postfix.loc);

	ptr = result.value;
	type = result.type.llvmType;
	value = LLVMBuildLoad2(state.builder, type, ptr);

	auto ptrType = cast(PointerType)result.type;
	auto primType = cast(PrimitiveType)result.type;
	if (ptrType !is null) {
		auto v = isInc ? 1 : -1;
		auto c = LLVMConstInt(LLVMInt32TypeInContext(state.context), cast(uint)v, true);
		store = LLVMBuildGEP(state.builder, value, [c], "");
	} else if (primType !is null) {
		auto op = isInc ? LLVMOpcode.Add : LLVMOpcode.Sub;
		auto c = primType.fromNumber(state, 1);
		store = LLVMBuildBinOp(state.builder, op, value, c, "");
	} else {
		throw makeExpected(postfix, "primitive or pointer");
	}

	LLVMBuildStore(state.builder, store, ptr);

	diUnsetPosition(state);

	result.isPointer = false;
	result.value = value;
}


/*
 *
 * Misc functions.
 *
 */

void handleAccessExp(State state, ir.AccessExp ae, Value result)
{
	auto b = state.builder;
	uint index;

	state.getValueAnyForm(ae.child, result);

	auto st = cast(StructType)result.type;
	auto ut = cast(UnionType)result.type;
	auto pt = cast(PointerType)result.type;

	if (pt !is null) {
		st = cast(StructType)pt.base;
		ut = cast(UnionType)pt.base;
		if (st is null && ut is null) {
			throw panic(ae, "pointed to value is not a struct or (static)array");
		}

		// We are looking at a pointer, make sure to load it.
		makeNonPointer(state, result);
		result.isPointer = true;
		result.type = pt.base;
	}

	auto key = ae.field.name;

	if (ut !is null) {
		auto ptr = key in ut.indices;
		if (ptr is null) {
			throw panicNotMember(ae, ut.irType.mangledName, key);
		} else {
			index = *ptr;
		}

		// We might be tempted to use a GEP here, but as far as I can
		// tell it is not possible to do this. We want a pointer we can
		// bitcast to what ever type we are reading.
		makePointer(state, result);

		result.type = ut.types[index];
		auto t = LLVMPointerType(result.type.llvmType, 0);
		result.value = LLVMBuildBitCast(state.builder, result.value, t, "");

	} else if (st !is null) {
		auto ptr = key in st.indices;
		if (ptr is null) {
			throw panicNotMember(ae, st.irType.mangledName, key);
		} else {
			index = *ptr;
		}

		getFieldFromAggregate(state, /*#ref*/ae.loc, result, index, st.types[index], result);
	} else {
		/*
		 * If you are ending up here wondering why you can't access a
		 * ArrayType, that is handled by handleBuiltinExp.
		 */
		throw panic(ae, format("%s is not struct, union or pointer", ir.nodeToString(result.type.irType)));
	}
}

void handleVaArgExp(State state, ir.VaArgExp vaexp, Value result)
{
	state.getValueAnyForm(vaexp.arg, result);
	auto ty = fromIr(state, vaexp.type);
	result.value = LLVMBuildVAArg(state.builder, result.value, ty.llvmType, "");
}

void handleBuiltinExp(State state, ir.BuiltinExp inbuilt, Value result)
{
	final switch (inbuilt.kind) with (ir.BuiltinExp.Kind) {
	case ArrayPtr:
		assert(inbuilt.children.length == 1);
		state.getValueAnyForm(inbuilt.children[0], result);
		auto at = cast(ArrayType)result.type;
		auto sat = cast(StaticArrayType)result.type;

		if (at !is null) {
			getFieldFromAggregate(
				state, /*#ref*/inbuilt.loc, result,
				ArrayType.ptrIndex,
				at.types[ArrayType.ptrIndex], result);
		} else if (sat !is null) {
			getPointerFromStaticArray(state, /*#ref*/inbuilt.loc, result);
		} else {
			throw panic(/*#ref*/inbuilt.loc, "bad array ptr built-in.");
		}
		break;
	case ArrayLength:
		assert(inbuilt.children.length == 1);
		state.getValueAnyForm(inbuilt.children[0], result);
		auto at = cast(ArrayType)result.type;
		auto sat = cast(StaticArrayType)result.type;

		if (at !is null) {
			getFieldFromAggregate(
				state, /*#ref*/inbuilt.loc, result,
				ArrayType.lengthIndex,
				at.types[ArrayType.lengthIndex], result);
		} else if (sat !is null) {
			auto t = state.sizeType;
			result.value = LLVMConstInt(t.llvmType, sat.length, false);
			result.isPointer = false;
			result.type = t;
		} else {
			throw panic(/*#ref*/inbuilt.loc, "bad array ptr built-in.");
		}
		break;
	case EnumMembers:
		assert(inbuilt.children.length == 2);
		assert(inbuilt._enum !is null);
		assert(inbuilt.functions.length == 1);  // throw_assert
		handleEnumMembers(state, inbuilt, result);
		break;
	case BuildVtable:
	case Invalid:
	case ArrayDup:
	case AALength:
	case AAKeys:
	case AAValues:
	case AARehash:
	case AAGet:
	case AARemove:
	case AAIn:
	case AADup:
	case UFCS:
	case Classinfo:
	case PODCtor:
	case VaStart, VaEnd, VaArg:
		throw panic(inbuilt, "unhandled");
	}
}

//! Get an LLVMValueRef from a constant string, known at compile time.
private LLVMValueRef fromConstantString(State state, ref in Location loc, string str)
{
	auto result = new Value();
	ir.ArrayType st = buildString(/*#ref*/loc);
	st.mangledName = "ac";
	st.base.mangledName = "mc";
	auto at = ArrayType.fromIr(state, st);
	at.from(state, buildConstantString(state.lp.errSink, /*#ref*/loc, str, false), result);
	return result.value;
}

//! Write the EnumMembers builtin.
void handleEnumMembers(State state, ir.BuiltinExp inbuilt, Value result)
{
	/*
	 * We can do this outside of the switch case since the sink variable
	 * never changes, lets us save a lot of generated IR.
	 */
	auto sinkVal = new Value();
	state.getValue(inbuilt.children[1], sinkVal);

	// Load the delegate pair for the sink.
	auto callval = LLVMBuildExtractValue(state.builder, sinkVal.value, 1, "");
	auto thisval = LLVMBuildExtractValue(state.builder, sinkVal.value, 0, "");

	// The enum argument, get the value and passed to switch.
	auto cond = state.getValue(inbuilt.children[0]);

	// Need to create this up front as it's passed into switch.
	auto defaultCase = LLVMAppendBasicBlockInContext(state.context, state.func, "defaultCase");

	// The actual switch case.
	auto _switch = LLVMBuildSwitch(state.builder, cond, defaultCase, cast(uint)inbuilt._enum.members.length);

	// Jumped to by call cases.
	auto endSwitch = LLVMAppendBasicBlockInContext(state.context, state.func, "endEnumSwitch");

	// Loop over the members of the enum.
	foreach (member; inbuilt._enum.members) {
		auto memberBlock = LLVMAppendBasicBlockInContext(state.context, state.func, "enumSwitchCase");
		auto val = state.getValue(member.assign);
		LLVMAddCase(_switch, val, memberBlock);
		LLVMPositionBuilderAtEnd(state.builder, memberBlock);

		// Now call the sink.
		auto args = new LLVMValueRef[](2);
		args[0] = thisval;
		args[1] = fromConstantString(state, /*#ref*/inbuilt.loc, member.name);
		state.buildCallNeverInvoke(/*#ref*/inbuilt.loc, callval,  args);
		LLVMBuildBr(state.builder, endSwitch);
	}

	LLVMPositionBuilderAtEnd(state.builder, defaultCase);
	Type t;
	auto assertval = state.getFunctionValue(inbuilt.functions[0], /*#out*/t);
	auto args = new LLVMValueRef[](2);
	args[0] = fromConstantString(state, /*#ref*/inbuilt.loc, inbuilt.loc.toString());
	args[1] = fromConstantString(state, /*#ref*/inbuilt.loc, "invalid enum member passed as composable string component");
	auto ct = cast(ir.CallableType)t.irType;
	abiCoerceArguments(state, /*can be null*/ct, /*#ref*/args);
	state.buildCallNeverInvoke(/*#ref*/inbuilt.loc, assertval, args);
	LLVMBuildUnreachable(state.builder);

	LLVMPositionBuilderAtEnd(state.builder, endSwitch);
}

void handleStatementExp(State state, ir.StatementExp statExp, Value result)
{
	foreach (stat; statExp.statements) {
		state.evaluateStatement(stat);
	}
	state.getValueAnyForm(statExp.exp, result);
}

void handleExpReference(State state, ir.ExpReference expRef, Value result)
{
	switch(expRef.decl.declKind) with (ir.Declaration.Kind) {
	case Function:
		auto func = cast(ir.Function)expRef.decl;
		result.isPointer = func.loadDynamic;
		result.value = state.getFunctionValue(func, /*#out*/result.type);
		break;
	case Variable:
		auto var = cast(ir.Variable)expRef.decl;
		result.isPointer = !var.useBaseStorage;
		result.value = state.getVariableValue(var, /*#out*/result.type);
		break;
	case FunctionParam:
		auto fp = cast(ir.FunctionParam)expRef.decl;
		result.isPointer = true;
		result.value = state.getVariableValue(fp, /*#out*/result.type);
		break;
	case EnumDeclaration:
		auto ed = cast(ir.EnumDeclaration)expRef.decl;
		state.getConstantValueAnyForm(ed.assign, result);
		break;
	default:
		throw panicUnhandled(/*#ref*/expRef.loc, toString(expRef.decl.declKind));
	}
}

/*!
 * Gets the value for the expressions and makes sure that
 * it is a struct reference value. Will handle pointers to
 * structs correctly, setting isPointer to true and
 * dereferencing the type pointer to the actual StructType.
 */
void getStructRef(State state, ir.Exp exp, Value result)
{
	getValueAnyForm(state, exp, result);

	auto strct = cast(StructType)result.type;
	auto pt = cast(PointerType)result.type;

	if (strct !is null) {
		makePointer(state, result);
	} else if (pt !is null) {
		makeNonPointer(state, result);

		strct = cast(StructType)pt.base;
		if (strct is null)
			throw panic(exp, "not a pointer to a struct");

		result.type = strct;
		result.isPointer = true;
	} else {
		throw panic(exp, "is not a struct");
	}
}

/*!
 * Get the value pair needed to call or create a delegate.
 */
void getCreateDelegateValues(State state, ir.Postfix postfix, Value instance, Value func)
{
	state.getStructRef(postfix.child, instance);

	// See if the function should be gotten from the vtable.
	int index = -1;
	ir.Function asFunction;
	if (postfix.memberFunction !is null &&
	    !postfix.supressVtableLookup) {
		asFunction = cast(ir.Function) postfix.memberFunction.decl;
		assert(asFunction !is null);
		if (!(asFunction.isFinal && !asFunction.isMarkedOverride)) {
			index = asFunction.vtableIndex;
		}
	}

	if (index >= 0) {
		auto st = cast(StructType)instance.type;
		assert(st !is null);

		getFieldFromAggregate(state, /*#ref*/postfix.loc, instance, 0, st.types[0], func);

		makeNonPointer(state, func);

		auto pt = cast(PointerType)func.type;
		assert(pt !is null);

		// Type of result function.
		auto fnType = state.fromIr(asFunction.type);
		// vtableIndex
		auto indexVal = LLVMConstInt(LLVMInt32TypeInContext(state.context), cast(uint)index, true);
		// void** + indexVal
		func.value = LLVMBuildGEP(state.builder, func.value, [indexVal], "");
		// void** -> void*
		func.value = LLVMBuildLoad2(state.builder, state.voidPtrType.llvmType, func.value);
		// void* -> fn
		func.value = LLVMBuildBitCast(state.builder, func.value, fnType.llvmType, "");
		func.type = fnType;
		func.isPointer = false;
	} else {
		state.getValue(postfix.memberFunction, func);
	}
}

/*!
 * If the given value isPointer is set build a load function.
 */
void makeNonPointer(State state, Value result)
{
	if (!result.isPointer)
		return;

	LLVMTypeRef llvmType = result.type.llvmType;
	result.value = LLVMBuildLoad2(state.builder, llvmType, result.value);
	result.isPointer = false;
}

/*!
 * Ensures that the given Value is a pointer by allocating temp storage for it.
 */
void makePointer(State state, Value result)
{
	if (result.isPointer)
		return;

	auto v = state.buildAlloca(result.type.llvmType, "tempStorage");
	LLVMBuildStore(state.builder, result.value, v);

	result.value = v;
	result.isPointer = true;
}

/*!
 * Ensures that the given Value is a pointer by allocating temp storage for it.
 */
void makeByValPtrTemp(State state, Value result)
{
	makeNonPointer(state, result);

	auto v = state.buildAlloca(result.type.llvmType, "tempByValStorage");
	LLVMBuildStore(state.builder, result.value, v);

	result.value = v;
	result.isPointer = true;
}
