module lib.http;
// HTTP plumbing shared by the `ops` and `frames` subcommands: talking to a
// running `vibe3d --test` instance's /api/* surface (reset, select, script,
// command, play-events, perf, frames, model).
//
// Extracted from tools/perf/run.d as part of task 0197 (perf tooling
// consolidation) — pure code-motion, no behavior change.

import std.array    : appender;
import std.conv     : to;
import std.format   : format;
import std.json     : parseJSON, JSONValue, JSONType;
import std.net.curl : get, post;
import std.string   : strip;

import core.thread : Thread;
import core.time    : msecs;

import lib.stats : FrameRecJ, parseFrameRec, FrameStats;

string g_baseUrl = "http://localhost:8088";

void postUrl(string path, string body_ = "") {
    post(g_baseUrl ~ path, body_);
}

// `tool.set` / `tool.pipe.attr` go through /api/script as a plain command
// string. Returns true on {"status":"ok"}.
bool script(string cmd) {
    try {
        auto resp = post(g_baseUrl ~ "/api/script", cmd);
        auto j = parseJSON(cast(string)resp);
        return ("status" in j) && j["status"].str == "ok";
    } catch (Exception e) {
        return false;
    }
}

void resetMesh(string type, int n) {
    string key = (type == "subdivcube") ? "levels" : "n";
    postUrl(format("/api/reset?type=%s&%s=%d", type, key, n));
}

bool selectVertices(int[] indices) {
    auto a = appender!string();
    a.put(`{"mode":"vertices","indices":[`);
    foreach (i, v; indices) {
        if (i) a.put(",");
        a.put(v.to!string);
    }
    a.put("]}");
    try {
        auto resp = post(g_baseUrl ~ "/api/select", a.data);
        auto j = parseJSON(cast(string)resp);
        return ("status" in j) && j["status"].str == "ok";
    } catch (Exception) {
        return false;
    }
}

// Mode-aware selection. POST /api/select {"mode":mode,"indices":[...]}.
// `mesh.select` sets the app's editMode to match `mode` as a side effect,
// and an empty `indices` clears the selection (⇒ "whole mesh"). Returns
// true on {"status":"ok"}.
bool selectMode(string mode, int[] indices) {
    auto a = appender!string();
    a.put(`{"mode":"`);
    a.put(mode);
    a.put(`","indices":[`);
    foreach (i, v; indices) {
        if (i) a.put(",");
        a.put(v.to!string);
    }
    a.put("]}");
    try {
        auto resp = post(g_baseUrl ~ "/api/select", a.data);
        auto j = parseJSON(cast(string)resp);
        return ("status" in j) && j["status"].str == "ok";
    } catch (Exception) {
        return false;
    }
}

// POST a bare command-id argstring to /api/command (e.g. "mesh.delete").
// Returns true on {"status":"ok"}.
bool postCommand(string id) {
    try {
        auto resp = post(g_baseUrl ~ "/api/command", id);
        auto j = parseJSON(cast(string)resp);
        return ("status" in j) && j["status"].str == "ok";
    } catch (Exception) {
        return false;
    }
}

void playAndWait(string log) {
    auto resp = post(g_baseUrl ~ "/api/play-events", log);
    auto j = parseJSON(cast(string)resp);
    if (j["status"].str != "success")
        throw new Exception("play-events failed: " ~ cast(string)resp);
    foreach (i; 0 .. 400) {
        auto s = parseJSON(cast(string)get(g_baseUrl ~ "/api/play-events/status"));
        if (s["finished"].type == JSONType.true_) return;
        Thread.sleep(25.msecs);
    }
    throw new Exception("play-events did not finish within 10s");
}

void perfReset() { postUrl("/api/perf/reset"); }

JSONValue perfRead() {
    return parseJSON(cast(string)get(g_baseUrl ~ "/api/perf"));
}

