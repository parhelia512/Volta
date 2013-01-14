// Copyright © 2012, Bernard Helyer.  All rights reserved.
// Copyright © 2012, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volt.visitor.print;

import std.stdio : writefln, writef;
import std.stream : Stream, File, FileMode;
import std.cstream : dout;

import volt.token.token;

import volt.exceptions;
import volt.interfaces;

import ir = volt.ir.ir;
import volt.visitor.visitor;


void printVisitor(ir.Module m)
{
	auto pv = new PrintVisitor();
	accept(m, pv);
}

class PrintVisitor : Visitor, Pass, Backend
{
protected:
	string mFilename;
	Stream mStream;

	int mIndent;
	string mIndentText;
	string mStartText;

public:
	this(string startText = null, string indentText = "\t")
	{
		mIndentText = indentText;
		mStartText = startText;
	}

	void close()
	{
		mFilename = null;
		assert(mStream is null);
		assert(mFilename is null);
	}


	/*
	 *
	 * Pass functions.
	 *
	 */


	void transform(ir.Module m)
	in {
		assert(mStream is null);
		assert(mFilename is null);
	}
	body {
		assert(mStream is null);
		assert(mFilename is null);

		mStream = dout;
		if (mStartText != null)
			mStream.writefln(mStartText);
		accept(m, this);
		mStream.writefln();
		mStream = null;
	}


	/*
	 *
	 * Backend.
	 *
	 */


	TargetType[] supported()
	{
		return [TargetType.VoltCode];
	}

	void setTarget(string filename, TargetType type)
	in {
		assert(mStream is null);
		assert(mFilename is null);
		assert(type == TargetType.VoltCode);
	}
	body {
		if (type != TargetType.VoltCode)
			throw new Exception("Unsupported target type");

		mFilename = filename;
	}

	void compile(ir.Module m)
	in {
		assert(mStream is null);
		assert(mFilename !is null);
	}
	body {
		scope(exit)
			mFilename = null;

		mStream = new File(mFilename, FileMode.OutNew);
		scope(exit) {
			mStream.flush();
			mStream.close();
			mStream = null;
		}

		accept(m, this);
	}


	/*
	 *
	 * Root
	 *
	 */

	override Status visit(ir.Identifier i)
	{
		wf(i.value);
		return Continue;
	}

	override Status visit(ir.QualifiedName qname)
	{
		if (qname.leadingDot) {
			wf(".");
		}
		foreach (i, ident; qname.identifiers) {
			accept(ident, this);
			if (i < qname.identifiers.length - 1) {
				wf(".");
			}
		}
		return Continue;
	}


	override Status enter(ir.Module m)
	{
		twf("module ");
		wf(m.name);
		wfln(";");

		return Continue;
	}

	override Status leave(ir.Module m)
	{
		return Continue;
	}

	override Status enter(ir.TopLevelBlock tlb) { return Continue; }
	override Status leave(ir.TopLevelBlock tlb) { return Continue; }

	override Status enter(ir.Import i)
	{
		twf("import ");
		if (i.bind !is null) {
			accept(i.bind, this);
			wf(" = ");
		}
		accept(i.name, this);
		if (i.aliases.length > 0) {
			wf(" : ");
			foreach (idx, _alias; i.aliases) {
				accept(_alias[0], this);
				if (_alias[1] !is null) {
					wf(" = ");
					accept(_alias[1], this);
				}
				if (idx < i.aliases.length - 1) {
					wf(", ");
				}
			}
		}

		wfln(";");
		return ContinueParent;
	}

	override Status leave(ir.Import i)
	{
		assert(false);
	}

	override Status enter(ir.Unittest u)
	{
		ln();
		twf("unittest {");
		ln();
		mIndent++;

		return Continue;
	}

	override Status leave(ir.Unittest u)
	{
		mIndent--;
		twfln("}");

		return Continue;
	}

	override Status enter(ir.Class c)
	{
		ln();
		twf("class ", c.name);
		if (c.parent !is null || c.interfaces.length > 0) {
			wf(" : ");
			wf(c.parent);
			foreach (i, _interface; c.interfaces) {
				wf(", ");
				wf(_interface);
			}
		}
		ln();

		twf("{\n");
		mIndent++;
		foreach (member; c.members.nodes) {
			accept(member, this);
		}
		mIndent--;
		twf("}\n");

		return ContinueParent;
	}

	override Status leave(ir.Class c)
	{
		assert(false);
	}

	override Status enter(ir._Interface i)
	{
		ln();
		twf("interface ", i.name);
		if (i.interfaces.length > 0) {
			wf(" : ");
			foreach (j, _interface; i.interfaces) {
				if (j > 0) {
					wf(", ");
				}
				wf(_interface);
			}
		}
		ln();

		twf("{\n");
		mIndent++;
		foreach (member; i.members.nodes) {
			accept(member, this);
		}
		mIndent--;
		twf("}\n");

		return ContinueParent;
	}

