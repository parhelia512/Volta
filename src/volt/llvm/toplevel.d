/*#D*/
// Copyright 2012-2017, Jakob Bornecrantz.
// SPDX-License-Identifier: BSL-1.0
/*!
 * Code handling control flow and toplevel contstructs.
 *
 * @ingroup backend llvmbackend
 */
module volt.llvm.toplevel;

import watt.text.format : format;

import lib.llvm.core;

import volt.errors;
import volta.visitor.visitor;
import volt.semantic.classify;
import volt.llvm.interfaces;
import volt.llvm.abi.base;
import ir = volta.ir;


/*!
 * Visits a module and turn it into code.
 *
 * @ingroup visitors llvmbackend
 */
class LlvmVisitor : NullVisitor
{
public:
	State state;
	LLVMModuleRef mod;
	LLVMBuilderRef b;


public:
	this(State lv)
	{
		this.state = lv;
		this.mod = lv.mod;
		this.b = lv.builder;
	}

	void compile(ir.Module m)
	{
		accept(m, this);
	}


	/*
	 *
	 * TopLevel
	 *
	 */


	override Status enter(ir.Function func)
	{
		Type type;
		auto llvmFunc = state.getFunctionValue(func, /*#out*/type);
		auto llvmType = type.llvmType;

		if (func.loadDynamic) {
			auto init = LLVMConstNull(llvmType);
			LLVMSetInitializer(llvmFunc, init);
			return ContinueParent;
		}

		// Don't export unused functions.
		if (!func.hasBody) {
			return ContinueParent;
		}

		auto ft = cast(FunctionType) type;
		auto ct = cast(ir.CallableType)type.irType;
		assert(ft !is null);

		auto di = diFunction(state, func, llvmFunc, ft);

		State.FunctionState old = state.fnState;
		state.fnState = State.FunctionState.init;

		state.fnState.fall = true;
		state.fnState.func = llvmFunc;
		state.fnState.di = di;
		state.fnState.block = LLVMAppendBasicBlock(llvmFunc, "block");

		// Create a entry block that all variables are declared on.
		auto entry = LLVMAppendBasicBlock(llvmFunc, "entry");
		LLVMMoveBasicBlockAfter(state.block, entry);
		LLVMPositionBuilderAtEnd(b, entry);
		state.fnState.entryBr = LLVMBuildBr(state.builder, state.block);

		// Move the builder to the block following the entry block.
		LLVMPositionBuilderAtEnd(b, state.block);

		// Set position for various setup instructions.
		diSetPosition(state, /*#ref*/func.loc);

		if (func.kind == ir.Function.Kind.GlobalConstructor) {
			state.globalConstructors ~= llvmFunc;
		} else if (func.kind == ir.Function.Kind.GlobalDestructor) {
			state.globalDestructors ~= llvmFunc;
		} else if (func.kind == ir.Function.Kind.LocalConstructor) {
			state.localConstructors ~= llvmFunc;
		} else if (func.kind == ir.Function.Kind.LocalDestructor) {
			state.localDestructors ~= llvmFunc;
		}

		if (ft.hasStructRet) {
			throw panic(func, "return struct with body not supported");
		}

		size_t offset = func.type.hiddenParameter || ft.hasStructRet;
		size_t abiOffset;
		for (size_t irIndex = 0; irIndex < func.params.length; ++irIndex) {
			auto p = func.params[irIndex];
			auto v = LLVMGetParam(llvmFunc, cast(uint)(irIndex + offset + abiOffset));
			auto t = state.fromIr(p.type);

			bool isRef = func.type.isArgRef[irIndex];
			bool isOut = func.type.isArgOut[irIndex];
			bool isByValAttr = t.passByValAttr;
			bool isByValPtr = t.passByValPtr;

			// These two conditions have to happen,
			// even if the parameter isn't named.
			if (isOut) {
				auto initC = LLVMConstNull(t.llvmType);
				LLVMBuildStore(state.builder, initC, v);
			} else if (isByValAttr && !isRef) {
				auto index = cast(LLVMAttributeIndex)(irIndex+offset+1);
				version (LLVMVersion12AndAbove) {
					LLVMAddAttributeAtIndex(llvmFunc, index, t.byValTypeAttr);
				} else {
					LLVMAddAttributeAtIndex(llvmFunc, index, state.attrByVal);
				}
			}

			// Early out on unamed parameters.
			if (p.name is null) {
				continue;
			} else if (isRef || isOut || isByValAttr || isByValPtr) {
				state.makeByValVariable(p, v);
			} else {
				if (!abiCoercePrologueParameter(state, llvmFunc, func, ct, v, irIndex+offset, /*#ref*/abiOffset)) {
					auto a = state.getVariableValue(p, /*#out*/t);
					LLVMBuildStore(state.builder, v, a);
				}
			}
		}

		ir.Variable thisVar = func.thisHiddenParameter;
		if (thisVar !is null) {
			auto v = LLVMGetParam(llvmFunc, 0);
			state.makeThisVariable(thisVar, v);
		}

		ir.Variable nestVar = func.nestedHiddenParameter;
		if (nestVar !is null) {
			auto v = LLVMGetParam(llvmFunc, 0);
			state.makeNestVariable(nestVar, v);
		}

		// Reset position.
		diUnsetPosition(state);

		// Go over the function body.
		accept(func.parsedBody, this);

		// Assume language pass knows what it is doing.
		if (state.fall) {
			state.buildCallNeverInvoke(/*#ref*/func.loc, state.llvmTrap, null);
			LLVMBuildUnreachable(state.builder);
		}

		// Clean up
		state.onFunctionClose();
		state.fnState = old;

		// Reset builder for nested functions.
		if (state.block !is null) {
			LLVMPositionBuilderAtEnd(b, state.block);
		}
		auto oldBlock = state.block;
		state.startBlock(oldBlock);

		handleScopedFunction(func, llvmFunc);

		return ContinueParent;
	}

