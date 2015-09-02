// Copyright © 2013, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.ir.util;

import ir = volt.ir.ir;

import volt.errors;
import volt.interfaces;
import volt.token.location;
import volt.util.string : unescapeString;
import volt.ir.copy;


/**
 * Builds an identifier exp from a string.
 */
ir.IdentifierExp buildIdentifierExp(Location loc, string value, bool isGlobal = false)
{
	auto iexp = new ir.IdentifierExp(value);
	iexp.location = loc;
	iexp.globalLookup = isGlobal;
	return iexp;
}

/**
 * Builds a QualifiedName from a string.
 */
ir.QualifiedName buildQualifiedName(Location loc, string value)
{
	auto i = new ir.Identifier(value);
	i.location = loc;
	auto q = new ir.QualifiedName();
	q.identifiers = [i];
	q.location = loc;
	return q;
}

/**
 * Builds a QualifiedName from an array.
 */
ir.QualifiedName buildQualifiedName(Location loc, string[] value...)
{
	version(Volt) {
		auto idents = new ir.Identifier[](value.length);
	} else {
		auto idents = new ir.Identifier[value.length];
	}
	foreach (i, val; value) {
		idents[i] = new ir.Identifier(val);
		idents[i].location = loc;
	}

	auto q = new ir.QualifiedName();
	q.identifiers = idents;
	q.location = loc;
	return q;
}

/**
 * Builds a QualifiedName from a Identifier.
 */
ir.QualifiedName buildQualifiedNameSmart(ir.Identifier i)
{
	auto q = new ir.QualifiedName();
	q.identifiers = [new ir.Identifier(i)];
	q.location = i.location;
	return q;
}

/**
 * Return the scope from the given type if it is,
 * a aggregate or a derivative from one.
 */
ir.Scope getScopeFromType(ir.Type type)
{
	switch (type.nodeType) with (ir.NodeType) {
	case TypeReference:
		auto asTypeRef = cast(ir.TypeReference) type;
		assert(asTypeRef !is null);
		assert(asTypeRef.type !is null);
		return getScopeFromType(asTypeRef.type);
	case ArrayType:
		auto asArray = cast(ir.ArrayType) type;
		assert(asArray !is null);
		return getScopeFromType(asArray.base);
	case PointerType:
		auto asPointer = cast(ir.PointerType) type;
		assert(asPointer !is null);
		return getScopeFromType(asPointer.base);
	case Struct:
		auto asStruct = cast(ir.Struct) type;
		assert(asStruct !is null);
		return asStruct.myScope;
	case Union:
		auto asUnion = cast(ir.Union) type;
		assert(asUnion !is null);
		return asUnion.myScope;
	case Class:
		auto asClass = cast(ir.Class) type;
		assert(asClass !is null);
		return asClass.myScope;
	case Interface:
		auto asInterface = cast(ir._Interface) type;
		assert(asInterface !is null);
		return asInterface.myScope;
	case UserAttribute:
		auto asAttr = cast(ir.UserAttribute) type;
		assert(asAttr !is null);
		return asAttr.myScope;
	case Enum:
		auto asEnum = cast(ir.Enum) type;
		assert(asEnum !is null);
		return asEnum.myScope;
	default:
		return null;
	}
}

/**
 * For the given store get the scope that it introduces.
 *
 * Returns null for Values and non-scope types.
 */
ir.Scope getScopeFromStore(ir.Store store)
{
	final switch(store.kind) with (ir.Store.Kind) {
	case Scope:
		return store.s;
	case Type:
		auto type = cast(ir.Type)store.node;
		assert(type !is null);
		return getScopeFromType(type);
	case Value:
	case Function:
	case FunctionParam:
	case Template:
	case EnumDeclaration:
	case Expression:
		return null;
	case Merge:
	case Alias:
		throw panic(store.node.location, "unresolved alias");
	}
}

/**
 * Does a smart copy of a type.
 *
 * Meaning that well copy all types, but skipping
 * TypeReferences, but inserting one when it comes
 * across a named type.
 */
ir.Type copyTypeSmart(Location loc, ir.Type type)
{
	ir.Type outType;
	switch (type.nodeType) with (ir.NodeType) {
	case PrimitiveType:
		auto pt = cast(ir.PrimitiveType)type;
		pt = new ir.PrimitiveType(pt.type);
		pt.location = loc;
		outType = pt;
		break;
	case PointerType:
		auto pt = cast(ir.PointerType)type;
		pt = new ir.PointerType(copyTypeSmart(loc, pt.base));
		pt.location = loc;
		outType = pt;
		break;
	case ArrayType:
		auto at = cast(ir.ArrayType)type;
		at = new ir.ArrayType(copyTypeSmart(loc, at.base));
		at.location = loc;
		outType = at;
		break;
	case StaticArrayType:
		auto asSat = cast(ir.StaticArrayType)type;
		auto sat = new ir.StaticArrayType();
		sat.location = loc;
		sat.base = copyTypeSmart(loc, asSat.base);
		sat.length = asSat.length;
		outType = sat;
		break;
	case AAType:
		auto asAA = cast(ir.AAType)type;
		auto aa = new ir.AAType();
		aa.location = loc;
		aa.value = copyTypeSmart(loc, asAA.value);
		aa.key = copyTypeSmart(loc, asAA.key);
		outType = aa;
		break;
	case FunctionType:
		auto asFt = cast(ir.FunctionType)type;
		auto ft = new ir.FunctionType(asFt);
		ft.location = loc;
		ft.ret = copyTypeSmart(loc, ft.ret);
		foreach(i, ref t; ft.params) {
			t = copyTypeSmart(loc, t);
		}
		outType = ft;
		break;
	case FunctionSetType:
		auto asFset = cast(ir.FunctionSetType)type;
		auto fset = new ir.FunctionSetType();
		fset.location = loc;
		fset.set = asFset.set;
		fset.isFromCreateDelegate = asFset.isFromCreateDelegate;
		outType = fset;
		break;
	case DelegateType:
		auto asDg = cast(ir.DelegateType)type;
		auto dg = new ir.DelegateType(asDg);
		dg.location = loc;
		dg.ret = copyTypeSmart(loc, dg.ret);
		foreach(i, ref t; dg.params) {
			t = copyTypeSmart(loc, t);
		}
		outType = dg;
		break;
	case StorageType:
		auto asSt = cast(ir.StorageType)type;
		auto st = new ir.StorageType();
		st.location = loc;
		if (asSt.base !is null) st.base = copyTypeSmart(loc, asSt.base);
		st.type = asSt.type;
		outType = st;
		break;
	case TypeReference:
		auto tr = cast(ir.TypeReference)type;
		assert(tr.type !is null);
		outType = copyTypeSmart(loc, tr.type);
		break;
	case NullType:
		auto nt = new ir.NullType();
		nt.location = type.location;
		outType = nt;
		break;
	case UserAttribute:
	case Interface:
	case Struct:
	case Class:
	case Union:
	case Enum:
		auto s = getScopeFromType(type);
		// @todo Get fully qualified name for type.
		outType = buildTypeReference(loc, type, s !is null ? s.name : null);
		break;
	default:
		throw panicUnhandled(type, ir.nodeToString(type));
	}
	addStorage(outType, type);
	return outType;
}