// ---------------------------------------------------------------------------
// /api/frames — FrameProbe (task 0195). Mirrors the /api/perf helpers above.
// ---------------------------------------------------------------------------

void framesReset() { postUrl("/api/frames/reset"); }

FrameStats fetchFrames() {
    FrameStats s;
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/frames"));
    if ("frameCount" !in j) return s;   // "{}" — uninstrumented build
    s.frameCount = j["frameCount"].integer;
    if (s.frameCount == 0) return s;
    s.empty = false;
    auto total = j["total"];
    s.p50Ns = total["p50_ns"].integer;
    s.p95Ns = total["p95_ns"].integer;
    s.p99Ns = total["p99_ns"].integer;
    s.maxNs = total["max_ns"].integer;
    s.hitch16 = j["hitch_16ms"].integer;
    s.hitch33 = j["hitch_33ms"].integer;
    s.meshCacheRebuilds = j["meshCacheRebuilds"].integer;
    s.gcAllocBytes  = j["gcAllocBytes"].integer;
    s.gcCollections = j["gcCollections"].integer;
    s.steadyMaxAllocBytes = j["steadyMaxAllocBytes"].integer;
    if (j["worst"].type != JSONType.null_) s.worst = parseFrameRec(j["worst"]);
    return s;
}

struct ModelInfo { long vertexCount; long faceCount; }
// Lightweight geometry probe for command cases: /api/layers reports the
// active layer's vertex/face counts AND its mutationVersion without
// serializing the mesh (the full /api/model dump times out the main-thread
// bridge past ~half a million faces). mutationVersion moves on EVERY
// mutation, including pure deforms (smooth/jitter/quantize), so
// "counts unchanged but version bumped" still proves the command ran.
struct LayerInfo { long vertexCount, faceCount, mutationVersion; }

LayerInfo activeLayerInfo() {
    import std.json : JSONType;
    // Patient: right after a huge one-shot command the main thread spends
    // several seconds inside ONE frame digesting the new mesh (caches,
    // loops, GPU upload), and /api/layers' 5s bridge times out (500) until
    // that frame ends. Retry for up to ~90s before giving up.
    string body_;
    for (int attempt = 0; ; ++attempt) {
        try { body_ = cast(string)get(g_baseUrl ~ "/api/layers"); break; }
        catch (Exception e) {
            if (attempt >= 180) throw e;
            Thread.sleep(500.msecs);
        }
    }
    auto j = parseJSON(body_);
    LayerInfo li;
    foreach (l; j["layers"].array) {
        if (l["active"].type == JSONType.true_) {
            li.vertexCount     = l["vertexCount"].integer;
            li.faceCount       = l["faceCount"].integer;
            li.mutationVersion = l["mutationVersion"].integer;
            break;
        }
    }
    return li;
}

ModelInfo modelInfo() {
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/model"));
    ModelInfo m;
    m.vertexCount = j["vertexCount"].integer;
    m.faceCount   = j["faceCount"].integer;
    return m;
}

// Visible BACKGROUND layers (`visible && !selected`, the derived third state
// /api/layers publishes per layer). That set is exactly what app.d installs
// as `snap`'s background SOURCES, and `snapCursor` runs its candidate walk —
// and therefore builds at most one visibility mask — once per source: once
// for the primary plus once per entry here. The perf lane's I7c bound reads
// this instead of assuming a single-layer document, so the day a multi-layer
// case is added the bound moves with it rather than false-failing (review
// fix, task 1359).
long fetchBackgroundLayerCount() {
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/layers"));
    if ("layers" !in j) return 0;
    long n = 0;
    foreach (l; j["layers"].array)
        if ("background" in l && l["background"].type == JSONType.true_) n++;
    return n;
}

// Selected polygon count from /api/selection — used by the `lasso-dense`
// frame scenario (task 0200, F-I6b: "lasso engaged").
long fetchSelectedFaceCount() {
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/selection"));
    if ("selectedFaces" !in j) return 0;
    return j["selectedFaces"].array.length;
}

