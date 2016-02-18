// Copyright © 2013-2015, Jakob Bornecrantz.  All rights reserved.
// Copyright © 2013-2015, David Herberth.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.lowerer.array;

import watt.text.format : format;

import ir = volt.ir.ir;
import volt.ir.copy;
import volt.ir.util;

import volt.interfaces;
import volt.token.location;

import volt.semantic.util;
import volt.semantic.mangle;
import volt.semantic.lookup;
import volt.semantic.classify;


/*
 *
 * Common helpers.
 *
 */

ir.Function getLlvmMemMove(Location loc, LanguagePass lp)
{
	auto name32 = "__llvm_memmove_p0i8_p0i8_i32";
	auto name64 = "__llvm_memmove_p0i8_p0i8_i64";
	auto name = lp.ver.isP64 ? name64 : name32;
	return retrieveFunctionFromObject(lp, loc, name);
}

ir.Function getLlvmMemCopy(Location loc, LanguagePass lp)
{
	auto name32 = "__llvm_memcpy_p0i8_p0i8_i32";
	auto name64 = "__llvm_memcpy_p0i8_p0i8_i64";
	auto name = lp.ver.isP64 ? name64 : name32;
	return retrieveFunctionFromObject(lp, loc, name);
}


/*
 *
 * Array function getters.
 *
 */

ir.Function getArrayAppendFunction(Location loc, LanguagePass lp, ir.Module thisModule, ir.ArrayType ltype, ir.Type rtype, bool isAssignment)
{
	if (ltype.mangledName is null) {
		ltype.mangledName = mangle(ltype);
	}
	if (rtype.mangledName is null) {
		rtype.mangledName = mangle(rtype);
	}

	string name;
	if (isAssignment) {
		name = "__appendArrayAssign" ~ ltype.mangledName ~ rtype.mangledName;
	} else {
		name = "__appendArray" ~ ltype.mangledName ~ rtype.mangledName;
	}

	auto fn = lookupFunction(lp, thisModule.myScope, loc, name);
	if (fn !is null) {
		return fn;
	}

	fn = buildFunction(loc, thisModule.children, thisModule.myScope, name);
	fn.type.ret = copyTypeSmart(loc, ltype);

	ir.FunctionParam left, right;
	if (isAssignment) {
		left = addParam(loc, fn, buildPtrSmart(loc, ltype), "left");
	} else {
		left = addParamSmart(loc, fn, ltype, "left");
	}
	right = addParamSmart(loc, fn, rtype, "right");

	auto fnAlloc = lp.allocDgVariable;
	auto allocExpRef = buildExpReference(loc, fnAlloc, fnAlloc.name);

	auto fnCopy = getLlvmMemCopy(loc, lp);

	ir.Exp[] args;

	auto allocated = buildVarStatSmart(loc, fn._body, fn._body.myScope, buildVoidPtr(loc), "allocated");
	auto count = buildVarStatSmart(loc, fn._body, fn._body.myScope, buildSizeT(loc, lp), "count");
	ir.Exp leftlength()
	{
		if (isAssignment) {
			return buildArrayLength(loc, lp, buildDeref(loc, buildExpReference(loc, left, left.name)));
		} else {
			return buildArrayLength(loc, lp, buildExpReference(loc, left, left.name));
		}
	}

	buildExpStat(loc, fn._body,
		buildAssign(loc,
			buildExpReference(loc, count, count.name),
			buildAdd(loc,
				leftlength(),
				buildConstantSizeT(loc, lp, 1)
			)
		)
	);

	args = [
		cast(ir.Exp)
		buildTypeidSmart(loc, ltype.base),
		buildExpReference(loc, count, count.name)
	];

	buildExpStat(loc, fn._body,
		buildAssign(loc,
			buildExpReference(loc, allocated, allocated.name),
			buildCall(loc, allocExpRef, args)
		)
	);

	ir.Exp leftPtr;
	if (isAssignment) {
		leftPtr = buildArrayPtr(loc, left.type, buildDeref(loc, buildExpReference(loc, left, left.name)));
	} else {
		leftPtr = buildArrayPtr(loc, left.type, buildExpReference(loc, left, left.name));
	}

	args = [
		cast(ir.Exp)
		buildExpReference(loc, allocated, allocated.name),
		buildCastToVoidPtr(loc, leftPtr),
		buildBinOp(loc, ir.BinOp.Op.Mul,
			leftlength(),
			buildConstantSizeT(loc, lp, size(lp, ltype.base))
		),
		buildConstantInt(loc, 0),
		buildConstantFalse(loc)
	];
	buildExpStat(loc, fn._body, buildCall(loc, buildExpReference(loc, fnCopy, fnCopy.name), args));

	buildExpStat(loc, fn._body,
		buildAssign(loc,
			buildDeref(loc,
				buildAdd(loc,
					buildCastSmart(loc, buildPtrSmart(loc, ltype.base), buildExpReference(loc, allocated, allocated.name)),
					leftlength()
				)
			),
			buildExpReference(loc, right, right.name)
		)
	);

	if (isAssignment) {
		buildExpStat(loc, fn._body,
			buildAssign(loc,
				buildDeref(loc, buildExpReference(loc, left, left.name)),
				buildSlice(loc,
					buildCastSmart(loc, buildPtrSmart(loc, ltype.base), buildExpReference(loc, allocated, allocated.name)),
					[cast(ir.Exp)buildConstantSizeT(loc, lp, 0), buildExpReference(loc, count, count.name)]
				)
			)
		);
		buildReturnStat(loc, fn._body, buildDeref(loc, buildExpReference(loc, left, left.name)));
	} else {
		buildReturnStat(loc, fn._body,
			buildSlice(loc,
				buildCastSmart(loc, buildPtrSmart(loc, ltype.base), buildExpReference(loc, allocated, allocated.name)),
				[cast(ir.Exp)buildConstantSizeT(loc, lp, 0), buildExpReference(loc, count, count.name)]
			)
		);
	}

	return fn;
}

