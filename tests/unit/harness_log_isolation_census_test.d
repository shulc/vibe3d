// A test that spawns the runner must not write to this host's load log (3260).
//
// THE DEFECT THIS CLOSES, found by the log itself on the day it was added.
// `run_test_space_preflight_test.d` mounts a 16 MiB tmpfs and invokes
// `rdmd run_test.d selection` against it — deliberately "exactly as a caller
// would, no diagnostic flags" — to prove the disk preflight refuses. That
// synthetic refusal was appended to ~/.local/state/vibe3d/harness.jsonl and
// read back by tools/local/harness-report.py as a real invocation that
// produced no verdict. Every `dub test --config=tests` in every lane would
// have added one, and the count it inflates —"invocations that ran nothing" —
// is one of the report's headline numbers. An instrument measuring its own
// test suite reports a defect that does not exist.
//
// WHY A CENSUS AND NOT THREE FIXES. Three of the four spawn sites are harmless
// TODAY because they pass only meta flags (`--print-scratch`, `--check-space`,
// `--sweep-plan`), which return before the log is armed. But "which exits
// log" is a property of run_test.d, not of these tests: moving the arm point
// one block earlier — an ordinary refactor — would silently re-poison the
// record with no test anywhere going red. So the rule is the blunt one, and
// it is enumerated rather than merely stated: a test file that both names the
// runner and spawns a process must neutralise the log.
//
// SATISFYING IT: set VIBE3D_HARNESS_LOG in the spawn's environment, either to
// "off" or to a scratch path the test owns. tests/test_harness_load_log.d does
// the latter, because it exists to read back what a run writes.
//
// MUTATION: drop `env["VIBE3D_HARNESS_LOG"] = "off";` from any of the three
// helpers, or the `VIBE3D_HARNESS_LOG=off` from the preflight test's witness
// script, and this test names that file.
module harness_log_isolation_census_test;

import std.algorithm : canFind, sort;
import std.array     : array;
import std.exception : enforce;
import std.file      : dirEntries, SpanMode, exists, readText;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;
import std.string    : indexOf;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

// The spawn verbs a D test can reach a subprocess through. `executeShell` and
// `spawnShell` are included even though no current site uses them: the point
// of a census is the site nobody has written yet.
private static immutable string[] kSpawnVerbs = [
    "execute(", "executeShell(", "spawnProcess(", "spawnShell(", "pipeProcess(",
];

// The runner AS A COMMAND, not as prose. A bare `run_test.d` matches six files
// that only mention it in a header comment ("run this with ./run_test.d
// test_tool_sticky") and happen to call `execute` for something else entirely —
// measured, when this census was first written with the loose predicate. So the
// reference must be the identifier a test binds the runner to, a quoted argv
// element, or an rdmd command line.
private static immutable string[] kRunnerRefs = [
    "runnerPath", `"./run_test.d"`, `"run_test.d"`, "rdmd run_test.d", "rdmd %s",
];

private bool mentionsAny(string txt, const string[] needles)
{
    foreach (n; needles) if (txt.indexOf(n) >= 0) return true;
    return false;
}

unittest
{
    const testDirs = [buildPath(repoRoot, "tests"),
                      buildPath(repoRoot, "tests", "unit")];

    string[] offenders;
    string[] covered;

    foreach (dir; testDirs)
    {
        if (!exists(dir)) continue;
        foreach (e; dirEntries(dir, "*.d", SpanMode.shallow))
        {
            const name = baseName(e.name);
            if (name == "harness_log_isolation_census_test.d") continue;

            string txt;
            try { txt = readText(e.name); } catch (Exception) { continue; }

            if (!mentionsAny(txt, kRunnerRefs)) continue;
            if (!mentionsAny(txt, kSpawnVerbs)) continue;   // names it, never runs it

            if (txt.indexOf("VIBE3D_HARNESS_LOG") >= 0) covered ~= name;
            else                                        offenders ~= name;
        }
    }

    sort(offenders);
    sort(covered);

    assert(offenders.length == 0, format(
        "these test files spawn run_test.d without neutralising the host's load "
      ~ "log: %s\n"
      ~ "A runner spawned by a test is not this host's load. Its record lands in "
      ~ "~/.local/state/vibe3d/harness.jsonl and tools/local/harness-report.py "
      ~ "counts it as a real invocation — see this file's header for the case "
      ~ "that actually happened. Fix: put VIBE3D_HARNESS_LOG in the spawn's "
      ~ "environment, either \"off\" or a scratch path the test owns.",
        offenders));

    // The census must not pass by finding nothing to census. If the detection
    // above ever stops matching — a renamed helper, a new spawn idiom — this
    // assert is what says so, instead of a green run over an empty set.
    enforce(covered.length >= 4, format(
        "expected at least 4 test files that spawn the runner, found %d (%s). "
      ~ "Either the spawn sites moved or the detection above no longer matches "
      ~ "them — an empty census passes for the wrong reason.",
        covered.length, covered));
}
