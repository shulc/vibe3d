module drag_helpers;

// Shared helpers for interactive-drag tests (test_tool_*_drag.d).
//
// What this module gives a test:
//   1. Fetch /api/camera, reconstruct the same Viewport vibe3d uses
//      (view + projection matrices).
//   2. Project a world point to window pixels — same formula as
//      source/math.d:projectToWindow.
//   3. Build a JSON Lines event log that fakes a mouse-down + N motion
//      events + mouse-up sequence, ready for POST /api/play-events.
//
// The math is duplicated from source/math.d (lookAt, perspectiveMatrix,
// gizmoSize) because the test binaries compile standalone, without
// pulling source/math.d / source/view.d / source/handler.d. Keeping the
// duplicate small (<150 LOC) is cheaper than the alternative of dragging
// vibe3d's source tree into every test's compilation unit.

import http_client : testBaseUrl, waitPlaybackProcessed;
import std.json;
import std.math : sin, cos, tan, sqrt, PI;
import std.format : format;
import std.net.curl : get, post;
import core.thread : Thread;
import core.time   : dur;

struct Vec3 {
    float x = 0, y = 0, z = 0;
    Vec3 opBinary(string op)(Vec3 b) const {
        static if (op == "+") return Vec3(x+b.x, y+b.y, z+b.z);
        else static if (op == "-") return Vec3(x-b.x, y-b.y, z-b.z);
        else static assert(0, "unsupported op " ~ op);
    }
    Vec3 opBinary(string op)(float s) const if (op == "*" || op == "/") {
        static if (op == "*") return Vec3(x*s, y*s, z*s);
        else                  return Vec3(x/s, y/s, z/s);
    }
}

float dot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }

Vec3 cross(Vec3 a, Vec3 b) {
    return Vec3(a.y*b.z - a.z*b.y,
                a.z*b.x - a.x*b.z,
                a.x*b.y - a.y*b.x);
}

Vec3 normalize(Vec3 v) {
    float L = sqrt(dot(v, v));
    return L > 1e-9f ? Vec3(v.x/L, v.y/L, v.z/L) : Vec3(0, 0, 0);
}

// Column-major 4×4 matrix, matching source/math.d.
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
        fnum/aspect, 0,    0,                  0,
        0,           fnum, 0,                  0,
        0,           0,    (far+near)/nf,     -1,
        0,           0,    2*far*near/nf,      0,
    ];
}

struct Viewport {
    float[16] view;
    float[16] proj;
    int width, height, x, y;
    Vec3 eye;
}

struct CameraState {
    Vec3 eye, focus;
    int width, height, vpX, vpY;
}

CameraState fetchCamera(string baseUrl = testBaseUrl()) {
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/camera"));
    CameraState c;
    c.eye    = Vec3(cast(float)j["eye"]["x"].floating,
                    cast(float)j["eye"]["y"].floating,
                    cast(float)j["eye"]["z"].floating);
    c.focus  = Vec3(cast(float)j["focus"]["x"].floating,
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
                                  cast(float)c.width / c.height,
                                  0.001f, 100.0f);
    vp.width  = c.width;
    vp.height = c.height;
    vp.x      = c.vpX;
    vp.y      = c.vpY;
    vp.eye    = c.eye;
    return vp;
}

/// The Viewport the cell RENDERS with, read from GET /api/camera's
/// `viewMatrix`/`projMatrix` (task 7139). Unlike `viewportFromCamera` it does
/// not rebuild the view from eye/focus with a world-up hint, so it holds for
/// an ortho view turned with a pinned work plane (gap 187). `eye` is the
/// published eye.
Viewport viewportFromCameraMatrices(string baseUrl = testBaseUrl()) {
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/camera"));
    assert("viewMatrix" in j && "projMatrix" in j,
        "GET /api/camera carries no viewMatrix/projMatrix");
    Viewport vp;
    foreach (i; 0 .. 16) {
        vp.view[i] = cast(float)jnum(j["viewMatrix"].array[i]);
        vp.proj[i] = cast(float)jnum(j["projMatrix"].array[i]);
    }
    vp.width  = cast(int)j["width"].integer;
    vp.height = cast(int)j["height"].integer;
    vp.x      = cast(int)j["vpX"].integer;
    vp.y      = cast(int)j["vpY"].integer;
    vp.eye    = Vec3(cast(float)jnum(j["eye"]["x"]), cast(float)jnum(j["eye"]["y"]),
                     cast(float)jnum(j["eye"]["z"]));
    return vp;
}

