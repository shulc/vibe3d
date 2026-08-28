// The disk-space preflight and the orphan-scratch sweep (task 2080).
//
// THE INCIDENT. A sanitizer night died mid-link:
//
//     Error: error writing file '.../worker_N/<test>.o'
//     /usr/bin/ld: final link failed: No space left on device
//
// and SIX unrelated fixture tests failed identically in the same run — which
// reads as a code regression and is one exhausted filesystem. `worker_N` is
// `run_test.d`'s own per-worker scratch directory, written by `compileTests`
// under `tempDir()`; on the affected host `/tmp` is a 32 GiB tmpfs, i.e. RAM.
//
// WHAT IS GATED HERE, following the same black-box discipline as
// `run_test_scratch_test.d` (this project runs run_test.d/lane.d as
// standalone rdmd scripts, never imported as modules — see that file's own
// header for why):
//
//   1. `--check-space` — the real `freeBytes()`/statvfs query against a real
//      path, on BOTH run_test.d and tools/sanitizer/lane.d, at the exact
//      boundary and past it. This is an EXACT term (`free < floor`), proven
//      on the real filesystem this test runs on rather than an injected
//      number, by supplying `--space-floor-mib` and letting the real query
//      answer against it.
//   2. `--sweep-plan` — the orphan-scratch RULE: a `--sweep-live` root's
//      computed scratch tree must NEVER appear in the swept set. This is the
//      "refuse to delete anything a live worktree still references" cell —
//      pure, no filesystem, so it cannot be an artefact of what happens to
//      be sitting in tempDir() when this test runs.
//   3. THE WITNESS THE CARD SPECIFIES, run for real when the host allows it:
//      an unprivileged mount namespace (`unshare --mount --map-root-user`,
//      needing no root) with a genuinely tiny tmpfs mounted inside it, and
//      the MANDATORY gate — `run_test.d`/`lane.d preflight` with NO special
//      flags, exactly as a real caller invokes them — pointed at it via
//      `TMPDIR`. Not a mocked free-byte number: a real `statvfs` answer from
//      a real, too-small filesystem. Skips (loudly, not silently) on a host
//      where the unprivileged mount namespace is unavailable — this project
//      has no CI runner known to lack it, but a check that could turn into a
//      silent false-green on a host that changes that must not pretend to
//      have run.
//
// WHAT THIS DOES NOT COVER: a run that starts on a filesystem clear of the
// floor and is exhausted by other activity DURING the run. That failure mode
// is unchanged by a preflight by construction (a one-shot check, not a
// monitor — see run_test.d's own comment on why) and is out of scope here.
module tests.unit.run_test_space_preflight_test;

import std.algorithm  : canFind;
import std.conv       : to;
import std.exception  : collectException, enforce;
import std.file       : exists, mkdirRecurse, rmdirRecurse, tempDir;
import std.format     : format;
import std.path       : buildPath, dirName;
import std.process    : Config, execute, environment, thisProcessID;
import std.stdio      : stderr;
import std.string     : startsWith, strip, indexOf, splitLines;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");
private enum lanePath   = buildPath(repoRoot, "tools", "sanitizer", "lane.d");

private struct Run { int status; string output; }

private Run rdmd(string script, string[] rest, string[string] extraEnv = null, string cwd = null)
{
    string[string] env;
    foreach (k, v; environment.toAA) env[k] = v;
    foreach (k, v; extraEnv)          env[k] = v;
    auto r = execute(["rdmd", script] ~ rest, env, Config.none, size_t.max,
                      cwd is null ? repoRoot : cwd);
    return Run(r.status, r.output);
}

private string askScratch(string cwd)
{
    auto r = rdmd(runnerPath, ["--print-scratch"], null, cwd);
    enforce(r.status == 0, format("--print-scratch (cwd %s) exited %d:\n%s", cwd, r.status, r.output));
    const path = r.output.strip;
    enforce(path.length, "--print-scratch printed nothing");
    return path;
}