	override Status leave(ir._Interface i)
	{
		assert(false);
	}

	override Status enter(ir.Struct s)
	{
		ln();
		twf("struct ");
		wf(s.name);
		ln();
		twf("{");
		ln();
		mIndent++;

		foreach (member; s.members.nodes) {
			accept(member, this);
		}

		mIndent--;
		twf("}\n");

		return ContinueParent;
	}

	override Status leave(ir.Struct s)
	{
		return Continue;
	}

	override Status enter(ir.Variable d)
	{
		twf("");
		accept(d.type, this);
		wf(" ");
		wf(d.name);
		if (d.assign !is null) {
			wf(" = ");
			accept(d.assign, this);
		}
		wfln(";");
		return ContinueParent;
	}

	override Status leave(ir.Variable d)
	{
		return Continue;
	}

	override Status enter(ir.Enum e)
	{
		ln();
		twf("enum");
		if (e.name.length > 0) {
			wf(" ", e.name);
		}
		if (e.base !is null) {
			wf(" : ");
			accept(e.base, this);
		}
		ln();
		twfln("{");
		mIndent++;
		foreach (member; e.members) {
			twf(member.name);
			if (member.init !is null) {
				wf(" = ");
				accept(member.init, this);
			}
			wfln(",");
		}
		mIndent--;
		twfln("}");

		return ContinueParent;
	}

	override Status leave(ir.Enum e)
	{
		assert(false);
	}

	override Status enter(ir.Attribute attr)
	{
		ln();
		final switch (attr.kind) with (ir.Attribute.Kind) {
		case Synchronized: twf("synchronized"); break;
		case Static: twf("static"); break;
		case Scope: twf("scope"); break;
		case Public: twf("public"); break;
		case Protected: twf("protected"); break;
		case Shared: twf("shared"); break;
		case Private: twf("private"); break;
		case Package: twf("package"); break;
		case Override: twf("override"); break;
		case Local: twf("local"); break;
		case LinkageC: twf("extern(C)"); break;
		case LinkageCPlusPlus: twf("extern(C++)"); break;
		case LinkageD: twf("extern(D)"); break;
		case LinkageVolt: twf("extern(Volt)"); break;
		case LinkageWindows: twf("extern(Windows)"); break;
		case LinkagePascal: twf("extern(Pascal)"); break;
		case LinkageSystem: twf("extern(System)"); break;
		case Inout: twf("inout"); break;
		case Immutable: twf("immutable"); break;
		case Global: twf("global"); break;
		case Final: twf("final"); break;
		case Extern: twf("extern"); break;
		case Export: twf("export"); break;
		case Disable: twf("@disable"); break;
		case Deprecated: twf("deprecated"); break;
		case Const: twf("const"); break;
		case Auto: twf("auto"); break;
		case Abstract: twf("abstract"); break;
		case Align:
			twf("align(");
			wf(attr.alignAmount);
			wf(")");
			break;
		}

		wfln(" {");
		mIndent++;
		foreach (member; attr.members.nodes) {
			accept(member, this);
		}
		mIndent--;
		twfln("}");

		return ContinueParent;
	}

	override Status leave(ir.Attribute attr)
	{
		assert(false);
	}

	override Status enter(ir.StaticAssert sa)
	{
		ln();
		twf("static assert(");
		accept(sa.exp, this);
		if (sa.message !is null) {
			wf(", ");
			accept(sa.message, this);
		}
		wfln(");");
		return ContinueParent;
	}

	override Status leave(ir.StaticAssert sa)
	{
		assert(false);
	}

	override Status visit(ir.EmptyTopLevel empty)
	{
		twfln("\n;");
		return Continue;
	}

	override Status enter(ir.Condition c)
	{
		final switch (c.kind) with (ir.Condition.Kind) {
		case Version:
			twf("version (", c.identifier, ")");
			break;
		case Debug:
			twf("debug");
			if (c.identifier.length > 0) {
				wf(" (", c.identifier, ")");
			}
			break;
		case StaticIf:
			twf("static if(");
			accept(c.exp, this);
			wf(")");
			break;
		}
		return ContinueParent;
	}

	override Status leave(ir.Condition c)
	{
		assert(false);
	}

	override Status enter(ir.ConditionTopLevel ctl)
	{
		ln();
		accept(ctl.condition, this);
		wfln(" {");
		mIndent++;
		foreach (member; ctl.members.nodes) {
			accept(member, this);
		}
		mIndent--;
		twf("}");
		if (ctl.elsePresent) {
			wfln(" else {");
			mIndent++;
			foreach (member; ctl._else.nodes) {
				accept(member, this);
			}
			mIndent--;
			twfln("}");
		} else {
			ln();
		}
		return ContinueParent;
	}

