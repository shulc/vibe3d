// Flex GESTURE CHAINING — a new gesture chains off the PERSISTED gizmo frame.
//
// flex_border_handles_plan.md Phase 3 / Commit B follow-up: after a flex ROTATE,
// the move/scale handles persist the rotated frame (R_gesture·B0). The user-found
// bug: grabbing the MOVE handle right after (no selection change) rendered the
// gizmo in the OLD un-rotated frame for the WHOLE move drag — because the new
// gesture's B0 was frozen from the live world-snapped currentBasis, ignoring the
// persisted softBasis. The fix sources the new run's B0 (render + apply translate)
// AND the move bank's input projection from softBasis when it is valid (and the
// selection/mode hasn't changed), so render + input + apply all agree on the
// rotated frame.
//
// What this asserts:
//   1. After a flex rotate, the persisted move frame deviates from the pre-rotate
//      (un-rotated) world B0 (the rotation took effect — precondition).
//   2. Grabbing the MOVE handle and dragging it (chunked, no selection change)
//      keeps the move's rendered frame at the ROTATED frame for the WHOLE drag —
//      it does NOT pop back to the un-rotated B0.
//   3. A selection change afterwards CLEARS the persisted frame → the first fresh
//      gesture re-derives the world-snapped basis (chaining stops at the boundary).
//
// This is a tracking-axis (axis=select / Border) effect only: under Auto/None the
// rotate suppresses R_gesture so softBasis == B0 and chaining is a no-op (the
// world-aligned cross-bank tests test_run_absolute_rotate / test_gpu_fold_parity
// stay green).

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
V3 moveRight()  { return readRight(getJson("/api/toolpipe/eval")["transform"]["moveRenderFrame"]); }
V3 acenCenter() {
    auto a = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
double maxDev(V3 a, V3 b) {
    double m = fabs(a.x-b.x);
    m = fabs(a.y-b.y) > m ? fabs(a.y-b.y) : m;
    m = fabs(a.z-b.z) > m ? fabs(a.z-b.z) : m;
    return m;
}

double[3][] dumpVerts() {
    double[3][] outv;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        outv ~= [a[0].floating, a[1].floating, a[2].floating];
    }
    return outv;
}
// World-space centroid of the verts that moved between `pre` and `now`.
V3 movedCentroid(double[3][] pre, double[3][] now) {
    double[3] s = [0, 0, 0]; int n = 0;
    foreach (k; 0 .. pre.length) {
        bool moved = false;
        foreach (c; 0 .. 3) if (fabs(now[k][c] - pre[k][c]) > 1e-4) moved = true;
        if (moved) { foreach (c; 0 .. 3) s[c] += now[k][c]; n++; }
    }
    if (n > 0) foreach (c; 0 .. 3) s[c] /= n;
    return V3(s[0], s[1], s[2]);
}
// World-space centroid delta of the moved set across a gesture.
V3 movedDelta(double[3][] pre, double[3][] now) {
    double[3] sPre = [0,0,0], sNow = [0,0,0]; int n = 0;
    foreach (k; 0 .. pre.length) {
        bool moved = false;
        foreach (c; 0 .. 3) if (fabs(now[k][c] - pre[k][c]) > 1e-4) moved = true;
        if (moved) {
            foreach (c; 0 .. 3) { sPre[c] += pre[k][c]; sNow[c] += now[k][c]; }
            n++;
        }
    }
    if (n == 0) return V3(0, 0, 0);
    return V3((sNow[0]-sPre[0])/n, (sNow[1]-sPre[1])/n, (sNow[2]-sPre[2])/n);
}

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
    string s = "[";
    foreach (i, v; sel) s ~= (i ? "," : "") ~ v.to!string;
    s ~= "]";
    postJson("/api/select", `{"mode":"polygons","indices":` ~ s ~ `}`);
}

void setupFlex() {
    postJson("/api/reset?type=subdivcube&levels=2", "");
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    selectUpperRegion();
    cmd("tool.set xfrm.flex on");
    cmd("tool.attr xfrm.flex T true");
    cmd("tool.attr xfrm.flex R true");
    cmd("tool.attr xfrm.flex S true");
}

bool projectPivot(Cam cam, out double ppx, out double ppy) {
    V3 pivot = acenCenter();
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    return project(pivot, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, ppx, ppy);
}

