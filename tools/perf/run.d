#!/usr/bin/env rdmd
// Interactive-tool perf benchmark runner (Phase 3+4 of
// doc/perf_harness_plan.md).
//
// Builds the optimized `perf` buildType, launches vibe3d in --perf mode,
// then for each matrix case:
//   1. reset + build a dense mesh   (/api/reset?type=grid&n=<N>)
//   2. select a deterministic vertex set (/api/select)
//   3. set the tool                  (/api/script tool.set move|rotate|scale)
//   4. configure the pipe            (/api/script tool.pipe.attr ...)
//   5. zero the perf counters        (/api/perf/reset)
//   6. synthesize + replay a gizmo drag (live camera + handle projection)
//   7. read the perf breakdown       (/api/perf)
//
// The drag is SYNTHESIZED at runtime (fetch the live camera, project the
// gizmo handle to pixels, build a JSON-Lines drag log) — never a frozen
// .log, which is camera-fragile. The projection helpers below are a small
// self-contained copy of tests/drag_helpers.d (the test module declares
// `module drag_helpers;` and would clash if imported into this rdmd unit).
//
// Output: a median/p95 table to stdout + tools/perf/results.json.
//
// This runner runs vibe3d SINGLE-THREADED on purpose — there is no -j.
// A perf measurement must not contend for CPU with a sibling instance, so
// one vibe3d at a time is the only correct configuration.
//
// Usage:
//   ./run.d                          # full matrix on the default mesh
//   ./run.d --no-build               # skip the dub build
//   ./run.d --keep                   # leave vibe3d running after the run
//   ./run.d --n 64                   # smaller grid (faster smoke run)
//   ./run.d --mesh-size 316          # alias for --n
//   ./run.d --subdivcube 7           # use subdivideCube(levels) instead of grid
//   ./run.d --repeats 5              # R measured drags per case (default 5)
//   ./run.d move rotate              # subset: only cases whose name contains a token
//   ./run.d --http-port 8090         # custom port (default 8088)
//   ./run.d --viewport 1280x960      # fixed viewport (default 1280x960)

import std.algorithm : sort, canFind, map, sum, min, max;
import std.array     : array, appender, join, split;
import std.conv      : to;
static import std.file;
import std.file      : exists, mkdirRecurse;
import std.format    : format;
import std.getopt    : getopt, config;
import std.json      : parseJSON, JSONValue, JSONType;
import std.math      : sqrt, sin, cos, tan, PI, fabs;
import std.net.curl  : get, post, HTTP, CurlException;
import std.path      : absolutePath, buildPath, buildNormalizedPath, dirName;
import std.process   : execute, executeShell, spawnProcess, Config, Pid,
                       environment, ProcessException;
import std.range     : enumerate, iota;
import std.stdio     : writeln, writefln, write, stdout, stderr, File, stdin;
import std.string    : strip, startsWith;

import core.thread        : Thread;
import core.time          : msecs, dur;
import core.stdc.stdlib   : exit;
import core.sys.posix.signal : signal, SIGINT, SIGTERM;
import core.sys.posix.signal : kill;

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
// Minimal vec/matrix + projection (self-contained copy of tests/drag_helpers)
// ---------------------------------------------------------------------------

struct Vec3 {
    float x = 0, y = 0, z = 0;
    Vec3 opBinary(string op)(Vec3 b) const {
        static if (op == "+") return Vec3(x+b.x, y+b.y, z+b.z);
        else static if (op == "-") return Vec3(x-b.x, y-b.y, z-b.z);
        else static assert(0);
    }
    Vec3 opBinary(string op)(float s) const if (op == "*" || op == "/") {
        static if (op == "*") return Vec3(x*s, y*s, z*s);
        else                  return Vec3(x/s, y/s, z/s);
    }
}

float dot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
Vec3  cross(Vec3 a, Vec3 b) {
    return Vec3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
Vec3 normalize(Vec3 v) {
    float L = sqrt(dot(v, v));
    return L > 1e-9f ? Vec3(v.x/L, v.y/L, v.z/L) : Vec3(0, 0, 0);
}

float[16] lookAt(Vec3 eye, Vec3 center, Vec3 worldUp) {
    Vec3 f = normalize(Vec3(center.x-eye.x, center.y-eye.y, center.z-eye.z));
    Vec3 r = normalize(cross(f, worldUp));
    Vec3 u = cross(r, f);
    return [
         r.x,  u.x, -f.x, 0,
         r.y,  u.y, -f.y, 0,
         r.z,  u.z, -f.z, 0,
        -(r.x*eye.x + r.y*eye.y + r.z*eye.z),
        -(u.x*eye.x + u.y*eye.y + u.z*eye.z),
         (f.x*eye.x + f.y*eye.y + f.z*eye.z), 1,
    ];
}

float[16] perspectiveMatrix(float fovY, float aspect, float near, float far) {
    float fnum = 1.0f / tan(fovY * 0.5f);
    float nf   = near - far;
    return [
        fnum/aspect, 0,    0,             0,
        0,           fnum, 0,             0,
        0,           0,    (far+near)/nf, -1,
        0,           0,    2*far*near/nf, 0,
    ];
}

struct Viewport {
    float[16] view;
    float[16] proj;
    int width, height, x, y;
}

struct CameraState {
    Vec3 eye, focus;
    int width, height, vpX, vpY;
}

string g_baseUrl = "http://localhost:8088";

CameraState fetchCamera() {
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/camera"));
    CameraState c;
    c.eye   = Vec3(cast(float)j["eye"]["x"].floating,
                   cast(float)j["eye"]["y"].floating,
                   cast(float)j["eye"]["z"].floating);
    c.focus = Vec3(cast(float)j["focus"]["x"].floating,
                   cast(float)j["focus"]["y"].floating,
                   cast(float)j["focus"]["z"].floating);
    c.width  = cast(int)j["width"].integer;
    c.height = cast(int)j["height"].integer;
    c.vpX    = cast(int)j["vpX"].integer;
    c.vpY    = cast(int)j["vpY"].integer;
    return c;
}

Viewport viewportFromCamera(CameraState c) {
    Viewport vp;
    vp.view   = lookAt(c.eye, c.focus, Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                  cast(float)c.width / c.height, 0.001f, 100.0f);
    vp.width  = c.width;
    vp.height = c.height;
    vp.x      = c.vpX;
    vp.y      = c.vpY;
    return vp;
}

bool projectToWindow(Vec3 w, const ref Viewport vp, out float px, out float py) {
    float vx = vp.view[0]*w.x + vp.view[4]*w.y + vp.view[8]*w.z + vp.view[12];
    float vy = vp.view[1]*w.x + vp.view[5]*w.y + vp.view[9]*w.z + vp.view[13];
    float vz = vp.view[2]*w.x + vp.view[6]*w.y + vp.view[10]*w.z + vp.view[14];
    float vw = vp.view[3]*w.x + vp.view[7]*w.y + vp.view[11]*w.z + vp.view[15];
    float cx = vp.proj[0]*vx + vp.proj[4]*vy + vp.proj[8] *vz + vp.proj[12]*vw;
    float cy = vp.proj[1]*vx + vp.proj[5]*vy + vp.proj[9] *vz + vp.proj[13]*vw;
    float cw = vp.proj[3]*vx + vp.proj[7]*vy + vp.proj[11]*vz + vp.proj[15]*vw;
    if (!(cw > 0.0f)) return false;
    float nx = cx / cw, ny = cy / cw;
    px = (nx * 0.5f + 0.5f)          * vp.width  + vp.x;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height + vp.y;
    return true;
}

float gizmoSize(Vec3 pos, const ref Viewport vp, float gizmoPixels = 90.0f) {
    float depth = -(vp.view[2]*pos.x + vp.view[6]*pos.y + vp.view[10]*pos.z + vp.view[14]);
    if (depth < 1e-4f) depth = 1e-4f;
    float vh = vp.height > 0 ? cast(float)vp.height : 1.0f;
    return 2.0f * gizmoPixels * depth / (vp.proj[5] * vh);
}

string buildDragLog(int vpX, int vpY, int vpW, int vpH,
                    int x0, int y0, int x1, int y1, int steps = 20) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    double tDown = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tDown, x0, y0);
    double stepMs = 50.0;
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tDown + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    double tUp = tDown + (steps + 1) * stepMs;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        tUp, x1, y1);
    return log;
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

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