	override Status leave(ir.ConditionTopLevel ctl)
	{
		assert(false);
	}

	/*
	 *
	 * Statement Nodes.
	 *
	 */

	override Status enter(ir.ExpStatement e)
	{
		twf("");
		accept(e.exp, this);
		wfln(";");
		return ContinueParent;
	}

	override Status leave(ir.ExpStatement e)
	{
		assert(false);
	}

	override Status enter(ir.ReturnStatement ret)
	{
		twf("return ");
		return Continue;
	}

	override Status leave(ir.ReturnStatement ret)
	{
		wfln(";");
		return Continue;
	}

	override Status enter(ir.BlockStatement b)
	{
		twf("{");
		ln();
		mIndent++;
		return Continue;
	}

	override Status leave(ir.BlockStatement b)
	{
		mIndent--;
		twf("}");
		ln();
		return Continue;
	}

	override Status enter(ir.AsmStatement a)
	{
		twf("asm {");
		ln();
		mIndent++;
		twf("");
		foreach (token; a.tokens) {
			if (token.type == TokenType.Semicolon) {
				wf(";");
				ln();
				twf("");
			} else {
				wf(" ");
				wf(token.value);
			}
		}
		ln();
		mIndent--;
		twf("}");

		return ContinueParent;
	}

	override Status leave(ir.AsmStatement a)
	{
		return Continue;
	}

	override Status enter(ir.IfStatement i)
	{
		twf("if ");
		wf("(");
		if (i.autoName.length > 0) {
			wf("auto ");
			wf(i.autoName);
			wf(" = ");
		}
		accept(i.exp, this);
		wf(") {");
		mIndent++;
		ln();
		internalPrintBlock(i.thenState);
		mIndent--;
		twf("}");
		if (i.elseState !is null) {
			wf(" else {");
			mIndent++;
			ln();
			internalPrintBlock(i.elseState);
			mIndent--;
			twf("}");
		}
		ln();
		return ContinueParent;
	}

	override Status leave(ir.IfStatement i)
	{
		assert(false);
	}

	override Status enter(ir.WhileStatement w)
	{
		twf("while ");
		wf("(");
		accept(w.condition, this);
		wf(") {");
		mIndent++;
		ln();
		internalPrintBlock(w.block);
		mIndent--;
		twf("}");
		ln();
		return ContinueParent;
	}

	override Status leave(ir.WhileStatement w)
	{
		assert(false);
	}

	override Status enter(ir.DoStatement d)
	{
		twf("do {");
		mIndent++;
		ln();
		internalPrintBlock(d.block);
		mIndent--;
		twf("} while (");
		accept(d.condition, this);
		wf(");");
		ln();

		return ContinueParent;
	}

	override Status leave(ir.DoStatement d)
	{
		assert(false);
	}

	override Status enter(ir.ForStatement f)
	{
		twf("for (");

		auto oldIndent = mIndent;
		mIndent = 0;

		if (f.initExps.length > 0) {
			foreach (index, i; f.initExps) {
				accept(i, this);
				if (index < f.initExps.length - 1) {
					wf(", ");
				}
			}
		} else if (f.initVars.length > 0) {
			auto asDecl = f.initVars[0];
			assert(asDecl !is null);
			accept(asDecl.type, this);
			wf(" ");
			foreach (i, d; f.initVars) {
				wf(d.name);
				if (d.assign !is null) {
					wf(" = ");
					accept(d.assign, this);
				}
				if (i < f.initVars.length - 1) {
					wf(", ");
				}
			}
		}
		wf(";");
		if (f.test !is null) {
			wf(" ");
			accept(f.test, this);
		}
		wf(";");
		if (f.increments.length > 0) {
			wf(" ");
			foreach (i, increment; f.increments) {
				accept(increment, this);
				if (i < f.increments.length - 1) {
					wf(", ");
				}
			}
		}
		wf(") {");
		mIndent = oldIndent + 1;
		ln();

		internalPrintBlock(f.block);

		mIndent--;
		twf("}");
		ln();
		return ContinueParent;
	}

	override Status leave(ir.ForStatement f)
	{
		assert(false);
	}

	override Status enter(ir.SwitchStatement ss)
	{
		if (ss.isFinal) {
			twf("final switch (");
		} else {
			twf("switch (");
		}
		accept(ss.condition, this);
		wfln(") {");

		return Continue;
	}

	override Status leave(ir.SwitchStatement ss)
	{
		twf("}");

		return Continue;
	}

