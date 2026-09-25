// Run slots (task 6205): N counting slots replace the single host run lock.
// Every cell drives the REAL runner (run_test.d) on a private slot family
// named through the seam, so a live lane holding the production slots on this
// host can neither satisfy nor starve these cells.
//
//   1. N concurrent runs get N DISTINCT slots with disjoint port windows, and
//      run N+1 waits and gives up with NO TESTS RAN; a freed slot is reused.
//   2. A second run of ONE checkout is refused before it builds; releasing
//      that checkout's build lock turns the same command into a slot wait.
//   3. A descendant borrows its ancestor's slot through /proc, WITHOUT an
//      inherited descriptor (the shape `dub test` gives the module gate), and
//      a descriptor on the slot file that holds no flock is not a lease.
module tests.unit.run_slots_test;

import std.algorithm : canFind;
import std.conv      : octal, to;
import std.exception : enforce;
import std.file      : dirEntries, exists, readText, remove, SpanMode, tempDir;
import std.format    : format;
import std.path      : baseName, buildPath, dirName;
import std.process   : Config, environment, execute, pipe, Pid, spawnProcess,
                       thisProcessID, wait;
import std.regex     : matchFirst, regex;
import std.stdio     : File;
import std.string    : lineSplitter, startsWith, strip, toStringz;
import core.thread   : Thread;
import core.time     : msecs;

import core.sys.posix.fcntl  : open, O_CREAT, O_RDWR;
import core.sys.posix.unistd : close;

import tools.harness.runslots : RunSlot, kSlotPortStride, releaseSlot,
    runSlotPath, tryAcquireFreeSlot;

private extern(C) int flock(int fd, int operation) nothrow @nogc;
private enum LOCK_EX = 2, LOCK_NB = 4;

private enum repoRoot   = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum runnerPath = buildPath(repoRoot, "run_test.d");

private string privateBase(string tag)
{
    return buildPath(tempDir(), format("vibe3d-run-slots-%s-%d.lock", tag, thisProcessID));
}

private void removeFamily(string base)
{
    foreach (e; dirEntries(tempDir(), baseName(base) ~ "*", SpanMode.shallow))
        remove(e.name);
}

private string[string] childEnv(string base, int slots)
{
    auto env = environment.toAA;
    env["VIBE3D_HARNESS_LOG"] = "off";
    env["VIBE3D_PERF_RUNTEST_LOCK_PATH"] = base;
    env["VIBE3D_RUN_SLOTS"] = slots.to!string;
    env["VIBE3D_INHERITED_RUN_LOCK_PID"] = "";
    env["VIBE3D_INHERITED_RUN_LOCK_FD"] = "";
    return env;
}

private struct Holder { Pid pid; File release; string log; }

private Holder startHolder(string[string] env, string log)
{
    auto p = pipe();
    auto o = File(log, "w");
    auto pid = spawnProcess([runnerPath, "--probe-run-lock-until-eof",
                             "--lock-timeout", "60"], p.readEnd, o, o, env);
    o.close();
    foreach (_; 0 .. 600) {
        if (exists(log) && readText(log).canFind("RUN SLOT:")) break;
        Thread.sleep(100.msecs);
    }
    enforce(readText(log).canFind("RUN SLOT:"),
        "a slot holder never reported its slot:\n" ~ readText(log));
    return Holder(pid, p.writeEnd, log);
}

private void stopHolder(ref Holder h)
{
    if (h.release.isOpen) h.release.close();
    wait(h.pid);
    if (exists(h.log)) remove(h.log);
}

private int[2] slotAndPort(string output)
{
    auto m = output.matchFirst(regex(`RUN SLOT: (\d+) PORTS: (\d+)\.\.(\d+)`));
    enforce(!m.empty, "no RUN SLOT line in:\n" ~ output);
    return [m[1].to!int, m[2].to!int];
}