	override Status enter(ir.Variable var)
	{
		Type type;

		final switch(var.storage) with (ir.Variable.Storage) {
		case Invalid:
			assert(false, "invalid variable");
		case Field:
			break;
		case Function, Nested:
			assert(state.func !is null);

			auto v = state.getVariableValue(var, /*#out*/type);

			if (var.specialInitValue) {
				assert(var.assign is null);
				if (var.name == "_typeids") {
					uint i = LLVMCountParams(state.func) - 2;
					LLVMBuildStore(state.builder, LLVMGetParam(state.func, i), v);
				} else if (var.name == "_args") {
					uint i = LLVMCountParams(state.func) - 1;
					LLVMBuildStore(state.builder, LLVMGetParam(state.func, i), v);
				}
				break;
			} else if (var.assign !is null) {
				auto ret = state.getValue(var.assign);
				diSetPosition(state, /*#ref*/var.loc);
				LLVMBuildStore(state.builder, ret, v);
				diUnsetPosition(state);
				break;
			}

			if (var.noInitialise) {
				break;
			}

			auto s = size(state.target, type.irType);
			if (s < 64) {
				auto ret = LLVMConstNull(type.llvmType);
				LLVMBuildStore(state.builder, ret, v);
				break;
			}

			break;
		case Local:
		case Global:
			if (var.isExtern) {
				break;
			}

			LLVMValueRef init;
			auto v = state.getVariableValue(var, /*#out*/type);

			if (var.assign !is null) {
				init = state.getConstant(var.assign);
			} else {
				init = LLVMConstNull(type.llvmType);
			}
			LLVMSetInitializer(v, init);
			state.diGlobalVariable(var, type, v);
			break;
		}

		return ContinueParent;
	}


	/*
	 *
	 * Statements
	 *
	 */


	override Status enter(ir.ReturnStatement ret)
	{
		assert(state.fall, ret.loc.toString() ~ "Huh?");

		Value val;
		if (ret.exp !is null) {
			val = new Value();
			state.getValue(ret.exp, val);

			// Handle void returning functions.
			if (val.type is state.voidType) {
				val = null;
			}
		}

		handleScopeSuccessTo(/*#ref*/ret.loc, null);

		diSetPosition(state, /*#ref*/ret.loc);

		if (val is null) {
			LLVMBuildRet(b, null);
		} else {
			LLVMBuildRet(b, val.value);
		}

		diUnsetPosition(state);

		state.fnState.fall = false;

		return ContinueParent;
	}

	override Status enter(ir.ExpStatement exps)
	{
		panicAssert(exps, state.fall);

		// XXX: Should we do something here?
		auto ret = state.getValue(exps.exp);

		return ContinueParent;
	}

	// Have to move this here for now.
	struct Block
	{
		ir.SwitchCase _case;
		LLVMBasicBlockRef block;
	}

