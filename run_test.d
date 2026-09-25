#!/usr/bin/env rdmd
/**
 * vibe3d test runner.
 *
 *   ./run_test.d                     # all tests
 *   ./run_test.d bevel selection     # subset
 *   ./run_test.d -v test_bevel       # verbose output
 *   ./run_test.d --keep              # leave vibe3d running after the run
 *   ./run_test.d --no-build          # skip `dub build`
 *   ./run_test.d -j N                # override the worker count (each worker
 *                                      gets its own vibe3d on a private port)
 *   VIBE3D_TEST_DISPLAY=:1 ./run_test.d # explicitly give workers one X display
 *   ./run_test.d --print-scratch     # name this checkout's scratch tree, exit
 *   ./run_test.d --print-run-lock    # name the host-wide run lock, exit
 *   ./run_test.d --probe-worker-display # report an owned worker's /proc env
 *   ./run_test.d --check-protocol    # prepared-protocol census alone, exit 0/2
 *   ./run_test.d --timeout N         # per-test wall-clock cap in seconds
 *                                      (default 600; 0 = no cap)
 *
 * With no -j the worker count auto-scales: clamp(totalCPUs/4, 4, 12), or the
 * VIBE3D_TEST_JOBS env var when set. An explicit -j always wins.
 */

module run_test;

// The runner is a 12 MB process that mostly sleeps: in the run-lock wait
// loop, in `wait()` on a worker's vibe3d, in HTTP polls. druntime's default
// PARALLEL GC spawns one mark thread per core, and on this host those 31
// idle threads were measured at 1 200-1 450 % CPU — contending on the mark
// event's mutex (`Gcx.scanBackground` -> `Event.wait` -> `__lll_lock_wait`)
// while the main thread slept in `Thread.sleep(1.seconds)` waiting for
// another runner (2026-08-25: two waiting runners = 28 cores burnt for
// nothing). The runner gains nothing from parallel marking; turn it off.
// This must be `rt_options` in the SOURCE: `./run_test.d --DRT-gcopt=...`
// never reaches the runner, because rdmd is itself a D program and druntime
// strips `--DRT-*` from ITS argv first.
extern(C) __gshared string[] rt_options = ["gcopt=parallel:0"];

import std.algorithm : canFind, sort, each, map, sum, minIndex;
import std.array     : array, appender, join;
import std.conv      : to, octal;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.json      : JSONValue, parseJSON, JSONType;
import std.math      : isNaN;
// Import std.file fully so the timings cache, the build stamp and the mold
// probe can call `std.file.write` without colliding with the `write` from
// std.stdio.
static import std.file;
import std.file : exists, isFile, isDir, mkdirRecurse, rmdirRecurse,
                  dirEntries, SpanMode, tempDir, readText, getcwd;
import std.format    : format;
import std.getopt    : getopt, config;
import std.parallelism : parallel, totalCPUs;
import std.path      : baseName, buildPath, stripExtension, dirName;
import std.process   : spawnProcess, spawnShell, wait, tryWait, executeShell,
                       execute, Config, Pid, ProcessException, environment;
import std.range     : empty;
import std.stdio     : writeln, writefln, write, stdin, stdout, stderr, File;
import std.string    : startsWith, endsWith, indexOf, split, splitLines, strip;

import core.thread        : Thread;
import core.time          : msecs, seconds, dur, Duration;
import core.stdc.stdlib   : exit;
import core.sys.posix.signal : signal, kill, SIGINT, SIGTERM, SIGKILL;
import core.sys.posix.unistd : isatty, STDOUT_FILENO, close, getpid, ftruncate,
                               setpgid, getpgrp, getppid;
import core.sys.posix.fcntl  : open, O_RDWR, O_CREAT, O_WRONLY, O_APPEND;
import core.sys.posix.sys.stat : fstat, stat, stat_t;
import core.sys.posix.sys.types : ssize_t;

import tools.harness.hostspace : SpaceAvailability, availabilityDetails,
    humanBytes, kMinPreflightFreeBytes, scratchRoot, spaceAvailability,
    spacePreflightMessage;
import tools.harness.runslots : RunSlot, borrowInheritedSlot, configuredRunSlots,
    kInheritedRunLockFdEnv, kInheritedRunLockPidEnv, kMaxRunSlots,
    kSlotPortStride, runSlotBase, runSlotFamily, runSlotPath, runSlotsConfigPath,
    slotHeld, slotPortBase, slotStamp, stampSlot, tryAcquireFreeSlot,
    worktreeLockPath;

// flock(2) is not surfaced by this druntime's posix bindings; declare it.
extern(C) int flock(int fd, int operation) nothrow @nogc;
pragma(mangle, "write")
extern(C) ssize_t c_write(int fd, const(void)* buf, size_t count) nothrow @nogc;
enum LOCK_EX = 2;   // exclusive lock
enum LOCK_NB = 4;   // non-blocking
enum LOCK_UN = 8;   // unlock

// ---------------------------------------------------------------------------
// Lifecycle state — accessed by signal handler
// ---------------------------------------------------------------------------

__gshared int[]  vibePids;     // worker PIDs to kill on signal / cleanup
__gshared ushort g_attachPort; // --attach: drive an already-running endpoint
                               // (e.g. the visual_test_proxy) instead of
                               // spawning our own vibe3d. 0 = normal mode.
__gshared string scratchDir;
__gshared bool   keepVibe;
__gshared bool   useColor;
__gshared int    runLockFd = -1;  // held for the whole run; see acquireRunLock
__gshared bool   runLockBorrowed; // verified descendant; outer runner owns fd
__gshared string projLibPath;  // prebuilt project test-lib (see buildProjectLib)
__gshared Duration g_testTimeout;   // per-test wall-clock cap; zero = no cap
__gshared int[]  testGroupPids;     // process-group leader pid of each RUNNING
                                    // test (0 = retired slot). A test that is
                                    // still running when we are interrupted is
                                    // in its own process group (see runOne), so
                                    // it no longer gets the terminal's SIGINT —
                                    // the handler below has to deliver it.
__gshared string moldFlag;     // " -L-fuse-ld=mold" for the lib link path; "" when mold unusable

enum workerDisplayEnv = "VIBE3D_TEST_DISPLAY";

// Machine-aware default worker count. See the call site in main() for the
// rationale; kept as a free function so run_all.d can mirror the same formula.
// VIBE3D_TEST_JOBS pins it per host (e.g. export it in your shell rc) so you
// don't have to pass -j every time; an explicit -j still overrides.
int defaultJobs() {
    import std.algorithm : clamp;
    const env = environment.get("VIBE3D_TEST_JOBS", "");
    if (env.length) {
        try { const n = env.to!int; if (n >= 1) return n; } catch (Exception) {}
    }
    return clamp(cast(int)totalCPUs / 4, 4, 12);
}

string col(string code, string s) {
    return useColor ? "\033[" ~ code ~ "m" ~ s ~ "\033[0m" : s;
}

string red   (string s) { return col("31", s); }
string green (string s) { return col("32", s); }
string yellow(string s) { return col("33", s); }
string dim   (string s) { return col("2",  s); }
string bold  (string s) { return col("1",  s); }

// ---------------------------------------------------------------------------
// Scratch tree identity
// ---------------------------------------------------------------------------
//
// THE SCRATCH TREE IS KEYED BY THE CHECKOUT IT IS RUN FROM, and that is the
// whole of the identity. Everything below is why it is not keyed by anything
// else, because the previous key looked right and was not (task 1282).
//
// It used to be `tempDir()/vibe3d-tests-<environment.get("PPID", "0")>`. Bash
// does not EXPORT `PPID`: it is a shell variable, and `environ` has no entry
// for it. Measured, not reasoned:
//
//     $ bash -c 'echo "in-shell PPID=$PPID"; env | grep -c "^PPID="'
//     in-shell PPID=5129
//     0
//
// So the lookup missed and took its default in EVERY invocation, from every
// checkout, on every host: one literal `/tmp/vibe3d-tests-0` shared by every
// lane on the machine. The cost was not a wrong path, it was a wrong DIAGNOSIS
// — the failure surfaces as `worker_N: Directory not empty` out of the startup
// `rmdirRecurse`, before a single test has run, and exits 1 exactly like a red
// suite. A lane spent an afternoon of task 1280 treating it as a regression in
// its own diff.
//
// WHY THE CHECKOUT AND NOT THE PARENT PID. `getppid()` would have made the
// original intent work, and it is the wrong intent. A pid is fresh per
// invocation, so the same lane re-running after a crash gets a NEW tree and can
// never adopt (or clear) the one its dead predecessor left behind — leftovers
// accumulate under names nothing will ever look at again. Here one lane IS one
// worktree pair, so keying on the worktree root gives an identity that is
// stable across re-runs, distinct between lanes, and distinct for the shared
// mainline checkout — none of which depends on how the process was started
// (shell, agent, `run_all.d` child, CI step).
//
// The cases that have to be right, and what each gets:
//   * two lanes at once      → two roots → two trees. Neither can see the other.
//   * one lane re-running    → same root → same tree, and step one is to clear
//     after a crash            it. `prepareScratchDir` treats a leftover as its
//                              own, and cannot be failed by one (below).
//   * the mainline checkout  → its own root, so an ad-hoc run from ~/Code/vibe3d
//                              is a third tree, not a squatter in a lane's.
//   * two runs, one checkout → SAME tree, deliberately: that is one lane running
//                              itself twice, which the host-wide run lock below
//                              already serialises. The lock is what keeps that
//                              case apart; the key is what keeps the OTHER three
//                              apart, and no amount of locking could (the lock
//                              cannot help a tree left by a run that is over).
//
// The name carries a readable slug of the last two path components so `ls
// /tmp` names the lane, plus a hash of the full absolute path so two lanes that
// end in the same two components still differ.
enum kScratchPrefix = "vibe3d-tests-";

private string slugOf(string s) {
    import std.ascii : isAlphaNum;
    auto b = appender!string;
    foreach (char c; s) {
        b ~= (isAlphaNum(c) || c == '-' || c == '.') ? c : '_';
        if (b.data.length >= 24) break;
    }
    return b.data;
}

// Pure: the scratch path this runner uses when run from `root`. Kept free of
// any process/environment read so it can be reasoned about — and tested — by
// value. `root` is expected to be absolute (getcwd() already is, and POSIX
// getcwd resolves symlinks, so two names for one worktree still key alike).
string scratchDirFor(string root) {
    import std.digest     : toHexString, LetterCase;
    import std.digest.md  : md5Of;
    import std.path       : buildNormalizedPath, absolutePath, pathSplitter;

    const canon = buildNormalizedPath(absolutePath(root));
    const hash  = toHexString!(LetterCase.lower)(md5Of(canon)).idup[0 .. 10];

    string[] parts;
    foreach (p; pathSplitter(canon)) if (p.length && p != "/" && p != "\\") parts ~= p;
    string slug;
    if (parts.length >= 2)      slug = slugOf(parts[$ - 2]) ~ "_" ~ slugOf(parts[$ - 1]);
    else if (parts.length == 1) slug = slugOf(parts[0]);
    else                        slug = "root";

    return buildPath(scratchRoot(), kScratchPrefix ~ slug ~ "-" ~ hash);
}

// Best-effort recursive delete. Returns false instead of throwing: a tree with
// a live writer in it loses the race between rmdirRecurse's readdir and its
// rmdir (ENOTEMPTY), and that is a thing to work around, not to die on.
private bool tryRemoveTree(string path) {
    foreach (attempt; 0 .. 3) {
        try { rmdirRecurse(path); return true; } catch (Exception) {}
        if (!exists(path)) return true;
        Thread.sleep(200.msecs);
    }
    return !exists(path);
}

// Make `path` an empty directory this run owns and return it (only the
// last-resort branch below returns anything else), and NEVER fail the run.
//
// WHAT THIS DOES WITH A DIRECTORY IT DID NOT CREATE. Since the key is the
// checkout, a leftover tree at `path` was left by an earlier run of THIS lane —
// one killed before `cleanup()` could fire, which is every hard kill: SIGKILL,
// an agent timeout, and `onSignal`'s `exit(130)` (core.stdc exit does not unwind
// main, so `scope(exit) cleanup()` never runs). Such a tree is adopted and
// wiped. If the wipe cannot win — the same kill orphans that run's `vibe3d
// --test` workers, which keep appending to `vibe3d.log` inside it — the tree is
// RENAMED aside rather than fought over: rename is atomic, does not care that
// the tree is busy (open fds follow the inode), and leaves the orphan writing
// happily into a path nothing else will touch. Parked trees are swept, best
// effort, by the next run that gets this far. If even the rename fails, this run
// takes a pid-suffixed path of its own: the run always gets a tree.
//
// Trees belonging to OTHER checkouts are never touched, whatever state they are
// in. That is the property task 1282 is about.
string prepareScratchDir(string path) {
    import std.file : rename;

    if (exists(path) && !tryRemoveTree(path)) {
        const parked = format("%s.stale-%d", path, getpid());
        bool moved;
        try { rename(path, parked); moved = true; } catch (Exception) {}
        if (moved) {
            stderr.writefln(yellow("scratch: %s was busy (a killed run's workers "
                ~ "are still writing there) — parked it as %s"), path, parked);
        } else {
            const own = format("%s.pid%d", path, getpid());
            stderr.writefln(yellow("scratch: %s is busy and could not be moved — "
                ~ "using %s for this run"), path, own);
            mkdirRecurse(own);
            return own;
        }
    }

    // Sweep any parked trees of THIS lane that are now quiet. Best effort:
    // one that is still busy simply survives to the next run.
    const dir  = dirName(path);
    const stem = baseName(path) ~ ".stale-";
    try {
        foreach (e; dirEntries(dir, SpanMode.shallow))
            if (baseName(e.name).startsWith(stem)) tryRemoveTree(e.name);
    } catch (Exception) {}

    mkdirRecurse(path);
    return path;
}

// ---------------------------------------------------------------------------
// Disk-space preflight (task 2080)
// ---------------------------------------------------------------------------
//
// THE INCIDENT. A sanitizer night died mid-link:
//
//     Error: error writing file '.../worker_N/<test>.o'
//     /usr/bin/ld: final link failed: No space left on device
//
// `worker_N/<test>.o` is exactly this runner's own per-worker scratch
// (`w.scratch = buildPath(scratchDir, "worker_%d")`, written by
// `compileTests` below). On the affected host the former /tmp default is a
// quota-limited tmpfs. SIX unrelated fixture tests failed identically in the
// same run, which reads as a code regression and is one exhausted filesystem.
// Task 5502 moved that default to /var/tmp; this check still removes the
// DISGUISE for explicit TMPDIR and any future quota-limited root: a run against an
// exhausted filesystem says so, once, with the word "space" in it, before a
// single test compiles, instead of failing 40 minutes in as red tests.
//
// kMinPreflightFreeBytes now lives in tools.harness.hostspace (task 5630).
// THE FLOOR IS A DECIDED THRESHOLD, NOT A DERIVED ONE, and that distinction
// is the point: CLAUDE.md's dead-check catalogue is about a threshold
// DERIVED FROM THE RUN IT JUDGES (I1's `radial <= K1 * baseline` in task
// 1840, which rotted the moment its own baseline moved). 256 MiB is a flat,
// host- and run-independent constant — it does not drift when a test suite
// grows or a host gets faster, and it is not tuned against any run this
// check has ever measured. It is deliberately far below "enough for a full
// run" (that depends on -j and which tests) and just above "the filesystem
// cannot be treated as writable at all": one dmd link for a source-backed
// test already needs tens of MiB, and every worker shares this filesystem.
// A run that clears the floor can still exhaust space mid-flight; that
// failure mode is unchanged by this check — see the task card for what
// (deliberately) was not decided here.
// Advisory only (tasks 4660/5502): measured 2026-09-11 on main@3b42e336 at
// `-j 6` with `du -sb <scratch>/worker_*` while the run was live. The estimate
// deliberately uses the largest worker as its coefficient: shared + jobs *
// max-worker; that worker was 1,620,727,255 bytes. The live 115,491,790-byte
// shared library was within ~0.5% of task 4640's 114,904,668-byte value, so its
// coefficient is kept unchanged. This advisory does not raise the flat floor.
enum ulong kObservedWorkerScratchBytes = 1_620_727_255UL;
enum ulong kObservedSharedTestLibraryBytes = 114_904_668UL;

ulong estimatedScratchBytes(int jobs) {
    if (jobs <= 0) return kObservedSharedTestLibraryBytes;
    return kObservedSharedTestLibraryBytes
         + cast(ulong) jobs * kObservedWorkerScratchBytes;
}

string spaceEstimateWarning(SpaceAvailability space, int jobs, string path) {
    const estimated = estimatedScratchBytes(jobs);
    if (space.available == ulong.max || space.available >= estimated) return null;
    return format(
        "space warning: %s has %s available (%s); estimated need for -j %d is %s "
        ~ "(%s/worker coefficient measured 2026-09-11 at -j 6, plus %s "
        ~ "shared test library); continuing",
        path, humanBytes(space.available), availabilityDetails(space), jobs,
        humanBytes(estimated),
        humanBytes(kObservedWorkerScratchBytes),
        humanBytes(kObservedSharedTestLibraryBytes));
}

// ---------------------------------------------------------------------------
// Scratch sweep (task 2080)
// ---------------------------------------------------------------------------
//
// The property this closes: `scratchDirFor` keys a tree by its owning
// checkout's absolute path (task 1282, above), and `prepareScratchDir` only
// ever adopts/wipes a LEFTOVER tree the next time something runs from that
// SAME checkout. Once a lane's worktree is torn down (`task-wt-rm.sh`),
// nothing ever runs from that path again — so its tree is orphaned
// permanently, not just until the next run. `task-wt-rm.sh` calls
// `--sweep-scratch` right after removing a lane's worktree pair, passing the
// CURRENT `git worktree list` as the live set (which correctly excludes the
// worktree just removed).
//
// The rule is pure and asymmetric on purpose: an entry is swept only if it
// does NOT match `scratchDirFor(root)` for any given live root. A live
// worktree's tree can therefore never be swept by construction, not by a
// runtime check — `--sweep-plan` below proves exactly this, in-memory, with
// no real filesystem or `--sweep-scratch` invocation involved.
string[] orphanScratchDirs(string[] tmpEntries, string[] liveRoots) {
    bool[string] keep;
    foreach (r; liveRoots) keep[scratchDirFor(r)] = true;
    string[] orphans;
    foreach (e; tmpEntries) if (e !in keep) orphans ~= e;
    return orphans;
}

/// Best-effort recursive byte total; never throws, never blocks a sweep on a
/// file that vanishes mid-walk (a live writer racing the scan).
ulong treeSize(string path) {
    ulong total;
    try {
        foreach (e; dirEntries(path, SpanMode.depth))
            if (e.isFile) total += e.size;
    } catch (Exception) {}
    return total;
}