unittest // 1. N=2: distinct slots, disjoint ports, the third waits, reuse
{
    const base = privateBase("count");
    scope(exit) removeFamily(base);
    auto env = childEnv(base, 2);

    auto a = startHolder(env, base ~ ".holder-a.log");
    scope(exit) stopHolder(a);
    auto b = startHolder(env, base ~ ".holder-b.log");
    bool bStopped;
    scope(exit) if (!bStopped) stopHolder(b);

    const sa = slotAndPort(readText(a.log));
    const sb = slotAndPort(readText(b.log));
    assert(sa[0] != sb[0], format(
        "two concurrent runs were handed the SAME slot %d:\n%s\n%s",
        sa[0], readText(a.log), readText(b.log)));
    assert(sa[0] + sb[0] == 1, format(
        "with N=2 the two holders must own slots 0 and 1, got %d and %d", sa[0], sb[0]));
    const lo = sa[1] < sb[1] ? sa[1] : sb[1];
    const hi = sa[1] < sb[1] ? sb[1] : sa[1];
    assert(lo + kSlotPortStride <= hi, format(
        "the two slots' worker-port windows overlap: %d.. and %d..", lo, hi));

    auto third = execute([runnerPath, "--probe-run-lock", "0", "--lock-timeout", "1"], env);
    assert(third.status != 0 && third.output.canFind("NO TESTS RAN")
        && !third.output.canFind("RUN SLOT:"), format(
        "run N+1 did not wait and give up while both slots were held (status %d):\n%s",
        third.status, third.output));

    const freed = sb[0];
    stopHolder(b);
    bStopped = true;
    auto fourth = execute([runnerPath, "--probe-run-lock", "0", "--lock-timeout", "5"], env);
    assert(fourth.status == 0 && slotAndPort(fourth.output)[0] == freed, format(
        "a run after release did not take the freed slot %d:\n%s", freed, fourth.output));

    // A count outside 1..6 is refused loudly, never clamped into a guess.
    auto bad = env.dup;
    bad["VIBE3D_RUN_SLOTS"] = "7";
    auto invalid = execute([runnerPath, "--probe-run-lock", "0", "--lock-timeout", "1"], bad);
    assert(invalid.status != 0 && invalid.output.canFind("invalid run-slot count"), format(
        "VIBE3D_RUN_SLOTS=7 was not refused (status %d):\n%s", invalid.status, invalid.output));
}

unittest // 2. one checkout, two runs: refused before any build
{
    const base = privateBase("worktree");
    scope(exit) removeFamily(base);
    auto env = childEnv(base, 1);

    auto q = execute([runnerPath, "--print-run-slots"], env, Config.none,
                     size_t.max, repoRoot);
    enforce(q.status == 0, "--print-run-slots failed:\n" ~ q.output);
    string wtLock;
    foreach (line; q.output.lineSplitter)
        if (line.startsWith("worktree ")) wtLock = line["worktree ".length .. $].strip;
    enforce(wtLock.startsWith(base ~ ".wt."), format(
        "the per-checkout build lock is not under the private seam %s: '%s'",
        base, wtLock));

    // The only slot is ours too, so a run that gets PAST the checkout lock
    // stops at the slot wait instead of building anything.
    RunSlot slot;
    enforce(tryAcquireFreeSlot(base, 1, slot, "run-slots witness"),
        "could not take the private slot");
    scope(exit) releaseSlot(slot);

    const run = [runnerPath, "--lock-timeout", "1", "--no-build", "--stale-ok",
                 "test_harness_load_log"];
    const record = base ~ ".harness.jsonl";
    env["VIBE3D_HARNESS_LOG"] = record;
    {
        // Hold the checkout's build lock as a live first run would.
        const fd = open(wtLock.toStringz, O_RDWR | O_CREAT, octal!"644");
        enforce(fd >= 0, "could not open " ~ wtLock);
        enforce(flock(fd, LOCK_EX | LOCK_NB) == 0, "could not hold " ~ wtLock);
        scope(exit) close(fd);

        auto second = execute(run, env, Config.none, size_t.max, repoRoot);
        assert(second.status == 2
            && second.output.canFind("already running in this checkout"), format(
            "a second run of one checkout was not refused (status %d):\n%s",
            second.status, second.output));
        assert(!second.output.canFind("run slots"),
            "the duplicate run reached the slot wait before being refused:\n"
          ~ second.output);
        assert(exists(record) && readText(record).canFind(`"stage":"worktree_busy"`),
            "the refused duplicate run did not record stage worktree_busy:\n"
          ~ (exists(record) ? readText(record) : "(no record)"));
    }
    // Control: the checkout lock released, the same command reaches the slot.
    auto third = execute(run, env, Config.none, size_t.max, repoRoot);
    assert(third.status == 1 && third.output.canFind("NO TESTS RAN")
        && third.output.canFind("run slots"), format(
        "with the checkout free the run did not reach the slot wait (status %d):\n%s",
        third.status, third.output));
}

