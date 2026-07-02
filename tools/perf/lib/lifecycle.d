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
import std.stdio   : write, writeln, stdout, stderr, File, stdin;
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

void killStaleVibe() {
    // pkill -x vibe3d (NOT -f 'vibe3d --test' — that self-kills this shell).
    executeShell("pkill -x vibe3d 2>/dev/null");
    for (int i = 0; i < 30; ++i) {
        auto r = executeShell("pgrep -x vibe3d >/dev/null");
        if (r.status != 0) return;
        Thread.sleep(100.msecs);
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
    string probe = format("curl -s -o /dev/null -w '%%{http_code}' " ~
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
