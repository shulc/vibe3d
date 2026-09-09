// The `dub test --config=tests` process is itself a CPU-heavy host lane. It
// must share `/tmp/vibe3d-run-test.lock` with run_test.d and nightly perf for
// its entire lifetime (task 4980, evidence in the matching task card). The
// intentional price is queueing: this gate can wait behind either lane until
// its timeout. That throughput loss buys an uncontaminated performance signal.
module tests.unit.module_gate_lock_test;

import std.algorithm : canFind;
import std.conv      : octal, to;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.exception : collectException, enforce;
import std.file      : exists, readText, remove, tempDir;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;
import std.process   : Config, environment, execute, thisProcessID;
import std.stdio     : stderr, writeln;
import std.string    : indexOf, toStringz;

import core.thread            : Thread;
import core.time              : seconds;
import core.sys.posix.fcntl   : open, O_CREAT, O_RDWR;
import core.sys.posix.unistd  : close, ftruncate, getpid;
import core.sys.posix.sys.types : ssize_t;

private extern(C) int flock(int fd, int operation) nothrow @nogc;
private pragma(mangle, "write")
extern(C) ssize_t c_write(int fd, const(void)* buf, size_t count) nothrow @nogc;
private enum LOCK_EX = 2, LOCK_NB = 4;

private enum kCanonicalRunLock = "/tmp/vibe3d-run-test.lock";
private enum kModuleGateTimeoutEnv = "VIBE3D_MODULE_GATE_LOCK_TIMEOUT_SECONDS";
private enum kDefaultModuleGateTimeoutSeconds = 600;
private enum kRunLockPathEnv = "VIBE3D_PERF_RUNTEST_LOCK_PATH";
private enum kHarnessLogEnv = "VIBE3D_HARNESS_LOG";
private enum kInheritedRunLockPidEnv = "VIBE3D_INHERITED_RUN_LOCK_PID";
private enum kInheritedRunLockFdEnv = "VIBE3D_INHERITED_RUN_LOCK_FD";

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");

// Kept open deliberately and never explicitly released: flock ownership lasts
// until process exit, including every unittest that druntime runs before main.
// A local variable would close too early and turn the gate into a startup-only
// handshake. The OS closes this descriptor on every exit path.
private __gshared int gModuleGateLockFd = -1;

private noreturn abortModuleGate(string message)
{
    stderr.writeln(message);
    throw new Exception(message);
}

private int moduleGateTimeoutSeconds()
{
    const raw = environment.get(kModuleGateTimeoutEnv, "");
    if (!raw.length) return kDefaultModuleGateTimeoutSeconds;
    try {
        const value = raw.to!int;
        if (value > 0) return value;
    } catch (Exception) {}
    abortModuleGate(format(
        "MODULE TESTS DID NOT RUN — invalid %s=%s; expected a positive "
      ~ "timeout in seconds", kModuleGateTimeoutEnv, raw));
}

private void stampModuleGateHolder()
{
    if (ftruncate(gModuleGateLockFd, 0) != 0) {
        stderr.writeln("module unittest gate: acquired lock but could not "
                     ~ "truncate its diagnostic PID stamp");
        return;
    }
    const stamp = format("pid %d module-gate\n", getpid());
    if (c_write(gModuleGateLockFd, stamp.ptr, stamp.length) != stamp.length)
        stderr.writeln("module unittest gate: acquired lock but could not "
                     ~ "write its diagnostic PID stamp");
}

private void acquireModuleGateLock()
{
    gModuleGateLockFd = open(kCanonicalRunLock.toStringz,
                             O_RDWR | O_CREAT, octal!"644");
    if (gModuleGateLockFd < 0)
        abortModuleGate("MODULE TESTS DID NOT RUN — could not open canonical "
                      ~ "shared test/perf lock " ~ kCanonicalRunLock);

    if (flock(gModuleGateLockFd, LOCK_EX | LOCK_NB) == 0) {
        stampModuleGateHolder();
        return;
    }

    const timeoutSeconds = moduleGateTimeoutSeconds();
    stderr.writefln("module unittest gate: %s is held by another test/perf "
                  ~ "run; waiting up to %ds. This intentional queue trades "
                  ~ "test throughput for uncontaminated perf measurements.",
                    kCanonicalRunLock, timeoutSeconds);
    foreach (waited; 1 .. timeoutSeconds + 1) {
        Thread.sleep(1.seconds);
        if (flock(gModuleGateLockFd, LOCK_EX | LOCK_NB) == 0) {
            stderr.writefln("module unittest gate: acquired shared lock after %ds",
                            waited);
            stampModuleGateHolder();
            return;
        }
        if (waited % 15 == 0)
            stderr.writefln("module unittest gate: still waiting for shared "
                          ~ "test/perf lock (%ds)", waited);
    }

    close(gModuleGateLockFd);
    gModuleGateLockFd = -1;
    abortModuleGate(format(
        "MODULE TESTS DID NOT RUN — timed out after %ds waiting for %s. "
      ~ "The module gate intentionally queues behind nightly perf and other "
      ~ "test runs; retry after the holder exits.",
        timeoutSeconds, kCanonicalRunLock));
}