	override Status enter(ir.SwitchCase sc)
	{
		if (sc.isDefault) {
			twfln("default:");
		} else {
			twf("case ");
			if (sc.firstExp !is null && sc.secondExp is null) {
				accept(sc.firstExp, this);
				wfln(":");
			} else if (sc.firstExp !is null && sc.secondExp !is null) {
				accept(sc.firstExp, this);
				wf(": .. case ");
				accept(sc.secondExp, this);
				wfln(":");
			} else if (sc.exps.length > 0) {
				foreach (i, exp; sc.exps) {
					accept(exp, this);
					if (i < sc.exps.length - 1) {
						wf(", ");
					}
				}
				wfln(":");
			} else {
				throw CompilerPanic(sc.location, "unknown case type passed to PrintVisitor.");
			}
		}
		mIndent++;
		foreach (statement; sc.statements) {
			accept(statement, this);
			if (statement.nodeType == ir.NodeType.Variable) {
				// Ew.
				ln();
			}
		}
		mIndent--;

		return Continue;
	}

	override Status leave(ir.SwitchCase sc)
	{
		return Continue;
	}

	override Status enter(ir.LabelStatement ls)
	{
		wf(ls.label ~ ":");
		ln();
		return Continue;
	}

	override Status leave(ir.LabelStatement ls)
	{
		return Continue;
	}

	override Status visit(ir.ContinueStatement cs)
	{
		twf("continue");
		if (cs.label.length > 0) {
			wf(" ");
			wf(cs.label);
		}
		wfln(";");

		return Continue;
	}

	override Status visit(ir.BreakStatement bs)
	{
		twf("break");
		if (bs.label.length > 0) {
			wf(" ");
			wf(bs.label);
		}
		wfln(";");

		return Continue;
	}

	override Status enter(ir.GotoStatement gs)
	{
		twf("goto ");
		if (gs.label.length > 0) {
			wf(gs.label);
		} else if (gs.isDefault) {
			wf("default");
		} else if (gs.isCase) {
			wf("case");
			if (gs.exp !is null) {
				wf(" ");
				accept(gs.exp, this);
			}
		} else {
			throw CompilerPanic(gs.location, "malformed goto statement made it to PrintVisitor.");
		}
		wfln(";");

		return ContinueParent;
	}

	override Status leave(ir.GotoStatement gs)
	{
		assert(false);
	}

	override Status enter(ir.WithStatement ws)
	{
		twf("with (");
		accept(ws.exp, this);
		wfln(") {");
		mIndent++;
		internalPrintBlock(ws.block);
		mIndent--;
		twfln("}");

		return ContinueParent;
	}

	override Status leave(ir.WithStatement ws)
	{
		assert(false);
	}

	override Status enter(ir.SynchronizedStatement ss)
	{
		twf("synchronized ");
		if (ss.exp !is null) {
			wf("(");
			accept(ss.exp, this);
			wf(") ");
		}
		wfln("{");
		mIndent++;
		internalPrintBlock(ss.block);
		mIndent--;
		twfln("}");

		return ContinueParent;
	}

	override Status leave(ir.SynchronizedStatement ss)
	{
		assert(false);
	}

	override Status enter(ir.TryStatement ts)
	{
		twfln("try {");
		mIndent++;
		internalPrintBlock(ts.tryBlock);
		mIndent--;
		twf("} ");
		if (ts.catchBlock !is null) {
			wf("catch(");
			if (ts.catchType !is null) {
				accept(ts.catchType, this);
				wf(" ");
				wf(ts.catchName);
			}
			wfln(") {");
			mIndent++;
			internalPrintBlock(ts.catchBlock);
			mIndent--;
			twf("} ");
		}

		if (ts.finallyBlock !is null) {
			wfln("finally {");
			mIndent++;
			internalPrintBlock(ts.finallyBlock);
			mIndent--;
			twf("}");
		}

		ln();

		return ContinueParent;
	}


	override Status leave(ir.TryStatement ts)
	{
		assert(false);
	}

	override Status enter(ir.ThrowStatement ts)
	{
		twf("throw ");
		accept(ts.exp, this);
		wfln(";");
		return ContinueParent;
	}

	override Status leave(ir.ThrowStatement ts)
	{
		assert(false);
	}

	override Status enter(ir.ScopeStatement ss)
	{
		twf("scope (");
		final switch (ss.kind) with (ir.ScopeStatement.Kind) {
		case Exit: wfln("exit) {"); break;
		case Success: wfln("success) {"); break;
		case Failure: wfln("failure) {"); break;
		}
		mIndent++;
		internalPrintBlock(ss.block);
		mIndent--;
		twfln("}");
		return ContinueParent;
	}

	override Status leave(ir.ScopeStatement ss)
	{
		assert(false);
	}

