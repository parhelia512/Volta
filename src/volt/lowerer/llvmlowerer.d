// Copyright © 2013, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.lowerer.llvmlowerer;

import watt.conv : toString;
import watt.text.format : format;
import watt.io.file : read, exists;

import ir = volt.ir.ir;
import volt.ir.copy;
import volt.ir.util;

import volt.errors;
import volt.interfaces;
import volt.token.location;
import volt.visitor.visitor;
import volt.visitor.scopemanager;
import volt.visitor.nodereplace;

import volt.lowerer.array;

import volt.semantic.util;
import volt.semantic.typer;
import volt.semantic.mangle;
import volt.semantic.lookup;
import volt.semantic.nested;
import volt.semantic.classify;
import volt.semantic.classresolver;
import volt.semantic.ctfe;
import volt.semantic.overload;


void buildAAInsert(Location loc, LanguagePass lp, ir.Module thisModule, ir.Scope current,
		ir.StatementExp statExp, ir.AAType aa, ir.Variable var, ir.Exp key, ir.Exp value,
		bool buildif=true, bool aaIsPointer=true) {
	auto aaNewFn = retrieveFunctionFromObject(lp, loc, "vrt_aa_new");

	string name;
	if (aa.key.nodeType == ir.NodeType.PrimitiveType) {
		name = "vrt_aa_insert_primitive";
	} else {
		name = "vrt_aa_insert_array";
	}

	auto aaInsertFn = retrieveFunctionFromObject(lp, loc, name);

	ir.Exp varExp;
	if (buildif) {
		auto thenState = buildBlockStat(loc, statExp, current);
		varExp = buildExpReference(loc, var, var.name);
		ir.Exp[] args = [ cast(ir.Exp)buildTypeidSmart(loc, lp, aa.value),
		                  cast(ir.Exp)buildTypeidSmart(loc, lp, aa.key)
		];
		buildExpStat(loc, thenState,
			buildAssign(loc,
				aaIsPointer ? buildDeref(loc, varExp) : varExp,
				buildCall(loc, aaNewFn, args, aaNewFn.name
				)
			)
		);

		varExp = buildExpReference(loc, var, var.name);
		buildIfStat(loc, statExp,
			buildBinOp(loc, ir.BinOp.Op.Is,
				aaIsPointer ? buildDeref(loc, varExp) : varExp,
				buildConstantNull(loc, buildVoidPtr(loc))
			),
			thenState
		);
	}

	varExp = buildExpReference(loc, var, var.name);
	auto call = buildExpStat(loc, statExp,
		buildCall(loc, aaInsertFn, [
			aaIsPointer ? buildDeref(loc, varExp) : varExp,
			buildAAKeyCast(loc, lp, thisModule, current, key, aa),
			buildCastToVoidPtr(loc, buildAddrOf(value))
		], aaInsertFn.name)
	);
}

void buildAALookup(Location loc, LanguagePass lp, ir.Module thisModule, ir.Scope current,
		ir.StatementExp statExp, ir.AAType aa, ir.Variable var, ir.Exp key, ir.Exp store) {
	string name;
	if (aa.key.nodeType == ir.NodeType.PrimitiveType)
		name = "vrt_aa_in_primitive";
	else
		name = "vrt_aa_in_array";
	auto inAAFn = retrieveFunctionFromObject(lp, loc, name);
	auto throwFn = lp.ehThrowFunc;

	auto thenState = buildBlockStat(loc, statExp, current);

	auto knfClass = retrieveClassFromObject(lp, loc, "KeyNotFoundException");
	auto throwableClass = retrieveClassFromObject(lp, loc, "Throwable");

	auto _new = buildNew(loc, knfClass, "KeyNotFoundException", [
			cast(ir.Exp)buildConstantString(loc, `Key does not exist`)
				]);
	_new.ctor = knfClass.userConstructors[0];

	buildExpStat(loc, thenState,
		buildCall(loc, throwFn, [
			buildCastSmart(throwableClass, _new),
			buildConstantString(loc, loc.filename),
			buildConstantSizeT(loc, lp, loc.line)],
		throwFn.name));

	buildIfStat(loc, statExp,
		buildBinOp(loc, ir.BinOp.Op.Equal,
			buildCall(loc, inAAFn, [
				buildDeref(loc, buildExpReference(loc, var, var.name)),
				buildAAKeyCast(loc, lp, thisModule, current, key, aa),
				buildCastToVoidPtr(loc,
					buildAddrOf(loc, store)
				)
			], inAAFn.name),
			buildConstantBool(loc, false)
		),
		thenState
	);
}

ir.Exp buildAAKeyCast(Location loc, LanguagePass lp, ir.Module thisModule, ir.Scope current, ir.Exp key, ir.AAType aa)
{
	if (aa.key.nodeType == ir.NodeType.PrimitiveType) {
		auto prim = cast(ir.PrimitiveType)aa.key;

		assert(prim.type != ir.PrimitiveType.Kind.Real);

		if (prim.type == ir.PrimitiveType.Kind.Float ||
			prim.type == ir.PrimitiveType.Kind.Double) {
			auto type = prim.type == ir.PrimitiveType.Kind.Double ?
				buildUlong(loc) : buildInt(loc);

			key = buildDeref(loc,
					buildCastSmart(loc, buildPtrSmart(loc, type), buildAddrOf(key))
			);
		}

		key = buildCastSmart(loc, buildUlong(loc), key);
	} else if (realType(aa.key).nodeType == ir.NodeType.Struct || realType(aa.key).nodeType == ir.NodeType.Class) {
		key = buildStructAAKeyCast(loc, lp, thisModule, current, key, aa);
	} else {
		key = buildCastSmart(loc, buildArrayTypeSmart(loc, buildVoid(loc)), key);
	}

	return key;
}