// ---------------------------------------------------------------------------
// Cross-process run slots (task 6205; replaces the single host-wide lock)
// ---------------------------------------------------------------------------
//
// Several runs may share a host, up to N (VIBE3D_RUN_SLOTS, else the per-host
// file, else 2 -- tools/harness/runslots.d owns the family, the count and the
// port windows). Each run holds ONE slot by flock and waits, printing a
// notice, while all N are held; after `--lock-timeout` it gives up with NO
// TESTS RAN. What used to make overlap unsafe is now partitioned instead of
// serialised:
//   * ports -- without `-p`, slot k's workers take its own window
//     (slotPortBase(k) + worker; a private test family uses 28080..). WITH `-p` the caller owns [p, p+j): two
//     concurrent runs given overlapping ranges still kill each other's
//     workers (killStaleVibe clears by port), so an explicit `-p` must be
//     disjoint from every other run's range on the host;
//   * scratch -- keyed per checkout (scratchDirFor);
//   * one checkout run twice -- refused up front by the per-checkout build
//     lock below, before `dub build`, so a worktree is never built twice at once.
// Nightly perf takes every slot of the family (with_perf_lock.sh), so a
// measurement still excludes all test runs. The canonical paths ignore TMPDIR
// on purpose (task 4870); the env seam is for tests only. flock is released
// when the fd closes, so a crashed holder never leaks a slot.
string runLockPath() { return runSlotBase(); }

__gshared int g_slotIndex = -1;          // the slot this run holds, -1 = none
__gshared int g_worktreeLockFd = -1;     // per-checkout build lock, ours

// A test of the runner can legitimately invoke a nested run_test.d while the
// outer runner holds a slot (tests/test_harness_load_log.d does this to force
// a post-slot worker-preparation failure). The lease is the holder's PID plus
// the holder's descriptor NUMBER, not a boolean bypass: it is honoured only
// when the PID is a live ancestor and /proc shows that descriptor holding a
// flock on a slot of this family (runslots.borrowInheritedSlot). An unrelated
// process must still queue.
enum inheritedRunLockPidEnv = kInheritedRunLockPidEnv;
enum inheritedRunLockFdEnv  = kInheritedRunLockFdEnv;

// Take one free slot, waiting up to `timeoutSec` while all N are held.
bool acquireRunLock(int timeoutSec) {
    const base = runSlotBase();
    RunSlot s;
    if (borrowInheritedSlot(base, s)) {
        runLockBorrowed = true;
        runLockFd = -1;
        g_slotIndex = s.index;
        g_harness.lockWaitSeconds = 0;
        g_lockAcquiredMs = nowUnixMs();
        return true;
    }
    runLockBorrowed = false;

    const count = configuredRunSlots();
    if (count.error.length) {
        stderr.writeln(red("NO TESTS RAN — invalid run-slot count: " ~ count.error));
        return false;
    }
    bool take() {
        if (!tryAcquireFreeSlot(base, count.n, s)) return false;
        runLockFd   = s.fd;
        g_slotIndex = s.index;
        g_lockAcquiredMs = nowUnixMs();
        return true;
    }
    if (take()) {
        g_harness.lockWaitSeconds = 0;
        return true;
    }

    // Name who we wait for BEFORE a slot's stamp is overwritten by its next
    // holder: that is what turns a wait into a collision between named lanes.
    try {
        auto held = slotStamp(runSlotPath(base, 0));
        if (held.startsWith("pid "))
            g_harness.lockHolderPid = held[4 .. $].split[0].to!int;
    } catch (Exception) {}

    writeln(yellow(format("all %d run slots on this host are held by other "
        ~ "test runs or a nightly perf measurement — waiting...", count.n)));
    stdout.flush();   // a queued run must say so now, not when its buffer fills
    int waited = 0;
    while (waited < timeoutSec) {
        Thread.sleep(1.seconds);
        waited += 1;
        if (take()) {
            writeln(green(format("  acquired run slot %d after %ds", g_slotIndex, waited)));
            g_harness.lockWaitSeconds = waited;
            return true;
        }
        if (waited % 15 == 0)
            writefln(yellow("  still waiting for a free run slot (%ds)..."), waited);
    }
    // NOT a test failure — nothing ran. Say so first and loudly: this exits
    // non-zero exactly like a red suite (task 0685).
    stderr.writeln(red(format(
        "NO TESTS RAN — timed out after %ds waiting for one of the %d shared "
        ~ "test/perf run slots on this host. This is a host-contention exit, "
        ~ "not a failing suite.", timeoutSec, count.n)));
    stderr.writeln(dim(
        "    Several agents/worktrees and nightly perf share this machine's\n"
        ~ "    run slots, and perf takes all of them. Full gates belong to\n"
        ~ "    tools/local/gate-pool.sh, which queues FIFO across hosts.\n"
        ~ "    While iterating, run NARROW tests instead: `./run_test.d <name> ...`."));
    foreach (k; 0 .. count.n) {
        const p = runSlotPath(base, k);
        stderr.writeln(dim(format("    Slot %d: %s (%s)", k, p, slotStamp(p))));
    }
    g_harness.lockWaitSeconds = timeoutSec;
    g_harness.lockTimedOut    = true;
    return false;
}

void releaseRunLock() {
    // The outer ancestor still owns the slot for a borrowed lease.
    if (runLockBorrowed) {
        runLockBorrowed = false;
        g_slotIndex = -1;
        return;
    }
    if (runLockFd >= 0) {
        flock(runLockFd, LOCK_UN);
        close(runLockFd);
        runLockFd = -1;
        g_slotIndex = -1;
    }
}

// One run per checkout: a second run of the same worktree would rebuild
// ./vibe3d under the first and clear its scratch tree. Non-blocking: the
// second run is REFUSED at once rather than queued. Held until exit.
bool acquireWorktreeLock(string root) {
    import std.string : toStringz;
    const path = worktreeLockPath(runSlotBase(), root);
    g_worktreeLockFd = open(path.toStringz, O_RDWR | O_CREAT, octal!"644");
    if (g_worktreeLockFd < 0) return true;   // cannot create: do not block CI
    if (flock(g_worktreeLockFd, LOCK_EX | LOCK_NB) == 0) {
        stampSlot(g_worktreeLockFd, "worktree " ~ root);
        return true;
    }
    stderr.writeln(red("NO TESTS RAN — another run_test.d is already running in "
        ~ "this checkout (" ~ root ~ "): " ~ slotStamp(path)));
    stderr.writeln(dim("    Two runs of one worktree would build ./vibe3d and clear "
        ~ "the scratch tree under each other.\n    Lock: " ~ path));
    close(g_worktreeLockFd);
    g_worktreeLockFd = -1;
    return false;
}

// ---------------------------------------------------------------------------
// Harness load log (task 3260)
// ---------------------------------------------------------------------------
//
// One JSON line per invocation, appended to a HOST-WIDE file, so the load this
// workstation carries can be READ rather than reconstructed.
//
// Reconstruction was tried first, off the agent transcripts, and was wrong
// three times running, each time plausibly:
//
//   * `grep -n run_test.d run_test.d` counted as a suite run;
//   * one lock wait was counted again on every `cat` of the log it had been
//     printed into;
//   * `./run_test.d --no-build > /tmp/x` parsed as a NARROW run, because the
//     redirect target read as a test name.
//
// Worse than the errors: the two facts that decide everything -- how long a run
// waited for the lock, and whether it ran AT ALL -- live only on stdout, and
// stdout goes to a file in most invocations. Across 2 970 reconstructed runs
// the lock wait was legible in about 200. This runner knows both exactly.
//
// WHERE, and why not tempDir(): /tmp on this host is an 8 GiB tmpfs, so a log
// there would cost RAM and vanish at reboot -- the two things a longitudinal
// record must not do. The number was "32 GiB (task 2080)" until 2026-09-20 and
// was wrong by four times: `df -h /tmp` reads `tmpfs 8.0G`. The size is quoted
// at all only to say that this is RAM, and the RAM cost is what the argument
// rests on -- so read `free`'s `shared` column, which IS this mount, and note
// that the OOM killer reads `free` rather than `available` (card 6685). It is
// host-wide for the same reason the LOCK
// is host-wide: every worktree shares one slot, so a per-checkout log would
// hide precisely the contention it exists to show.
//
// IT NEVER FAILS THE RUN. Every write is best-effort under a catch-all: a full
// disk or a read-only home leaves the log incomplete, never the suite red.
// `VIBE3D_HARNESS_LOG=off` disables it; any other value is used as the path.

enum kHarnessLogVersion = 1;

// Where this invocation STOPPED. The load report's first question is not "did
// it pass" but "did it produce a verdict", and those are unrelated: a run
// refused by the stale-binary guard, one that gave up waiting for the lock, or
// one whose worker preparation died after the lock measured nothing while
// still spending a lane's attention. Every value except `ran` is an invocation
// that produced NO verdict -- the "the run never happened" class this project
// keeps paying for, finally counted instead of inferred.
enum HarnessStage : string {
    started      = "started",        // logged only if we died between arming and every known exit
    spaceRefused = "space_refused",
    noTests      = "no_tests",
    gateRefused  = "gate_refused",
    protocolRefused = "protocol_refused",
    buildFailed  = "build_failed",
    staleRefused = "stale_refused",
    lockTimeout  = "lock_timeout",
    worktreeBusy = "worktree_busy",       // another run of this checkout is live
    slotConfigInvalid = "slot_config_invalid",
    noSuchTest   = "no_such_test",
    noBinary     = "no_binary",
    runIncomplete = "run_incomplete", // acquired the slot, but no Total/verdict was produced
    ran          = "ran",
}

// THE ONE GAP, named rather than papered over: a run killed by SIGINT/SIGTERM
// leaves NO record. `onSignal` is `nothrow @nogc` and reaches the process
// through `core.stdc.stdlib.exit`, which unwinds nothing -- so neither the
// `scope(exit)` below nor any allocating writer can run there, and making the
// handler allocate to fix it would trade a missing row for a deadlock risk in
// the handler. Consequence for the reader: a missing row is NOT evidence that
// nothing ran, and a slot can be busy with no record open. The report says so
// on its face rather than quietly averaging over it.

struct HarnessRecord {
    string kind = "suite";       // the dub shim writes "dub" into the same file
    long   startMs, endMs;
    string host, root, branch, sha;
    int    pid;
    string mode = "full";        // "full" = no test named on the command line
    int    testsSelected;
    int    j;
    bool   noBuild;
    double buildSeconds     = 0;
    int    lockWaitSeconds  = -1;   // -1 = this invocation never reached the lock
    int    lockHolderPid    = 0;    // who held it while we waited
    bool   lockTimedOut     = false;
    double serviceSeconds   = 0;    // wall time the lock was actually HELD
    int    total, passed, failed, timedOut;
    string stage = HarnessStage.started;
    int    rc = -1;
}

__gshared HarnessRecord g_harness;
__gshared bool          g_harnessArmed;      // false => meta invocation, log nothing
__gshared long          g_lockAcquiredMs;

long nowUnixMs() {
    import std.datetime.systime : Clock;
    // currStdTime is hnsecs since 1 Jan 0001; 621_355_968_000_000_000 of those
    // are the Unix epoch.
    return (Clock.currStdTime - 621_355_968_000_000_000L) / 10_000L;
}

private string harnessHostName() {
    try {
        auto h = environment.get("HOSTNAME", "");
        if (h.length) return h;
        if (exists("/etc/hostname")) return readText("/etc/hostname").strip;
    } catch (Exception) {}
    return "unknown";
}

private string gitOneLine(string cmd) {
    try {
        auto r = executeShell("git " ~ cmd ~ " 2>/dev/null");
        if (r.status != 0) return "";
        return r.output.strip;
    } catch (Exception) { return ""; }
}

private string jstr(string s_) {
    auto b = appender!string;
    b.put('"');
    foreach (char c; s_) {
        switch (c) {
            case '"':  b.put(`\"`); break;
            case '\\': b.put(`\\`); break;
            case '\n': b.put(`\n`); break;
            case '\r': b.put(`\r`); break;
            case '\t': b.put(`\t`); break;
            default:
                if (c < 0x20) b.put(format(`\u%04x`, cast(int)c));
                else b.put(c);
        }
    }
    b.put('"');
    return b.data;
}

/// The record as ONE line. Pure, so it is testable without a filesystem: the
/// writer below can then only fail by not being CALLED, which is exactly the
/// mutation `tests/test_harness_load_log.d` drives.
string harnessRecordLine(in HarnessRecord r) {
    return format(
        `{"v":%d,"kind":%s,"stage":%s,"start_ms":%d,"end_ms":%d,"host":%s,`
      ~ `"pid":%d,"root":%s,"branch":%s,"sha":%s,"mode":%s,"tests_selected":%d,`
      ~ `"j":%d,"no_build":%s,"build_s":%.3f,"lock_wait_s":%d,`
      ~ `"lock_holder_pid":%d,"lock_timeout":%s,"service_s":%.3f,"total":%d,`
      ~ `"passed":%d,"failed":%d,"timed_out":%d,"rc":%d}`,
        kHarnessLogVersion, jstr(r.kind), jstr(r.stage), r.startMs, r.endMs,
        jstr(r.host), r.pid, jstr(r.root), jstr(r.branch), jstr(r.sha),
        jstr(r.mode), r.testsSelected, r.j, r.noBuild ? "true" : "false",
        r.buildSeconds, r.lockWaitSeconds, r.lockHolderPid,
        r.lockTimedOut ? "true" : "false", r.serviceSeconds,
        r.total, r.passed, r.failed, r.timedOut, r.rc);
}

/// "" = do not log (either switched off, or no HOME to log under).
string harnessLogPath() {
    auto env = environment.get("VIBE3D_HARNESS_LOG", "");
    if (env == "off") return "";
    if (env.length) return env;
    auto home = environment.get("HOME", "");
    if (!home.length) return "";
    return buildPath(home, ".local", "state", "vibe3d", "harness.jsonl");
}

void writeHarnessRecord() {
    if (!g_harnessArmed) return;
    try {
        string path = harnessLogPath();
        if (!path.length) return;
        g_harness.endMs = nowUnixMs();
        if (g_lockAcquiredMs > 0)
            g_harness.serviceSeconds = (g_harness.endMs - g_lockAcquiredMs) / 1000.0;
        auto line = harnessRecordLine(g_harness) ~ "\n";
        // One write(2) of a line shorter than PIPE_BUF onto an O_APPEND fd is
        // atomic on Linux -- which is what lets several lanes share one file
        // with no lock of their own. An over-long record is DROPPED rather than
        // torn: a half-written line would poison the reader for every run after
        // it, and a missing row is a smaller lie than a corrupt one.
        if (line.length >= 4096) return;
        mkdirRecurse(dirName(path));
        import std.string : toStringz;
        int fd = open(path.toStringz, O_WRONLY | O_CREAT | O_APPEND, octal!"644");
        if (fd < 0) return;
        c_write(fd, line.ptr, line.length);
        close(fd);
    } catch (Exception) {
        // Best-effort by design -- see this section's header.
    }
}

// Is `p` (a recorded process-GROUP id, from `testGroupPids` or a per-test
// timeout kill) actually safe to SIGKILL as a whole group? `ownPgid` is the
// runner's own `getpgrp()`.
//
// `p <= 0` is never a real group leader's pid — `0` is a retired slot (see
// `testGroupPids`'s comment), and `kill(-0, …)` is the POSIX special case
// "signal the CALLER's own group" — another route to the exact hazard this
// function exists to close, so it is excluded the same way `p == ownPgid`
// is, not treated as merely "no-op".
//
// `p == ownPgid` is the case this task exists for. This runner is NOT
// always its own process-group leader: under `xvfb-run`, neither `sh` (the
// wrapper) nor its non-interactive `Xvfb … &` job control a new pgrp for
// what they spawn, so `xvfb-run`'s own shell, `Xvfb`, and this process all
// inherit ONE shared group — measured 2026-08-28 with instrumented builds
// on this host AND on `ai` (task 2001; a `getpgrp()` probe placed at
// `main()`, at every `vibePids`/`testGroupPids` append, and at both
// group-kill sites). A `testGroupPids` entry is only ever supposed to be a
// FRESH test child's own post-`setpgid(0,0)` group — by pid-uniqueness that
// can never legitimately equal a group an ALIVE ancestor (the wrapper)
// still holds — but this check costs one word compare and turns any future
// violation of that invariant into a skipped signal instead of a
// self-inflicted, uncatchable SIGKILL of the wrapper (and of this process,
// since it is a member of that same group). Group-wide kill call sites
// must route through this, not `p > 0` alone.
bool shouldKillGroup(int p, int ownPgid) pure @safe @nogc nothrow {
    return p > 0 && p != ownPgid;
}

// `run_test.d` is an rdmd script, outside `source/` and `tests/unit/`, so it
// has no home in the `dub test --config=tests` gate — the same reason
// `tools/perf/lib/vslast.d` needed its own carve-out (dub.json's `_comment`
// there). This block is this file's own witness instead: build+run it with
//   dmd -unittest -I. run_test.d tools/harness/hostspace.d \
//     tools/harness/runslots.d -of=/tmp/run_test_ut \
//     && /tmp/run_test_ut
// The line above used to read `dmd -unittest run_test.d` with a parenthetical
// saying this module has no project-local imports and needs no import-path
// juggling. That stopped being true when `tools.harness.hostspace` arrived:
// the documented command now dies with `undefined reference to
// tools.harness.hostspace.scratchRoot()` and produces no binary at all, so
// the witness it points at has been unrunnable — and therefore unrun — since
// then (task 6291). Compiling WITHOUT `-unittest`, which
// is how every real invocation of this script runs, elides this block
// entirely; druntime's default (non-`--DRT-testmode=run-main`) unittest
// runner exits after the block below instead of falling into the real
// `main()`, so running this is never destructive.
//
// The mutation this guards against: restoring either group-kill loop to its
// pre-task-2001 form (`foreach (p; testGroupPids) if (p > 0) kill(-p, …)`,
// i.e. dropping the `p != ownPgid` term) reddens this block at the
// `assert(!shouldKillGroup(selfGroup, selfGroup), ...)` line with its
// message, because `shouldKillGroup` is exactly that dropped term factored
// out — the loops have no other path to "is this our own group" than this
// function.
unittest {
    // A real recorded id: positive, distinct from our own group — the
    // ordinary case, killable.
    assert(shouldKillGroup(4242, 1000),
        "a fresh test/vibe3d process group must remain killable");

    // The retired-slot sentinel `testGroupPids` zeroes a finished test's
    // entry to (see its declaration comment) — never a group to signal.
    assert(!shouldKillGroup(0, 1000),
        "a retired (zeroed) slot must never be sent a group signal");

    // A theoretically-possible negative/garbage value must not be
    // reinterpreted as some OTHER group by negating it again.
    assert(!shouldKillGroup(-7, 1000),
        "a negative recorded id must never be treated as killable");

    // THE case this task exists for: under `xvfb-run` this runner shares its
    // process group with the wrapper (measured, see the doc comment above).
    // A recorded id equal to our own group must be refused, or
    // `kill(-p, SIGKILL)` SIGKILLs the wrapper and this process with it.
    enum selfGroup = 1000;
    assert(!shouldKillGroup(selfGroup, selfGroup),
        "a process-group id equal to the runner's own group must be refused "
        ~ "— sending it SIGKILL reaches the xvfb-run wrapper AND this runner");

    // A near-miss (adjacent pid, not an exact match) must NOT be caught by
    // the guard — this is a targeted exclusion, not a blanket refusal of
    // anything nearby.
    assert(shouldKillGroup(selfGroup + 1, selfGroup),
        "a group merely adjacent to our own must remain killable — the "
        ~ "guard is an exact-id exclusion, not a range");
}