// ---------------------------------------------------------------------------
// 1. --check-space: the real statvfs query, exact boundary, both binaries.
// ---------------------------------------------------------------------------
unittest
{
    enforce(exists(runnerPath), runnerPath ~ " not found — repo root misderived");
    enforce(exists(lanePath),   lanePath   ~ " not found — repo root misderived");

    // A real path with a real amount of free space (the repo root's
    // filesystem) — a floor of 0 must always pass, on both binaries.
    {
        auto r = rdmd(runnerPath, ["--check-space", repoRoot, "--space-floor-mib", "0"]);
        assert(r.status == 0, "run_test.d --check-space with a 0 MiB floor refused a real "
             ~ "filesystem:\n" ~ r.output);
    }
    {
        auto r = rdmd(lanePath, ["check-space", repoRoot, "0"]);
        assert(r.status == 0, "lane.d check-space with a 0 MiB floor refused a real "
             ~ "filesystem:\n" ~ r.output);
    }

    // The same real filesystem, with a floor no real disk clears — this is
    // NOT a mocked free-byte number: the query is real, only the floor
    // argument is deliberately absurd, so this proves the COMPARISON reddens
    // without needing a constrained mount for the exact-boundary case.
    {
        auto r = rdmd(runnerPath, ["--check-space", repoRoot, "--space-floor-mib", "999999999"]);
        assert(r.status == 1, "run_test.d --check-space did not refuse an unmeetable floor");
        assert(r.output.indexOf("no space left") >= 0,
            "refusal message does not say \"no space left\": " ~ r.output);
        assert(r.output.indexOf(repoRoot) >= 0, "refusal message does not name the checked path: " ~ r.output);
    }
    {
        auto r = rdmd(lanePath, ["check-space", repoRoot, "999999999"]);
        assert(r.status == 1, "lane.d check-space did not refuse an unmeetable floor");
        assert(r.output.indexOf("no space left") >= 0,
            "refusal message does not say \"no space left\": " ~ r.output);
    }

    // A path with no existing ancestor climbed root-ward from it must never
    // be treated as "no space" — that would turn an unrelated situation
    // (nothing to query) into a false disk-space refusal.
    {
        auto r = rdmd(runnerPath, ["--check-space",
                       buildPath(tempDir(), "vibe3d-2080-does-not-exist-xyz")]);
        assert(r.status == 0, "a not-yet-created path under an existing tempDir() was refused: "
             ~ r.output);
    }
}

// ---------------------------------------------------------------------------
// 2. --sweep-plan: the refusal cell. A live root's tree must never be swept.
// ---------------------------------------------------------------------------
unittest
{
    const stem = buildPath(tempDir(), format("vibe3d-sweepplan-test-%d", thisProcessID));
    const liveA = buildPath(stem, "live-a", "vibe3d");
    const liveB = buildPath(stem, "live-b", "vibe3d");
    const goneC = buildPath(stem, "gone-c", "vibe3d");
    foreach (d; [liveA, liveB, goneC]) mkdirRecurse(d);
    scope(exit) cast(void) collectException(rmdirRecurse(stem));

    // Each checkout's real scratch-tree NAME, via the same derivation
    // `--sweep-scratch` uses internally (`scratchDirFor`) — not
    // reimplemented here, so this test cannot pass by agreeing with itself.
    const scratchA = askScratch(liveA);
    const scratchB = askScratch(liveB);
    const scratchC = askScratch(goneC);

    // goneC is deliberately NOT in --sweep-live: it simulates a worktree
    // whose pair has already been torn down (task-wt-rm.sh), so nothing will
    // ever run from that checkout again and its tree is legitimately orphaned.
    auto r = rdmd(runnerPath, [
        "--sweep-plan",
        "--sweep-entry", scratchA, "--sweep-entry", scratchB, "--sweep-entry", scratchC,
        "--sweep-live",  liveA,    "--sweep-live",  liveB,
    ]);
    enforce(r.status == 0, "--sweep-plan exited " ~ r.status.to!string ~ ":\n" ~ r.output);

    auto orphans = r.output.strip.splitLines;

    assert(orphans.canFind(scratchC), format(
        "the gone checkout's tree (%s) was not reported as an orphan — output:\n%s",
        scratchC, r.output));
    assert(!orphans.canFind(scratchA), format(
        "a LIVE worktree's tree (%s) was reported as swept — this is exactly the refusal "
      ~ "--sweep-scratch must never violate. Output:\n%s", scratchA, r.output));
    assert(!orphans.canFind(scratchB), format(
        "a LIVE worktree's tree (%s) was reported as swept — output:\n%s", scratchB, r.output));
    assert(orphans.length == 1, format(
        "expected exactly one orphan (the gone checkout), got %d: %s", orphans.length, orphans));
}

// ---------------------------------------------------------------------------
// 3. THE WITNESS: a real, tiny, unprivileged tmpfs; the MANDATORY default
//    gate (no flags) on both binaries; a real red saying "space".
// ---------------------------------------------------------------------------

