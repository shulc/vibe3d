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

CameraState fetchCamera(string baseUrl = "http://localhost:8080") {
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
// arrow length matching the running gizmo's pixel target (90px default).
float gizmoSize(Vec3 pos, const ref Viewport vp, float gizmoPixels = 90.0f) {
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
string buildDragLog(int vpX, int vpY, int vpW, int vpH,
                    int x0, int y0, int x1, int y1, int steps = 20,
                    uint mod = 0)
{
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
        vpX, vpY, vpW, vpH);

    double tDown = 50.0;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}` ~ "\n",
        tDown, x0, y0, mod);

    double stepMs = 50.0;
    int lastX = x0, lastY = y0;
    foreach (i; 1 .. steps + 1) {
        int x = x0 + cast(int)((cast(double)(x1 - x0) * i) / steps);
        int y = y0 + cast(int)((cast(double)(y1 - y0) * i) / steps);
        double t = tDown + i * stepMs;
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":%u}` ~ "\n",
            t, x, y, x - lastX, y - lastY, mod);
        lastX = x; lastY = y;
    }
    double tUp = tDown + (steps + 1) * stepMs;
    log ~= format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":%u}` ~ "\n",
        tUp, x1, y1, mod);
    return log;
}

void playAndWait(string log, string baseUrl = "http://localhost:8080") {
    auto resp = post(baseUrl ~ "/api/play-events", log);
    auto j = parseJSON(cast(string)resp);
    assert(j["status"].str == "success", "play-events failed: " ~ cast(string)resp);
    foreach (i; 0 .. 200) {
        auto s = parseJSON(cast(string)get(baseUrl ~ "/api/play-events/status"));
        if (s["finished"].type == JSONType.TRUE) return;
        Thread.sleep(dur!"msecs"(50));
    }
    assert(false, "play-events did not finish within 10s");
}

double[3] vertexPos(int idx, string baseUrl = "http://localhost:8080") {
    auto j = parseJSON(cast(string)get(baseUrl ~ "/api/model"));
    auto v = j["vertices"].array[idx].array;
    return [v[0].floating, v[1].floating, v[2].floating];
}