extern(C) void onSignal(int sig) nothrow @nogc @system {
    foreach (p; vibePids) if (p != 0) kill(p, SIGKILL);
    immutable ownPgid = getpgrp();
    // Negative pid = the whole process group. Running tests are group leaders
    // of their own group precisely so this reaches their children too — see
    // `shouldKillGroup` for why `ownPgid` is excluded.
    foreach (p; testGroupPids) {
        if (p > 0 && p == ownPgid) {
            import core.stdc.stdio : fprintf, stderr;
            fprintf(stderr, "run_test: onSignal: refusing to SIGKILL process "
                ~ "group %d — it is this runner's OWN group\n", p);
            continue;
        }
        if (shouldKillGroup(p, ownPgid)) kill(-p, SIGKILL);
    }
    if (runLockFd >= 0) { flock(runLockFd, LOCK_UN); close(runLockFd); }
    import core.stdc.stdio : fputs, stderr;
    fputs("\ninterrupted\n", stderr);
    exit(130);
}

void cleanup() {
    if (!keepVibe) {
        foreach (p; vibePids) {
            if (p == 0) continue;
            try { kill(p, SIGTERM); } catch (Exception) {}
        }
        // Give them ~500ms each to exit cleanly, then SIGKILL.
        for (int i = 0; i < 10; ++i) {
            Thread.sleep(50.msecs);
            bool anyAlive;
            foreach (p; vibePids) if (p != 0 && kill(p, 0) == 0) { anyAlive = true; break; }
            if (!anyAlive) break;
        }
        foreach (p; vibePids) {
            if (p == 0) continue;
            try { kill(p, SIGKILL); } catch (Exception) {}
        }
        vibePids = null;
    }
    // Anything a per-test timeout could not reap (or a test still running when
    // an exception unwound the run) gets one last group-wide SIGKILL. Cheap,
    // and it is the difference between "the next lane's worker starts" and
    // "the next lane's worker finds its port taken by an orphan" — EXCEPT
    // when the recorded id is our own process group (see `shouldKillGroup`):
    // under `xvfb-run` that group also holds the wrapper we are running
    // under and this process itself, and SIGKILL cannot be caught, so
    // sending it there would kill the wrapper and read back to the caller
    // as this runner exiting 137 — AFTER a fully green summary already
    // printed (task 2001; the race this file's tests pin).
    immutable ownPgid = getpgrp();
    foreach (p; testGroupPids) {
        if (p > 0 && p == ownPgid)
            stderr.writefln("run_test: cleanup(): refusing to SIGKILL process "
                ~ "group %d — it is this runner's OWN group (shared with the "
                ~ "xvfb-run wrapper); sending it SIGKILL would kill the "
                ~ "wrapper and this runner too", p);
    }
    foreach (p; testGroupPids) if (shouldKillGroup(p, ownPgid)) {
        try { kill(-p, SIGKILL); } catch (Exception) {}
    }
    testGroupPids = null;
    // Only ever the tree THIS run made (or adopted at startup and emptied);
    // never another checkout's, and never a parked one that is still busy.
    // Best-effort by design: a leftover here is harmless — the next run of this
    // same lane clears it, and no other lane can see it.
    if (scratchDir.length && exists(scratchDir)) tryRemoveTree(scratchDir);
    releaseRunLock();
}

// ---------------------------------------------------------------------------
// Test discovery & name normalization
// ---------------------------------------------------------------------------

string normalize(string arg) {
    if (arg.startsWith("tests/") && arg.endsWith(".d")) return arg;
    if (arg.startsWith("test_"))                         return "tests/" ~ arg ~ ".d";
    return "tests/test_" ~ arg ~ ".d";
}

string[] resolveTests(string[] args) {
    string[] paths;
    if (args.empty) {
        foreach (e; dirEntries("tests", "test_*.d", SpanMode.shallow))
            paths ~= e.name;
        sort(paths);
        return paths;
    }
    foreach (a; args) {
        string p = normalize(a);
        if (!exists(p) || !isFile(p)) {
            stderr.writefln("no such test: %s (resolved %s)", a, p);
            // `exit` is core.stdc's: it unwinds NOTHING, so main's
            // `scope(exit) writeHarnessRecord()` will not fire here. Write the
            // record by hand instead of losing the invocation. Unlike
            // `onSignal`, this is ordinary code, so allocating is fine.
            g_harness.stage = HarnessStage.noSuchTest;
            g_harness.rc    = 2;
            writeHarnessRecord();
            exit(2);
        }
        paths ~= p;
    }
    return paths;
}

// ---------------------------------------------------------------------------
// Per-test timing persistence (machine-specific; gitignored)
// ---------------------------------------------------------------------------
//
// We record each test's wall-clock duration after every run and persist it to
// `.test_timings.json` in the repo root. Durations are smoothed across runs
// with an exponential moving average (EMA, alpha = 0.3): a run's fresh sample
// counts 30%, the prior history 70%. EMA was chosen over "median of last 5"
// because it needs no per-test sample ring (one float per test), still damps
// one-off spikes (a loaded host on a single run barely moves the estimate),
// and adapts smoothly when a test's real cost shifts (e.g. a test grows). The
// estimates feed the LPT scheduler (longest-processing-time-first) so workers
// finish nearly together instead of one dragging the long tail.
//
// The file is keyed by the bare test name (e.g. "test_bevel") so it is stable
// across the per-worker scratch copies and across worktrees/checkouts.

enum double EMA_ALPHA = 0.3;

// ---------------------------------------------------------------------------
// The per-test wall-clock cap
// ---------------------------------------------------------------------------
//
// 600 s, and the number comes from the timing caches, not from taste (task
// 1420, trap 1). Measured on 2026-08-19 over the 30 `.test_timings.json`
// caches this host carries (one per lane worktree + main), ~700 tests each:
//
//     median test                                 0.28 s
//     p90 / p95 / p99                        7.2 / 13.7 / 53.8 s
//     slowest legitimate test    test_explore_fly       120.2 s
//                                (a FIRST observation, so a raw wall-clock
//                                 sample, not an EMA-damped one)
//     next slowest               test_xfrm_flex_undo_pose 106.1 s
//                                (26 caches agree to 0.1 s — its true cost)
//
// So the cap is 5.0x the slowest test anyone has ever measured here.
//
// The margin is sized against the LOADED host, not the mean, because the
// loaded host is where a cap that is merely "generous" starts lying. One cache
// (the cmd-quadratic-cost lane) records 16 tests at ~86.5 s whose median in
// every OTHER cache is 0.1-0.3 s — i.e. an ordinary test, on a contended host,
// once took at least 86.5 s. And that 86.5 s is an EMA value: at alpha 0.3
// over the ~0.3 s prior the other caches hold, the raw sample behind it was
// ~288 s. 600 s clears even that by 2.1x. CI is more contended still (a QEMU
// VM reporting 16 vCPUs on a 4-core host; on 2026-08-19 the app's own
// readiness budget was blown there by nothing but scheduling contention), so
// the multiple is deliberately not tight.
//
// What it costs when it fires: 10 minutes per hung test instead of an
// unbounded wait. The integration step carries no `timeout-minutes` of its
// own, so today a hang there runs to GitHub's job limit and names no test.
enum int kDefaultTestTimeoutSec = 600;

string timingsPath() { return ".test_timings.json"; }

// Load smoothed per-test durations (seconds), keyed by bare test name. Missing
// or malformed file → empty map (every test then falls back to a default).
double[string] loadTimings() {
    double[string] m;
    auto p = timingsPath();
    if (!exists(p)) return m;
    try {
        auto j = parseJSON(readText(p));
        if (j.type != JSONType.object) return m;
        foreach (k, v; j.object) {
            if (v.type == JSONType.float_)        m[k] = v.floating;
            else if (v.type == JSONType.integer)  m[k] = cast(double)v.integer;
        }
    } catch (Exception) { /* corrupt cache — ignore, rebuild from scratch */ }
    return m;
}

// Fold this run's fresh samples into the prior estimates (EMA) and write back.
// `samples` is keyed by bare test name → wall-clock seconds for THIS run.
void saveTimings(double[string] prior, double[string] samples) {
    double[string] merged;
    foreach (k, v; prior) merged[k] = v;
    foreach (k, v; samples) {
        if (auto old = k in merged) *old = EMA_ALPHA * v + (1 - EMA_ALPHA) * (*old);
        else                        merged[k] = v;  // first observation
    }
    JSONValue[string] obj;
    foreach (k, v; merged) obj[k] = JSONValue(v);
    JSONValue j = JSONValue(obj);
    try { std.file.write(timingsPath(), j.toPrettyString); }
    catch (Exception e) { stderr.writeln(yellow("warning: could not write "
        ~ timingsPath() ~ ": " ~ e.msg)); }
}

// Best estimate (seconds) for a test path, given the loaded timings. Unknown
// tests get the median of known timings (robust to outliers), or a constant
// when the cache is empty.
double estimateFor(string path, double[string] timings, double defaultEst) {
    auto name = baseName(path).stripExtension;
    if (auto t = name in timings) return *t;
    return defaultEst;
}

double medianOf(double[] xs, double fallback) {
    if (xs.empty) return fallback;
    auto s = xs.dup;
    s.sort();
    return s[s.length / 2];
}

// ---------------------------------------------------------------------------
// Stale-process & port handling
// ---------------------------------------------------------------------------

/// Is anything LISTENING on this port right now? One definition, because the
/// two callers below must agree: `killStaleVibe` waits on it, and the
/// default-port guard refuses on it. A wrong answer here is invisible in the
/// direction that matters — it reads "free" and every guard built on it stops
/// firing — so its witness binds a real socket rather than trusting the shape
/// of the command.
bool portBusy(ushort port) {
    return executeShell(
        format("ss -ltn 'sport = :%d' | tail -n +2 | grep -q .", port)).status == 0;
}

/// Who is holding the port? Returns the listener's `/proc` cmdline with NULs
/// turned into spaces, or "" when nothing is listening or it cannot be read
/// (another user's process, or one that exited between the two reads).
///
/// Deliberately NOT `pgrep -f`: that matches the pattern against every
/// process on the host, including this runner's own argv, and the project has
/// been bitten by exactly that self-match. This asks the kernel WHICH pid owns
/// the listening socket and then reads only that one.
string portHolderCmdline(ushort port) {
    auto r = executeShell(format(
        "ss -ltnp 'sport = :%d' | tail -n +2 | grep -o 'pid=[0-9]*' | "
        ~ "head -1 | cut -d= -f2", port));
    const pid = r.output.strip;
    if (r.status != 0 || pid.length == 0) return "";
    try {
        import std.array : replace;
        return readText(format("/proc/%s/cmdline", pid)).replace("\0", " ").strip;
    } catch (Exception) {
        return "";
    }
}

/// Is the process holding the port one of OUR OWN stale test instances — the
/// thing `killStaleVibe` exists to clear? Keyed on the same three argv tokens
/// that `killStaleVibe`'s pattern uses, so the two agree by construction: if
/// this says yes, that function can and will clean it up.
bool holderIsStaleTestInstance(string cmdline, ushort port) {
    return cmdline.canFind("vibe3d")
        && cmdline.canFind("--test")
        && cmdline.canFind(format("--http-port %d", port));
}

/// Is this a mapped user namespace rather than the host's initial one?
///
/// Read from `/proc/self/uid_map`, whose initial-namespace content is exactly
/// `0 0 4294967295` — identity over the whole uid range. `unshare
/// --map-root-user` writes `0 <caller uid> 1` instead. Measured on this host:
/// `[         0          0 4294967295]` outside and `[         0       1000
/// 1]` inside. The first thing tried here was comparing `/proc/self/ns/user`
/// with `/proc/1/ns/user`, which cannot work: init's link is unreadable to a
/// normal user in BOTH cases, so the comparison threw and answered "host"
/// every time — a carve-out that could never fire.
///
/// An unreadable or unparsable map answers NO, keeping the guard fail-closed.
bool isMappedUserNamespace(string uidMap) {
    import std.array : split;
    try {
        auto f = uidMap.strip.split;
        if (f.length < 3) return false;
        return !(f[0] == "0" && f[1] == "0" && f[2] == "4294967295");
    } catch (Exception) {
        return false;
    }
}

bool inForeignUserNamespace() {
    try {
        return isMappedUserNamespace(readText("/proc/self/uid_map"));
    } catch (Exception) {
        return false;
    }
}

/// The classification the guard actually needs, and the reason it is not just
/// `holderIsStaleTestInstance` (task 6291, second defect, 2026-09-16).
///
/// Inside a user namespace `ss -ltnp` cannot attribute a listening socket to a
/// pid at all, so the holder's command line reads EMPTY — and an empty string
/// is not "vibe3d --test --http-port N". A test that spawns a real runner
/// inside `unshare --mount --map-root-user` while the parent suite's worker 0
/// legitimately holds the default port therefore saw its own family classified
/// as a stranger and was refused. Measured: outside the namespace the pid
/// extraction yields the holder; inside, the same pipeline yields nothing while
/// the port still reads busy.
///
/// So an unreadable holder means "ours" ONLY in a foreign namespace, where we
/// are by construction a child of our own harness and there is no interactive
/// session for this guard to protect. On the host an unreadable holder is a
/// process of another user, and there the fail-closed answer stays.
bool holderCountsAsOurs(string cmdline, ushort port, bool foreignNamespace) {
    if (holderIsStaleTestInstance(cmdline, port)) return true;
    return cmdline.length == 0 && foreignNamespace;
}

/// Refuse to run when the port was NOT asked for, is already taken, and the
/// holder is NOT one of our own stale test instances (task 6291). The default
/// is 8080, which is also what a plain interactive `./vibe3d` binds, so a lane
/// that forgets `--port` aims the whole run at whatever the developer is
/// using. What happens then is not one failure but two:
///
///   - an instance started as `vibe3d --test --http-port 8080` matches
///     `killStaleVibe`'s pattern and is cleared before the run — which is
///     CORRECT and routine on CI, where a killed run leaves exactly that
///     behind, and is why this guard must not fire on it;
///   - a plain `./vibe3d`, the interactive one, does not match, survives,
///     keeps the port, and the run dies minutes later with "failed to come
///     up" after a 5 s warning — having first sent its `pkill` at the
///     developer's machine for nothing.
///
/// Two discriminators, and both are needed. "Was the port ASKED for" rather
/// than the port number: an explicit `--port 8080` is a human saying they mean
/// it, and banning 8080 outright would break the ordinary local run in main,
/// where it is free. "Is the holder our own test instance" rather than "is
/// anything there": without that term this guard refuses every CI run that
/// follows an interrupted one, which is the case the cleanup was written for.
/// `--attach` is exempt by construction — it exists to drive an endpoint that
/// is already listening.
bool refuseDefaultBusyPort(bool portGiven, int attach, bool busy, bool ourStaleInstance)
        pure nothrow @safe @nogc {
    return !portGiven && attach == 0 && busy && !ourStaleInstance;
}

// Witness for both of the above. The predicate's table is exhaustive over its
// three booleans, so a dropped term cannot hide in an untried combination; the
// `portBusy` cell binds a real listening socket, because the failure that
// matters is the silent one where it answers "free" forever.
unittest {
    import std.socket;

    // Every row of the truth table, so removing any one term reddens: dropping
    // `!portGiven` breaks row 2, dropping `attach == 0` breaks row 3, dropping
    // `busy` breaks row 4, dropping `!ourStaleInstance` breaks row 5.
    assert(refuseDefaultBusyPort(false, 0, true, false),
        "a default port held by something that is not ours must refuse");
    assert(!refuseDefaultBusyPort(true, 0, true, false),
        "an explicit --port is a human saying they mean it");
    assert(!refuseDefaultBusyPort(false, 8080, true, false),
        "--attach exists to drive an endpoint that is already up");
    assert(!refuseDefaultBusyPort(false, 0, false, false),
        "a free default port is the ordinary local run");
    assert(!refuseDefaultBusyPort(false, 0, true, true),
        "our own stale test instance is killStaleVibe's job, not a refusal — "
        ~ "refusing here breaks every CI run that follows an interrupted one");
    foreach (pg; [false, true])
        foreach (at; [0, 8080])
            foreach (bs; [false, true])
                foreach (ours; [false, true])
                    assert(refuseDefaultBusyPort(pg, at, bs, ours)
                           == (!pg && at == 0 && bs && !ours),
                        "the predicate must be exactly the conjunction it documents");

    // The holder classifier, against the argv shapes that actually occur. The
    // port term matters: a stale instance on ANOTHER port is not this port's
    // holder, and treating it as one would hand the port to killStaleVibe,
    // whose pattern would then match nothing and leave the run to fail late.
    assert(holderIsStaleTestInstance("./vibe3d --test --http-port 8080", 8080),
        "our own stale test instance must be recognised");
    assert(!holderIsStaleTestInstance("./vibe3d", 8080),
        "a plain interactive instance is NOT ours to clear");
    assert(!holderIsStaleTestInstance("./vibe3d --test --http-port 8570", 8080),
        "a test instance on another port does not hold this one");
    // Found by mutation, not by design: with the `--test` term dropped every
    // other row above still passed, because none of them had `vibe3d` and this
    // port WITHOUT `--test`. That shape is a real one — a human running the
    // editor on an explicit port — and it is precisely NOT ours to clear,
    // since killStaleVibe's pattern also requires `--test` and would match
    // nothing.
    assert(!holderIsStaleTestInstance("./vibe3d --http-port 8080", 8080),
        "an interactive instance on an explicit port carries no --test, so "
        ~ "killStaleVibe's pattern cannot match it and it is not ours to clear");
    assert(!holderIsStaleTestInstance("", 8080),
        "an unreadable holder must never be taken for ours");
    assert(!holderIsStaleTestInstance("python3 -m http.server 8080", 8080),
        "an unrelated listener is not a vibe3d test instance");

    // The namespace carve-out, in both directions. An unreadable holder is our
    // own family ONLY when we cannot possibly be looking at a human's session.
    assert(holderCountsAsOurs("", 8080, true),
        "inside a foreign user namespace an unattributable holder is our own "
        ~ "harness: ss cannot name a pid there, and a real runner spawned by a "
        ~ "test was refused for exactly this");
    assert(!holderCountsAsOurs("", 8080, false),
        "on the host an unreadable holder is another user's process, and the "
        ~ "fail-closed answer is the whole point of the guard");
    assert(holderCountsAsOurs("./vibe3d --test --http-port 8080", 8080, false),
        "a readable holder of our own shape needs no namespace excuse");
    assert(!holderCountsAsOurs("./vibe3d", 8080, true),
        "a READABLE holder is judged on what it says, namespace or not — the "
        ~ "carve-out is for the unreadable case only");

    // The namespace reader itself, against the two shapes measured on this
    // host: `[         0          0 4294967295]` outside `unshare`, and
    // `[         0       1000          1]` inside it.
    assert(!isMappedUserNamespace("         0          0 4294967295\n"),
        "the initial namespace maps the whole uid range identically");
    assert(isMappedUserNamespace("         0       1000          1\n"),
        "`unshare --map-root-user` maps one uid and must read as mapped");
    assert(!isMappedUserNamespace(""),
        "an unreadable map answers 'host', keeping the guard fail-closed");
    assert(!isMappedUserNamespace("garbage"),
        "an unparsable map answers 'host' too");

    // The real probe, against a socket this block owns. Bound to port 0 so the
    // kernel picks a free one — asking for a fixed port here would fail on a
    // busy host and read as a broken guard.
    auto sock = new TcpSocket();
    sock.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    sock.bind(new InternetAddress("127.0.0.1", 0));
    sock.listen(1);
    const ushort bound = sock.localAddress.toPortString.to!ushort;
    assert(bound != 0, "the kernel must have assigned a real port");
    assert(portBusy(bound),
        "portBusy answered 'free' for a port this test is listening on");
    sock.close();
    // Not asserting !portBusy(bound) after the close: another process on this
    // shared host may take the port in the gap, and a flaky guard is worse
    // than a one-sided one. The direction that must never fail silently is the
    // one above.

    // WHERE the guard is called cannot be seen by the table above — the
    // predicate is identical wherever it sits — and the position is exactly
    // what broke `tests/test_harness_load_log.d` once already: refusing a
    // `--print-scratch` query for a port it never takes. A behavioural cell
    // would have to occupy the default port, which this project forbids on
    // this machine, so the witness is a census over this file's own text.
    // It reddens the moment someone moves the call back above the query modes.
    {
        import std.file : readText;
        import std.algorithm : count;
        // The needles are SPLIT so that this block does not contain them: a
        // census that quotes its own subject finds itself. Two attempts here
        // did exactly that — first over the whole file, then over "main()'s
        // body" anchored on a spelling that also appears above — and both
        // times the mutation that moves the guard stayed GREEN while the
        // numbers looked plausible. The population floor below is what makes
        // the self-match impossible to reintroduce quietly: each needle must
        // occur EXACTLY once in this file.
        const self    = readText(__FILE_FULL_PATH__);
        const nQuery   = "if (print" ~ "Scratch) {";
        const nGuard   = "refuseDefaultBusyPort(port" ~ "Given,";
        const nBarrier = "test-liveness barrier: refusing" ~ " to build";
        assert(self.count(nQuery)   == 1, "the --print-scratch early exit is not unique");
        assert(self.count(nGuard)   == 1, "the default-port guard's call site is not unique");
        assert(self.count(nBarrier) == 1, "the test-liveness barrier is not unique");
        const query   = self.indexOf(nQuery);
        const guard   = self.indexOf(nGuard);
        const barrier = self.indexOf(nBarrier);
        assert(query < guard,
            "the default-port guard must run AFTER the query modes: they bind "
            ~ "no port, and refusing them is how this guard broke the harness "
            ~ "load test the first time");
        assert(guard < barrier,
            "the default-port guard must still run BEFORE anything is built, "
            ~ "killed or spawned — the barrier is that boundary");
    }
}

