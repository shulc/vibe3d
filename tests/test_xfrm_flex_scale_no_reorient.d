// Flex SCALE drag — sibling MOVE + ROTATE handles must NOT re-orient (bug 2).
//
// flex_border_handles_plan.md Phase 2, Model C. During a move/scale gesture
// R_gesture = identity, so the rendered basis = B0 frozen cross-bank for the
// whole drag. Pre-fix, every bank re-derived the live select-derived basis
// each frame (gated on dragAxis<0 only for the ACTIVE bank); the INACTIVE
// sibling banks (move + rotate, dragAxis == -1) kept re-deriving the live
// world-snapped basis, which flips its up-sign / swaps its right axis as the
// deforming mesh crosses an extent/normal boundary — a spurious mid-drag flip
// of the rendered sibling handles (BUG 2).
//
// The fix routes ALL banks' rendered orientation through the wrapper's shared
// Model-C renderBasis. For a scale drag that basis is the gesture-frozen B0
// (R_gesture = I), so the move + rotate sibling triples stay put across the
// whole drag.
//
// What this test does:
//   1. Build a level-2 Catmull-Clark cube (interior verts move under
//      selection-falloff; a plain cube is all-boundary → no motion).
//   2. Select the upper face region (partial set, up-axis = +Y) and activate
//      xfrm.flex with T + R + S ALL on (so the move + rotate sibling banks
//      actually render and publish their rendered triples).
//   3. Grab the SCALE single-axis Z box (same camera/pixel the scale-flip
//      regression uses — the underlying select-basis DOES flip during this
//      drag) and drag it in CHUNKS (one play-events per step, button held).
//   4. After each step sample the LIVE rendered move + rotate triples via the
//      /api/toolpipe/eval rendered-pose seam, and assert each stays within eps
//      of its drag-start value. Pre-fix they flip; post-fix they are frozen.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, tan, PI;
import std.conv : to;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

void main() {}

enum baseUrl = "http://localhost:8080";

JSONValue getJson(string p) { return parseJSON(cast(string) get(baseUrl ~ p)); }
JSONValue postJson(string p, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ p, body_));
}
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

// ---- minimal camera / projection math (kept local, standalone) ----------
struct V3 { double x = 0, y = 0, z = 0; }
double dot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 cross(V3 a, V3 b) {
    return V3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
V3 norm(V3 v) {
    double L = sqrt(dot(v, v));
    return L > 1e-12 ? V3(v.x/L, v.y/L, v.z/L) : V3(0, 0, 0);
}
double[16] lookAt(V3 eye, V3 ctr, V3 up) {
    V3 f = norm(V3(ctr.x-eye.x, ctr.y-eye.y, ctr.z-eye.z));
    V3 r = norm(cross(f, up));
    V3 u = cross(r, f);
    return [ r.x, u.x, -f.x, 0, r.y, u.y, -f.y, 0, r.z, u.z, -f.z, 0,
        -(r.x*eye.x+r.y*eye.y+r.z*eye.z), -(u.x*eye.x+u.y*eye.y+u.z*eye.z),
         (f.x*eye.x+f.y*eye.y+f.z*eye.z), 1 ];
}
double[16] persp(double fovY, double asp, double n, double f) {
    double fn = 1.0 / tan(fovY * 0.5); double nf = n - f;
    return [ fn/asp,0,0,0, 0,fn,0,0, 0,0,(f+n)/nf,-1, 0,0,2*f*n/nf,0 ];
}
struct Cam { V3 eye, focus; int w, h, vpX, vpY; }
Cam fetchCam() {
    auto j = getJson("/api/camera");
    Cam c;
    c.eye   = V3(j["eye"]["x"].floating,   j["eye"]["y"].floating,   j["eye"]["z"].floating);
    c.focus = V3(j["focus"]["x"].floating, j["focus"]["y"].floating, j["focus"]["z"].floating);
    c.w = cast(int)j["width"].integer; c.h = cast(int)j["height"].integer;
    c.vpX = cast(int)j["vpX"].integer;  c.vpY = cast(int)j["vpY"].integer;
    return c;
}
bool project(V3 world, const ref double[16] view, const ref double[16] p,
             int w, int h, int vpX, int vpY, out double px, out double py) {
    double vx = view[0]*world.x+view[4]*world.y+view[8]*world.z+view[12];
    double vy = view[1]*world.x+view[5]*world.y+view[9]*world.z+view[13];
    double vz = view[2]*world.x+view[6]*world.y+view[10]*world.z+view[14];
    double vw = view[3]*world.x+view[7]*world.y+view[11]*world.z+view[15];
    double cx = p[0]*vx+p[4]*vy+p[8]*vz+p[12]*vw;
    double cy = p[1]*vx+p[5]*vy+p[9]*vz+p[13]*vw;
    double cw = p[3]*vx+p[7]*vy+p[11]*vz+p[15]*vw;
    if (!(cw > 0)) return false;
    px = (cx/cw*0.5+0.5)*w + vpX;
    py = (1-(cy/cw*0.5+0.5))*h + vpY;
    return true;
}

void play(string log) {
    auto r = postJson("/api/play-events", log);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString);
    foreach (i; 0 .. 200) {
        if (getJson("/api/play-events/status")["finished"].type == JSONType.TRUE) break;
        Thread.sleep(dur!"msecs"(20));
    }
    Thread.sleep(dur!"msecs"(40));
}