// Authoritative gizmo pivot: /api/toolpipe/eval runs the pipeline once and
// returns the evaluated ActionCenterPacket.center — the exact point the
// gizmo sits on, regardless of ACEN mode/submode. Using this instead of a
// re-derived centroid eliminates handle-projection misses when ACEN
// relocates the pivot (select/local modes).
Vec3 fetchActionCenter() {
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/toolpipe/eval"));
    auto c = j["actionCenter"]["center"].array;
    return Vec3(cast(float)c[0].floating, cast(float)c[1].floating,
                cast(float)c[2].floating);
}

JSONValue perfRead() {
    return parseJSON(cast(string)get(g_baseUrl ~ "/api/perf"));
}

struct ModelInfo { long vertexCount; long faceCount; }
ModelInfo modelInfo() {
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/model"));
    ModelInfo m;
    m.vertexCount = j["vertexCount"].integer;
    m.faceCount   = j["faceCount"].integer;
    return m;
}

Vec3 vertexPos(int idx) {
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/model"));
    auto v = j["vertices"].array[idx].array;
    return Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                cast(float)v[2].floating);
}

// ---------------------------------------------------------------------------
// Grid selection helpers (row-major (N+1)×(N+1), index(i,j) = i*(N+1)+j;
// i along Z, j along X, both spanning [-1, 1] — see mesh.d:makeGridPlane).
// ---------------------------------------------------------------------------

int gridIdx(int n, int i, int j) { return i * (n + 1) + j; }

// One vertex near the grid centre.
int[] selSingle(int n) {
    int c = n / 2;
    return [gridIdx(n, c, c)];
}

// A full row (a "loop"/ring across the plane): the centre Z-row.
int[] selRing(int n) {
    int i = n / 2;
    int[] r;
    foreach (j; 0 .. n + 1) r ~= gridIdx(n, i, j);
    return r;
}

// Half the verts: every vertex with i < (N+1)/2 (the lower-Z half).
int[] selHalf(int n) {
    int side = n + 1;
    int[] r;
    foreach (i; 0 .. side / 2)
        foreach (j; 0 .. side)
            r ~= gridIdx(n, i, j);
    return r;
}

// "whole" — empty selection ⇒ the whole mesh moves (universal transform
// rule, CLAUDE.md). We model it as NO selection call; the caller skips
// /api/select for whole.

// ---------------------------------------------------------------------------
// Matrix definition
// ---------------------------------------------------------------------------

enum Tool { move, rotate, scale }

struct PipeAttr { string stage, name, value; }

struct Case {
    string  name;       // e.g. "move/baseline", "rotate/falloff=radial"
    Tool    tool;
    string  selection;  // "whole" | "single" | "ring" | "half"
    PipeAttr[] attrs;   // pipe configuration applied on top of a clean reset
    string  note;       // human-readable axis varied
}

