module lib.drag;
// Minimal vec/matrix + projection + drag/eventlog synthesis (formerly a
// "self-contained copy of tests/drag_helpers.d" living inline in run.d —
// see D1 in doc/perf_tooling_consolidation_plan.md for why this stays a
// SEPARATE copy from tests/drag_helpers.d rather than a shared import:
// tools/perf/ and tests/ are disjoint compilation universes (rdmd vs.
// run_test.d's dmd static-lib build), so true dedup would require touching
// the shared test-compile path — out of scope for this task).
//
// Extracted from tools/perf/run.d as part of task 0197 (perf tooling
// consolidation) — pure code-motion, no behavior change. This IS the
// extraction that makes run.d's inline drag/projection copy die (task's
// literal ask): run.d now has zero inline drag/projection math, it imports
// this module.

import std.format : format;
import std.json   : parseJSON;
import std.math   : sqrt, tan, PI;
import std.net.curl : get;

import lib.http : g_baseUrl;

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

Vec3 vertexPos(int idx) {
    auto j = parseJSON(cast(string)get(g_baseUrl ~ "/api/model"));
    auto v = j["vertices"].array[idx].array;
    return Vec3(cast(float)v[0].floating, cast(float)v[1].floating,
                cast(float)v[2].floating);
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

// KMOD_LALT (SDL2 SDL_Keymod bit layout: LALT=0x0100, RALT=0x0200,
// ALT=LALT|RALT=0x0300). `(mods & KMOD_ALT) != 0` in app.d's button-down
// handler only tests the bit is set, so LALT alone is sufficient to drive
// DragMode.Orbit. EventPlayer.tick() calls SDL_SetModState(entry.mod) for
// every mouse event before dispatch (eventlog.d), so a recorded "mod" value
// reliably reproduces a real modifier-held drag under replay.
enum int SDL_KMOD_LALT = 0x0100;

// Alt+LMB orbit drag (view.d DragMode.Orbit) — camera-only, mesh untouched.
// Used by the `orbit-dense` frame scenario (tools/perf/run.d frames) to
// exercise the draw path without any mesh-cache work (F-I1).
string buildOrbitLog(int vpX, int vpY, int vpW, int vpH,
                     int x0, int y0, int x1, int y1, int steps = 60) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    double tDown = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}` ~ "\n",
        tDown, x0, y0, SDL_KMOD_LALT);
    double stepMs = 20.0;
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tDown + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":%d}` ~ "\n",
            t, x, y, x - lastX, y - lastY, SDL_KMOD_LALT);
        lastX = x; lastY = y;
    }
    double tUp = tDown + (steps + 1) * stepMs;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%d}` ~ "\n",
        tUp, x1, y1, SDL_KMOD_LALT);
    return log;
}

// Plain mouse sweep, NO button — drives per-frame pickVertices/pickEdges/
// pickFaces hover resolution. Used by the `hover-sweep` frame scenario.
string buildHoverLog(int vpX, int vpY, int vpW, int vpH,
                     int x0, int y0, int x1, int y1, int steps = 80) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);
    double stepMs = 20.0;
    int lastX = x0, lastY = y0;
    foreach (i; 0 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = 50.0 + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":0,"mod":0}` ~ "\n",
            t, x, y, x - lastX, y - lastY);
        lastX = x; lastY = y;
    }
    return log;
}

// ---------------------------------------------------------------------------
// Grid selection helpers (row-major (N+1)×(N+1), index(i,j) = i*(N+1)+j;
// i along Z, j along X, both spanning [-1, 1] — see mesh.d:makeGridPlane).
// ---------------------------------------------------------------------------

int gridIdx(int n, int i, int j) { return i * (n + 1) + j; }

// Grid faces are row-major: face(i,j) = i*n + j, for i,j in 0..n (n×n
// faces). Mirrors selHalf's lower-half style but in face space.
int gridFace(int n, int i, int j) { return i * n + j; }
