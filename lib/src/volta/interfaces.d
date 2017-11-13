/*#D*/
// Copyright © 2012-2017, Jakob Bornecrantz.  All rights reserved.
// See copyright notice in src/volt/license.d (BOOST ver. 1.0).
module volta.interfaces;

import ir = volta.ir;


/*!
 * @defgroup ifaces Interfaces
 * @breif Common interfaces between various parts of the compiler.
 *
 */

/*!
 * A set of version/debug identifiers.
 *
 * @ingroup ifaces
 */
final class VersionSet
{
public:
	bool debugEnabled;

	//! These are always set
	enum string[] defaultVersions = [
		"all",
		"Volt",
	];

	enum string[] reservedVersions = [
		// Generic
		"all",
		"none",
		"Volt",
		// Arch
		"X86",
		"X86_64",
		"LE32",
		// Platforms
		"Posix",
		"Windows",
		// Targets
		"OSX",
		"MSVC",
		"Linux",
		"MinGW",
		"Solaris",
		"FreeBSD",
		"Standalone",
		"Emscripten",
		// Misc
		"V_P32",
		"V_P64",
		// C runtime flags
		"CRuntime_All",
		"CRuntime_Any",
		"CRuntime_None",
		"CRuntime_Glibc",
		"CRuntime_Bionic",
		"CRuntime_Microsoft",
	];

private:
	//! If the ident exists and is true, it's set, if false it's reserved.
	bool[string] mVersionIdentifiers;
	//! If the ident exists, it's set.
	bool[string] mDebugIdentifiers;


public:
	this()
	{
		foreach (r; reservedVersions) {
			reserveVersionIdentifier(r);
		}

		foreach (d; defaultVersions) {
			overwriteVersionIdentifier(d);
		}
	}

	//! Throws: Exception if ident is reserved.
	final bool setVersionIdentifierIfNotReserved(string ident)
	{
		if (auto p = ident in mVersionIdentifiers) {
			if (!(*p)) {
				return false;
			}
		}
		mVersionIdentifiers[ident] = true;
		return true;
	}

	//! Doesn't throw on ident reserve.
	final void overwriteVersionIdentifier(string ident)
	{
		mVersionIdentifiers[ident] = true;
	}

	//! Doesn't throw, debug identifiers can't be reserved.
	final void setDebugIdentifier(string ident)
	{
		mDebugIdentifiers[ident] = true;
	}

	/*!
	 * Check if a given version identifier is set.
	 * Params:
	 *   ident = the identifier to check.
	 * Returns: true if set, false otherwise.
	 */
	final bool isVersionSet(string ident)
	{
		if (auto p = ident in mVersionIdentifiers) {
			return *p;
		} else {
			return false;
		}
	}

	/*!
	 * Check if a given debug identifier is set.
	 * Params:
	 *   ident = the identifier to check.
	 * Returns: true if set, false otherwise.
	 */
	final bool isDebugSet(string ident)
	{
		return (ident in mDebugIdentifiers) !is null;
	}

	/*!
	 * Quick helpers to get version flags.
	 * @{
	 */
	@property bool isP64() { return isVersionSet("V_P64"); }
	/*!
	 * @}
	 */


private:
	//! Marks an identifier as unable to be set. Doesn't set the identifier.
	final void reserveVersionIdentifier(string ident)
	{
		mVersionIdentifiers[ident] = false;
	}
}

/*!
 * @defgroup passes Passes
 * @brief Volt transforms code by running multiple 'passes' that mutate the code.
 */

/*!
 * Interface implemented by transformation, debug and/or validation passes.
 *
 * Transformation passes often lowers high level Volt IR into something
 * that is easier for backends to handle.
 *
 * Validation passes validates the Volt IR, and reports errors, often halting
 * compilation by throwing CompilerError.
 *
 * @ingroup passes ifaces
 */
interface Pass
{
	//! Free resources.
	void close();

	//! Run the pass on the given module.
	void transform(ir.Module m);
}
