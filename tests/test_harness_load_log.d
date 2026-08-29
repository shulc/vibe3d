// The two facts about a run that no reconstruction could reach (task 3260).
//
// `run_test.d` appends one JSON line per invocation to a host-wide load log.
// Two of its fields are the whole reason the log exists, and both are only
// correct if the record is written on the paths where NOTHING RAN:
//
//   * `stage`       — did this invocation run tests at all, or was it refused;
//   * `lock_wait_s` / `lock_holder_pid` — how long it queued behind another
//     lane on this host, and behind WHICH one.
//
// Reconstructing these from the agent transcripts was tried first and could
// see neither: the "acquired run lock after Ns" line goes to stdout, and
// stdout is redirected to a file in most invocations — it was legible in about
// 200 of 2 970 runs.
//
// TWO CELLS, separate on purpose:
//
//   A. an exit reached BEFORE the lock ever is (`no_such_test`). Proves a
//      record is written at all, and that `lock_wait_s` carries its "never got
//      there" sentinel instead of a plausible-looking 0. It also covers a
//      route that unwinds nothing: `resolveTests` leaves through core.stdc's
//      `exit`, so main's `scope(exit)` does NOT fire and the record has to be
//      written by hand there.
//
//   B. the lock GIVE-UP (`lock_timeout`) — the path the reconstruction most
//      needed, and the likeliest to be forgotten, because it is the only exit
//      that produces no test output whatsoever.
//
// Cell B is deterministic for a structural reason: this test runs UNDER a
// run_test.d that holds the host-wide lock, so a child runner cannot get it.
// That is also why the child needs `--lock-timeout`: otherwise it would sit
// for the full 600 s.
//
// MUTATIONS THIS CATCHES — each reddens a named assert, and they are in two
// different cells, so run them one at a time (druntime stops a module at its
// first failed assert):
//
//   delete `scope(exit) writeHarnessRecord()` in main   -> B: "no record"
//   drop the hand-written record before `exit(2)`       -> A: "no record"
//   drop `g_harness.stage = HarnessStage.lockTimeout`   -> B: stage
//   drop `g_harness.lockTimedOut = true`                -> B: lock_timeout
//   drop the holder read before recordLockHolder()      -> B: holder pid
//   make `lock_wait_s` default to 0 instead of -1       -> A: sentinel

import std.process : execute, thisProcessID;
import std.file    : exists, readText, remove, tempDir;
import std.json    : JSONValue, parseJSON;
import std.path    : buildPath;
import std.string  : strip, startsWith, splitLines;
import std.conv    : to;
import std.format  : format;
import std.stdio   : writeln;
import liveness_gate : scenario;

string g_logPath;

JSONValue[] records() {
    if (!exists(g_logPath)) return [];
    JSONValue[] out_;
    foreach (line; readText(g_logPath).splitLines) {
        if (line.strip.length == 0) continue;
        out_ ~= parseJSON(line);
    }
    return out_;
}

void main() {
    assert(exists("run_test.d"),
        "this test must run from the repo root, but the cwd has no run_test.d");

    g_logPath = buildPath(tempDir(),
        format("vibe3d-harness-log-test-%d.jsonl", thisProcessID));
    if (exists(g_logPath)) remove(g_logPath);
    scope(exit) if (exists(g_logPath)) remove(g_logPath);

    // Redirect the child's log to our own file: the point is to read what a
    // run writes, not to add rows to this host's real record.
    string[string] env = ["VIBE3D_HARNESS_LOG": g_logPath];

    // ---------------------------------------------------------------- cell A
    scenario("A: an invocation refused before the lock still leaves a record");
    auto a = execute(["./run_test.d", "definitely-not-a-test-3260"], env);
    assert(a.status == 2,
        format("A: an unknown test should exit 2, got %d\n%s", a.status, a.output));

    auto recsA = records();
    assert(recsA.length == 1, format(
        "A: expected exactly ONE record, got %d — the invocation left no record. "
      ~ "`resolveTests` leaves through core.stdc `exit`, which unwinds nothing, "
      ~ "so main's scope(exit) cannot cover it.", recsA.length));
    auto rA = recsA[0];
    assert(rA["stage"].str == "no_such_test",
        "A: stage should be no_such_test, is " ~ rA["stage"].str);
    assert(rA["lock_wait_s"].integer == -1, format(
        "A: lock_wait_s should be the -1 'never reached the lock' sentinel, is %d. "
      ~ "A 0 here would read as 'waited nothing', which is a different fact.",
        rA["lock_wait_s"].integer));
    assert(rA["mode"].str == "narrow", "A: a named test is a narrow run");
    assert(rA["rc"].integer == 2, "A: rc should be 2");
    assert(rA["kind"].str == "suite", "A: kind should be suite");
    assert(rA["branch"].str.length > 0, "A: the lane's branch was not recorded");
    assert(rA["root"].str.length > 0, "A: the lane's root was not recorded");

    // ---------------------------------------------------------------- cell B
    scenario("B: a run that gave up waiting for the host lock records the wait");
    // Whoever holds the host lock right now is the run_test.d running THIS
    // test. The child must name that pid, or "who were we queued behind" is
    // not actually being captured.
    auto lockFile = buildPath(tempDir(), "vibe3d-run-test.lock");
    int holder = 0;
    if (exists(lockFile)) {
        auto t = readText(lockFile).strip;
        if (t.startsWith("pid ")) holder = t["pid ".length .. $].strip.to!int;
    }
    assert(holder > 0, format(
        "B: this cell needs a run_test.d holding the host lock (it is normally "
      ~ "the runner executing this very test), but %s names no pid. Running "
      ~ "this test binary by hand instead of through ./run_test.d cannot "
      ~ "exercise the give-up path.", lockFile));

    // --stale-ok so the binary-freshness guard, which sits BEFORE the lock,
    // cannot decide this cell's outcome instead of the lock doing it.
    auto b = execute(["./run_test.d", "--lock-timeout", "1", "--no-build",
                      "--stale-ok", "test_harness_load_log"], env);
    assert(b.status == 1,
        format("B: a lock give-up should exit 1, got %d\n%s", b.status, b.output));

    auto recsB = records();
    assert(recsB.length == 2, format(
        "B: expected a second record, got %d in total — the give-up path wrote "
      ~ "nothing, which is exactly the invocation the log exists to count.",
        recsB.length));
    auto rB = recsB[1];
    assert(rB["stage"].str == "lock_timeout", format(
        "B: stage should be lock_timeout, is %s. `started` here means the "
      ~ "record was written but the give-up did not label itself.",
        rB["stage"].str));
    assert(rB["lock_timeout"].boolean, "B: lock_timeout should be true");
    assert(rB["lock_wait_s"].integer == 1, format(
        "B: lock_wait_s should be the 1 s we allowed, is %d",
        rB["lock_wait_s"].integer));
    assert(rB["lock_holder_pid"].integer == holder, format(
        "B: lock_holder_pid should name the lock's holder (%d), is %d",
        holder, rB["lock_holder_pid"].integer));
    assert(rB["total"].integer == 0, "B: a run that never started has no tests");

    writeln("harness load log: both cells pass — a refused run and a lock "
          ~ "give-up each leave exactly one labelled record");
}
