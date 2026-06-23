// Flex ROTATE drag — sibling MOVE + SCALE handles FOLLOW the rotation (bug 3),
// and the PLAIN-mode counterpart leaves them FIXED (the no-`if` discriminator).
//
// flex_border_handles_plan.md Phase 2, Model C:
//
//     renderBasis = (axisTracksSelection ? R_gesture : I) · B0
//
// During a ROTATE gesture R_gesture is the accumulated ring rotation. In a FLEX
// preset (axis.mode=select, so axisTracksSelection() == true) renderBasis =
// R_gesture·B0 ⇒ the move + scale SIBLING banks re-orient smoothly with the
// applied angle (BUG 3 fixed). In a PLAIN preset (axis=auto, axisTracksSelection
// == false) renderBasis = B0 ⇒ the siblings stay fixed. The split comes from the
// ONE AxisStage.axisTracksSelection() boolean — there is NO per-mode branch in
// the gizmo, so this test pins both arms of that single discriminator.
//
// Drag mechanics: the view-aligned rotate ring (arcView, dragAxis==3) lives at a
// constant ~99 px screen radius around the projected gizmo pivot (gizmoSize
// compensates depth). We project the pivot per-mode (the flex BORDER center and
// the auto SELECTION centroid differ), place the ring-grab pixel at
// projected_pivot + (95, 0), and drag up ~70 px in CHUNKS (one play-events per
// step, button held). After the drag we read the rendered move + scale `right`
// vectors via the /api/toolpipe/eval rendered-pose seam.

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

V3 readRight(JSONValue blk) {
    auto a = blk["right"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
double maxDev(V3 a, V3 b) {
    double m = fabs(a.x-b.x);
    m = fabs(a.y-b.y) > m ? fabs(a.y-b.y) : m;
    m = fabs(a.z-b.z) > m ? fabs(a.z-b.z) : m;
    return m;
}

// Select the upper-region face patch (partial set with a moving interior).
void selectUpperRegion() {
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
}

// Drive one chunked view-ring rotate at the CURRENT gizmo pivot. Returns the
// post-drag rendered move + scale `right` deviation from their drag-start value
// and the published rotate euler magnitude (to confirm the ring engaged).
struct RotResult { double moveDev, scaleDev, rotMag; bool valid; }
RotResult driveViewRingRotate(Cam cam) {
    // Project the LIVE gizmo pivot (border center for flex, auto centroid for
    // plain) and place the ring-grab pixel at projected_pivot + (95, 0).
    auto tp = getJson("/api/toolpipe/eval");
    auto ac = tp["actionCenter"]["center"].array;
    V3 pivot = V3(ac[0].floating, ac[1].floating, ac[2].floating);
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    double ppx, ppy;
    assert(project(pivot, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, ppx, ppy),
        "gizmo pivot projects off-camera — camera setup changed");
    int x0 = cast(int)(ppx + 95), y0 = cast(int)ppy;   // on the view-ring
    int y1 = y0 - 70;                                    // tangent drag up

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    // Drag-start rendered move + scale right (after button-down, before motion).
    V3 moveStart, scaleStart;
    {
        auto t = getJson("/api/toolpipe/eval")["transform"];
        moveStart  = readRight(t["moveRenderFrame"]);
        scaleStart = readRight(t["scaleRenderFrame"]);
    }

    int lastY = y0;
    double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x0, yy, 0, yy - lastY));
        lastY = yy; t += 50.0;
    }

    auto endT = getJson("/api/toolpipe/eval")["transform"];
    RotResult res;
    res.moveDev  = maxDev(readRight(endT["moveRenderFrame"]),  moveStart);
    res.scaleDev = maxDev(readRight(endT["scaleRenderFrame"]), scaleStart);
    auto rot = endT["rotate"].array;
    res.rotMag = fabs(rot[0].floating) + fabs(rot[1].floating) + fabs(rot[2].floating);
    res.valid  = endT["runFrameValid"].type == JSONType.TRUE;

    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y1));
    return res;
}

unittest {
    // ================= FLEX (axis.mode=select) — siblings FOLLOW =============
    postJson("/api/reset?type=subdivcube&levels=2", "");
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    selectUpperRegion();

    cmd("tool.set xfrm.flex on");
    cmd("tool.attr xfrm.flex T true");
    cmd("tool.attr xfrm.flex R true");
    cmd("tool.attr xfrm.flex S true");

    Cam cam = fetchCam();
    RotResult flex = driveViewRingRotate(cam);

    assert(flex.valid, "flex rotate never started a run — ring hit-test failed");
    assert(flex.rotMag > 10.0,
        "flex view-ring drag produced too small a rotation (" ~ flex.rotMag.to!string
        ~ " deg) — ring hit-test / drag is wrong");
    // Bug 3: the move + scale SIBLING handles must FOLLOW the rotation. A ~tens-
    // of-degrees rotation moves the `right` vector by an order-0.3+ amount.
    assert(flex.moveDev > 0.1,
        "flex MOVE sibling did NOT follow the rotation (dev=" ~ flex.moveDev.to!string
        ~ ") — Model-C R_gesture·B0 follow regressed (bug 3).");
    assert(flex.scaleDev > 0.1,
        "flex SCALE sibling did NOT follow the rotation (dev=" ~ flex.scaleDev.to!string
        ~ ") — Model-C R_gesture·B0 follow regressed (bug 3).");

    // ================= PLAIN (axis=auto) — siblings FIXED ====================
    // Same scene + selection + drag mechanics; flip ONLY the action-center /
    // axis to auto (axisTracksSelection() == false). The single boolean is the
    // sole discriminator — no per-mode branch in the gizmo.
    postJson("/api/reset?type=subdivcube&levels=2", "");
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    selectUpperRegion();

    cmd("tool.set xfrm.flex on");
    cmd("tool.attr xfrm.flex T true");
    cmd("tool.attr xfrm.flex R true");
    cmd("tool.attr xfrm.flex S true");
    cmd("actr.auto");                  // axis -> auto, !axisTracksSelection

    cam = fetchCam();
    RotResult plain = driveViewRingRotate(cam);

    assert(plain.valid, "plain rotate never started a run — ring hit-test failed");
    assert(plain.rotMag > 10.0,
        "plain view-ring drag produced too small a rotation (" ~ plain.rotMag.to!string
        ~ " deg) — ring hit-test / drag is wrong");
    // The siblings must stay FIXED (renderBasis = B0; R_gesture suppressed).
    enum double eps = 1e-3;
    assert(plain.moveDev < eps,
        "plain MOVE sibling FOLLOWED the rotation (dev=" ~ plain.moveDev.to!string
        ~ ") — axisTracksSelection discriminator leaked into plain mode.");
    assert(plain.scaleDev < eps,
        "plain SCALE sibling FOLLOWED the rotation (dev=" ~ plain.scaleDev.to!string
        ~ ") — axisTracksSelection discriminator leaked into plain mode.");
}
