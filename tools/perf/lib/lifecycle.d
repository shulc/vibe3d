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
import std.socket  : TcpSocket, InternetAddress, SocketOptionLevel, SocketOption;
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

// Every foreign vibe3d this run has SEEN, as "pid [cmdline]" — the sweeps in
// `warnForeignVibe` append here, and `runWasContaminated` is what the history
// writer asks. See that function for why an observation is enough to void the
// run's numbers (task 1840).
__gshared string[] g_foreignVibeSeen;

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

/// Is this PID a vibe3d, judged by its EXECUTABLE rather than by any string
/// it happens to carry? Matching a pattern is not the same as identifying a
/// process, and both callers here need the identification.
bool isVibeExe(string pid) {
    import std.algorithm : endsWith;

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
    import std.string    : splitLines;

    alias isVibe = isVibeExe;

    auto r = executeShell(format(
        "pgrep -f -- '--http-port %d([[:space:]]|$)' 2>/dev/null", port));
    string[] pids;
    foreach (line; r.output.splitLines) {
        auto pid = line.strip;
        if (pid.length && isVibe(pid)) pids ~= pid;
    }
    return pids;
}

/// Can a TCP listener be bound to `port` RIGHT NOW?
///
/// This is the condition `launchVibe` actually needs, and it is a different
/// question from "does a process whose command line names this port exist",
/// which is what this guard used to wait on. The two came apart on the
/// 2026-08-24 nightly (task 1840), and the log says exactly how:
///
///     note: 2 vibe3d instance(s) running OUTSIDE port 8088 ...
///           NOT killed (may be another lane's): 3081331 [./vibe3d]; 3083949 []
///     vibe3d did not become responsive
///     [http] Error starting server: Unable to bind socket: Address already in use
///
/// `3083949 []` — an EMPTY command line. `vibePidsOnPort` selects with
/// `pgrep -f`, which matches command LINES, so a process whose cmdline is
/// unreadable cannot be selected by ANY pattern; `killStaleVibe` saw an empty
/// list, concluded "nothing stale", and handed a held port to `launchVibe`.
/// The bind below asks the kernel instead of asking procfs about a proxy.
///
/// It mirrors `http_server.d`'s own bind EXACTLY — SO_REUSEADDR, INADDR_ANY —
/// because a probe that differs answers a different question than the one the
/// server will ask: without SO_REUSEADDR it reads "held" for a socket in
/// TIME_WAIT the server would bind fine, and on 127.0.0.1 it reads "free" for
/// a wildcard listener that will make the server's bind fail.
bool portBindable(ushort port) {
    try {
        auto s = new TcpSocket();
        scope(exit) s.close();
        s.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        s.bind(new InternetAddress(port));
        return true;
    } catch (Exception) {
        return false;
    }
}

/// The listening socket's owner, straight from `ss` — pid list first, the raw
/// line second (for the operator, so an unkillable holder is NAMED rather than
/// merely counted).
///
/// Identifying the holder BY THE PORT is strictly more faithful to the port
/// reservation rule than matching a command-line pattern is: whatever answers
/// on this lane's port is this lane's business by definition, however its
/// cmdline reads. Absent `ss` (or a socket owned by another user) both fields
/// come back empty and the callers degrade to reporting rather than killing.
struct PortHolder {
    string[] pids;
    string   raw;
}

