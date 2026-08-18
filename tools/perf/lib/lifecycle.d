module lib.lifecycle;
// vibe3d process lifecycle: build, launch, health-probe, teardown, and the
// SIGINT/SIGTERM handler that guarantees a spawned vibe3d doesn't outlive
// an interrupted harness run.
//
// Extracted from tools/perf/run.d as part of task 0197 (perf tooling
// consolidation) — pure code-motion, no behavior change.

import std.conv    : to;
import std.format  : format;
import std.path    : buildPath;
import std.process : execute, executeShell, spawnProcess, Config, Pid,
                     ProcessException;
import std.stdio   : write, writeln, writefln, stdout, stderr, File, stdin;
import std.string  : strip, join;

import core.thread : Thread;
import core.time   : msecs;
import core.stdc.stdlib : exit;
import core.sys.posix.signal : signal, SIGINT, SIGTERM, kill;

// ---------------------------------------------------------------------------
// Lifecycle state (accessed by signal handler)
// ---------------------------------------------------------------------------

__gshared int  g_vibePid;
__gshared bool g_keep;

extern(C) void onSignal(int sig) nothrow @nogc @system {
    if (g_vibePid != 0) kill(g_vibePid, SIGTERM);
    import core.stdc.stdio : fputs, stderr;
    fputs("\ninterrupted\n", stderr);
    exit(130);
}

void teardown() {
    if (g_keep || g_vibePid == 0) return;
    try { kill(g_vibePid, SIGTERM); } catch (Exception) {}
    for (int i = 0; i < 20; ++i) {
        Thread.sleep(50.msecs);
        if (kill(g_vibePid, 0) != 0) { g_vibePid = 0; return; }
    }
    try { kill(g_vibePid, /*SIGKILL*/ 9); } catch (Exception) {}
    g_vibePid = 0;
}

// ---------------------------------------------------------------------------
// Build & launch
// ---------------------------------------------------------------------------

enum LDC2 = "/home/ashagarov/.local/dlang/ldc2-1.42.0-linux-x86_64/bin/ldc2";

string g_repoRoot;

bool dubBuildPerf() {
    write("Building vibe3d (perf buildType, ldc2 1.42)... ");
    stdout.flush();
    auto r = execute(["dub", "build", "--build=perf",
                      "--compiler=" ~ LDC2, "--root", g_repoRoot]);
    if (r.status != 0) {
        writeln("FAIL");
        writeln(r.output);
        return false;
    }
    writeln("OK");
    return true;
}

/// Every vibe3d PID whose command line names THIS port.
///
/// Two guards keep the selection honest:
///   * `pgrep -f` matches command LINES, so it also hits this runner's own
///     process and any editor/shell that happens to mention the port. Every
///     candidate is therefore confirmed by its EXECUTABLE (`/proc/PID/exe`
///     resolving to a file named `vibe3d`). Matching a pattern is not the
///     same as identifying a process.
///   * pgrep's regex is unanchored, so `--http-port 845` would match
///     `--http-port 8450`; the trailing boundary is spelled out as
///     `[[:space:]]`, NOT `\s` (review fix, task 1357). procps-ng compiles
///     the pattern with `regcomp(REG_EXTENDED)` and POSIX ERE has no `\s` —
///     glibc honours it as a GNU extension, musl and BusyBox do not. There
///     the pattern matches nothing (or `regcomp` errors, into the
///     `2>/dev/null` right here), this function returns EMPTY, `killStaleVibe`
///     becomes a no-op, and the run measures whatever stale binary still
///     holds the port — silently, because "no stale instance" and "the regex
///     did not compile" look identical from the caller. `[[:space:]]` is
///     POSIX, needs no shell- or D-level escaping, and selects the same PID
///     on a glibc host (verified 2026-08-19).
string[] vibePidsOnPort(ushort port) {
    import std.algorithm : endsWith;
    import std.string    : splitLines;

    bool isVibe(string pid) {
        auto exe = executeShell(format("readlink /proc/%s/exe 2>/dev/null", pid))
                     .output.strip;
        // A REBUILD renames the inode out from under a running instance, and
        // the kernel then reports its exe as `/path/vibe3d (deleted)`. That is
        // the ordinary case here, not an edge one — `dub build` immediately
        // precedes the run — and an exact-suffix test without this line
        // silently declines to kill exactly the stale instance the rebuild
        // just orphaned, leaving the port held by the PREVIOUS binary for the
        // harness to measure (verified 2026-08-19).
        enum string kDeleted = " (deleted)";
        if (exe.endsWith(kDeleted)) exe = exe[0 .. $ - kDeleted.length];
        return exe.endsWith("/vibe3d");
    }

    auto r = executeShell(format(
        "pgrep -f -- '--http-port %d([[:space:]]|$)' 2>/dev/null", port));
    string[] pids;
    foreach (line; r.output.splitLines) {
        auto pid = line.strip;
        if (pid.length && isVibe(pid)) pids ~= pid;
    }
    return pids;
}