ir.Function getArrayPrependFunction(Location loc, LanguagePass lp, ir.Module thisModule, ir.ArrayType ltype, ir.Type rtype)
{
	if (ltype.mangledName is null) {
		ltype.mangledName = mangle(ltype);
	}
	if (rtype.mangledName is null) {
		rtype.mangledName = mangle(rtype);
	}

	string name = "__prependArray" ~ ltype.mangledName ~ rtype.mangledName;

	auto fn = lookupFunction(lp, thisModule.myScope, loc, name);
	if (fn !is null) {
		return fn;
	}

	fn = buildFunction(loc, thisModule.children, thisModule.myScope, name);
	fn.mangledName = fn.name;
	fn.isWeakLink = true;
	fn.type.ret = copyTypeSmart(loc, ltype);

	ir.FunctionParam left, right;
	right = addParamSmart(loc, fn, rtype, "left");
	left = addParamSmart(loc, fn, ltype, "right");

	auto fnAlloc = lp.allocDgVariable;
	auto allocExpRef = buildExpReference(loc, fnAlloc, fnAlloc.name);

	auto fnCopy = getLlvmMemCopy(loc, lp);

	ir.Exp[] args;

	auto allocated = buildVarStatSmart(loc, fn._body, fn._body.myScope, buildVoidPtr(loc), "allocated");
	auto count = buildVarStatSmart(loc, fn._body, fn._body.myScope, buildSizeT(loc, lp), "count");

	buildExpStat(loc, fn._body,
		buildAssign(loc,
			buildExpReference(loc, count, count.name),
			buildAdd(loc,
				buildArrayLength(loc, lp, buildExpReference(loc, left, left.name)),
				buildConstantSizeT(loc, lp, 1)
			)
		)
	);

	args = [
		cast(ir.Exp)
		buildTypeidSmart(loc, ltype.base),
		buildExpReference(loc, count, count.name)
	];

	buildExpStat(loc, fn._body,
		buildAssign(loc,
			buildExpReference(loc, allocated, allocated.name),
			buildCall(loc, allocExpRef, args)
		)
	);

	args = [
		cast(ir.Exp)
		buildAdd(loc, buildExpReference(loc, allocated, allocated.name), buildConstantSizeT(loc, lp, size(lp, ltype.base))),
		buildCastToVoidPtr(loc, buildArrayPtr(loc, left.type, buildExpReference(loc, left, left.name))),
		buildBinOp(loc, ir.BinOp.Op.Mul,
			buildArrayLength(loc, lp, buildExpReference(loc, left, left.name)),
			buildConstantSizeT(loc, lp, size(lp, ltype.base))
		),
		buildConstantInt(loc, 0),
		buildConstantFalse(loc)
	];
	buildExpStat(loc, fn._body, buildCall(loc, buildExpReference(loc, fnCopy, fnCopy.name), args));

	buildExpStat(loc, fn._body,
		buildAssign(loc,
			buildDeref(loc,
					buildCastSmart(loc, buildPtrSmart(loc, ltype.base), buildExpReference(loc, allocated, allocated.name)),
			),
			buildExpReference(loc, right, right.name)
		)
	);

	buildReturnStat(loc, fn._body,
		buildSlice(loc,
			buildCastSmart(loc, buildPtrSmart(loc, ltype.base), buildExpReference(loc, allocated, allocated.name)),
			[cast(ir.Exp)buildConstantSizeT(loc, lp, 0), buildExpReference(loc, count, count.name)]
		)
	);

	return fn;
}

