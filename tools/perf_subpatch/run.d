#!/usr/bin/env rdmd
// Perf harness for the "Tab on a 24K-poly cage" scenario.
//
// Sequence:
//   1. Start vibe3d --test (no perf attached).
//   2. /api/reset → 6 × mesh.subdivide  (cube → 24576 quads).
//   3. Attach `perf record -p <PID> -g --call-graph=dwarf` to the running
//      vibe3d. This skips startup / GL init / ImGui-font cost which would
//      otherwise dominate a single launch-to-exit capture.
//   4. /api/command mesh.subpatch_toggle  (= the user's "Tab").
//   5. Idle for --capture seconds so per-frame cost shows up.
//   6. SIGINT perf → SIGINT vibe3d → run `perf report` + write a folded
//      stack file for FlameGraph.
//
// Outputs land in tools/perf_subpatch/out/.
//
// Usage:
//   rdmd tools/perf_subpatch/run.d                 # default 10 s capture
//   rdmd tools/perf_subpatch/run.d --capture 30
//   rdmd tools/perf_subpatch/run.d --polys 6144    # stop earlier (5 subdivs)
//   rdmd tools/perf_subpatch/run.d --no-build
//   rdmd tools/perf_subpatch/run.d --port 8090
//   rdmd tools/perf_subpatch/run.d --freq 4999     # higher sampling rate

import std.array      : array, join;
import std.conv       : to;
import std.datetime.systime : Clock;
import std.file       : exists, mkdirRecurse;
import std.format     : format;
import std.getopt     : getopt;
import std.net.curl   : get, post, HTTP, CurlException;
import std.path       : buildPath, dirName;
import std.process    : Config, Pid, ProcessException, kill, spawnProcess,
                         wait, tryWait, execute, executeShell;
import std.stdio      : writeln, writefln, stderr;
import core.thread    : Thread;
import core.time      : dur;
import core.sys.posix.signal : SIGINT;

