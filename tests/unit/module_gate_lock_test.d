// The `dub test --config=tests` process is itself a CPU-heavy host lane. It
// holds one run SLOT of the family run_test.d and nightly perf share
// (tools/harness/runslots.d) for its entire lifetime (task 4980; slots since
// task 6205, evidence in the matching task cards). The intentional price is
// queueing: while every slot is held this gate waits, up to its timeout. Under
// a gate-pool dispatcher the gate BORROWS the dispatcher's slot instead, so one
// gate pair is one slot.
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

import tools.harness.runslots : RunSlot, borrowInheritedSlot, configuredRunSlots,
    kCanonicalRunSlotBase, kRunSlotBaseEnv, runSlotBase, runSlotPath,
    tryAcquireFreeSlot;

private enum kModuleGateTimeoutEnv = "VIBE3D_MODULE_GATE_LOCK_TIMEOUT_SECONDS";
private enum kDefaultModuleGateTimeoutSeconds = 600;
private enum kRunLockPathEnv = "VIBE3D_PERF_RUNTEST_LOCK_PATH";
private enum kHarnessLogEnv = "VIBE3D_HARNESS_LOG";
private enum kProbeOnlyEnv = "VIBE3D_MODULE_GATE_PROBE_ONLY";
// Build-only (task 6205): `dub test` has no build-without-run mode, and ai-gate
// must hold its cross-slot dub lock for the BUILD only, never for a run or a
// slot wait. With this set the binary stops before taking a slot and before any
// unittest, says so, and prints no UT-TOTAL line -- so no caller can read the
// exit 0 as a verdict. The caller then runs ./vibe3d-test-tests itself.
private enum kBuildOnlyEnv = "VIBE3D_MODULE_GATE_BUILD_ONLY";
private enum kInheritedRunLockPidEnv = "VIBE3D_INHERITED_RUN_LOCK_PID";
private enum kInheritedRunLockFdEnv = "VIBE3D_INHERITED_RUN_LOCK_FD";

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");

// Kept open deliberately and never explicitly released: flock ownership lasts
// until process exit, including every unittest that druntime runs before main.
// A local variable would close too early and turn the gate into a startup-only
// handshake. The OS closes this descriptor on every exit path.
private __gshared RunSlot gModuleGateSlot;

/// The slot this gate holds. The parallel runner (tests/unit/ut_runner.d)
/// hands it to its worker processes as a lease, so N workers are one slot.
package RunSlot moduleGateSlot() { return gModuleGateSlot; }

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

private void acquireModuleGateLock()
{
    const base = runSlotBase();
    if (borrowInheritedSlot(base, gModuleGateSlot)) {
        stderr.writefln("module unittest gate: borrowing run slot %d (%s) from "
                      ~ "its caller", gModuleGateSlot.index, gModuleGateSlot.path);
        return;
    }
    const count = configuredRunSlots();
    if (count.error.length)
        abortModuleGate("MODULE TESTS DID NOT RUN — invalid run-slot count: "
                      ~ count.error);
    if (tryAcquireFreeSlot(base, count.n, gModuleGateSlot, "module-gate"))
        return;

    const timeoutSeconds = moduleGateTimeoutSeconds();
    stderr.writefln("module unittest gate: all %d run slots of %s are held by "
                  ~ "other test/perf runs; waiting up to %ds. This intentional "
                  ~ "queue trades test throughput for uncontaminated perf "
                  ~ "measurements.", count.n, base, timeoutSeconds);
    foreach (waited; 1 .. timeoutSeconds + 1) {
        Thread.sleep(1.seconds);
        if (tryAcquireFreeSlot(base, count.n, gModuleGateSlot, "module-gate")) {
            stderr.writefln("module unittest gate: acquired run slot %d after %ds",
                            gModuleGateSlot.index, waited);
            return;
        }
        if (waited % 15 == 0)
            stderr.writefln("module unittest gate: still waiting for a free "
                          ~ "shared test/perf run slot (%ds)", waited);
    }

    abortModuleGate(format(
        "MODULE TESTS DID NOT RUN — timed out after %ds waiting for one of the "
      ~ "%d run slots of %s. The module gate intentionally queues behind "
      ~ "nightly perf and other test runs; retry after a holder exits.",
        timeoutSeconds, count.n, base));
}

// druntime executes module unittests before main, so this is the only startup
// point that brackets the complete gate without relying on dub's generated
// main. gModuleGateSlot keeps the acquired descriptor alive until exit.
shared static this()
{
    if (environment.get(kBuildOnlyEnv, "") == "1") {
        import core.stdc.stdlib : exit;
        stderr.writeln("MODULE TESTS DID NOT RUN — " ~ kBuildOnlyEnv
                     ~ "=1: the test binary was built; run it to get a verdict");
        stderr.flush();
        exit(0);
    }
    acquireModuleGateLock();
    // Test seam for the standalone probe below: report the slot and stop, so a
    // cell can witness acquisition without running this module's cells again.
    if (environment.get(kProbeOnlyEnv, "") == "1") {
        import core.stdc.stdlib : exit;
        stderr.writefln("module gate slot: %d %s", gModuleGateSlot.index,
                        gModuleGateSlot.borrowed ? "borrowed" : "own");
        stderr.flush();
        exit(0);
    }
}

private string[string] isolatedChildEnvironment()
{
    auto env = environment.toAA;
    env[kHarnessLogEnv] = "off";
    env[kInheritedRunLockPidEnv] = "";
    env[kInheritedRunLockFdEnv] = "";
    return env;
}