	override Status enter(ir.SwitchStatement ss)
	{
		assert(state.fall);

		auto cond = state.getValue(ss.condition);

		Block[] blocks;

		auto old = state.fnState.swi;
		state.fnState.swi = State.SwitchState.init;
		// Even final switches have an (invalid) default case.
		state.fnState.swi.def = LLVMAppendBasicBlockInContext(state.context, state.func, "defaultCase");
		ir.BlockStatement defaultStatements;
		auto _switch = LLVMBuildSwitch(state.builder, cond, state.switchDefault, cast(uint)(ss.cases.length));

		foreach (_case; ss.cases) {
			if (_case.firstExp !is null) acceptExp(/*#ref*/_case.firstExp, this);
			void addVal(ir.Node node, LLVMValueRef val, LLVMBasicBlockRef block)
			{
				LLVMBasicBlockRef tmp;
				auto i = LLVMConstIntGetSExtValue(val);
				if (state.switchGetCase(i, /*#out*/tmp)) {
					throw makeSwitchDuplicateCase(node);
				} else {
					state.switchSetCase(i, block);
				}
				LLVMAddCase(_switch, val, block);
			}

			void addExp(ir.Exp exp, LLVMBasicBlockRef block)
			{
				if (exp is null) {
					return;
				}
				auto val = state.getValue(exp);
				addVal(exp, val, block);
			}

			if (_case.isDefault) {
				defaultStatements = _case.statements;
				Block add = { _case, state.fnState.swi.def };
				blocks ~= add;
			} else {
				auto block = LLVMAppendBasicBlockInContext(state.context, state.func, "switchCase");
				if (_case.firstExp !is null && _case.secondExp !is null) {
					// case A: .. case B:
					auto aval = state.getValue(_case.firstExp);
					auto bval = state.getValue(_case.secondExp);
					auto typ = LLVMTypeOf(aval);
					auto ai = LLVMConstIntGetSExtValue(aval);
					auto bi = LLVMConstIntGetSExtValue(bval);
					if (ai >= bi) {
						throw panic(/*#ref*/ss.loc, "invalid case range");
					}
					while (ai <= bi) {
						auto val = LLVMConstInt(typ, cast(ulong)ai++, false);
						addVal(_case.firstExp, val, block);
					}
				} else {
					addExp(_case.firstExp, block);
					foreach (exp; _case.exps) addExp(exp, block);
				}
				Block add = { _case, block };
				blocks ~= add;
			}
		}
		auto outBlock = LLVMAppendBasicBlockInContext(state.context, state.func, "endSwitch");

		// Generate code for each case.
		auto breakBlock = state.replaceBreakBlock(outBlock);
		foreach (i, block; blocks) {
			if (block._case.isDefault) {
				continue;
			}
			state.startBlock(block.block);
			doNewBlock(block.block, block._case.statements, i == blocks.length - 1 ? outBlock : blocks[i+1].block);
		}
		state.startBlock(state.switchDefault);
		if (defaultStatements !is null) {
			doNewBlock(state.switchDefault, defaultStatements, outBlock);
		} else {
			// No default block (e.g. final switches)
			state.buildCallNeverInvoke(/*#ref*/ss.loc, state.llvmTrap, null);
			LLVMBuildUnreachable(state.builder);
		}
		state.replaceBreakBlock(breakBlock);

		// Continue generating code after the switch.
		LLVMMoveBasicBlockAfter(outBlock, state.block);
		state.startBlock(outBlock);

		state.fnState.swi = old;

		return ContinueParent;
	}

	override Status enter(ir.TryStatement t)
	{
		if (state.target.ehType == ExceptionHandlingType.Posix) {
			handleTryPosixEH(t);
		} else if (state.target.ehType == ExceptionHandlingType.Windows) {
			version (LLVMVersion7AndAbove) {
				handleTryWindowsEH(t);
			} else {
				assert(false, "handleTryWindowsEH not avaible on LLVM < 7.");
			}
		} else {
			handleTryNoEH(t);
		}

		return ContinueParent;
	}

	void handleTryNoEH(ir.TryStatement t)
	{
		accept(t.tryBlock, this);

		if (t.finallyBlock !is null) {
			accept(t.finallyBlock, this);
		}
	}