// Drive a chunked Border view-ring rotate at the current gizmo pivot.
// Returns the published rotation magnitude (deg) so the caller can assert it ran.
double driveBorderRotate(Cam cam, int dragPx = 70) {
    double ppx, ppy;
    assert(projectPivot(cam, ppx, ppy), "rotate: gizmo pivot off-camera");
    int rx0 = cast(int)(ppx + 95), ry0 = cast(int)ppy;
    int ry1 = ry0 - dragPx;
    enum int rsteps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, rx0, ry0));
    int lastY = ry0;
    double t = 100.0;
    foreach (i; 1 .. rsteps + 1) {
        int yy = ry0 + cast(int)(cast(double)(ry1 - ry0) * i / rsteps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, rx0, yy, 0, yy - lastY));
        lastY = yy; t += 50.0;
    }
    auto rot = getJson("/api/toolpipe/eval")["transform"]["rotate"].array;
    double rotMag = fabs(rot[0].floating) + fabs(rot[1].floating) + fabs(rot[2].floating);
    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, rx0, ry1));
    return rotMag;
}

// Drive a chunked CENTER-BOX free-plane drag (grab the projected gizmo pivot, so
// hitTestAxes returns dragAxis 3) by `(dx,dy)` screen pixels. Returns the
// world-space moved-set centroid delta.
//
// CenterBoxResult.maxScreenDrift: the worst per-step distance (px) between the
// CURSOR and the projected published gizmoCenter. A correct center-box screen-
// plane drag keeps the gizmo UNDER the cursor (the visual-follow + apply use the
// LIVE basis, so handler.center tracks the screen ray), so this stays small. If
// dragAxis==3 chained off the rotated softBasis, the center drifts off the cursor
// by the gizmo rotation → large drift. observedDragAxis confirms we grabbed the
// center box (==3), not a rotated arrow.
struct CenterBoxResult { V3 worldDelta; double maxScreenDrift; int observedDragAxis; }
int moveDragAxis() {
    auto t = getJson("/api/toolpipe/eval")["transform"];
    auto v = "moveDragAxis" in t;
    return v is null ? -99 : cast(int)(*v).integer;
}
// Project a world point to window px with the camera's view/proj.
bool projWorld(Cam cam, V3 w, out double px, out double py) {
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    return project(w, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, px, py);
}
CenterBoxResult driveCenterBoxDrag(Cam cam, int dx, int dy) {
    // Grab the projected MOVE gizmo center (handler.center — where the center box
    // is DRAWN), not acenCenter; after a rotate the soft-pinned acenCenter and the
    // drawn center can differ by float noise, and the box hit-test is tight.
    double ppx, ppy;
    assert(projWorld(cam, gizmoCenter(), ppx, ppy), "centerbox: gizmo off-camera");
    int x0 = cast(int)(ppx + 0.5), y0 = cast(int)(ppy + 0.5);   // ON the center box
    int x1 = x0 + dx, y1 = y0 + dy;
    enum int steps = 16;
    auto pre = dumpVerts();
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));
    CenterBoxResult res;
    res.observedDragAxis = moveDragAxis();   // right after button-down
    res.maxScreenDrift = 0;
    int lastX = x0, lastY = y0;
    double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
        // Project the live gizmoCenter back to screen; it must stay under the cursor.
        double gx, gy;
        if (projWorld(cam, gizmoCenter(), gx, gy)) {
            double drift = sqrt((gx - xx)*(gx - xx) + (gy - yy)*(gy - yy));
            if (drift > res.maxScreenDrift) res.maxScreenDrift = drift;
        }
    }
    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x1, y1));
    res.worldDelta = movedDelta(pre, dumpVerts());
    return res;
}
V3 gizmoCenter() {
    auto a = getJson("/api/toolpipe/eval")["transform"]["gizmoCenter"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}

unittest {
    setupFlex();
    Cam cam = fetchCam();

    // Idle (pre-rotate) un-rotated move frame = the world-snapped B0.
    V3 worldB0 = moveRight();

    // ---- flex ROTATE (view ring, chunked) ----
    double ppx, ppy;
    assert(projectPivot(cam, ppx, ppy), "gizmo pivot off-camera — camera changed");
    int rx0 = cast(int)(ppx + 95), ry0 = cast(int)ppy;
    int ry1 = ry0 - 70;
    enum int rsteps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, rx0, ry0));
    int lastY = ry0;
    double t = 100.0;
    foreach (i; 1 .. rsteps + 1) {
        int yy = ry0 + cast(int)(cast(double)(ry1 - ry0) * i / rsteps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, rx0, yy, 0, yy - lastY));
        lastY = yy; t += 50.0;
    }
    auto rot = getJson("/api/toolpipe/eval")["transform"]["rotate"].array;
    double rotMag = fabs(rot[0].floating) + fabs(rot[1].floating) + fabs(rot[2].floating);
    assert(rotMag > 10.0, "flex rotate too small (" ~ rotMag.to!string ~ ")");
    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, rx0, ry1));

    // Precondition: the persisted (idle) move frame is the ROTATED frame.
    V3 rotatedFrame = moveRight();
    double rotDev = maxDev(rotatedFrame, worldB0);
    assert(rotDev > 0.1,
        "flex rotate did not persist a rotated move frame (dev from world B0="
        ~ rotDev.to!string ~ ") — Commit B basis persistence precondition failed.");

    // ---- chained flex MOVE (no selection change): the move handle must render
    // the ROTATED frame for the WHOLE drag, NOT pop to the un-rotated world B0 ----
    cam = fetchCam();
    int mx0 = 418, my0 = 384;          // move Z-arrow shaft (same px as flex_drag)
    int mx1 = mx0 - 60, my1 = my0;
    enum int msteps = 18;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, mx0, my0));

    // Right at button-down (before motion), the rendered move frame must already
    // be the rotated frame (no first-frame un-rotated pop).
    V3 atDown = moveRight();
    assert(maxDev(atDown, rotatedFrame) < 5e-2,
        "chained MOVE popped to a DIFFERENT frame at button-down (rotated="
        ~ rotatedFrame.to!string ~ " atDown=" ~ atDown.to!string
        ~ ") — gesture chaining regressed (un-rotated B0 leaked in).");
    assert(maxDev(atDown, worldB0) > 0.1,
        "chained MOVE rendered the UN-ROTATED world B0 at button-down — the new "
        ~ "gesture's B0 ignored softBasis (the user-found bug).");

    int lastX = mx0; lastY = my0; t = 100.0;
    double worstPop = 0;
    foreach (i; 1 .. msteps + 1) {
        int xx = mx0 + cast(int)(cast(double)(mx1 - mx0) * i / msteps);
        int yy = my0 + cast(int)(cast(double)(my1 - my0) * i / msteps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
        // Every drag frame the rendered move frame stays on the rotated frame.
        double pop = maxDev(moveRight(), rotatedFrame);
        if (pop > worstPop) worstPop = pop;
    }
    assert(worstPop < 5e-2,
        "chained MOVE drag rendered frame DEVIATED from the rotated frame "
        ~ "(worst=" ~ worstPop.to!string ~ ") — the gizmo popped to the un-rotated "
        ~ "B0 mid-drag (gesture chaining regressed).");

    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, mx1, my1));

    // ---- selection change clears the chain → re-derive fresh world basis ----
    auto model = getJson("/api/model");
    auto verts = model["vertices"].array;
    auto faces = model["faces"].array;
    int[] sel2;
    foreach (fi, f; faces) {
        auto idx = f.array;
        double cx = 0;
        foreach (vi; idx) cx += verts[cast(size_t)vi.integer].array[0].floating;
        cx /= idx.length;
        if (cx > 0.1) sel2 ~= cast(int)fi;
    }
    assert(sel2.length > 10, "expected a right-side patch for the re-derive check");
    string s2 = "[";
    foreach (i, v; sel2) s2 ~= (i ? "," : "") ~ v.to!string;
    s2 ~= "]";
    postJson("/api/select", `{"mode":"polygons","indices":` ~ s2 ~ `}`);
    Thread.sleep(dur!"msecs"(80));
    getJson("/api/toolpipe/eval");        // idle tick fires the clear hook
    Thread.sleep(dur!"msecs"(40));

    V3 reDerive = moveRight();
    assert(maxDev(reDerive, rotatedFrame) > 1e-3,
        "a selection change did NOT clear the persisted rotated frame (still "
        ~ rotatedFrame.to!string ~ ") — clearSoftBasis not firing on selection "
        ~ "change, so the chain never resets.");
}