/// The cursor ray of window pixel (sx, sy) under `vp` — the same two arms as
/// source/math.d's `screenPointToRay`: one apex (the eye) in perspective,
/// parallel rays starting on the image plane in ortho. `dir` is unit.
void pixelRay(float sx, float sy, const ref Viewport vp, out Vec3 org, out Vec3 dir) {
    float nx = ((sx - vp.x) / vp.width)  * 2.0f - 1.0f;
    float ny = 1.0f - ((sy - vp.y) / vp.height) * 2.0f;
    float vx = nx / vp.proj[0], vy = ny / vp.proj[5];
    Vec3 right = Vec3(vp.view[0], vp.view[4], vp.view[8]);
    Vec3 up    = Vec3(vp.view[1], vp.view[5], vp.view[9]);
    Vec3 back  = Vec3(vp.view[2], vp.view[6], vp.view[10]);
    if (vp.proj[15] != 0.0f) {                     // orthographic
        org = vp.eye + right * vx + up * vy;
        dir = back * -1.0f;
    } else {
        org = vp.eye;
        dir = normalize(right * vx + up * vy - back);
    }
}

/// Distance from `p` to the ray (org, unit dir) — the placement witnesses'
/// d_perp.
double rayDistance(Vec3 p, Vec3 org, Vec3 dir) {
    Vec3 d = p - org;
    float t = dot(d, dir);
    Vec3 q = d - dir * t;
    return sqrt(cast(double)dot(q, q));
}

private double jnum(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger : v.floating;
}

// World → window pixel projection (matches source/math.d:projectToWindow,
// but returns floats directly and doesn't reject off-screen points — same
// behaviour as projectToWindowFull, which is what the hit-test path uses).
bool projectToWindow(Vec3 world, const ref Viewport vp,
                     out float px, out float py)
{
    float vx = vp.view[0]*world.x + vp.view[4]*world.y + vp.view[8]*world.z + vp.view[12];
    float vy = vp.view[1]*world.x + vp.view[5]*world.y + vp.view[9]*world.z + vp.view[13];
    float vz = vp.view[2]*world.x + vp.view[6]*world.y + vp.view[10]*world.z + vp.view[14];
    float vw = vp.view[3]*world.x + vp.view[7]*world.y + vp.view[11]*world.z + vp.view[15];
    float cx = vp.proj[0]*vx + vp.proj[4]*vy + vp.proj[8] *vz + vp.proj[12]*vw;
    float cy = vp.proj[1]*vx + vp.proj[5]*vy + vp.proj[9] *vz + vp.proj[13]*vw;
    float cz = vp.proj[2]*vx + vp.proj[6]*vy + vp.proj[10]*vz + vp.proj[14]*vw;
    float cw = vp.proj[3]*vx + vp.proj[7]*vy + vp.proj[11]*vz + vp.proj[15]*vw;
    if (!(cw > 0.0f)) return false;
    float nx = cx / cw, ny = cy / cw;
    px = (nx * 0.5f + 0.5f)          * vp.width  + vp.x;
    py = (1.0f - (ny * 0.5f + 0.5f)) * vp.height + vp.y;
    return true;
}

// Same formula as source/handler.d:gizmoSize — produces the world-space
// arrow length matching the running gizmo's pixel target (120px default).
//
// 120, not 90, since task 0553: the reference's arm is its handle scale x 6.0
// SCREEN units at 20 pixels per screen unit = 120 px at shipped defaults,
// read out of the engine's own length functions. This is an independent copy
// of `g_gizmoPixels` on purpose — it is what makes a product-side geometry
// move fail loudly here instead of silently following. It did: 28 tests went
// red on the arm change alone, most of them rotate-ring grabs, because a ring
// whose radius IS the arm moved 30 px outward past an 8 px grab band.
float gizmoSize(Vec3 pos, const ref Viewport vp, float gizmoPixels = 120.0f) {
    float depth = -(vp.view[2]*pos.x + vp.view[6]*pos.y + vp.view[10]*pos.z + vp.view[14]);
    if (depth < 1e-4f) depth = 1e-4f;
    float vh = vp.height > 0 ? cast(float)vp.height : 1.0f;
    return 2.0f * gizmoPixels * depth / (vp.proj[5] * vh);
}

