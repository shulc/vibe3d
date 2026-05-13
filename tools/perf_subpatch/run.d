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
import std.string     : indexOf;
import core.thread    : Thread;
import core.time      : dur;
import core.sys.posix.signal : SIGINT;

int main(string[] args) {
    int    port        = 8080;
    int    captureSecs = 10;
    int    targetPolys = 24576;
    bool   noBuild     = false;
    int    perfFreq    = 999;
    int    tabs        = 1;
    string via         = "api";    // "api" or "sdl"

    getopt(args,
        "port",     &port,
        "capture",  &captureSecs,
        "polys",    &targetPolys,
        "no-build", &noBuild,
        "freq",     &perfFreq,
        "tabs",     &tabs,
        "via",      &via);

    if (via != "api" && via != "sdl") {
        stderr.writeln("[perf] --via must be 'api' or 'sdl' (got: "
                       ~ via ~ ")");
        return 1;
    }
    if (tabs < 1) { stderr.writeln("[perf] --tabs must be >= 1"); return 1; }

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
    // `setpriv --pdeathsig SIGKILL --` makes the kernel send SIGKILL
    // to vibe3d the instant the harness's main thread exits, no
    // matter how (SIGKILL from sandbox, abort, segfault). The D
    // scope(exit) cleanup won't run in those abnormal cases, but
    // PDEATHSIG is enforced kernel-side so we never leak.
    string[] vibe3dArgs = [
        "setpriv", "--pdeathsig", "SIGKILL", "--",
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

    // Phase C — Tab × N + idle = the actual profile target.
    //
    // Why multi-Tab? A single toggle triggers ONE rebuildIfStale frame
    // (heavy: OSD topology build + GPU stencil tables + gpu.upload).
    // Subsequent frames just render. With perf at -F999 over an 8 s
    // window that single frame is well below top-30 visibility — most
    // of the capture is steady-state per-frame work. Toggle N times
    // (with a short pause between) to amplify the rebuild signal.
    //
    // `--via sdl` injects a real SDL_KEYDOWN through /api/play-events,
    // exercising the SDLK_TAB handler in app.d. That handler is
    // byte-for-byte equivalent to mesh.subpatch_toggle (both call
    // setSubpatch in a loop), but skips the command pipeline +
    // history.record + origSubpatch.dup, so the API path adds a
    // 24576-bool dup per toggle. Measure both to confirm or refute
    // that the difference is negligible at this poly count.
    long[] tabTimings;
    tabTimings.reserve(tabs);
    foreach (i; 0 .. tabs) {
        auto t0 = nowMs();
        if (via == "api") {
            callApi("/api/command", `{"id":"mesh.subpatch_toggle"}`);
        } else {
            // SDL_KEYDOWN { sym=9 (SDLK_TAB), scan=43 (SDL_SCANCODE_TAB) }
            // Single-event log → play-events runs through SDL handler.
            string log =
                `{"t":0.0,"type":"SDL_KEYDOWN","sym":9,"scan":43,`
                ~ `"mod":0,"repeat":0}`;
            callApi("/api/play-events", log);
            // Spin on /api/play-events/status until "complete".
            int iters = 0;
            while (iters++ < 500) {
                string s;
                try s = cast(string) get(baseUrl ~ "/api/play-events/status");
                catch (CurlException) { break; }
                if (s.length > 0 && s != "running" && s.indexOf("running") < 0)
                    break;
                Thread.sleep(dur!"msecs"(2));
            }
        }
        auto dtMs = nowMs() - t0;
        tabTimings ~= dtMs;
        writefln("[perf] tab %d/%d via=%s : %d ms", i + 1, tabs, via, dtMs);
        // Let one frame render between toggles so rebuildIfStale runs.
        Thread.sleep(dur!"msecs"(50));
    }

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

    // Tab timing stats — sort + sum to derive median / avg.
    import std.algorithm : sort, sum, minElement, maxElement;
    auto sorted = tabTimings.dup;
    sorted.sort();
    long med = sorted.length > 0 ? sorted[sorted.length / 2] : 0;
    long avg = sorted.length > 0 ? sorted.sum / sorted.length : 0;
    writefln("[perf] DONE.\n"
             ~ "  Tab via            : %s\n"
             ~ "  Tab count          : %d\n"
             ~ "  Tab ms min/avg/med/max : %d / %d / %d / %d\n"
             ~ "  raw capture        : %s\n"
             ~ "  text summary       : %s\n"
             ~ "  folded stacks      : %s\n"
             ~ "Top non-idle hits (perf report --no-children, first 30 lines):",
             via, tabs,
             sorted.minElement, avg, med, sorted.maxElement,
             perfData, perfTxt, foldTxt);
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
