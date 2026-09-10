// The perf measuring window's host-wide locks (task 2030, extended
// 2026-08-30 to also take the test runner's lock — see
// tools/perf/lib/with_perf_lock.sh's own header for the three measurements
// that made "a perf run and a test run may legitimately overlap" false).
//
// WHY THIS FILE EXISTS AT ALL. The failure mode of a lock that stops
// excluding what it was meant to exclude is SILENT and produces plausible
// numbers: the perf lane measures beside a test run, every case comes back
// 20-60% slow, `--vs-last` reddens, and nothing anywhere says "the host was
// busy". That is the shape CLAUDE.md names — a green (or a red) that cannot
// tell you which of two very different worlds it came from. The specific
// ways it can go silently wrong, one block each:
//
//   1. THE TWO PATHS DRIFT. Both programs expose the value they will actually
//      use; this test asks under two different TMPDIR values and compares the
//      answers. If either path moves — or a workflow sets the test seam or
//      skip flag — the perf lane takes a lock NOBODY ELSE TAKES and every
//      number stays plausible.
//   2. THE SECOND ACQUISITION IS NOT ACTUALLY THERE. A `flock` that is
//      written but never reached (an early `exec`, a misplaced `fi`) leaves
//      the script running exactly as before.
//   3. THE REFUSAL DEGRADES. On a timeout this must exit non-zero WITHOUT
//      running the command. "Run anyway" measures under contention; "skip
//      quietly and exit 0" reports a green that means "did not measure".
//      Both are worse than a red.
//
// Blocks 2 and 3 are BEHAVIOURAL: this process takes a REAL `flock(2)` on a
// real file and then drives the REAL script against it. No mock — the thing
// under test is a kernel advisory lock, and a mocked one proves nothing about
// it. The lock files are private to the test through the runner/wrapper's
// shared env seam because the real /tmp/vibe3d-run-test.lock is routinely
// held by a live test lane on this host, which would make the "free host" arm
// a coin flip and make `dub test --config=tests` contend with production.
module tests.unit.perf_lock_test;

import std.algorithm : canFind;
import std.conv      : to, octal;
import std.exception : enforce;
import std.file      : exists, readText, tempDir, remove, mkdir, rmdirRecurse;
import std.format    : format;
import std.path      : buildPath, dirName;
import std.process   : execute, spawnProcess, wait, thisProcessID, environment, pipe;
import std.stdio     : File;
import std.string    : startsWith, strip;
import core.thread   : Thread;
import core.time     : msecs;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum scriptPath = buildPath(repoRoot, "tools", "perf", "lib", "with_perf_lock.sh");
private enum runTestPath = buildPath(repoRoot, "run_test.d");

// The behavioural cell is deliberately FIRST: on the broken tree the value
// check below also fails, but a string/value mismatch is not evidence that two
// processes were prevented from overlapping.
unittest { proveTmpdirContention(); }