ir.Function getArrayCopyFunction(Location loc, LanguagePass lp, ir.Module thisModule, ir.ArrayType type)
{
	if (type.mangledName is null) {
		type.mangledName = mangle(type);
	}

	auto name = "__copyArray" ~ type.mangledName;
	auto fn = lookupFunction(lp, thisModule.myScope, loc, name);
	if (fn !is null) {
		return fn;
	}

	fn = buildFunction(loc, thisModule.children, thisModule.myScope, name);
	fn.mangledName = fn.name;
	fn.isWeakLink = true;
	fn.type.ret = copyTypeSmart(loc, type);
	auto left = addParamSmart(loc, fn, type, "left");
	auto right = addParamSmart(loc, fn, type, "right");

	auto fnMove = getLlvmMemMove(loc, lp);
	auto expRef = buildExpReference(loc, fnMove, fnMove.name);

	auto typeSize = size(lp, type.base);

	ir.Exp[] args = [
		cast(ir.Exp)
		buildCastToVoidPtr(loc, buildArrayPtr(loc, left.type, buildExpReference(loc, left, "left"))),
		buildCastToVoidPtr(loc, buildArrayPtr(loc, right.type, buildExpReference(loc, right, "right"))),
		buildBinOp(loc, ir.BinOp.Op.Mul,
			buildArrayLength(loc, lp, buildExpReference(loc, left, "left")),
			buildConstantSizeT(loc, lp, size(lp, type.base))
			),
		buildConstantInt(loc, 0),
		buildConstantFalse(loc)
	];
	buildExpStat(loc, fn._body, buildCall(loc, expRef, args));

	buildReturnStat(loc, fn._body, buildExpReference(loc, fn.params[0], "left"));

	return fn;
}