ir.TypeReference buildTypeReference(Location loc, ir.Type type, string[] names...)
{
	auto tr = new ir.TypeReference();
	tr.location = loc;
	tr.type = type;
	tr.id = buildQualifiedName(loc, names);
	return tr;
}

ir.StorageType buildStorageType(Location loc, ir.StorageType.Kind kind, ir.Type base)
{
	auto storage = new ir.StorageType();
	storage.location = loc;
	storage.type = kind;
	storage.base = base;
	return storage;
}

/**
 * Build a PrimitiveType.
 */
ir.PrimitiveType buildPrimitiveType(Location loc, ir.PrimitiveType.Kind kind)
{
	auto pt = new ir.PrimitiveType(kind);
	pt.location = loc;
	return pt;
}

ir.ArrayType buildArrayType(Location loc, ir.Type base)
{
	auto array = new ir.ArrayType();
	array.location = loc;
	array.base = base;
	return array;
}

ir.ArrayType buildArrayTypeSmart(Location loc, ir.Type base)
{
	auto array = new ir.ArrayType();
	array.location = loc;
	array.base = copyTypeSmart(loc, base);
	return array;
}

ir.PrimitiveType buildVoid(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Void); }
ir.PrimitiveType buildBool(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Bool); }
ir.PrimitiveType buildChar(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Char); }
ir.PrimitiveType buildDchar(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Dchar); }
ir.PrimitiveType buildWchar(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Wchar); }
ir.PrimitiveType buildByte(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Byte); }
ir.PrimitiveType buildUbyte(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Ubyte); }
ir.PrimitiveType buildShort(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Short); }
ir.PrimitiveType buildUshort(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Ushort); }
ir.PrimitiveType buildInt(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Int); }
ir.PrimitiveType buildUint(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Uint); }
ir.PrimitiveType buildLong(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Long); }
ir.PrimitiveType buildUlong(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Ulong); }
ir.PrimitiveType buildSizeT(Location loc, LanguagePass lp) { return lp.settings.getSizeT(loc); }
ir.PrimitiveType buildFloat(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Float); }
ir.PrimitiveType buildDouble(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Double); }
ir.PrimitiveType buildReal(Location loc) { return buildPrimitiveType(loc, ir.PrimitiveType.Kind.Real); }

/**
 * Build a string (immutable(char)[]) type.
 */
ir.ArrayType buildString(Location loc)
{
	auto c = buildChar(loc);
	c.isImmutable = true;
	return buildArrayType(loc, c);
}

ir.ArrayType buildStringArray(Location loc)
{
	return buildArrayType(loc, buildString(loc));
}


/**
 * Build a void* type.
 */
ir.PointerType buildVoidPtr(Location loc)
{
	auto pt = new ir.PointerType(buildVoid(loc));
	pt.location = loc;

	return pt;
}

ir.PointerType buildPtrSmart(Location loc, ir.Type base)
{
	auto pt = new ir.PointerType(copyTypeSmart(loc, base));
	pt.location = loc;

	return pt;
}

ir.ArrayLiteral buildArrayLiteralSmart(Location loc, ir.Type type, ir.Exp[] exps...)
{
	auto literal = new ir.ArrayLiteral();
	literal.location = loc;
	literal.type = copyTypeSmart(loc, type);
	version(Volt) {
		literal.values = new exps[0 .. $];
	} else {
		literal.values = exps.dup;
	}
	return literal;
}

ir.StructLiteral buildStructLiteralSmart(Location loc, ir.Type type, ir.Exp[] exps)
{
	auto literal = new ir.StructLiteral();
	literal.location = loc;
	literal.type = copyTypeSmart(loc, type);
	version(Volt) {
		literal.exps = new exps[0 .. $];
	} else {
		literal.exps = exps.dup;
	}
	return literal;
}

ir.UnionLiteral buildUnionLiteralSmart(Location loc, ir.Type type, ir.Exp[] exps)
{
	auto literal = new ir.UnionLiteral();
	literal.location = loc;
	literal.type = copyTypeSmart(loc, type);
	version(Volt) {
		literal.exps = new exps[0 .. $];
	} else {
		literal.exps = exps.dup;
	}
	return literal;
}

/**
 * Add a Variable to the BlockStatement scope and either to
 * its statement or if StatementExp given to it instead.
 */
void addVariable(ir.BlockStatement b, ir.StatementExp statExp, ir.Variable var)
{
	b.myScope.addValue(var, var.name);
	if (statExp !is null) {
		statExp.statements ~= var;
	} else {
		b.statements ~= var;
	}
}

/**
 * Build a Variable, while not being smart about its type.
 */