// Build the baseline + one-axis-at-a-time cases for a tool. The radius/size
// for linear & radial falloff is set RELATIVE to the [-1,1] mesh extent so
// the falloff weight actually varies across the selected verts (a radius far
// larger than the mesh, or zero, makes falloff a no-op and defeats the
// benchmark). The grid spans [-2 units] across; a radius/size of ~1.0 puts
// the falloff boundary mid-plane.
Case[] casesForTool(Tool t) {
    string tname = t.to!string;
    Case[] cs;

    // Baseline: falloff none, symmetry off, acen auto, snap off, whole mesh.
    cs ~= Case(tname ~ "/baseline", t, "whole", [], "baseline");

    // Falloff variations. linear/radial get an explicit size relative to the
    // mesh extent; element/screen auto-size to the selection on type switch.
    // Falloff with the WHOLE mesh + a mid-plane radius makes weights vary.
    cs ~= Case(tname ~ "/falloff=linear", t, "whole",
        [PipeAttr("falloff", "type", "linear"),
         PipeAttr("falloff", "start", "0,0,-1"),
         PipeAttr("falloff", "end",   "0,0,1")],
        "falloff=linear (start/end span the plane)");
    cs ~= Case(tname ~ "/falloff=radial", t, "whole",
        [PipeAttr("falloff", "type", "radial"),
         PipeAttr("falloff", "center", "0,0,0"),
         PipeAttr("falloff", "size",   "1,1,1")],
        "falloff=radial (r=1 mid-plane)");
    cs ~= Case(tname ~ "/falloff=element", t, "single",
        [PipeAttr("falloff", "type", "element"),
         PipeAttr("falloff", "dist", "1.0")],
        "falloff=element (range 1.0, single-vert anchor)");
    cs ~= Case(tname ~ "/falloff=screen", t, "whole",
        [PipeAttr("falloff", "type", "screen"),
         PipeAttr("falloff", "screenSize", "300")],
        "falloff=screen (300px)");

    // Symmetry X.
    cs ~= Case(tname ~ "/symmetry=X", t, "whole",
        [PipeAttr("symmetry", "enabled", "true"),
         PipeAttr("symmetry", "axis", "x")],
        "symmetry=X");

    // ACEN variations (selection / local). The whole-mesh baseline uses Auto;
    // selection/local need an actual selection so the centre differs.
    cs ~= Case(tname ~ "/acen=selection", t, "half",
        [PipeAttr("actionCenter", "mode", "select")],
        "acen=selection (half sel)");
    cs ~= Case(tname ~ "/acen=local", t, "half",
        [PipeAttr("actionCenter", "mode", "local")],
        "acen=local (half sel)");

    // Snap to grid.
    cs ~= Case(tname ~ "/snap=grid", t, "whole",
        [PipeAttr("snap", "enabled", "true"),
         PipeAttr("snap", "types", "grid")],
        "snap=grid");

    // Selection variations off the baseline config.
    cs ~= Case(tname ~ "/selection=single", t, "single", [], "selection=single");
    cs ~= Case(tname ~ "/selection=ring",   t, "ring",   [], "selection=ring");
    cs ~= Case(tname ~ "/selection=half",   t, "half",   [], "selection=half");

    return cs;
}

// ---------------------------------------------------------------------------
// Drag synthesis per tool (handle-projection recipe matching the drag tests)
// ---------------------------------------------------------------------------

struct Drag { int x0, y0, x1, y1; }

// Build the mouse-down + drag-end pixels for grabbing the right handle of
// each tool's gizmo, pivoted at `pivot`. Mirrors the recipes pinned by
// tests/test_tool_{move_plane,rotate_view_wholemesh,scale}_drag.d.
Drag dragFor(Tool t, Vec3 pivot, const ref Viewport vp) {
    final switch (t) {
        case Tool.move: {
            // XY plane circle: center + axisX*0.75*size + axisY*0.75*size,
            // normal Z (handler.d MoveHandler). Drag screen-down 60px.
            float size = gizmoSize(pivot, vp);
            Vec3 circle = Vec3(pivot.x + size * 0.75f, pivot.y + size * 0.75f, pivot.z);
            float cx, cy;
            if (!projectToWindow(circle, vp, cx, cy)) return Drag(0,0,0,0);
            return Drag(cast(int)cx, cast(int)cy, cast(int)cx, cast(int)cy + 60);
        }
        case Tool.rotate: {
            // View ring ~99px around the gizmo center; grab at +95px,
            // drag tangentially -70px (test_tool_rotate_view_wholemesh).
            float cx, cy;
            if (!projectToWindow(pivot, vp, cx, cy)) return Drag(0,0,0,0);
            int x0 = cast(int)(cx + 95);
            int y0 = cast(int)cy;
            return Drag(x0, y0, x0, y0 - 70);
        }
        case Tool.scale: {
            // X-arrow shaft: center+axisX*(size/7) → center+axisX*size.
            // Grab 70% along, drag ~80px in projected +X (test_tool_scale).
            float size = gizmoSize(pivot, vp);
            Vec3 start = Vec3(pivot.x + size / 7.0f, pivot.y, pivot.z);
            Vec3 end   = Vec3(pivot.x + size,        pivot.y, pivot.z);
            float sx1, sy1, sx2, sy2;
            if (!projectToWindow(start, vp, sx1, sy1)) return Drag(0,0,0,0);
            if (!projectToWindow(end,   vp, sx2, sy2)) return Drag(0,0,0,0);
            int x0 = cast(int)(sx1 + 0.7f * (sx2 - sx1));
            int y0 = cast(int)(sy1 + 0.7f * (sy2 - sy1));
            double sdx = sx2 - sx1, sdy = sy2 - sy1;
            double sLen = sqrt(sdx*sdx + sdy*sdy);
            if (sLen < 1.0) return Drag(0,0,0,0);
            int x1 = x0 + cast(int)(80.0 * sdx / sLen);
            int y1 = y0 + cast(int)(80.0 * sdy / sLen);
            return Drag(x0, y0, x1, y1);
        }
    }
}

// ---------------------------------------------------------------------------
// Per-case execution
// ---------------------------------------------------------------------------

enum CaseStatus { OK, SKIP, ERROR }

struct CaseResult {
    string     name;
    string     note;
    CaseStatus status;
    string     detail;
    // medians/p95 across R repeats, in microseconds.
    double     kernelMedianUs, kernelP95Us;
    double     pipeMedianUs;
    double     pipeSymmetryMedianUs;   // pipe.symmetry stage cost (for I2)
    string     dominantStage;
    long       vertsTouched;     // sum from the last repeat
    long       kernelInternalP95Ns;  // /api/perf's own per-sample p95
    JSONValue  lastBreakdown;    // full /api/perf from the last repeat
}

// Apply the selection (or clear it for "whole").
bool applySelection(ref Case c, int n) {
    if (c.selection == "whole") {
        // Empty selection ⇒ whole mesh. Clear any prior selection.
        return selectVertices([]);
    }
    int[] idx;
    if      (c.selection == "single") idx = selSingle(n);
    else if (c.selection == "ring")   idx = selRing(n);
    else if (c.selection == "half")   idx = selHalf(n);
    else return false;
    return selectVertices(idx);
}