	override Status enter(ir.PragmaStatement ps)
	{
		twf("pragma(");
		wf(ps.type);
		if (ps.arguments.length > 0) {
			foreach (i, arg; ps.arguments) {
				if (i < ps.arguments.length - 1) {
					wf(", ");
				}
				accept(arg, this);
			}
		}
		wfln(") {");
		mIndent++;
		internalPrintBlock(ps.block);
		mIndent--;
		twfln("}");
		return ContinueParent;
	}

	override Status leave(ir.PragmaStatement ps)
	{
		assert(false);
	}

	override Status visit(ir.EmptyStatement es)
	{
		twfln(";");
		return Continue;
	}

	override Status enter(ir.ConditionStatement cs)
	{
		accept(cs.condition, this);

		wfln(" {");
		mIndent++;
		internalPrintBlock(cs.block);
		mIndent--;
		twf("}");

		if (cs._else !is null) {
			wfln(" else {");
			mIndent++;
			internalPrintBlock(cs._else);
			mIndent--;
			twfln("}");
		} else {
			ln();
		}

		return ContinueParent;
	}

	override Status leave(ir.ConditionStatement cs)
	{
		assert(false);
	}

	/*
	 *
	 * Declarations.
	 *
	 */

	override Status enter(ir.PointerType pointer)
	{
		accept(pointer.base, this);
		wf("*");
		return ContinueParent;
	}

	override Status leave(ir.PointerType pointer)
	{
		return Continue;
	}

	override Status enter(ir.ArrayType array)
	{
		accept(array.base, this);
		wf("[]");
		return ContinueParent;
	}

	override Status leave(ir.ArrayType array)
	{
		return Continue;
	}

	override Status enter(ir.StaticArrayType array)
	{
		accept(array.base, this);
		wf("[");
		wf(array.length);
		wf("]");
		return ContinueParent;
	}

	override Status leave(ir.StaticArrayType array)
	{
		return Continue;
	}

	override Status enter(ir.AAType array)
	{
		accept(array.value, this);
		wf("[");
		accept(array.key, this);
		wf("]");
		return ContinueParent;
	}

	override Status enter(ir.FunctionType fn)
	{
		accept(fn.ret, this);
		wf(" function(");
		foreach (i, param; fn.params) {
			accept(param.type, this);
			wf(" ");
			wf(param.name);
			//if (param.name.length > 0) {

			//}
			if (i < fn.params.length - 1) {
				wf(", ");
			}
		}
		wf(")");
		return ContinueParent;
	}

	override Status leave(ir.FunctionType fn)
	{
		return Continue;
	}

	override Status enter(ir.DelegateType fn)
	{
		accept(fn.ret, this);
		wf(" delegate(");
		foreach (i, param; fn.params) {
			accept(param.type, this);
			if (param.name.length > 0) {
				wf(" ");
				wf(param.name);
			}
			if (i < fn.params.length - 1) {
				wf(", ");
			}
		}
		wf(")");
		return ContinueParent;
	}

	override Status leave(ir.DelegateType fn)
	{
		return Continue;
	}

	override Status leave(ir.AAType array)
	{
		return Continue;
	}
	
	override Status enter(ir.Function fn)
	{
		ln();
		twf("");

		final switch(fn.kind) with (ir.Function.Kind) {
		case LocalMember:
			wf("local ");
			goto case Member;
		case GlobalMember:
			wf("local ");
			goto case Member;
		case Function:
		case Member:
			accept(fn.type.ret, this);
			wf(" ");
			wf(fn.mangledName);
			wf("(");
			break;
		case Constructor:
			wf("this(");
			break;
		case Destructor:
			wf("~this(");
			break;
		case LocalConstructor:
			wf("local this(");
			break;
		case LocalDestructor:
			wf("local ~this(");
			break;
		case GlobalConstructor:
			wf("global this(");
			break;
		case GlobalDestructor:
			wf("global ~this(");
			break;
		}

		foreach (i, param; fn.type.params) {
			accept(param.type, this);
			if (param.name.length > 0) {
				wf(" ");
				wf(param.name);
			}
			if (i < fn.type.params.length - 1) {
				wf(", ");
			}
		}
		wf(")");

		void printNodes(ir.Node[] nodes)
		{
			mIndent++;
			foreach (node; nodes) {
				accept(node, this);
			}
			mIndent--;
		}

		if (fn.inContract !is null) {
			ln();
			twfln("in {");
			printNodes(fn.inContract.statements);
			ln();
			twfln("}");
		}

		if (fn.outContract !is null) {
			if (fn.outParameter.length > 0) {
				twfln("out (" ~ fn.outParameter ~ ") {");
			} else {
				twfln("out {");
			}
			printNodes(fn.outContract.statements);
			ln();
			twfln("}");
		}

		if (fn._body !is null) {
			if (fn.inContract is null || fn.outContract is null) {
				twfln("body {");
			} else {
				ln();
				twfln("{");
			}

			printNodes(fn._body.statements);

			ln();
			twfln("}");
		} else {
			wfln(";");
		}

		return ContinueParent;
	}