ir.Variable buildVariable(Location loc, ir.Type type, ir.Variable.Storage st, string name, ir.Exp assign = null)
{
	auto var = new ir.Variable();
	var.location = loc;
	var.name = name;
	var.type = type;
	var.storage = st;
	var.assign = assign;

	return var;
}

/**
 * Build a Variable with an anon. name and insert it into the BlockStatement
 * or StatementExp if given. Note even if you want the Variable to end up in
 * the StatementExp you must give it the BlockStatement that the StatementExp
 * lives in as the variable will be added to its scope and generated a uniqe
 * name from its context.
 */
ir.Variable buildVariableAnonSmart(Location loc, ir.BlockStatement b,
                                   ir.StatementExp statExp,
                                   ir.Type type, ir.Exp assign)
{
	auto name = b.myScope.genAnonIdent();
	auto var = buildVariable(loc, copyTypeSmart(loc, type), ir.Variable.Storage.Function, name, assign);
	addVariable(b, statExp, var);
	return var;
}

/**
 * Create an anonymous variable for a statementexp without a block statement.
 */
ir.Variable buildVariableAnonSmart(Location loc, ir.Scope current,
                                   ir.StatementExp statExp,
                                   ir.Type type, ir.Exp assign)
{
	auto name = current.genAnonIdent();
	auto var = buildVariable(loc, copyTypeSmart(loc, type), ir.Variable.Storage.Function, name, assign);
	current.addValue(var, var.name);
	statExp.statements ~= var;
	return var;
}

/**
 * Copy a Variable, while being smart about its type, does
 * not copy the the assign exp on the Variable.
 */
ir.Variable copyVariableSmart(Location loc, ir.Variable right)
{
	return buildVariable(loc, copyTypeSmart(loc, right.type), right.storage, right.name);
}

ir.Variable[] copyVariablesSmart(Location loc, ir.Variable[] vars)
{
	version(Volt) {
		auto outVars = new ir.Variable[](vars.length);
	} else {
		auto outVars = new ir.Variable[vars.length];
	}
	foreach (i, var; vars) {
		outVars[i] = copyVariableSmart(loc, var);
	}
	return outVars;
}

/**
 * Get ExpReferences from a list of variables.
 */
ir.Exp[] getExpRefs(Location loc, ir.FunctionParam[] vars)
{
	version(Volt) {
		auto erefs = new ir.Exp[](vars.length);
	} else {
		auto erefs = new ir.Exp[vars.length];
	}
	foreach (i, var; vars) {
		erefs[i] = buildExpReference(loc, var, var.name);
	}
	return erefs;
}

/**
 * Build a Variable, while being smart about its type.
 */
ir.Variable buildVariableSmart(Location loc, ir.Type type, ir.Variable.Storage st, string name)
{
	return buildVariable(loc, copyTypeSmart(loc, type), st, name);
}

/**
 * Builds a usable ExpReference.
 */
ir.ExpReference buildExpReference(Location loc, ir.Declaration decl, string[] names...)
{
	auto varRef = new ir.ExpReference();
	varRef.location = loc;
	varRef.decl = decl;
	varRef.idents ~= names;

	return varRef;
}

/**
 * Builds a constant double.
 */
ir.Constant buildConstantDouble(Location loc, double value)
{
	auto c = new ir.Constant();
	c.location = loc;
	c.u._double = value;
	c.type = buildDouble(loc);

	return c;
}

/**
 * Builds a constant float.
 */
ir.Constant buildConstantFloat(Location loc, float value)
{
	auto c = new ir.Constant();
	c.location = loc;
	c.u._double = value;
	c.type = buildFloat(loc);

	return c;
}

/**
 * Builds a constant int.
 */
ir.Constant buildConstantInt(Location loc, int value)
{
	auto c = new ir.Constant();
	c.location = loc;
	c.u._int = value;
	c.type = buildInt(loc);

	return c;
}

ir.Constant buildConstantUint(Location loc, uint value)
{
	auto c = new ir.Constant();
	c.location = loc;
	c.u._uint = value;
	c.type = buildUint(loc);

	return c;
}

ir.Constant buildConstantLong(Location loc, long value)
{
	auto c = new ir.Constant();
	c.location = loc;
	c.u._long = value;
	c.type = buildLong(loc);

	return c;
}

ir.Constant buildConstantUlong(Location loc, ulong value)
{
	auto c = new ir.Constant();
	c.location = loc;
	c.u._ulong = value;
	c.type = buildUlong(loc);

	return c;
}

/**
 * Builds a constant bool.
 */
ir.Constant buildConstantBool(Location loc, bool val)
{
	auto c = new ir.Constant();
	c.location = loc;
	c.u._bool = val;
	c.type = buildBool(loc);

	return c;
}

ir.Constant buildConstantNull(Location loc, ir.Type base)
{
	auto c = new ir.Constant();
	c.location = loc;
	c.u._pointer = null;
	c.type = copyTypeSmart(loc, base);
	c.type.location = loc;
	c.isNull = true;
	return c;
}

/**
 * Gets a size_t Constant and fills it with a value.
 */
ir.Constant buildConstantSizeT(Location loc, LanguagePass lp, size_t val)
{
	auto c = new ir.Constant();
	c.location = loc;
	auto prim = lp.settings.getSizeT(loc);
	// Uh, I assume just c._uint = val would work, but I can't test it here, so just be safe.
	if (prim.type == ir.PrimitiveType.Kind.Ulong) {
		c.u._ulong = cast(ulong)val;
	} else {
		c.u._uint = cast(uint)val;
	}
	c.type = prim;
	return c;
}

/**
 * Builds a constant string.
 */
ir.Constant buildConstantString(Location loc, string val, bool escape = true)
{
	auto c = new ir.Constant();
	c.location = loc;
	c._string = val;
	auto atype = buildArrayType(loc, buildChar(loc));
	atype.base.isImmutable = true;
	c.type = atype;
	if (escape) {
		c.arrayData = unescapeString(loc, c._string);
	} else {
		c.arrayData = cast(immutable(void)[]) c._string;
	}
	return c;
}

/**
 * Builds a constant 'c' string.
 */