ir.Exp buildStructAAKeyCast(Location l, LanguagePass lp, ir.Module thisModule, ir.Scope current, ir.Exp key, ir.AAType aa)
{
	auto concatfn = getArrayAppendFunction(l, lp, thisModule, buildArrayType(l, buildUlong(l)), buildUlong(l), false);
	auto keysfn = retrieveFunctionFromObject(lp, l, "vrt_aa_get_keys");
	auto valuesfn = retrieveFunctionFromObject(lp, l, "vrt_aa_get_values");

	// ulong[] array;
	auto atype = buildArrayType(l, buildUlong(l));
	auto sexp = buildStatementExp(l);
	auto var = buildVariableSmart(l, copyTypeSmart(l, atype), ir.Variable.Storage.Function, "array");
	sexp.statements ~= var;

	ir.ExpReference eref(ir.Variable v)
	{
		return buildExpReference(v.location, v, v.name);
	}

	void addElement(ir.Exp e, ref ir.Node[] statements)
	{
		auto call = buildCall(l, concatfn, [eref(var), e], concatfn.name);
		statements ~= buildExpStat(l, buildAssign(l, eref(var), call));
	}

	void delegate(ir.Aggregate) aggdg;  // Filled in with gatherAggregate, as DMD won't look forward for inline functions.

	void gatherType(ir.Type t, ir.Exp e, ref ir.Node[] statements)
	{
		switch (t.nodeType) {
		case ir.NodeType.ArrayType:
			auto atype = cast(ir.ArrayType)t;
			ir.ForStatement forStatement;
			ir.Variable index;
			buildForStatement(l, lp, current, buildArrayLength(l, lp, e), forStatement, index);
			gatherType(realType(atype.base), buildIndex(l, e, eref(index)), forStatement.block.statements);
			sexp.statements ~= forStatement;
			break;
		case ir.NodeType.Struct:
		case ir.NodeType.Union:
			auto agg = cast(ir.Aggregate)t;
			aggdg(agg);
			break;
		case ir.NodeType.StorageType:
			auto stype = cast(ir.StorageType)t;
			gatherType(stype.base, e, statements);
			break;
		case ir.NodeType.PointerType:
		case ir.NodeType.PrimitiveType:
		case ir.NodeType.Class:
		case ir.NodeType.AAType:
			addElement(buildCastSmart(l, buildUlong(l), e), statements);
			break;
		default:
			throw panicUnhandled(t, format("aa aggregate key type '%s'", t.nodeType));
		}
	}

	void gatherAggregate(ir.Aggregate agg)
	{
		foreach (node; agg.members.nodes) {
			auto var = cast(ir.Variable) node;
			if (var is null) {
				continue;
			}
			if (var.name == "") {
				continue;
			}
			auto store = lookupInGivenScopeOnly(lp, agg.myScope, l, var.name);
			if (store is null) {
				continue;
			}
			auto rtype = realType(var.type);
			gatherType(rtype, buildAccess(l, copyExp(key), var.name), sexp.statements);
		}
	}

	version (Volt) {
		aggdg = cast(typeof(aggdg))gatherAggregate;
	} else {
		aggdg = &gatherAggregate;
	}

	gatherType(realType(aa.key), key, sexp.statements);

	// ubyte[] barray;
	auto oarray = buildArrayType(l, buildUbyte(l));
	auto outvar = buildVariableSmart(l, oarray, ir.Variable.Storage.Function, "barray");
	sexp.statements ~= outvar;

	// barray.ptr = cast(ubyte*) array.ptr;
	auto ptrcast = buildCastSmart(l, buildPtrSmart(l, buildUbyte(l)), buildArrayPtr(l, atype.base, eref(var)));
	auto ptrass = buildAssign(l, buildArrayPtr(l, oarray.base, eref(outvar)), ptrcast);
	buildExpStat(l, sexp, ptrass);

	// barray.length = exps.length * typeid(ulong).size;
	auto lenaccess = buildArrayLength(l, lp, eref(outvar));
	auto mul = buildBinOp(l, ir.BinOp.Op.Mul, buildArrayLength(l, lp, eref(var)), buildConstantSizeT(l, lp, 8));
	auto lenass = buildAssign(l, lenaccess, mul);
	buildExpStat(l, sexp, lenass);

	sexp.exp = eref(outvar);
	return buildCastSmart(l, buildArrayType(l, buildVoid(l)), sexp);
}

void handleProperty(LanguagePass lp, ref ir.Exp exp, ir.PropertyExp prop)
{
	assert (prop.getFn !is null);

	auto name = prop.identifier.value;
	auto expRef = buildExpReference(prop.location, prop.getFn, name);

	if (prop.child is null) {
		exp = buildCall(prop.location, expRef, []);
	} else {
		exp = buildMemberCall(prop.location,
		                      prop.child,
		                      expRef, name, []);
	}
}

/**
 * Lowers misc things needed by the LLVM backend.
 */
class LlvmLowerer : ScopeManager, Pass
{
public:
	LanguagePass lp;

	ir.Module thisModule;

	bool V_P64;

public:
	this(LanguagePass lp)
	{
		this.lp = lp;
		this.V_P64 = lp.ver.isP64;
	}

	override void transform(ir.Module m)
	{
		thisModule = m;
		accept(m, this);
	}

	override void close()
	{
	}

	override Status enter(ir.BlockStatement bs)
	{
		super.enter(bs);
		transformForeaches(lp, current, functionStack[$-1], bs);
		insertBinOpAssignsForNestedVariableAssigns(lp, bs);

		/* Hoist declarations out of blocks and place them at the top
		 * of the function, to avoid alloc()ing in a loop. Name
		 * collisions aren't an issue, as the generated assign
		  * statements are already tied to the correct variable.
		 */
		auto top = functionStack[$-1]._body;
		if (functionStack.length == 0 ||
		    top is bs) {
			return Continue;
		}

		ir.Node[] newTopVars;
		for (size_t i = 0; i < bs.statements.length; ++i) {
			auto var = cast(ir.Variable) bs.statements[i];
			if (var is null) {
				accept(bs.statements[i], this);
				continue;
			}

			auto l = bs.statements[i].location;

			if (!var.specialInitValue) {
				ir.Exp assign;
				if (var.assign !is null) {
					assign = var.assign;
					var.assign = null;

					acceptExp(assign, this);
				} else {
					assign = getDefaultInit(l, lp, var.type);
				}

				auto eref = buildExpReference(l, var, var.name);
				auto a = buildAssign(l, eref, assign);

				bs.statements[i] = buildExpStat(l, a);
			} else {
				bs.statements[i] = buildBlockStat(l, null, bs.myScope);
			}

			accept(var, this);
			newTopVars ~= var;
		}

		top.statements = newTopVars ~ top.statements;
		super.leave(bs);

		return ContinueParent;
	}

	override Status leave(ir.BlockStatement bs)
	{
		super.leave(bs);
		return Continue;
	}

	override Status leave(ir.ThrowStatement t)
	{
		auto fn = lp.ehThrowFunc;
		auto eRef = buildExpReference(t.location, fn, "vrt_eh_throw");
		t.exp = buildCall(t.location, eRef, [t.exp,
			buildConstantString(t.location, t.location.filename, false),
			buildConstantSizeT(t.location, lp, t.location.line)]);
		return Continue;
	}

	override Status enter(ref ir.Exp exp, ir.BinOp binOp)
	{
		switch(binOp.op) with(ir.BinOp.Op) {
		case AddAssign:
		case SubAssign:
		case MulAssign:
		case DivAssign:
		case ModAssign:
		case AndAssign:
		case OrAssign:
		case XorAssign:
		case CatAssign:
		case LSAssign:  // <<=
		case SRSAssign:  // >>=
		case RSAssign: // >>>=
		case PowAssign:
		case Assign:
			auto asPostfix = cast(ir.Postfix)binOp.left;
			if (asPostfix is null)
				return Continue;

			auto leftType = getExpType(lp, asPostfix.child, current);
			if (leftType !is null &&
			    leftType.nodeType == ir.NodeType.AAType &&
			    asPostfix.op == ir.Postfix.Op.Index) {
				acceptExp(asPostfix.child, this);
				acceptExp(asPostfix.arguments[0], this);
				acceptExp(binOp.right, this);

				if (binOp.op == ir.BinOp.Op.Assign) {
					return handleAssignAA(exp, binOp, asPostfix, cast(ir.AAType)leftType);
				} else {
					return handleOpAssignAA(exp, binOp, asPostfix, cast(ir.AAType)leftType);
				}
			}
			return Continue;
		default:
			return Continue;
		}
	}