unittest // the module gate holds a real slot of the family run_test.d takes
{
    assert(gModuleGateSlot.held,
        "module gate reached a unittest without holding a run slot");
    // Ask the PRODUCTION runner which slots of the same family are held. It
    // answers by flock, so this is the kernel's view, not ours. The family is
    // the production default unless the seam was set for this whole binary
    // (a standalone run on a busy host); perf_lock_test pins the default.
    auto env = isolatedChildEnvironment();
    env["VIBE3D_RUN_SLOTS"] = "6";
    auto child = execute([runnerPath, "--print-run-slots"], env);
    assert(child.status == 0, "run_test.d --print-run-slots failed:\n" ~ child.output);
    const want = format("slot %d %s held", gModuleGateSlot.index,
                        runSlotPath(runSlotBase(), gModuleGateSlot.index));
    assert(child.output.canFind(want), format(
        "run_test.d does not see the module gate's slot as held; expected `%s`:\n%s",
        want, child.output));
    if (!gModuleGateSlot.borrowed)
        assert(child.output.canFind(want ~ format(" pid %d module-gate", thisProcessID)),
            "the held slot does not carry the module gate's stamp:\n" ~ child.output);
}

unittest // a second module gate must fail loudly while every slot is held
{
    const probeBin = buildPath(tempDir(), format(
        "vibe3d-module-gate-timeout-%d", thisProcessID));
    const privateBase = buildPath(tempDir(), format(
        "vibe3d-module-gate-full-%d.lock", thisProcessID));
    scope(exit) if (exists(probeBin)) cast(void) collectException(remove(probeBin));
    scope(exit) if (exists(privateBase))
        cast(void) collectException(remove(privateBase));

    auto build = execute(["dmd", "-i", "-main", "-I" ~ repoRoot,
                          __FILE_FULL_PATH__, "-of=" ~ probeBin]);
    enforce(build.status == 0, format(
        "could not compile the standalone module-gate probe (status %d):\n%s",
        build.status, build.output));
    // dmd leaves `<probeBin>.o` beside the binary; nothing removed it, and
    // 154 of them (4.6 MB each) had piled up in /tmp by 2026-09-25 (card
    // gate-speedup). Removed at once, and checked, so a leak is red here.
    cast(void) collectException(remove(probeBin ~ ".o"));
    assert(!exists(probeBin ~ ".o"), "the probe build's object file leaks: " ~ probeBin ~ ".o");

    // Fill the private one-slot family ourselves, so the probe's only way
    // forward is the give-up path.
    RunSlot full;
    enforce(tryAcquireFreeSlot(privateBase, 1, full, "full-host witness"),
        "could not take the private slot this cell needs held");
    scope(exit) { import tools.harness.runslots : releaseSlot; releaseSlot(full); }

    auto env = isolatedChildEnvironment();
    env[kModuleGateTimeoutEnv] = "1";
    env[kRunLockPathEnv] = privateBase;
    env["VIBE3D_RUN_SLOTS"] = "1";
    auto child = execute([probeBin], env);
    assert(child.output.canFind("MODULE TESTS DID NOT RUN"),
        "module-gate timeout was silent; expected `MODULE TESTS DID NOT RUN`, got:\n"
      ~ child.output);
    assert(child.status != 0, format(
        "module-gate timeout returned success (%d), so CI could report a green "
      ~ "gate after running no unittests:\n%s", child.status, child.output));

    // The same full family, but the probe runs under a gate-pool style LEASE
    // on the held slot: it must borrow it, not queue behind it. The lease
    // descriptor is NOT inherited, exactly as `dub test` delivers it.
    auto leased = env.dup;
    leased[kProbeOnlyEnv] = "1";
    leased[kInheritedRunLockPidEnv] = thisProcessID.to!string;
    leased[kInheritedRunLockFdEnv] = full.fd.to!string;
    auto borrow = execute([probeBin], leased);
    assert(borrow.status == 0 && borrow.output.canFind("module gate slot: 0 borrowed"), format(
        "the module gate did not borrow its caller's held slot (status %d):\n%s",
        borrow.status, borrow.output));

    // Build-only stops BEFORE the slot: with the family still full it exits at
    // once instead of queueing, and it never claims to have run anything.
    auto buildOnly = env.dup;
    buildOnly[kBuildOnlyEnv] = "1";
    auto bo = execute([probeBin], buildOnly);
    assert(bo.status == 0 && bo.output.canFind("MODULE TESTS DID NOT RUN")
        && !bo.output.canFind("UT-TOTAL") && !bo.output.canFind("module gate slot"), format(
        "build-only did not stop before the slot (status %d):\n%s", bo.status, bo.output));

    // Control: the slot released, the same probe takes it as its own.
    { import tools.harness.runslots : releaseSlot; releaseSlot(full); }
    auto own = env.dup;
    own[kProbeOnlyEnv] = "1";
    auto freeRun = execute([probeBin], own);
    assert(freeRun.status == 0 && freeRun.output.canFind("module gate slot: 0 own"), format(
        "with its slot free the module gate did not take it (status %d):\n%s",
        freeRun.status, freeRun.output));
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
            from += kCanonicalRunSlotBase.length;
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
        foreach (seam; [kBuildOnlyEnv, kProbeOnlyEnv])
            assert(!text.canFind(seam),
                workflow ~ " sets " ~ seam ~ ", which stops the module gate before it runs");
    }
}