ir.Exp buildConstantCString(Location loc, string val, bool escape = true)
{
	return buildAccess(loc, buildConstantString(loc, val, escape), "ptr");
}

/**
 * Build a constant to insert to the IR from a resolved EnumDeclaration.
 */
ir.Constant buildConstantEnum(Location loc, ir.EnumDeclaration ed)
{
	auto cnst = cast(ir.Constant) ed.assign;
	auto c = new ir.Constant();
	c.location = loc;
	c.u._ulong = cnst.u._ulong;
	c._string = cnst._string;
	c.arrayData = cnst.arrayData;
	c.type = copyTypeSmart(loc, ed.type);

	return c;
}

ir.Constant buildConstantTrue(Location loc) { return buildConstantBool(loc, true); }
ir.Constant buildConstantFalse(Location loc) { return buildConstantBool(loc, false); }

/**
 * Build a cast and sets the location, does not call copyTypeSmart.
 */
ir.Unary buildCast(Location loc, ir.Type type, ir.Exp exp)
{
	auto cst = new ir.Unary(type, exp);
	cst.location = loc;
	return cst;
}

/**
 * Build a cast, sets the location and calling copyTypeSmart
 * on the type, to avoid duplicate nodes.
 */
ir.Unary buildCastSmart(Location loc, ir.Type type, ir.Exp exp)
{
	return buildCast(loc, copyTypeSmart(loc, type), exp);
}

ir.Unary buildCastToBool(Location loc, ir.Exp exp) { return buildCast(loc, buildBool(loc), exp); }
ir.Unary buildCastToVoidPtr(Location loc, ir.Exp exp) { return buildCast(loc, buildVoidPtr(loc), exp); }

/**
 * Builds a not expression.
 */
ir.Unary buildNot(Location loc, ir.Exp exp)
{
	auto unot = new ir.Unary();
	unot.location = loc;
	unot.op = ir.Unary.Op.Not;
	unot.value = exp;
	return unot;
}

/**
 * Builds an AddrOf expression.
 */
ir.Unary buildAddrOf(Location loc, ir.Exp exp)
{
	auto addr = new ir.Unary();
	addr.location = loc;
	addr.op = ir.Unary.Op.AddrOf;
	addr.value = exp;
	return addr;
}

/**
 * Builds a ExpReference and a AddrOf from a Variable.
 */
ir.Unary buildAddrOf(Location loc, ir.Variable var, string[] names...)
{
	return buildAddrOf(loc, buildExpReference(loc, var, names));
}

/**
 * Builds a Dereference expression.
 */
ir.Unary buildDeref(Location loc, ir.Exp exp)
{
	auto deref = new ir.Unary();
	deref.location = loc;
	deref.op = ir.Unary.Op.Dereference;
	deref.value = exp;
	return deref;
}

/**
 * Builds a New expression.
 */
ir.Unary buildNew(Location loc, ir.Type type, string name, ir.Exp[] arguments...)
{
	auto new_ = new ir.Unary();
	new_.location = loc;
	new_.op = ir.Unary.Op.New;
	new_.type = buildTypeReference(loc, type, name);
	new_.hasArgumentList = arguments.length > 0;
	version(Volt) {
		new_.argumentList = new arguments[0 .. $];
	} else {
		new_.argumentList = arguments.dup;
	}
	return new_;
}

ir.Unary buildNewSmart(Location loc, ir.Type type, ir.Exp[] arguments...)
{
	auto new_ = new ir.Unary();
	new_.location = loc;
	new_.op = ir.Unary.Op.New;
 	new_.type = copyTypeSmart(loc, type);
	new_.hasArgumentList = arguments.length > 0;
	version(Volt) {
		new_.argumentList = new arguments[0 .. $];
	} else {
		new_.argumentList = arguments.dup;
	}
	return new_;
}

/**
 * Builds a typeid with type smartly.
 */
ir.Typeid buildTypeidSmart(Location loc, ir.Type type)
{
	auto t = new ir.Typeid();
	t.location = loc;
	t.type = copyTypeSmart(loc, type);
	return t;
}

/**
 * Build a postfix Identifier expression.
 */
ir.Postfix buildAccess(Location loc, ir.Exp exp, string name)
{
	auto access = new ir.Postfix();
	access.location = loc;
	access.op = ir.Postfix.Op.Identifier;
	access.child = exp;
	access.identifier = new ir.Identifier();
	access.identifier.location = loc;
	access.identifier.value = name;

	return access;
}

/**
 * Builds a chain of postfix lookups from a QualifiedName.
 * These are only useful before the extyper runs.
 */
ir.Postfix buildAccess(Location loc, ir.QualifiedName qname, string name)
{
	ir.Exp current = buildIdentifierExp(loc, qname.identifiers[0].value);
	foreach (ident; qname.identifiers[1 .. $]) {
		auto pfix = new ir.Postfix();
		pfix.location = loc;
		pfix.child = current;
		pfix.op = ir.Postfix.Op.Identifier;
		pfix.identifier = new ir.Identifier();
		pfix.identifier.location = loc;
		pfix.identifier.value = ident.value;
		current = pfix;
	}
	return buildAccess(loc, current, name);
}

/**
 * Builds a postfix slice.
 */
ir.Postfix buildSlice(Location loc, ir.Exp child, ir.Exp[] args...)
{
	auto slice = new ir.Postfix();
	slice.location = loc;
	slice.op = ir.Postfix.Op.Slice;
	slice.child = child;
	version(Volt) {
		slice.arguments = new args[0 .. $];
	} else {
		slice.arguments = args.dup;
	}

	return slice;
}

/**
 * Builds a postfix increment.
 */
ir.Postfix buildIncrement(Location loc, ir.Exp child)
{
	auto inc = new ir.Postfix();
	inc.location = loc;
	inc.op = ir.Postfix.Op.Increment;
	inc.child = child;

	return inc;
}

/**
 * Builds a postfix decrement.
 */