	version (LLVMVersion7AndAbove) void handleTryWindowsEH(ir.TryStatement t)
	{
		if (!LLVMHasPersonalityFn(state.func)) {
			LLVMSetPersonalityFn(state.func, state.ehPersonalityFunc);
		}

		LLVMBasicBlockRef catchDispatch, catchBlock, tryDone;

		LLVMBasicBlockRef callBlock = state.block;
		catchDispatch = LLVMAppendBasicBlockInContext(
			state.context, state.func, "catch.dispatch");
		auto catchBlocks   = new LLVMBasicBlockRef[](t.catchVars.length);
		auto catchHandlers = new LLVMBasicBlockRef[](t.catchVars.length);
		foreach (i; 0 .. t.catchVars.length) {
			catchBlocks[i]   = LLVMAppendBasicBlockInContext(
				state.context, state.func, "catch"
			);
			catchHandlers[i] = LLVMAppendBasicBlockInContext(
				state.context, state.func, "catch.handler"
			);
		}
		tryDone = LLVMAppendBasicBlockInContext(
			state.context, state.func, "try.done");

		state.pushPath();
		auto p = state.path;

		auto loads = new LLVMValueRef[](t.catchVars.length);
		auto tinfos = new LLVMValueRef[](t.catchVars.length);
		foreach (index, v; t.catchVars) {
			Type type;
			auto asTR = cast(ir.TypeReference) v.type;
			ir.Class c = cast(ir.Class) asTR.type;
			loads[index] = state.getVariableValue(t.catchVars[index], /*#out*/type);
			tinfos[index] = state.getVariableValue(c.typeInfo, /*#out*/type);
	
			auto value = state.getVariableValue(c.typeInfo, /*#out*/type);
		}

		p.landingBlock = catchDispatch;

		accept(t.tryBlock, this);
		if (state.fall) {
			LLVMBuildBr(b, tryDone);
		}

		state.popPath();

		state.startBlock(catchDispatch);

		auto cs = LLVMBuildCatchSwitch(b, null, null, cast(uint)t.catchVars.length, "");

		foreach (i, v; t.catchVars) {
			LLVMAddHandler(cs, catchBlocks[i]);
			state.startBlock(catchBlocks[i]);

			auto args = new LLVMValueRef[](3);
			args[0] = tinfos[i];
			args[1] = LLVMConstInt(LLVMInt32TypeInContext(state.context), 0, true);
			args[2] = loads[i];
			auto cpad = LLVMBuildCatchPad(b, cs, args.ptr, 3, "");

			LLVMBuildCatchRet(b, cpad, catchHandlers[i]);
			state.startBlock(catchHandlers[i]);
			accept(t.catchBlocks[i], this);
			if (state.fall) {
				LLVMBuildBr(b, tryDone);
			}
		}

		state.startBlock(tryDone);
	}

	void handleTryPosixEH(ir.TryStatement t)
	{
		LLVMBasicBlockRef landingPad, catchBlock, tryDone;

		landingPad = LLVMAppendBasicBlockInContext(
			state.context, state.func, "landingPad");
		tryDone = LLVMAppendBasicBlockInContext(
			state.context, state.func, "tryDone");
		catchBlock = LLVMAppendBasicBlockInContext(
			state.context, state.func, "catchBlock");


		/*
		 * Setup catch block, catch types and landingpad state.
		 */
		state.pushPath();
		auto p = state.path;

		p.catchBlock = catchBlock;
		p.landingBlock = landingPad;
		p.catchTypeInfos = new LLVMValueRef[](t.catchVars.length);
		foreach (index, v; t.catchVars) {
			Type type;
			auto asTR = cast(ir.TypeReference) v.type;
			ir.Class c = cast(ir.Class) asTR.type;
			p.catchTypeInfos[index] = state.getVariableValue(c.typeInfo, /*#out*/type);
		}


		/*
		 * The try body.
		 */
		accept(t.tryBlock, this);

		if (state.fall) {
			LLVMBuildBr(state.builder, tryDone);
		}


		/*
		 * Landing pad.
		 */
		State.PathState dummy;
		LLVMMoveBasicBlockAfter(landingPad, state.block);
		fillInLandingPad(landingPad, t.finallyBlock !is null, /*#out*/dummy);
		assert(dummy is p);

		// Reset the path.
		state.popPath();


		/*
		 * Catch code.
		 */
		LLVMBuildBr(state.builder, catchBlock);
		LLVMMoveBasicBlockAfter(catchBlock, state.block);
		state.startBlock(catchBlock);

		auto e = LLVMBuildLoad(state.builder, state.ehExceptionVar);
		auto i = LLVMBuildLoad(state.builder, state.ehIndexVar);
		foreach (index, v; t.catchVars) {
			Type type;
			auto asTR = cast(ir.TypeReference)v.type;
			ir.Class c = cast(ir.Class)asTR.type;
			auto value = state.getVariableValue(c.typeInfo, /*#out*/type);
			value = LLVMBuildBitCast(state.builder, value, state.voidPtrType.llvmType, "");

			auto func = state.ehTypeIdFunc;
			auto test = state.buildCallNeverInvoke(/*#ref*/v.loc, func, [value]);
			test = LLVMBuildICmp(state.builder, LLVMIntPredicate.EQ, test, i, "");


			LLVMBasicBlockRef thenBlock, elseBlock;
			thenBlock = LLVMAppendBasicBlockInContext(
					state.context, state.func, "ifTrue");

			elseBlock = LLVMAppendBasicBlockInContext(
					state.context, state.func, "ifFalse");


			LLVMBuildCondBr(state.builder, test, thenBlock, elseBlock);
			LLVMMoveBasicBlockAfter(thenBlock, state.block);
			state.startBlock(thenBlock);

			auto ptr = state.getVariableValue(v, /*#out*/type);
			value = LLVMBuildBitCast(state.builder, e, type.llvmType, "");
			LLVMBuildStore(state.builder, value, ptr);

			accept(t.catchBlocks[index], this);

			if (state.fall) {
				LLVMBuildBr(state.builder, tryDone);
			}

			LLVMMoveBasicBlockAfter(elseBlock, state.block);
			state.startBlock(elseBlock);
		}

		/*
		 * Finally block.
		 */
		if (t.finallyBlock !is null) {
			accept(t.finallyBlock, this);
			LLVMBuildBr(state.builder, state.ehResumeBlock);
			throw panic(t.finallyBlock, "does not support finally statements");
		} else {
			LLVMBuildBr(state.builder, state.ehResumeBlock);
		}

		/*
		 * Everything after the try statement.
		 */
		LLVMMoveBasicBlockAfter(tryDone, state.block);
		state.startBlock(tryDone);
	}

