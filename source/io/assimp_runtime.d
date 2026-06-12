/// Runtime loader for libassimp (Open Asset Import Library).
///
/// vibe3d's interchange I/O — OBJ / glTF / FBX import & export, plus the
/// LWO-via-assimp import path — runs through the `bindbc-assimp6` dynamic
/// bindings, which `dlopen` the shared library at startup (the same model as
/// SDL2 / OpenGL). The native `.v3d` document format and the pure-D LWO writer
/// do NOT depend on assimp, so a missing library is non-fatal: the editor runs
/// with interchange formats greyed out.
///
/// Release builds bundle libassimp next to the executable (Linux: $ORIGIN;
/// macOS: Contents/Frameworks; Windows: beside the .exe). `initAssimp` tries
/// the bundled library first, then falls back to the system loader search path
/// so a developer build with a distro libassimp also works.
///
/// See doc/asset_io_plan.md, Phase 0.
module io.assimp_runtime;

import std.file   : thisExePath;
import std.path   : dirName, buildPath;
import std.format : format;
import std.string : toStringz, fromStringz;

import bindbc.assimp;
import log : logInfo, logWarn;

private bool g_loaded = false;

/// True once libassimp has loaded. Gate interchange import/export on this;
/// native `.v3d` and the pure-D LWO writer ignore it.
bool isAssimpAvailable() nothrow @nogc { return g_loaded; }

/// Load libassimp once, at startup. Bundled library first, then the system
/// search path. Idempotent; never throws — a missing library just leaves
/// `isAssimpAvailable` false.
void initAssimp() nothrow {
    if (g_loaded) return;

    version (BindAssimp_Static) {
        // Statically linked: assimp's extern(C) symbols are inside this binary,
        // so there is no library to dlopen and no candidate path to probe. The
        // bindbc static config's loadAssimp() is a no-op stub that always
        // reports `loaded`, so the bundled-candidate loop below would falsely
        // claim a bundled path. Just mark available and report the version.
        g_loaded = true;
        try {
            const v = aiGetVersionMajor();
            const mi = aiGetVersionMinor();
            const p = aiGetVersionPatch();
            logInfo("io", format("libassimp %s.%s.%s linked statically", v, mi, p));
        } catch (Exception) {}
        return;
    } else {

    // 1. Library bundled with the application (release builds).
    foreach (cand; bundledCandidates()) {
        if (cand.length == 0) continue;
        if (loadAssimp(cand.toStringz) == AssimpSupport.loaded) {
            g_loaded = true;
            report("bundled", cand);
            return;
        }
        // A candidate that dlopened but failed (e.g. badLibrary: missing
        // symbols) leaves bindbc's internal SharedLib handle set; unload it so
        // the next iteration doesn't overwrite and leak the handle.
        unloadAssimp();
    }

    // 2. System loader search path (distro libassimp, dev hosts).
    if (loadAssimp() == AssimpSupport.loaded) {
        g_loaded = true;
        report("system", null);
        return;
    }

    try logWarn("io",
        "libassimp not found — OBJ/glTF/FBX import/export disabled "
        ~ "(native .v3d and LWO save still work)");
    catch (Exception) {}
    } // version (BindAssimp_Static) else
}

/// Unload libassimp at shutdown. Idempotent.
void shutdownAssimp() nothrow {
    if (!g_loaded) return;
    unloadAssimp();
    g_loaded = false;
}

// ---------------------------------------------------------------------------

/// Candidate paths for a library bundled alongside the executable, most
/// specific first. Returns an empty range if the exe path can't be resolved.
private string[] bundledCandidates() nothrow {
    string dir;
    try dir = thisExePath().dirName;
    catch (Exception) return null;

    try {
        version (linux) {
            return [ buildPath(dir, "libassimp.so.6"),
                     buildPath(dir, "libassimp.so") ];
        } else version (OSX) {
            return [ buildPath(dir, "..", "Frameworks", "libassimp.6.dylib"),
                     buildPath(dir, "libassimp.6.dylib"),
                     buildPath(dir, "libassimp.dylib") ];
        } else version (Windows) {
            return [ buildPath(dir, "assimp.dll"),
                     buildPath(dir, "libassimp.dll") ];
        } else {
            return null;
        }
    } catch (Exception) {
        return null;
    }
}

private void report(string origin, string path) nothrow {
    try {
        const v = aiGetVersionMajor();
        const mi = aiGetVersionMinor();
        const p = aiGetVersionPatch();
        if (path.length)
            logInfo("io", format("libassimp %s.%s.%s loaded (%s: %s)", v, mi, p, origin, path));
        else
            logInfo("io", format("libassimp %s.%s.%s loaded (%s)", v, mi, p, origin));
    } catch (Exception) {}
}
