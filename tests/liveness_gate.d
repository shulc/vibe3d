/// liveness_gate.d — a test binary that executes NOTHING must not exit 0.
///
/// WHY THIS EXISTS (task 1111). Druntime's default `--DRT-testmode` is
/// `test-or-main`: `runModuleUnitTests()` counts how many MODULES ran unittests
/// and then sets `runMain = (executed == 0)`. So if ANY module linked into the
/// binary carries a `unittest` block, druntime runs the unittests, prints
/// "N modules passed unittests", **skips `main` entirely**, and exits 0.
///
/// `run_test.d` compiles EVERY `tests/*_helpers.d` into EVERY test binary, and
/// links a `-unittest` build of the project's own source into the source-backed
/// ones. A `unittest` block in any of those is therefore enough to silence the
/// `main` of every test that links it — and the result LOOKS like a pass. It
/// happened: one shared helper disarmed fourteen scenarios of one suite for a
/// whole build, and the suite stayed green.
///
/// The rule this module enforces is by SYMPTOM, not by cause: a test binary
/// must execute either at least one unittest OF ITS OWN MODULE, or at least one
/// counted `scenario()`. Otherwise it dies with exit code 3 and names the
/// modules whose unittests took `main`'s place. That covers the known cause and
/// the ones nobody has met yet — an early `return` in `main`, a commented-out
/// body, a future runtime rule — because it asks "did anything run?" instead of
/// "is the one construction we know about present?".
///
/// It is deliberately paired with, and not replaced by, the build-time barrier
/// in `run_test.d` (`gateViolations`). The barrier sees causes this module
/// cannot: "`main` has a body" is a fact about TEXT, and from inside the
/// process an empty `main` and a `main` that was never called are the same
/// thing. Conversely this module fires under any runner, on any branch, for
/// reasons the barrier has never heard of. Two instruments, two blind spots,
/// on purpose.
///
/// IMPLEMENTATION CONSTRAINTS, both measured:
///   * the check runs from an `atexit` handler, i.e. AFTER druntime has shut
///     down. The GC is gone by then: a first version built its diagnostic in
///     GC memory and segfaulted (exit 139). The message therefore lives in the
///     C heap and the handler is `nothrow @nogc`.
///   * the module walk must visit ALL modules, not just the ones carrying
///     unittests. "Did I find my own module?" and "does my own module carry
///     unittests?" are two independent facts, and a loop that skips
///     unittest-less modules can only ever answer the second.
module liveness_gate;

import core.stdc.stdio  : fflush, fprintf, stderr;
import core.stdc.stdlib : atexit, _Exit, malloc;

private enum size_t kDiagCap = 4096;

private __gshared int   g_scenarios;
private __gshared bool  g_ownFound;
private __gshared bool  g_ownHasUnittest;
private __gshared char* g_diag;          // C heap: outlives druntime shutdown

/// Count one attempted scenario. Call it FIRST inside the test's own runner
/// closure, before the case can throw: an attempt that fails is still an
/// attempt, and "it ran and failed" is reported by the test's own exit code,
/// not by this gate. `name` is there so the call site reads as a declaration
/// of what ran; only the count is load-bearing.
void scenario(string name) nothrow {
    cast(void) name;
    g_scenarios++;
}

private extern(C) void livenessCheck() nothrow @nogc {
    if (g_ownHasUnittest || g_scenarios > 0) return;
    fprintf(stderr,
        "\nLIVENESS FAILURE: this test binary executed ZERO scenarios and none of\n"
        ~ "its OWN unittests, yet was about to exit successfully.\n"
        ~ "%s\n"
        ~ "Druntime skips main() as soon as any linked module runs unittests, so a\n"
        ~ "unittest block in a shared tests/*_helpers.d — or in project source linked\n"
        ~ "with -unittest — silences the main() of every test that links it.\n"
        ~ "Put the scenarios in this file's own unittest blocks, or count them with\n"
        ~ "liveness_gate.scenario().\n",
        g_diag ? g_diag : cast(char*) "");
    // Insurance only, and it is not what the corresponding test pins: druntime
    // flushes stdout in its own main wrapper, BEFORE returning into C's exit()
    // and therefore before this handler runs. Measured on a redirected (fully
    // buffered) stdout — the victim's output is on disk with or without this
    // line. One line is worth not having to re-derive that.
    fflush(null);
    _Exit(3);
}

shared static this() {
    import core.runtime : Runtime;
    import std.path : baseName, stripExtension;

    // The runner names each binary `baseName(source).stripExtension` and execs
    // it under that very argv[0]; a module with no `module` declaration takes
    // its name from its file's base name alone. So argv[0] identifies our own
    // module. If it ever does not, say so loudly (exit 4) rather than guessing
    // wrong quietly — a gate that silently mis-identifies its subject is the
    // failure this whole module exists to prevent.
    string own = Runtime.args.length ? stripExtension(baseName(Runtime.args[0])) : "";

    char* buf = cast(char*) malloc(kDiagCap);
    size_t n = 0;
    void put(const(char)[] s) nothrow @nogc {
        if (buf is null) return;
        foreach (c; s) if (n + 1 < kDiagCap) buf[n++] = c;
        buf[n] = '\0';
    }

    put("modules carrying unittests in this binary: ");
    bool any = false;
    foreach (m; ModuleInfo) {
        if (m is null) continue;
        immutable bool hasUnittest = (m.unitTest !is null);
        if (m.name == own) {
            g_ownFound       = true;
            g_ownHasUnittest = hasUnittest;
            continue;
        }
        if (!hasUnittest) continue;
        if (any) put(", ");
        put(m.name);
        any = true;
    }
    if (!any) put("(none)");
    g_diag = buf;

    if (!g_ownFound) {
        fprintf(stderr,
            "\nLIVENESS GATE: cannot identify my own module from argv[0] ('%.*s').\n"
            ~ "The gate cannot tell whether this binary ran anything, so it refuses to\n"
            ~ "let it report success. Name the binary after its test source file.\n",
            cast(int) own.length, own.ptr);
        _Exit(4);
    }

    atexit(&livenessCheck);
}
