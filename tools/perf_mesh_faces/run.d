#!/usr/bin/env rdmd
// Focused perf harness for the Mesh.faces flat-storage refactor.
//
// Scenarios (machine-parseable lines under `[perf_mesh_faces] …`):
//
//   1. SUBDIVIDE — reset → 6 × mesh.subdivide (cube → 24576 quads).
//      Times each subdivide individually. Exercises catmullClarkOsd:
//      result.faces.length = limitF and the per-element writes in
//      result.faces[fi][j] = … that the refactor's Stage B replaces.
//
//   2. SUBPATCH-TAB — on the 24576-poly cage from scenario 1, toggle
//      subpatch N times and report min/avg/median/max ms per toggle.
//      Same workload as perf_subpatch but timed directly without the
//      perf-record overhead, so we can run it back-to-back with the
//      other scenarios in one vibe3d session.
//
//   3. BEVEL — reset → 4 × mesh.subdivide (→ 1536 quads) → select all
//      polygons → tool.set bevel → tool.attr (inset / shift) →
//      tool.doApply → tool.set bevel off. Times the doApply step.
//      Exercises mesh.faces[fi] reads + mesh.faces[fi] = newSlice
//      writes inside bevel.d / poly_bevel.d.
//
// Each scenario is run --reps times; the reported numbers are over
// those repetitions only (warmup is the first iteration, which is
// not counted).
//
// Companion to tools/perf_subpatch/run.d. The Tab number here is
// expected to match perf_subpatch's median within noise; if it
// diverges, perf_subpatch's perf-record overhead is showing.
//
// Usage:
//   rdmd tools/perf_mesh_faces/run.d                     # 5 reps each
//   rdmd tools/perf_mesh_faces/run.d --reps 10           # 10 reps
//   rdmd tools/perf_mesh_faces/run.d --no-build
//   rdmd tools/perf_mesh_faces/run.d --port 8090
//   rdmd tools/perf_mesh_faces/run.d --scenarios subdivide,tab
//
// Output (machine-parseable, one `[perf_mesh_faces]` line per metric):
//   [perf_mesh_faces] subdivide-L1 ms : min=… avg=… med=… max=…
//   [perf_mesh_faces] …
//   [perf_mesh_faces] subdivide-L6 ms : …
//   [perf_mesh_faces] subpatch-tab ms : …
//   [perf_mesh_faces] bevel-1536 ms  : …
//
// Optional --perf (attach perf record around the whole timed window
// after warmup) produces tools/perf_mesh_faces/out/perf.{data,txt}.

import std.algorithm    : map, sort, sum, minElement, maxElement, canFind;
import std.array        : array, join, split;
import std.conv         : to;
import std.datetime.systime : Clock;
import std.file         : exists, mkdirRecurse;
import std.format       : format;
import std.getopt       : getopt;
import std.net.curl     : get, post, HTTP, CurlException;
import std.path         : buildPath, dirName;
import std.process      : Config, Pid, ProcessException, kill,
                           spawnProcess, wait, tryWait, execute, executeShell;
import core.sys.posix.signal : SIGINT, SIGTERM, SIGKILL;
import std.stdio        : writeln, writefln, writef, stderr, stdout;
import std.string       : strip;
import core.thread      : Thread;
import core.time        : dur;