// Run ONE drag, return the /api/perf breakdown after it. Throws on a
// play-events failure. Re-fetches the LIVE action-centre pivot immediately
// before building the drag, so a prior drag that relocated the pivot
// (ACEN select/local click-away-relocate) doesn't leave subsequent drags
// projecting onto a stale gizmo position.
JSONValue runOneDrag(Tool t, const ref Viewport vp, CameraState cam) {
    Vec3 pivot = fetchActionCenter();
    Drag d = dragFor(t, pivot, vp);
    if (d.x0 == 0 && d.y0 == 0 && d.x1 == 0 && d.y1 == 0)
        throw new Exception("handle projected off-camera");
    string log = buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
                              d.x0, d.y0, d.x1, d.y1, 20);
    perfReset();
    playAndWait(log);
    return perfRead();
}

double medianOf(double[] xs) {
    if (xs.length == 0) return 0;
    auto s = xs.dup; s.sort();
    return s[s.length / 2];
}
double p95Of(double[] xs) {
    if (xs.length == 0) return 0;
    auto s = xs.dup; s.sort();
    size_t idx = cast(size_t)((s.length - 1) * 95 / 100);
    return s[idx];
}

// From a /api/perf breakdown, the dominant pipeline stage by sum_ns.
string dominantStage(JSONValue perf) {
    static immutable string[] stages = [
        "pipeSymmetry", "pipeSnap", "pipeAcen", "pipeAxis", "pipeFalloff",
        "kernelApply", "symmetryMirror", "cacheInvalidate", "gpuUpload",
    ];
    string best = "-";
    long bestNs = -1;
    foreach (s; stages) {
        if (s !in perf) continue;
        long ns = perf[s]["sum_ns"].integer;
        if (ns > bestNs) { bestNs = ns; best = s; }
    }
    return best;
}

long sumNs(JSONValue perf, string cat) {
    return (cat in perf) ? perf[cat]["sum_ns"].integer : 0;
}

