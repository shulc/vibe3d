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
// THREE CELLS, separate on purpose:
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
//   C. preparation starts after the lock but cannot build the shared project
//      test library. It must be `run_incomplete`, never `ran`: selected tests
//      are not measured tests, and there is no verdict without `Total:`.
//      The nested invocation reuses only a PID+fd lease for this test's private
//      lock, verified through /proc ancestry plus descriptor/path device+inode
//      identity. The outer runner's canonical lock remains untouched.
//
// Cell B is deterministic for a structural reason: this process holds the
// private lock named in every child's environment, so an independent child
// cannot get it. That is also why the child needs `--lock-timeout`: otherwise
// it would sit for the full 600 s.
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

import std.process : Config, environment, execute, thisProcessID;
import std.file    : dirEntries, exists, getcwd, mkdirRecurse, readText, remove, rmdirRecurse,
                     SpanMode, tempDir;
import std.json    : JSONValue, parseJSON;
import std.path    : absolutePath, baseName, buildPath, isAbsolute;
import std.string  : indexOf, strip, startsWith, splitLines;
import std.conv    : octal, to;
import std.format  : format;
import std.stdio   : writeln;
import liveness_gate : scenario;
import core.sys.posix.fcntl : open, O_CREAT, O_RDWR;
import core.sys.posix.unistd : access, close, X_OK;
import core.sys.posix.sys.stat : chmod;

string g_logPath;