unittest // 3. a lease is read through /proc, and an unlocked fd is not one
{
    const base = privateBase("lease");
    scope(exit) removeFamily(base);
    auto env = childEnv(base, 1);

    RunSlot slot;
    enforce(tryAcquireFreeSlot(base, 1, slot, "lease witness"),
        "could not take the private slot");
    scope(exit) releaseSlot(slot);

    // The descriptor is NOT inherited (no Config.inheritFDs): the borrower
    // must prove the lease from /proc alone, as the module gate under dub must.
    auto leased = env.dup;
    leased["VIBE3D_INHERITED_RUN_LOCK_PID"] = thisProcessID.to!string;
    leased["VIBE3D_INHERITED_RUN_LOCK_FD"] = slot.fd.to!string;
    auto borrow = execute([runnerPath, "--probe-run-lock", "0", "--lock-timeout", "1"],
                          leased);
    assert(borrow.status == 0 && borrow.output.canFind("RUN SLOT: 0")
        && borrow.output.canFind("(borrowed)"), format(
        "a descendant could not borrow its ancestor's held slot through /proc "
      ~ "(status %d):\n%s", borrow.status, borrow.output));

    // Same file, same ancestor, but this descriptor holds no flock.
    const bare = open(runSlotPath(base, 0).toStringz, O_RDWR | O_CREAT, octal!"644");
    enforce(bare >= 0, "could not open a second descriptor on the slot");
    scope(exit) close(bare);
    leased["VIBE3D_INHERITED_RUN_LOCK_FD"] = bare.to!string;
    auto decoy = execute([runnerPath, "--probe-run-lock", "0", "--lock-timeout", "1"],
                         leased);
    assert(decoy.status != 0 && decoy.output.canFind("NO TESTS RAN"), format(
        "an unlocked descriptor on the slot file was accepted as a lease "
      ~ "(status %d):\n%s", decoy.status, decoy.output));
    // The same unlocked descriptor, INHERITED this time (the other route).
    auto inherited = execute([runnerPath, "--probe-run-lock", "0", "--lock-timeout", "1"],
                             leased, Config.inheritFDs);
    assert(inherited.status != 0 && inherited.output.canFind("NO TESTS RAN"), format(
        "an inherited unlocked descriptor on the slot file was accepted as a lease "
      ~ "(status %d):\n%s", inherited.status, inherited.output));

    // A process that is NOT a descendant of the holder cannot borrow, even
    // with the holder's real descriptor inherited.
    leased["VIBE3D_INHERITED_RUN_LOCK_FD"] = slot.fd.to!string;
    auto orphan = execute(["setsid", "--fork", runnerPath, "--probe-run-lock", "0",
                           "--lock-timeout", "1"], leased, Config.inheritFDs);
    assert(orphan.output.canFind("NO TESTS RAN") && !orphan.output.canFind("RUN SLOT:"),
        "a reparented (non-descendant) process borrowed the slot:\n" ~ orphan.output);
}

unittest // 5. a real run's workers take the HELD slot's port window
{
    // Slot 0 is held, so this run gets slot 1; -j 40 exceeds the 36-port
    // window, so the run refuses right after deriving its ports and prints
    // them, before any barrier, build or worker. The window printed is the
    // one `port` was set to, not the probe's own arithmetic.
    const base = privateBase("ports");
    scope(exit) removeFamily(base);
    auto env = childEnv(base, 2);
    RunSlot zero;
    enforce(tryAcquireFreeSlot(base, 1, zero, "ports witness"), "could not take slot 0");
    scope(exit) releaseSlot(zero);
    auto r = execute([runnerPath, "-j", "40", "--no-build", "--lock-timeout", "1"],
                     env, Config.none, size_t.max, repoRoot);
    assert(r.status == 2 && r.output.canFind("exceeds this slot's 36-port window (28116..28151)"),
        format("a slot-1 run did not derive the slot-1 window 28116.. (status %d):\n%s",
               r.status, r.output));
}

unittest // 4. inside a user namespace the lease is read from the INHERITED fd
{
    // There another process's /proc/<pid>/fd is unreadable (EACCES), so only
    // the inherited-descriptor route can prove the lease -- the shape of
    // test_harness_load_log's constrained cell C.
    import std.stdio : writeln;
    auto probe = execute(["unshare", "--user", "--map-root-user", "true"]);
    if (probe.status != 0) {
        writeln("run_slots_test cell 4: SKIPPED — unshare --user is unavailable");
        return;
    }
    const base = privateBase("userns");
    scope(exit) removeFamily(base);
    auto env = childEnv(base, 1);
    RunSlot slot;
    enforce(tryAcquireFreeSlot(base, 1, slot, "userns lease witness"),
        "could not take the private slot");
    scope(exit) releaseSlot(slot);
    env["VIBE3D_INHERITED_RUN_LOCK_PID"] = thisProcessID.to!string;
    env["VIBE3D_INHERITED_RUN_LOCK_FD"] = slot.fd.to!string;
    auto r = execute(["unshare", "--user", "--map-root-user", runnerPath,
                      "--probe-run-lock", "0", "--lock-timeout", "1"],
                     env, Config.inheritFDs);
    assert(r.status == 0 && r.output.canFind("(borrowed)"), format(
        "a descendant in a user namespace could not borrow through its inherited "
      ~ "descriptor (status %d):\n%s", r.status, r.output));
}
