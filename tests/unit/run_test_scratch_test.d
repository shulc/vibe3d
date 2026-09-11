// The test runner's scratch-tree identity (task 1282).
//
// WHAT WENT WRONG. `run_test.d` named its scratch tree after
// `environment.get("PPID", "0")`, and bash does not EXPORT `PPID`: it is a
// shell variable and `environ` has no entry for it. The lookup therefore missed
// and took its default in every invocation from every checkout — one literal
// `/tmp/vibe3d-tests-0` shared by every lane on the host. Lanes then deleted
// each other's worker directories, and the failure arrived as
// `worker_N: Directory not empty` out of the startup wipe, exiting 1 before a
// single test had run and reading exactly like a red suite.
//
// WHAT IS GATED HERE. The derivation, through the shipped runner, by running
// `run_test.d --print-scratch` from more than one working directory:
//
//   1. two checkouts       → two different paths     (the collision itself)
//   2. one checkout, twice → the same path           (stable across a re-run)
//   3. two checkouts whose LAST TWO path components are identical → still two
//      different paths (the readable slug alone would collide; the hash is
//      what makes the whole path the identity)
//   4. the environment does not enter into it: the same directory with
//      different `PPID` values exported answers the same path, and two
//      directories with the SAME `PPID` exported still answer differently
//
// VERIFIED BY SUBSTITUTION — four derivations put into `scratchDirFor` in turn,
// each one caught, and by a named case rather than by "something changed":
//
//   `environment.get("PPID", "0")`  the shipped defect  → case 1, and the
//                                   message it prints names `/tmp/vibe3d-tests-0`
//   `getppid()`                     the rejected pid    → case 1. Both runs here
//                                   alternative           have the SAME parent —
//                                   which is not an artefact of the harness but
//                                   the shape of one driver (`run_all.d`, an
//                                   agent shell) starting two lanes.
//   `getpid()`                      any per-invocation  → case 2
//                                   key
//   the slug with no hash           → case 3 for two checkouts both named
//                                     `vibe3d`, which is every worktree here
//
// Case 4 is the belt-and-braces one: exported, `PPID` IS visible to
// `environment.get`, so it fails any implementation that went back to reading
// the invoking shell even where the unexported form would have gone unnoticed.
//
// WHAT THIS DOES NOT COVER, and it is most of the interesting part:
//
//   * It is a test of a NAME, not of concurrency. It never starts two runs.
//     That two runs with two names do not collide is arithmetic; that two runs
//     with ONE name do collide was measured by hand, by putting a live writer
//     in the shared tree and running the pre-fix runner against it (the run
//     died with `worker_1: Directory not empty` and SUITE_EXIT=1, and the
//     post-fix runner in the same situation went green and left the other
//     tree alone). None of that is reproduced here: the suite would have to
//     spawn two full runs on one host, which the host-wide run lock exists to
//     prevent.
//   * It says nothing about `prepareScratchDir`'s adoption of a leftover tree
//     (wipe, then park aside when the wipe cannot win, then a pid-suffixed
//     fallback). That path is reached only when a tree is BUSY, which needs a
//     live writer and therefore a second process — also measured by hand, not
//     here.
//   * It cannot see a run that never calls the derivation. It checks what
//     `--print-scratch` answers; that main() then uses that answer is one line
//     of run_test.d away from this file's reach.
module tests.unit.run_test_scratch_test;

import std.algorithm : canFind;
import std.exception : collectException, enforce;
import std.file      : exists, mkdirRecurse, readText, remove, rmdirRecurse, tempDir;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.process   : Config, execute, environment, thisProcessID;
import std.string    : startsWith, strip;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");
private enum scratchRootTestEnv = "VIBE3D_TEST_DEFAULT_SCRATCH_ROOT";

private string runnerLockPath()
{
    return buildPath(tempDir(), format(
        "vibe3d-run-test-scratch-test-%d.lock", thisProcessID));
}

