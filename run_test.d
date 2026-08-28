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
 *   ./run_test.d --print-scratch     # name this checkout's scratch tree, exit
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
import std.array     : array, appender, replace, join;
import std.conv      : to, octal;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.json      : JSONValue, parseJSON, JSONType;
import std.math      : isNaN;
// Import std.file fully so the per-worker scratch source-write can call
// `std.file.write` without colliding with the `write` from std.stdio.
static import std.file;
import std.file : exists, isFile, isDir, mkdirRecurse, rmdirRecurse,
                  dirEntries, SpanMode, tempDir, readText, getcwd;
import std.format    : format;
import std.getopt    : getopt, config;
import std.parallelism : parallel, totalCPUs;
import std.path      : baseName, buildPath, stripExtension, dirName;
import std.process   : spawnProcess, spawnShell, wait, tryWait, executeShell,
                       Config, Pid, ProcessException, environment;
import std.range     : empty;
import std.stdio     : writeln, writefln, write, stdin, stdout, stderr, File;
import std.string    : startsWith, endsWith, indexOf, splitLines, strip;

import core.thread        : Thread;
import core.time          : msecs, seconds, dur, Duration;
import core.stdc.stdlib   : exit;
import core.sys.posix.signal : signal, kill, SIGINT, SIGTERM, SIGKILL;
import core.sys.posix.unistd : isatty, STDOUT_FILENO, close, getpid, ftruncate,
                               setpgid, getpgrp;
import core.sys.posix.fcntl  : open, O_RDWR, O_CREAT;
import core.sys.posix.sys.types : ssize_t;

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
__gshared string projLibPath;  // prebuilt project test-lib (see buildProjectLib); "" => -i fallback
__gshared Duration g_testTimeout;   // per-test wall-clock cap; zero = no cap
__gshared int[]  testGroupPids;     // process-group leader pid of each RUNNING
                                    // test (0 = retired slot). A test that is
                                    // still running when we are interrupted is
                                    // in its own process group (see runOne), so
                                    // it no longer gets the terminal's SIGINT —
                                    // the handler below has to deliver it.
__gshared string moldFlag;     // " -L-fuse-ld=mold" for the lib link path; "" when mold unusable

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

    return buildPath(tempDir(), kScratchPrefix ~ slug ~ "-" ~ hash);
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
    const dir  = tempDir();
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
// `compileTests` below) — under `tempDir()`, which on the affected host is a
// 32 GiB tmpfs, i.e. RAM. SIX unrelated fixture tests failed identically in
// the same run, which reads as a code regression and is one exhausted
// filesystem. This check does not move the scratch root or make lanes clean
// up after themselves (see `orphanScratchDirs` / `--sweep-scratch` below for
// the second half) — it removes the DISGUISE: a run that starts against an
// exhausted filesystem says so, once, with the word "space" in it, before a
// single test compiles, instead of failing 40 minutes in as red tests.
//
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
enum ulong kMinPreflightFreeBytes = 256UL * 1024 * 1024;

/// Free bytes on the filesystem containing `path`. `path` need not exist —
/// this climbs to the nearest existing ancestor first, so it works against a
/// cold checkout's not-yet-created scratch dir. Returns `ulong.max` (never
/// blocks a run) when the query itself cannot be answered — a permission
/// error or a path with no existing ancestor is a different problem, and one
/// this check is not the place to raise.
ulong freeBytes(string path) {
    import core.sys.posix.sys.statvfs : statvfs, statvfs_t;
    import std.string : toStringz;

    string p = path;
    while (p.length && !exists(p)) {
        const parent = dirName(p);
        if (parent == p) break;
        p = parent;
    }
    if (!p.length || !exists(p)) return ulong.max;

    statvfs_t st;
    if (statvfs(p.toStringz, &st) != 0) return ulong.max;
    return cast(ulong) st.f_bavail * cast(ulong) st.f_frsize;
}

string humanBytes(ulong b) {
    enum double Ki = 1024.0, Mi = Ki * 1024, Gi = Mi * 1024;
    if (b == ulong.max)   return "unknown";
    if (b >= cast(ulong)Gi) return format("%.1f GiB", b / Gi);
    if (b >= cast(ulong)Mi) return format("%.1f MiB", b / Mi);
    if (b >= cast(ulong)Ki) return format("%.1f KiB", b / Ki);
    return format("%d B", b);
}