	override Status leave(ir.Function fn)
	{
		return Continue;
	}

	override Status enter(ir.StorageType type)
	{
		final switch (type.type) with (ir.StorageType.Kind) {
		case Auto: wf("auto("); break;
		case Const: wf("const("); break;
		case Immutable: wf("immutable("); break;
		case Inout: wf("inout("); break;
		case Scope: wf("scope("); break;
		}
		if (type.base !is null) {
			accept(type.base, this);
		}
		wf(")");
		return ContinueParent;
	}

	override Status leave(ir.StorageType type)
	{
		assert(false);
	}

	override Status enter(ir.Alias a)
	{
		ln();
		twf("alias ");
		wf(a.name);
		wf(" = ");
		accept(a.type, this);
		wfln(";");
		return ContinueParent;
	}

	override Status leave(ir.Alias a)
	{
		assert(false);
	}

	/*
	 *
	 * Expression Nodes.
	 *
	 */


	override Status visit(ir.Constant constant)
	{
		wf(constant.value);
		return ContinueParent;
	}

	override Status visit(ir.IdentifierExp identifier)
	{
		if (identifier.globalLookup) {
			wf(".");
		}
		wf(identifier.value);
		return Continue;
	}

	override Status enter(ir.ArrayLiteral array)
	{
		wf("[");
		foreach (i, exp; array.values) {
			accept(exp, this);
			if (i < array.values.length - 1) {
				wf(", ");
			}
		}
		wf("]");
		return ContinueParent;
	}

	override Status leave(ir.ArrayLiteral array)
	{
		return Continue;
	}

	override Status enter(ir.AssocArray array)
	{
		wf("[");
		foreach (i, ref pair; array.pairs) {
			accept(pair.key, this);
			wf(":");
			accept(pair.value, this);
			if (i < array.pairs.length - 1) {
				wf(", ");
			}
		}
		wf("]");
		return ContinueParent;
	}

	override Status leave(ir.AssocArray array)
	{
		return Continue;
	}

	override Status enter(ir.Assert _assert)
	{
		wf("assert(");
		accept(_assert.condition, this);
		if (_assert.message !is null) {
			wf(", ");
			accept(_assert.message, this);
		}
		wf(")");
		return ContinueParent;
	}

	override Status leave(ir.Assert _assert)
	{
		return Continue;
	}

	override Status enter(ir.StringImport strimport)
	{
		wf("import(");
		accept(strimport.filename, this);
		wf(")");
		return ContinueParent;
	}

	override Status leave(ir.StringImport strimport)
	{
		return Continue;
	}

	override Status enter(ir.Ternary ternary)
	{
		accept(ternary.condition, this);
		wf(" ? ");
		accept(ternary.ifTrue, this);
		wf(" : ");
		accept(ternary.ifFalse, this);
		return ContinueParent;
	}

	override Status leave(ir.Ternary ternary)
	{
		return Continue;
	}

	override Status enter(ir.BinOp binop)
	{
		wf("(");

		accept(binop.left, this);

		switch (binop.op) {
		case ir.BinOp.Type.Assign: wf(" = "); break;
		case ir.BinOp.Type.AddAssign: wf(" += "); break;
		case ir.BinOp.Type.SubAssign: wf(" -= "); break;
		case ir.BinOp.Type.MulAssign: wf(" *= "); break;
		case ir.BinOp.Type.DivAssign: wf(" /= "); break;
		case ir.BinOp.Type.ModAssign: wf(" %= "); break;
		case ir.BinOp.Type.AndAssign: wf(" &= "); break;
		case ir.BinOp.Type.OrAssign: wf(" |= "); break;
		case ir.BinOp.Type.XorAssign: wf(" ^= "); break;
		case ir.BinOp.Type.CatAssign: wf(" ~= "); break;
		case ir.BinOp.Type.LSAssign: wf(" <<= "); break;
		case ir.BinOp.Type.SRSAssign: wf(" >>= "); break;
		case ir.BinOp.Type.RSAssign: wf(" >>>= "); break;
		case ir.BinOp.Type.PowAssign: wf(" ^^= "); break;
		case ir.BinOp.Type.OrOr: wf(" || "); break;
		case ir.BinOp.Type.AndAnd: wf(" && "); break;
		case ir.BinOp.Type.Or: wf(" | "); break;
		case ir.BinOp.Type.Xor: wf(" ^ "); break;
		case ir.BinOp.Type.And: wf(" & "); break;
		case ir.BinOp.Type.Equal: wf(" == "); break;
		case ir.BinOp.Type.NotEqual: wf(" != "); break;
		case ir.BinOp.Type.Is: wf(" is "); break;
		case ir.BinOp.Type.NotIs: wf(" !is "); break;
		case ir.BinOp.Type.Less: wf(" < "); break;
		case ir.BinOp.Type.LessEqual: wf(" <= "); break;
		case ir.BinOp.Type.GreaterEqual: wf(" >= "); break;
		case ir.BinOp.Type.Greater: wf(" > "); break;
		case ir.BinOp.Type.In: wf(" in "); break;
		case ir.BinOp.Type.NotIn: wf(" !in "); break;
		case ir.BinOp.Type.LS: wf(" << "); break;
		case ir.BinOp.Type.SRS: wf(" >> "); break;
		case ir.BinOp.Type.RS: wf(" >>> "); break;
		case ir.BinOp.Type.Add: wf(" + "); break;
		case ir.BinOp.Type.Sub: wf(" - "); break;
		case ir.BinOp.Type.Cat: wf(" ~ "); break;
		case ir.BinOp.Type.Mul: wf(" * "); break;
		case ir.BinOp.Type.Div: wf(" / "); break;
		case ir.BinOp.Type.Mod: wf(" % "); break;
		case ir.BinOp.Type.Pow: wf(" ^^ "); break;
		default: assert(false);
		}

		accept(binop.right, this);

		wf(")");

		return ContinueParent;
	}