	override Status leave(ref ir.Exp exp, ir.BinOp binOp)
	{
		/*
		 * We do this on the leave function so we know that
		 * any children has been lowered as well.
		 */
		switch(binOp.op) {
		case ir.BinOp.Op.Assign:
			return handleAssign(exp, binOp);
		case ir.BinOp.Op.Cat:
			return handleCat(exp, binOp);
		case ir.BinOp.Op.CatAssign:
			return handleCatAssign(exp, binOp);
		case ir.BinOp.Op.NotEqual:
		case ir.BinOp.Op.Equal:
			return handleEqual(exp, binOp);
		default:
			return Continue;
		}
	}

	override Status enter(ref ir.Exp exp, ir.BuiltinExp builtin)
	{
		auto l = exp.location;
		final switch (builtin.kind) with (ir.BuiltinExp.Kind) {
		case ArrayPtr:
		case ArrayLength:
			break;
		case ArrayDup:
			if (builtin.children.length != 3) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto sexp = buildStatementExp(l);
			auto type = builtin.type;
			auto asStatic = cast(ir.StaticArrayType)realType(type);
			ir.Exp value = builtin.children[0];
			value = buildSlice(l, value, []);
			auto valueVar = buildVariableAnonSmart(l, current, sexp, type, value);
			value = buildExpReference(l, valueVar, valueVar.name);

			auto startCast = buildCastSmart(l, buildSizeT(l, lp), builtin.children[1]);
			auto startVar = buildVariableAnonSmart(l, current, sexp, buildSizeT(l, lp), startCast);
			auto start = buildExpReference(l, startVar, startVar.name);
			auto endCast = buildCastSmart(l, buildSizeT(l, lp), builtin.children[2]);
			auto endVar = buildVariableAnonSmart(l, current, sexp, buildSizeT(l, lp), endCast);
			auto end = buildExpReference(l, endVar, endVar.name);


			auto length = buildSub(l, end, start);
			auto newExp = buildNewSmart(l, type, length);
			auto var = buildVariableAnonSmart(l, current, sexp, type, newExp);
			auto evar = buildExpReference(l, var, var.name);
			auto sliceL = buildSlice(l, evar, copyExp(start), copyExp(end));
			auto sliceR = buildSlice(l, value, copyExp(start), copyExp(end));

			sexp.exp = buildAssign(l, sliceL, sliceR);
			exp = sexp;
			break;
		case AALength:
			if (builtin.children.length != 1) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto rtfn = buildExpReference(exp.location, lp.aaGetLength, lp.aaGetLength.name);
			exp = buildCall(exp.location, rtfn, builtin.children);
			break;
		case AAKeys:
			if (builtin.children.length != 1) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto rtfn = buildExpReference(exp.location, lp.aaGetKeys, lp.aaGetKeys.name);
			exp = buildCastSmart(exp.location, builtin.type, buildCall(exp.location, rtfn, builtin.children));
			break;
		case AAValues:
			if (builtin.children.length != 1) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto rtfn = buildExpReference(exp.location, lp.aaGetValues, lp.aaGetValues.name);
			exp = buildCastSmart(exp.location, builtin.type, buildCall(exp.location, rtfn, builtin.children));
			break;
		case AARehash:
			if (builtin.children.length != 1) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto rtfn = buildExpReference(exp.location, lp.aaRehash, lp.aaRehash.name);
			exp = buildCall(exp.location, rtfn, builtin.children);
			break;
		case AAGet:
			if (builtin.children.length != 3) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto aa = cast(ir.AAType)realType(getExpType(lp, builtin.children[0], current));
			if (aa is null) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			bool keyIsArray = isArray(realType(aa.key));
			bool valIsArray = isArray(realType(aa.value));
			if (keyIsArray) {
				builtin.children[1] = buildCastSmart(l, buildArrayType(l, buildVoid(l)), builtin.children[1]);
			} else {
				builtin.children[1] = buildCastSmart(l, buildUlong(l), builtin.children[1]);
			}
			if (valIsArray) {
				builtin.children[2] = buildCastSmart(l, buildArrayType(l, buildVoid(l)), builtin.children[2]);
			} else {
				builtin.children[2] = buildCastSmart(l, buildUlong(l), builtin.children[2]);
			}
			ir.Exp rtfn;
			if (keyIsArray && valIsArray) {
				rtfn = buildExpReference(exp.location, lp.aaGetAA, lp.aaGetAA.name);
			} else if (!keyIsArray && valIsArray) {
				rtfn = buildExpReference(exp.location, lp.aaGetPA, lp.aaGetPA.name);
			} else if (keyIsArray && !valIsArray) {
				rtfn = buildExpReference(exp.location, lp.aaGetAP, lp.aaGetAP.name);
			} else {
				rtfn = buildExpReference(exp.location, lp.aaGetPP, lp.aaGetPP.name);
			}
			exp = buildCastSmart(exp.location, aa.value, buildCall(exp.location, rtfn, builtin.children));
			break;
		case AARemove:
			if (builtin.children.length != 2) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto aa = cast(ir.AAType)realType(getExpType(lp, builtin.children[0], current));
			if (aa is null) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			bool keyIsArray = isArray(realType(aa.key));
			ir.Exp rtfn;
			if (keyIsArray) {
				rtfn = buildExpReference(exp.location, lp.aaDeleteArray, lp.aaDeleteArray.name);
				builtin.children[1] = buildCastSmart(l, buildArrayType(l, buildVoid(l)), builtin.children[1]);
			} else {
				rtfn = buildExpReference(exp.location, lp.aaDeletePrimitive, lp.aaDeletePrimitive.name);
				builtin.children[1] = buildCastSmart(l, buildUlong(l), builtin.children[1]);
			}
			exp = buildCall(exp.location, rtfn, builtin.children);
			break;
		case AAIn:
			if (builtin.children.length != 2) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto aa = cast(ir.AAType)realType(getExpType(lp, builtin.children[0], current));
			if (aa is null) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			bool keyIsArray = isArray(realType(aa.key));
			ir.Exp rtfn;
			if (keyIsArray) {
				rtfn = buildExpReference(exp.location, lp.aaInArray, lp.aaInArray.name);
				builtin.children[1] = buildCast(l, buildArrayType(l, buildVoid(l)), copyExp(builtin.children[1]));
			} else {
				rtfn = buildExpReference(exp.location, lp.aaInPrimitive, lp.aaInPrimitive.name);
				builtin.children[1] = buildCast(l, buildUlong(l), copyExp(builtin.children[1]));
			}
			exp = buildCall(exp.location, rtfn, builtin.children);
			exp = buildCast(l, builtin.type, exp);
			break;
		case AADup:
			if (builtin.children.length != 1) {
				throw panic(exp.location, "malformed BuiltinExp.");
			}
			auto rtFn = buildExpReference(l, lp.aaDup, lp.aaDup.name);
			exp = buildCall(l, rtFn, builtin.children);
			exp = buildCastSmart(l, builtin.type, exp);
			break;
		case Classinfo:
			panicAssert(exp, builtin.children.length == 1);
			auto iface = cast(ir._Interface)realType(getExpType(lp, builtin.children[0], current));
			auto ti = buildPtrSmart(l, buildPtrSmart(l, buildArrayType(l, copyTypeSmart(l, lp.classInfoClass))));
			auto sexp = buildStatementExp(l);
			ir.Exp ptr = buildCastToVoidPtr(l, builtin.children[0]);
			if (iface !is null) {
				/* We need the class vtable. Each interface instance holds the
				 * amount it's set forward from the beginning of the class one,
				 * as the first entry in the interface layout table,
				 * so we just do `**cast(size_t**)cast(void*)iface` to get at it.
				 * Then we subtract that value from the pointer.
				 */
				auto offset = buildDeref(l, buildDeref(l, buildCastSmart(l, buildPtrSmart(l, buildPtrSmart(l, buildSizeT(l, lp))), copyExp(l, ptr))));
				ptr = buildSub(l, ptr, offset);
			}
			auto tinfos = buildDeref(l, buildDeref(l, buildCastSmart(l, ti, ptr)));
			auto tvar = buildVariableAnonSmart(l, current, sexp, buildArrayType(l, copyTypeSmart(l, lp.classInfoClass)), tinfos);
			ir.Exp tlen = buildArrayLength(l, lp, buildExpReference(l, tvar, tvar.name));
			tlen = buildSub(l, tlen, buildConstantSizeT(l, lp, 1));
			sexp.exp = buildIndex(l, buildExpReference(l, tvar, tvar.name), tlen);
			exp = buildCastSmart(l, lp.classInfoClass, sexp);
			break;
		case UFCS:
		case Invalid:
			panicAssert(exp, false);
		}
		return Continue;
	}

