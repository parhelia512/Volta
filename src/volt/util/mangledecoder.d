/*#D*/
module volt.util.mangledecoder;

import watt.conv : toInt;
import watt.text.ascii : isDigit;
import watt.text.sink : StringSink;

import ir = volta.ir;
import volta.util.util;
import volta.ir.location;


//! Take the first n characters from s, advance s by n characters, and return the result.
string take(ref string s, size_t n)
{
	assert(s.length >= n);
	auto result = s[0 .. n];
	s = s[n .. $];
	return result;
}

int takeDigit(ref string mangledString)
{
	StringSink numbuf;
	while (mangledString[0].isDigit()) {
		numbuf.sink([mangledString[0]]);
		mangledString = mangledString[1 .. $];
	}
	return toInt(numbuf.toString());
}

ir.Identifier takeNameSegment(ref string mangledString, ref Location loc)
{
	int count = mangledString.takeDigit();

	auto ident = new ir.Identifier();
	ident.loc = loc;
	ident.value = mangledString.take(cast(size_t)count);
	return ident;
}

ir.QualifiedName takeName(ref string mangledString, ref Location loc)
{
	auto qname = new ir.QualifiedName();
	qname.loc = loc;
	while (mangledString[0].isDigit()) {
		qname.identifiers ~= mangledString.takeNameSegment(/*#ref*/loc);
		qname.identifiers[$-1].loc = loc;
	}
	return qname;
}

ir.Declaration mangledToDeclaration(string mangledString, ref Location loc)
{
	auto exportTag = mangledString.take(2);
	auto name = mangledString.takeName(/*#ref*/loc);

	if (exportTag == "Vv") {
		auto var = mangledString.mangledToVariable(/*#ref*/loc);
		var.loc = loc;
		var.name = name.identifiers[$-1].value;
		return var;
	} else if (exportTag == "Vf") {
		auto func = new ir.Function();
		func.loc = loc;
		func.name = name.identifiers[$-1].value;
		func.type = cast(ir.FunctionType) mangledString.mangleToCallable(/*#ref*/loc);
		assert(func.type !is null);
		return func;
	}

	assert(false);
}

ir.Variable mangledToVariable(string mangledString, ref Location loc)
{
	auto var = new ir.Variable();
	var.loc = loc;
	bool isRef;
	if (mangledString[0] == 'r') {
		mangledString.take(1);
		isRef = true;
	}
	var.type = mangledString.mangledToType(/*#ref*/loc);
	if (isRef) {
		auto storage = new ir.StorageType();
		storage.loc = var.type.loc;
		storage.type = ir.StorageType.Kind.Ref;
		storage.base = var.type;
		var.type = storage;
	}
	return var;
}