CaseResult runCase(ref Case c, int n, string meshType, int repeats) {
    CaseResult res;
    res.name = c.name;
    res.note = c.note;

    // 1. fresh mesh
    resetMesh(meshType, n);

    // 2. selection
    if (!applySelection(c, n)) {
        res.status = CaseStatus.ERROR;
        res.detail = "selection failed";
        return res;
    }

    // 3. tool
    if (!script("tool.set " ~ c.tool.to!string)) {
        res.status = CaseStatus.ERROR;
        res.detail = "tool.set failed";
        return res;
    }

    // 4. pipe config. The argstring parser the /api/script command bridge
    // uses rejects bare commas (vec3 values like "0,0,0"), so the value is
    // always double-quoted — harmless for scalar values (radial/true/grid).
    foreach (a; c.attrs) {
        if (!script(format(`tool.pipe.attr %s %s "%s"`, a.stage, a.name, a.value))) {
            res.status = CaseStatus.SKIP;
            res.detail = format("pipe attr rejected: %s %s %s",
                                a.stage, a.name, a.value);
            return res;
        }
    }

    auto cam = fetchCamera();
    auto vp  = viewportFromCamera(cam);

    // Warmup drag (discarded). Verify geometry actually moves. runOneDrag
    // re-fetches the live evaluated gizmo pivot (authoritative under any
    // ACEN mode) so the handle projection lands on the gizmo.
    Vec3 probeBefore = vertexPos(0);
    try {
        runOneDrag(c.tool, vp, cam);
    } catch (Exception e) {
        res.status = CaseStatus.ERROR;
        res.detail = "warmup drag: " ~ e.msg;
        return res;
    }
    Vec3 probeAfter = vertexPos(0);
    // For a partial selection v0 may legitimately not move; check ANY motion
    // via the perf vertsTouched counter from the warmup instead.
    auto warmupPerf = perfRead();
    long warmTouched = ("vertsTouched" in warmupPerf)
        ? warmupPerf["vertsTouched"]["sum"].integer : 0;
    bool moved = warmTouched > 0;
    if (!moved) {
        // Fall back to a position check on a vertex inside the selection.
        Vec3 d = probeAfter - probeBefore;
        moved = sqrt(dot(d, d)) > 1e-5f;
    }
    if (!moved) {
        res.status = CaseStatus.ERROR;
        res.detail = "drag moved no geometry (vertsTouched=0) — handle miss?";
        return res;
    }

    // R measured repeats.
    double[] kernelTot;   // total kernelApply ns per drag (sum across frames)
    double[] pipeTot;     // total pipeTotal ns per drag
    double[] pipeSymTot;  // total pipeSymmetry ns per drag
    JSONValue last;
    foreach (r; 0 .. repeats) {
        JSONValue perf;
        try {
            perf = runOneDrag(c.tool, vp, cam);
        } catch (Exception e) {
            res.status = CaseStatus.ERROR;
            res.detail = format("repeat %d drag: %s", r, e.msg);
            return res;
        }
        kernelTot  ~= cast(double)sumNs(perf, "kernelApply")  / 1000.0;
        pipeTot    ~= cast(double)sumNs(perf, "pipeTotal")    / 1000.0;
        pipeSymTot ~= cast(double)sumNs(perf, "pipeSymmetry") / 1000.0;
        last = perf;
    }

    res.status = CaseStatus.OK;
    res.kernelMedianUs       = medianOf(kernelTot);
    res.kernelP95Us          = p95Of(kernelTot);
    res.pipeMedianUs         = medianOf(pipeTot);
    res.pipeSymmetryMedianUs = medianOf(pipeSymTot);
    res.dominantStage  = dominantStage(last);
    res.vertsTouched   = ("vertsTouched" in last)
        ? last["vertsTouched"]["sum"].integer : 0;
    res.kernelInternalP95Ns = ("kernelApply" in last)
        ? last["kernelApply"]["p95_ns"].integer : 0;
    res.lastBreakdown = last;
    return res;
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

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

void printTable(CaseResult[] results) {
    writeln();
    writeln("=== perf results ===");
    writefln("%-28s %12s %12s %12s %-16s %10s",
             "case", "kApply med", "kApply p95", "pipe med", "dominant", "verts");
    writefln("%-28s %12s %12s %12s %-16s %10s",
             "", "(us)", "(us)", "(us)", "stage", "touched");
    writeln("".replicate(96));
    foreach (r; results) {
        final switch (r.status) {
            case CaseStatus.OK:
                writefln("%-28s %12.2f %12.2f %12.2f %-16s %10d",
                         r.name, r.kernelMedianUs, r.kernelP95Us,
                         r.pipeMedianUs, r.dominantStage, r.vertsTouched);
                break;
            case CaseStatus.SKIP:
                writefln("%-28s  SKIP  %s", r.name, r.detail);
                break;
            case CaseStatus.ERROR:
                writefln("%-28s  ERROR %s", r.name, r.detail);
                break;
        }
    }
    int ok = 0, skip = 0, err = 0;
    foreach (r; results) final switch (r.status) {
        case CaseStatus.OK:    ok++;   break;
        case CaseStatus.SKIP:  skip++; break;
        case CaseStatus.ERROR: err++;  break;
    }
    writeln("".replicate(96));
    writefln("Totals: OK=%d  SKIP=%d  ERROR=%d  (of %d cases)",
             ok, skip, err, results.length);
}

string replicate(string s, size_t n) {
    auto a = appender!string();
    foreach (_; 0 .. n) a.put(s);
    return a.data;
}

void writeResultsJson(string path, string meshType, int n, long faceCount,
                      string viewport, int repeats, CaseResult[] results) {
    auto a = appender!string();
    a.put("{\n");
    a.put(format(`  "buildType": "perf",` ~ "\n"));
    a.put(format(`  "compiler": "ldc2 1.42.0",` ~ "\n"));
    a.put(format(`  "meshType": "%s",` ~ "\n", meshType));
    a.put(format(`  "n": %d,` ~ "\n", n));
    a.put(format(`  "faceCount": %d,` ~ "\n", faceCount));
    a.put(format(`  "viewport": "%s",` ~ "\n", viewport));
    a.put(format(`  "repeats": %d,` ~ "\n", repeats));
    // Optional reproducibility stamp from the environment (no wall-clock
    // from inside D, per the plan — determinism).
    a.put(format(`  "stamp": "%s",` ~ "\n",
                 environment.get("VIBE3D_PERF_STAMP", "")));
    a.put(`  "cases": [` ~ "\n");
    foreach (i, r; results) {
        a.put("    {\n");
        a.put(format(`      "name": "%s",` ~ "\n", r.name));
        a.put(format(`      "note": "%s",` ~ "\n", r.note));
        a.put(format(`      "status": "%s",` ~ "\n", r.status.to!string));
        if (r.status == CaseStatus.OK) {
            a.put(format(`      "kernelMedianUs": %.3f,` ~ "\n", r.kernelMedianUs));
            a.put(format(`      "kernelP95Us": %.3f,` ~ "\n", r.kernelP95Us));
            a.put(format(`      "pipeMedianUs": %.3f,` ~ "\n", r.pipeMedianUs));
            a.put(format(`      "dominantStage": "%s",` ~ "\n", r.dominantStage));
            a.put(format(`      "vertsTouched": %d,` ~ "\n", r.vertsTouched));
            a.put(format(`      "kernelInternalP95Ns": %d,` ~ "\n",
                         r.kernelInternalP95Ns));
            a.put(`      "breakdown": ` ~ r.lastBreakdown.toString() ~ "\n");
        } else {
            a.put(format(`      "detail": "%s"` ~ "\n",
                         r.detail.replaceQuotes));
        }
        a.put(i + 1 < results.length ? "    },\n" : "    }\n");
    }
    a.put("  ]\n}\n");
    std.file.write(path, a.data);
}

string replaceQuotes(string s) {
    auto a = appender!string();
    foreach (ch; s) {
        if (ch == '"') a.put("\\\"");
        else a.put(ch);
    }
    return a.data;
}

// ---------------------------------------------------------------------------
// Phase 5 — regression detection (two levels: absolute baseline + relative
// invariants). See doc/perf_harness_plan.md §7.
//
//   * ABSOLUTE  — compare each case's kernelApply/pipeTotal median against a
//                 captured baseline.json. Machine-bound, so it is GATED by a
//                 build/mesh/viewport-match guard: a baseline captured on a
//                 different config is NOT compared (warn + skip), falling back
//                 to relative invariants only.
//   * RELATIVE  — same-run ratios that do not drift with hardware. These run
//                 ALWAYS (no baseline / mismatched machine included). Generous
//                 thresholds: gross-regression guards, not tight benchmarks.
// ---------------------------------------------------------------------------

// Baseline.json shares the same header shape the runner already writes for
// results.json, so a header mismatch can be detected field-by-field.
struct RunHeader {
    string buildType, compiler, meshType, viewport;
    int    n;
    long   faceCount;
    int    repeats;
}

RunHeader currentHeader(string meshType, int n, long faceCount,
                        string viewport, int repeats) {
    return RunHeader("perf", "ldc2 1.42.0", meshType, viewport,
                     n, faceCount, repeats);
}

// One per-case row stored in baseline.json.
struct BaselineCase {
    string name;
    double kernelMedianUs, kernelP95Us, pipeMedianUs;
    string dominantStage;
    long   vertsTouched;
}

void writeBaselineJson(string path, RunHeader h, CaseResult[] results) {
    auto a = appender!string();
    a.put("{\n");
    a.put(format(`  "buildType": "%s",` ~ "\n", h.buildType));
    a.put(format(`  "compiler": "%s",` ~ "\n", h.compiler));
    a.put(format(`  "meshType": "%s",` ~ "\n", h.meshType));
    a.put(format(`  "n": %d,` ~ "\n", h.n));
    a.put(format(`  "faceCount": %d,` ~ "\n", h.faceCount));
    a.put(format(`  "viewport": "%s",` ~ "\n", h.viewport));
    a.put(format(`  "repeats": %d,` ~ "\n", h.repeats));
    a.put(`  "cases": [` ~ "\n");
    bool first = true;
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;  // only OK cases are baselined
        if (!first) a.put(",\n");
        first = false;
        a.put("    {\n");
        a.put(format(`      "name": "%s",` ~ "\n", r.name));
        a.put(format(`      "kernelMedianUs": %.3f,` ~ "\n", r.kernelMedianUs));
        a.put(format(`      "kernelP95Us": %.3f,` ~ "\n", r.kernelP95Us));
        a.put(format(`      "pipeMedianUs": %.3f,` ~ "\n", r.pipeMedianUs));
        a.put(format(`      "dominantStage": "%s",` ~ "\n", r.dominantStage));
        a.put(format(`      "vertsTouched": %d` ~ "\n", r.vertsTouched));
        a.put("    }");
    }
    a.put("\n  ]\n}\n");
    std.file.write(path, a.data);
}