// A rendered basis triple (right/up/fwd) read from the eval seam.
struct Frame { V3 r, u, f; }
Frame readFrame(JSONValue blk) {
    V3 g(string axis) {
        auto a = blk[axis].array;
        return V3(a[0].floating, a[1].floating, a[2].floating);
    }
    return Frame(g("right"), g("up"), g("fwd"));
}
// Max per-component deviation between two frames.
double frameDelta(Frame a, Frame b) {
    double m = 0;
    void chk(V3 x, V3 y) {
        m = fabs(x.x-y.x) > m ? fabs(x.x-y.x) : m;
        m = fabs(x.y-y.y) > m ? fabs(x.y-y.y) : m;
        m = fabs(x.z-y.z) > m ? fabs(x.z-y.z) : m;
    }
    chk(a.r, b.r); chk(a.u, b.u); chk(a.f, b.f);
    return m;
}

unittest {
    // ---- scene: level-2 Catmull-Clark cube, upper-region face patch ----
    postJson("/api/reset?type=subdivcube&levels=2", "");
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);

    auto model = getJson("/api/model");
    auto verts = model["vertices"].array;
    auto faces = model["faces"].array;
    int[] sel;
    foreach (fi, f; faces) {
        auto idx = f.array;
        double cy = 0;
        foreach (vi; idx) cy += verts[cast(size_t)vi.integer].array[1].floating;
        cy /= idx.length;
        if (cy > -0.35) sel ~= cast(int)fi;
    }
    assert(sel.length > 30, "expected a large upper-region patch, got "
        ~ sel.length.to!string);
    string selStr = "[";
    foreach (i, s; sel) selStr ~= (i ? "," : "") ~ s.to!string;
    selStr ~= "]";
    postJson("/api/select", `{"mode":"polygons","indices":` ~ selStr ~ `}`);

    // Flex preset with T + R + S ALL on so the move + rotate SIBLING banks
    // render and publish their rendered triples during the scale drag.
    cmd("tool.set xfrm.flex on");
    cmd("tool.attr xfrm.flex T true");
    cmd("tool.attr xfrm.flex R true");
    cmd("tool.attr xfrm.flex S true");

    // ---- locate the SCALE Z-axis box handle (same pixel the scale-flip
    //      regression uses; local-Z = world+Y → box straight above gizmo center;
    //      registerGizmoHandles registers scale first in compact mode so the
    //      scale box wins the overlap with the move arrow).
    Cam cam = fetchCam();
    int x0 = 475, y0 = 260;     // on the scale Z-axis box handle (local-Z = world+Y)
    int x1 = x0, y1 = y0 - 60;  // drag 60 px upward (toward world+Y, scale up)

    auto tp0 = getJson("/api/toolpipe/eval");
    auto ac = tp0["actionCenter"]["center"].array;
    V3 pivot = V3(ac[0].floating, ac[1].floating, ac[2].floating);
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    double ppx, ppy;
    assert(project(pivot, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, ppx, ppy),
        "gizmo pivot projects off-camera — camera setup changed");

    // ---- chunked drag: one play-events per motion step, button held ----
    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    // The drag-START rendered move + rotate triples (read AFTER button-down,
    // i.e. after the gesture began but before any motion).
    Frame moveStart, rotStart;
    {
        auto t = getJson("/api/toolpipe/eval")["transform"];
        moveStart = readFrame(t["moveRenderFrame"]);
        rotStart  = readFrame(t["rotateRenderFrame"]);
    }

    double[] moveDev, rotDev;     // sibling frame deviation from start, per step
    int lastX = x0, lastY = y0;
    double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
        auto tr = getJson("/api/toolpipe/eval")["transform"];
        moveDev ~= frameDelta(readFrame(tr["moveRenderFrame"]),   moveStart);
        rotDev  ~= frameDelta(readFrame(tr["rotateRenderFrame"]), rotStart);
    }
    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x1, y1));

    // ---- assertions ----
    assert(moveDev.length == steps && rotDev.length == steps);

    // The scale drag must actually have engaged (verify some motion happened by
    // checking the published run-frame is valid — set on first applyTRS).
    auto endT = getJson("/api/toolpipe/eval")["transform"];
    assert(endT["runFrameValid"].type == JSONType.TRUE,
        "scale drag never started a run — handle hit-test / selection is wrong");

    // The rendered MOVE + ROTATE sibling triples must stay frozen across the
    // whole drag (R_gesture = I for a scale gesture ⇒ renderBasis = B0). eps is
    // generous (basis vectors are unit length; pre-fix the flip is order-1).
    enum double eps = 1e-3;
    foreach (i; 0 .. steps) {
        assert(moveDev[i] < eps,
            "MOVE sibling handle re-oriented during scale drag at step "
            ~ (i + 1).to!string ~ " (dev=" ~ moveDev[i].to!string
            ~ ") — Model-C renderBasis regressed (bug 2)."
            ~ "\n moveDev: " ~ moveDev.to!string);
        assert(rotDev[i] < eps,
            "ROTATE sibling handle re-oriented during scale drag at step "
            ~ (i + 1).to!string ~ " (dev=" ~ rotDev[i].to!string
            ~ ") — Model-C renderBasis regressed (bug 2)."
            ~ "\n rotDev: " ~ rotDev.to!string);
    }
}