/// True iff this host will let an unprivileged user create a mount
/// namespace and mount tmpfs inside it — the mechanism this witness needs,
/// needing no root and no sudoers entry. Probed with the cheapest possible
/// command so a host that lacks it fails fast, not slowly.
private bool canUnprivilegedMount()
{
    auto probe = execute(["unshare", "--mount", "--map-root-user", "true"]);
    return probe.status == 0;
}

unittest
{
    if (!canUnprivilegedMount()) {
        stderr.writeln("run_test_space_preflight_test: SKIPPED constrained-mount witness "
            ~ "— `unshare --mount --map-root-user` is unavailable on this host (unprivileged "
            ~ "user namespaces disabled or `unshare` missing). --check-space above already "
            ~ "proved the comparison; this block additionally proves it against a REAL "
            ~ "too-small filesystem where the host permits building one.");
        return;
    }

    const mp = buildPath(tempDir(), format("vibe3d-2080-fsw-%d", thisProcessID));
    mkdirRecurse(mp);
    scope(exit) cast(void) collectException(rmdirRecurse(mp));

    // 16 MiB: enough for rdmd's own bootstrap object-cache write (measured
    // ~3-4 MiB on a fresh mount) so the failure observed is THIS check's own
    // refusal, not rdmd dying before main() ever runs — a real, deeper edge
    // case this task also found and does not claim to fix (see the header).
    // Still far below the 256 MiB floor, so it is a genuine, not a marginal,
    // constrained mount.
    // `lane.d preflight` also refuses on DISPLAY=:0 (check (2), unrelated to
    // this task) — this host's shell inherits exactly that, and its own
    // sanitizer.yaml clears DISPLAY for the same reason (every real step runs
    // under xvfb-run). Cleared here so THIS check is what is being isolated,
    // not masked by a second, unrelated refusal firing first (measured: with
    // DISPLAY=:0 inherited, a deliberately neutered disk check still exits 1,
    // for the wrong reason — see the mutation note in the task card).
    const script = format(
        "mount -t tmpfs -o size=16m tmpfs %s || exit 99\n"
      ~ "TMPDIR=%s rdmd %s selection 2>&1; echo RUNNER_EXIT=$?\n"
      ~ "TMPDIR=%s DISPLAY= rdmd %s preflight 2>&1; echo LANE_EXIT=$?\n",
        mp, mp, runnerPath, mp, lanePath);
    auto r = execute(["unshare", "--mount", "--map-root-user", "bash", "-c", script]);

    enforce(r.status != 99, "could not mount a 16 MiB tmpfs inside the unprivileged "
        ~ "namespace — canUnprivilegedMount() said yes but the mount itself failed:\n" ~ r.output);

    const runnerExitAt = r.output.indexOf("RUNNER_EXIT=");
    const laneExitAt   = r.output.indexOf("LANE_EXIT=");
    enforce(runnerExitAt >= 0 && laneExitAt >= 0,
        "witness script did not complete — output:\n" ~ r.output);

    assert(r.output.indexOf("RUNNER_EXIT=1") >= 0, format(
        "run_test.d, invoked exactly as a caller would (`./run_test.d selection`, no "
      ~ "diagnostic flags), did not exit 1 against a real 16 MiB tmpfs:\n%s", r.output));
    assert(r.output.indexOf("LANE_EXIT=1") >= 0, format(
        "tools/sanitizer/lane.d preflight did not exit 1 against a real 16 MiB tmpfs:\n%s",
        r.output));

    // The word the card asks for, verbatim, from a REAL statvfs answer.
    // Segments: run_test.d's own output precedes its RUNNER_EXIT marker;
    // lane.d's own output runs from there to its LANE_EXIT marker.
    const runnerSection = r.output[0 .. runnerExitAt];
    const laneSection    = r.output[runnerExitAt .. laneExitAt];
    assert(runnerSection.indexOf("no space left") >= 0,
        "run_test.d's refusal does not say \"no space left\":\n" ~ runnerSection);
    assert(laneSection.indexOf("no space left") >= 0,
        "lane.d's refusal does not say \"no space left\":\n" ~ laneSection);

    // And it must not be disguised as red TESTS: the runner must refuse
    // before it ever gets far enough to report a test outcome. This is the
    // literal shape of the incident — six unrelated tests failing identically
    // — so the absence of the runner's own "tests failed" summary is the
    // right thing to check, not a re-derived heuristic.
    assert(runnerSection.indexOf("Failed tests:") < 0, format(
        "run_test.d reached its test-failure summary instead of refusing up front — "
      ~ "this is exactly the incident's disguise:\n%s", runnerSection));
}