struct Baseline {
    RunHeader header;
    BaselineCase[string] byName;   // keyed by case name
}

Baseline loadBaseline(string path) {
    Baseline b;
    auto j = parseJSON(cast(string)std.file.read(path));
    b.header.buildType = j["buildType"].str;
    b.header.compiler  = j["compiler"].str;
    b.header.meshType  = j["meshType"].str;
    b.header.viewport  = j["viewport"].str;
    b.header.n         = cast(int)j["n"].integer;
    b.header.faceCount = j["faceCount"].integer;
    b.header.repeats   = cast(int)j["repeats"].integer;
    foreach (cv; j["cases"].array) {
        BaselineCase bc;
        bc.name           = cv["name"].str;
        bc.kernelMedianUs = cv["kernelMedianUs"].floating;
        bc.kernelP95Us    = cv["kernelP95Us"].floating;
        bc.pipeMedianUs   = cv["pipeMedianUs"].floating;
        bc.dominantStage  = cv["dominantStage"].str;
        bc.vertsTouched   = cv["vertsTouched"].integer;
        b.byName[bc.name] = bc;
    }
    return b;
}

// The build-mismatch guard. Absolute comparison is only meaningful when the
// baseline was captured on the SAME build + mesh + viewport. Returns a
// non-empty reason string if the configs differ (⇒ skip absolute).
string headerMismatch(RunHeader baseH, RunHeader curH) {
    if (baseH.buildType != curH.buildType)
        return format("buildType %s vs %s", baseH.buildType, curH.buildType);
    if (baseH.compiler != curH.compiler)
        return format("compiler %s vs %s", baseH.compiler, curH.compiler);
    if (baseH.meshType != curH.meshType)
        return format("meshType %s vs %s", baseH.meshType, curH.meshType);
    if (baseH.n != curH.n)
        return format("n %d vs %d", baseH.n, curH.n);
    if (baseH.viewport != curH.viewport)
        return format("viewport %s vs %s", baseH.viewport, curH.viewport);
    return "";
}

// Find an OK case result by exact name.
CaseResult* findCase(CaseResult[] results, string name) {
    foreach (ref r; results)
        if (r.name == name && r.status == CaseStatus.OK) return &r;
    return null;
}

// ----- Relative invariant thresholds -----------------------------------
//
// Tuned from observed n=64 ratios with generous margin (gross-regression
// guards, not tight benchmarks). Observed (worst tool) ⇒ chosen K:
//   I1 falloff radial / baseline kernelApply:  ~1.95×   ⇒ K1 = 6.0
//   I2 pipeSymmetry sum when symmetry OFF:     ≤ ~7.5µs ⇒ K2 = 200µs (abs)
//   I3 symmetry=X / baseline kernelApply:      ~1.86×   ⇒ K3 = 4.0
//   I4 baseline pipeTotal / kernelApply:       ~1.19×   ⇒ K4 = 4.0
enum double K1_FALLOFF        = 6.0;
enum double K2_SYM_OFF_US     = 200.0;   // absolute µs ceiling, per case
enum double K3_SYMMETRY       = 4.0;
enum double K4_PIPE_OVERHEAD  = 4.0;

struct Invariant {
    string id;        // "I1", "I2", ...
    string desc;      // human-readable
    bool   pass;
    string detail;    // actual ratio vs threshold
}