int main(string[] args) {
    int  port        = 8080;
    int  captureSecs = 10;
    int  targetPolys = 24576;
    bool noBuild     = false;
    int  perfFreq    = 999;

    getopt(args,
        "port",     &port,
        "capture",  &captureSecs,
        "polys",    &targetPolys,
        "no-build", &noBuild,
        "freq",     &perfFreq);

    string repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    if (!exists(buildPath(repoRoot, "dub.json"))) {
        stderr.writeln("[perf] couldn't locate repo root at ", repoRoot);
        return 1;
    }
    string outDir   = buildPath(repoRoot, "tools",
                                 "perf_subpatch", "out");
    mkdirRecurse(outDir);
    string perfData = buildPath(outDir, "perf.data");
    string perfTxt  = buildPath(outDir, "perf.txt");
    string foldTxt  = buildPath(outDir, "folded.txt");

    if (!noBuild) {
        writeln("[perf] dub build");
        auto br = execute(["dub", "build"], null, Config.none, size_t.max,
                           repoRoot);
        if (br.status != 0) {
            stderr.writeln("[perf] dub build failed:\n", br.output);
            return 1;
        }
    }

    string vibe3d = buildPath(repoRoot, "vibe3d");
    if (!exists(vibe3d)) {
        stderr.writeln("[perf] missing ", vibe3d,
                       " — rebuild without --no-build");
        return 1;
    }

    killStaleVibe3d();

    if (execute(["which", "perf"]).status != 0) {
        stderr.writeln("[perf] `perf` not found in PATH "
                       ~ "(install linux-perf / perf userspace tools)");
        return 1;
    }

    // Phase 0 — launch vibe3d (no perf attached yet).
    string[] vibe3dArgs = [
        vibe3d, "--test", "--http-port", port.to!string,
    ];
    writefln("[perf] spawn: %s", vibe3dArgs.join(" "));
    Pid vibe3dPid;
    try {
        vibe3dPid = spawnProcess(vibe3dArgs, null, Config.none, repoRoot);
    } catch (ProcessException e) {
        stderr.writeln("[perf] vibe3d spawn failed: ", e.msg);
        return 1;
    }
    bool vibe3dDown = false;
    void killVibe3d() {
        if (vibe3dDown) return;
        vibe3dDown = true;
        try kill(vibe3dPid, SIGINT); catch (Exception) {}
        try wait(vibe3dPid);          catch (Exception) {}
    }
    scope (exit) killVibe3d();

    if (!waitForHttp(port, 30)) {
        stderr.writeln("[perf] vibe3d didn't open HTTP within 30 s");
        return 1;
    }

    int subdivides = 0;
    {
        int polys = 6;
        while (polys < targetPolys) { polys *= 4; ++subdivides; }
        if (polys != targetPolys) {
            stderr.writefln("[perf] target %d isn't 6 × 4^N — closest %d "
                             ~ "after %d subdivides",
                             targetPolys, polys, subdivides);
            return 1;
        }
    }
    writefln("[perf] setup: %d subdivides → %d polys", subdivides, targetPolys);

    string baseUrl = format("http://localhost:%d", port);
    string callApi(string path, string body_) {
        try return cast(string) post(baseUrl ~ path, body_);
        catch (CurlException e) {
            stderr.writefln("[perf] %s failed: %s", path, e.msg);
            return "";
        }
    }

    // Phase A — setup. Subdivide pipeline runs unprofiled.
    callApi("/api/reset", "");
    callApi("/api/command", "select.typeFrom polygon");
    foreach (i; 0 .. subdivides) {
        auto t0 = nowMs();
        callApi("/api/command", `{"id":"mesh.subdivide"}`);
        writefln("[perf] subdivide %d/%d done in %d ms",
                 i + 1, subdivides, nowMs() - t0);
    }

    // Phase B — attach perf to the live vibe3d. `--inherit` follows child
    // threads (we DON'T want to follow children — vibe3d doesn't spawn any
    // — but the option keeps threads in the same process attached).
    string[] perfArgs = [
        "perf", "record",
        "--call-graph", "dwarf",
        "-F",           perfFreq.to!string,
        "-o",           perfData,
        "-p",           vibe3dPid.processID.to!string,
    ];
    writefln("[perf] attaching: %s", perfArgs.join(" "));
    Pid perfPid;
    try {
        perfPid = spawnProcess(perfArgs, null, Config.none, repoRoot);
    } catch (ProcessException e) {
        stderr.writeln("[perf] perf spawn failed: ", e.msg);
        return 1;
    }
    bool perfDown = false;
    void killPerf() {
        if (perfDown) return;
        perfDown = true;
        try kill(perfPid, SIGINT); catch (Exception) {}
        try wait(perfPid);          catch (Exception) {}
    }
    scope (exit) killPerf();

    // perf record needs ~200 ms before it's actually sampling; sleep a
    // hair so the Tab call doesn't precede sample capture.
    Thread.sleep(dur!"msecs"(500));

    // Phase C — Tab + idle = the actual profile target.
    writeln("[perf] mesh.subpatch_toggle (Tab)");
    auto tabT0 = nowMs();
    callApi("/api/command", `{"id":"mesh.subpatch_toggle"}`);
    auto tabMs = nowMs() - tabT0;
    writefln("[perf] subpatch_toggle returned in %d ms", tabMs);

    writefln("[perf] idle %d s for per-frame capture…", captureSecs);
    Thread.sleep(dur!"seconds"(captureSecs));

    killPerf();
    killVibe3d();

    // Phase D — reports.
    writeln("[perf] generating reports");
    {
        auto r = executeShell(format(
            "perf report --stdio --no-children -i %s > %s",
            shQuote(perfData), shQuote(perfTxt)));
        if (r.status != 0)
            stderr.writeln("[perf] perf report failed:\n", r.output);
    }
    {
        // Best-effort folded stacks; if `stackcollapse-perf.pl` from
        // FlameGraph is on PATH we use it, otherwise dump raw `perf
        // script` output for later collation.
        auto sc = execute(["which", "stackcollapse-perf.pl"]);
        string cmd;
        if (sc.status == 0) {
            cmd = format("perf script -i %s | stackcollapse-perf.pl > %s",
                          shQuote(perfData), shQuote(foldTxt));
        } else {
            cmd = format("perf script -i %s > %s",
                          shQuote(perfData), shQuote(foldTxt));
        }
        auto r = executeShell(cmd);
        if (r.status != 0)
            stderr.writeln("[perf] folded stacks dump failed:\n", r.output);
    }

    writefln("[perf] DONE.\n"
             ~ "  Tab cost (one-shot): %d ms\n"
             ~ "  raw capture        : %s\n"
             ~ "  text summary       : %s\n"
             ~ "  folded stacks      : %s\n"
             ~ "Top non-idle hits (perf report --no-children, first 30 lines):",
             tabMs, perfData, perfTxt, foldTxt);
    auto top = executeShell(format(
        "grep -E '^\\s*[0-9]+\\.' %s | head -30",
        shQuote(perfTxt)));
    if (top.status == 0) writeln(top.output);
    return 0;
}

void killStaleVibe3d() {
    try execute(["pkill", "-f", "vibe3d --test"]); catch (Exception) {}
    Thread.sleep(dur!"msecs"(500));
}

bool waitForHttp(int port, int timeoutSecs) {
    string url = format("http://localhost:%d/api/model", port);
    int elapsed = 0;
    while (elapsed < timeoutSecs * 1000) {
        try {
            auto h = HTTP();
            h.connectTimeout = dur!"msecs"(200);
            h.operationTimeout = dur!"msecs"(400);
            get(url, h);
            return true;
        } catch (Exception) {
            Thread.sleep(dur!"msecs"(200));
            elapsed += 200;
        }
    }
    return false;
}

long nowMs() {
    auto t = Clock.currTime;
    return t.toUnixTime!long * 1000 + t.fracSecs.total!"msecs";
}

string shQuote(string s) {
    return "'" ~ s ~ "'";
}