	override Status leave(ir.BinOp binop)
	{
		return Continue;
	}

	override Status enter(ir.Unary unary)
	{
		switch (unary.op) {
		case ir.Unary.Op.AddrOf: wf("&"); break;
		case ir.Unary.Op.Increment: wf("++"); break;
		case ir.Unary.Op.Decrement: wf("--"); break;
		case ir.Unary.Op.Dereference: wf("*"); break;
		case ir.Unary.Op.Minus: wf("-"); break;
		case ir.Unary.Op.Plus: wf("+"); break;
		case ir.Unary.Op.Not: wf("!"); break;
		case ir.Unary.Op.Complement: wf("~"); break;
		case ir.Unary.Op.Cast:
			wf("cast(");
			accept(unary.type, this);
			wf(")");
			break;
		case ir.Unary.Op.New:
			wf("new ");
			accept(unary.type, this);
			if (unary.hasArgumentList) {
				wf("(");
				foreach (i, arg; unary.argumentList) {
					accept(arg, this);
					if (i < unary.argumentList.length - 1) {
						wf(", ");
					}
					wf(")");
				}
			}
			break;
		default: assert(false);
		}

		if (unary.value !is null) {
			accept(unary.value, this);
		}

		return ContinueParent;
	}

	override Status leave(ir.Unary unary)
	{
		assert(false);
	}

	override Status leave(ir.Postfix postfix)
	{
		assert(false);
	}

	override Status enter(ir.Postfix postfix)
	{
		accept(postfix.child, this);
		switch (postfix.op) {
		case ir.Postfix.Op.Identifier:
			wf(".");
			wf(postfix.identifier.value);
			break;
		case ir.Postfix.Op.Increment:
			wf("++");
			break;
		case ir.Postfix.Op.Decrement:
			wf("--");
			break;
		case ir.Postfix.Op.Index:
			wf("[");
			foreach (i, arg; postfix.arguments) {
				accept(arg, this);
				if (i < postfix.arguments.length - 1) {
					wf(", ");
				}
			}
			wf("]");
			break;
		case ir.Postfix.Op.Slice:
			wf("[");
			switch (postfix.arguments.length) {
			case 0:
				break;
			case 1:
				accept(postfix.arguments[0], this);
				break;
			case 2:
				accept(postfix.arguments[0], this);
				wf("..");
				accept(postfix.arguments[1], this);
				break;
			default:
				throw CompilerPanic(postfix.location, "bad slice.");
			}
			wf("]");
			break;
		case ir.Postfix.Op.Call:
			wf("(");
			foreach (i, arg; postfix.arguments) {
				accept(arg, this);
				if (i < postfix.arguments.length - 1) {
					wf(", ");
				}
			}
			wf(")");
			break;
		case ir.Postfix.Op.CreateDelegate:
			wf(".");
			wf(postfix.identifier.value);
			break;
		default:
			throw CompilerPanic(postfix.location, "tried to print bad postfix expression.");
		}

		return ContinueParent;
	}

	override Status enter(ir.Typeid ti)
	{
		wf("typeid(");
		if (ti.exp !is null) {
			accept(ti.exp, this);
		} else {
			accept(ti.type, this);
		}
		wf(")");
		return ContinueParent;
	}

	override Status leave(ir.Typeid ti)
	{
		assert(false);
	}