// Run the relative invariants over the results. Per-tool where applicable.
Invariant[] checkInvariants(CaseResult[] results) {
    Invariant[] inv;

    // I1 — falloff loop bounded: radial kernelApply ≤ K1 × baseline (per tool).
    foreach (tool; ["move", "rotate", "scale"]) {
        auto base = findCase(results, tool ~ "/baseline");
        auto rad  = findCase(results, tool ~ "/falloff=radial");
        if (base is null || rad is null || base.kernelMedianUs <= 0) continue;
        double ratio = rad.kernelMedianUs / base.kernelMedianUs;
        bool ok = ratio <= K1_FALLOFF;
        inv ~= Invariant("I1", format("%s falloff=radial kernelApply ≤ %.1f× baseline",
                                      tool, K1_FALLOFF), ok,
                         format("ratio=%.2f× (%.1f/%.1f µs) threshold %.1f×",
                                ratio, rad.kernelMedianUs, base.kernelMedianUs,
                                K1_FALLOFF));
    }

    // I2 — symmetry disabled is free: pipeSymmetry sum ≈ 0 in every case whose
    // name is NOT symmetry=X (i.e. symmetry OFF). Catches the SymmetryStage
    // running/allocating (rebuildPairing O(n log n)) when disabled.
    {
        double worst = 0;
        string worstCase = "-";
        foreach (r; results) {
            if (r.status != CaseStatus.OK) continue;
            if (r.name.canFind("symmetry=X")) continue;   // symmetry ON
            if (r.pipeSymmetryMedianUs > worst) {
                worst = r.pipeSymmetryMedianUs;
                worstCase = r.name;
            }
        }
        bool ok = worst <= K2_SYM_OFF_US;
        inv ~= Invariant("I2",
            format("symmetry OFF ⇒ pipeSymmetry ≤ %.0f µs", K2_SYM_OFF_US), ok,
            format("worst=%.2f µs (%s) threshold %.0f µs",
                   worst, worstCase, K2_SYM_OFF_US));
    }

    // I3 — symmetry mirror bounded: symmetry=X kernelApply ≤ K3 × baseline
    // (per tool). Mirroring at most ~doubles the moving set.
    foreach (tool; ["move", "rotate", "scale"]) {
        auto base = findCase(results, tool ~ "/baseline");
        auto sym  = findCase(results, tool ~ "/symmetry=X");
        if (base is null || sym is null || base.kernelMedianUs <= 0) continue;
        double ratio = sym.kernelMedianUs / base.kernelMedianUs;
        bool ok = ratio <= K3_SYMMETRY;
        inv ~= Invariant("I3", format("%s symmetry=X kernelApply ≤ %.1f× baseline",
                                      tool, K3_SYMMETRY), ok,
                         format("ratio=%.2f× (%.1f/%.1f µs) threshold %.1f×",
                                ratio, sym.kernelMedianUs, base.kernelMedianUs,
                                K3_SYMMETRY));
    }

    // I4 — pipeline overhead bounded: baseline pipeTotal ≤ K4 × kernelApply
    // (per tool). Catches per-frame pipeline cost dominating the transform.
    foreach (tool; ["move", "rotate", "scale"]) {
        auto base = findCase(results, tool ~ "/baseline");
        if (base is null || base.kernelMedianUs <= 0) continue;
        double ratio = base.pipeMedianUs / base.kernelMedianUs;
        bool ok = ratio <= K4_PIPE_OVERHEAD;
        inv ~= Invariant("I4", format("%s baseline pipeTotal ≤ %.1f× kernelApply",
                                      tool, K4_PIPE_OVERHEAD), ok,
                         format("ratio=%.2f× (%.1f/%.1f µs) threshold %.1f×",
                                ratio, base.pipeMedianUs, base.kernelMedianUs,
                                K4_PIPE_OVERHEAD));
    }

    return inv;
}

struct AbsRegression {
    string name;
    string metric;     // "kernelApply" | "pipeTotal"
    double baseUs, curUs, growth;   // growth = cur/base - 1
}

// Below this baseline median (µs), a metric is in the timing noise floor and a
// percentage-growth comparison is meaningless (e.g. selection=single touches
// ~20 verts ⇒ kernelApply 0.1µs, where +0.2µs reads as +200%). Real
// regressions land on the heavy cases (kernelApply ~550µs+), far above this.
enum double ABS_NOISE_FLOOR_US = 50.0;