ir.Postfix buildDecrement(Location loc, ir.Exp child)
{
	auto inc = new ir.Postfix();
	inc.location = loc;
	inc.op = ir.Postfix.Op.Decrement;
	inc.child = child;

	return inc;
}

/**
 * Builds a postfix index.
 */
ir.Postfix buildIndex(Location loc, ir.Exp child, ir.Exp arg)
{
	auto slice = new ir.Postfix();
	slice.location = loc;
	slice.op = ir.Postfix.Op.Index;
	slice.child = child;
	slice.arguments ~= arg;

	return slice;
}

/**
 * Builds a postfix call.
 */
ir.Postfix buildCall(Location loc, ir.Exp child, ir.Exp[] args)
{
	auto call = new ir.Postfix();
	call.location = loc;
	call.op = ir.Postfix.Op.Call;
	call.child = child;
	version(Volt) {
		call.arguments = new args[0 .. $];
	} else {
		call.arguments = args.dup;
	}

	return call;
}

ir.Postfix buildMemberCall(Location loc, ir.Exp child, ir.ExpReference fn, string name, ir.Exp[] args)
{
	auto lookup = new ir.Postfix();
	lookup.location = loc;
	lookup.op = ir.Postfix.Op.CreateDelegate;
	lookup.child = child;
	lookup.identifier = new ir.Identifier();
	lookup.identifier.location = loc;
	lookup.identifier.value = name;
	lookup.memberFunction = fn;

	auto call = new ir.Postfix();
	call.location = loc;
	call.op = ir.Postfix.Op.Call;
	call.child = lookup;
	call.arguments = args;

	return call;
}

ir.Postfix buildCreateDelegate(Location loc, ir.Exp child, ir.ExpReference fn)
{
	auto postfix = new ir.Postfix();
	postfix.location = loc;
	postfix.op = ir.Postfix.Op.CreateDelegate;
	postfix.child = child;
	postfix.memberFunction = fn;
	return postfix;
}

/**
 * Builds a postfix call.
 */
ir.Postfix buildCall(Location loc, ir.Declaration decl, ir.Exp[] args, string[] names...)
{
	return buildCall(loc, buildExpReference(loc, decl, names), args);
}

/**
 * Builds an add BinOp.
 */
ir.BinOp buildAdd(Location loc, ir.Exp left, ir.Exp right)
{
	return buildBinOp(loc, ir.BinOp.Op.Add, left, right);
}

/**
 * Builds a subtraction BinOp.
 */
ir.BinOp buildSub(Location loc, ir.Exp left, ir.Exp right)
{
	return buildBinOp(loc, ir.BinOp.Op.Sub, left, right);
}

/**
 * Builds an assign BinOp.
 */
ir.BinOp buildAssign(Location loc, ir.Exp left, ir.Exp right)
{
	return buildBinOp(loc, ir.BinOp.Op.Assign, left, right);
}

/**
 * Builds an add-assign BinOp.
 */
ir.BinOp buildAddAssign(Location loc, ir.Exp left, ir.Exp right)
{
	return buildBinOp(loc, ir.BinOp.Op.AddAssign, left, right);
}

/**
 * Builds a cat-assign BinOp.
 */
ir.BinOp buildCatAssign(Location loc, ir.Exp left, ir.Exp right)
{
	return buildBinOp(loc, ir.BinOp.Op.CatAssign, left, right);
}

/**
 * Builds an BinOp.
 */
ir.BinOp buildBinOp(Location loc, ir.BinOp.Op op, ir.Exp left, ir.Exp right)
{
	auto binop = new ir.BinOp();
	binop.location = loc;
	binop.op = op;
	binop.left = left;
	binop.right = right;
	return binop;
}

ir.StatementExp buildStatementExp(Location loc)
{
	auto stateExp = new ir.StatementExp();
	stateExp.location = loc;
	return stateExp;
}

ir.StatementExp buildStatementExp(Location loc, ir.Node[] stats, ir.Exp exp)
{
	auto stateExp = buildStatementExp(loc);
	stateExp.statements = stats;
	stateExp.exp = exp;
	return stateExp;
}

ir.FunctionParam buildFunctionParam(Location loc, size_t index, string name, ir.Function fn)
{
	auto fparam = new ir.FunctionParam();
	fparam.location = loc;
	fparam.index = index;
	fparam.name = name;
	fparam.fn = fn;
	return fparam;
}

/**
 * Adds a variable argument to a function, also adds it to the scope.
 */
ir.FunctionParam addParam(Location loc, ir.Function fn, ir.Type type, string name)
{
	auto var = buildFunctionParam(loc, fn.type.params.length, name, fn);

	fn.type.params ~= type;
	fn.type.isArgOut ~= false;
	fn.type.isArgRef ~= false;

	fn.params ~= var;
	fn.myScope.addValue(var, name);

	return var;
}

/**
 * Adds a variable argument to a function, also adds it to the scope.
 */
ir.FunctionParam addParamSmart(Location loc, ir.Function fn, ir.Type type, string name)
{
	return addParam(loc, fn, copyTypeSmart(loc, type), name);
}

/**
 * Builds a variable statement smartly, inserting at the end of the
 * block statements and inserting it in the scope.
 */
ir.Variable buildVarStatSmart(Location loc, ir.BlockStatement block, ir.Scope _scope, ir.Type type, string name)
{
	auto var = buildVariableSmart(loc, type, ir.Variable.Storage.Function, name);
	block.statements ~= var;
	_scope.addValue(var, name);
	return var;
}

/**
 * Build an exp statement and add it to a StatementExp.
 */
ir.ExpStatement buildExpStat(Location loc, ir.StatementExp stat, ir.Exp exp)
{
	auto ret = new ir.ExpStatement();
	ret.location = loc;
	ret.exp = exp;

	stat.statements ~= ret;

	return ret;
}