// CENTER-BOX free-plane drag after a Border rotate stays SCREEN-PLANE (it must NOT
// chain off the rotated softBasis). The center box is basis-free input; if the
// apply-path runFrame B0 / visual-follow chained off softBasis, run.t would be
// decomposed against the live basis but re-expanded against the rotated frame →
// the moved-set translates rotated by the gizmo angle (off the cursor). This
// asserts the chained center-box drag's world delta DIRECTION matches a baseline
// (no-rotate) center-box drag of the SAME screen vector.
unittest {
    enum int dx = -55, dy = -20;       // an oblique screen drag (both components)

    // Baseline: a fresh Border scene, center-box drag with NO preceding rotate.
    // Establishes the inherent gizmo-vs-cursor screen tracking error (small).
    setupFlex();
    Cam cam = fetchCam();
    auto baseRes = driveCenterBoxDrag(cam, dx, dy);
    assert(baseRes.observedDragAxis == 3,
        "baseline grab did NOT engage the center box (dragAxis="
        ~ baseRes.observedDragAxis.to!string ~ ") — center-box hit-test wrong");
    double baseLen = sqrt(dot(baseRes.worldDelta, baseRes.worldDelta));
    assert(baseLen > 0.05,
        "baseline center-box drag produced no motion (len=" ~ baseLen.to!string ~ ")");
    // Sanity: the un-rotated center-box drag tracks the cursor closely.
    assert(baseRes.maxScreenDrift < 18.0,
        "baseline center-box gizmo did not track the cursor (drift="
        ~ baseRes.maxScreenDrift.to!string ~ " px) — test methodology issue");

    // Chained: fresh Border scene, a Border ROTATE first, THEN the SAME center-box
    // drag (no selection change between, so softBasis is the rotated frame).
    setupFlex();
    cam = fetchCam();
    // A ~38° rotate (dragPx 45): large enough that a rotated apply would drift the
    // center tens of px off the cursor, but small enough that the center box stays
    // grabbable (a ~48°+ rotate fans the rotated arrows over the box → grab misses,
    // a gizmo-layout limit of synthetic-pixel driving, not the behaviour under test).
    double rotMag = driveBorderRotate(cam, 45);
    assert(rotMag > 25.0,
        "Border rotate too small (" ~ rotMag.to!string ~ ") — ring hit-test wrong");
    cam = fetchCam();
    auto chainRes = driveCenterBoxDrag(cam, dx, dy);
    assert(chainRes.observedDragAxis == 3,
        "chained grab did NOT engage the center box (dragAxis="
        ~ chainRes.observedDragAxis.to!string ~ ") — after the rotate the projected "
        ~ "pivot pixel must still hit the center box");
    double chainLen = sqrt(dot(chainRes.worldDelta, chainRes.worldDelta));
    assert(chainLen > 0.05,
        "chained center-box drag produced no motion (len=" ~ chainLen.to!string ~ ")");

    // THE FIX: the center-box drag after a Border rotate must stay SCREEN-PLANE —
    // the gizmo center keeps tracking the cursor, just like the un-rotated baseline.
    // If dragAxis==3 chained off the rotated softBasis (apply runFrame + visual
    // follow), the center would drift off the cursor by the gizmo rotation R
    // (tens of px for a ~30° rotate on this gizmo) — far above the baseline error.
    assert(chainRes.maxScreenDrift < baseRes.maxScreenDrift + 12.0,
        "center-box drag after a Border rotate DRIFTED off the cursor (chain drift="
        ~ chainRes.maxScreenDrift.to!string ~ " px vs baseline "
        ~ baseRes.maxScreenDrift.to!string ~ " px) — dragAxis==3 was not excluded "
        ~ "from softBasis chaining (apply/visual desync).");
}