void killStaleVibe(ushort port) {
    // pkill returns 1 if no matches — that's fine. We match by --http-port
    // arg so workers running on OTHER ports survive.
    auto pat = format("vibe3d --test --http-port %d", port);
    executeShell(format("pkill -f '%s' 2>/dev/null", pat));
    // Wait for the process to die.
    for (int i = 0; i < 20; ++i) {
        auto r = executeShell(format("pgrep -f '%s' >/dev/null", pat));
        if (r.status != 0) break;
        Thread.sleep(100.msecs);
    }
    // Wait for the port itself to be free (TIME_WAIT can linger).
    for (int i = 0; i < 50; ++i) {
        if (!portBusy(port)) return;  // port free
        Thread.sleep(100.msecs);
    }
    stderr.writefln(red("warning: port %d still in use after 5s"), port);
}

// ---------------------------------------------------------------------------
// Build steps
// ---------------------------------------------------------------------------

bool dubBuild() {
    write("Building vibe3d... ");
    stdout.flush();
    auto sw = StopWatch(AutoStart.yes);
    scope(exit) g_harness.buildSeconds = sw.peek.total!"msecs" / 1000.0;
    auto r = executeShell("dub build 2>&1");
    if (r.status != 0) {
        writeln(red("FAIL"));
        writeln(r.output);
        return false;
    }
    writeln(green("OK"));
    writeBuildStamp();
    return true;
}

// What `./vibe3d` was built FROM, recorded next to it. `--no-build` compares
// against this instead of file timestamps, because timestamps answer neither
// question that matters:
//
//   * `git checkout` / stash / rebase rewrite mtimes without changing content,
//     so an mtime rule refuses a binary that is in fact current (the branch
//     workflow this repo runs on hits that constantly);
//   * `run_all.d`'s perf lane and `--config=with-render` OVERWRITE ./vibe3d
//     with a different build, leaving it NEWER than every source — so an mtime
//     rule waves through exactly the "you are testing a different artifact"
//     case the guard exists to catch (run_all.d says so in its own comments).
//
// The digest is over source CONTENT, so it answers "same sources?"; the stamp
// is only written by dubBuild, so a foreign build leaves it absent or stale
// and the mismatch is caught by the binary's own mtime being newer than it.
enum string kBuildStampPath = ".vibe3d.buildstamp";

string sourceDigest() {
    import std.digest.crc : CRC64ECMA;
    import std.file : read;
    CRC64ECMA hash;
    hash.start();
    string[] files;
    // `dirEntries` is lazy and stats each entry as it goes, so an editor's
    // temp file (or a `.d` deleted by a concurrent branch switch) mid-walk
    // throws FileException — out of a helper whose whole job is answering
    // "same sources?". A partial walk gives a digest that simply differs,
    // which the caller already handles as "rebuild"; a stack trace instead
    // of a test run does not (task 0685 T7).
    try {
        foreach (pattern; ["*.d", "*.c"])
            foreach (e; dirEntries("source", pattern, SpanMode.depth))
                if (e.isFile) files ~= e.name;
    } catch (Exception e) {
        stderr.writeln(yellow("source scan interrupted (" ~ e.msg
                            ~ ") — treating the build as stale"));
        return "";
    }
    sort(files);
    foreach (f; files) {
        hash.put(cast(const(ubyte)[]) f);
        try hash.put(cast(const(ubyte)[]) read(f));
        catch (Exception) { /* vanished mid-scan — digest simply differs */ }
    }
    import std.digest : toHexString;
    return hash.finish().toHexString().idup;
}

void writeBuildStamp() {
    // Empty = the walk was interrupted (see sourceDigest). Never stamp that:
    // an empty stamp would compare EQUAL to a second interrupted digest and
    // certify a stale binary as fresh. Leaving the old stamp in place makes
    // the next run's comparison fail, which is the safe direction.
    auto digest = sourceDigest();
    if (digest.length == 0) return;
    try std.file.write(kBuildStampPath, digest);
    catch (Exception e) stderr.writeln(yellow("could not write build stamp: " ~ e.msg));
}

// Pure-D unit tests that exercise project source modules in-process (e.g.
// test_xform_matrix_kernel imports `tools.xform_kernels` / `mesh` / `math`)
// cannot be compiled with the bare `-I=tests` line below — they pull the
// full dependency graph (bindbc-opengl, OpenSubdiv C libs, …). For those we
// harvest dmd flags from `dub describe` ONCE and append them. Other tests
// (HTTP drivers that only import std.* + helpers) are unaffected.
//
// `__gshared` + lazy init so the (slowish) `dub describe` runs at most once
// across all workers, and only if a source-backed test is present.
// Harvested once and split in two so the project test-lib can be linked in the
// right order: COMPILE flags (-I / -J / -version) are position-independent,
// while the LINK TAIL (lflags, -l libs, dep .a archives) is order-sensitive and
// must come AFTER the project lib on the command line so its undefined symbols
// resolve against the deps.
__gshared string g_compileFlags;
__gshared string g_linkTail;
__gshared bool   g_sourceFlagsDone;

void harvestSourceFlags() {
    synchronized {
        if (g_sourceFlagsDone) return;
        g_sourceFlagsDone = true;
        // Each `--data=<x> --data-list` emits one item per line; dub prints a
        // few leading "Warning" lines to stderr which 2>/dev/null drops.
        string gather(string kind, string prefix) {
            auto rr = executeShell(format(
                "dub describe --config=modeling --data=%s --data-list 2>/dev/null", kind));
            if (rr.status != 0) return "";
            string acc;
            foreach (line; rr.output.splitLines) {
                auto s = line.strip;
                if (s.length == 0) continue;
                acc ~= " " ~ prefix ~ s;
            }
            return acc;
        }
        g_compileFlags ~= gather("import-paths",        "-I=");
        g_compileFlags ~= gather("string-import-paths", "-J=");
        g_compileFlags ~= gather("versions",            "-version=");
        // ImportC preprocess flags are compile inputs too. In particular,
        // task 5930's project-owned C source includes the linked UI package's
        // header through its expanded -P-I path.
        g_compileFlags ~= gather("dflags",               "");
        g_linkTail     ~= gather("lflags",              "-L");
        g_linkTail     ~= gather("libs",                "-L-l");
        // linker-files (.a archives) are passed verbatim.
        {
            auto rr = executeShell(
                "dub describe --config=modeling --data=linker-files --data-list 2>/dev/null");
            if (rr.status == 0)
                foreach (line; rr.output.splitLines) {
                    auto s = line.strip;
                    if (s.length) g_linkTail ~= " " ~ s;
                }
        }
    }
}

string sourceCompileFlags() { harvestSourceFlags(); return g_compileFlags; }
string sourceLinkTail()     { harvestSourceFlags(); return g_linkTail; }

// A test is "source-backed" if it imports any first-party project module.
// Heuristic: a top-level `import <mod>` / `import <mod> :` whose module is one
// of the known project roots. HTTP-driver tests only import std.* + helpers,
// so this stays false for them and the cheap compile path is used.
bool isSourceBackedTest(string path) {
    string txt;
    try { txt = readText(path); } catch (Exception) { return false; }
    static immutable string[] roots = [
        "math", "mesh", "tools.", "toolpipe.", "falloff", "symmetry",
        "view", "camera_stamp", "handler", "shader", "editmode", "command",
        "snapshot", "forms", "params", "argstring", "shortcuts", "ai.",
        "buttonset", "ai3d.", "document", "commands.ai3d.", "http_server",
    ];
    foreach (line; txt.splitLines) {
        auto s = line.strip;
        // R1: anchor to column 0 — test the RAW line so only genuinely top-level
        // imports count (an indented function-local `import math:` must NOT
        // flip an HTTP test to the heavy source-backed compile line).
        if (!line.startsWith("import ")) continue;
        string mod = s["import ".length .. $].strip;
        foreach (root; roots) {
            if (mod == root || mod.startsWith(root ~ " ")
                || mod.startsWith(root ~ ":") || mod.startsWith(root ~ ";")
                || (root.endsWith(".") && mod.startsWith(root)))
                return true;
        }
    }
    return false;
}

/// Build all modeling project source (minus app.d's `main`) into a static lib
/// ONCE per run, so each source-backed test links it instead of recompiling the
/// whole project graph via `dmd -i` — ≈6× faster per test and ≈6× less peak RAM
/// (so far more workers fit in the same memory), and it removes the `-i` + dep
/// archive duplicate symbols that block mold. Returns the lib path, or "" on
/// failure (the caller hard-fails rather than taking the high-RAM -i path).
/// Built with -unittest to match
/// the test compile; as a static archive only referenced members are pulled, so
/// a test no longer re-runs its *imported* project modules' unittests — those
/// are covered by the separate `dub test` step, and the test's own asserts are
/// unchanged (verified: identical assertion output, just fewer module unittests).
string buildProjectLib(string scratch) {
    auto rr = executeShell(
        "dub describe --config=modeling --data=source-files --data-list 2>/dev/null");
    if (rr.status != 0) return "";
    string[] srcs;
    foreach (line; rr.output.splitLines) {
        auto s = line.strip;
        // Exclude app.d: it carries the real `main`, which would clash with the
        // test binary's own `main`. Every other modeling module compiles clean
        // without WithRender (render/* bodies are version-gated to empty).
        if (s.length && !s.endsWith("/app.d") && !s.endsWith("\\app.d"))
            srcs ~= s;
    }
    if (srcs.empty) return "";
    const lib = buildPath(scratch, "libvibe3d_test.a");
    auto r = executeShell(format("dmd -lib -unittest%s %s -of=%s 2>&1",
                                 sourceCompileFlags(), srcs.join(" "), lib));
    if (r.status != 0 || !exists(lib)) {
        if (r.output.length) stderr.writeln(dim(r.output));
        return "";
    }
    return lib;
}

/// Probe ONCE whether dmd can link through mold (much faster than bfd/gold for
/// the lib-link path). Needs mold on PATH and a cc new enough for
/// `-fuse-ld=mold` (gcc>=12 / clang); otherwise returns "" and we keep the
/// default linker. Only used on the project-lib path — the `-i` path links the
/// project AND the dep archives, which double-defines symbols that mold (unlike
/// GNU ld) rejects; the prebuilt lib has no such duplication.
string probeMoldFlag() {
    if (executeShell("command -v mold").status != 0) return "";
    const probe = buildPath(tempDir(), format("vibe3d_mold_probe_%d", getpid()));
    void cleanup() {
        foreach (ext; ["", ".d", ".o"])
            try { if (exists(probe ~ ext)) std.file.remove(probe ~ ext); }
            catch (Exception) {}
    }
    scope(exit) cleanup();
    try {
        std.file.write(probe ~ ".d", "void main(){}\n");
        if (executeShell(format("dmd -L-fuse-ld=mold -of=%s %s.d 2>&1", probe, probe)).status == 0)
            return " -L-fuse-ld=mold";
    } catch (Exception) {}
    return "";
}

/// The modules injected into EVERY test binary's compile line, in command-line
/// order. THIS IS THE SINGLE SOURCE OF TRUTH for that set: the compile below
/// and the build-time barrier `gateViolations` both read it, so the barrier
/// can never check a different list than the one that actually gets compiled.
/// Do not re-derive the set from a glob at either call site.
string[] injectedTestModules(string testsDir = "tests") {
    string[] mods;
    if (!exists(testsDir)) return mods;
    // Shared HTTP transport for every driver. `-I=tests` makes the module
    // visible, but DMD only emits code for modules named on its command line.
    mods ~= buildPath(testsDir, "http_client.d");
    foreach (e; dirEntries(testsDir, "*_helpers.d", SpanMode.shallow))
        mods ~= e.name;
    sort(mods);
    // The liveness gate (task 1111): linked into every binary so a test that
    // executes nothing cannot exit 0. Deliberately named so it matches neither
    // the `test_*.d` discovery glob nor the `*_helpers.d` glob above — it is
    // not a test and not a helper, and matching either would have quietly made
    // it one.
    mods ~= buildPath(testsDir, "liveness_gate.d");
    return mods;
}

/// The BUILD-TIME half of task 1111 — the cause-side companion to the
/// symptom-side check in tests/liveness_gate.d. Returns one "file:line: text"
/// string per violation; empty means the tree is sound.
///
/// ONE IMPLEMENTATION, DELIBERATELY. `--check-gate` and the startup path must
/// both call THIS function. A second copy written "for the test" would make
/// every barrier case in tests/test_liveness_gate.d vacuous — they would pin
/// the copy while real runs used the original. Same reason the injected-module
/// set is read from injectedTestModules() rather than re-globbed here.
///
/// NOT A PARSER, and that limit is accepted. Rules (a) and (b) look for a line
/// that STARTS with `unittest`, and rule (c) recognises `main` by the stripped
/// text of its declaration line — so a `unittest` at column 0 inside a block
/// comment, or a `main` whose brace sits on the next line, would be judged
/// wrongly. Neither exists in tests/ today (measured: no indented unittest
/// blocks either), and the answer to a false refusal is to reshape the two
/// lines, not to weaken the rule into something that cannot refuse.
string[] gateViolations(string testsDir) {
    string[] out_;

    static bool startsUnittest(string line) { return line.startsWith("unittest"); }

    static bool hasOwnUnittest(string txt) {
        foreach (line; txt.splitLines) if (startsUnittest(line)) return true;
        return false;
    }

    // (a) A module injected into EVERY test binary must carry no unittest.
    foreach (m; injectedTestModules(testsDir)) {
        if (!exists(m) || !isFile(m)) continue;
        string txt;
        try { txt = readText(m); } catch (Exception) { continue; }
        foreach (i, line; txt.splitLines) {
            if (!startsUnittest(line)) continue;
            out_ ~= format("%s:%d: a module compiled into EVERY test binary carries a "
                ~ "`unittest` block. Druntime runs the unittests and then SKIPS main() "
                ~ "in every test that links it, so those tests print a pass having run "
                ~ "nothing. Put the check in a test_*.d file's own unittest block.",
                m, i + 1);
        }
    }

    if (!exists(testsDir)) return out_;

    string[] testPaths;
    foreach (e; dirEntries(testsDir, "test_*.d", SpanMode.shallow)) testPaths ~= e.name;
    sort(testPaths);

    foreach (t; testPaths) {
        string txt;
        try { txt = readText(t); } catch (Exception) { continue; }
        immutable bool ownUt = hasOwnUnittest(txt);

        // (b) A source-backed test links a -unittest build of the project
        // library, so SOMETHING in that library will run unittests and its
        // main() will be skipped. Its scenarios must live in its own blocks.
        if (!ownUt && isSourceBackedTest(t))
            out_ ~= format("%s:1: this test imports project source, so it links a "
                ~ "-unittest build of the project library; druntime will run that "
                ~ "library's unittests and SKIP this file's main(). Move the scenarios "
                ~ "into this file's own `unittest` blocks.", t);

        // (c) A test that has its OWN unittest blocks must have an EMPTY main:
        // once any module runs unittests, main() is not called, so a non-empty
        // body is code that can never execute. The symptom-side gate cannot see
        // this class at all — from inside the process, an empty main and a main
        // that was never called are indistinguishable.
        if (ownUt) {
            foreach (i, line; txt.splitLines) {
                auto t2 = line.strip;
                if (!t2.startsWith("void main(") && !t2.startsWith("int main(")) continue;
                if (t2 == "void main() {}" || t2 == "void main(string[] args) {}") break;
                out_ ~= format("%s:%d: this test has its own `unittest` block(s), so "
                    ~ "druntime will NOT call main() — but main() has a body, and that "
                    ~ "body can never run. Make it `void main() {}` and move its work "
                    ~ "into a `unittest` block.", t, i + 1);
                break;
            }
        }
    }
    return out_;
}