ir.StatementExp buildVaArgCast(Location loc, ir.VaArgExp vaexp)
{
	auto sexp = new ir.StatementExp();
	sexp.location = loc;

	auto ptrToPtr = buildVariableSmart(loc, buildPtrSmart(loc, buildVoidPtr(loc)), ir.Variable.Storage.Function, "ptrToPtr");
	ptrToPtr.assign = buildAddrOf(loc, vaexp.arg);
	sexp.statements ~= ptrToPtr;

	auto cpy = buildVariableSmart(loc, buildVoidPtr(loc), ir.Variable.Storage.Function, "cpy");
	cpy.assign = buildDeref(loc, buildExpReference(loc, ptrToPtr));
	sexp.statements ~= cpy;

	auto vlderef = buildDeref(loc, buildExpReference(loc, ptrToPtr));
	auto tid = buildTypeidSmart(loc, vaexp.type);
	auto sz = buildAccess(loc, tid, "size");
	auto assign = buildAddAssign(loc, vlderef, sz);
	buildExpStat(loc, sexp, assign);

	auto ptr = buildPtrSmart(loc, vaexp.type);
	auto _cast = buildCastSmart(loc, ptr, buildExpReference(loc, cpy));
	auto deref = buildDeref(loc, _cast);
	sexp.exp = deref;

	return sexp;
}

ir.ThrowStatement buildThrowStatement(Location loc, ir.Exp exp)
{
	auto ts = new ir.ThrowStatement();
	ts.location = loc;
	ts.exp = exp;
	return ts;
}

ir.Exp buildVaArgStart(Location loc, ir.Exp vlexp, ir.Exp argexp)
{
	return buildAssign(loc, buildDeref(loc, vlexp), argexp);
}

ir.Exp buildVaArgEnd(Location loc, ir.Exp vlexp)
{
	return buildAssign(loc, buildDeref(loc, vlexp), buildConstantNull(loc, buildVoidPtr(loc)));
}

ir.StatementExp buildInternalArrayLiteralSmart(Location loc, ir.Type atype, ir.Exp[] exps)
{
	if (atype.nodeType != ir.NodeType.ArrayType)
		throw panic(atype, "must be array type");

	auto sexp = new ir.StatementExp();
	sexp.location = loc;
	auto var = buildVariableSmart(loc, copyTypeSmart(loc, atype), ir.Variable.Storage.Function, "array");
	sexp.statements ~= var;
	auto _new = buildNewSmart(loc, atype, buildConstantUint(loc, cast(uint) exps.length));
	auto vassign = buildAssign(loc, buildExpReference(loc, var), _new);
	buildExpStat(loc, sexp, vassign);
	foreach (i, exp; exps) {
		auto slice = buildIndex(loc, buildExpReference(loc, var), buildConstantUint(loc, cast(uint) i));
		auto assign = buildAssign(loc, slice, exp);
		buildExpStat(loc, sexp, assign);
	}
	sexp.exp = buildExpReference(loc, var, var.name);
	return sexp;
}

ir.StatementExp buildInternalStaticArrayLiteralSmart(Location loc, ir.Type atype, ir.Exp[] exps)
{
	if (atype.nodeType != ir.NodeType.StaticArrayType)
		throw panic(atype, "must be staticarray type");

	auto sexp = new ir.StatementExp();
	sexp.location = loc;
	auto var = buildVariableSmart(loc, copyTypeSmart(loc, atype), ir.Variable.Storage.Function, "sarray");
	sexp.statements ~= var;
	foreach (i, exp; exps) {
		auto l = buildIndex(loc, buildExpReference(loc, var), buildConstantUint(loc, cast(uint) i));
		auto assign = buildAssign(loc, l, exp);
		buildExpStat(loc, sexp, assign);
	}
	sexp.exp = buildExpReference(loc, var, var.name);
	return sexp;
}

ir.StatementExp buildInternalArrayLiteralSliceSmart(Location loc, ir.Type atype, ir.Type[] types, int[] sizes, int totalSize, ir.Function memcpyFn, ir.Exp[] exps)
{
	if (atype.nodeType != ir.NodeType.ArrayType)
		throw panic(atype, "must be array type");

	auto sexp = new ir.StatementExp();
	sexp.location = loc;
	auto var = buildVariableSmart(loc, copyTypeSmart(loc, atype), ir.Variable.Storage.Function, "array");

	sexp.statements ~= var;
	auto _new = buildNewSmart(loc, atype, buildConstantUint(loc, cast(uint) totalSize));
	auto vassign = buildAssign(loc, buildExpReference(loc, var), _new);
	buildExpStat(loc, sexp, vassign);

	int offset;
	foreach (i, exp; exps) {
		auto evar = buildVariableSmart(loc, types[i], ir.Variable.Storage.Function, "exp"); 
		sexp.statements ~= evar;
		auto evassign = buildAssign(loc, buildExpReference(loc, evar), exp);
		buildExpStat(loc, sexp, evassign);

		ir.Exp dst = buildAdd(loc, buildAccess(loc, buildExpReference(loc, var), "ptr"), buildConstantUint(loc, cast(uint)offset));
		ir.Exp src = buildCastToVoidPtr(loc, buildAddrOf(loc, buildExpReference(loc, evar)));
		ir.Exp len = buildConstantUint(loc, cast(uint) sizes[i]);
		ir.Exp aln = buildConstantInt(loc, 0);
		ir.Exp vol = buildConstantBool(loc, false);
		auto call = buildCall(loc, buildExpReference(loc, memcpyFn), [dst, src, len, aln, vol]);
		buildExpStat(loc, sexp, call);
		offset += sizes[i];
	}
	sexp.exp = buildExpReference(loc, var, var.name);
	return sexp;
}
/**
 * Build an exp statement and add it to a block.
 */
ir.ExpStatement buildExpStat(Location loc, ir.BlockStatement block, ir.Exp exp)
{
	auto ret = new ir.ExpStatement();
	ret.location = loc;
	ret.exp = exp;

	block.statements ~= ret;

	return ret;
}

/**
 * Build an exp statement without inserting it anywhere.
 */
ir.ExpStatement buildExpStat(Location loc, ir.Exp exp)
{
	auto ret = new ir.ExpStatement();
	ret.location = loc;
	ret.exp = exp;
	return ret;
}