/// The whole decision, as one pure function: `null` means "proceed", a
/// non-null string is the refusal message and always contains the word
/// "space" (the witness this check exists to satisfy — a preflight that only
/// prints free space is green when there is none). `free == ulong.max` (the
/// query could not be answered) never refuses: this check must not turn an
/// unrelated errno into a false "no space" report.
string spacePreflightMessage(ulong free, ulong floor, string path) {
    if (free == ulong.max || free >= floor) return null;
    return format(
        "no space left: %s has %s free, below the %s floor -- refusing to "
        ~ "start rather than fail mid-run and disguise it as red tests "
        ~ "(task 2080)", path, humanBytes(free), humanBytes(floor));
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
// Cross-process run lock
// ---------------------------------------------------------------------------
//
// Two test runs MUST NOT overlap on one host: the runner boots `vibe3d --test`
// on ports `port + worker` and `killStaleVibe` clears stale instances by port —
// two concurrent runs (e.g. two agents) fight over the same ports and mutually
// kill each other's vibe3d, producing "No such file" / "Could not connect"
// flakes. A host-wide advisory flock serialises runs: the second runner blocks
// (printing a notice) until the first releases, or times out and bails without
// stomping.
//
// The scratch tree is NOT among the reasons any more — it is keyed per checkout
// above, and a lock could never have covered it anyway: the tree outlives the
// run that made it whenever that run is killed, and a lock held by nobody
// protects nothing.
//
// The lock is on a fixed file in tempDir so it is shared across worktrees /
// checkouts. flock is released automatically when the fd closes (process exit),
// so a crashed runner never leaks the lock.
string runLockPath() { return buildPath(tempDir(), "vibe3d-run-test.lock"); }

// Acquire the host-wide run lock, waiting up to `timeoutSec` for any other
// runner to finish. Returns true on success; false if the wait timed out.
bool acquireRunLock(int timeoutSec) {
    import std.string : toStringz;
    runLockFd = open(runLockPath().toStringz, O_RDWR | O_CREAT, octal!"644");
    if (runLockFd < 0) {
        // Can't create the lockfile — degrade to no-lock rather than block CI.
        stderr.writeln(yellow("warning: could not open run lock; "
            ~ "running without cross-run serialisation"));
        return true;
    }
    // Fast path: grab it immediately if free.
    if (flock(runLockFd, LOCK_EX | LOCK_NB) == 0) return recordLockHolder();

    writeln(yellow("another test run is in progress on this host — waiting "
        ~ "(another agent may be running ./run_test.d)..."));
    int waited = 0;
    while (waited < timeoutSec) {
        Thread.sleep(1.seconds);
        waited += 1;
        if (flock(runLockFd, LOCK_EX | LOCK_NB) == 0) {
            writeln(green(format("  acquired run lock after %ds", waited)));
            return recordLockHolder();
        }
        if (waited % 15 == 0)
            writefln(yellow("  still waiting for the other run (%ds)..."), waited);
    }
    // NOT a test failure — nothing ran. Say so first and loudly: this exits
    // non-zero exactly like a red suite, and telling the two apart used to
    // take reading the FIRST line of a long log (task 0685 / the 2026-08-13
    // parallel-agent session, where it was mistaken for a regression).
    stderr.writeln(red(format(
        "NO TESTS RAN — timed out after %ds waiting for another test run on "
        ~ "this host. This is a host-contention exit, not a failing suite.",
        timeoutSec)));
    stderr.writeln(dim(
        "    Several agents/worktrees share one machine and one lock. While\n"
        ~ "    iterating, run NARROW tests instead: `./run_test.d <name> ...`\n"
        ~ "    (plus `dub test --config=tests`, which takes no lock). Save\n"
        ~ "    the full suite for the merge step."));
    stderr.writeln(dim(format("    Lock: %s (holder's pid is inside it)",
                              runLockPath())));
    close(runLockFd);
    runLockFd = -1;
    return false;
}

// Stamp our PID into the lockfile for diagnostics ("who holds it?").
bool recordLockHolder() {
    import std.string : toStringz;
    ftruncate(runLockFd, 0);
    string stamp = format("pid %d\n", getpid());
    c_write(runLockFd, stamp.ptr, stamp.length);
    return true;
}

void releaseRunLock() {
    if (runLockFd >= 0) {
        flock(runLockFd, LOCK_UN);
        close(runLockFd);
        runLockFd = -1;
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
//   dmd -unittest run_test.d -of=/tmp/run_test_ut && /tmp/run_test_ut
// (a single-file compile — this module has no project-local imports, so no
// `-i`/import-path juggling is needed). Compiling WITHOUT `-unittest`, which
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
    string portCheck = format("ss -ltn 'sport = :%d' | tail -n +2 | grep -q .", port);
    for (int i = 0; i < 50; ++i) {
        auto r = executeShell(portCheck);
        if (r.status != 0) return;  // port free
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
        foreach (e; dirEntries("source", "*.d", SpanMode.depth))
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
// resolve against the deps. The `-i` fallback path just concatenates the two.
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
string sourceTestFlags()    { harvestSourceFlags(); return g_compileFlags ~ g_linkTail; }

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
        "buttonset", "ai3d.", "document", "commands.ai3d.",
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
/// failure (callers fall back to the -i compile). Built with -unittest to match
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
        stderr.writeln(yellow("project test-lib build failed; "
            ~ "falling back to per-test -i compile"));
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

/// Compile each test in `paths` into `outDir`. Source is read AS-IS unless
/// `port` differs from 8080 — then literal "localhost:8080" is rewritten
/// to "localhost:<port>" in a per-test scratch copy. This keeps tests
/// portable to N parallel vibe3d instances without source changes.
string[] compileTests(string[] paths, string outDir, ushort port) {
    string[] bins;
    foreach (p; paths) {
        string name = baseName(p).stripExtension;
        string of   = buildPath(outDir, name);
        string src  = p;
        if (port != 8080) {
            string txt = readText(p)
                .replace("localhost:8080", "localhost:" ~ port.to!string);
            src = buildPath(outDir, name ~ ".d");
            std.file.write(src, txt);
        }
        // Pull every injected module (see injectedTestModules) into the
        // compilation so a test can `import drag_helpers;` — or
        // `import liveness_gate : scenario;` — without duplicating shared
        // code. They also get their literal "localhost:8080" rewritten to the
        // per-worker port: without this, parallel workers' tests all hit port
        // 8080 through the helpers, corrupting each other's vibe3d state.
        string helpers;
        foreach (m; injectedTestModules()) {
            string hSrc = m;
            if (port != 8080) {
                string hTxt = readText(m)
                    .replace("localhost:8080", "localhost:" ~ port.to!string);
                hSrc = buildPath(outDir, baseName(m));
                std.file.write(hSrc, hTxt);
            }
            helpers ~= " " ~ hSrc;
        }
        // -I=<outDir> first so the rewritten helpers in the scratch dir
        // win over the unmodified originals in tests/. -J=tests lets a
        // test embed a golden fixture via `import("fixtures/<name>.json")`
        // (see tests/fixture_helpers.d) — the path is resolved against the
        // repo's tests/ dir regardless of the per-worker scratch copy.
        //
        // Source-backed tests (those importing project modules like
        // tools.xform_kernels / mesh / math) need the full dependency graph:
        // dmd's `-i` auto-includes the imported project source, and the
        // harvested `dub describe` flags supply the dep import paths + the
        // native link inputs (OpenSubdiv C libs, bindbc archives, …). We drop
        // `-w` for these because the third-party dep code carries warnings
        // that aren't ours to fix; the test's own warnings still surface via
        // the bare-path tests. HTTP-driver tests keep the original cheap line.
        string cmd;
        if (isSourceBackedTest(p)) {
            if (projLibPath.length) {
                // Link the prebuilt project lib instead of recompiling it via
                // `-i`. Order is load-bearing: test.o, then the project lib,
                // then the dep archives/link tail (mold is order-strict).
                cmd = format("dmd -unittest -J=tests -I=%s -I=tests%s%s %s %s%s%s -of=%s 2>&1",
                             outDir, helpers, sourceCompileFlags(), src,
                             projLibPath, sourceLinkTail(), moldFlag, of);
            } else {
                cmd = format("dmd -unittest -i -J=tests -I=%s -I=tests%s%s %s -of=%s 2>&1",
                             outDir, helpers, sourceTestFlags(), src, of);
            }
        } else {
            cmd = format("dmd -unittest -J=tests -I=%s -I=tests%s %s -w -of=%s 2>&1",
                         outDir, helpers, src, of);
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
// vibe3d lifecycle
// ---------------------------------------------------------------------------

Pid startVibe(ushort port, string logPath) {
    auto logFile = File(logPath, "wb");
    string[] argv = ["./vibe3d", "--test", "--http-port", port.to!string];
    Pid pid;
    try {
        pid = spawnProcess(argv, stdin, logFile, logFile,
            null, Config.suppressConsole);
    } catch (ProcessException e) {
        stderr.writeln(red("failed to spawn vibe3d: "), e.msg);
        return null;
    }
    synchronized {
        vibePids ~= pid.processID;
    }
    return pid;
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
    stderr.writefln(red("  :%d listened but never answered 200 (last status: %s). "
                        ~ "500 = still wiring providers, so startup outran the "
                        ~ "probe budget; 000 = connected but no reply, i.e. wedged."),
                    port, lastStatus);
    return false;
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
// tell apart from a real one: 500 means "still starting", 000 means the
// connection never completed, and those want opposite investigations.
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

TestResult runOne(string bin, bool verbose) {
    TestResult r;
    r.name = baseName(bin);
    auto sw = StopWatch(AutoStart.yes);

    Config cfg;
    cfg.preExecFunction = &ownProcessGroup;

    string outPath = bin ~ ".out";
    File   out_;
    Pid    pid;
    if (verbose) {
        pid = spawnProcess([bin], stdin, stdout, stderr, null, cfg);
    } else {
        out_ = File(outPath, "wb");
        pid  = spawnProcess([bin], stdin, out_, out_, null, cfg);
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
    w.bins = compileTests(w.tests, w.scratch, w.port);
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
// state dirty for the next one in five ways:
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
//      Closed inside /api/reset (step 3): see eventlog.parkOverrideMouse.
//   6. THE SELECTION TYPE. Every viewport pick site gates on the front of the
//      selection-type ordering, not on the edit mode, and the two are not the
//      same reading: under the ITEM type `/api/selection` still reports mode
//      "vertices". A slice whose baseline is left with the item type current
//      hands the next binary a viewport in which nothing can be picked, while
//      reporting a pristine cube and an empty selection. Closed by the reset
//      itself (its promote hook) and by the `/api/select` in step 3b; the
//      verify below checks it so that a regression in either one is a named
//      failure rather than one silently dead test.
// A SEVENTH was found by task 0674 and is deliberately NOT handled here, so
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
// Driven over HTTP with curl (already this runner's transport). Best-effort:
// any failure here is non-fatal (the per-test reset, if present, still runs).
void resetBetweenTests(ushort port) {
    string base = format("http://localhost:%d", port);
    string curl(string verb, string path, string data = "") {
        // -s silent, -m short timeout so a wedged server never stalls the run.
        string cmd = data.length
            ? format("curl -s -m 5 -X %s -d '%s' '%s%s'", verb, data, base, path)
            : format("curl -s -m 5 -X %s '%s%s'",          verb,       base, path);
        auto r = executeShell(cmd);
        return r.status == 0 ? r.output : "";
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
        //     are DISPATCHED, but /api/play-events pushes them onto the SDL
        //     queue (g_directDispatch is null) — the LAST few are still in the
        //     queue, unprocessed, when the player goes idle. They drain on the
        //     next 1–2 main-loop frames. If we reset before they drain, those
        //     queued mouse events (e.g. a drag's final mouse-up) fire AFTER the
        //     reset, landing on the next test's freshly-reset mesh + active
        //     tool — exactly the test_property_panel_drag "got (-1,0,1)" bleed.
        //     A short settle lets the queue drain onto the OLD mesh first; the
        //     reset below then wipes whatever they did.
        Thread.sleep(120.msecs);
        // 3. Reset to the pristine startup cube.
        curl("POST", "/api/reset");
        // 3b. Normalize the edit mode back to Vertices and keep all component
        //     selections empty. SceneReset already does this; the explicit
        //     select is a cheap guard for older/bisected app binaries.
        curl("POST", "/api/select", `{"mode":"vertices","indices":[]}`);
        // 4. Clear undo/redo without undoing the reset/select we just applied.
        //    Undo-draining here can restore the prior test's mesh/selection.
        curl("POST", "/api/command", "history.clear");
        if (cubePristine() && selectionPristine()) return;
        Thread.sleep(20.msecs);
    }
    // Last reset stands; the test's own preamble (if any) gets the final word.
    curl("POST", "/api/reset");
    curl("POST", "/api/select", `{"mode":"vertices","indices":[]}`);
    curl("POST", "/api/command", "history.clear");
}

TestResult[] runWorker(ref Worker w, bool verbose) {
    TestResult[] out_;
    foreach (b; w.bins) {
        // Re-baseline the shared instance before each test so a prior test's
        // leftover state (draining replay, active tool, undo entries, mutated
        // mesh) cannot bleed in. Kills the cross-test state-bleed flake family.
        resetBetweenTests(w.port);
        auto r = runOne(b, verbose);
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
    bool verbose, noBuild, keep, staleOk, writeStampOnly, printScratch, checkGate;
    // task 2080 — see the "Disk-space preflight" / "Scratch sweep" sections
    // above for what each of these drives.
    string checkSpacePath;
    long   spaceFloorMiB = -1;   // -1 = use kMinPreflightFreeBytes
    bool   sweepScratch;
    bool   sweepPlan;
    string[] sweepEntry, sweepLive;
    ushort port = 8080;
    int timeoutSec = -1;   // -1 = not given → per-mode default, resolved below
    // Machine-aware default worker count: scale with the host but stay sane.
    // Each worker boots its OWN vibe3d (a GL app), so we don't go 1:1 with
    // cores — clamp(totalCPUs/4, 4, 12). On a 32-core host that's 8; small
    // hosts still get 4; huge hosts cap at 12 so we don't spawn a swarm of
    // GL instances. An explicit `-j N` always overrides this default.
    int j = defaultJobs();
    int attach = 0;
    string[] exclude;
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
        "check-gate", "run the test-liveness barrier over a directory "
                    ~ "(default tests/) and exit 0/2, building nothing and "
                    ~ "starting no vibe3d",                                     &checkGate,
        "check-space","(task 2080) check free space at PATH against the "
                    ~ "preflight floor and exit 0/1, doing nothing else",       &checkSpacePath,
        "space-floor-mib", "override the space-preflight floor in MiB, for "
                    ~ "--check-space against a real constrained mount "
                    ~ "(default: 256)",                                        &spaceFloorMiB,
        "sweep-scratch", "(task 2080) delete this host's orphaned "
                    ~ "`vibe3d-tests-*` scratch trees under tempDir() -- "
                    ~ "positional args are the LIVE worktree roots (e.g. from "
                    ~ "`git worktree list`); a tree matching one is refused",   &sweepScratch,
        "sweep-plan", "(task 2080, diagnostic) print, one per line, which of "
                    ~ "the given --sweep-entry values --sweep-scratch would "
                    ~ "remove given --sweep-live -- pure, touches no "
                    ~ "filesystem", &sweepPlan,
        "sweep-entry","(task 2080, diagnostic) one simulated tempDir() entry "
                    ~ "for --sweep-plan (repeatable)",                         &sweepEntry,
        "sweep-live", "(task 2080, diagnostic) one simulated live worktree "
                    ~ "root for --sweep-plan (repeatable)",                    &sweepLive,
        "p|port",     "HTTP port for vibe3d (default 8080)",                  &port,
        "j|jobs",     "parallel workers — each runs its own vibe3d on a "
                    ~ "private port (default = clamp(cpus/4, 4, 12))",        &j,
        "attach",     "drive an already-running endpoint on this port (e.g. "
                    ~ "tools/visual_test_proxy.py) instead of spawning vibe3d; "
                    ~ "forces -j1, leaves the endpoint running",              &attach,
        "exclude",    "skip a test by name (repeatable). Same name forms as "
                    ~ "the positional args: bevel | test_bevel | tests/test_bevel.d", &exclude,
        "timeout",    "seconds one test may run before its process tree is "
                    ~ "killed and it is reported as TIMEOUT (default 600; "
                    ~ "0 = no cap; --attach defaults to no cap)",             &timeoutSec);

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

    // --check-space: the real freeBytes()/statvfs query against a real path,
    // with an overridable floor — the surface a constrained-mount witness
    // drives (see tests/unit/run_test_space_preflight_test.d). Not the
    // preflight gate itself (below); a standalone diagnostic.
    if (checkSpacePath.length) {
        const floor = spaceFloorMiB >= 0
            ? cast(ulong) spaceFloorMiB * 1024 * 1024
            : kMinPreflightFreeBytes;
        const free = freeBytes(checkSpacePath);
        if (auto msg = spacePreflightMessage(free, floor, checkSpacePath)) {
            stderr.writeln(red(msg));
            return 1;
        }
        writefln("--check-space: %s has %s free (floor %s) -- ok",
                 checkSpacePath, humanBytes(free), humanBytes(floor));
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
        const root = tempDir();
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

    // Disk-space preflight (task 2080), MANDATORY on every real run — before
    // the build, before the run lock, before anything expensive. See the
    // "Disk-space preflight" section above for the incident this guards
    // against: this is the same tempDir() that `prepareScratchDir` and every
    // worker's `dmd` compile below write into.
    {
        const root = tempDir();
        if (auto msg = spacePreflightMessage(freeBytes(root), kMinPreflightFreeBytes, root)) {
            stderr.writeln(red(msg));
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

    if (tests.empty) {
        writeln(yellow("no tests found"));
        return 0;
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

    // The barrier runs ONCE, before anything is built and before any worker
    // starts. A violation here means some test in this set would compile and
    // then report success without executing its scenarios, so measuring the run
    // at all would be measuring nothing.
    {
        auto violations = gateViolations("tests");
        if (violations.length) {
            stderr.writeln(red("test-liveness barrier: refusing to build this set."));
            foreach (v; violations) stderr.writeln(red("  " ~ v));
            return 2;
        }
    }

    if (!noBuild && !dubBuild()) return 1;

    // --no-build reuses ./vibe3d as-is, so the whole run is only meaningful if
    // that binary was built from the sources on disk NOW. Task 0678 shipped a
    // segfault whose pre-merge gate came back 598/598 green because the binary
    // predated the edit — the run measured the previous build. Refuse instead
    // of measuring the wrong artifact (the inert-measurement class).
    if (noBuild && g_attachPort == 0) {
        import std.file : timeLastModified;
        if (!exists("./vibe3d")) {
            stderr.writeln(red("--no-build: ./vibe3d does not exist — drop --no-build"));
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
            stderr.writeln(dim("    rebuild (`dub build`), or pass --stale-ok to measure it anyway"));
            if (!staleOk) return 1;
            stderr.writeln(yellow("--stale-ok given: proceeding against a binary that may not match"));
        }
    }

    // Serialise with any other runner on this host BEFORE we touch ports /
    // scratch / vibe3d — concurrent runs mutually kill each other's instances
    // (killStaleVibe by port) and share the scratch dir, causing spurious
    // "Could not connect" / "No such file" failures. Wait up to 10 min.
    if (!acquireRunLock(600)) return 1;

    // Per-CHECKOUT scratch tree; see scratchDirFor / prepareScratchDir above for
    // why it is keyed that way and what happens to a leftover one.
    scratchDir = prepareScratchDir(scratchDirFor(getcwd()));
    writeln(dim("scratch: " ~ scratchDir));

    // Cap workers at # of tests so we don't spin up empty vibe3d instances.
    if (j > cast(int)tests.length) j = cast(int)tests.length;

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
    // unaffected. On lib-build failure projLibPath stays "" and we fall back.
    if (tests.canFind!isSourceBackedTest) {
        projLibPath = buildProjectLib(scratchDir);
        if (projLibPath.length) {
            moldFlag = probeMoldFlag();
            writeln(dim("Built project test-lib for source-backed tests"
                ~ (moldFlag.length ? " (linking with mold)." : ".")));
        }
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

    return rc;
}