	override Status visit(ref ir.Exp exp, ir.TraitsExp traits)
	{
		replaceTraits(exp, traits, lp, thisModule, current);
		return Continue;
	}

	override Status leave(ref ir.Exp exp, ir.ArrayLiteral al)
	{
		transformArrayLiteralIfNeeded(lp, current, functionStack.length > 0, exp, al);
		return Continue;
	}

	override Status leave(ref ir.Exp exp, ir.AssocArray assocArray)
	{
		auto loc = exp.location;
		auto aa = cast(ir.AAType)getExpType(lp, exp, current);
		assert(aa !is null);

		auto statExp = buildStatementExp(loc);

		auto aaNewFn = retrieveFunctionFromObject(lp, loc, "vrt_aa_new");

		auto bs = cast(ir.BlockStatement)current.node;
		if (bs is null) {
			auto fn = cast(ir.Function)current.node;
			if (fn !is null) {
				bs = fn._body;
			}
		}
		panicAssert(exp, bs !is null);

		auto var = buildVariableAnonSmart(loc, bs, statExp,
			copyTypeSmart(loc, aa), buildCall(loc, aaNewFn, [
				cast(ir.Exp)buildTypeidSmart(loc, lp, aa.value),
				cast(ir.Exp)buildTypeidSmart(loc, lp, aa.key)
			], aaNewFn.name)
		);

		foreach (pair; assocArray.pairs) {
			auto key = buildVariableAnonSmart(loc, bs, statExp,
				copyTypeSmart(loc, aa.key), pair.key
			);

			auto value = buildVariableAnonSmart(loc, bs, statExp,
				copyTypeSmart(loc, aa.value), pair.value
			);

			buildAAInsert(loc, lp, thisModule, current, statExp,
				 aa, var, buildExpReference(loc, key), buildExpReference(loc, value), false, false
			);
		}

		statExp.exp = buildExpReference(loc, var);
		exp = statExp;

		return Continue;
	}

	override Status leave(ref ir.Exp exp, ir.Unary uexp)
	{
		replaceInterfaceCastIfNeeded(exp.location, lp, current, uexp, exp);
		if (functionStack.length > 0) {
			replaceArrayCastIfNeeded(exp.location, lp, current, uexp, exp);
		}

		return Continue;
	}

	override Status leave(ref ir.Exp exp, ir.Postfix postfix)
	{
		handleStructLookupViaFunctionCall(lp, current, exp, postfix);
		switch(postfix.op) {
		case ir.Postfix.Op.Index:
			return handleIndex(exp, postfix);
		default:
			break;
		}
		ir._Interface iface;
		if (isInterfacePointer(lp, postfix, current, iface)) {
			assert(iface !is null);
			auto cpostfix = cast(ir.Postfix) postfix.child;  // TODO: Calling returned interfaces directly.
			if (cpostfix is null || cpostfix.memberFunction is null) {
				throw makeExpected(exp.location, "interface");
			}
			auto fn = cast(ir.Function) cpostfix.memberFunction.decl;
			if (fn is null) {
				throw makeExpected(exp.location, "method");
			}
			auto l = exp.location;
			auto handle = buildCastToVoidPtr(l, buildSub(l, buildCastSmart(l, buildPtrSmart(l, buildUbyte(l)), copyExp(cpostfix.child)), buildAccess(l, buildDeref(l, copyExp(cpostfix.child)), "__offset")));
			exp = buildCall(l, buildAccess(l, buildDeref(l, copyExp(cpostfix.child)), mangle(null, fn)), handle ~ postfix.arguments);
		}
		return Continue;
	}

	override Status leave(ref ir.Exp exp, ir.PropertyExp prop)
	{
		handleProperty(lp, exp, prop);
		return Continue;
	}

	override Status enter(ref ir.Exp exp, ir.StructLiteral literal)
	{
		if (functionStack.length == 0) {
			// Global struct literals can use LLVM's native handling.
			return Continue;
		}

		/* Turn `Struct a = {1, "banana"};`
		 * into `Struct a; a.firstField = 1; b.secondField = "banana";`.
		 */

		// Pull out the struct and its fields.
		panicAssert(exp, literal.type !is null);
		auto theStruct = cast(ir.Struct) realType(literal.type);
		panicAssert(exp, theStruct !is null);
		auto fields = getStructFieldVars(theStruct);
		// The extyper should've caught this.
		panicAssert(exp, fields.length >= literal.exps.length);

		// Struct __anon;
		auto l = exp.location;
		auto sexp = buildStatementExp(l);
		auto var = buildVariableAnonSmart(l, current, sexp, theStruct, null);

		// Assign the literal expressions to the fields.
		foreach (i, e; literal.exps) {
			auto eref = buildExpReference(l, var, var.name);
			auto lh = buildAccess(l, eref, fields[i].name);
			auto assign = buildAssign(l, lh, e);
			buildExpStat(l, sexp, assign);
		}

		sexp.exp = buildExpReference(l, var, var.name);
		sexp.originalExp = exp;
		exp = sexp;
		return Continue;
	}