	override Status enter(ir.IfStatement ifs)
	{
		assert(state.fall);

		auto cond = state.getValue(ifs.exp);

		bool hasElse = ifs.elseState !is null;
		LLVMBasicBlockRef thenBlock, elseBlock, endBlock;

		thenBlock = LLVMAppendBasicBlockInContext(
			state.context, state.func, "ifTrue");
		if (hasElse)
			elseBlock = LLVMAppendBasicBlockInContext(
				state.context, state.func, "ifFalse");
		endBlock = LLVMAppendBasicBlockInContext(
			state.context, state.func, "endIf");

		// Condition placed in the current block.
		LLVMBuildCondBr(state.builder, cond, thenBlock,
			hasElse ? elseBlock : endBlock);

		// Do new then block after the current block.
		doNewBlock(thenBlock, ifs.thenState, endBlock);

		// Any else block, after any block that might have be added.
		if (hasElse) {
			doNewBlock(elseBlock, ifs.elseState, endBlock);
		}

		// And the out block.
		LLVMMoveBasicBlockAfter(endBlock, state.block);
		state.startBlock(endBlock);

		return ContinueParent;
	}

	override Status enter(ir.WhileStatement w)
	{
		assert(state.fall);

		LLVMBasicBlockRef whileCond, whileBody, whileOut;

		whileCond = LLVMAppendBasicBlockInContext(
			state.context, state.func, "whileCond");
		whileBody = LLVMAppendBasicBlockInContext(
			state.context, state.func, "whileBody");
		whileOut = LLVMAppendBasicBlockInContext(
			state.context, state.func, "whileOut");

		// Make continue jump to the cond block, and break to out.
		auto saveBre = state.replaceBreakBlock(whileOut);
		auto saveCon = state.replaceContinueBlock(whileCond);

		// Jump to the cond block.
		LLVMBuildBr(state.builder, whileCond);

		// Do while cond.
		state.startBlock(whileCond);
		auto cond = state.getValue(w.condition);
		LLVMBuildCondBr(state.builder, cond, whileBody, whileOut);

		// Do whileBody
		doNewBlock(whileBody, w.block, whileCond);

		// Switch out block
		LLVMMoveBasicBlockAfter(whileOut, state.block);
		state.startBlock(whileOut);
		state.replaceBreakBlock(saveBre);
		state.replaceContinueBlock(saveCon);

		return ContinueParent;
	}