/// Compile each test in `paths` into `outDir`. Tests resolve their worker's
/// endpoint at runtime through `VIBE3D_TEST_PORT`; sources are compiled AS-IS,
/// straight from tests/ — `outDir` receives binaries and their `.out` logs and
/// nothing else, which is why no `-I=<outDir>` appears on the lines below.
string[] compileTests(string[] paths, string outDir) {
    // Pull every injected module (see injectedTestModules) into the
    // compilation so a test can `import drag_helpers;` — or
    // `import liveness_gate : scenario;` — without duplicating shared code.
    // `http_client` reads the per-worker port from the child environment, so
    // these sources are compiled without scratch copies. Globbed ONCE: the set
    // cannot change mid-run, and re-reading tests/ per test binary was ~750
    // directory scans a worker.
    string helpers;
    foreach (m; injectedTestModules()) helpers ~= " " ~ m;

    string[] bins;
    foreach (p; paths) {
        string name = baseName(p).stripExtension;
        string of   = buildPath(outDir, name);
        // -J=tests lets a test embed a golden fixture via
        // `import("fixtures/<name>.json")` (see tests/fixture_helpers.d).
        //
        // Source-backed tests link the prebuilt project library plus the
        // harvested dependency graph. We drop `-w` for these because the
        // third-party dep code carries warnings that aren't ours to fix; the
        // test's own warnings still surface via the bare-path tests.
        // HTTP-driver tests keep the original cheap line.
        string cmd;
        if (isSourceBackedTest(p)) {
            if (!projLibPath.length) {
                writeln("  ", red("FAIL  "), name,
                    ": source-backed compile has no project test-lib");
                return null;
            }
            // Order is load-bearing: test.o, then the project lib, then the
            // dep archives/link tail (mold is order-strict).
            cmd = format("dmd -unittest -J=tests -I=tests%s%s %s %s%s%s -of=%s 2>&1",
                         helpers, sourceCompileFlags(), p,
                         projLibPath, sourceLinkTail(), moldFlag, of);
        } else {
            cmd = format("dmd -unittest -J=tests -I=tests%s %s -w -of=%s 2>&1",
                         helpers, p, of);
        }
        auto r = executeShell(cmd);
        if (r.status != 0) {
            writeln("  ", red("FAIL  "), name);
            writeln(r.output);
            return null;
        }
        bins ~= of;
    }
    return bins;
}

// ---------------------------------------------------------------------------
// Prepared-tool protocol census
// ---------------------------------------------------------------------------

enum string kProtocolScanner = "tools/check_prepared_protocol.py";

/// The prepared tool-transition protocol's census. Since task 4052 it is a
/// SOURCE SCAN and nothing else: the `tests/compile_fail/` fixtures it used to
/// hand to the compiler one file at a time are gone, because both properties
/// they stated are one `static assert` in D. They now live in
/// `tests/unit/prepared_tool_transition_test.d` -- `!__traits(isCopyable, T)`
/// over a named census of all 134 prepared tokens, and
/// `!__traits(compiles, requirePreparedField!T)` for the seven field shapes --
/// paid by `dub test --config=tests`, which compiles that module anyway.
///
/// WHAT IS LEFT IS THE IRREPLACEABLE HALF, AND IT IS NOT FIXTURES. Roughly
/// 85 % of the scanner pins properties D compile-time reflection cannot state
/// at all: the ORDER of statements inside another module's function body, the
/// set of CALLERS of a symbol across files no test binary imports, occurrence
/// counts, negative call sets, and SHA-256 digests of function bodies. Those
/// have no assert-shaped substitute, which is why this call did not go away
/// with the fixtures. The scanner also keeps the half of the new D census a
/// compiler cannot see: that the module list the census runs over still
/// matches the .d files on disk, in both directions.
///
/// WHY IT LIVES HERE AND NOT IN dub.json. It hung off `preBuildCommands` of
/// the `tests` configuration, where P1.0a's review had put it for a reason
/// that is still true: with no caller at all, the whole-tree properties above
/// may degrade while both routine lanes stay green. The reason it could not
/// stay there is cost. Measured on the gate host, 2026-09-02, three
/// consecutive runs: 38.4 / 38.4 / 38.5 s wall, 243 MiB peak RSS -- against a
/// lane that is otherwise ~51 s, and dub runs preBuildCommands on every build
/// that actually builds. Task 4052 measured where that went by putting a
/// timing wrapper around the compiler: 81 invocations, of which 72 were
/// fixtures costing 21.6 s. With them gone, three consecutive runs on
/// 2026-09-04 read 19.5 / 19.6 / 19.5 s wall, 242 MiB peak RSS (the memory is
/// the Python, not the compiler, and did not move). Still paid ONCE per suite
/// run rather than once per test build.
///
/// The output is the scanner's own, inherited: its PASS line on stdout, its
/// `SystemExit` message on stderr. Nothing is summarised or swallowed, so a
/// failure reads the same here as it did in the build log.
bool protocolCensus() {
    // A missing scanner is a REFUSAL, not a skip. "The file is not there" is
    // indistinguishable, from a green lane, from "the fixtures are fine", and
    // the whole point of moving this call was to keep exactly one caller
    // honest about running it.
    if (!exists(kProtocolScanner)) {
        stderr.writeln(red("prepared-protocol census: " ~ kProtocolScanner
                         ~ " is missing -- refusing to measure a tree whose "
                         ~ "compile-fail fixtures nothing checks"));
        return false;
    }
    auto sw = StopWatch(AutoStart.yes);
    Pid pid;
    try {
        pid = spawnProcess(["python3", kProtocolScanner]);
    } catch (ProcessException e) {
        stderr.writeln(red("prepared-protocol census: could not start python3: " ~ e.msg));
        return false;
    }
    const rc = wait(pid);
    sw.stop();
    const secs = sw.peek.total!"msecs" / 1000.0;
    if (rc != 0) {
        stderr.writefln(red("prepared-protocol census: FAILED (exit %d, %.1fs) "
                          ~ "-- the scanner's own message is above"), rc, secs);
        return false;
    }
    writefln(dim("prepared-protocol census: ok (%.1fs)"), secs);
    return true;
}

// ---------------------------------------------------------------------------
// vibe3d lifecycle
// ---------------------------------------------------------------------------

Pid startVibe(ushort port, string logPath) {
    auto logFile = File(logPath, "wb");
    string[] argv = ["./vibe3d", "--test", "--http-port", port.to!string];
    // A runner-owned worker must not inherit one caller-owned X socket (task
    // 4660). Task 5010 adds one narrow exception: a NON-EMPTY
    // VIBE3D_TEST_DISPLAY becomes the worker's DISPLAY. Missing or empty keeps
    // DISPLAY absent. No other display variable is rewritten, and --attach
    // never reaches startVibe, so external endpoints remain caller-owned.
    auto childEnv = environment.toAA();
    childEnv.remove("DISPLAY");
    const requestedDisplay = environment.get(workerDisplayEnv, "");
    if (requestedDisplay.length)
        childEnv["DISPLAY"] = requestedDisplay;
    Pid pid;
    try {
        pid = spawnProcess(argv, stdin, logFile, logFile,
            childEnv, Config.suppressConsole | Config.newEnv);
    } catch (ProcessException e) {
        stderr.writeln(red("failed to spawn vibe3d: "), e.msg);
        return null;
    }
    synchronized {
        vibePids ~= pid.processID;
    }
    return pid;
}

// Linux-only behavioural probe for the runner's own spawn boundary (task
// 5010). It launches through startVibe, waits until exec has installed the
// worker argv, then reports DISPLAY from the ACTUAL /proc environment. Tests
// run it beside a harmless fake ./vibe3d so no X server is required.
int probeWorkerDisplay(ushort port) {
    version (linux) {
        const logPath = buildPath(getcwd(), "worker-display-probe.log");
        auto pid = startVibe(port, logPath);
        if (pid is null) return 2;
        scope(exit) cleanup();

        const procRoot = format("/proc/%d", pid.processID);
        bool execReady;
        foreach (_; 0 .. 200) {
            try {
                if (readText(buildPath(procRoot, "cmdline")).canFind("--http-port")) {
                    execReady = true;
                    break;
                }
            } catch (Exception) {}
            Thread.sleep(10.msecs);
        }
        if (!execReady) {
            stderr.writefln(red("worker-display probe: pid %d did not reach exec"),
                            pid.processID);
            return 2;
        }

        string display;
        bool present;
        try {
            const raw = readText(buildPath(procRoot, "environ"));
            foreach (entry; raw.split('\0')) {
                enum prefix = "DISPLAY=";
                if (!entry.startsWith(prefix)) continue;
                present = true;
                display = entry[prefix.length .. $];
                break;
            }
        } catch (Exception e) {
            stderr.writefln(red("worker-display probe: could not read pid %d environment: %s"),
                            pid.processID, e.msg);
            return 2;
        }

        if (present) writeln("WORKER DISPLAY PRESENT=", display);
        else         writeln("WORKER DISPLAY ABSENT");
        return 0;
    } else {
        stderr.writeln("worker-display probe requires Linux /proc");
        return 2;
    }
}

bool waitForHttpReady(string logPath, ushort port) {
    string needle = format("HTTP server started on port %d", port);
    bool listening;
    for (int i = 0; i < 100; ++i) {
        if (exists(logPath)) {
            try {
                auto f = File(logPath, "r");
                foreach (line; f.byLine())
                    if ((cast(string)line.idup).canFind(needle)) { listening = true; break; }
            } catch (Exception) {}
        }
        if (listening) break;
        Thread.sleep(100.msecs);
    }
    if (!listening) {
        stderr.writefln(red("  :%d never logged \"HTTP server started\" — "
                            ~ "the process died or never got that far"), port);
        return false;
    }
    string lastStatus;
    if (httpProbe(port, 300, 5, &lastStatus)) return true;
    stderr.writefln(red("  :%d listened but never answered 200. %s"),
                    port, diagnoseProbeFailure(port, lastStatus));
    return false;
}

// Turn the last probe sample into a sentence that says WHICH investigation to
// open (task 1740). The message this replaces enumerated two outcomes, 500 and
// 000, and CI then failed with a third — `curl-rc=52` — on four workers of
// four, for a day, with the instances perfectly healthy: their logs carried
// not one `Received request` line, because the probe had never reached them.
//
// The rule the runner now applies, and the reason it is a CODE and not a body:
//   503  the app is up and says it is still wiring (the ONLY "keep waiting"
//        answer; `http_server.d`'s readiness gate). Seeing it here means the
//        budget was genuinely outrun.
//   200  ready.
//   anything else — another HTTP code, or curl failing to complete at all —
//        is a REFUSAL, and the probe stops rather than spending 30 s
//        re-confirming it.
//
// The curl exit codes are spelled out because each one names a different
// place to look, and they were measured rather than recalled (task 1740,
// `scratch/curlcodes.py`): 52 is produced by exactly ONE server shape —
// accepted the connection, read the request, closed it without writing a
// byte — which our own listener cannot do at any point in its startup.
string diagnoseProbeFailure(ushort port, string lastStatus) {
    string proxyNote() {
        // The measured cause of the 2026-08-30 CI failure. A GitHub Actions
        // self-hosted runner exports its proxy configuration into every
        // step's environment, and curl honours `http_proxy` for
        // `http://localhost:PORT` too unless `no_proxy` says otherwise — so
        // the probe talks to the proxy, the proxy has nothing to forward to,
        // and the app never sees a request.
        foreach (v; ["http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"]) {
            auto p = environment.get(v, "");
            if (!p.length) continue;
            auto np = environment.get("no_proxy", environment.get("NO_PROXY", ""));
            if (np.canFind("localhost") && np.canFind("127.0.0.1")) continue;
            return format("\n  %s=%s is set and no_proxy=%s does not exempt "
                        ~ "localhost — curl is sending this probe to the PROXY, "
                        ~ "not to :%d. That is a probe-transport failure, not a "
                        ~ "server failure.",
                        v, p, np.length ? np : "<unset>", port);
        }
        return "";
    }
    switch (lastStatus) {
        case "503":
            return format("last status 503 — the app is alive and still wiring "
                        ~ "its providers, so startup outran the %d s probe "
                        ~ "budget. Widen the budget or find what made startup "
                        ~ "slow; the server itself is healthy.", 30);
        case "curl-rc=7":
            return "curl could not connect (rc=7): nothing is listening on "
                 ~ "that port any more — the process died after logging "
                 ~ "\"HTTP server started\"." ~ proxyNote();
        case "curl-rc=28":
            return "curl timed out with no reply (rc=28): the connection was "
                 ~ "completed by the kernel's listen backlog but the accept "
                 ~ "loop never answered — a wedged server (cf. task 0652)."
                 ~ proxyNote();
        case "curl-rc=52":
            return "curl got an EMPTY reply (rc=52): something accepted the "
                 ~ "connection, read the request and closed it without "
                 ~ "answering. Our listener has no such state at any point in "
                 ~ "startup — check the instance's log for `Received request` "
                 ~ "lines first: if there are NONE, the probe never reached "
                 ~ "the app." ~ proxyNote();
        case "curl-rc=56":
            return "curl's connection was RESET (rc=56): the peer aborted "
                 ~ "mid-request — the listening socket was closed while this "
                 ~ "request was in flight." ~ proxyNote();
        default:
            if (lastStatus.startsWith("curl-rc="))
                return format("curl failed to complete the request (%s) — this "
                            ~ "is a probe-transport failure, not an answer from "
                            ~ "the app.%s", lastStatus, proxyNote());
            return format("last status %s. Only 503 means \"still starting\"; "
                        ~ "any other code is a refusal from something that "
                        ~ "answered.%s", lastStatus, proxyNote());
    }
}