/// Clear a stale vibe3d off THIS RUN'S PORT — and off no other.
///
/// This used to be `pkill -x vibe3d` with a `pgrep -x vibe3d` wait, i.e. it
/// killed EVERY vibe3d on the host. That is a cross-lane hazard, not a
/// theoretical one: task worktrees run their own instances on their own ports
/// concurrently, and a perf run starting in one lane would kill another lane's
/// instance mid-measurement (observed 2026-08-19). The old wait loop had the
/// same fault from the other side — it would spin until a SIBLING's instance
/// happened to exit.
///
/// The port is the lane's reservation, so it is the right scope; see
/// `vibePidsOnPort` for what makes that selection trustworthy, and
/// `warnForeignVibe` for what the narrowed scope gives up and how that is
/// reported instead of silently accepted.
void killStaleVibe(ushort port) {
    foreach (pid; vibePidsOnPort(port))
        executeShell(format("kill %s 2>/dev/null", pid));
    bool gone = false;
    for (int i = 0; i < 30; ++i) {
        if (vibePidsOnPort(port).length == 0) { gone = true; break; }
        Thread.sleep(100.msecs);
    }
    if (!gone) {
        // Still there after 3 s: escalate, again only on our own port — and
        // then WAIT for it (review fix, task 1357). SIGKILL is delivered
        // asynchronously; returning straight from it lets `launchVibe` race a
        // process that still holds the port, and the loser of that race is the
        // NEW instance, whose bind fails while the harness happily measures
        // the old binary that won it.
        foreach (pid; vibePidsOnPort(port))
            executeShell(format("kill -9 %s 2>/dev/null", pid));
        for (int i = 0; i < 20; ++i) {
            if (vibePidsOnPort(port).length == 0) { gone = true; break; }
            Thread.sleep(100.msecs);
        }
        if (!gone)
            stderr.writefln("warning: port %d still held by vibe3d pid(s) %s "
                            ~ "after SIGKILL — the launch below will probably "
                            ~ "fail to bind",
                            port, vibePidsOnPort(port).join(" "));
    }

    warnForeignVibe(port);
}

/// Report — never kill — vibe3d instances that are NOT on this run's port.
///
/// The counterpart to `killStaleVibe`'s port scope (review fix, task 1357).
/// The host-wide `pkill` this replaced also swept ORPHANS: an instance left
/// behind by an interrupted run on another port, or a hand-launched
/// `./vibe3d --test`. Those now survive — and in `--perf` mode vibe3d's main
/// loop is UNCAPPED, so one of them burns a whole core straight through this
/// run's measurement, which is the one resource this lane actually spends.
///
/// They are still not killed: from here an orphan and a sibling lane's live
/// instance are the same observation (a vibe3d on some other port), and
/// killing the second is exactly the incident the port scope exists to
/// prevent. So the operator is told, with PIDs and command lines, and decides.
void warnForeignVibe(ushort port) {
    import std.algorithm : canFind;
    import std.string    : splitLines;

    auto ours = vibePidsOnPort(port);
    auto r = executeShell("pgrep -x vibe3d 2>/dev/null");
    string[] foreign;
    foreach (line; r.output.splitLines) {
        auto pid = line.strip;
        if (!pid.length || ours.canFind(pid)) continue;
        // /proc/PID/cmdline is NUL-separated; NUL→space makes it printable,
        // and it is printed rather than parsed — the operator wants to see
        // WHICH instance this is (port, worktree) to judge it.
        auto cmd = executeShell(
            format("tr '\\0' ' ' < /proc/%s/cmdline 2>/dev/null", pid))
            .output.strip;
        foreign ~= format("%s [%s]", pid, cmd);
    }
    if (foreign.length)
        stderr.writefln("note: %d vibe3d instance(s) running OUTSIDE port %d "
                        ~ "— a --perf instance spins an uncapped main loop and "
                        ~ "competes for CPU with this run. NOT killed (may be "
                        ~ "another lane's): %s",
                        foreign.length, port, foreign.join("; "));
}

bool launchVibe(ushort port, string viewport, string logPath) {
    auto logFile = File(logPath, "wb");
    string[] argv = [buildPath(g_repoRoot, "vibe3d"),
                     "--test", "--perf",
                     "--http-port", port.to!string,
                     "--viewport", viewport];
    Pid pid;
    try {
        pid = spawnProcess(argv, stdin, logFile, logFile, null,
                           Config.suppressConsole);
    } catch (ProcessException e) {
        stderr.writeln("failed to spawn vibe3d: ", e.msg);
        return false;
    }
    g_vibePid = pid.processID;
    // Wait for /api/camera to respond 200.
    // --noproxy '*': a CI runner may inject lowercase http_proxy into the
    // job env, and curl (unlike with the uppercase form) then routes even
    // localhost through the proxy — where our port does not exist.
    string probe = format("curl -s --noproxy '*' -o /dev/null -w '%%{http_code}' " ~
                          "http://localhost:%d/api/camera", port);
    for (int i = 0; i < 150; ++i) {
        auto r = executeShell(probe);
        if (r.status == 0 && r.output.strip == "200") return true;
        Thread.sleep(100.msecs);
    }
    stderr.writeln("vibe3d did not become responsive");
    try { stderr.writeln(File(logPath, "r").byLine.join("\n")); } catch (Exception) {}
    return false;
}
