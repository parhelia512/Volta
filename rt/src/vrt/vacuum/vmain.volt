// Copyright © 2012-2016, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module vrt.vacuum.vmain;

import core.exception: Throwable;
import core.typeinfo: TypeInfo;
import core.rt.gc: vrt_gc_init, allocDg, vrt_gc_get_alloc_dg, vrt_gc_shutdown;
import core.rt.misc: vrt_run_global_ctors, vrt_run_global_dtors, vrt_panic;



extern(C) fn vrt_run_main(argc: i32, argv: char**, vmain: fn (string[]) int) i32
{

	// Currently all the init that is needed for the GC.
	vrt_gc_init();
	allocDg = vrt_gc_get_alloc_dg();

	args := new string[](argc);
	foreach (i, ref arg; args) {
		arg = unsafeToString(argv[i]);
	}

	ret: i32;
	try {
		vrt_run_global_ctors();
		ret = vmain(args);
		vrt_run_global_dtors();
	} catch (Throwable t) {
		// For lack of T.classinfo
		ti := **cast(TypeInfo[]**)t;
		msgs: char[][3];
		msgs[0] = cast(char[])"Uncaught exception";
		msgs[1] = cast(char[])ti[ti.length - 1].mangledName;
		msgs[2] = cast(char[])t.msg;

		vrt_panic(cast(char[][])msgs, t.throwLocation);
	}

	vrt_gc_shutdown();

	return ret;
}

fn unsafeToString(str: const(char)*) string
{
	start := str;
	while (*str) {
		str++;
	}
	len := cast(size_t)str - cast(size_t)start;
	return (cast(immutable(char)*)start)[0 .. len];
}