/**
 * Build an if statement.
 */
ir.IfStatement buildIfStat(Location loc, ir.Exp exp,
                           ir.BlockStatement thenState, ir.BlockStatement elseState = null, string autoName = "")
{
	auto ret = new ir.IfStatement();
	ret.location = loc;
	ret.exp = exp;
	ret.thenState = thenState;
	ret.elseState = elseState;
	ret.autoName = autoName;

	return ret;
}

/**
 * Build an if statement.
 */
ir.IfStatement buildIfStat(Location loc, ir.BlockStatement block, ir.Exp exp,
                           ir.BlockStatement thenState, ir.BlockStatement elseState = null, string autoName = "")
{
	auto ret = new ir.IfStatement();
	ret.location = loc;
	ret.exp = exp;
	ret.thenState = thenState;
	ret.elseState = elseState;
	ret.autoName = autoName;

	block.statements ~= ret;

	return ret;
}

/**
 * Build an if statement.
 */
ir.IfStatement buildIfStat(Location loc, ir.StatementExp statExp, ir.Exp exp,
                           ir.BlockStatement thenState, ir.BlockStatement elseState = null, string autoName = "")
{
	auto ret = new ir.IfStatement();
	ret.location = loc;
	ret.exp = exp;
	ret.thenState = thenState;
	ret.elseState = elseState;
	ret.autoName = autoName;

	statExp.statements ~= ret;

	return ret;
}

/**
 * Build a block statement.
 */
ir.BlockStatement buildBlockStat(Location loc, ir.Node introducingNode, ir.Scope _scope, ir.Node[] statements...)
{
	auto ret = new ir.BlockStatement();
	ret.location = loc;
	version(Volt) {
		ret.statements = new statements[0 .. $];
	} else {
		ret.statements = statements.dup;
	}
	ret.myScope = new ir.Scope(_scope, introducingNode is null ? ret : introducingNode, "block");

	return ret;
}


/**
 * Build a return statement.
 */
ir.ReturnStatement buildReturnStat(Location loc, ir.BlockStatement block, ir.Exp exp = null)
{
	auto ret = new ir.ReturnStatement();
	ret.location = loc;
	ret.exp = exp;

	block.statements ~= ret;

	return ret;
}

ir.FunctionType buildFunctionTypeSmart(Location loc, ir.Type ret, ir.Type[] args...)
{
	auto type = new ir.FunctionType();
	type.location = loc;
	type.ret = copyType(ret);
	foreach (arg; args) {
		type.params ~= copyType(arg);
		type.isArgRef ~= false;
		type.isArgOut ~= false;
	}
	return type;
}

/// Builds a function without inserting it anywhere.
ir.Function buildFunction(Location loc, ir.Scope _scope, string name, bool buildBody = true)
{
	auto fn = new ir.Function();
	fn.name = name;
	fn.location = loc;
	fn.kind = ir.Function.Kind.Function;
	fn.myScope = new ir.Scope(_scope, fn, fn.name);

	fn.type = new ir.FunctionType();
	fn.type.location = loc;
	fn.type.ret = new ir.PrimitiveType(ir.PrimitiveType.Kind.Void);
	fn.type.ret.location = loc;

	if (buildBody) {
		fn._body = new ir.BlockStatement();
		fn._body.location = loc;
		fn._body.myScope = new ir.Scope(fn.myScope, fn._body, name);
	}

	return fn;
}

/**
 * Builds a completely useable Function and insert it into the
 * various places it needs to be inserted.
 */
ir.Function buildFunction(Location loc, ir.TopLevelBlock tlb, ir.Scope _scope, string name, bool buildBody = true)
{
	auto fn = buildFunction(loc, _scope, name, buildBody);

	// Insert the struct into all the places.
	_scope.addFunction(fn, fn.name);
	tlb.nodes ~= fn;
	return fn;
}

ir.Function buildGlobalConstructor(Location loc, ir.TopLevelBlock tlb, ir.Scope _scope, string name, bool buildBody = true)
{
	auto fn = buildFunction(loc, tlb, _scope, name, buildBody);
	fn.kind = ir.Function.Kind.GlobalConstructor;
	return fn;
}

/**
 * Builds a alias from a string and a Identifier.
 */
ir.Alias buildAliasSmart(Location loc, string name, ir.Identifier i)
{
	auto a = new ir.Alias();
	a.name = name;
	a.location = loc;
	a.id = buildQualifiedNameSmart(i);
	return a;
}

/**
 * Builds a alias from two strings.
 */
ir.Alias buildAlias(Location loc, string name, string from)
{
	auto a = new ir.Alias();
	a.name = name;
	a.location = loc;
	a.id = buildQualifiedName(loc, from);
	return a;
}

/**
 * Builds a completely useable struct and insert it into the
 * various places it needs to be inserted.
 *
 * The members list is used directly in the new struct; be wary not to duplicate IR nodes.
 */
ir.Struct buildStruct(Location loc, ir.TopLevelBlock tlb, ir.Scope _scope, string name, ir.Variable[] members...)
{
	auto s = new ir.Struct();
	s.name = name;
	s.myScope = new ir.Scope(_scope, s, name);
	s.location = loc;

	s.members = new ir.TopLevelBlock();
	s.members.location = loc;

	foreach (member; members) {
		s.members.nodes ~= member;
		s.myScope.addValue(member, member.name);
	}

	// Insert the struct into all the places.
	_scope.addType(s, s.name);
	tlb.nodes ~= s;
	return s;
}

/**
 * Builds an IR complete, but semantically unfinished struct. i.e. it has no scope and isn't inserted anywhere.
 * The members list is used directly in the new struct; be wary not to duplicate IR nodes.
 */
ir.Struct buildStruct(Location loc, string name, ir.Variable[] members...)
{
	auto s = new ir.Struct();
	s.name = name;
	s.location = loc;

	s.members = new ir.TopLevelBlock();
	s.members.location = loc;

	foreach (member; members) {
		s.members.nodes ~= member;
	}

	return s;
}

