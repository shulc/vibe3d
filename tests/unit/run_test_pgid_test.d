// The teardown group-kill must never signal the runner's OWN process group
// (task 2001).
//
// THE INCIDENT. Two runs of the same tree, minutes apart, same command
// (`xvfb-run -a -s "-screen 0 1280x960x24" ./run_test.d --no-build -j 8`) on
// the second gate host: both printed a fully green suite summary
// (`Total: 719  Passed: 719  Failed: 0  Timed out: 0`) AFTER 286 modules
// passed unittests — one exited 0, the other exited 137 (SIGKILL). The
// summary is complete and green and prints BEFORE the death, so this is
// teardown, not a test.
//
// ROOT CAUSE, measured with an instrumented `getpgrp()` probe placed at
// `main()`, at every `vibePids`/`testGroupPids` append, and at both
// group-kill sites, run under `xvfb-run` on this host AND on `ai`: under
// `xvfb-run`, neither its own `sh` nor its non-interactive `Xvfb … &`/`"$@"`
// job-control a new process group for what they spawn, so `xvfb-run`'s own
// shell, `Xvfb`, and `run_test.d` itself all inherit ONE shared process
// group — confirmed identical whether `run_test.d` is reached directly or
// through the `bash -c 'echo $$ …; exec ./run_test.d …'` trick
// `tools/local/ai-gate.sh` uses to track its real pid. `cleanup()` and
// `onSignal` each end with a group-wide `kill(-p, SIGKILL)` over every
// recorded test/vibe3d process group with no check that `p` was never OUR
// OWN group — sending SIGKILL there reaches the wrapper (uncatchable) and,
// because this process is a MEMBER of that same group, reaches this process
// too, which is indistinguishable from an external kill.
//
// WHAT WAS NOT FOUND, and is worth recording so nobody re-derives it: a
// `testGroupPids`/`vibePids` entry cannot LEGITIMATELY equal the runner's
// own group by ordinary pid allocation — the group's original member (the
// `xvfb-run` wrapper) stays alive for the runner's whole lifetime, and Linux
// will not hand out a pid that is currently in use as a live process-group
// id, so a freshly `setpgid(0,0)`'d test child's own pid can never collide
// with it while the runner is still running. Two full-scale (`-j 8`, all
// tests) stress runs on `ai` against the UNFIXED code, with the same
// `getpgrp()` instrumentation, did not catch the race in the act either.
// The fix below is unconditionally correct regardless of the exact trigger
// — it closes the entire class of "a recorded group id is our own", not one
// timing window — which is why this test exercises the GUARD directly
// rather than trying to reproduce the race.
//
// WHY THIS IS A BLACK-BOX (subprocess) TEST, following the same discipline
// as `run_test_scratch_test.d`/`run_test_space_preflight_test.d`: this
// project runs `run_test.d` as a standalone rdmd script, never imported as
// a module, and it lives outside `source/`+`tests/unit/`, so it has no
// other home in the `dub test --config=tests` gate (the same reason
// `tools/perf/lib/vslast.d` needed a `dub.json` carve-out — not repeated
// here since `dub.json` is a live lane this task does not touch). Compiling
// `run_test.d` WITH `-unittest` and running the resulting binary directly
// exercises its own `unittest { }` block (which pins `shouldKillGroup`,
// the extracted guard both group-kill sites and `killTestTree` route
// through) without ever reaching the real `main()`: druntime's default
// (non-`--DRT-testmode=run-main`) unittest runner exits after the
// unittest blocks pass, so this never takes the host run-lock, builds
// vibe3d, or spawns anything `run_test.d`'s real invocation would.
module tests.unit.run_test_pgid_test;

import std.exception : collectException, enforce;
import std.file      : exists, remove, tempDir;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.process   : environment, execute, thisProcessID;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");

unittest
{
    enforce(exists(runnerPath), runnerPath ~ " not found — repo root misderived");

    // pid-suffixed so two lanes running `dub test` at once do not clobber
    // each other's binary.
    const outBin = buildPath(tempDir(), format("run_test_pgid_ut_%d", thisProcessID));
    scope(exit) cast(void) collectException(remove(outBin));

    auto build = execute(["dmd", "-unittest", runnerPath, "-of=" ~ outBin]);
    enforce(build.status == 0, format(
        "compiling %s with -unittest failed (status %d):\n%s",
        runnerPath, build.status, build.output));

    // See tests/unit/harness_log_isolation_census_test.d: a runner spawned by a
    // test must not append to this host's load log (task 3260). Harmless here
    // today — druntime runs run_test.d's own unittests and skips main, so no
    // record is written — but "which exits log" is a property of run_test.d,
    // not of this test, and it is not this test's business to depend on it.
    string[string] env;
    foreach (k, v; environment.toAA) env[k] = v;
    env["VIBE3D_HARNESS_LOG"] = "off";
    auto run = execute([outBin], env);
    enforce(run.status == 0, format(
        "%s's own unittest block failed (status %d):\n%s\n" ~
        "This is run_test.d's `shouldKillGroup` witness (task 2001): the " ~
        "teardown group-kill must never signal the runner's own process " ~
        "group, or it can SIGKILL the xvfb-run wrapper it runs under — and " ~
        "this process with it — AFTER a fully green suite summary already " ~
        "printed.",
        runnerPath, run.status, run.output));
}
