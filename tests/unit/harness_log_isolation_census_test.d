// A test that spawns the runner must isolate both host-owned channels (4920).
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
// WHY A CENSUS AND NOT POINT FIXES. Several spawn sites are harmless TODAY
// because they pass only meta flags (`--print-scratch`, `--check-space`,
// `--sweep-plan`), which return before the log or lock is reached. But which
// exits reach those channels is a property of run_test.d, not of these tests:
// moving either point one block earlier — an ordinary refactor — would silently
// poison the host record or contend on the production lock. So the rule is the
// blunt one, enumerated rather than merely stated: a test file that both names
// the runner and spawns a process must neutralise both channels.
//
// SATISFYING IT: set VIBE3D_HARNESS_LOG in the spawn's environment, either to
// "off" or to a scratch path the test owns, and set
// VIBE3D_PERF_RUNTEST_LOCK_PATH to a test-owned path. The load-log test owns
// both files because it exists to read the record and exercise real flock.
//
// MUTATION: drop either environment seam from a runner-spawning file and this
// test names that file. Empty the detected spawn-site list and only the
// population floor keeps the two universal checks from passing vacuously.
module tests.unit.harness_log_isolation_census_test;

import std.algorithm : sort;
import std.file      : dirEntries, SpanMode, exists, readText;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode;

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

// Runner references may legitimately be argv literals, but a spawn verb must
// be executable D code. Scanning the code projection keeps source-inspection
// tests from becoming launch sites merely because their fixtures quote a call.
private bool hasSpawnCall(string txt)
{
    return mentionsAny(blankNonCode(txt), kSpawnVerbs);
}

private bool runsRunner(string txt)
{
    return mentionsAny(txt, kRunnerRefs) && hasSpawnCall(txt);
}

unittest
{
    enum unsafeRunnerSpawn = q{
        enum runnerPath = "run_test.d";
        auto child = spawnProcess(["rdmd", runnerPath]);
    };
    assert(runsRunner(unsafeRunnerSpawn),
        "the census no longer recognises an actual runner process-spawn call");

    const displayTest = readText(buildPath(repoRoot, "tests", "unit",
        "run_test_display_environment_test.d"));
    assert(mentionsAny(displayTest, kSpawnVerbs),
        "the display source-scan no longer contains the quoted spawn fixture");
    assert(!hasSpawnCall(displayTest),
        "run_test_display_environment_test.d only inspects quoted spawn "
      ~ "fixtures; it must not be classified as launching the runner");

    const testDirs = [buildPath(repoRoot, "tests"),
                      buildPath(repoRoot, "tests", "unit")];

    string[] spawnSites;
    string[] logOffenders;
    string[] lockOffenders;

    foreach (dir; testDirs)
    {
        if (!exists(dir)) continue;
        foreach (e; dirEntries(dir, "*.d", SpanMode.shallow))
        {
            const name = baseName(e.name);
            if (name == "harness_log_isolation_census_test.d") continue;

            string txt;
            try { txt = readText(e.name); } catch (Exception) { continue; }

            if (!runsRunner(txt)) continue;

            spawnSites ~= name;
            if (txt.indexOf("VIBE3D_HARNESS_LOG") < 0)
                logOffenders ~= name;
            if (txt.indexOf("VIBE3D_PERF_RUNTEST_LOCK_PATH") < 0)
                lockOffenders ~= name;
        }
    }

    sort(spawnSites);
    sort(logOffenders);
    sort(lockOffenders);

    assert(logOffenders.length == 0, format(
        "these test files spawn run_test.d without neutralising the host's load "
      ~ "log: %s\n"
      ~ "A runner spawned by a test is not this host's load. Its record lands in "
      ~ "~/.local/state/vibe3d/harness.jsonl and tools/local/harness-report.py "
      ~ "counts it as a real invocation — see this file's header for the case "
      ~ "that actually happened. Fix: put VIBE3D_HARNESS_LOG in the spawn's "
      ~ "environment, either \"off\" or a scratch path the test owns.",
        logOffenders));

    assert(lockOffenders.length == 0, format(
        "these test files spawn run_test.d without neutralising the production "
      ~ "run lock: %s\n"
      ~ "A runner spawned by a test must use a lock path owned by that test; "
      ~ "otherwise `dub test --config=tests` can wait up to 600 seconds behind "
      ~ "the real suite/perf lock before reaching the condition its witness "
      ~ "exists to test. Fix: put VIBE3D_PERF_RUNTEST_LOCK_PATH in the spawn's "
      ~ "environment and point it at test-owned storage.",
        lockOffenders));

    // The census must not pass by finding nothing to census. If the detection
    // above ever stops matching — a renamed helper, a new spawn idiom — this
    // population floor says so beside the two universal assertions, instead of
    // letting both pass green over an empty set.
    assert(spawnSites.length >= 4, format(
        "expected at least 4 test files that spawn the runner, found %d (%s). "
      ~ "Either the spawn sites moved or the detection above no longer matches "
      ~ "them — an empty census passes for the wrong reason.",
        spawnSites.length, spawnSites));
}