// Compare current results to a baseline. Flags a regression when the
// kernelApply median grows by more than `tolerance` (e.g. 0.30 ⇒ +30%).
//
// kernelApply is the only metric compared absolutely: it is the actual
// transform cost and is stable run-to-run (observed full-matrix spread on the
// heavy cases ~1.02–1.06×, well under +30%). pipeTotal is deliberately NOT
// compared absolutely — it is dominated by the per-frame ActionCenter pivot
// recompute (pipeAcen) which jitters 40–90% run-to-run and is not a transform
// regression; pipeline overhead is instead watched RELATIVELY by invariant I4
// (pipeTotal / kernelApply ratio), which is hardware-stable.
//
// Cases whose baseline kernelApply is below ABS_NOISE_FLOOR_US are skipped:
// they touch a handful of verts (selection=single/falloff=element ⇒ ~0.1µs)
// and a percentage comparison there is pure timer granularity. The slow
// acen=local case is kernelApply-cheap (its cost is pipeAcen, not compared) so
// it never trips an invariant; it still appears in results/baseline as-is.
AbsRegression[] checkAbsolute(CaseResult[] results, Baseline base,
                              double tolerance) {
    AbsRegression[] regs;
    foreach (r; results) {
        if (r.status != CaseStatus.OK) continue;
        // snap cases recompute WHICH verts land on grid points each run, so
        // their moving-set size (and thus kernelApply) varies run-to-run and is
        // not a stable absolute metric — skip them (snap is still in the table).
        if (r.name.canFind("snap=")) continue;
        auto p = r.name in base.byName;
        if (p is null) continue;   // new case absent from baseline — not a regression
        if (p.kernelMedianUs < ABS_NOISE_FLOOR_US) continue;  // noise floor
        double g = r.kernelMedianUs / p.kernelMedianUs - 1.0;
        if (g > tolerance)
            regs ~= AbsRegression(r.name, "kernelApply",
                                  p.kernelMedianUs, r.kernelMedianUs, g);
    }
    return regs;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(string[] args) {
    g_repoRoot = buildNormalizedPath(
        absolutePath(buildPath(__FILE_FULL_PATH__.dirName, "..", "..")));

    bool noBuild = false;
    bool keep    = false;
    int  n       = 316;        // ~99856 faces
    int  meshSizeAlias = -1;
    int  subdivLevels  = -1;
    int  repeats = 5;
    ushort port  = 8088;
    string viewport = "1280x960";
    bool   updateBaseline = false;
    bool   noAbsolute     = false;   // skip absolute comparison (invariants only)
    double tolerance      = 0.30;    // absolute regression threshold (+30%)

    auto helpInfo = getopt(args,
        config.passThrough,
        "no-build",  "skip the dub build",                 &noBuild,
        "keep",      "leave vibe3d running after the run",  &keep,
        "n",         "grid resolution N (default 316 → ~100K faces)", &n,
        "mesh-size", "alias for --n",                        &meshSizeAlias,
        "subdivcube","use subdivideCube(levels) instead of grid", &subdivLevels,
        "repeats",   "measured drags per case (default 5)",  &repeats,
        "http-port", "HTTP port (default 8088)",             &port,
        "viewport",  "fixed viewport WxH (default 1280x960)", &viewport,
        "update-baseline", "write tools/perf/baseline.json from this run", &updateBaseline,
        "no-absolute",     "skip absolute baseline comparison (relative invariants only)", &noAbsolute,
        "tolerance",       "absolute-regression threshold as a fraction (default 0.30 = +30%)", &tolerance);

    if (helpInfo.helpWanted) {
        writeln("usage: ./run.d [options] [case-name-substring...]");
        foreach (o; helpInfo.options)
            writefln("  %-14s %s", o.optLong, o.help);
        return 0;
    }

    if (meshSizeAlias >= 0) n = meshSizeAlias;
    string meshType = "grid";
    int meshParam = n;
    if (subdivLevels >= 0) { meshType = "subdivcube"; meshParam = subdivLevels; }

    string[] requested = args[1 .. $];

    g_keep = keep;
    g_baseUrl = format("http://localhost:%d", port);

    signal(SIGINT,  &onSignal);
    signal(SIGTERM, &onSignal);
    scope(exit) teardown();

    if (!noBuild && !dubBuildPerf()) return 1;

    // Build the matrix.
    Case[] allCases;
    foreach (t; [Tool.move, Tool.rotate, Tool.scale])
        allCases ~= casesForTool(t);

    Case[] cases;
    foreach (c; allCases) {
        bool keepIt = requested.length == 0;
        foreach (req; requested) if (c.name.canFind(req)) keepIt = true;
        if (keepIt) cases ~= c;
    }
    if (cases.length == 0) {
        writeln("no cases matched");
        return 0;
    }

    killStaleVibe();
    string logPath = "/tmp/vibe3d_perf.log";
    writefln("Launching vibe3d --test --perf --http-port %d --viewport %s ...",
             port, viewport);
    if (!launchVibe(port, viewport, logPath)) return 1;
    writeln("  vibe3d is up");

    // Confirm the mesh builds + report face count.
    resetMesh(meshType, meshParam);
    auto mi = modelInfo();
    writefln("Mesh: %s param=%d → %d verts, %d faces",
             meshType, meshParam, mi.vertexCount, mi.faceCount);
    writefln("Repeats per case: %d (+1 warmup, discarded)", repeats);

    CaseResult[] results;
    foreach (c; cases) {
        write("  running ", c.name, " ... ");
        stdout.flush();
        auto r = runCase(c, meshParam, meshType, repeats);
        final switch (r.status) {
            case CaseStatus.OK:    writeln("OK");                  break;
            case CaseStatus.SKIP:  writeln("SKIP (", r.detail, ")"); break;
            case CaseStatus.ERROR: writeln("ERROR (", r.detail, ")"); break;
        }
        results ~= r;
    }

    printTable(results);

    string outPath = buildPath(g_repoRoot, "tools", "perf", "results.json");
    writeResultsJson(outPath, meshType, meshParam, mi.faceCount,
                     viewport, repeats, results);
    writeln("\nWrote ", outPath);

    // -------------------------------------------------------------------
    // Phase 5 — regression detection.
    // -------------------------------------------------------------------
    auto curHeader = currentHeader(meshType, meshParam, mi.faceCount,
                                   viewport, repeats);
    string baselinePath = buildPath(g_repoRoot, "tools", "perf", "baseline.json");

    if (updateBaseline) {
        writeBaselineJson(baselinePath, curHeader, results);
        writeln("Wrote ", baselinePath, " (baseline updated from this run)");
        // An --update-baseline run still reports invariants below but does
        // not perform an absolute comparison against the freshly-written file.
        noAbsolute = true;
    }

    int failures = 0;

    // 1. Relative invariants — ALWAYS run (machine-stable).
    writeln();
    writeln("=== relative invariants (machine-stable) ===");
    auto invs = checkInvariants(results);
    int invFail = 0;
    foreach (iv; invs) {
        writefln("  [%s] %-4s %-52s  %s",
                 iv.pass ? "PASS" : "FAIL", iv.id, iv.desc, iv.detail);
        if (!iv.pass) { invFail++; failures++; }
    }
    if (invs.length == 0)
        writeln("  (no invariants applicable — no OK baseline cases)");

    // 2. Absolute baseline comparison — gated by build-match guard.
    writeln();
    writeln("=== absolute baseline comparison ===");
    int absFail = 0;
    if (noAbsolute && !updateBaseline) {
        writeln("  skipped (--no-absolute)");
    } else if (updateBaseline) {
        writeln("  skipped (baseline was just written by --update-baseline)");
    } else if (!exists(baselinePath)) {
        writeln("  no baseline (", baselinePath, " absent) — run with",
                " --update-baseline to capture one");
    } else {
        auto base = loadBaseline(baselinePath);
        string mismatch = headerMismatch(base.header, curHeader);
        if (mismatch.length > 0) {
            writefln("  build mismatch — skipping absolute comparison: %s",
                     mismatch);
            writefln("  baseline was captured on {buildType=%s, compiler=%s," ~
                     " meshType=%s, n=%d, viewport=%s}; current run is" ~
                     " {buildType=%s, compiler=%s, meshType=%s, n=%d," ~
                     " viewport=%s} — relative invariants only.",
                     base.header.buildType, base.header.compiler,
                     base.header.meshType, base.header.n, base.header.viewport,
                     curHeader.buildType, curHeader.compiler,
                     curHeader.meshType, curHeader.n, curHeader.viewport);
        } else {
            auto regs = checkAbsolute(results, base, tolerance);
            if (regs.length == 0) {
                writefln("  no regressions (tolerance +%.0f%%, %d cases" ~
                         " compared)", tolerance * 100, base.byName.length);
            } else {
                foreach (rg; regs) {
                    writefln("  [FAIL] %-28s %-12s %+.0f%%  (%.1f → %.1f µs)",
                             rg.name, rg.metric, rg.growth * 100,
                             rg.baseUs, rg.curUs);
                    absFail++;
                    failures++;
                }
            }
        }
    }

    // 3. Final verdict.
    writeln();
    writeln("=== verdict ===");
    writefln("  relative invariants: %d/%d passed", invs.length - invFail,
             invs.length);
    if (absFail > 0)
        writefln("  absolute regressions: %d", absFail);
    writeln(failures == 0 ? "  OVERALL: PASS" : "  OVERALL: FAIL");

    return failures == 0 ? 0 : failures;
}