// JSON-Lines event log: one mouse-button-down at (x0,y0), `steps` motion
// events linearly interpolating to (x1,y1), one mouse-button-up. Motion
// events are spaced 50 ms apart so each lands in its own frame; SDL's
// X11 backend would otherwise coalesce them and only the LAST motion
// would reach the tool.
//
// `btn` (task 0477, doc/topopen_p6_addloop_plan.md — additive, defaulted to
// 1/LEFT so every existing positional call site stays byte-identical): the
// SDL button index (1=LEFT, 2=MIDDLE, 3=RIGHT) stamped on both the down/up
// events' "btn" field and derived into the motion events' "state" bitmask
// via the standard SDL_BUTTON(x) = 1 << (x-1) convention — lets a caller
// drive a MIDDLE-button drag (e.g. Shift+MMB Add Loop) through this same
// helper instead of hand-rolling its own JSON-Lines builder.
// Every builder below is frame-PACED: the player
// delivers one distinct `t` per frame, so the 50 ms gaps keep their meaning
// ("each lands in its own frame") without being waited out in wall-clock time.
enum string kPaceLine = `{"t":0.000,"type":"PACE","mode":"frames"}` ~ "\n";

string buildDragLog(int vpX, int vpY, int vpW, int vpH,
                    int x0, int y0, int x1, int y1, int steps = 20,
                    uint mod = 0, ubyte btn = 1)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine,
        vpX, vpY, vpW, vpH);

    double tDown = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%u}` ~ "\n",
        tDown, btn, x0, y0, mod);

    double stepMs = 50.0;
    uint state = 1u << (btn - 1);
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tDown + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%u,"mod":%u}` ~ "\n",
            t, x, y, x - lastX, y - lastY, state, mod);
        lastX = x; lastY = y;
    }
    double tUp = tDown + (steps + 1) * stepMs;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%u}` ~ "\n",
        tUp, btn, x1, y1, mod);
    return log;
}

// Task 6450: split a drag into independently playable logs so a test can
// inspect the rendered frame while the mouse button is still held.
string buildDragDownLog(int vpX, int vpY, int vpW, int vpH,
                        int x0, int y0, uint mod = 0, ubyte btn = 1)
{
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%u}` ~ "\n",
        vpX, vpY, vpW, vpH, btn, x0, y0, mod);
}

string buildDragMotionLog(int vpX, int vpY, int vpW, int vpH,
                          int x0, int y0, int x1, int y1, int steps = 20,
                          uint mod = 0, ubyte btn = 1)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine,
        vpX, vpY, vpW, vpH);
    uint state = 1u << (btn - 1);
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":%u,"mod":%u}` ~ "\n",
            i * 50.0, x, y, x - lastX, y - lastY, state, mod);
        lastX = x; lastY = y;
    }
    return log;
}

string buildDragUpLog(int vpX, int vpY, int vpW, int vpH,
                      int x1, int y1, uint mod = 0, ubyte btn = 1)
{
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":%d,"x":%d,"y":%d,"clicks":1,"mod":%u}` ~ "\n",
        vpX, vpY, vpW, vpH, btn, x1, y1, mod);
}

void playAndWait(string log, string baseUrl = testBaseUrl()) {
    auto resp = post(baseUrl ~ "/api/play-events", log);
    auto j = parseJSON(cast(string)resp);
    assert(j["status"].str == "success", "play-events failed: " ~ cast(string)resp);
    waitPlaybackProcessed(baseUrl);
}