// druntime executes module unittests before main, so this is the only startup
// point that brackets the complete gate without relying on dub's generated
// main. gModuleGateLockFd keeps the acquired descriptor alive until exit.
shared static this()
{
    acquireModuleGateLock();
}

private string[string] isolatedChildEnvironment()
{
    auto env = environment.toAA;
    env[kHarnessLogEnv] = "off";
    env[kInheritedRunLockPidEnv] = "";
    env[kInheritedRunLockFdEnv] = "";
    return env;
}

unittest // the module gate and run_test.d cannot enter their runs together
{
    assert(gModuleGateLockFd >= 0,
        "module gate reached a unittest without a live lock descriptor");
    auto env = isolatedChildEnvironment();
    env.remove(kRunLockPathEnv); // exercise run_test.d's production default
    auto child = execute([runnerPath, "--probe-run-lock", "0",
                          "--lock-timeout", "1"], env);
    assert(child.status != 0, format(
        "module gate and run_test.d started simultaneously: the nested runner "
      ~ "acquired the canonical lock while this module unittest was running:\n%s",
        child.output));
    assert(child.output.canFind("NO TESTS RAN"),
        "run_test.d was blocked but did not report its zero-test timeout loudly:\n"
      ~ child.output);
}

unittest // a second module gate must fail loudly before its main can run
{
    const probeBin = buildPath(tempDir(), format(
        "vibe3d-module-gate-timeout-%d", thisProcessID));
    scope(exit) if (exists(probeBin)) cast(void) collectException(remove(probeBin));

    auto build = execute(["dmd", "-i", "-main", "-I" ~ repoRoot,
                          __FILE_FULL_PATH__, "-of=" ~ probeBin]);
    enforce(build.status == 0, format(
        "could not compile the standalone module-gate probe (status %d):\n%s",
        build.status, build.output));

    auto env = isolatedChildEnvironment();
    env[kModuleGateTimeoutEnv] = "1";
    auto child = execute([probeBin], env);
    assert(child.output.canFind("MODULE TESTS DID NOT RUN"),
        "module-gate timeout was silent; expected `MODULE TESTS DID NOT RUN`, got:\n"
      ~ child.output);
    assert(child.status != 0, format(
        "module-gate timeout returned success (%d), so CI could report a green "
      ~ "gate after running no unittests:\n%s", child.status, child.output));
}

unittest // a nested runner's private seam stays independent of the parent lock
{
    const privateLock = buildPath(tempDir(), format(
        "vibe3d-module-gate-nested-%d.lock", thisProcessID));
    scope(exit) if (exists(privateLock))
        cast(void) collectException(remove(privateLock));

    auto env = isolatedChildEnvironment();
    env[kRunLockPathEnv] = privateLock;
    auto sw = StopWatch(AutoStart.yes);
    auto child = execute([runnerPath, "--probe-run-lock", "0",
                          "--lock-timeout", "1"], env);
    sw.stop();
    const elapsedMs = sw.peek.total!"msecs";
    assert(child.status == 0 && child.output.canFind(
        "RUN LOCK ACQUIRED: " ~ privateLock), format(
        "nested run_test.d did not acquire its private lock while the parent "
      ~ "held the canonical lock (status %d, %d ms):\n%s",
        child.status, elapsedMs, child.output));
    assert(elapsedMs < 5_000, format(
        "nested run_test.d took %d ms on its private lock; it appears to have "
      ~ "queued behind the parent's canonical lock", elapsedMs));
    writeln(format("module-gate private nested runner: acquired in %d ms",
                   elapsedMs));
}

unittest // the six runner-spawning witnesses must stay on private lock paths
{
    static immutable string[] privateFiles = [
        "tests/unit/perf_lock_test.d",
        "tests/unit/run_test_pgid_test.d",
        "tests/unit/run_test_space_preflight_test.d",
        "tests/unit/run_test_scratch_test.d",
        "tests/unit/harness_log_isolation_census_test.d",
        "tests/test_harness_load_log.d",
    ];

    size_t population;
    size_t canonicalLiterals;
    foreach (relative; privateFiles) {
        const path = buildPath(repoRoot, relative);
        assert(exists(path), "private runner-lock roster lost " ~ relative);
        const text = readText(path);
        assert(text.canFind(kRunLockPathEnv),
            baseName(path) ~ " no longer names the private runner-lock seam");
        ++population;
        size_t from;
        while ((from = text.indexOf(`"/tmp/vibe3d-run-test.lock"`, from))
               != -1) {
            ++canonicalLiterals;
            from += kCanonicalRunLock.length;
        }
    }
    assert(population == 6, format(
        "private runner-lock roster population is %d, expected 6", population));
    assert(canonicalLiterals == 1, format(
        "the six private runner-lock files contain %d canonical path literals, "
      ~ "expected exactly the one production-default assertion in perf_lock_test.d; "
      ~ "a nested-runner path was redirected onto the parent's lock",
        canonicalLiterals));

    foreach (workflow; ["ci.yaml", "sanitizer.yaml"]) {
        const text = readText(buildPath(repoRoot, ".github", "workflows", workflow));
        assert(!text.canFind(kModuleGateTimeoutEnv),
            workflow ~ " overrides the module-gate timeout test seam");
    }
}