private enum LOCK_EX = 2;
private enum LOCK_NB = 4;
private enum LOCK_UN = 8;
extern(C) int flock(int fd, int operation) nothrow @nogc;

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

    // Preserve task 4870's positive witness before this test moves its other
    // children to private storage: the outer runner must supply a descriptor
    // whose identity lets a real nested runner borrow the already-held lease.
    auto inheritedEnv = environment.toAA;
    inheritedEnv["VIBE3D_HARNESS_LOG"] = "off";
    assert(inheritedEnv.get("VIBE3D_INHERITED_RUN_LOCK_PID", "").length > 0
        && inheritedEnv.get("VIBE3D_INHERITED_RUN_LOCK_FD", "").length > 0,
        "the outer runner did not provide its PID+fd lock lease");
    auto inheritedProbe = execute(
        ["./run_test.d", "--probe-run-lock", "0", "--lock-timeout", "1"],
        inheritedEnv, Config.inheritFDs);
    assert(inheritedProbe.status == 0
        && inheritedProbe.output.indexOf("RUN LOCK ACQUIRED:") >= 0,
        "the nested runner could not borrow the outer runner's verified lease:\n"
      ~ inheritedProbe.output);

    g_logPath = buildPath(tempDir(),
        format("vibe3d-harness-log-test-%d.jsonl", thisProcessID));
    if (exists(g_logPath)) remove(g_logPath);
    scope(exit) if (exists(g_logPath)) remove(g_logPath);

    const lockFile = buildPath(tempDir(),
        format("vibe3d-harness-lock-test-%d", thisProcessID));
    if (exists(lockFile)) remove(lockFile);
    scope(exit) if (exists(lockFile)) remove(lockFile);
    // The runner's per-checkout build lock lives beside the private slot base.
    scope(exit) foreach (e; dirEntries(tempDir(), baseName(lockFile) ~ ".wt.*",
                                       SpanMode.shallow))
        remove(e.name);
    import std.string : toStringz;
    const lockFd = open(lockFile.toStringz, O_RDWR | O_CREAT, octal!"644");
    assert(lockFd >= 0, "could not open the private runner lock " ~ lockFile);
    scope(exit) {
        cast(void) flock(lockFd, LOCK_UN);
        close(lockFd);
    }
    assert(flock(lockFd, LOCK_EX | LOCK_NB) == 0,
        "could not establish the private runner-lock precondition");
    static import std.file;
    std.file.write(lockFile, format("pid %d\n", thisProcessID));

    // Redirect the child's log to our own file: the point is to read what a
    // run writes, not to add rows to this host's real record. This deliberately
    // starts from an empty environment rather than environment.toAA(): cell B
    // must NOT inherit a verified lock lease, because it is the witness for a
    // genuinely independent runner timing out on this test's private lock.
    string[string] env = [
        "VIBE3D_HARNESS_LOG": g_logPath,
        "VIBE3D_PERF_RUNTEST_LOCK_PATH": lockFile,
        // One slot (task 6205): with the default two, an independent child
        // would take the private family's free second slot instead of queueing.
        "VIBE3D_RUN_SLOTS": "1",
        "VIBE3D_INHERITED_RUN_LOCK_PID": "",
        "VIBE3D_INHERITED_RUN_LOCK_FD": "",
    ];

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
    scenario("B: a run that gave up waiting for the runner lock records the wait");
    // This process holds the private lock. The child must report this PID, or
    // "who were we queued behind" is not actually being captured.
    auto lockQuery = execute(["./run_test.d", "--print-run-lock"], env);
    assert(lockQuery.status == 0,
        "B: run_test.d could not report its configured lock:\n" ~ lockQuery.output);
    const queriedLock = lockQuery.output.strip;
    assert(queriedLock == lockFile, format(
        "B: run_test.d ignored the private lock seam: expected %s, got %s",
        lockFile, queriedLock));
    int holder = 0;
    if (exists(lockFile)) {
        auto t = readText(lockFile).strip;
        if (t.startsWith("pid ")) holder = t["pid ".length .. $].strip.to!int;
    }
    assert(holder > 0, format(
        "B: this process should hold the private runner lock, but %s names no pid.",
        lockFile));

    // --stale-ok so the binary-freshness guard cannot decide this cell's
    // outcome instead of the run slot doing it.
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

    // ------------------------------------------------------- lease ancestry
    scenario("lease ancestry: an orphaned session cannot borrow the lock");
    inheritedEnv["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = lockFile;
    inheritedEnv["VIBE3D_RUN_SLOTS"] = "1";
    inheritedEnv["VIBE3D_INHERITED_RUN_LOCK_PID"] = thisProcessID.to!string;
    inheritedEnv["VIBE3D_INHERITED_RUN_LOCK_FD"] = lockFd.to!string;
    auto orphaned = execute(
        ["setsid", "--fork", "./run_test.d", "--probe-run-lock", "0",
         "--lock-timeout", "1"],
        inheritedEnv, Config.inheritFDs);
    assert(orphaned.output.indexOf("NO TESTS RAN") >= 0
        && orphaned.output.indexOf("RUN LOCK ACQUIRED:") < 0,
        "lease ancestry: a setsid --fork child reparented away from the "
        ~ "declared owner borrowed its lock:\n" ~ orphaned.output);

    // ------------------------------------------------------ lease identity
    scenario("lease identity: ancestry alone cannot borrow a different fd");
    const decoyPath = buildPath(tempDir(),
        format("vibe3d-run-lock-decoy-%d", thisProcessID));
    if (exists(decoyPath)) remove(decoyPath);
    scope(exit) if (exists(decoyPath)) remove(decoyPath);
    const decoyFd = open(decoyPath.toStringz, O_RDWR | O_CREAT, octal!"644");
    assert(decoyFd >= 0, "lease identity: could not open the decoy descriptor");
    scope(exit) close(decoyFd);

    auto wrongIdentityEnv = inheritedEnv.dup;
    wrongIdentityEnv["VIBE3D_INHERITED_RUN_LOCK_PID"] = thisProcessID.to!string;
    wrongIdentityEnv["VIBE3D_INHERITED_RUN_LOCK_FD"] = decoyFd.to!string;
    auto wrongIdentity = execute(
        ["./run_test.d", "--probe-run-lock", "0", "--lock-timeout", "1"],
        wrongIdentityEnv, Config.inheritFDs);
    assert(wrongIdentity.status == 1
        && wrongIdentity.output.indexOf("NO TESTS RAN") >= 0
        && wrongIdentity.output.indexOf("RUN LOCK ACQUIRED:") < 0,
        "lease identity: a live ancestor borrowed the host lock through a "
        ~ "descriptor for a different inode:\n" ~ wrongIdentity.output);

    // ---------------------------------------------------------------- cell C
    scenario("C: a run that loses its project library before Total is incomplete");
    // Unlike cells A/B, execute() here receives this test's verified private
    // lease while its fd stays owned by this process. The host lock remains
    // excluded for the entire nested run.
    // Task 20262050: ordinary compiler failure must reach the existing refusal.
    // Match only the exact project-library argv, then require a fresh witness;
    // custody and controls: doc/tasks/20262050-evidence/receipt.md.
    const childTmp = buildPath(tempDir(),
        format("vibe3d-harness-incomplete-%d", thisProcessID));
    assert(!exists(childTmp), "C: child temporary directory must be fresh");
    mkdirRecurse(buildPath(childTmp, "bin"));
    scope(exit) if (exists(childTmp)) rmdirRecurse(childTmp);

    auto compilerQuery = execute(["sh", "-c", "command -v dmd"], inheritedEnv);
    assert(compilerQuery.status == 0 && compilerQuery.output.strip.length > 0,
        "C: could not resolve the original compiler:\n" ~ compilerQuery.output);
    const realDmd = absolutePath(compilerQuery.output.strip);
    assert(isAbsolute(realDmd) && access(realDmd.toStringz, X_OK) == 0,
        "C: resolved compiler must be an absolute executable path");

    auto queryEnv = inheritedEnv.dup;
    queryEnv["TMPDIR"] = childTmp;
    auto scratchQuery = execute(["./run_test.d", "--print-scratch"], queryEnv);
    const scratch = scratchQuery.output.strip;
    assert(scratchQuery.status == 0 && scratch.length > 0 && isAbsolute(scratch),
        "C: runner must report an absolute child scratch path:\n" ~ scratchQuery.output);
    const expectedLib = buildPath(scratch, "libvibe3d_test.a");
    const witnessPath = buildPath(childTmp, "project-library-failure.witness");
    const witness = "PROJECT_LIB_FAILURE_WITNESS status=73 output=" ~ expectedLib;
    const shim = buildPath(childTmp, "bin", "dmd");
    std.file.write(shim,
        "#!/bin/sh\n"
      ~ "lib=0; unittest=0; output=0\n"
      ~ "for arg do\n"
      ~ "  [ \"$arg\" = '-lib' ] && lib=1\n"
      ~ "  [ \"$arg\" = '-unittest' ] && unittest=1\n"
      ~ "  [ \"$arg\" = \"-of=$VIBE3D_FAILURE_LIBRARY\" ] && output=1\n"
      ~ "done\n"
      // buildProjectLib serializes one quoted argument per line. Compare its
      // canonical spelling, escaping the exact output operand by the same rules.
      ~ "response_output=$(printf '%s\\n' \"-of=$VIBE3D_FAILURE_LIBRARY\" | sed 's/\\(\\\\*\\)\"/\\1\\1\\\\\"/g; s/\\(\\\\*\\)$/\\1\\1/; s/^/\"/; s/$/\"/')\n"
      ~ "for arg do\n"
      ~ "  case \"$arg\" in @*)\n"
      ~ "    while IFS= read -r operand; do\n"
      ~ "      [ \"$operand\" = '\"-lib\"' ] && lib=1\n"
      ~ "      [ \"$operand\" = '\"-unittest\"' ] && unittest=1\n"
      ~ "      [ \"$operand\" = \"$response_output\" ] && output=1\n"
      ~ "    done < \"${arg#@}\"\n"
      ~ "  esac\n"
      ~ "done\n"
      ~ "if [ \"$lib\" = 1 ] && [ \"$unittest\" = 1 ] && [ \"$output\" = 1 ]; then\n"
      ~ "  printf '%s\\n' \"$VIBE3D_FAILURE_WITNESS_TEXT\" >> \"$VIBE3D_FAILURE_WITNESS_PATH\"\n"
      ~ "  printf '%s\\n' \"$VIBE3D_FAILURE_WITNESS_TEXT\" >&2\n"
      ~ "  exit 73\n"
      ~ "fi\n"
      ~ "exec \"$VIBE3D_REAL_DMD\" \"$@\"\n");
    assert(chmod(shim.toStringz, octal!"755") == 0,
        "C: compiler wrapper must be executable");
    auto childEnv = inheritedEnv.dup;
    childEnv["TMPDIR"] = childTmp;
    childEnv["PATH"] = buildPath(childTmp, "bin") ~ ":" ~ environment["PATH"];
    childEnv["VIBE3D_REAL_DMD"] = realDmd;
    childEnv["VIBE3D_FAILURE_LIBRARY"] = expectedLib;
    childEnv["VIBE3D_FAILURE_WITNESS_PATH"] = witnessPath;
    childEnv["VIBE3D_FAILURE_WITNESS_TEXT"] = witness;
    childEnv["VIBE3D_HARNESS_LOG"] = g_logPath;

    auto statusProbe = execute([shim, "-lib", "-unittest", "-of=" ~ expectedLib], childEnv);
    assert(statusProbe.status == 73,
        format("C: wrapper must exit normally with configured compiler status 73, got %d\n%s",
            statusProbe.status, statusProbe.output));
    assert(exists(witnessPath) && readText(witnessPath) == witness ~ "\n",
        "C: project-library compiler failure witness missing or mismatched (probe)");
    remove(witnessPath);

    const childPort = 20_000 + cast(int)(thisProcessID % 20_000);
    const script =
        "env -u DISPLAY rdmd \"$1/run_test.d\" --no-build --stale-ok -p \"$2\" -j 1 test_ai3d_controller\n"
      ~ "runner_rc=$?\n"
      ~ "echo CHILD_RUNNER_EXIT=$runner_rc\n"
      ~ "exit 0\n";
    auto c = execute(["sh", "-c", script, "_", getcwd(), childPort.to!string],
        childEnv, Config.inheritFDs);
    assert(exists(witnessPath) && readText(witnessPath) == witness ~ "\n"
        && c.output.indexOf(witness) >= 0,
        "C: project-library compiler failure witness missing or mismatched:\n" ~ c.output);
    assert(c.status == 0, format(
        "C: constrained child failed outside the expected runner refusal (%d):\n%s",
        c.status, c.output));
    assert(c.output.indexOf(
            "project test-lib build failed; refusing per-test -i fallback") >= 0,
        format("C: witnessed project-library failure did not reach the intended refusal:\n%s",
        c.output));
    assert(c.output.indexOf(
            "project test-lib build failed; falling back to per-test -i compile") < 0,
        "C: the forbidden per-test fallback reappeared:\n" ~ c.output);
    assert(c.output.indexOf("CHILD_RUNNER_EXIT=1") >= 0,
        "C: failed preparation should exit 1:\n" ~ c.output);
    assert(c.output.indexOf("Total:") < 0,
        "C: the failed preparation unexpectedly produced a verdict:\n" ~ c.output);

    auto recsC = records();
    assert(recsC.length == 3, format(
        "C: expected exactly one new record, got %d total", recsC.length));
    auto rC = recsC[2];
    assert(rC["stage"].str == "run_incomplete", format(
        "C: selected work whose worker died before Total must be run_incomplete, is %s",
        rC["stage"].str));
    assert(rC["tests_selected"].integer == 1,
        "C: the witness must select exactly one test");
    assert(rC["total"].integer == 0,
        "C: no TestResult reached the summary, so total must stay zero");
    assert(rC["rc"].integer == 1,
        "C: an incomplete run must retain the pessimistic rc=1");

    writeln("harness load log: refusal, lock give-up, and incomplete worker "
          ~ "preparation each leave one precisely labelled record");
}