	override Status enter(ir.DoStatement d)
	{
		assert(state.fall);

		LLVMBasicBlockRef doCond, doBody, doOut;

		doBody = LLVMAppendBasicBlockInContext(
			state.context, state.func, "doBody");
		doCond = LLVMAppendBasicBlockInContext(
			state.context, state.func, "doCond");
		doOut = LLVMAppendBasicBlockInContext(
			state.context, state.func, "doOut");

		// Make continue jump to the cond block, and break to out.
		auto saveBre = state.replaceBreakBlock(doOut);
		auto saveCon = state.replaceContinueBlock(doCond);

		// Jump to the body block
		LLVMBuildBr(state.builder, doBody);

		// Do followed by the body
		doNewBlock(doBody, d.block, doCond);

		// Do the while statement part
		LLVMMoveBasicBlockAfter(doCond, state.block);
		state.startBlock(doCond);
		auto cond = state.getValue(d.condition);
		LLVMBuildCondBr(state.builder, cond, doBody, doOut);

		// Switch out block
		LLVMMoveBasicBlockAfter(doOut, state.block);
		state.startBlock(doOut);
		state.replaceBreakBlock(saveBre);
		state.replaceContinueBlock(saveCon);

		return ContinueParent;
	}

	override Status enter(ir.ForStatement f)
	{
		LLVMBasicBlockRef forCond, forBody, forPost, forOut;

		forCond = LLVMAppendBasicBlockInContext(
			state.context, state.func, "forCond");
		forBody = LLVMAppendBasicBlockInContext(
			state.context, state.func, "forBody");
		forPost = LLVMAppendBasicBlockInContext(
			state.context, state.func, "forPost");
		forOut = LLVMAppendBasicBlockInContext(
			state.context, state.func, "forOut");

		// Init stuff go into the fnState.block
		foreach (var; f.initVars)
			enter(var);
		foreach (exp; f.initExps)
			state.getValue(exp);

		// Make continue jump to the post block, and break to out.
		auto saveBre = state.replaceBreakBlock(forOut);
		auto saveCon = state.replaceContinueBlock(forPost);

		// Jump to the cond block
		LLVMBuildBr(state.builder, forCond);

		// Do while cond.
		state.startBlock(forCond);
		LLVMValueRef cond;
		if (f.test is null) {
			cond = LLVMConstInt(LLVMInt1Type(), 1, false);
		} else {
			cond = state.getValue(f.test);
		}
		LLVMBuildCondBr(state.builder, cond, forBody, forOut);

		// Main body
		doNewBlock(forBody, f.block, forPost);

		// For post block
		LLVMMoveBasicBlockAfter(forPost, state.block);
		state.startBlock(forPost);

		foreach (exp; f.increments) {
			state.getValue(exp);
		}

		// End the increment block with jump back to cond
		LLVMBuildBr(state.builder, forCond);

		// For out block
		LLVMMoveBasicBlockAfter(forOut, state.block);
		state.startBlock(forOut);
		state.replaceBreakBlock(saveBre);
		state.replaceContinueBlock(saveCon);

		return ContinueParent;
	}

	override Status enter(ir.BlockStatement bs)
	{
		auto old = state.path;
		state.pushPath();

		foreach (s; bs.statements) {
			accept(s, this);
		}

		if (state.fall) {
			// TODO Add a endBraceLocation field to BlockStatement.
			handleScopeSuccessTo(/*#ref*/bs.loc, old);
		}

		state.popPath();
		return ContinueParent;
	}

	override Status visit(ir.ContinueStatement cs)
	{
		auto p = state.findContinue();

		if (cs.label !is null) {
			throw panic(/*#ref*/cs.loc, "labled continue statements not supported");
		}

		handleScopeSuccessTo(/*#ref*/cs.loc, p);

		LLVMBuildBr(state.builder, p.continueBlock);
		state.fnState.fall = false;

		return Continue;
	}

	override Status visit(ir.BreakStatement bs)
	{
		auto p = state.findBreak();

		if (bs.label !is null) {
			throw panic(/*#ref*/bs.loc, "labled break statements not supported");
		}

		handleScopeSuccessTo(/*#ref*/bs.loc, p);

		LLVMBuildBr(state.builder, p.breakBlock);
		state.fnState.fall = false;

		return Continue;
	}

	override Status leave(ir.GotoStatement gs)
	{
		// Goto will exit the scope just as if it was a break.
		auto p = state.findBreak();
		handleScopeSuccessTo(/*#ref*/gs.loc, p);

		if (gs.isDefault) {
			LLVMBuildBr(state.builder, state.switchDefault);
			state.fnState.fall = false;
		} else if (gs.isCase) {
			if (gs.exp is null) {
				// TODO XXX this is a bug.
				state.fnState.fall = true;
			} else {
				auto v = state.getValue(gs.exp);
				auto i = LLVMConstIntGetSExtValue(v);
				LLVMBasicBlockRef b;

				if (!state.switchGetCase(i, /*#out*/b)) {
					throw makeExpected(/*#ref*/gs.loc, "valid case");
				}
				LLVMBuildBr(state.builder, b);
				state.fnState.fall = false;
			}
		} else {
			throw panic(/*#ref*/gs.loc, "non switch goto");
		}
		return Continue;
	}

