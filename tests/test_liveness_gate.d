/// test_liveness_gate.d — the permanent mutation test for task 1111.
///
/// Both halves of that task are gates, and a gate's failure mode is a GREEN
/// result: if either one stops working, nothing anywhere goes red on its own.
/// So each half is exercised here against a fixture that is DESIGNED to trip
/// it, plus a control that must NOT trip it — a case that can only ever pass
/// is not a check.
///
///   * the SYMPTOM half (tests/liveness_gate.d) is exercised by compiling
///     throwaway .d files with dmd, running them, and reading their exit codes;
///   * the CAUSE half (run_test.d's gateViolations) is exercised through
///     `./run_test.d --check-gate <dir>` over a temp directory of fixtures.
///
/// The barrier fixtures go into a TEMP directory, never into the live tests/.
/// A file like `test_tmp_bothhalves.d` left behind by a test that was killed
/// mid-run would make the barrier refuse to build the WHOLE suite.
///
/// What this file does NOT cover, stated rather than implied: that
/// gateViolations is actually CALLED at the start of an ordinary run. Covering
/// that would mean standing up a copy of the repository. It was demonstrated
/// once by hand; if it ever rots, the symptom half still fires.
///
/// This test's own scenarios live in `unittest` blocks — which is the very rule
/// it enforces — so `main` is empty and druntime runs the blocks.
module test_liveness_gate;

import std.conv    : to;
import std.file    : exists, mkdirRecurse, rmdirRecurse, readText, write, copy,
                     setAttributes, getAttributes, tempDir;
import std.format  : format;
import std.path    : buildPath;
import std.process : executeShell;
import std.stdio   : writeln;
import std.string  : indexOf;

void main() {}

// ---------------------------------------------------------------------------
// Fixture plumbing
// ---------------------------------------------------------------------------

private __gshared int g_tmpSeq;

private string freshTmpDir(string tag) {
    string d;
    do {
        d = buildPath(tempDir(), format("vibe3d_liveness_%s_%d", tag, g_tmpSeq++));
    } while (exists(d));
    mkdirRecurse(d);
    return d;
}

/// The real gate module, resolved against the repo root — the cwd every test
/// binary inherits from the runner.
private string gateModule() { return buildPath("tests", "liveness_gate.d"); }

private struct Ran { int status; string output; }

/// Compile `srcs` into `dir/name` and return the binary path, asserting the
/// compile succeeded (a compile error here would otherwise read as a gate
/// verdict).
private string buildBin(string dir, string name, string[] srcs) {
    import std.array : join;
    const bin = buildPath(dir, name);
    const cmd = format("dmd -unittest -od=%s %s -of=%s 2>&1", dir, srcs.join(" "), bin);
    auto r = executeShell(cmd);
    assert(r.status == 0, "fixture failed to compile: " ~ cmd ~ "\n" ~ r.output);
    assert(exists(bin), "fixture compiled but produced no binary: " ~ bin);
    return bin;
}

// executeShell captures stdout AND stderr into `output`, which is what these
// cases read the diagnosis out of.
private Ran run(string bin) {
    auto r = executeShell(bin);
    return Ran(r.status, r.output);
}

// Fixture sources. Kept as literals so each case reads as its own statement of
// what shape is being tested.
private enum kPoisonHelper =
    "module poison_helpers;\n"
  ~ "int shared_helper() { return 7; }\n"
  ~ "unittest { assert(shared_helper() == 7); }\n";

private enum kCleanHelper =
    "module clean_helpers;\n"
  ~ "int shared_helper() { return 7; }\n";

// A test whose scenarios live in main and which has no unittest of its own:
// exactly the nine real ones the runner carries.
private enum kVictimMain =
    "module victim;\n"
  ~ "import std.stdio;\n"
  ~ "import poison_helpers;\n"
  ~ "int main(string[] args) { writeln(\"victim scenario ran\"); return 0; }\n";

// ---------------------------------------------------------------------------
// The SYMPTOM half: tests/liveness_gate.d
// ---------------------------------------------------------------------------

unittest {  // poisoned helper + a victim whose scenarios live in main -> exit 3
    const d = freshTmpDir("poison");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "poison_helpers.d"), kPoisonHelper);
    write(buildPath(d, "victim.d"),         kVictimMain);
    const bin = buildBin(d, "victim",
        [buildPath(d, "victim.d"), buildPath(d, "poison_helpers.d"), gateModule()]);
    auto r = run(bin);
    assert(r.status == 3,
        format("a binary that executed nothing exited %d, expected 3\n%s", r.status, r.output));
    assert(r.output.indexOf("poison_helpers") >= 0,
        "the diagnosis must NAME the module that took main's place:\n" ~ r.output);
    writeln("PASS: poisoned helper makes the victim exit 3 and names the poisoner");
}