	override Status visit(ref ir.Exp exp, ir.ExpReference eref)
	{
		bool replaced = replaceNested(exp, eref, functionStack.length == 0 ? null : functionStack[$-1].nestedVariable);
		if (replaced) {
			return Continue;
		}

		auto fn = cast(ir.Function) eref.decl;
		if (fn is null) {
			return Continue;
		}
		if (functionStack.length == 0 || functionStack[$-1].nestedVariable is null) {
			return Continue;
		}
		bool isNested;
		foreach (pf; functionStack) {
			foreach (nf; pf.nestedFunctions) {
				if (fn is nf) {
					isNested = true;
				}
			}
			if (isNested) {
				break;
			}
		}
		if (!isNested) {
			return Continue;
		}
		auto np = functionStack[$-1].nestedVariable;
		exp = buildCreateDelegate(exp.location, buildExpReference(np.location, np, np.name), eref);

		return Continue;
	}

	protected override Status enter(ref ir.Exp exp, ir.StringImport simport)
	{
		if (lp.settings.stringImportPaths.length == 0) {
			throw makeNoStringImportPaths(exp.location);
		}

		auto constant = evaluateOrNull(lp, current, simport.filename);
		if (constant is null || !isString(constant.type) ||
		    constant._string.length < 3) {
			throw makeStringImportWrongConstant(exp.location);
		}

		auto fname = constant._string[1 .. $-1];  // Remove string literal terminators.
		foreach (path; lp.settings.stringImportPaths) {
			string str;
			try {
				str = cast(string)read(path ~ "/" ~ fname);
				exp = buildConstantString(exp.location, str, false);
				return Continue;
			} catch (Exception) {
			}
		}
		throw makeImportFileOpenFailure(exp.location, fname);
	}

	protected Status handleIndex(ref ir.Exp exp, ir.Postfix postfix)
	{
		auto type = getExpType(lp, postfix.child, current);
		switch (type.nodeType) with(ir.NodeType) {
			case AAType:
				return handleIndexAA(exp, postfix, cast(ir.AAType)type);
			default:
				return Continue;
		}
	}

	protected Status handleIndexAA(ref ir.Exp exp, ir.Postfix postfix, ir.AAType aa)
	{
		auto loc = postfix.location;
		auto statExp = buildStatementExp(loc);

		auto var = buildVariableAnonSmart(loc, cast(ir.BlockStatement)current.node, statExp,
			buildPtrSmart(loc, aa), buildAddrOf(loc, postfix.child)
		);

		auto key = buildVariableAnonSmart(loc, cast(ir.BlockStatement)current.node, statExp,
			copyTypeSmart(loc, aa.key), postfix.arguments[0]
		);
		auto store = buildVariableAnonSmart(loc, cast(ir.BlockStatement)current.node, statExp,
			copyTypeSmart(loc, aa.value), null
		);

		buildAALookup(loc, lp, thisModule, current, statExp, aa, var,
			buildExpReference(loc, key, key.name),
			buildExpReference(loc, store, store.name)
		);

		statExp.exp = buildExpReference(loc, store);

		exp = statExp;

		return Continue;
	}

	protected Status handleAssign(ref ir.Exp exp, ir.BinOp binOp)
	{
		auto asPostfix = cast(ir.Postfix)binOp.left;
		if (asPostfix is null)
			return Continue;

		auto leftType = getExpType(lp, asPostfix, current);
		if (leftType is null)
			return Continue;

		switch (leftType.nodeType) with(ir.NodeType) {
			case ArrayType:
				return handleAssignArray(exp, binOp, asPostfix, cast(ir.ArrayType)leftType);
			default:
				return Continue;
		}

	}

	protected Status handleAssignArray(ref ir.Exp exp, ir.BinOp binOp, ir.Postfix asPostfix, ir.ArrayType leftType)
	{
		auto loc = binOp.location;

		if (asPostfix.op != ir.Postfix.Op.Slice)
			return Continue;

		auto fn = getArrayCopyFunction(loc, lp, thisModule, leftType);
		exp = buildCall(loc, fn, [asPostfix, binOp.right], fn.name);

		return Continue;
	}

	protected Status handleAssignAA(ref ir.Exp exp, ir.BinOp binOp, ir.Postfix asPostfix, ir.AAType aa)
	{
		auto loc = binOp.location;
		assert(asPostfix.op == ir.Postfix.Op.Index);
		auto statExp = buildStatementExp(loc);

		auto bs = cast(ir.BlockStatement)current.node;
		if (bs is null) {
			auto fn = cast(ir.Function)current.node;
			if (fn !is null) {
				bs = fn._body;
			}
		}
		panicAssert(exp, bs !is null);

		auto var = buildVariableAnonSmart(loc, bs, statExp,
			buildPtrSmart(loc, aa), buildAddrOf(loc, asPostfix.child)
		);

		auto key = buildVariableAnonSmart(loc, bs, statExp,
			copyTypeSmart(loc, aa.key), asPostfix.arguments[0]
		);
		auto value = buildVariableAnonSmart(loc, bs, statExp,
			copyTypeSmart(loc, aa.value), binOp.right
		);

		buildAAInsert(loc, lp, thisModule, current, statExp, aa, var,
				buildExpReference(loc, key, key.name),
				buildExpReference(loc, value, value.name)
		);

		statExp.exp = buildExpReference(loc, value, value.name);
		exp = statExp;

		return ContinueParent;
	}

	protected Status handleOpAssignAA(ref ir.Exp exp, ir.BinOp binOp, ir.Postfix asPostfix, ir.AAType aa)
	{
		auto loc = binOp.location;
		assert(asPostfix.op == ir.Postfix.Op.Index);
		auto statExp = buildStatementExp(loc);

		auto var = buildVariableAnonSmart(loc, cast(ir.BlockStatement)current.node, statExp,
			buildPtrSmart(loc, aa), null
		);
		buildExpStat(loc, statExp,
			buildAssign(loc, buildExpReference(loc, var, var.name), buildAddrOf(loc, asPostfix.child))
		);

		auto key = buildVariableAnonSmart(loc, cast(ir.BlockStatement)current.node, statExp,
			copyTypeSmart(loc, aa.key), null
		);
		buildExpStat(loc, statExp,
			buildAssign(loc, buildExpReference(loc, key, key.name), asPostfix.arguments[0])
		);
		auto store = buildVariableAnonSmart(loc, cast(ir.BlockStatement)current.node, statExp,
			copyTypeSmart(loc, aa.value), null
		);

		buildAALookup(loc, lp, thisModule, current, statExp, aa, var,
			buildExpReference(loc, key, key.name),
			buildExpReference(loc, store, store.name)
		);

		buildExpStat(loc, statExp,
			buildBinOp(loc, binOp.op,
				buildExpReference(loc, store, store.name),
			 	binOp.right
			)
		);

		buildAAInsert(loc, lp, thisModule, current, statExp, aa, var,
			buildExpReference(loc, key, key.name),
			buildExpReference(loc, store, store.name),
			false
		);

		statExp.exp = buildExpReference(loc, store, store.name);
		exp = statExp;

		return ContinueParent;
	}