// POST /api/camera — sets View azimuth/elevation/distance/focus (existing
// test-automation endpoint). Used by the `lasso-dense` frame scenario (task
// 0200) to look at a `grid`-type mesh from BELOW: `makeGridPlane`'s Newell-
// method face normal computes to -Y (mesh.d), so the DEFAULT above-plane
// camera trips app.d's Polygons-lasso CPU backface pre-check (`dot(faceNormal,
// vert - eye) >= 0` skips every face) even though ordinary GPU-FBO click
// picking is unaffected (a different code path with no CPU pre-check).
// Looking from below makes the lasso's pre-check agree with the mesh's
// actual winding. This is a scenario camera-setup choice, not a mesh/
// winding fix — see doc/frame_scenarios_ci_plan.md's provenance note (pure
// perf tooling; lasso *correctness* stays owned by tests/test_lasso_select.d).
//
// SAVE/RESTORE IS NOT LOSSLESS, and a caller that uses this to put a camera
// BACK (`run.d`'s per-case `Case.elevation`, task 1350) should know exactly
// what it restores (review note, task 1357). The camera's rotational truth is
// a 3x3 `Orientation`, not three angles (`source/view.d`); `View.elevation`'s
// setter reads (azimuth, elevation, roll) out of that matrix and rebuilds it
// from (azimuth, NEW elevation, roll). So a read-then-write round trip:
//   * costs float dust (~1e-7) on the two angles it did not mean to touch;
//   * cannot separate heading from bank at a POLE — the chart is degenerate
//     there, so a camera parked at elevation ±pi/2 does not come back;
//   * carries NO information about roll or azimuth of its own. It restores
//     the pitch and nothing else, which is faithful only because the caller
//     set nothing else. A case that ever banks or orbits the camera must
//     save and restore the ORIENTATION, not this scalar.
// It is used anyway because the perf matrix's cases only ever change pitch,
// and this is the field `/api/camera` accepts.
bool setCameraElevation(double elevation) {
    try {
        auto resp = post(g_baseUrl ~ "/api/camera", format(`{"elevation":%f}`, elevation));
        auto j = parseJSON(cast(string)resp);
        return ("status" in j) && j["status"].str == "ok";
    } catch (Exception) {
        return false;
    }
}

// POST /api/undo — same main-thread sync bridge as /api/command. Used by
// the `undo-spam` frame scenario (task 0200). Returns true on
// {"status":"ok"}; a stack-empty/revert-failed noop or an error both
// return false (the caller only cares whether the request round-tripped —
// the actual per-undo count comes from /api/perf's `undoApply` counter).
bool postUndo() {
    try {
        auto resp = post(g_baseUrl ~ "/api/undo", "");
        auto j = parseJSON(cast(string)resp);
        return ("status" in j) && j["status"].str == "ok";
    } catch (Exception) {
        return false;
    }
}

// Post-drag settle: /api/play-events/status reports "finished" once events
// are POSTED to the SDL queue, not necessarily fully processed by the main
// loop (same caveat documented in CLAUDE.md for the HTTP test suite) — wait
// a beat before reading /api/frames so the window includes the drag's last
// frames.
void settleAfterPlay() { Thread.sleep(150.msecs); }

// Cold-start settle: a fresh dense mesh's FIRST few rendered frames pay
// one-time setup costs (GPU buffer allocation, cache first-resize, pipeline
// first-evaluate) that can legitimately trigger a GC collection — the same
// class of cost the ops matrix's `runCase` discards via its "warmup drag"
// (see the comment there). `framesReset()` is always called AFTER this
// settle so the measured ring only sees steady-state frames, keeping F-I4
// (0 GC collections) a meaningful signal instead of a cold-start false
// positive. `--perf` runs uncapped (no vsync, no SDL_Delay), so this window
// covers many dozens of frames.
void settleAfterReset() { Thread.sleep(200.msecs); }