// Poll /api/camera until it answers 200 (or we give up). Used after we spawn
// vibe3d, in --attach mode to wait for the external endpoint, and by the
// end-of-run report to tell a HUNG server from a healthy one.
//
// `--max-time` is load-bearing, not hygiene: a server whose accept loop is
// wedged (task 0652) still gets its connection completed by the kernel's
// listen backlog, so a bare `curl` CONNECTS and then waits for a reply that
// never comes — forever, with no timeout of its own. Every caller here would
// rather have "no" after a few seconds than hang the runner (task 0685 T5).
// `tries` is 300 (~30 s), not 100. The budget has to cover the window
// between "the listener is up" and "the app finished wiring its providers",
// because GET /api/camera answers 500 for the whole of it
// (`http_server.d`'s route returns 500 while `cameraDataProvider` is null).
// On a loaded CI VM — 16 logical cores over 4 physical, four instances
// initialising GL through a software rasteriser at once — that window
// exceeded the old ~10 s and failed a run whose code was fine; the same
// commit passed on a re-run (2026-08-19).
//
// `lastStatus` exists so the NEXT such failure is diagnosable from one
// line. Without it the log shows a healthy-looking startup and then
// silence, which reads as a hang and cost three misdirected attempts to
// tell apart from a real one.
//
// TASK 1740 — WHAT COUNTS AS "KEEP WAITING" IS NOW A CODE, NOT A GUESS.
// `http_server.d` answers 503 on every `/api/*` route until it is ready, and
// 503 is the ONLY status this loop treats as "not yet". Everything else is a
// refusal and ends the loop on the spot, because re-asking 299 more times
// cannot change a refusal and costs 30 s of a lane's turn. The old loop spun
// the full budget over `curl-rc=52` — a code the failure message did not even
// enumerate — and then blamed the app, whose log showed it had never been
// asked anything. `diagnoseProbeFailure` above says which of those it was.
//
// The 500 the previous version waited on is now a REFUSAL, deliberately: with
// the gate in place, 500 from `/api/camera` means the server is ready and
// `cameraDataProvider` is genuinely absent, which no amount of waiting fixes.
bool httpProbe(ushort port, int tries = 300, int timeoutSec = 5,
               string* lastStatus = null) {
    string probe = format("curl -s -o /dev/null --connect-timeout %d "
                          ~ "--max-time %d -w '%%{http_code}' "
                          ~ "http://localhost:%d/api/camera",
                          timeoutSec, timeoutSec, port);
    string seen = "none";
    scope(exit) if (lastStatus !is null) *lastStatus = seen;
    for (int i = 0; i < tries; ++i) {
        auto r = executeShell(probe);
        seen = (r.status == 0) ? r.output.strip : format("curl-rc=%d", r.status);
        if (seen == "200") return true;
        // 000 is what curl prints for `%{http_code}` when it exited non-zero;
        // the rc branch above has already recorded the real reason.
        //
        // TWO states mean "ask again", and only two. 503 is the app saying it
        // is still wiring. `curl-rc=7` is "nothing is listening yet", which is
        // a real startup state for the `--attach` caller below (it waits for
        // an endpoint that does not exist at first) and a bind race for the
        // spawn caller. Every other answer is a refusal: re-asking cannot
        // change it, and spending the remaining budget on it is how a
        // transport failure got 30 s of a lane's turn and then a message
        // blaming the app.
        if (seen != "503" && seen != "curl-rc=7") return false;
        Thread.sleep(100.msecs);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Test execution
// ---------------------------------------------------------------------------

// A test that HUNG and a test that FAILED want opposite investigations, so
// they are different states and not one `bool passed` (task 1420). "It went
// quiet" was read as a hang three times in one CI diagnosis on 2026-08-19 and
// was not one; the runner is the only place that KNOWS which happened, so it
// is the place that has to say so.
enum TestStatus { passed, failed, timedOut }

struct TestResult {
    string     name;
    TestStatus status;
    string     output;   // captured stdout+stderr (only kept on failure/timeout)
    double     seconds;  // wall-clock duration of this test (for timing cache)

    // Everything that only asks "is this run red?" keeps reading one flag.
    bool passed() const { return status == TestStatus.passed; }
}

// Run in the CHILD between fork and exec: put it in its own process GROUP.
//
// This is what makes the timeout able to kill a TREE. Our tests shell out —
// `curl` per API call, and some spawn their own helpers — and killing only the
// direct child leaves those orphans behind, holding the port the next worker
// wants (task 1420, trap 4). With the child as its own group leader, one
// `kill(-pid)` reaches the whole subtree it created.
//
// The cost of the group: the terminal's Ctrl-C no longer reaches the test.
// That is why `testGroupPids` exists and why `onSignal` kills those groups.
bool ownProcessGroup() nothrow @nogc @trusted {
    return setpgid(0, 0) == 0;
}

// Reap `pid` if it terminates within `limit`. Polls rather than blocking so
// the caller keeps the option of giving up.
private bool reapWithin(Pid pid, Duration limit) {
    auto sw = StopWatch(AutoStart.yes);
    while (true) {
        if (tryWait(pid).terminated) return true;
        if (sw.peek >= limit) return false;
        Thread.sleep(20.msecs);
    }
}

// Wait for `pid`, but not forever. `false` = `limit` elapsed and the process is
// still running (and is now the caller's to kill).
//
// `limit <= 0` means "no cap" and takes the old blocking path verbatim, so
// --timeout 0 costs nothing and behaves exactly as this runner did before.
bool waitFor(Pid pid, Duration limit, out int status) {
    if (limit <= Duration.zero) { status = wait(pid); return true; }
    auto sw = StopWatch(AutoStart.yes);
    while (true) {
        auto st = tryWait(pid);
        if (st.terminated) { status = st.status; return true; }
        immutable waited = sw.peek;
        if (waited >= limit) return false;
        // Fine-grained while a test could plausibly still be a fast one (the
        // median test here is ~0.3 s, so a coarse poll would tax every one of
        // ~130 of them), then back off: a legitimately slow test costs 20
        // wakeups a second instead of 500.
        Thread.sleep(waited < 1.seconds ? 2.msecs : 50.msecs);
    }
}

// SIGKILL the process group led by `gpid`, then reap the leader.
//
// SIGKILL and not a SIGTERM grace, deliberately. The process we are killing is
// by definition WEDGED, and the live hang this task was written for lives in a
// `scope(exit)` shutdown path (app.d's HttpServer.stop joining a server thread
// parked on a dead main thread) — i.e. exactly in the code a polite signal
// would ask it to run again. There is nothing to flush either: the captured
// output is a redirected FILE, so its stdio buffer is lost the same way under
// either signal.
//
// The group is killed BEFORE the leader is reaped, which is also what keeps
// `-gpid` unambiguous: a process group cannot be recycled while it still has a
// member, and the un-reaped leader is one.
//
// `gpid` here is always a just-spawned test's own post-`setpgid(0,0)` group,
// so by pid-uniqueness it can never legitimately equal the runner's own
// group (see `shouldKillGroup`) — but the check is one word compare, and
// skipping a self-group kill here is cheap insurance against exactly the
// same hazard `cleanup()`/`onSignal` guard against.
bool killTestTree(Pid pid, int gpid) {
    if (gpid <= 0) return false;
    if (!shouldKillGroup(gpid, getpgrp())) {
        stderr.writefln("run_test: killTestTree: refusing to SIGKILL process "
            ~ "group %d — it is this runner's OWN group", gpid);
        return false;
    }
    kill(-gpid, SIGKILL);
    return reapWithin(pid, 10.seconds);
}

TestResult runOne(string bin, bool verbose, ushort port) {
    TestResult r;
    r.name = baseName(bin);
    auto sw = StopWatch(AutoStart.yes);

    Config cfg;
    cfg.preExecFunction = &ownProcessGroup;
    string[string] childEnv = environment.toAA();
    childEnv["VIBE3D_TEST_PORT"] = port.to!string;
    if ((runLockFd >= 0 || runLockBorrowed) && r.name == "test_harness_load_log") {
        // The lease names the HOLDER's pid and descriptor; a borrowed slot
        // passes its own lender's lease on unchanged (task 6205).
        cfg.flags |= Config.Flags.inheritFDs;
        childEnv[inheritedRunLockPidEnv] = runLockBorrowed
            ? environment.get(inheritedRunLockPidEnv, "") : getpid().to!string;
        childEnv[inheritedRunLockFdEnv] = runLockBorrowed
            ? environment.get(inheritedRunLockFdEnv, "") : runLockFd.to!string;
    }

    string outPath = bin ~ ".out";
    File   out_;
    Pid    pid;
    if (verbose) {
        pid = spawnProcess([bin], stdin, stdout, stderr, childEnv, cfg);
    } else {
        out_ = File(outPath, "wb");
        pid  = spawnProcess([bin], stdin, out_, out_, childEnv, cfg);
    }
    immutable int gpid = pid.processID;   // == its pgid: it is the group leader
    synchronized { testGroupPids ~= gpid; }
    scope(exit) synchronized {
        foreach (ref p; testGroupPids) if (p == gpid) p = 0;
    }

    int code;
    immutable finished = waitFor(pid, g_testTimeout, code);
    r.seconds = sw.peek.total!"msecs" / 1000.0;

    if (finished) {
        r.status = (code == 0) ? TestStatus.passed : TestStatus.failed;
    } else {
        r.status = TestStatus.timedOut;
        if (!killTestTree(pid, gpid))
            stderr.writefln(red("  %s: still alive after SIGKILL — its pid %d "
                                ~ "is unreapable (uninterruptible sleep?)"),
                            r.name, gpid);
    }

    if (!verbose) {
        out_.close();
        // Kept for the timeout report too: the partial output is the only
        // evidence of HOW FAR the test got before it stopped moving.
        if (!r.passed) {
            try { r.output = readText(outPath); } catch (Exception) {}
        }
    }
    return r;
}

// ---------------------------------------------------------------------------
// Worker: one vibe3d + a slice of tests
// ---------------------------------------------------------------------------

struct Worker {
    int      id;
    ushort   port;
    string[] tests;    // assigned source paths
    string[] bins;     // compiled binaries
    string   scratch;  // per-worker scratch dir
    string   logPath;
    Pid      vibePid;
    // The OS pid, captured at spawn. `Pid.processID` is only valid until the
    // process is reaped — after `tryWait` returns `terminated` it reads back a
    // sentinel (-2), which is exactly when the end-of-run death report wants to
    // name it (task 0685 T3). Keep our own copy.
    int      vibePidNum;
}

// Last `maxLines` lines of `path`, read by seeking from the END rather than
// slurping the file (task 0685 T4). The report below runs on a FAILING run,
// and a crash-looping vibe3d's raw stdout+stderr log is exactly the case where
// it is large — on a CI VM with 7.7 GiB and a history of OOM kills, reading it
// whole to show 25 lines is the wrong trade.
string[] tailLines(string path, size_t maxLines) {
    auto f = File(path, "rb");
    scope (exit) f.close();
    immutable size_t chunk = 64 * 1024;
    ulong pos = f.size;
    ubyte[] buf;
    string[] lines;
    while (true) {
        immutable ulong step = pos > chunk ? chunk : pos;
        pos -= step;
        f.seek(cast(long) pos);
        auto part = new ubyte[cast(size_t) step];
        buf   = f.rawRead(part) ~ buf;
        lines = (cast(string) buf).splitLines;
        // `>` not `>=`: one spare line absorbs the partial line the chunk
        // boundary cut in half, which the slice below then drops.
        if (pos == 0 || lines.length > maxLines) break;
    }
    if (lines.length > maxLines) lines = lines[$ - maxLines .. $];
    return lines;
}

// Print the tail of a worker's vibe3d log — shared by both arms of the
// end-of-run server report (died / hung).
void reportVibeLogTail(ref Worker w) {
    enum size_t kTailLines = 25;
    try {
        auto lines = tailLines(w.logPath, kTailLines);
        writeln(dim(format("  last %d line(s) of %s:", lines.length, w.logPath)));
        foreach (line; lines) writeln("    ", line);
    } catch (Exception e) {
        writeln(dim("  (its log could not be read: " ~ e.msg ~ ")"));
    }
}

bool prepareWorker(ref Worker w) {
    mkdirRecurse(w.scratch);
    w.bins = compileTests(w.tests, w.scratch);
    if (w.bins is null) return false;
    if (g_attachPort != 0) {
        // Attach mode: an external endpoint (the visual_test_proxy → a visible
        // vibe3d) already listens on w.port. Don't kill or spawn anything — just
        // wait for it to answer. It stays alive after the run (never in vibePids).
        if (!httpProbe(w.port)) {
            stderr.writefln(red("attach: nothing answering on http://localhost:%d"), w.port);
            return false;
        }
        return true;
    }
    killStaleVibe(w.port);
    w.logPath = buildPath(w.scratch, "vibe3d.log");
    w.vibePid = startVibe(w.port, w.logPath);
    if (w.vibePid is null) return false;
    w.vibePidNum = w.vibePid.processID;   // valid now; a sentinel once reaped
    if (!waitForHttpReady(w.logPath, w.port)) {
        stderr.writefln(red("worker %d: vibe3d on :%d failed to come up"),
            w.id, w.port);
        try { stderr.writeln(readText(w.logPath)); } catch (Exception) {}
        return false;
    }
    return true;
}

// Re-establish a known-clean baseline on a worker's shared vibe3d BEFORE each
// test binary runs. The runner reuses ONE `vibe3d --test` per worker across
// that worker's whole slice of tests, so a preceding test can leave global
// state dirty for the next one in seven ways:
//   1. an event-log replay (/api/play-events) is still DRAINING on the
//      background event player when the test process exits — its queued
//      mouse-move events keep firing into the next test's freshly-reset mesh;
//   2. a tool was left active (a stray interactive session);
//   3. the undo stack carries the prior test's entries (command_history caps
//      at 50, which would pin any count-delta assertion).
//   4. selection/edit mode can leak when a reset is undone while draining
//      history.
//   5. THE POINTER. Every replayed motion/button event moves the override
//      cursor (eventlog.setOverrideMouse) and nothing ever moved it back, so
//      the position the previous test walked away from keeps being hover-picked
//      against the next test's freshly reset scene — a hovered vertex costs one
//      extra vertex-dot submission, a hovered gizmo part gets repainted in the
//      hover colour. Any test that reads draw counts or framebuffer pixels is
//      then wrong by exactly one hover, and ONLY when the slice happens to put
//      it after a test that parked the cursor somewhere interesting. Since the
//      LPT packing below is recomputed from a timing cache that every run
//      rewrites, that pairing is re-rolled every run — which is what made this
//      look like "a different test fails each time, and it passes on the rerun".
//      Closed by the scene.reset in step 3: its automation tail
//      (CommandHttpAdapter.resetAutomationAfter) calls eventlog.parkOverrideMouse.
//   6. THE SELECTION TYPE. Every viewport pick site gates on the front of the
//      selection-type ordering, not on the edit mode, and the two are not the
//      same reading: under the ITEM type `/api/selection` still reports mode
//      "vertices". A slice whose baseline is left with the item type current
//      hands the next binary a viewport in which nothing can be picked, while
//      reporting a pristine cube and an empty selection. Closed by the reset
//      itself (its promote hook) and by the `/api/select` in step 3b; the
//      verify below checks it so that a regression in either one is a named
//      failure rather than one silently dead test.
//   7. STEP TRACE CAPTURE. POST /api/trace/reset arms a process-wide capture
//      ring. Scene reset intentionally clears without disarming it because a
//      capture window can include a reset. Only the runner knows where one
//      test session ends, so it must disarm the ring before the next binary.
// AN EIGHTH was found by task 0674 and is deliberately NOT handled here, so
// that this list stays a list of things this function does: THE MODIFIER KEYS.
// Every replayed mouse event drove `SDL_SetModState` to the value the log
// recorded and nothing put it back, so a log that ended on a Ctrl left the app
// believing Ctrl was held for the rest of the process — and side-panel buttons
// draw their `ctrl:` variant while it is, which is a different label and a
// different action. It could not be closed from here anyway (there is no HTTP
// route that clears it), so it is closed at the only writer: `EventPlayer` now
// borrows the modifier state and hands it back when the log runs out. Named
// here because it belongs to exactly this family and cost a CI lane a day —
// red at -j 4, green at -j 8, on the same commit, because the packing below
// decides which test inherits the latch.
// A NINTH, THE HELD MOUSE BUTTONS (slice M1a): no key is dispatched while a
// mouse button is held, and a replayed press with no release leaves the button
// held — so EVERY key of every later test on this editor is silently dropped,
// and each one fails as "the key did nothing". Closed by the scene.reset in
// step 3: its automation tail (CommandHttpAdapter.resetAutomationAfter) clears
// the held set. NOT closed at the end of a replay, deliberately: tests split
// one held gesture across two play-events calls (press, then a key, then the
// release) and a replay-end clear would release the button they are holding.
//
// This is the documented cross-test state-bleed flake family (test_http_endpoint
// asserting the pristine startup cube, test_selection's "expected 2 got 0",
// etc.). Resetting at the RUNNER level — between every binary — kills the whole
// class at the source: each test now starts from a guaranteed-pristine cube,
// idle player, no active tool, empty undo stack. Tests that need a different
// baseline (empty mesh, a loaded LWO, a fixture, an empty-undo start) all
// establish it themselves at the top of their first unittest, so this reset is
// belt-and-suspenders for them and load-bearing for the state-asserting ones.
//
// Driven over HTTP with curl (already this runner's transport). The state
// VERIFY below stays best-effort — a scene that will not come clean is retried
// and then handed to the test's own preamble. What is NOT best-effort any more
// is the reset ITSELF answering: see `command` below.
//
// Task 4063: the two mutating calls here used to be `POST /api/reset` and
// `POST /api/select`, two wrapper routes over commands that are also reachable
// through `/api/command`. Those wrappers are gone, and this function is why
// their removal had to be checked here first: `curl` exits 0 on a 404, the
// helper returned the body unexamined, and so a runner posting to a route that
// no longer exists resets NOTHING while reporting nothing. Every one of the
// seven state-bleed channels above comes straight back, the eight-attempt retry
// budget is burned in full at every test transition, and the gate stays green
// throughout. The envelopes are inlined rather than taken from
// `tests/http_command_helpers.d` because this runner is a standalone `rdmd`
// script and does not compile the test tree.
//
// Returns false when the reset could not be DRIVEN at all (route gone, command
// id unregistered, command refused, server unreachable). The caller stops that
// worker's slice and reports it; a broken baseline makes every later result on
// that worker meaningless, which is exactly the reading this silence used to
// hide.
bool resetBetweenTests(ushort port, ref string failure) {
    import std.algorithm : min;
    string base = format("http://localhost:%d", port);
    string curl(string verb, string path, string data = "") {
        // -s silent, -m short timeout so a wedged server never stalls the run.
        string cmd = data.length
            ? format("curl -s -m 5 -X %s -d '%s' '%s%s'", verb, data, base, path)
            : format("curl -s -m 5 -X %s '%s%s'",          verb,       base, path);
        auto r = executeShell(cmd);
        return r.status == 0 ? r.output : "";
    }
    // Drive one REGISTERED command through the single generic endpoint and say
    // whether it applied. `/api/command` answers 200 `{"status":"ok"}` on
    // apply and 200 `{"status":"error","message":…}` on refusal; a route that
    // does not exist answers a 404 HTML page, and an unreachable server gives
    // us "" from `curl` above. All four are distinguished by the one test
    // below, and the last three are the ones that used to read as success.
    string lastBody;
    bool command(string id, string params = null) {
        immutable env = params.length
            ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
            : `{"id":"` ~ id ~ `"}`;
        lastBody = curl("POST", "/api/command", env);
        return lastBody.canFind(`"status":"ok"`);
    }
    // A scene reset cannot mark the test-session boundary: trace consumers
    // deliberately reset the scene inside an armed capture window. Disarm
    // explicitly before any reset commands can be recorded on stale state.
    lastBody = curl("POST", "/api/trace/disarm");
    if (!lastBody.canFind(`"status":"ok"`)) {
        failure = "trace disarm did not answer: " ~ (lastBody.length
            ? lastBody[0 .. min($, 300)] : "(no response from the server)");
        return false;
    }
    // Deactivate + drain-replay + reset + clear history, then VERIFY the cube
    // and selection/edit-mode baseline are actually pristine, retrying
    // the whole sequence a few times if not. A still-queued replay can briefly
    // report finished BETWEEN its events, so a single drain pass is not enough;
    // the verify-and-retry closes that window — a transient bleed clears on
    // re-reset while a genuine regression would persist (reset always restores
    // the cube), so this defends against the flake without masking real bugs.
    bool cubePristine() {
        // /api/model's v6 of the startup cube is (0.5, 0.5, 0.5).
        auto m = curl("GET", "/api/model");
        // Cheap structural check first: 8 verts. Then v6 ≈ (0.5,0.5,0.5).
        if (m.length == 0) return false;
        try {
            auto j = parseJSON(m);
            if (j["vertices"].array.length != 8) return false;
            auto v = j["vertices"].array[6].array;
            import std.math : fabs;
            return fabs(v[0].floating - 0.5) < 1e-4
                && fabs(v[1].floating - 0.5) < 1e-4
                && fabs(v[2].floating - 0.5) < 1e-4;
        } catch (Exception) { return false; }
    }
    bool selectionPristine() {
        auto s = curl("GET", "/api/selection");
        if (s.length == 0) return false;
        try {
            auto j = parseJSON(s);
            // Channel 6 of the list above: THE SELECTION TYPE. `mode` is the
            // derived GEOMETRY view, and it reads "vertices" even while the
            // ITEM type is current — deliberately, since that persistence is
            // what lets 1/2/3 restore the previous geometry mode. But the
            // viewport pick sites gate on the TYPE, not on `mode`, so a
            // baseline verified through `mode` alone accepts a state in which
            // the next test's clicks, hovers, bands and double-clicks all
            // decline in silence. Measured on a live instance: `/api/model`
            // reporting the pristine 8-vertex cube with v6 = (0.5, 0.5, 0.5),
            // `mode` "vertices", all three selection arrays empty — and
            // `selType` "item". Every field these two predicates read says
            // clean; the one that decides is not among them.
            //
            // This is not a new mechanism, it is this loop's existing one
            // pointed at the field that now decides: a false re-runs the reset
            // above, and `/api/reset` does clear the type. Two things already
            // clear it (the reset's promote hook and the `/api/select` on the
            // line above), so this is a tripwire rather than a repair — it is
            // here so that a future change to either of them surfaces as a
            // named failure instead of as one silently dead test per slice.
            //
            // Absent on older / bisected binaries: missing is fine, present
            // and wrong is not.
            if (auto t = "selType" in j)
                if (t.str != "vertex") return false;
            return j["mode"].str == "vertices"
                && j["selectedVertices"].array.length == 0
                && j["selectedEdges"].array.length == 0
                && j["selectedFaces"].array.length == 0;
        } catch (Exception) { return false; }
    }
    foreach (attempt; 0 .. 8) {
        // 1. Deactivate any tool the previous test left active (idempotent).
        curl("POST", "/api/command", "tool.set move off");
        // 2. Drain any in-flight event-log replay so its leftover mouse events
        //    cannot perturb the reset. /api/play-events/status reports
        //    {"finished":true} when idle (absent ⇒ never played ⇒ idle).
        foreach (_; 0 .. 200) {
            auto s = curl("GET", "/api/play-events/status");
            if (s.length == 0 || !s.canFind("\"finished\":false")) break;
            Thread.sleep(10.msecs);
        }
        // 2b. Settle. The event player reports "finished" once all its events
        //     have returned from the production input sink, before the later
        //     tool update/draw work in that frame. If we reset before those
        //     derived effects settle across the next 1–2 main-loop frames,
        //     late tool state (for example a drag's final mouse-up effects)
        //     can settle AFTER the reset, on the next test's freshly-reset mesh
        //     + active tool — exactly the test_property_panel_drag
        //     "got (-1,0,1)" bleed.
        //     A short settle lets the queue drain onto the OLD mesh first; the
        //     reset below then wipes whatever they did.
        Thread.sleep(120.msecs);
        // 3. Reset to the pristine startup cube.
        if (!command("scene.reset")) {
            failure = "scene.reset did not apply: " ~ (lastBody.length
                ? lastBody[0 .. min($, 300)] : "(no response from the server)");
            return false;
        }
        // 3b. Normalize the edit mode back to Vertices and keep all component
        //     selections empty. SceneReset already does this; the explicit
        //     select is a cheap guard for older/bisected app binaries.
        if (!command("mesh.select", `{"mode":"vertices","indices":[]}`)) {
            failure = "mesh.select did not apply: " ~ (lastBody.length
                ? lastBody[0 .. min($, 300)] : "(no response from the server)");
            return false;
        }
        // 4. Clear undo/redo without undoing the reset/select we just applied.
        //    Undo-draining here can restore the prior test's mesh/selection.
        curl("POST", "/api/command", "history.clear");
        if (cubePristine() && selectionPristine()) return true;
        Thread.sleep(20.msecs);
    }
    // The scene would not verify clean in eight attempts. The reset itself
    // ANSWERED every time (a refusal returns above), so this is a dirty-state
    // reading, not a broken harness: last reset stands and the test's own
    // preamble, if any, gets the final word — the pre-4063 behaviour.
    command("scene.reset");
    command("mesh.select", `{"mode":"vertices","indices":[]}`);
    curl("POST", "/api/command", "history.clear");
    return true;
}

TestResult[] runWorker(ref Worker w, bool verbose) {
    TestResult[] out_;
    foreach (b; w.bins) {
        // Re-baseline the shared instance before each test so a prior test's
        // leftover state (draining replay, active tool, undo entries, mutated
        // mesh) cannot bleed in. Kills the cross-test state-bleed flake family.
        //
        // A reset that cannot be DRIVEN stops this worker's slice and lands in
        // the summary as a red row. Continuing would run every remaining test
        // on this worker against whatever the previous one left behind, and
        // report the results as if the baseline had held — the failure mode
        // task 4063 found already shipped once (see resetBetweenTests).
        string resetFailure;
        if (!resetBetweenTests(w.port, resetFailure)) {
            synchronized {
                stderr.writeln(red(format(
                    "  worker %d: the between-test reset could not be driven — %s",
                    w.id, resetFailure)));
                stderr.writefln(red("  worker %d: abandoning its remaining %d "
                    ~ "test(s); every result after an un-driven baseline is "
                    ~ "cross-test bleed reported as a verdict."),
                    w.id, w.bins.length - out_.length);
                stderr.flush();
            }
            out_ ~= TestResult(format("runner:reset-between-tests[w%d]", w.id),
                               TestStatus.failed, resetFailure, 0);
            break;
        }
        auto r = runOne(b, verbose, w.port);
        synchronized {
            // The three markers are the FIRST field of the line on purpose:
            // .github/workflows/ci.yaml turns these lines into the job summary
            // table by matching /^\s*(PASS|FAIL|TIMEOUT)\s/ and taking the
            // test name from the field after [wN]. Change the shape here and
            // change it there, or a timed-out test silently leaves the table.
            writeln("  ", r.status == TestStatus.passed ? green("PASS")
                        : r.status == TestStatus.failed ? red("FAIL")
                        :                                 red("TIMEOUT"),
                    "  ", dim(format("[w%d]", w.id)), "  ", r.name,
                    r.status == TestStatus.timedOut
                        ? red(format("  (no exit after %.0fs — killed)", r.seconds))
                        : "");
            stdout.flush();
        }
        out_ ~= r;
    }
    return out_;
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

void printSummary(TestResult[] results) {
    int passed, failed, timedOut;
    foreach (ref r; results) final switch (r.status) {
        case TestStatus.passed:   passed++;   break;
        case TestStatus.failed:   failed++;   break;
        case TestStatus.timedOut: timedOut++; break;
    }

    g_harness.total    = cast(int) results.length;
    g_harness.passed   = passed;
    g_harness.failed   = failed;
    g_harness.timedOut = timedOut;

    writeln();
    writeln(dim("─────────────────────────────────────"));
    // Three DISJOINT counters that sum to Total: a timed-out test is counted
    // once, under "Timed out", and never also under "Failed".
    writefln("Total: %d  %s  %s  %s",
        results.length,
        green(format("Passed: %d", passed)),
        failed   == 0 ? dim("Failed: 0")    : red(format("Failed: %d", failed)),
        timedOut == 0 ? dim("Timed out: 0") : red(format("Timed out: %d", timedOut)));

    if (timedOut > 0) {
        writeln();
        writeln(bold("Timed out (killed — these HUNG, they did not fail an assertion):"));
        foreach (ref r; results) {
            if (r.status != TestStatus.timedOut) continue;
            writefln("  - %s %s", red(r.name),
                dim(format("— no exit after %.1fs; its process tree was SIGKILLed",
                    r.seconds)));
            auto lines = r.output.splitLines;
            if (lines.length) {
                writeln(dim("      last output before it stopped moving:"));
                foreach (line; lines.length > 5 ? lines[$ - 5 .. $] : lines)
                    writefln("      %s", line);
            } else {
                writeln(dim("      (it produced no output at all)"));
            }
        }
        writeln(dim(format("  A hang is not an assertion: re-run just this test "
                  ~ "with `-v`, and while it sits there, `gdb -p <pid>` "
                  ~ "(thread apply all bt) names the parked thread. Raise the "
                  ~ "cap with `--timeout N` if %ds is genuinely too short.",
                  cast(int) g_testTimeout.total!"seconds")));
    }

    if (failed > 0) {
        writeln();
        writeln(bold("Failed tests:"));
        foreach (ref r; results) {
            if (r.passed) continue;
            writeln("  - ", red(r.name));
            auto lines = r.output.splitLines;
            enum int budget = 8;
            foreach (i, line; lines) {
                if (i >= budget) {
                    writefln("      %s",
                        dim(format("… %d more line(s); rerun with -v for full output",
                            cast(int)(lines.length - budget))));
                    break;
                }
                writefln("      %s", line);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(string[] args) {
    bool verbose, noBuild, keep, staleOk, writeStampOnly, printScratch, printRunLock, checkGate;
    bool probeDisplay;
    bool probeRunLockUntilEof;
    bool printRunSlots;
    bool checkProtocol;
    // task 2080 — see the "Disk-space preflight" / "Scratch sweep" sections
    // above for what each of these drives.
    string checkSpacePath;
    long   spaceFloorMiB = -1;   // -1 = use kMinPreflightFreeBytes
    bool   sweepScratch;
    bool   sweepPlan;
    string[] sweepEntry, sweepLive;
    // 0 = not given. Resolved to the 8080 default right after getopt, so that
    // "the caller asked for a port" stays distinguishable from "the caller got
    // the default" — which is the whole discriminator of refuseDefaultBusyPort.
    ushort port = 0;
    int timeoutSec = -1;   // -1 = not given → per-mode default, resolved below
    // Machine-aware default worker count: scale with the host but stay sane.
    // Each worker boots its OWN vibe3d (a GL app), so we don't go 1:1 with
    // cores — clamp(totalCPUs/4, 4, 12). On a 32-core host that's 8; small
    // hosts still get 4; huge hosts cap at 12 so we don't spawn a swarm of
    // GL instances. An explicit `-j N` always overrides this default.
    int j = defaultJobs();
    int attach = 0;
    int runLockProbeSeconds = -1;
    string[] exclude;
    int lockTimeoutSec = 600;
    auto helpInfo = getopt(args,
        config.bundling,
        "v|verbose",  "stream test output instead of summarizing on failure", &verbose,
        "k|keep",     "leave vibe3d running after tests finish",              &keep,
        "no-build",   "skip `dub build`",                                     &noBuild,
        "stale-ok",   "with --no-build: run anyway when the binary does not "
                    ~ "match source/ (measures a DIFFERENT build — see the guard)", &staleOk,
        "write-stamp","record ./vibe3d as built from the current source/ and "
                    ~ "exit — for callers that ran `dub build` themselves (CI)", &writeStampOnly,
        "print-scratch","print the scratch directory this checkout would use "
                    ~ "and exit, creating nothing",                             &printScratch,
        "print-run-lock","print the run-slot family's base path (slot 0) "
                    ~ "and exit, creating nothing",                            &printRunLock,
        "print-run-slots","print the configured slot count, every slot this "
                    ~ "host's runs may take with held/free and its holder, "
                    ~ "and the whole family perf takes; exit",                &printRunSlots,
        "probe-worker-display","launch runner-owned ./vibe3d, read DISPLAY "
                    ~ "from its Linux /proc environment, print it and exit; "
                    ~ "test diagnostic, no build or host lock",                &probeDisplay,
        "probe-run-lock","diagnostic: acquire a real run slot, "
                    ~ "hold it for N seconds, then exit without building or "
                    ~ "running tests",                                         &runLockProbeSeconds,
        "probe-run-lock-until-eof","diagnostic: acquire a real run slot "
                    ~ "and hold it until stdin closes; test-only "
                    ~ "controlled-release companion to --probe-run-lock",     &probeRunLockUntilEof,
        "check-gate", "run the test-liveness barrier over a directory "
                    ~ "(default tests/) and exit 0/2, building nothing and "
                    ~ "starting no vibe3d",                                     &checkGate,
        "check-protocol", "run the prepared-tool protocol census alone (a "
                    ~ "source scan; no fixtures to compile since 4052) and "
                    ~ "exit 0/2, building nothing and starting no vibe3d",    &checkProtocol,
        "check-space","(task 2080) check free space at PATH against the "
                    ~ "preflight floor and exit 0/1, doing nothing else",       &checkSpacePath,
        "space-floor-mib", "override the space-preflight floor in MiB, for "
                    ~ "--check-space against a real constrained mount "
                    ~ "(default: 256)",                                        &spaceFloorMiB,
        "sweep-scratch", "(task 2080) delete this host's orphaned "
                    ~ "`vibe3d-tests-*` scratch trees under scratchRoot() -- "
                    ~ "positional args are the LIVE worktree roots (e.g. from "
                    ~ "`git worktree list`); a tree matching one is refused",   &sweepScratch,
        "sweep-plan", "(task 2080, diagnostic) print, one per line, which of "
                    ~ "the given --sweep-entry values --sweep-scratch would "
                    ~ "remove given --sweep-live -- pure, touches no "
                    ~ "filesystem", &sweepPlan,
        "sweep-entry","(task 2080, diagnostic) one simulated scratch-root entry "
                    ~ "for --sweep-plan (repeatable)",                         &sweepEntry,
        "sweep-live", "(task 2080, diagnostic) one simulated live worktree "
                    ~ "root for --sweep-plan (repeatable)",                    &sweepLive,
        "p|port",     "HTTP base port; workers take [p, p+j). Default: the "
                    ~ "held slot's own window (8080 + 36*slot). An explicit -p "
                    ~ "must not overlap another concurrent run's range",       &port,
        "j|jobs",     "parallel workers — each runs its own vibe3d on a "
                    ~ "private port (default = clamp(cpus/4, 4, 12))",        &j,
        "attach",     "drive an already-running endpoint on this port (e.g. "
                    ~ "tools/visual_test_proxy.py) instead of spawning vibe3d; "
                    ~ "forces -j1, leaves the endpoint running",              &attach,
        "exclude",    "skip a test by name (repeatable). Same name forms as "
                    ~ "the positional args: bevel | test_bevel | tests/test_bevel.d", &exclude,
        "lock-timeout", "seconds to wait for a free test/perf run slot before "
                    ~ "giving up with NO TESTS RAN (default 600). Lowered by "
                    ~ "tests/test_harness_load_log.d, which needs the give-up "
                    ~ "path to be reachable in a bounded time",              &lockTimeoutSec,
        "timeout",    "seconds one test may run before its process tree is "
                    ~ "killed and it is reported as TIMEOUT (default 600; "
                    ~ "0 = no cap; --attach defaults to no cap)",             &timeoutSec);

    const bool portGiven = (port != 0);
    if (!portGiven) port = slotPortBase(0);   // re-derived from the held slot below

    // --attach: target a pre-launched endpoint (visual proxy / external vibe3d).
    // Single worker on that one port; never kill or spawn an instance.
    if (attach != 0) {
        g_attachPort = cast(ushort)attach;
        port = cast(ushort)attach;
        j = 1;
    }

    // --attach drives an endpoint a HUMAN is driving (the visual proxy in front
    // of a visible vibe3d), where a test sitting still for ten minutes is the
    // point of the session and not a fault. Exempt it explicitly rather than
    // leaving it to whether 600 s happened to be enough: no cap unless the
    // caller asked for one by name.
    // Any negative value (including the "not given" sentinel) means "decide
    // for me"; 0 means the caller asked for no cap.
    if (timeoutSec < 0)
        timeoutSec = (g_attachPort != 0) ? 0 : kDefaultTestTimeoutSec;
    g_testTimeout = timeoutSec.seconds;

    if (helpInfo.helpWanted) {
        writeln("usage: ./run_test.d [options] [test_name...]");
        writeln();
        writeln("Test names accept any of: bevel | test_bevel | tests/test_bevel.d");
        writeln();
        foreach (o; helpInfo.options)
            writefln("  %-20s %s", o.optShort ~ ", " ~ o.optLong, o.help);
        return 0;
    }

    // Answer this BEFORE anything that needs a repository around us: it is the
    // one query a checkout can be asked from outside itself, and the mutation
    // test for task 1282 asks it from two different working directories.
    if (printScratch) {
        writeln(scratchDirFor(getcwd()));
        return 0;
    }

    // These diagnostics expose the SAME value and acquisition path as a real
    // run. They exist so the cross-process contract can be tested without
    // compiling the application or occupying a worker port.
    if (printRunLock) {
        writeln(runLockPath());
        return 0;
    }
    if (printRunSlots) {
        const count = configuredRunSlots();
        if (count.error.length) {
            stderr.writeln(red("invalid run-slot count: " ~ count.error));
            return 2;
        }
        writefln("slots %d (%s)", count.n, count.source);
        foreach (k; 0 .. count.n) {
            const p = runSlotPath(runSlotBase(), k);
            const held = slotHeld(p);
            writefln("slot %d %s %s%s", k, p, held ? "held" : "free",
                     held ? " " ~ slotStamp(p) : "");
        }
        foreach (p; runSlotFamily(runSlotBase())) writeln("family ", p);
        writeln("worktree ", worktreeLockPath(runSlotBase(), getcwd()));
        return 0;
    }
    if (probeDisplay)
        return probeWorkerDisplay(port);
    if (runLockProbeSeconds >= 0 || probeRunLockUntilEof) {
        if (!acquireRunLock(lockTimeoutSec)) return 1;
        scope(exit) releaseRunLock();
        writeln("RUN LOCK ACQUIRED: ", runSlotPath(runLockPath(), g_slotIndex));
        writefln("RUN SLOT: %d PORTS: %d..%d%s", g_slotIndex,
                 slotPortBase(g_slotIndex, runSlotBase()),
                 slotPortBase(g_slotIndex, runSlotBase()) + kSlotPortStride - 1,
                 runLockBorrowed ? " (borrowed)" : "");
        stdout.flush();
        if (probeRunLockUntilEof)
            stdin.readln();
        else
            Thread.sleep(runLockProbeSeconds.seconds);
        return 0;
    }

    // --check-gate: the barrier alone, over an arbitrary directory, with no
    // build and no vibe3d. This is what makes the barrier's RULES automatically
    // testable (tests/test_liveness_gate.d lays fixtures into a temp directory
    // and calls this) without standing up a copy of the repository. It must go
    // through the same gateViolations() the startup path below uses.
    if (checkGate) {
        const dir = (args.length > 1) ? args[1] : "tests";
        auto violations = gateViolations(dir);
        foreach (v; violations) stderr.writeln(red(v));
        if (violations.length) {
            stderr.writefln(red("--check-gate: %d violation(s) in %s"), violations.length, dir);
            return 2;
        }
        writefln("--check-gate: %s is clean", dir);
        return 0;
    }

    // --check-protocol: the protocol census ALONE -- the same protocolCensus()
    // the full run below calls, with nothing around it. Two jobs. It is how the
    // new call site is point-checked without standing up a suite (the scan is
    // ~38 s; the suite is minutes), and it is the hand-hold for a narrow run
    // that wants the census anyway. Like every meta invocation above it, it
    // returns BEFORE the load log is armed: it ran no tests, so it is not an
    // invocation the host-load report should see.
    if (checkProtocol)
        return protocolCensus() ? 0 : 2;

    // --check-space: the real filesystem/quota query against a real path,
    // with an overridable floor — the surface a constrained-mount witness
    // drives (see tests/unit/run_test_space_preflight_test.d). Not the
    // preflight gate itself (below); a standalone diagnostic.
    if (checkSpacePath.length) {
        const floor = spaceFloorMiB >= 0
            ? cast(ulong) spaceFloorMiB * 1024 * 1024
            : kMinPreflightFreeBytes;
        const space = spaceAvailability(checkSpacePath);
        if (auto msg = spacePreflightMessage(space, floor, checkSpacePath)) {
            stderr.writeln(red(msg));
            return 1;
        }
        if (auto msg = spaceEstimateWarning(space, j, checkSpacePath))
            stderr.writeln(yellow(msg));
        writefln("--check-space: %s has %s available (%s; floor %s) -- ok",
                 checkSpacePath, humanBytes(space.available),
                 availabilityDetails(space), humanBytes(floor));
        return 0;
    }

    // --sweep-plan: the orphan RULE alone, over caller-supplied strings, no
    // filesystem touched. This is what proves --sweep-scratch below refuses
    // a live worktree's tree, without needing a real /tmp scan to prove it.
    if (sweepPlan) {
        foreach (o; orphanScratchDirs(sweepEntry, sweepLive)) writeln(o);
        return 0;
    }

    // --sweep-scratch: the real thing, run by `task-wt-rm.sh` right after it
    // removes a lane's worktree pair. Positional args are the live roots.
    if (sweepScratch) {
        string[] liveRoots = args[1 .. $];
        const root = scratchRoot();
        string[] entries;
        try {
            foreach (e; dirEntries(root, SpanMode.shallow))
                if (e.isDir && baseName(e.name).startsWith(kScratchPrefix))
                    entries ~= e.name;
        } catch (Exception ex) {
            stderr.writeln(red("--sweep-scratch: could not list " ~ root ~ ": " ~ ex.msg));
            return 1;
        }
        auto orphans = orphanScratchDirs(entries, liveRoots);
        ulong freed;
        int removed;
        foreach (o; orphans) {
            const sz = treeSize(o);
            if (tryRemoveTree(o)) {
                removed++;
                freed += sz;
                writeln("  removed ", o, " (~", humanBytes(sz), ")");
            } else {
                stderr.writeln(yellow("  could not remove (busy?): " ~ o));
            }
        }
        writefln("--sweep-scratch: %d live root(s), %d orphaned tree(s) found, "
                ~ "%d removed, ~%s freed",
                liveRoots.length, orphans.length, removed, humanBytes(freed));
        return 0;
    }

    if (j < 1) {
        stderr.writeln(red("-j must be >= 1"));
        return 2;
    }

    // Arm the load log. Everything ABOVE this line is a meta invocation
    // (--print-scratch, --check-gate, --sweep-*, --help) that does no work by
    // design and would only dilute the record; everything BELOW is an attempt
    // to run tests, including the attempts that are refused.
    //
    // `scope(exit)` at FUNCTION scope, deliberately never under an `if`: a
    // scope guard nested in a conditional fires when that STATEMENT is left,
    // which is immediately -- the shape that left prefs.json unsaved for
    // months. Every `return` below therefore writes exactly one record.
    g_harness.startMs = nowUnixMs();
    g_harness.pid     = getpid();
    g_harness.host    = harnessHostName();
    g_harness.root    = getcwd();
    g_harness.branch  = gitOneLine("rev-parse --abbrev-ref HEAD");
    g_harness.sha     = gitOneLine("rev-parse --short HEAD");
    g_harness.mode    = args.length > 1 ? "narrow" : "full";
    g_harness.j       = j;
    g_harness.noBuild = noBuild;
    g_harnessArmed    = true;
    scope(exit) writeHarnessRecord();

    // Disk-space preflight (task 2080), MANDATORY on every real run — before
    // the build, before the run lock, before anything expensive. See the
    // "Disk-space preflight" section above for the incident this guards
    // against: this is the same scratchRoot() that `prepareScratchDir` and every
    // worker's `dmd` compile below write into.
    {
        const root = scratchRoot();
        const space = spaceAvailability(root);
        if (auto msg = spacePreflightMessage(space, kMinPreflightFreeBytes, root)) {
            stderr.writeln(red(msg));
            g_harness.stage = HarnessStage.spaceRefused;
            g_harness.rc = 1;
            return 1;
        }
    }

    keepVibe = keep;
    useColor = isatty(STDOUT_FILENO) != 0;

    signal(SIGINT,  &onSignal);
    signal(SIGTERM, &onSignal);
    scope(exit) cleanup();

    auto tests = resolveTests(args[1 .. $]);

    // --exclude removes any tests whose normalized path matches.
    if (!exclude.empty) {
        bool[string] excludeSet;
        foreach (e; exclude) excludeSet[normalize(e)] = true;
        string[] kept;
        foreach (t; tests) if (t !in excludeSet) kept ~= t;
        if (kept.length != tests.length) {
            writefln("excluding: %s", exclude.join(", "));
        }
        tests = kept;
    }

    g_harness.testsSelected = cast(int) tests.length;

    if (tests.empty) {
        writeln(yellow("no tests found"));
        g_harness.stage = HarnessStage.noTests;
        g_harness.rc = 0;
        return 0;
    }

    // Cap workers at # of tests so we don't spin up empty vibe3d instances.
    // The advisory follows this clamp and still precedes every census, build,
    // lock and worker scratch write, so it names the workers this run will
    // actually create while there is still time for the caller to intervene.
    if (j > cast(int)tests.length) j = cast(int)tests.length;
    {
        const root = scratchRoot();
        const space = spaceAvailability(root);
        if (auto msg = spaceEstimateWarning(space, j, root))
            stderr.writeln(yellow(msg));
    }

    // A caller that ran `dub build` itself (CI's own Build step) records the
    // stamp with this, so the --no-build guard below can tell that binary from
    // one a different build produced.
    if (writeStampOnly) {
        if (!exists("./vibe3d")) {
            stderr.writeln(red("--write-stamp: ./vibe3d does not exist"));
            return 1;
        }
        writeBuildStamp();
        writeln(green("build stamp written for the current source/"));
        return 0;
    }

    // One run per checkout, then one run slot, BEFORE the barriers, the build
    // and the default-port guard (task 6205): the build is part of the load a
    // slot accounts for, the refusal of a duplicate run of this worktree must
    // precede its `dub build`, and the default port is the held slot's window.
    if (!acquireWorktreeLock(getcwd())) {
        g_harness.stage = HarnessStage.worktreeBusy;
        g_harness.rc = 2;
        return 2;
    }
    // The canonical path ignores TMPDIR on purpose; a capacity-isolated run
    // may therefore wait or reach `lock_timeout` after 600 s (task 4870).
    if (!acquireRunLock(lockTimeoutSec)) {
        g_harness.stage = g_harness.lockTimedOut ? HarnessStage.lockTimeout
                                                 : HarnessStage.slotConfigInvalid;
        g_harness.rc = 1;
        return 1;
    }
    if (!portGiven && attach == 0) {
        port = slotPortBase(g_slotIndex, runSlotBase());
        if (j > kSlotPortStride) {
            stderr.writefln(red("refusing to run: -j %d exceeds this slot's "
                ~ "%d-port window (%d..%d); pass an explicit -p whose range "
                ~ "no other run on this host uses."), j, kSlotPortStride,
                port, port + kSlotPortStride - 1);
            g_harness.stage = HarnessStage.gateRefused;
            g_harness.rc = 2;
            return 2;
        }
    }
    writeln(dim(format("run slot %d%s; worker ports %d..%d", g_slotIndex,
                       runLockBorrowed ? " (borrowed from the caller)" : "",
                       port, port + j - 1)));

    // The default-port guard sits HERE, not up beside the option parsing, and
    // the position is the whole of task 6291's second lesson. Every mode above
    // this line — `--print-scratch`, `--print-run-lock`, `--check-gate`,
    // `--check-space`, `--sweep-scratch`, `--write-stamp` — is a QUERY: it
    // prints something and returns, binding no port and spawning nothing. The
    // guard's first placement was before all of them, so a query on a machine
    // whose default port happened to be busy was refused for a port it was
    // never going to use. That broke `tests/test_harness_load_log.d`, whose
    // constrained child asks for the scratch path with `--print-scratch` and
    // then asserts a DIFFERENT, specific refusal: my guard answered first and
    // the refusal under test was never reached — the "second, unnamed guard
    // refuses first" shape, committed by the person who had just written that
    // shape into a card. Caught by the nightly sanitizer lane, 2026-09-16,
    // `Total: 803 Passed: 802 Failed: 1`.
    //
    // `--probe-worker-display` is deliberately NOT exempt: it reaches
    // `startVibe` and really does take the port, so it belongs on this side of
    // the line even though it is a diagnostic.
    //
    // `busy` comes from portBusy, NOT from "we managed to read a cmdline": a
    // listener owned by another user gives an empty cmdline, and reading that
    // as "nothing is there" would drop the guard in exactly the case it can
    // say least about. Unreadable holder ⇒ busy, and not ours ⇒ refuse.
    const holder = portHolderCmdline(port);
    if (refuseDefaultBusyPort(portGiven, attach, portBusy(port),
                              holderCountsAsOurs(holder, port,
                                                 inForeignUserNamespace()))) {
        stderr.writefln(red("refusing to run: port %d is the DEFAULT and it is "
                          ~ "held by something that is not a stale test "
                          ~ "instance of ours."), port);
        stderr.writefln("  holder: %s", holder);
        stderr.writeln("This run would send its pkill at that process and then "
                     ~ "fail minutes later with\n\"failed to come up\", because "
                     ~ "the port never becomes free.");
        stderr.writeln("Pass this lane's own port (see ~/Code/wt/.lanes.tsv), "
                     ~ "e.g. --port 8570.\nIf you really mean this port, say "
                     ~ "so explicitly: --port " ~ port.to!string ~ ".");
        return 2;
    }

    // The barrier runs ONCE, before anything is built and before any worker
    // starts. A violation here means some test in this set would compile and
    // then report success without executing its scenarios, so measuring the run
    // at all would be measuring nothing.
    {
        auto violations = gateViolations("tests");
        if (violations.length) {
            stderr.writeln(red("test-liveness barrier: refusing to build this set."));
            foreach (v; violations) stderr.writeln(red("  " ~ v));
            g_harness.stage = HarnessStage.gateRefused;
            g_harness.rc = 2;
            return 2;
        }
    }

    // The prepared-tool protocol census -- the second barrier, and for the same
    // reason as the first: it answers a whole-tree question -- statement order
    // inside bodies, caller sets across files nothing imports, occurrence
    // counts -- and a run that cannot answer it is measuring a tree in which
    // any of that may have quietly drifted. It moved here out of dub.json's
    // `tests` configuration preBuildCommands, where every `dub test` that
    // rebuilt anything paid it; see protocolCensus() for the measurement, for
    // what task 4052 took out of it, and for why deleting the call is not an
    // option.
    //
    // A NARROW run (a test named on the command line) skips it and SAYS SO.
    // The census is a property of the tree, not of the named test, and a
    // ~20 s tax on `./run_test.d <name>` is a tax on the iteration loop that
    // people would answer by not using the runner. Both routine gates are FULL
    // runs -- `./run_test.d --no-build` with no names, and CI's
    // `run_all.d --only unit`, which passes `--exclude` and never a name -- so
    // both pay it exactly once. The skip is printed, never silent: a census
    // that can go quiet is the inert-gate class this project pays for most.
    if (args.length > 1) {
        writeln(yellow("prepared-protocol census: SKIPPED -- this is a narrow "
                     ~ "run. The full lane runs it; `./run_test.d "
                     ~ "--check-protocol` runs it alone."));
    } else if (!protocolCensus()) {
        stderr.writeln(red("prepared-protocol census: refusing to build this set."));
        g_harness.stage = HarnessStage.protocolRefused;
        g_harness.rc = 2;
        return 2;
    }

    if (!noBuild && !dubBuild()) {
        g_harness.stage = HarnessStage.buildFailed;
        g_harness.rc = 1;
        return 1;
    }

    // --no-build reuses ./vibe3d as-is, so the whole run is only meaningful if
    // that binary was built from the sources on disk NOW. Task 0678 shipped a
    // segfault whose pre-merge gate came back 598/598 green because the binary
    // predated the edit — the run measured the previous build. Refuse instead
    // of measuring the wrong artifact (the inert-measurement class).
    if (noBuild && g_attachPort == 0) {
        import std.file : timeLastModified;
        if (!exists("./vibe3d")) {
            stderr.writeln(red("--no-build: ./vibe3d does not exist — drop --no-build"));
            g_harness.stage = HarnessStage.noBinary;
            g_harness.rc = 1;
            return 1;
        }
        string why;
        if (!exists(kBuildStampPath)) {
            why = "no build stamp — ./vibe3d was not produced by this runner's `dub build`";
        } else if (timeLastModified("./vibe3d") > timeLastModified(kBuildStampPath)) {
            // Something rebuilt the binary without writing a stamp: the perf
            // lane (buildType=perf, PerfProbe on) and `--config=with-render`
            // both do exactly this, and both leave a binary that is NEWER than
            // every source file — invisible to any timestamp-vs-source rule.
            why = "./vibe3d is newer than the stamp — a different build "
                ~ "(perf / with-render / manual) overwrote it";
        } else if (readText(kBuildStampPath).strip != sourceDigest()) {
            why = "source content differs from what ./vibe3d was built from";
        }
        if (why.length) {
            stderr.writeln(red("--no-build refused: " ~ why));
            stderr.writeln(dim("    drop --no-build and let the runner build (simplest: no"));
            stderr.writeln(dim("    window opens between building and measuring), or run"));
            stderr.writeln(dim("    `dub build` with no edits after it."));
            stderr.writeln(dim("    --stale-ok exists for harness tests that must reach past"));
            stderr.writeln(dim("    this guard; it reports a full green Total: for a binary"));
            stderr.writeln(dim("    that does not contain your change."));
            if (!staleOk) {
                g_harness.stage = HarnessStage.staleRefused;
                g_harness.rc = 1;
                return 1;
            }
            stderr.writeln(yellow("--stale-ok given: proceeding against a binary that may not match"));
        }
    }

    // Pessimistic until printSummary has both populated the counters and
    // emitted the Total line. Worker preparation/link failures return before
    // that point; calling them `ran` made total=0 indistinguishable from a
    // verdict (task 4640).
    g_harness.stage = HarnessStage.runIncomplete;
    g_harness.rc = 1;

    // Per-CHECKOUT scratch tree; see scratchDirFor / prepareScratchDir above for
    // why it is keyed that way and what happens to a leftover one.
    scratchDir = prepareScratchDir(scratchDirFor(getcwd()));
    writeln(dim("scratch: " ~ scratchDir));

    // Build N workers and distribute tests by LONGEST-PROCESSING-TIME-FIRST:
    // sort tests by expected duration DESCENDING, then greedily assign each to
    // the currently least-loaded worker. This packs the long tests early and
    // backfills the short ones, so all workers finish at nearly the same time
    // instead of one worker dragging a long test at the very end. Expected
    // durations come from the smoothed timing cache (.test_timings.json);
    // unknown tests get the median of known timings (or a 2s constant when the
    // cache is empty / cold).
    auto timings   = loadTimings();
    double defaultEst = medianOf(timings.values, 2.0);

    Worker[] workers;
    workers.length = j;
    foreach (i, ref w; workers) {
        w.id      = cast(int)i;
        w.port    = cast(ushort)(port + i);
        w.scratch = buildPath(scratchDir, format("worker_%d", i));
    }

    // Sort a working copy of the test paths by descending estimate.
    auto ordered = tests.dup;
    ordered.sort!((a, b) =>
        estimateFor(a, timings, defaultEst) > estimateFor(b, timings, defaultEst));

    auto load = new double[j];   // expected accumulated load per worker
    load[] = 0;                  // double[].init is NaN in D — zero it first
    foreach (t; ordered) {
        size_t target = load[].minIndex;   // least-loaded worker
        workers[target].tests ~= t;
        load[target] += estimateFor(t, timings, defaultEst);
    }

    if (verbose && j > 1) {
        writeln(dim("LPT schedule (expected load per worker):"));
        foreach (i, ref w; workers)
            writefln(dim("  w%d: %5.1fs  (%d test%s)"),
                i, load[i], w.tests.length, w.tests.length == 1 ? "" : "s");
        writeln();
    }

    // Prepare workers in parallel — compile tests + boot vibe3d. Each
    // worker's compile/boot is independent.
    writefln("Compiling %d test%s and booting %d vibe3d instance%s...",
        tests.length, tests.length == 1 ? "" : "s",
        j, j == 1 ? "" : "s");
    // Say the cap out loud. A run that kills a test needs the reader to know
    // the cap existed; a run under --attach needs them to know it does not.
    writeln(dim(g_testTimeout > Duration.zero
        ? format("Per-test timeout: %ds (--timeout N to change, 0 to disable)",
                 g_testTimeout.total!"seconds")
        : "Per-test timeout: none"
          ~ (g_attachPort != 0 ? " (--attach: an externally driven endpoint is "
                                 ~ "expected to wait as long as its human does)"
                               : " (--timeout 0)")));
    // Source-backed tests: build the project once into a shared static lib and
    // link it (≈6× faster + ≈6× less RAM per test than recompiling via `dmd -i`,
    // and it unlocks mold). Done once here, single-threaded, before workers fan
    // out; the lib + flag are read-only thereafter. HTTP-driver tests are
    // unaffected. A source-backed run must build this library: the per-test
    // fallback costs about six times the peak RAM and cannot fit the CI VM.
    if (tests.canFind!isSourceBackedTest) {
        projLibPath = buildProjectLib(scratchDir);
        if (!projLibPath.length) {
            stderr.writeln(red("project test-lib build failed; refusing per-test -i fallback"));
            return 1;
        }
        moldFlag = probeMoldFlag();
        writeln(dim("Built project test-lib for source-backed tests"
            ~ (moldFlag.length ? " (linking with mold)." : ".")));
    }
    bool allUp = true;
    foreach (i, ref w; parallel(workers, 1)) {
        if (!prepareWorker(w)) {
            stderr.writefln(red("worker %d failed to prepare"), w.id);
            allUp = false;
        }
    }
    if (!allUp) return 1;
    writeln(green("  OK"));
    writeln();

    // Run each worker's slice in parallel (each on its own vibe3d).
    TestResult[][] perWorker;
    perWorker.length = workers.length;
    foreach (i, ref w; parallel(workers, 1)) {
        perWorker[i] = runWorker(w, verbose);
    }

    // Sort results by test name for deterministic summary output.
    TestResult[] results;
    foreach (slice; perWorker) results ~= slice;
    results.sort!((a, b) => a.name < b.name);

    // Fold this run's wall-clock durations into the smoothed timing cache so
    // the next run schedules better. Key by bare test name (drop ".out"/path).
    double[string] samples;
    foreach (ref r; results) {
        // A timed-out test contributes NO sample. Its duration is the cap, not
        // the test's cost, and folding it into the EMA would teach the
        // scheduler that a 0.3 s test costs ten minutes — and would drag the
        // median that unknown tests inherit up with it.
        if (r.status == TestStatus.timedOut) continue;
        auto name = baseName(r.name).stripExtension;
        if (r.seconds > 0 && !r.seconds.isNaN) samples[name] = r.seconds;
    }
    if (samples.length) saveTimings(timings, samples);

    printSummary(results);
    g_harness.stage = HarnessStage.ran;
    int failed = 0;
    foreach (ref r; results) if (!r.passed) failed++;

    // A worker's `vibe3d --test` that DIES mid-slice turns every remaining
    // test on that worker into an identical "Couldn't connect to server", and
    // the cause — the app's own stderr — sits in a scratch log this runner
    // deletes on exit. That is how a segfault on every tool drop reached main
    // and then read, in CI, as 537 interchangeable connection failures with no
    // stated reason (task 0678 D9-a follow-up). Name it here: report the dead
    // server FIRST, with the tail of its log, so the real failure is the thing
    // you see rather than something to be inferred from a wall of curl errors.
    //
    // A server that HANGS produces the identical wall of connect errors while
    // `tryWait` reports it perfectly alive — the "one silent peer wedges the
    // inline accept loop" class from task 0652. The dead-only report walked
    // past it and the log was deleted a second later, so the second arm below
    // probes the survivors and reports the ones that no longer answer
    // (task 0685 T5).
    if (failed > 0) {
        foreach (ref w; workers) {
            if (w.vibePid is null) continue;    // --attach: not ours to judge
            auto st = tryWait(w.vibePid);
            if (st.terminated) {
                // `tryWait` REAPED it: the pid number is now free for the
                // kernel to hand to an unrelated process of this user, and
                // `cleanup()` would SIGTERM/SIGKILL whatever holds it next.
                // Retire the slot (task 0685 T6).
                synchronized {
                    foreach (ref p; vibePids) if (p == w.vibePidNum) p = 0;
                }
                writeln();
                writefln("%s", red(format(
                    "worker %d: its vibe3d on :%d (pid %d) DIED during the run "
                    ~ "(status %d) — every test it had left could only fail to "
                    ~ "connect", w.id, w.port, w.vibePidNum, st.status)));
                reportVibeLogTail(w);
                writeln(dim(format("  a SIGSEGV leaves a coredump: "
                          ~ "`coredumpctl debug %d --debugger=gdb` names the line",
                          w.vibePidNum)));
                continue;
            }
            // Alive. Still answering? Two probes, 2 s each — the run is
            // already over, so anything slower than that stalled the tests too.
            if (httpProbe(w.port, 2, 2)) continue;
            writeln();
            writefln("%s", red(format(
                "worker %d: its vibe3d on :%d (pid %d) is ALIVE but no longer "
                ~ "answers /api/camera — it HUNG during the run, so every test "
                ~ "it had left could only fail to connect",
                w.id, w.port, w.vibePidNum)));
            reportVibeLogTail(w);
            writeln(dim(format("  a wedged server is attachable while it lives — "
                      ~ "re-run with `-k` and then `gdb -p %d` (thread apply "
                      ~ "all bt); `ss -tnp 'sport = :%d'` shows whether a "
                      ~ "peer's Recv-Q is stuck", w.vibePidNum, w.port)));
        }
    }

    int rc = failed == 0 ? 0 : 1;

    g_harness.rc = rc;
    return rc;
}