	protected Status handleCat(ref ir.Exp exp, ir.BinOp binOp)
	{
		auto loc = binOp.location;

		auto leftType = getExpType(lp, binOp.left, current);
		auto rightType = getExpType(lp, binOp.right, current);

		auto arrayType = cast(ir.ArrayType)leftType;
		auto elementType = rightType;
		bool reversed = false;
		if (arrayType is null) {
			reversed = true;
			arrayType = cast(ir.ArrayType) rightType;
			elementType = leftType;
			if (arrayType is null) {
				throw panic(exp.location, "array concat failure");
			}
		}

		if (typesEqual(elementType, arrayType.base)) {
			// T[] ~ T
			ir.Function fn;
			if (reversed) {
				fn = getArrayPrependFunction(loc, lp, thisModule, arrayType, elementType);
			} else {
				fn = getArrayAppendFunction(loc, lp, thisModule, arrayType, elementType, false);
			}
			exp = buildCall(loc, fn, [binOp.left, binOp.right], fn.name);
		} else {
			// T[] ~ T[]
			auto fn = getArrayConcatFunction(loc, lp, thisModule, arrayType, false);
			exp = buildCall(loc, fn, [binOp.left, binOp.right], fn.name);
		}

		return Continue;
	}

	protected Status handleCatAssign(ref ir.Exp exp, ir.BinOp binOp)
	{
		auto loc = binOp.location;

		auto leftType = getExpType(lp, binOp.left, current);
		auto leftArrayType = cast(ir.ArrayType)realType(leftType);
		if (leftArrayType is null)
			throw panic(binOp, "couldn't retrieve array type from cat assign.");

		// Currently realType is not needed here, but if it ever was
		// needed remember to realType leftArrayType.base as well,
		// since realType will remove enum's as well.
		auto rightType = getExpType(lp, binOp.right, current);

		if (typesEqual(rightType, leftArrayType.base)) {
			// T[] ~ T
			auto fn = getArrayAppendFunction(loc, lp, thisModule, leftArrayType, rightType, true);
			exp = buildCall(loc, fn, [buildAddrOf(binOp.left), binOp.right], fn.name);
		} else {
			auto fn = getArrayConcatFunction(loc, lp, thisModule, leftArrayType, true);
			exp = buildCall(loc, fn, [buildAddrOf(binOp.left), binOp.right], fn.name);
		}

		return Continue;
	}

	protected Status handleEqual(ref ir.Exp exp, ir.BinOp binOp)
	{
		auto loc = binOp.location;

		auto leftType = getExpType(lp, binOp.left, current);
		auto leftArrayType = cast(ir.ArrayType)leftType;
		if (leftArrayType is null)
			return Continue;

		auto fn = getArrayCmpFunction(loc, lp, thisModule, leftArrayType, binOp.op == ir.BinOp.Op.NotEqual);
		exp = buildCall(loc, fn, [binOp.left, binOp.right], fn.name);

		return Continue;
	}

	protected void replaceInterfaceCastIfNeeded(Location loc, LanguagePass lp, ir.Scope current, ir.Unary uexp, ref ir.Exp exp)
	{
		if (uexp.op != ir.Unary.Op.Cast) {
			return;
		}
		auto iface = cast(ir._Interface) realType(uexp.type);
		if (iface is null) {
			return;
		}
		auto agg = cast(ir.Aggregate) realType(getExpType(lp, uexp.value, current));
		if (agg is null) {
			return;
		}
		exp = buildAddrOf(loc, buildAccess(loc, uexp.value, mangle(iface)));
	}

	protected void replaceArrayCastIfNeeded(Location loc, LanguagePass lp, ir.Scope current, ir.Unary uexp, ref ir.Exp exp)
	{
		if (uexp.op != ir.Unary.Op.Cast) {
			return;
		}

		auto toArray = cast(ir.ArrayType) realType(uexp.type);
		if (toArray is null) {
			return;
		}
		auto fromArray = cast(ir.ArrayType) getExpType(lp, uexp.value, current);
		if (fromArray is null) {
			auto stype = cast(ir.StaticArrayType) getExpType(lp, uexp.value, current);
			if (stype !is null) {
				uexp.value = buildSlice(exp.location, uexp.value, []);
				fromArray = cast(ir.ArrayType)getExpType(lp, uexp.value, current);
				panicAssert(exp, fromArray !is null);
			} else {
				return;
			}
		}
		if (typesEqual(toArray, fromArray)) {
			return;
		}

		auto toClass = cast(ir.Class) realType(toArray.base);
		auto fromClass = cast(ir.Class) realType(fromArray.base);
		if (toClass !is null && fromClass !is null && isOrInheritsFrom(fromClass, toClass)) {
			return;
		}

		auto fromSz = size(lp, fromArray.base);
		auto toSz = size(lp, toArray.base);
		auto biggestSz = fromSz > toSz ? fromSz : toSz;
		bool decreasing = fromSz > toSz;

		// ({
		auto sexp = new ir.StatementExp();
		sexp.location = loc;

		// auto arr = <exp>
		auto varName = "arr";
		auto var = buildVariableSmart(loc, copyTypeSmart(loc, fromArray), ir.Variable.Storage.Function, varName);
		var.assign = uexp.value;
		sexp.statements ~= var;

		if (fromSz % toSz) {
			//     vrt_throw_slice_error(arr.length, typeid(T).size);
			auto ln = buildArrayLength(loc, lp, buildExpReference(loc, var, varName));
			auto sz = buildAccess(loc, buildTypeidSmart(loc, lp, toArray.base), "size");
			ir.Exp fname = buildConstantString(loc, exp.location.filename, false);
			ir.Exp lineNum = buildConstantSizeT(loc, lp, exp.location.line);
			auto rtCall = buildCall(loc, buildExpReference(loc, lp.ehThrowSliceErrorFunc, lp.ehThrowSliceErrorFunc.name), [fname, lineNum]);
			auto bs = buildBlockStat(loc, rtCall, current, buildExpStat(loc, rtCall));
			auto check = buildBinOp(loc, ir.BinOp.Op.NotEqual, buildBinOp(loc, ir.BinOp.Op.Mod, ln, sz), buildConstantSizeT(loc, lp, 0));
			auto _if = buildIfStat(loc, check, bs);
			sexp.statements ~= _if;
		}

		auto inLength = buildArrayLength(loc, lp, buildExpReference(loc, var, varName));
		ir.Exp lengthTweak;
		if (fromSz == toSz) {
			lengthTweak = inLength;
		} else if (!decreasing) {
			lengthTweak = buildBinOp(loc, ir.BinOp.Op.Div, inLength, buildConstantSizeT(loc, lp, biggestSz));
		} else {
			lengthTweak = buildBinOp(loc, ir.BinOp.Op.Mul, inLength, buildConstantSizeT(loc, lp, biggestSz));
		}

		auto ptrType = buildPtrSmart(loc, toArray.base);
		auto ptrIn = buildArrayPtr(loc, fromArray.base, buildExpReference(loc, var, varName));
		auto ptrOut = buildCast(loc, ptrType, ptrIn);
		sexp.exp = buildSlice(loc, ptrOut, buildConstantSizeT(loc, lp, 0), lengthTweak);
		exp = sexp;
	}
}