unittest {  // control: the SAME fixture without the gate is green — so it is
            // the gate that changed the answer, not the fixture
    const d = freshTmpDir("nogate");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "poison_helpers.d"), kPoisonHelper);
    write(buildPath(d, "victim.d"),         kVictimMain);
    const bin = buildBin(d, "victim",
        [buildPath(d, "victim.d"), buildPath(d, "poison_helpers.d")]);
    auto r = run(bin);
    assert(r.status == 0,
        format("without the gate this fixture should still pass green; got %d\n%s",
               r.status, r.output));
    assert(r.output.indexOf("victim scenario ran") < 0,
        "the premise of this whole task: main must NOT have run:\n" ~ r.output);
    writeln("PASS: without the gate the same binary exits 0 having run nothing");
}

unittest {  // a healthy unittest-carrying test is untouched
    const d = freshTmpDir("healthy");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "clean_helpers.d"), kCleanHelper);
    write(buildPath(d, "healthy.d"),
        "module healthy;\n"
      ~ "import clean_helpers;\n"
      ~ "void main() {}\n"
      ~ "unittest { assert(shared_helper() == 7); }\n");
    const bin = buildBin(d, "healthy",
        [buildPath(d, "healthy.d"), buildPath(d, "clean_helpers.d"), gateModule()]);
    auto r = run(bin);
    assert(r.status == 0,
        format("a test running its OWN unittests must pass the gate; got %d\n%s",
               r.status, r.output));
    writeln("PASS: a test running its own unittests passes the gate");
}

unittest {  // no poison anywhere — main runs, but executes zero scenarios
    const d = freshTmpDir("deadmain");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "deadmain.d"),
        "module deadmain;\n"
      ~ "import std.stdio;\n"
      ~ "int main(string[] args) { return 0; }\n");
    const bin = buildBin(d, "deadmain", [buildPath(d, "deadmain.d"), gateModule()]);
    auto r = run(bin);
    assert(r.status == 3,
        format("a main that ran zero scenarios exited %d, expected 3\n%s", r.status, r.output));
    writeln("PASS: an early-returning main with zero scenarios exits 3");
}

unittest {  // a main that counts a scenario is alive
    const d = freshTmpDir("livemain");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "livemain.d"),
        "module livemain;\n"
      ~ "import std.stdio;\n"
      ~ "import liveness_gate : scenario;\n"
      ~ "int main(string[] args) { scenario(\"only case\"); writeln(\"ok\"); return 0; }\n");
    const bin = buildBin(d, "livemain", [buildPath(d, "livemain.d"), gateModule()]);
    auto r = run(bin);
    assert(r.status == 0,
        format("a main that counted a scenario exited %d, expected 0\n%s", r.status, r.output));
    writeln("PASS: a main that counts one scenario passes the gate");
}

unittest {  // the victim's stdout survives the gate's exit
    // NOTE, honestly: what this pins is druntime's own contract — it flushes
    // stdout in its main wrapper, before returning into C's exit() and thus
    // before our atexit handler. It is green with or without the `fflush(null)`
    // in liveness_gate.d, which is insurance and not the thing under test. The
    // redirect to a FILE is load-bearing: on a tty stdout is line-buffered and
    // the case would pass for the wrong reason.
    const d = freshTmpDir("stdout");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "chatty.d"),
        "module chatty;\n"
      ~ "import std.stdio;\n"
      ~ "int main(string[] args) { writeln(\"chatty got this far\"); return 0; }\n");
    const bin = buildBin(d, "chatty", [buildPath(d, "chatty.d"), gateModule()]);
    const outFile = buildPath(d, "captured.txt");
    auto r = executeShell(format("%s > %s 2>/dev/null", bin, outFile));
    assert(r.status == 3, format("expected exit 3, got %d", r.status));
    assert(exists(outFile), "the redirect produced no file at all");
    const captured = readText(outFile);
    assert(captured.indexOf("chatty got this far") >= 0,
        "the killed binary's buffered stdout was lost — the runner keeps it as "
      ~ "its only evidence of how far a test got. Captured: [" ~ captured ~ "]");
    writeln("PASS: the victim's buffered stdout survives the gate's exit");
}