// Ask the shipped runner what scratch directory it would use when run from
// `cwd`, with `extraEnv` added to its environment.
private string askRunner(string cwd, string flag,
                         string[string] extraEnv = null,
                         bool clearTmpDir = false)
{
    string[string] env;
    foreach (k, v; environment.toAA) env[k] = v;
    if (clearTmpDir) env.remove("TMPDIR");
    env.remove(scratchRootTestEnv);
    foreach (k, v; extraEnv)          env[k] = v;
    // A runner spawned BY A TEST is not this host's load: without this the
    // record would land in ~/.local/state/vibe3d/harness.jsonl and be counted
    // by tools/local/harness-report.py as a real invocation (task 3260). It
    // Both isolation seams are set here rather than at each call site so a new
    // case cannot forget; tests/unit/harness_log_isolation_census_test.d
    // refuses a runner spawn that leaves either host-owned channel live.
    env["VIBE3D_HARNESS_LOG"] = "off";
    env["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = runnerLockPath();
    if (flag == "--print-run-lock")
        env.remove("VIBE3D_PERF_RUNTEST_LOCK_PATH");

    auto r = execute(["rdmd", runnerPath, flag],
                     env, Config.none, size_t.max, cwd);
    enforce(r.status == 0, format(
        "`rdmd %s %s` (cwd %s) exited %d:\n%s\n" ~
        "rdmd drives the whole HTTP suite (run_test.d's own shebang), so it " ~
        "being unusable is a broken toolchain, not a reason to skip this check.",
        runnerPath, flag, cwd, r.status, r.output));

    auto path = r.output.strip;
    enforce(path.length, "--print-scratch printed nothing");
    return path;
}

private string askScratch(string cwd, string[string] extraEnv = null,
                          bool clearTmpDir = false)
{
    return askRunner(cwd, "--print-scratch", extraEnv, clearTmpDir);
}

unittest
{
    // This cell intentionally runs before the default-root cell: a default
    // mutation must reach that later red only after this explicit override
    // has demonstrably survived.
    const stem = buildPath(tempDir(), format(
        "vibe3d-scratch-explicit-test-%d", thisProcessID));
    const laneA = buildPath(stem, "alpha", "vibe3d");
    const explicitRoot = buildPath(stem, "explicit-root");
    foreach (d; [laneA, explicitRoot]) mkdirRecurse(d);
    scope(exit) cast(void) collectException(rmdirRecurse(stem));

    const explicitScratch = askScratch(laneA, ["TMPDIR": explicitRoot]);
    assert(explicitScratch.startsWith(buildPath(explicitRoot, "vibe3d-tests-")),
        format("explicit TMPDIR=%s was ignored; --print-scratch returned %s",
               explicitRoot, explicitScratch));
}

unittest
{
    enforce(exists(runnerPath), runnerPath ~ " not found — repo root misderived");
    if (exists(runnerLockPath())) remove(runnerLockPath());
    scope(exit) if (exists(runnerLockPath())) remove(runnerLockPath());

    // Two synthetic checkouts, plus a third whose last two path components are
    // deliberately identical to the second's.
    // pid-suffixed so two lanes running `dub test` at once do not share it.
    const stem = buildPath(tempDir(), format("vibe3d-scratchkey-test-%d", thisProcessID));
    const laneA = buildPath(stem, "alpha", "vibe3d");
    const laneB = buildPath(stem, "beta",  "vibe3d");
    const twinB = buildPath(stem, "elsewhere", "beta", "vibe3d");   // same last two as laneB
    foreach (d; [laneA, laneB, twinB]) mkdirRecurse(d);
    // (a `catch` may not appear inside `scope(exit)`; collectException is the
    //  same swallow written where the compiler accepts it)
    scope(exit) cast(void) collectException(rmdirRecurse(stem));

    const a  = askScratch(laneA, null, true);
    const b  = askScratch(laneB, null, true);
    const a2 = askScratch(laneA, null, true);
    const tb = askScratch(twinB, null, true);

    // 1. Two checkouts, two trees. This is the whole defect: before task 1282
    //    both of these were `/tmp/vibe3d-tests-0`.
    assert(a != b, format(
        "two checkouts share one scratch tree (%s) — the runner is keying on " ~
        "something that is not the checkout, which is how lanes wipe each " ~
        "other's worker directories mid-run", a));

    // 2. Same checkout, same tree. A re-run after a crash must land on the
    //    tree its predecessor left, so it can adopt and clear it; a per-process
    //    key would strand that tree under a name nothing looks at again.
    assert(a == a2, format(
        "the same checkout answered two different scratch trees (%s, %s) — the " ~
        "key is not stable across invocations", a, a2));

    // 3. The readable slug is a convenience; the identity is the whole path.
    assert(b != tb, format(
        "two checkouts whose last two path components match share one scratch " ~
        "tree (%s) — the slug is being used as the identity", b));

    // 4. Nothing from the environment decides this. Both halves fail for any
    //    implementation that reads PPID (or any other exported shell variable)
    //    the way the pre-1282 one meant to.
    const aPpid1 = askScratch(laneA, ["PPID": "111111"], true);
    const aPpid2 = askScratch(laneA, ["PPID": "222222"], true);
    assert(a == aPpid1 && a == aPpid2, format(
        "an exported PPID changed the scratch tree (%s / %s / %s) — the runner " ~
        "is keyed on the invoking shell, so one lane re-running gets a new tree " ~
        "and a leftover one is never adopted", a, aPpid1, aPpid2));

    const bSamePpid = askScratch(laneB, ["PPID": "111111"], true);
    assert(aPpid1 != bSamePpid, format(
        "two checkouts under one exported PPID share a scratch tree (%s) — " ~
        "exactly the pre-1282 collision, with the variable actually set", aPpid1));

    // Shape: the root-filesystem default, and recognisable at a glance in `ls`.
    foreach (p; [a, b, tb])
        assert(p.startsWith(buildPath("/var/tmp", "vibe3d-tests-")), format(
            "scratch path %s is not a `vibe3d-tests-*` directory under the " ~
            "root-filesystem default /var/tmp", p));
}

unittest
{
    // Capacity isolation must never split the host-wide lock.
    const stem = buildPath(tempDir(), format(
        "vibe3d-scratch-lock-test-%d", thisProcessID));
    const laneA = buildPath(stem, "alpha", "vibe3d");
    const explicitRoot = buildPath(stem, "explicit-root");
    foreach (d; [laneA, explicitRoot]) mkdirRecurse(d);
    scope(exit) cast(void) collectException(rmdirRecurse(stem));

    const defaultLock = askRunner(laneA, "--print-run-lock", null, true);
    const explicitLock = askRunner(laneA, "--print-run-lock",
                                   ["TMPDIR": explicitRoot]);
    const canonicalLock = buildPath("/tmp", "vibe3d-run-test.lock");
    assert(defaultLock == canonicalLock
        && explicitLock == defaultLock, format(
        "--print-run-lock moved with TMPDIR: default=%s explicit=%s",
        defaultLock, explicitLock));

    const workflow = readText(buildPath(repoRoot, ".github", "workflows",
                                        "sanitizer.yaml"));
    assert(!workflow.canFind("TMPDIR:"),
        "sanitizer.yaml sets TMPDIR, so its suite would not exercise the " ~
        "root-filesystem scratch default");
    assert(!workflow.canFind(scratchRootTestEnv),
        "sanitizer.yaml sets the scratch-root test seam");
}

unittest
{
    // Exercise the real --sweep-scratch filesystem walk without exposing any
    // host or sibling-lane tree: only the default root is substituted, while
    // TMPDIR stays unset exactly as it is in the nightly workflow.
    const root = buildPath(tempDir(), format(
        "vibe3d-sweep-root-test-%d", thisProcessID));
    const orphan = buildPath(root, "vibe3d-tests-injected-orphan");
    mkdirRecurse(orphan);
    scope(exit) if (exists(root)) cast(void) collectException(rmdirRecurse(root));

    string[string] env;
    foreach (k, v; environment.toAA) env[k] = v;
    env.remove("TMPDIR");
    env[scratchRootTestEnv] = root;
    env["VIBE3D_HARNESS_LOG"] = "off";
    env["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = runnerLockPath();

    auto r = execute(["rdmd", runnerPath, "--sweep-scratch"],
                     env, Config.none, size_t.max, repoRoot);
    assert(r.status == 0, "--sweep-scratch failed:\n" ~ r.output);
    assert(r.output.canFind(orphan), format(
        "--sweep-scratch did not report the injected orphan %s:\n%s",
        orphan, r.output));
    assert(!exists(orphan), format(
        "--sweep-scratch left the injected orphan under its own root: %s\n%s",
        orphan, r.output));
}