bool isInterfacePointer(LanguagePass lp, ir.Postfix pfix, ir.Scope current, out ir._Interface iface)
{
	pfix = cast(ir.Postfix) pfix.child;
	if (pfix is null) {
		return false;
	}
	auto t = getExpType(lp, pfix.child, current);
	iface = cast(ir._Interface) realType(t);
	if (iface !is null) {
		return true;
	}
	auto ptr = cast(ir.PointerType) realType(t);
	if (ptr is null) {
		return false;
	}
	ptr = cast(ir.PointerType) realType(ptr.base);
	if (ptr is null) {
		return false;
	}
	auto _struct = cast(ir.Struct) realType(ptr.base);
	if (_struct is null) {
		return false;
	}
	iface = cast(ir._Interface) _struct.loweredNode;
	return iface !is null;
}

/**
 * If a postfix operates directly on a struct via a
 * function call, put it in a variable first.
 */
void handleStructLookupViaFunctionCall(LanguagePass lp, ir.Scope current, ref ir.Exp exp, ir.Postfix postfix)
{
	// This lists the cases where we need to rewrite (reversed).
	if (postfix.op != ir.Postfix.Op.Identifier) {
		return;
	}

	auto child = cast(ir.Postfix) postfix.child;
	if (child is null || child.op != ir.Postfix.Op.Call) {
		return;
	}

	auto type = realType(getExpType(lp, postfix.child, current));
	if (type.nodeType != ir.NodeType.Union &&
	    type.nodeType != ir.NodeType.Struct) {
		return;
	}

	auto loc = postfix.location;
	auto statExp = buildStatementExp(loc);
	auto host = getParentFunction(current);
	auto var = buildVariableAnonSmart(loc, host._body, statExp, type,
	                                  postfix.child);
	postfix.child = buildExpReference(loc, var, var.name);
	statExp.exp = exp;
	exp = statExp;
}

/**
 * Rewrites a given foreach statement (fes) into a for statement.
 * The ForStatement create takes several nodes directly; that is
 * to say, the original foreach and the new for cannot coexist.
 */