	override Status leave(ir.ThrowStatement t)
	{
		// Should not call success here.

		if (t.exp is null) {
			throw panic(/*#ref*/t.loc, "empty throw statement");
		}
	
		state.getValue(t.exp);
		LLVMBuildUnreachable(state.builder);
		state.fnState.fall = false;

		return Continue;
	}

	override Status leave(ir.Module m)
	{
		if (state.globalConstructors.length > 0 || state.globalDestructors.length > 0) {
			throw panic(/*#ref*/m.loc, "global constructor or destructor made it into llvm backend.");
		}

		if (state.localConstructors.length > 0 || state.localDestructors.length > 0) {
			throw panic(/*#ref*/m.loc, "local constructor or destructor made it into llvm backend.");
		}

		return Continue;
	}

	void doNewBlock(LLVMBasicBlockRef b, ir.BlockStatement bs,
	                LLVMBasicBlockRef fall)
	{
		LLVMMoveBasicBlockAfter(b, state.block);
		state.startBlock(b);
		accept(bs, this);
		if (state.fall)
			LLVMBuildBr(state.builder, fall);
	}

	void handleScopeSuccessTo(ref Location loc, State.PathState to)
	{
		LLVMValueRef[] arg;
		void buildArgIfNeeded() {
			if (arg.length) {
				return;
			}
			auto value = LLVMBuildBitCast(
				state.builder, state.fnState.nested,
				state.voidPtrType.llvmType, "");
			arg = [value];
		}


		auto p = state.path;
		while (p !is to) {
			foreach_reverse (index, func; p.scopeSuccess) {
				if (func is null) {
					continue;
				}

				buildArgIfNeeded();
				auto pad = p.scopeLanding[index];
				state.buildCallOrInvoke(/*#ref*/loc, func, arg, pad);
			}
			p = p.prev;
		}
	}

	void handleScopedFunction(ir.Function func, LLVMValueRef llvmFunc)
	{
		if (state.target.ehType == ExceptionHandlingType.Windows) {
			version (LLVMVersion7AndAbove) {
				handleScopedFunctionWindows(func, llvmFunc);
			} else {
				assert(false, "handleScopedFunctionWindows not avaible on LLVM < 7.");
			}
		} else {
			handleScopedFunctionPosixAndNone(func, llvmFunc);
		}
	}

	version (LLVMVersion7AndAbove) void handleScopedFunctionWindows(ir.Function func, LLVMValueRef llvmFunc)
	{
		auto success = func.isLoweredScopeExit | func.isLoweredScopeSuccess;
		auto failure = func.isLoweredScopeExit | func.isLoweredScopeFailure;

		if (!success && !failure) {
			return;
		}

		auto landingPath = state.findLanding();
		state.path.scopeSuccess ~= success ? llvmFunc : null;
		state.path.scopeFailure ~= failure ? llvmFunc : null;
		state.path.scopeLanding ~= landingPath !is null ?
			landingPath.landingBlock : null;

		if (!failure) {
			return;
		}

		if (!LLVMHasPersonalityFn(state.func)) {
			LLVMSetPersonalityFn(state.func, state.ehPersonalityFunc);
		}

		auto p = state.path;
		auto oldBlock = state.block;
		p.landingBlock = LLVMAppendBasicBlockInContext(
			state.context, state.func, "scope.failure.cs");

		auto callblock = LLVMAppendBasicBlockInContext(state.context, state.func, "scope.failure.catchswitch");
		auto failblock = LLVMAppendBasicBlockInContext(state.context, state.func, "scope.failure");
		state.startBlock(p.landingBlock);
		auto cs = LLVMBuildCatchSwitch(b, null, null, 1, "");
		LLVMAddHandler(cs, callblock);

		state.startBlock(callblock);
		auto args = new LLVMValueRef[](3);
		Type type;
		auto args2Type = state.fromIr(state.lp.exceptThrowable);
		args[0] = state.getVariableValue(state.lp.exceptThrowable.typeInfo, /*#out*/type);
		args[1] = LLVMConstInt(LLVMInt32TypeInContext(state.context), 0, true);
		args[2] = state.buildAlloca(args2Type.llvmType, "failcatchvar");
		auto cpad = LLVMBuildCatchPad(b, cs, args.ptr, 3, "");

		LLVMBuildCatchRet(b, cpad, failblock);
		state.startBlock(failblock);

		auto value = LLVMBuildBitCast(
			state.builder, state.fnState.nested,
			state.voidPtrType.llvmType, "");
		auto arg = [value];

		while (p !is null) {
			foreach_reverse (loopFunc; p.scopeFailure) {
				if (loopFunc is null) {
					continue;
				}
				state.buildCallNeverInvoke(/*#ref*/func.loc, loopFunc, arg);
			}
			p = p.prev;
		}

		auto throwFunc = state.getFunctionValue(state.lp.ehRethrowFunc, /*#out*/type);
		LLVMValueRef[1] throwArgs;
		throwArgs[0] = LLVMBuildLoad2(b, args2Type.llvmType, args[2]);
		state.buildCallNeverInvoke(/*#ref*/func.loc, throwFunc, throwArgs[0 .. $]);
		LLVMBuildUnreachable(b);

		state.startBlock(oldBlock);
	}