ir.Function getArrayConcatFunction(Location loc, LanguagePass lp, ir.Module thisModule, ir.ArrayType type, bool isAssignment)
{
	if (type.mangledName is null) {
		type.mangledName = mangle(type);
	}

	string name;
	if (isAssignment) {
		name = "__concatAssignArray" ~ type.mangledName;
	} else {
		name = "__concatArray" ~ type.mangledName;
	}
	auto fn = lookupFunction(lp, thisModule.myScope, loc, name);

	if (fn !is null) {
		return fn;
	}

	fn = buildFunction(loc, thisModule.children, thisModule.myScope, name);
	fn.mangledName = fn.name;
	fn.isWeakLink = true;
	fn.type.ret = copyTypeSmart(loc, type);

	ir.FunctionParam left;
	if (isAssignment) {
		left = addParam(loc, fn, buildPtrSmart(loc, type), "left");
	} else {
		left = addParamSmart(loc, fn, type, "left");
	}
	auto right = addParamSmart(loc, fn, type, "right");

	auto fnAlloc = lp.allocDgVariable;
	auto allocExpRef = buildExpReference(loc, fnAlloc, fnAlloc.name);

	auto fnCopy = getLlvmMemCopy(loc, lp);

	ir.Exp[] args;

	auto allocated = buildVarStatSmart(loc, fn._body, fn._body.myScope, buildVoidPtr(loc), "allocated");
	auto count = buildVarStatSmart(loc, fn._body, fn._body.myScope, buildSizeT(loc, lp), "count");
	ir.Exp leftlength()
	{
		if (isAssignment) {
			return buildArrayLength(loc, lp, buildDeref(loc, buildExpReference(loc, left, left.name)));
		} else {
			return buildArrayLength(loc, lp, buildExpReference(loc, left, left.name));
		}
	}

	buildExpStat(loc, fn._body,
		buildAssign(loc,
			buildExpReference(loc, count, count.name),
			buildAdd(loc,
				leftlength(),
				buildArrayLength(loc, lp, buildExpReference(loc, right, right.name))
			)
		)
	);

	args = [
		cast(ir.Exp)
		buildTypeidSmart(loc, type.base),
		buildExpReference(loc, count, count.name)
	];

	buildExpStat(loc, fn._body,
		buildAssign(loc,
			buildExpReference(loc, allocated, allocated.name),
			buildCall(loc, allocExpRef, args)
		)
	);

	ir.Exp leftPtr;
	if (isAssignment) {
		leftPtr = buildArrayPtr(loc, left.type, buildDeref(loc, buildExpReference(loc, left, left.name)));
	} else {
		leftPtr = buildArrayPtr(loc, left.type, buildExpReference(loc, left, left.name));
	}

	args = [
		cast(ir.Exp)
		buildExpReference(loc, allocated, allocated.name),
		buildCastToVoidPtr(loc, leftPtr),
		buildBinOp(loc, ir.BinOp.Op.Mul,
			leftlength(),
			buildConstantSizeT(loc, lp, size(lp, type.base))
		),
		buildConstantInt(loc, 0),
		buildConstantFalse(loc)
	];
	buildExpStat(loc, fn._body, buildCall(loc, buildExpReference(loc, fnCopy, fnCopy.name), args));


	args = [
		cast(ir.Exp)
		buildAdd(loc,
			buildExpReference(loc, allocated, allocated.name),
			buildBinOp(loc, ir.BinOp.Op.Mul,
				leftlength(),
				buildConstantSizeT(loc, lp, size(lp, type.base))
			)
		),
		buildCastToVoidPtr(loc, buildArrayPtr(loc, right.type, buildExpReference(loc, right, right.name))),
		buildBinOp(loc, ir.BinOp.Op.Mul,
			buildArrayLength(loc, lp, buildExpReference(loc, right, right.name)),
			buildConstantSizeT(loc, lp, size(lp, type.base))
		),
		buildConstantInt(loc, 0),
		buildConstantFalse(loc)
	];
	buildExpStat(loc, fn._body, buildCall(loc, buildExpReference(loc, fnCopy, fnCopy.name), args));


	if (isAssignment) {
		buildExpStat(loc, fn._body,
			buildAssign(loc,
				buildDeref(loc, buildExpReference(loc, left, left.name)),
				buildSlice(loc,
					buildCastSmart(loc, buildPtrSmart(loc, type.base), buildExpReference(loc, allocated, allocated.name)),
					[cast(ir.Exp)buildConstantSizeT(loc, lp, 0), buildExpReference(loc, count, count.name)]
				)
			)
		);
		buildReturnStat(loc, fn._body, buildDeref(loc, buildExpReference(loc, left, left.name)));
	} else {
		buildReturnStat(loc, fn._body,
			buildSlice(loc,
				buildCastSmart(loc, buildPtrSmart(loc, type.base), buildExpReference(loc, allocated, allocated.name)),
				[cast(ir.Exp)buildConstantSizeT(loc, lp, 0), buildExpReference(loc, count, count.name)]
			)
		);
	}

	return fn;
}