ir.Type mangledToType(ref string mangledString, ref Location loc)
{
	switch (mangledString.take(1)) {
	case "b":
		return buildByte(/*#ref*/loc);
	case "s":
		return buildShort(/*#ref*/loc);
	case "i":
		return buildInt(/*#ref*/loc);
	case "l":
		return buildLong(/*#ref*/loc);
	case "v":
		return buildVoid(/*#ref*/loc);
	case "c":
		return buildChar(/*#ref*/loc);
	case "d":
		return buildDchar(/*#ref*/loc);
	case "w":
		return buildWchar(/*#ref*/loc);
	case "f":
		switch (mangledString.take(1)) {
		case "f":
			return buildFloat(/*#ref*/loc);
		case "d":
			return buildDouble(/*#ref*/loc);
		case "r":
			return buildReal(/*#ref*/loc);
		default:
			assert(false);
		}
	case "u":
		switch (mangledString.take(1)) {
		case "b":
			return buildUbyte(/*#ref*/loc);
		case "s":
			return buildUshort(/*#ref*/loc);
		case "i":
			return buildUint(/*#ref*/loc);
		case "l":
			return buildUlong(/*#ref*/loc);
		default:
			assert(false);
		}
	case "p":
		return buildPtrSmart(/*#ref*/loc, mangledString.mangledToType(/*#ref*/loc));
	case "a":
		if (mangledString[0] == 't') {
			mangledString.take(1);
			auto length = cast(size_t)mangledString.takeDigit();
			return buildStaticArrayTypeSmart(/*#ref*/loc, length, mangledString.mangledToType(/*#ref*/loc));
		}
		return buildArrayTypeSmart(/*#ref*/loc, mangledString.mangledToType(/*#ref*/loc));
	case "A":
		if (mangledString[0] == 'a') {
			mangledString.take(1);
			ir.Type key = mangledString.mangledToType(/*#ref*/loc);
			ir.Type value = mangledString.mangledToType(/*#ref*/loc);
			return buildAATypeSmart(/*#ref*/loc, key, value);
		} else {
			assert(false, "annotation");
		}
	case "e":
		return buildStorageType(/*#ref*/loc, ir.StorageType.Kind.Scope, mangledString.mangledToType(/*#ref*/loc));
	case "o":
		return buildStorageType(/*#ref*/loc, ir.StorageType.Kind.Const, mangledString.mangledToType(/*#ref*/loc));
	case "m":
		return buildStorageType(/*#ref*/loc, ir.StorageType.Kind.Immutable, mangledString.mangledToType(/*#ref*/loc));
	case "n":
		return buildStorageType(/*#ref*/loc, ir.StorageType.Kind.Immutable, mangledString.mangledToType(/*#ref*/loc));
	case "r":
		assert(false, "ref");
	case "E":
		auto qname = mangledString.takeName(/*#ref*/loc);
		auto _enum = new ir.Enum();
		_enum.loc = loc;
		_enum.name = qname.identifiers[$-1].value;
		return _enum;
	case "C":
		auto qname = mangledString.takeName(/*#ref*/loc);
		auto _class = new ir.Class();
		_class.loc = loc;
		_class.name = qname.identifiers[$-1].value;
		return _class;
	case "S":
		auto qname = mangledString.takeName(/*#ref*/loc);
		auto _struct = new ir.Struct();
		_struct.loc = loc;
		_struct.name = qname.identifiers[$-1].value;
		return _struct;
	case "U":
		auto qname = mangledString.takeName(/*#ref*/loc);
		auto _union = new ir.Union();
		_union.loc = loc;
		_union.name = qname.identifiers[$-1].value;
		return _union;
	case "I":
		auto qname = mangledString.takeName(/*#ref*/loc);
		auto _iface = new ir._Interface();
		_iface.loc = loc;
		_iface.name = qname.identifiers[$-1].value;
		return _iface;
	case "F", "D":
		return mangledString.mangleToCallable(/*#ref*/loc);
	default:
		assert(false);
	}
}

ir.CallableType mangleToCallable(ref string mangledString, ref Location loc)
{
	ir.CallableType ctype;
	auto t = mangledString.take(1);
	if (t == "F") {
		ctype = new ir.FunctionType();
	} else if (t == "D") {
		ctype = new ir.DelegateType();
	} else {
		assert(false);
	}
	ctype.loc = loc;

	auto cc = mangledString.take(1);
	switch (cc) {
	case "v":
		ctype.linkage = ir.Linkage.Volt;
		break;
	case "d":
		ctype.linkage = ir.Linkage.D;
		break;
	case "c":
		ctype.linkage = ir.Linkage.C;
		break;
	case "C":
		ctype.linkage = ir.Linkage.CPlusPlus;
		break;
	case "P":
		ctype.linkage = ir.Linkage.Pascal;
		break;
	case "W":
		ctype.linkage = ir.Linkage.Windows;
		break;
	default:
		assert(false);
	}

	while (mangledString[0] != 'X' && mangledString[0] != 'Y' && mangledString[0] != 'Z') {
		ctype.params ~= mangledString.mangledToType(/*#ref*/loc);
	}

	auto argsclose = mangledString.take(1);
	switch (argsclose) {
	case "X", "Y": ctype.hasVarArgs = true; break;
	case "Z": break;
	default:
		assert(false);
	}

	ctype.ret = mangledString.mangledToType(/*#ref*/loc);

	return ctype;
}