/**
 * Add a variable to a pre-built struct.
 */
void addVarToStructSmart(ir.Struct _struct, ir.Variable var)
{
	assert(var.name != "");
	auto cvar = buildVariableSmart(var.location, var.type, ir.Variable.Storage.Field, var.name);
	_struct.members.nodes ~= cvar;
	_struct.myScope.addValue(cvar, cvar.name);
}

/**
 * If t is a class, or a typereference to a class, returns the
 * class. Otherwise, returns null.
 */
ir.Class getClass(ir.Type t)
{
	auto asClass = cast(ir.Class) t;
	if (asClass !is null) {
		return asClass;
	}
	auto asTR = cast(ir.TypeReference) t;
	if (asTR is null) {
		return null;
	}
	asClass = cast(ir.Class) asTR.type;
	return asClass;
}

ir.Type buildStaticArrayTypeSmart(Location loc, size_t length, ir.Type base)
{
	auto sa = new ir.StaticArrayType();
	sa.location = loc;
	sa.length = length;
	sa.base = copyTypeSmart(loc, base);
	return sa;
}

ir.Type buildAATypeSmart(Location loc, ir.Type key, ir.Type value)
{
	auto aa = new ir.AAType();
	aa.location = loc;
	aa.key = copyTypeSmart(loc, key);
	aa.value = copyTypeSmart(loc, value);
	return aa;
}

/*
 * Functions who takes the location from the given exp.
 */
ir.Unary buildCastSmart(ir.Type type, ir.Exp exp) { return buildCastSmart(exp.location, type, exp); }
ir.Unary buildAddrOf(ir.Exp exp) { return buildAddrOf(exp.location, exp); }
ir.Unary buildCastToBool(ir.Exp exp) { return buildCastToBool(exp.location, exp); }

ir.Type buildSetType(Location loc, ir.Function[] functions)
{
	assert(functions.length > 0);
	if (functions.length == 1) {
		return functions[0].type;
	}

	auto set = new ir.FunctionSetType();
	set.location = loc;
	set.set = cast(ir.FunctionSet) buildSet(loc, functions);
	assert(set.set !is null);
	assert(set.set.functions.length > 0);
	return set;
}

ir.Declaration buildSet(Location loc, ir.Function[] functions, ir.ExpReference eref = null)
{
	assert(functions.length > 0);
	if (functions.length == 1) {
		return functions[0];
	}

	auto set = new ir.FunctionSet();
	set.functions = functions;
	set.location = loc;
	set.reference = eref;
	assert(set.functions.length > 0);
	return set;
}

ir.Type stripStorage(ir.Type type)
{
	auto storage = cast(ir.StorageType) type;
	while (storage !is null) {
		type = storage.base;
		storage = cast(ir.StorageType) type;
	}
	return type;
}

ir.Type deepStripStorage(ir.Type type)
{
	auto ptr = cast(ir.PointerType) type;
	if (ptr !is null) {
		ptr.base = deepStripStorage(ptr.base);
		return ptr;
	}

	auto arr = cast(ir.ArrayType) type;
	if (arr !is null) {
		arr.base = deepStripStorage(arr.base);
		return arr;
	}

	auto aa = cast(ir.AAType) type;
	if (aa !is null) {
		aa.value = deepStripStorage(aa.value);
		aa.key = deepStripStorage(aa.key);
		return aa;
	}

	auto ct = cast(ir.CallableType) type;
	if (ct !is null) {
		ct.ret = deepStripStorage(ct.ret);
		foreach (ref param; ct.params) {
			param = deepStripStorage(param);
		}
		return ct;
	}

	auto storage = cast(ir.StorageType) type;
	if (storage !is null) {
		storage.base = stripStorage(storage.base);
		return storage.base;
	}

	return type;
}

/// Returns the base of consecutive pointers. e.g. 'int***' returns 'int'.
ir.Type realBase(ir.PointerType ptr)
{
	ir.Type base;
	do {
		base = ptr.base;
		ptr = cast(ir.PointerType) base;
	} while (ptr !is null);
	return base;
}

ir.IdentifierExp buildIdentifierExp(Location loc, string name)
{
	auto iexp = new ir.IdentifierExp();
	iexp.location = loc;
	iexp.value = name;
	return iexp;
}

/// Build a with statement that has no block.
ir.WithStatement buildWithStatement(Location loc, ir.Exp exp)
{
	auto ws = new ir.WithStatement();
	ws.location = loc;
	ws.exp = exp;
	return ws;
}

ir.TokenExp buildTokenExp(Location loc, ir.TokenExp.Type type)
{
	auto texp = new ir.TokenExp(type);
	texp.location = loc;
	return texp;
}

/// Build a simple index for loop. for (i = 0; i < length; ++i)
void buildForStatement(Location loc, LanguagePass lp, ir.Scope parent, ir.Exp length, out ir.ForStatement forStatement, out ir.Variable ivar)
{
	forStatement = new ir.ForStatement();
	forStatement.location = loc;

	ivar = buildVariable(loc, buildSizeT(loc, lp), ir.Variable.Storage.Function, "i", buildConstantSizeT(loc, lp, 0));
	forStatement.initVars ~= ivar;
	forStatement.test = buildBinOp(loc, ir.BinOp.Op.Less, buildExpReference(loc, ivar, ivar.name), copyExp(length));
	forStatement.increments ~= buildIncrement(loc, buildExpReference(loc, ivar, ivar.name));
	forStatement.block = buildBlockStat(loc, forStatement, parent);
}

void addStorage(ir.Type dest, ir.Type src)
{
	if (dest is null || src is null) {
		return;
	}
	if (!dest.isConst) dest.isConst = src.isConst;
	if (!dest.isImmutable) dest.isImmutable = src.isImmutable;
	if (!dest.isScope) dest.isScope = src.isScope;
}

void insertInPlace(ref ir.Node[] list, size_t index, ir.Node node)
{
	version (Volt) {
		assert(false);
	} else {
		list = list[0 .. index] ~ node ~ list[index .. $];
	}
}