// ---------------------------------------------------------------------------
// 2. The two lock paths agree — ask BOTH programs for the values they will
//    actually use, under two different TMPDIR values.
// ---------------------------------------------------------------------------
unittest
{
    enforce(exists(scriptPath),  scriptPath  ~ " not found — repo root misderived");
    enforce(exists(runTestPath), runTestPath ~ " not found — repo root misderived");

    const tag = thisProcessID.to!string;
    const tmpA = buildPath(tempDir(), "vibe3d-perf-lock-path-a-" ~ tag);
    const tmpB = buildPath(tempDir(), "vibe3d-perf-lock-path-b-" ~ tag);
    mkdir(tmpA);
    mkdir(tmpB);
    scope(exit) {
        if (exists(tmpA)) rmdirRecurse(tmpA);
        if (exists(tmpB)) rmdirRecurse(tmpB);
    }

    string queriedRunLock(string tmp) {
        auto env = environment.toAA;
        env["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = "";
        env["TMPDIR"] = tmp;
        env["VIBE3D_HARNESS_LOG"] = "off";
        auto r = execute([runTestPath, "--print-run-lock"], env);
        enforce(r.status == 0, "run_test.d --print-run-lock failed:\n" ~ r.output);
        return r.output.strip;
    }
    string queriedPerfRunLock(string tmp) {
        auto env = environment.toAA;
        env["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = "";
        env["TMPDIR"] = tmp;
        auto r = execute(["bash", scriptPath, "--print-runtest-lock"], env);
        enforce(r.status == 0,
            "with_perf_lock.sh --print-runtest-lock failed:\n" ~ r.output);
        return r.output.strip;
    }

    const runA = queriedRunLock(tmpA);
    const runB = queriedRunLock(tmpB);
    const perfA = queriedPerfRunLock(tmpA);
    const perfB = queriedPerfRunLock(tmpB);
    assert(runA == runB,
        "run_test.d changes its host-wide lock with TMPDIR:\n  A: " ~ runA
        ~ "\n  B: " ~ runB);
    assert(perfA == perfB,
        "with_perf_lock.sh changes its run-test lock with TMPDIR:\n  A: "
        ~ perfA ~ "\n  B: " ~ perfB);
    assert(runA == perfA,
        "the two programs reported different production run-lock paths:\n"
        ~ "  run_test.d: " ~ runA ~ "\n  with_perf_lock.sh: " ~ perfA);
    assert(runA == "/tmp/vibe3d-run-test.lock",
        "the default seam no longer names the production host lock: " ~ runA);

    // The seam must never be set by a workflow: a lane pointed at a
    // private lock file excludes nothing and says nothing.
    foreach (wf; ["perf.yaml", "ci.yaml", "tsan.yaml", "sanitizer.yaml"]) {
        const p = buildPath(repoRoot, ".github", "workflows", wf);
        if (!exists(p)) continue;
        assert(!readText(p).canFind("VIBE3D_PERF_RUNTEST_LOCK_PATH"),
            wf ~ " sets the lock-path TEST SEAM. That redirects the perf lane "
            ~ "onto a lock nothing else takes, which is exactly the silent "
            ~ "failure this file exists to prevent.");
        assert(!readText(p).canFind("VIBE3D_PERF_SKIP_RUNTEST_LOCK"),
            wf ~ " sets VIBE3D_PERF_SKIP_RUNTEST_LOCK — the perf lane would "
            ~ "measure beside live test runs again.");
    }
}

// ---------------------------------------------------------------------------
// 1. Two REAL run_test.d processes with different TMPDIR values still contend
//    for one host-wide lock. The second must time out while the first holds it,
//    then acquire it after release. This is the mechanism, not a source string.
// ---------------------------------------------------------------------------
private void proveTmpdirContention()
{
    const tag = thisProcessID.to!string;
    const tmpA = buildPath(tempDir(), "vibe3d-run-lock-probe-a-" ~ tag);
    const tmpB = buildPath(tempDir(), "vibe3d-run-lock-probe-b-" ~ tag);
    const lock = buildPath(tempDir(), "vibe3d-run-lock-private-" ~ tag);
    const holderLog = buildPath(tempDir(), "vibe3d-run-lock-holder-" ~ tag ~ ".log");
    mkdir(tmpA);
    mkdir(tmpB);
    scope(exit) {
        if (exists(holderLog)) remove(holderLog);
        if (exists(lock)) remove(lock);
        if (exists(tmpA)) rmdirRecurse(tmpA);
        if (exists(tmpB)) rmdirRecurse(tmpB);
    }

    auto holderEnv = environment.toAA;
    holderEnv["VIBE3D_INHERITED_RUN_LOCK_PID"] = "";
    holderEnv["VIBE3D_INHERITED_RUN_LOCK_FD"] = "";
    holderEnv["TMPDIR"] = tmpA;
    holderEnv["VIBE3D_HARNESS_LOG"] = "off";
    holderEnv["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = lock;
    auto releasePipe = pipe();
    auto holderOut = File(holderLog, "w");
    auto holder = spawnProcess(
        [runTestPath, "--probe-run-lock-until-eof", "--lock-timeout", "600"],
        releasePipe.readEnd, holderOut, holderOut, holderEnv);
    holderOut.close();
    bool holderReaped;
    scope(exit) {
        if (releasePipe.writeEnd.isOpen) releasePipe.writeEnd.close();
        if (!holderReaped) wait(holder);
    }

    bool holderReady;
    // The holder uses the production 600 s budget. After task 4870 it may be
    // queued behind a real nightly measurement, which is correct behaviour;
    // let that wait resolve instead of misreporting it as a broken probe.
    foreach (_; 0 .. 6_100) {
        if (exists(holderLog)
         && readText(holderLog).canFind("RUN LOCK ACQUIRED:")) {
            holderReady = true;
            break;
        }
        Thread.sleep(100.msecs);
    }
    enforce(holderReady,
        "first run_test.d never reported acquiring its lock:\n"
        ~ (exists(holderLog) ? readText(holderLog) : "(no log)"));
    assert(readText(holderLog).canFind("RUN LOCK ACQUIRED: " ~ lock),
        "the run_test.d contention probe ignored "
        ~ "VIBE3D_PERF_RUNTEST_LOCK_PATH; expected the private module-test "
        ~ "lock " ~ lock ~ ":\n" ~ readText(holderLog));

    auto contenderEnv = environment.toAA;
    contenderEnv["VIBE3D_INHERITED_RUN_LOCK_PID"] = "";
    contenderEnv["VIBE3D_INHERITED_RUN_LOCK_FD"] = "";
    contenderEnv["TMPDIR"] = tmpB;
    contenderEnv["VIBE3D_HARNESS_LOG"] = "off";
    contenderEnv["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = lock;
    auto blocked = execute(
        [runTestPath, "--probe-run-lock", "0", "--lock-timeout", "1"],
        contenderEnv);
    assert(blocked.status != 0,
        "two run_test.d processes with different TMPDIR values acquired "
        ~ "simultaneously: the contender exited 0 while the holder reported "
        ~ "RUN LOCK ACQUIRED");
    assert(blocked.output.canFind("NO TESTS RAN")
        && blocked.output.canFind("host-contention exit"),
        "the contender did not report the real lock-timeout protocol:\n"
        ~ blocked.output);

    // Release only after both refusal facts above are fixed in this process.
    // EOF is a peer-owned handshake, not a signal sent to the holder.
    releasePipe.writeEnd.close();

    const holderStatus = wait(holder);
    holderReaped = true;
    assert(holderStatus == 0,
        "the holder run_test.d failed:\n" ~ readText(holderLog));

    auto released = execute(
        [runTestPath, "--probe-run-lock", "0", "--lock-timeout", "1"],
        contenderEnv);
    assert(released.status == 0
        && released.output.canFind("RUN LOCK ACQUIRED:"),
        "the second TMPDIR could not acquire the lock after release:\n"
        ~ released.output);
}

// ---------------------------------------------------------------------------
// 3 + 4. The real lock, the real script: held => REFUSED, non-zero, and the
//    wrapped command never ran. Free => runs, and the command's own exit code
//    survives the wrapper.
// ---------------------------------------------------------------------------
private extern(C) int flock(int fd, int operation) nothrow @nogc;
private enum LOCK_EX = 2, LOCK_UN = 8, LOCK_NB = 4;

unittest
{
    import core.sys.posix.fcntl : open, O_RDWR, O_CREAT;
    import core.sys.posix.unistd : close;
    import std.string : toStringz;

    const tag      = thisProcessID.to!string;
    const lock     = buildPath(tempDir(), "vibe3d-perf-lock-test-runtest-" ~ tag);
    const perfLock = buildPath(tempDir(), "vibe3d-perf-lock-test-perf-" ~ tag);
    const witness  = buildPath(tempDir(), "vibe3d-perf-lock-witness-" ~ tag);
    string[string] seam = [
        "VIBE3D_PERF_LOCK_PATH":         perfLock,
        "VIBE3D_PERF_RUNTEST_LOCK_PATH": lock,
        // A runner spawned by a test is not this host's load, and this file
        // both NAMES run_test.d and spawns a child, which is the shape
        // `harness_log_isolation_census_test.d` refuses. The census is textual
        // and cannot see that the child here is the wrapper script rather than
        // the runner, so satisfy it the way the rule intends rather than by
        // exempting the file: every child this test starts inherits a
        // neutralised harness log, and if the wrapper ever grows a path into
        // the runner, the isolation is already in place instead of being
        // discovered by a polluted ~/.local/state/vibe3d/harness.jsonl.
        "VIBE3D_HARNESS_LOG":            "off",
    ];
    scope(exit) foreach (f; [lock, perfLock, witness]) if (exists(f)) remove(f);
    if (exists(witness)) remove(witness);

    // A waiting perf wrapper must not erase the live runner's diagnostic
    // stamp merely by opening the file before flock. This exact content is
    // also what acquireRunLock reads into harness.lock_holder_pid.
    const holderStamp = format("pid %d", thisProcessID);
    static import std.file;
    std.file.write(lock, holderStamp ~ "\n");

    // Take the run-test lock the way run_test.d takes it: flock(2) LOCK_EX on
    // an fd this process keeps open. Advisory locks are per open-file-
    // description, so the child script's own fd genuinely blocks on it.
    const fd = open(lock.toStringz, O_RDWR | O_CREAT, octal!"644");
    enforce(fd >= 0, "could not open the test lock file " ~ lock);
    bool released;
    void release() { if (!released) { released = true; flock(fd, LOCK_UN); close(fd); } }
    scope(exit) release();
    enforce(flock(fd, LOCK_EX | LOCK_NB) == 0,
        "could not establish the precondition: this process could not take "
        ~ lock ~ ", so the refusal below would prove nothing");

    // 3. HELD => refuse, non-zero, and the wrapped command must NOT have run.
    {
        auto r = execute(["bash", scriptPath, "1", "--",
                          "bash", "-c", "touch " ~ witness], seam);
        assert(r.status != 0,
            "with_perf_lock.sh returned 0 while a test run held " ~ lock
            ~ " — a green that means 'measured under contention':\n" ~ r.output);
        assert(!exists(witness),
            "with_perf_lock.sh RAN the wrapped command while " ~ lock
            ~ " was held. The refusal must happen BEFORE the command, never "
            ~ "degrade to 'run anyway'.");
        assert(r.output.canFind("REFUSED") && r.output.canFind(lock),
            "the refusal does not name the lock it could not take:\n" ~ r.output);
        assert(r.output.canFind("(" ~ holderStamp ~ ")"),
            "with_perf_lock.sh erased the live runner's stamp before flock; "
            ~ "the timeout reported the holder as unknown:\n" ~ r.output);
    }

    // The skip flag is the documented one-line reversal and must actually
    // reverse it — otherwise the escape hatch is a lie and nobody can measure
    // on a host where no test lane exists.
    {
        auto env2 = seam.dup;
        env2["VIBE3D_PERF_SKIP_RUNTEST_LOCK"] = "1";
        auto r = execute(["bash", scriptPath, "1", "--",
                          "bash", "-c", "touch " ~ witness ~ "; exit 0"], env2);
        scope(exit) if (exists(witness)) remove(witness);
        assert(r.status == 0, "VIBE3D_PERF_SKIP_RUNTEST_LOCK=1 did not skip "
            ~ "the run-test lock:\n" ~ r.output);
        assert(r.output.canFind("WITHOUT excluding a concurrent test run"),
            "the skip path must say loudly what it gave up:\n" ~ r.output);
    }

    release();

    // 2 (reverse direction). FREE => the command runs and its own exit code
    // survives. Without this cell the assertions above are satisfied by a
    // script that refuses unconditionally.
    {
        auto r = execute(["bash", scriptPath, "5", "--",
                          "bash", "-c", "touch " ~ witness ~ "; exit 0"], seam);
        scope(exit) if (exists(witness)) remove(witness);
        assert(r.status == 0, "with_perf_lock.sh refused on a free host:\n" ~ r.output);
        assert(exists(witness), "the wrapped command did not run:\n" ~ r.output);
        assert(r.output.canFind("acquired " ~ lock),
            "the run-test lock was never acquired on a free host — the second "
            ~ "flock is not on the executed path at all:\n" ~ r.output);
        assert(readText(lock).strip.startsWith("pid "),
            "the perf wrapper acquired the run-test lock but left no holder "
            ~ "pid for a queued run_test.d to record");
        assert(r.output.canFind("loadavg BEFORE the measuring window"),
            "the load sample (card 3430's residual, made visible) is missing:\n" ~ r.output);
    }
    {
        // The wrapper `exec`s, so a non-zero command code must come back
        // unchanged — not swallowed into a success, not remapped onto the
        // wrapper's own "refused" code 1.
        auto r = execute(["bash", scriptPath, "5", "--", "bash", "-c", "exit 7"], seam);
        assert(r.status == 7, "the wrapped command's exit code did not survive "
            ~ "the wrapper (got " ~ r.status.to!string ~ "):\n" ~ r.output);
    }
}