int main(string[] args) {
    int    port        = 8080;
    int    reps        = 5;
    bool   noBuild     = false;
    bool   attachPerf  = false;
    int    perfFreq    = 999;
    string scenariosCsv = "subdivide,tab,bevel";

    getopt(args,
        "port",       &port,
        "reps",       &reps,
        "no-build",   &noBuild,
        "perf",       &attachPerf,
        "freq",       &perfFreq,
        "scenarios",  &scenariosCsv);

    if (reps < 1) { stderr.writeln("--reps must be >= 1"); return 1; }
    bool[string] enable;
    foreach (s; scenariosCsv.split(",")) enable[s.strip] = true;

    string repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    if (!exists(buildPath(repoRoot, "dub.json"))) {
        stderr.writeln("[pmf] couldn't locate repo root at ", repoRoot);
        return 1;
    }
    string outDir = buildPath(repoRoot, "tools",
                               "perf_mesh_faces", "out");
    mkdirRecurse(outDir);

    if (!noBuild) {
        writeln("[pmf] dub build");
        auto br = execute(["dub", "build"], null, Config.none, size_t.max,
                           repoRoot);
        if (br.status != 0) {
            stderr.writeln("[pmf] dub build failed:\n", br.output);
            return 1;
        }
    }

    string vibe3d = buildPath(repoRoot, "vibe3d");
    if (!exists(vibe3d)) {
        stderr.writeln("[pmf] missing ", vibe3d);
        return 1;
    }

    killStaleVibe3d();

    // Phase 0 — launch vibe3d.
    string[] vibe3dArgs = [
        vibe3d, "--test", "--http-port", port.to!string,
    ];
    writefln("[pmf] spawn: %s", vibe3dArgs.join(" "));
    stdout.flush();
    Pid vibe3dPid;
    try {
        vibe3dPid = spawnProcess(vibe3dArgs, null, Config.none, repoRoot);
    } catch (ProcessException e) {
        stderr.writeln("[pmf] vibe3d spawn failed: ", e.msg);
        return 1;
    }
    bool vibe3dDown = false;
    void killVibe3d() {
        if (vibe3dDown) return;
        vibe3dDown = true;
        // Escalating shutdown: SIGINT → wait up to 3 s → SIGTERM →
        // wait 1 s more → SIGKILL. vibe3d's --test mode does react to
        // SIGINT cleanly under normal load, but if the harness was
        // interrupted mid-command the main thread may be stuck on a
        // long mesh operation and miss the signal. Escalating avoids
        // orphan vibe3d processes leaking out of the harness.
        try kill(vibe3dPid, SIGINT); catch (Exception) {}
        if (!waitFor(vibe3dPid, 3000)) {
            try kill(vibe3dPid, SIGTERM); catch (Exception) {}
            if (!waitFor(vibe3dPid, 1000)) {
                try kill(vibe3dPid, SIGKILL); catch (Exception) {}
                try wait(vibe3dPid); catch (Exception) {}
            }
        }
    }
    scope (exit) killVibe3d();

    if (!waitForHttp(port, 30)) {
        stderr.writeln("[pmf] vibe3d didn't open HTTP within 30 s");
        return 1;
    }

    Pid perfPid;
    bool perfStarted = false;
    bool perfDown    = false;
    void killPerf() {
        if (!perfStarted || perfDown) return;
        perfDown = true;
        try kill(perfPid, SIGINT); catch (Exception) {}
        if (!waitFor(perfPid, 3000)) {
            try kill(perfPid, SIGTERM); catch (Exception) {}
            if (!waitFor(perfPid, 1000)) {
                try kill(perfPid, SIGKILL); catch (Exception) {}
                try wait(perfPid); catch (Exception) {}
            }
        }
    }
    scope (exit) killPerf();
    if (attachPerf) {
        if (execute(["which", "perf"]).status != 0) {
            stderr.writeln("[pmf] `perf` not found in PATH "
                           ~ "(skip --perf or install linux-perf)");
            return 1;
        }
        string[] perfArgs = [
            "perf", "record",
            "--call-graph", "dwarf",
            "-F",           perfFreq.to!string,
            "-o",           buildPath(outDir, "perf.data"),
            "-p",           vibe3dPid.processID.to!string,
        ];
        writefln("[pmf] attaching: %s", perfArgs.join(" "));
        try {
            perfPid = spawnProcess(perfArgs, null, Config.none, repoRoot);
            perfStarted = true;
        } catch (ProcessException e) {
            stderr.writeln("[pmf] perf spawn failed: ", e.msg);
            return 1;
        }
        Thread.sleep(dur!"msecs"(500));
    }

    string baseUrl = format("http://localhost:%d", port);
    string callApi(string path, string body_) {
        try return cast(string) post(baseUrl ~ path, body_);
        catch (CurlException e) {
            stderr.writefln("[pmf] %s failed: %s", path, e.msg);
            return "";
        }
    }
    string getApi(string path) {
        try return cast(string) get(baseUrl ~ path);
        catch (CurlException e) {
            stderr.writefln("[pmf] GET %s failed: %s", path, e.msg);
            return "";
        }
    }

    // ----- helpers ------------------------------------------------
    void resetCube() {
        callApi("/api/reset", "");
        callApi("/api/command", "select.typeFrom polygon");
    }
    long timeCmd(string body_) {
        auto t0 = nowMs();
        callApi("/api/command", body_);
        return nowMs() - t0;
    }
    long timeScript(string body_) {
        auto t0 = nowMs();
        callApi("/api/script", body_);
        return nowMs() - t0;
    }
    void reportStats(string label, long[] xs) {
        if (xs.length == 0) {
            writefln("[perf_mesh_faces] %s : no samples", label);
            stdout.flush();
            return;
        }
        auto s = xs.dup; s.sort();
        long med = s[s.length / 2];
        long avg = s.sum / cast(long)s.length;
        writefln("[perf_mesh_faces] %s : min=%d avg=%d med=%d max=%d "
                 ~ "(n=%d)",
                 label, s.minElement, avg, med, s.maxElement, s.length);
        stdout.flush();
    }
    void progress(string s) { writeln(s); stdout.flush(); }

    // ----- 1. SUBDIVIDE -------------------------------------------
    // Always one warmup rep before the timed loop — primes the GC,
    // OSD topology cache, and any internal-buffer high-water marks.
    // Then `reps` measured iterations.
    if ("subdivide" in enable) {
        progress("[pmf] scenario: subdivide");
        long[][6] perLevel;
        progress("[pmf]   warmup");
        resetCube();
        foreach (lvl; 0 .. 6) callApi("/api/command",
                                       `{"id":"mesh.subdivide"}`);
        foreach (rep; 0 .. reps) {
            progress(format("[pmf]   rep %d/%d", rep + 1, reps));
            resetCube();
            foreach (lvl; 0 .. 6) {
                long dt = timeCmd(`{"id":"mesh.subdivide"}`);
                perLevel[lvl] ~= dt;
            }
        }
        foreach (lvl; 0 .. 6)
            reportStats(format("subdivide-L%d ms", lvl + 1), perLevel[lvl]);
    }

    // ----- 2. SUBPATCH-TAB ----------------------------------------
    if ("tab" in enable) {
        progress("[pmf] scenario: subpatch-tab");
        long[] perTab;
        void setupTab() {
            resetCube();
            foreach (lvl; 0 .. 6) callApi("/api/command",
                                           `{"id":"mesh.subdivide"}`);
            // Warmup toggle so the first measured one is steady-
            // state (avoids paying topology-create startup cost on
            // the very first build).
            callApi("/api/command", `{"id":"mesh.subpatch_toggle"}`);
        }
        progress("[pmf]   warmup");
        setupTab();
        // 8 toggles per rep — 4 build-side measurements per rep.
        // Per-toggle timing INCLUDES the wait until the next
        // main-loop iteration's tickCommand fires. Because main loop
        // runs `tickCommand → rebuildIfStale → render` per iteration
        // and the previous-iteration's heavy rebuildIfStale must
        // finish before the next iteration's tickCommand starts, the
        // heavy build time SHOWS UP on the toggle AFTER the one that
        // triggered the rebuild — i.e. even-indexed iters (0, 2, 4,
        // 6 after the warmup-ON state).
        foreach (rep; 0 .. reps) {
            progress(format("[pmf]   rep %d/%d (setup + 8 toggles)",
                             rep + 1, reps));
            setupTab();
            foreach (i; 0 .. 8) {
                long dt = timeCmd(`{"id":"mesh.subpatch_toggle"}`);
                if (i % 2 == 0) perTab ~= dt;   // measures the prev build
            }
        }
        reportStats("subpatch-tab ms ", perTab);
    }

    // ----- 3. BEVEL -----------------------------------------------
    // 384 polys (cube → 3 × subdivide). Smaller than the 1536-poly
    // case originally planned because bevel-all on 1536 polys runs
    // over half a minute per rep; at 384 it's a couple seconds and
    // still exercises the faces[fi] read + replace paths in
    // poly_bevel.d / bevel.d that the refactor's Stage D affects.
    if ("bevel" in enable) {
        progress("[pmf] scenario: bevel");
        long[] perBevel;
        void setupBevel() {
            resetCube();
            foreach (lvl; 0 .. 3) callApi("/api/command",
                                           `{"id":"mesh.subdivide"}`);
            // "Select all polygons" — vibe3d has no `select.all`,
            // but select.invert from an empty selection ⇒ all.
            callApi("/api/command", "select.invert");
        }
        immutable string bevelScript =
            "tool.set bevel\n"
            ~ "tool.attr bevel insert 0.05\n"
            ~ "tool.attr bevel shift 0\n"
            ~ "tool.doApply\n"
            ~ "tool.set bevel off";
        progress("[pmf]   warmup");
        setupBevel();
        callApi("/api/script", bevelScript);
        foreach (rep; 0 .. reps) {
            progress(format("[pmf]   rep %d/%d", rep + 1, reps));
            setupBevel();
            auto t0 = nowMs();
            callApi("/api/script", bevelScript);
            long dt = nowMs() - t0;
            perBevel ~= dt;
        }
        reportStats("bevel-384 ms  ", perBevel);
    }

    killPerf();
    killVibe3d();

    if (attachPerf) {
        auto r = executeShell(format(
            "perf report --stdio --no-children -i %s > %s",
            shQuote(buildPath(outDir, "perf.data")),
            shQuote(buildPath(outDir, "perf.txt"))));
        if (r.status != 0)
            stderr.writeln("[pmf] perf report failed:\n", r.output);
        else
            writefln("[pmf] perf report: %s",
                     buildPath(outDir, "perf.txt"));
    }
    return 0;
}

void killStaleVibe3d() {
    try execute(["pkill", "-f", "vibe3d --test"]); catch (Exception) {}
    Thread.sleep(dur!"msecs"(500));
}

/// Poll `tryWait` for up to `timeoutMs` milliseconds. Returns true if
/// the process exited within the window, false on timeout.
bool waitFor(Pid pid, int timeoutMs) {
    int elapsed = 0;
    while (elapsed < timeoutMs) {
        auto r = tryWait(pid);
        if (r.terminated) return true;
        Thread.sleep(dur!"msecs"(50));
        elapsed += 50;
    }
    return false;
}

bool waitForHttp(int port, int timeoutSecs) {
    string url = format("http://localhost:%d/api/model", port);
    int elapsed = 0;
    while (elapsed < timeoutSecs * 1000) {
        try {
            auto h = HTTP();
            h.connectTimeout   = dur!"msecs"(200);
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

string shQuote(string s) { return "'" ~ s ~ "'"; }