PortHolder portHolder(ushort port) {
    import std.string : indexOf;

    PortHolder h;
    auto r = executeShell(format("ss -H -ltnp 'sport = :%d' 2>/dev/null", port));
    h.raw = r.output.strip;
    // users:(("vibe3d",pid=3083949,fd=7),("x",pid=12,fd=3))
    string rest = h.raw;
    for (;;) {
        auto at = rest.indexOf("pid=");
        if (at < 0) break;
        rest = rest[at + 4 .. $];
        size_t n = 0;
        while (n < rest.length && rest[n] >= '0' && rest[n] <= '9') ++n;
        if (n > 0) h.pids ~= rest[0 .. n];
        rest = rest[n .. $];
    }
    return h;
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
///
/// WHAT IT WAITS ON — the part task 1840 changed. The wait is on
/// `portBindable`, never on a process disappearing. Waiting for the PROCESS
/// while needing the PORT is a named failure mode in this project (CLAUDE.md,
/// "the gate inspects the wrong thing"), and this function was the live
/// instance of it: on 2026-08-24 the holder had an unreadable command line,
/// no pattern could select it, the process-vanish loop was satisfied
/// instantly, and the run died on `Address already in use`. Bindability is
/// the condition the launch needs, so it is the condition the guard waits on.
void killStaleVibe(ushort port) {
    // Everything this lane may legitimately kill on its own port: the
    // instances whose command line names it, PLUS whoever the kernel says
    // holds the listening socket, when that is a vibe3d.
    string[] killable() {
        import std.algorithm : canFind;
        auto pids = vibePidsOnPort(port);
        foreach (pid; portHolder(port).pids)
            if (!pids.canFind(pid) && isVibeExe(pid)) pids ~= pid;
        return pids;
    }

    bool waitBindable(int tenths) {
        for (int i = 0; i < tenths; ++i) {
            if (portBindable(port)) return true;
            Thread.sleep(100.msecs);
        }
        return portBindable(port);
    }

    foreach (pid; killable())
        executeShell(format("kill %s 2>/dev/null", pid));

    if (!waitBindable(30)) {
        // Still held after 3 s: escalate, again only on our own port — and
        // then WAIT for it (review fix, task 1357). SIGKILL is delivered
        // asynchronously; returning straight from it lets `launchVibe` race a
        // process that still holds the port, and the loser of that race is the
        // NEW instance, whose bind fails while the harness happily measures
        // the old binary that won it.
        foreach (pid; killable())
            executeShell(format("kill -9 %s 2>/dev/null", pid));
        if (!waitBindable(20)) {
            auto h = portHolder(port);
            stderr.writefln("warning: port %d is STILL not bindable after "
                            ~ "SIGKILL — the launch below will fail with "
                            ~ "\"Address already in use\". Holder: %s",
                            port,
                            h.raw.length ? h.raw
                                         : "unknown (ss reported nothing — not "
                                         ~ "installed, or the socket belongs to "
                                         ~ "another user)");
        }
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
///
/// TASK 1840 — the note is now also RECORDED, not only printed. Telling the
/// operator was never the whole job: the run went on to measure anyway and to
/// APPEND those numbers to the history, where they became the next night's
/// `--vs-last` reference. The 2026-08-24 nightly is the worked example. A
/// foreign `./vibe3d` (pid 3081331) ran through the entire ops matrix and the
/// three cases it hit were reported as day-over-day regressions:
///
///     flip/polygons/whole        14017 -> 22012 us   (+57%)
///     magnet/vertices/whole       4287 ->  5949 us   (+39%)
///     mergeFaces/polygons/half   61912 -> 75601 us   (+22%)
///
/// Re-measured on a quiet host at the SAME HEAD they came back to 14675 /
/// 4325 / 65444 — i.e. all three were the neighbour's CPU, not the code. Left
/// unmarked, that entry becomes tomorrow's reference and turns the same three
/// cases into fake IMPROVEMENTS, behind which a real regression of up to the
/// same size passes unseen. So every sweep appends to `g_foreignVibeSeen`,
/// the history writer stamps the entry `"contaminated":true`, and
/// `checkVsLast` refuses both to gate FROM such an entry and to compare
/// AGAINST one.
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
    if (foreign.length) {
        stderr.writefln("note: %d vibe3d instance(s) running OUTSIDE port %d "
                        ~ "— a --perf instance spins an uncapped main loop and "
                        ~ "competes for CPU with this run. NOT killed (may be "
                        ~ "another lane's): %s — this run's numbers are marked "
                        ~ "CONTAMINATED and will not gate",
                        foreign.length, port, foreign.join("; "));
        foreach (f; foreign)
            if (!g_foreignVibeSeen.canFind(f)) g_foreignVibeSeen ~= f;
    }
}

/// Did any sweep of this run see a foreign vibe3d? Sweeps run before the
/// first measurement (from `killStaleVibe`) and again after the last one, so
/// an instance that appears mid-run is caught too.
///
/// It says SEEN, not "measured to have cost us something": from here the two
/// are indistinguishable, and the asymmetry decides which way to fail. A
/// neighbour that was idle costs a re-run; a neighbour that was busy and
/// unrecorded costs a poisoned reference for every night that compares
/// against it.
bool runWasContaminated() { return g_foreignVibeSeen.length > 0; }

string contaminationDetail() { return g_foreignVibeSeen.join("; "); }

// ---------------------------------------------------------------------------
// Process RSS (task 2030 — per-case memory recording)
// ---------------------------------------------------------------------------
//
// The app has no memory-observable endpoint as of this task (a sibling lane
// is adding `GET /api/memory`; not landed on `main` at the time this was
// written, and this harness does not block on it — see the ops-case caller
// for the fallback note). So the ops matrix's before/after reading comes
// straight from the KERNEL's own count of the process's resident pages,
// `/proc/<pid>/statm`, read from the harness process rather than the app:
// this is the harness measuring the app from OUTSIDE it, which needs no
// instrumentation in vibe3d itself and cannot be fooled by a build that
// forgot to wire a counter.
//
// `/proc/<pid>/statm` fields (all in PAGES, space-separated): size resident
// shared text lib data dt. Field 1 (0-indexed) is RESIDENT. Page size is
// hardcoded at 4096 rather than queried via `sysconf(_SC_PAGESIZE)` — every
// host this harness runs on (the dev workstation, `fedora-perf`, the CI
// runners) is x86_64 Linux, where the page size is architecturally fixed at
// 4 KiB; querying it would add an FFI declaration to save nothing real.
//
// Returns -1 on any failure (process gone, /proc unavailable, malformed
// line) so a caller can tell "no reading" from "0 kB resident" — the two
// are not the same claim, and the ops case's caller needs to know when RSS
// simply is not available on this host rather than silently print a zero.
enum long kPageSizeBytes = 4096;

long processRssKb(int pid) {
    import std.file   : readText;
    import std.string : split;

    try {
        auto text = readText(format("/proc/%d/statm", pid));
        auto fields = text.split();
        if (fields.length < 2) return -1;
        long pages = fields[1].to!long;
        return (pages * kPageSizeBytes) / 1024;
    } catch (Exception) {
        return -1;
    }
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