double[3] vertexPos(int idx, string baseUrl = testBaseUrl()) {
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/model"));
    auto v = j["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}

// GET /api/tool/handles — fetch the screen anchor of a registered handle by
// its stable part id (task 0234). `found` is false when the tool has no
// arbiter (`{"handles":null}`), the part isn't registered, or its anchor is
// off-camera (`screen:null`) — callers should assert `found` and fail loud,
// since a missing part is usually a genuine regression (numbering shift,
// gizmo not drawn yet), not something to silently skip.
void fetchHandlePart(int part, out double sx, out double sy, out bool found,
                     string baseUrl = testBaseUrl())
{
    found = false;
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/tool/handles"));
    auto handles = j["handles"];
    if (handles.type == JSONType.null_) return;
    foreach (p; handles["parts"].array) {
        if (cast(int)p["part"].integer != part) continue;
        if (p["screen"].type == JSONType.null_) return;   // off-camera
        auto s = p["screen"].array;
        sx = s[0].floating;
        sy = s[1].floating;
        found = true;
        return;
    }
}

// GET /api/snap/last — the most recent SnapResult any tool published during a
// drag (snap_render.publishLastSnap). Carries snapped / highlighted /
// targetType / targetIndex / targetSource (0 = active mesh, 1..N = background
// snap source) + world positions. Lets a headless test assert the snap
// visual-feedback wiring (which source/element the highlight resolves to)
// without a screenshot diff.
JSONValue fetchSnapLast(string baseUrl = testBaseUrl()) {
    return parseJSON(cast(string)get(baseUrl ~ "/api/snap/last"));
}

// Projects the X-axis scale/move arrow handle at `pivot` to screen space and
// returns the grab pixel (gx,gy) at 70% along the shaft, plus the normalised
// screen-space drag direction (ux,uy). Matches the CubicArrow / ArrowHandler
// endpoints: shaft starts at pivot + X*(size/5) and ends at pivot + X*(size).
//
// /5 and 1.00 since task 0553, both measured: the reference starts BOTH banks'
// shafts at screenLength/5 (24 px) and ends BOTH banks' arms at screenLength
// (120 px). The /7 and 1.18 this replaces were the scale bank's own inset and
// an 18 % stagger past the move tip; neither exists in the reference, and this
// helper was applied to the MOVE arrow as well, where the /7 start was never
// right — it only went unnoticed because 78 px landed inside the move arrow's
// grab band anyway.
// Requires projectToWindow and gizmoSize from this module.
void axisGrabPx(Vec3 pivot, ref Viewport vp, out int gx, out int gy,
                out double ux, out double uy)
{
    float size = gizmoSize(pivot, vp);
    float sx1, sy1, sx2, sy2;
    projectToWindow(Vec3(pivot.x + size / 5.0f,  pivot.y, pivot.z), vp, sx1, sy1);
    projectToWindow(Vec3(pivot.x + size * 1.00f, pivot.y, pivot.z), vp, sx2, sy2);
    gx = cast(int)(sx1 + 0.7f * (sx2 - sx1));
    gy = cast(int)(sy1 + 0.7f * (sy2 - sy1));
    double dx = sx2 - sx1, dy = sy2 - sy1;
    double len = sqrt(dx*dx + dy*dy);
    ux = dx / len; uy = dy / len;
}

// Set a UserPlaced action-center pivot via tool.pipe.attr.
void setFarPivot(double px, double py, double pz,
                 string baseUrl = testBaseUrl())
{
    import std.conv : to;
    post(baseUrl ~ "/api/script", "tool.pipe.attr actionCenter userPlacedX " ~ px.to!string);
    post(baseUrl ~ "/api/script", "tool.pipe.attr actionCenter userPlacedY " ~ py.to!string);
    post(baseUrl ~ "/api/script", "tool.pipe.attr actionCenter userPlacedZ " ~ pz.to!string);
}

// Position camera so the gizmo at (px,py,pz) is on-screen.
// Eye = pivot + (3,1,2) → view-space depth ≈ √14 ≈ 3.7 units, well within
// the 100-unit far clip regardless of how large |pivot| is.
void setCameraAtPivot(double px, double py, double pz,
                      string baseUrl = testBaseUrl())
{
    import std.format : format;
    string body_ = format(
        `{"eye":{"x":%g,"y":%g,"z":%g},"focus":{"x":%g,"y":%g,"z":%g}}`,
        px+3.0, py+1.0, pz+2.0, px, py, pz);
    post(baseUrl ~ "/api/camera", body_);
}

/// Task 7116: one left press + release, no motion, 150 px right of the active
/// viewport's centre — off every handle of a tool armed at the origin. Used to
/// ENGAGE a tool whose law is "nothing is evaluated before the first viewport
/// press" (the Mirror tool): a parameter write alone no longer does it.
void engageByPress(string baseUrl = testBaseUrl()) {
    auto c = fetchCamera(baseUrl);
    immutable int x = c.vpX + c.width / 2 + 150, y = c.vpY + c.height / 2;
    playAndWait(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~ kPaceLine ~
        `{"t":30.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":60.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":90.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        c.vpX, c.vpY, c.width, c.height, x, y, x, y, x, y), baseUrl);
}