ir.ForStatement foreachToFor(ir.ForeachStatement fes, LanguagePass lp,
                             ir.Scope current)
{
	auto l = fes.location;
	auto fs = new ir.ForStatement();
	fs.location = l;
	panicAssert(fes, fes.itervars.length == 1 || fes.itervars.length == 2);
	fs.initVars = fes.itervars;
	fs.block = fes.block;

	// foreach (i; 5 .. 7) => for (int i = 5; i < 7; i++)
	// foreach_reverse (i; 5 .. 7) => for (int i = 7 - 1; i >= 5; i--)
	if (fes.beginIntegerRange !is null) {
		panicAssert(fes, fes.endIntegerRange !is null);
		panicAssert(fes, fes.itervars.length == 1);
		auto v = fs.initVars[0];
		auto begin = realType(getExpType(lp, fes.beginIntegerRange, current));
		auto end = realType(getExpType(lp, fes.endIntegerRange, current));
		if (!isIntegral(begin) || !isIntegral(end)) {
			throw makeExpected(fes.beginIntegerRange.location, "integral beginning and end of range");
		}
		panicAssert(fes, typesEqual(begin, end));
		if (v.type !is null) {
			v.type = lp.resolve(current, v.type);
		}
		if (v.type is null) {
			v.type = copyType(begin);
		}
		v.assign = fes.reverse ?
			buildSub(l, fes.endIntegerRange, buildConstantInt(l, 1)) :
			fes.beginIntegerRange;

		auto cmpRef = buildExpReference(v.location, v, v.name);
		auto incRef = buildExpReference(v.location, v, v.name);
		fs.test = buildBinOp(l,
							 fes.reverse ? ir.BinOp.Op.GreaterEqual : ir.BinOp.Op.Less,
							 cmpRef, buildCastSmart(l, begin, fes.reverse ? fes.beginIntegerRange : fes.endIntegerRange));
		fs.increments ~= fes.reverse ? buildDecrement(v.location, incRef) :
						 buildIncrement(v.location, incRef);
		return fs;
	}


	// foreach (e; a) => foreach (e; auto _anon = a) 
	auto sexp = buildStatementExp(l);

	// foreach (i, e; array) => for (size_t i = 0; i < array.length; i++) auto e = array[i]; ...
	// foreach_reverse (i, e; array) => for (size_t i = array.length - 1; i+1 >= 0; i--) auto e = array[i]; ..
	auto aggType = realType(getExpType(lp, fes.aggregate, current));

	if (aggType.nodeType == ir.NodeType.ArrayType || aggType.nodeType == ir.NodeType.StaticArrayType) {
		aggType = realType(getExpType(lp, buildSlice(l, fes.aggregate, []), current));
		auto anonVar = buildVariableAnonSmart(l, current, sexp, aggType, buildSlice(l, fes.aggregate, []));
		anonVar.type.mangledName = mangle(aggType);
		scope (exit) fs.initVars = anonVar ~ fs.initVars;
		ir.ExpReference aggref() { return buildExpReference(l, anonVar, anonVar.name); }
		fes.aggregate = aggref();

		// i = 0 / i = array.length
		ir.Variable indexVar, elementVar;
		ir.Exp indexAssign;
		if (!fes.reverse) {
			indexAssign = buildConstantSizeT(l, lp, 0);
		} else {
			indexAssign = buildArrayLength(l, lp, aggref());
		}
		if (fs.initVars.length == 2) {
			indexVar = fs.initVars[0];
			if (indexVar.type is null) {
				indexVar.type = buildSizeT(l, lp);
			}
			indexVar.assign = copyExp(indexAssign);
			elementVar = fs.initVars[1];
		} else {
			panicAssert(fes, fs.initVars.length == 1);
			indexVar = buildVariable(l, buildSizeT(l, lp),
			                         ir.Variable.Storage.Function, "i", indexAssign);
			elementVar = fs.initVars[0];
		}

		// Move element var to statements so it can be const/immutable.
		fs.initVars = [indexVar];
		fs.block.statements = [cast(ir.Node)elementVar] ~ fs.block.statements;

		ir.Variable nextIndexVar;  // This is what we pass when decoding strings.
		if (fes.decodeFunction !is null && !fes.reverse) {
			auto ivar = buildExpReference(indexVar.location, indexVar, indexVar.name);
			nextIndexVar = buildVariable(l, buildSizeT(l, lp),
			                             ir.Variable.Storage.Function, "__nexti", ivar);
			fs.initVars ~= nextIndexVar;
		}



		// i < array.length / i + 1 >= 0
		auto tref = buildExpReference(indexVar.location, indexVar, indexVar.name);
		auto rtref = buildDecrement(l, tref);
		auto length = buildArrayLength(l, lp, fes.aggregate);
		auto zero = buildConstantSizeT(l, lp, 0);
		fs.test = buildBinOp(l, fes.reverse ? ir.BinOp.Op.Greater : ir.BinOp.Op.Less,
							 fes.reverse ? rtref : tref,
							 fes.reverse ? zero : length);

		// auto e = array[i]; i++/i--
		auto incRef = buildExpReference(indexVar.location, indexVar, indexVar.name);
		auto accessRef = buildExpReference(indexVar.location, indexVar, indexVar.name);
		auto eRef = buildExpReference(elementVar.location, elementVar, elementVar.name);
		if (fes.decodeFunction !is null) {  // foreach (i, dchar c; str)
			auto dfn = buildExpReference(l, fes.decodeFunction, fes.decodeFunction.name);
			if (!fes.reverse) {
				elementVar.assign = buildCall(l, dfn, [cast(ir.Exp)aggref(), cast(ir.Exp)buildExpReference(l, nextIndexVar, nextIndexVar.name)]);
				auto lvar = buildExpReference(indexVar.location, indexVar, indexVar.name);
				auto rvar = buildExpReference(nextIndexVar.location, nextIndexVar, nextIndexVar.name);
				fs.increments ~= buildAssign(l, lvar, rvar);
			} else {
				elementVar.assign = buildCall(l, dfn, [cast(ir.Exp)aggref(),
				                              cast(ir.Exp)buildExpReference(indexVar.location, indexVar, indexVar.name)]);
			}
		} else {
			elementVar.assign = buildIndex(incRef.location, aggref(), accessRef);
			if (!fes.reverse) {
				fs.increments ~= buildIncrement(incRef.location, incRef);
			}
		}



		foreach (i, ivar; fes.itervars) {
			if (!fes.refvars[i]) {
				continue;
			}
			if (i == 0 && fes.itervars.length > 1) {
				throw makeForeachIndexRef(fes.location);
			}
			auto nr = new ExpReferenceReplacer(ivar, elementVar.assign);
			accept(fs.block, nr);
		}

		return fs;
	}

	// foreach (k, v; aa) => for (size_t i; i < aa.keys.length; i++) k = aa.keys[i]; v = aa[k];
	// foreach_reverse => error, as order is undefined.
	auto aaanonVar = buildVariableAnonSmart(l, current, sexp, aggType, fes.aggregate);
	aaanonVar.type.mangledName = mangle(aggType);
	scope (exit) fs.initVars = aaanonVar ~ fs.initVars;
	ir.ExpReference aaaggref() { return buildExpReference(l, aaanonVar, aaanonVar.name); }
	fes.aggregate = aaaggref();
	auto aa = cast(ir.AAType) aggType;
	if (aa !is null) {
		ir.Exp buildAACall(ir.Function fn, ir.Type outType)
		{
			auto eref = buildExpReference(l, fn, fn.name);
			return buildCastSmart(l, outType, buildCall(l, eref, [cast(ir.Exp)buildCastToVoidPtr(l, aaaggref())]));
		}

		if (fes.reverse) {
			throw makeForeachReverseOverAA(fes);
		}
		if (fs.initVars.length != 1 && fs.initVars.length != 2) {
			throw makeExpected(fes.location, "1 or 2 iteration variables");
		}

		auto valVar = fs.initVars[0];
		ir.Variable keyVar;
		if (fs.initVars.length == 2) {
			keyVar = valVar;
			valVar = fs.initVars[1];
		} else {
			keyVar = buildVariable(l, null, ir.Variable.Storage.Function, format("%sk", fs.block.myScope.nestedDepth));
			fs.initVars ~= keyVar;
		}

		auto vstor = cast(ir.StorageType) valVar.type;
		if (vstor !is null && vstor.type == ir.StorageType.Kind.Auto) {
			valVar.type = null;
		}

		auto kstor = cast(ir.StorageType) keyVar.type;
		if (kstor !is null && kstor.type == ir.StorageType.Kind.Auto) {
			keyVar.type = null;
		}

		if (valVar.type is null) {
			valVar.type = copyTypeSmart(l, aa.value);
		}
		if (keyVar.type is null) {
			keyVar.type = copyTypeSmart(l, aa.key);
		}
		auto indexVar = buildVariable(
			l,
			buildSizeT(l, lp),
			ir.Variable.Storage.Function,
			format("%si", fs.block.myScope.nestedDepth),
			buildConstantSizeT(l, lp, 0)
		);
		assert(keyVar.type !is null);
		assert(valVar.type !is null);
		assert(indexVar.type !is null);
		fs.initVars ~= indexVar;

		// i < aa.keys.length
		auto index = buildExpReference(l, indexVar, indexVar.name);
		auto len = buildAACall(lp.aaGetLength, indexVar.type);
		fs.test = buildBinOp(l, ir.BinOp.Op.Less, index, len);

		// k = aa.keys[i]
		auto kref = buildExpReference(l, keyVar, keyVar.name);
		auto keys = buildAACall(lp.aaGetKeys, buildArrayTypeSmart(l, keyVar.type));
		auto rh   = buildIndex(l, keys, buildExpReference(l, indexVar, indexVar.name));
		fs.block.statements = buildExpStat(l, buildAssign(l, kref, rh)) ~ fs.block.statements;

		// v = aa.exps[i]
		auto vref = buildExpReference(l, valVar, valVar.name);
		auto vals = buildAACall(lp.aaGetValues, buildArrayTypeSmart(l, valVar.type));
		auto rh2  = buildIndex(l, vals, buildExpReference(l, indexVar, indexVar.name));
		fs.block.statements = buildExpStat(l, buildAssign(l, vref, rh2)) ~ fs.block.statements;

		// i++
		fs.increments ~= buildIncrement(l, buildExpReference(l, indexVar, indexVar.name));

		return fs;
	}

	throw panic(l, "expected foreach aggregate type");
}

void transformForeaches(LanguagePass lp, ir.Scope current,
                        ir.Function currentFunction, ir.BlockStatement bs)
{
	for (size_t i = 0; i < bs.statements.length; i++) {
		auto fes = cast(ir.ForeachStatement) bs.statements[i];
		if (fes is null) {
			continue;
		}
		bs.statements[i] = foreachToFor(fes, lp, current);
	}
}

void transformArrayLiteralIfNeeded(LanguagePass lp, ir.Scope current, bool inFunction, ref ir.Exp exp,
                                   ir.ArrayLiteral al)
{
	if (al.exps.length == 0 || !inFunction) {
		return;
	}
	auto at = getExpType(lp, al, current);
	if (at.nodeType == ir.NodeType.StaticArrayType) {
		return;
	}
	auto sexp = buildInternalArrayLiteralSmart(al.location, at, al.exps);
	sexp.originalExp = al;
	exp = sexp;
}