unittest {  // a binary run under a name that is not its module's -> exit 4
    // This branch is lethal (it would kill ANY test binary), so it must be
    // executed by something, or it is a blade nobody has ever swung.
    const d = freshTmpDir("renamed");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "named_ok.d"),
        "module named_ok;\n"
      ~ "void main() {}\n"
      ~ "unittest { assert(true); }\n");
    const bin = buildBin(d, "named_ok", [buildPath(d, "named_ok.d"), gateModule()]);
    auto ok = run(bin);
    assert(ok.status == 0,
        format("the healthy binary must pass under its own name; got %d\n%s",
               ok.status, ok.output));
    const copyPath = buildPath(d, "renamed_bin");
    copy(bin, copyPath);
    setAttributes(copyPath, getAttributes(bin));
    auto renamed = run(copyPath);
    assert(renamed.status == 4,
        format("a binary that cannot identify its own module exited %d, expected 4\n%s",
               renamed.status, renamed.output));
    assert(renamed.output.indexOf("cannot identify my own module") >= 0,
        "exit 4 must say WHY:\n" ~ renamed.output);
    writeln("PASS: a renamed binary refuses to report success (exit 4)");
}

// ---------------------------------------------------------------------------
// The CAUSE half: run_test.d --check-gate
// ---------------------------------------------------------------------------

private Ran checkGate(string dir) {
    auto r = executeShell(format("./run_test.d --check-gate %s", dir));
    return Ran(r.status, r.output);
}

unittest {  // rule (a): a unittest in an injected helper
    const d = freshTmpDir("rule_a");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "x_helpers.d"),
        "module x_helpers;\n"
      ~ "int f() { return 1; }\n"
      ~ "unittest { assert(f() == 1); }\n");
    auto r = checkGate(d);
    assert(r.status == 2,
        format("rule (a) should refuse; --check-gate exited %d\n%s", r.status, r.output));
    assert(r.output.indexOf("x_helpers.d") >= 0,
        "the refusal must name the offending file:\n" ~ r.output);
    writeln("PASS: barrier rule (a) refuses a unittest in an injected helper");
}

unittest {  // rule (b): a source-backed test with no unittest of its own.
            // The rule is EMPTY over the real tests/ today, which is exactly
            // why it needs a fixture: an empty rule rots green.
    const d = freshTmpDir("rule_b");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "test_tmp_srcbacked.d"),
        "import mesh;\n"
      ~ "import std.stdio;\n"
      ~ "int main(string[] args) { writeln(\"scenario\"); return 0; }\n");
    auto r = checkGate(d);
    assert(r.status == 2,
        format("rule (b) should refuse; --check-gate exited %d\n%s", r.status, r.output));
    assert(r.output.indexOf("test_tmp_srcbacked.d") >= 0,
        "the refusal must name the offending file:\n" ~ r.output);
    writeln("PASS: barrier rule (b) refuses a source-backed test with no own unittest");
}

unittest {  // rule (c): own unittest AND a non-empty main. Also empty over the
            // real tests/ once task 1111's own fix landed.
    const d = freshTmpDir("rule_c");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "test_tmp_bothhalves.d"),
        "import std.stdio;\n"
      ~ "void doThing() { writeln(\"never reached\"); }\n"
      ~ "void main() { doThing(); }\n"
      ~ "unittest { assert(true); }\n");
    auto r = checkGate(d);
    assert(r.status == 2,
        format("rule (c) should refuse; --check-gate exited %d\n%s", r.status, r.output));
    assert(r.output.indexOf("test_tmp_bothhalves.d") >= 0,
        "the refusal must name the offending file:\n" ~ r.output);
    writeln("PASS: barrier rule (c) refuses own-unittest + non-empty main");
}

unittest {  // control: healthy forms of all three shapes -> clean. Without this
            // the three cases above are satisfied by "--check-gate always 2".
    const d = freshTmpDir("rule_ok");
    scope(exit) rmdirRecurse(d);
    write(buildPath(d, "ok_helpers.d"),
        "module ok_helpers;\n"
      ~ "int f() { return 1; }\n");
    write(buildPath(d, "test_tmp_healthy.d"),
        "void main() {}\n"
      ~ "unittest { assert(true); }\n");
    write(buildPath(d, "test_tmp_mainonly.d"),
        "import std.stdio;\n"
      ~ "int main(string[] args) { writeln(\"scenario\"); return 0; }\n");
    auto r = checkGate(d);
    assert(r.status == 0,
        format("healthy fixtures were refused; --check-gate exited %d\n%s", r.status, r.output));
    writeln("PASS: barrier control — healthy forms of all three shapes pass");
}