	override Status enter(ir.IsExp isExp)
	{
		wf("is(");
		accept(isExp.type, this);
		if (isExp.identifier.length > 0) {
			wf(" ", isExp.identifier);
		}
		if (isExp.compType != ir.IsExp.Comparison.None) {
			if (isExp.compType == ir.IsExp.Comparison.Implicit) {
				wf(" : ");
			} else {
				assert(isExp.compType == ir.IsExp.Comparison.Exact);
				wf(" == ");
			}
			final switch (isExp.specialisation) with (ir.IsExp.Specialisation) {
			case None:
				assert(false);
			case Type:
				assert(isExp.specType !is null);
				accept(isExp.specType, this);
				break;
			case Struct: wf("struct"); break;
			case Union: wf("union"); break;
			case Class: wf("class"); break;
			case Interface: wf("interface"); break;
			case Function: wf("function"); break;
			case Enum: wf("enum"); break;
			case Delegate: wf("delegate"); break;
			case Super: wf("super"); break;
			case Const: wf("const"); break;
			case Immutable: wf("immutable"); break;
			case Inout: wf("inout"); break;
			case Shared: wf("shared"); break;
			case Return: wf("return"); break;
			}
		}
		wf(")");
		return ContinueParent;
	}

	override Status leave(ir.IsExp isExp)
	{
		assert(false);
	}

	override Status enter(ir.FunctionLiteral functionLiteral)
	{
		void printParams() {
			foreach (i, param; functionLiteral.params) {
				accept(param.type, this);
				if (param.name.length > 0) {
					wf(" ", param.name);
				}
				if (i < functionLiteral.params.length - 1) {
					wf(", ");
				}
			}
		}

		if (functionLiteral.lambdaExp !is null) {
			if (functionLiteral.singleLambdaParam.length > 0) {
				wf(functionLiteral.singleLambdaParam);
			} else {
				wf("(");
				printParams();
				wf(")");
			}
			wf(" => ");
			accept(functionLiteral.lambdaExp, this);
			return ContinueParent;
		}

		if (functionLiteral.isDelegate) {
			wf("delegate ");
		} else {
			wf("function ");
		}

		if (functionLiteral.returnType !is null) {
			accept(functionLiteral.returnType, this);
		}
		wf("(");
		printParams();
		wfln(") {");
		mIndent++;
		foreach (statement; functionLiteral.block.statements) {
			accept(statement, this);
		}
		mIndent--;
		twf("}");

		return ContinueParent;
	}

	override Status leave(ir.FunctionLiteral functionLiteral)
	{
		assert(false);
	}

	override Status enter(ir.StructLiteral sliteral)
	{
		wf("{ ");
		foreach (i, exp; sliteral.exps) {
			accept(exp, this);
			if (i < sliteral.exps.length - 1) {
				wf(", ");
			}
		}
		wf("}");

		return ContinueParent;
	}

	override Status leave(ir.StructLiteral sliteral)
	{
		assert(false);
	}

	override Status visit(ir.ExpReference e)
	{ 
		if (e.idents.length > 1) for (int i = cast(int)e.idents.length - 1; i > 0; --i) {
			wf(e.idents[i]);
			if (i > 1) {
				wf(".");
			}
		} else if (e.idents.length == 1) {
			wf(e.idents[0]);
		}
		return Continue; 
	}

	/*
	 *
	 * Base stuff.
	 *
	 */

	override Status debugVisitNode(ir.Node n)
	{
		return Continue;
	}

	override Status visit(ir.PrimitiveType type)
	{
		wf(tokenToString[type.type]);
		return Continue;
	}

	override Status visit(ir.TypeReference tr)
	{
		foreach (i, name; tr.names) {
			wf(name);
			if (i < tr.names.length - 1) {
				wf(".");
			}
		}
		return Continue;
	}


	/*
	 *
	 * Helper functions.
	 *
	 */


protected:
	void internalPrintBlock(ir.BlockStatement bs)
	{
		foreach (statement; bs.statements) {
			accept(statement, this);
			if (statement.nodeType == ir.NodeType.Variable) {
				ln();
			}
		}
	}

	void wf(ir.QualifiedName qn)
	{
		if (qn.leadingDot)
			wf(".");
		wf(qn.identifiers[0].value);

		foreach(id; qn.identifiers[1 .. $]) {
			wf(".");
			wf(id.value);
		}
	}

	void twf(string[] strings...)
	{
		for(int i; i < mIndent; i++)
			mStream.writef(mIndentText);
		foreach (s; strings) {
			mStream.writef(s);
		}
	}

	void twfln(string[] strings...)
	{
		foreach (s; strings) {
			twf(s);
			mStream.writefln();
		}
	}

	void wf(string[] strings...)
	{
		foreach (s; strings) {
			mStream.writef(s);
		}
	}

	void wf(size_t i) { mStream.writef("%s", i); }
	void wfln(string str) { wf(str); mStream.writefln(); }
	void ln() { mStream.writefln(); }
}