ir.Function getArrayCmpFunction(Location loc, LanguagePass lp, ir.Module thisModule, ir.ArrayType type, bool notEqual)
{
	if (type.mangledName is null) {
		type.mangledName = mangle(type);
	}

	string name;
	if (notEqual) {
		name = "__cmpNotArray" ~ type.mangledName;
	} else {
		name = "__cmpArray" ~ type.mangledName;
	}
	auto fn = lookupFunction(lp, thisModule.myScope, loc, name);
	if (fn !is null) {
		return fn;
	}

	fn = buildFunction(loc, thisModule.children, thisModule.myScope, name);
	fn.mangledName = fn.name;
	fn.isWeakLink = true;
	fn.type.ret = buildBool(loc);

	auto left = addParamSmart(loc, fn, type, "left");
	auto right = addParamSmart(loc, fn, type, "right");

	auto memCmp = lp.memcmpFunc;
	auto memCmpExpRef = buildExpReference(loc, memCmp, memCmp.name);


	auto thenState = buildBlockStat(loc, fn, fn._body.myScope);
	buildReturnStat(loc, thenState, buildConstantBool(loc, notEqual));
	buildIfStat(loc, fn._body,
		buildBinOp(loc, ir.BinOp.Op.NotEqual,
			buildArrayLength(loc, lp, buildExpReference(loc, left, left.name)),
			buildArrayLength(loc, lp, buildExpReference(loc, right, right.name))
		),
		thenState
	);

	auto childArray = cast(ir.ArrayType) type.base;
	if (childArray !is null) {
		/* for (size_t i = 0; i < left.length; ++i) {
		 *     if (left[i] !=/== right[i]) {
		 *         return true;
		 *     }
		 * }
		 * return false;
		 */
		ir.ForStatement forLoop;
		ir.Variable iVar;
		buildForStatement(loc, lp, fn._body.myScope, buildArrayLength(loc, lp, buildExpReference(loc, left, left.name)), forLoop, iVar);
		auto l = buildIndex(loc, buildExpReference(loc, left, left.name), buildExpReference(loc, iVar, iVar.name));
		auto r = buildIndex(loc, buildExpReference(loc, right, right.name), buildExpReference(loc, iVar, iVar.name));
		auto cmp = buildBinOp(loc, notEqual ? ir.BinOp.Op.NotEqual : ir.BinOp.Op.Equal, l, r);
		auto then = buildBlockStat(loc, null, forLoop.block.myScope);
		buildReturnStat(loc, then, buildConstantBool(loc, true));
		auto ifs = buildIfStat(loc, cmp, then);
		forLoop.block.statements ~= ifs;
		fn._body.statements ~= forLoop;
		buildReturnStat(loc, fn._body, buildConstantBool(loc, false));
	} else {
		buildReturnStat(loc, fn._body,
			buildBinOp(loc, notEqual ? ir.BinOp.Op.NotEqual : ir.BinOp.Op.Equal,
				buildCall(loc, memCmpExpRef, [
					buildCastSmart(loc, buildVoidPtr(loc), buildArrayPtr(loc, left.type, buildExpReference(loc, left, left.name))),
					buildCastSmart(loc, buildVoidPtr(loc), buildArrayPtr(loc, right.type, buildExpReference(loc, right, right.name))),
					cast(ir.Exp)buildBinOp(loc, ir.BinOp.Op.Mul,
						buildArrayLength(loc, lp, buildExpReference(loc, left, left.name)),
						buildConstantSizeT(loc, lp, size(lp, type.base))
					)

				]),
				buildConstantInt(loc, 0)
			)
		);
	}

	return fn;
}