// SAME-SESSION rotate→move: the user-found bug the separate-grab test above MISSED.
//
// In ONE tool session (no reset / selection change / tool drop between gestures —
// exactly the GUI flow), a flex rotate then a move renders the move handle in the
// WORLD frame for the whole move drag. Root cause: runFrame is frozen ONCE per
// session (at the session's first applyTRS = the rotate's start = world) and is
// NOT re-frozen for the within-session move, so renderBasis's runFrameValid branch
// returned the stale WORLD B0 (with R_gesture == I, since gestureStart.r == run.r).
// The fix sources renderBasis's B0 from the persisted softBasis (rotated) even when
// runFrameValid — RENDER ONLY (the apply path / runFrame are untouched; re-sourcing
// runFrame would double-rotate the translate via the fold's run.r·T, verified).
//
// The first chain unittest above missed this because after its larger rotate the
// move Z-ARROW pixel (418,384) no longer hits a handle (the gizmo moved), so its
// "move" never engaged (dragAxis -1) and the rotated frame it observed was the IDLE
// (runFrameValid=false) render, not a real within-session move. Here we use a
// SMALLER rotate (~30°) and grab the CENTER BOX (always at the gizmo center, so the
// move reliably engages dragAxis==3 with runFrameValid==TRUE — the bug condition).
unittest {
    setupFlex();
    Cam cam = fetchCam();
    V3 worldB0 = moveRight();              // un-rotated frame, ~ (1,0,0)

    // ~30° rotate (dragPx 35) — small enough the center box stays grabbable, large
    // enough the rotated frame is unmistakably off world. SAME SESSION after this.
    double rotMag = driveBorderRotate(cam, 35);
    assert(rotMag > 15.0,
        "same-session: Border rotate too small (" ~ rotMag.to!string ~ ")");
    V3 rotatedFrame = moveRight();         // persisted rotated frame (idle)
    assert(maxDev(rotatedFrame, worldB0) > 0.15,
        "same-session: rotate did not persist a rotated frame (dev="
        ~ maxDev(rotatedFrame, worldB0).to!string ~ ")");

    // Grab the CENTER BOX in the SAME session (no reset / selection change). The
    // move engages dragAxis==3 with runFrameValid==TRUE — the exact within-session
    // path the user hit and the first unittest missed.
    cam = fetchCam();
    double ppx, ppy;
    assert(projWorld(cam, gizmoCenter(), ppx, ppy), "same-session: gizmo off-camera");
    int x0 = cast(int)(ppx + 0.5), y0 = cast(int)(ppy + 0.5);
    int x1 = x0 - 55, y1 = y0 - 18;
    enum int steps = 16;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    // The move MUST have engaged a real handle (not missed like the first test).
    auto td = getJson("/api/toolpipe/eval")["transform"];
    assert(cast(int)td["moveDragAxis"].integer == 3,
        "same-session: center-box move did not engage (dragAxis="
        ~ td["moveDragAxis"].integer.to!string ~ ")");
    // Document the bug CONDITION: runFrame is still the session's (world) frame.
    assert(td["runFrameValid"].type == JSONType.TRUE,
        "same-session: expected the session's runFrame to still be valid (the "
        ~ "within-session path); got invalid — test no longer exercises the bug");

    // BUG: the move handle must render the ROTATED frame for the WHOLE drag — NOT
    // snap back to world — even though runFrameValid (the session's world frame).
    int lastX = x0, lastY = y0; double t = 100.0;
    double worstWorldSnap = 0, worstRotDev = 0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
        V3 mr = moveRight();
        double devRot   = maxDev(mr, rotatedFrame);   // distance from rotated frame
        double devWorld = maxDev(mr, worldB0);         // distance from world frame
        if (devRot   > worstRotDev)   worstRotDev   = devRot;
        if (devWorld < worstWorldSnap || worstWorldSnap == 0) worstWorldSnap = devWorld;
    }
    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x1, y1));

    assert(worstRotDev < 5e-2,
        "same-session move rendered frame DEVIATED from the rotated frame (worst="
        ~ worstRotDev.to!string ~ ") — within-session render reverted toward world "
        ~ "(the user-found same-session bug).");
    assert(worstWorldSnap > 0.15,
        "same-session move rendered frame SNAPPED to the WORLD frame (closest dev="
        ~ worstWorldSnap.to!string ~ ") — runFrameValid world B0 leaked into the "
        ~ "within-session render (the bug).");

    // Idle after the move stays rotated (guardrail #4 — the move's settleGestureBasis
    // re-pins the rotated frame, so the chain holds).
    assert(maxDev(moveRight(), worldB0) > 0.15,
        "same-session: idle-after-move snapped back to world — softBasis not re-pinned "
        ~ "(guardrail #4).");
}