	void handleScopedFunctionPosixAndNone(ir.Function func, LLVMValueRef llvmFunc)
	{
		auto success = func.isLoweredScopeExit | func.isLoweredScopeSuccess;
		auto failure = func.isLoweredScopeExit | func.isLoweredScopeFailure;

		// Disable scope(failure) handling when we don't have exception handling.
		if (state.target.ehType != ExceptionHandlingType.Posix) {
			failure = false;
		}

		// Nothing needs to be done
		if (!success && !failure) {
			return;
		}

		auto landingPath = state.findLanding();
		state.path.scopeSuccess ~= success ? llvmFunc : null;
		state.path.scopeFailure ~= failure ? llvmFunc : null;
		state.path.scopeLanding ~= landingPath !is null ?
			landingPath.landingBlock : null;

		// Don't need to generate a landingPad
		if (!failure) {
			return;
		}

		auto oldBlock = state.block;
		auto landingPad = LLVMAppendBasicBlockInContext(
			state.context, state.func, "landingPad");

		State.PathState catchPath;
		fillInLandingPad(landingPad, true, /*#out*/catchPath);

		auto value = LLVMBuildBitCast(
			state.builder, state.fnState.nested,
			state.voidPtrType.llvmType, "");
		auto arg = [value];

		auto p = state.path;
		while (p !is null) {
			foreach_reverse (loopFunc; p.scopeFailure) {
				if (loopFunc is null) {
					continue;
				}
				state.buildCallNeverInvoke(/*#ref*/func.loc, loopFunc, arg);
			}

			if (p is catchPath) {
				break;
			}
			p = p.prev;
		}

		state.path.landingBlock = landingPad;
		if (catchPath is null) {
			LLVMBuildBr(state.builder, state.ehResumeBlock);
		} else {
			LLVMBuildBr(state.builder, catchPath.catchBlock);
		}

		state.startBlock(oldBlock);
	}

	/*
	 * Fills in the given landing pad.
	 *
	 * Side-effects:
	 *   Will set the landingPad as the current working block.
	 */
	void fillInLandingPad(LLVMBasicBlockRef landingPad, bool setCleanup,
	                      out State.PathState catchPath)
	{
		catchPath = state.findCatch();
		auto catches = catchPath !is null ? catchPath.catchTypeInfos : null;

		state.startBlock(landingPad);
		auto lp = LLVMBuildLandingPad(
			state.builder, state.ehLandingType,
			state.ehPersonalityFunc,
			cast(uint)catches.length, "");
		auto e = LLVMBuildExtractValue(state.builder, lp, 0, "");
		LLVMBuildStore(state.builder, e, state.ehExceptionVar);
		auto i = LLVMBuildExtractValue(state.builder, lp, 1, "");
		LLVMBuildStore(state.builder, i, state.ehIndexVar);

		LLVMSetCleanup(lp, setCleanup);
		foreach (ti; catches) {
			LLVMAddClause(lp, ti);
		}
	}

	/*
	 * Ignore but pass.
	 */
	override Status enter(ir.Module m) { return Continue; }

	/*
	 * Should not enter.
	 */
	override Status leave(ir.Variable v) { assert(false); }
	override Status leave(ir.Function f) { assert(false); }
	override Status leave(ir.IfStatement i) { assert(false); }
	override Status leave(ir.ExpStatement e) { assert(false); }
	override Status leave(ir.BlockStatement b) { assert(false); }
	override Status leave(ir.ReturnStatement r) { assert(false); }
}
