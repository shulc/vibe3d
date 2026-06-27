// Gizmo-POSE undo restore (flex transform) — does an in-session Ctrl+Z restore
// the transform gizmo's RENDERED FRAME BASIS (not just the geometry + action
// center) one gesture back?
//
// BUG: an in-session Ctrl+Z of a flex ROTATE restored the geometry + the action
// center, but NOT the rendered gizmo basis — the gizmo kept rendering the rotated
// frame while the geometry was back at pristine. An undo bumps the mutation
// version but not the selection hash, so clearFrame() never fired and the idle
// renderBasis kept returning the persisted (rotated) gesture-end basis.
//
// FIX: mirror the existing center soft-pin undo splice for the persisted
// `GestureFrame frame` — snapshot the gesture-START frame at each
// begin*DragSession and restore it from the per-gesture REVERT hook (apply
// restores the gesture-END frame, so redo also lands correctly).
//
// RED on HEAD 8f28625 WITHOUT the fix (the ROTATE rotFrameGap assertion fires:
//   rotFrameGap == the full post-gesture rotation travel, gizmo basis stale).
// GREEN WITH the fix (rotFrameGap ≈ 0, basis returns to the pre-gesture frame).
// MOVE / SCALE undo are restore-to-same (their gesture does not rotate the frame),
// so those assertions pass with AND without the fix — they pin that the splice is
// a no-op for the non-rotating banks.
//
// This strengthens test_xfrm_flex_center_freeze's undo assertions (which only
// check the center is non-NaN + agrees with the gizmo center) by also asserting
// the rendered frame returns to the PRE-gesture pose.

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, tan, sin, cos, atan2, PI;
import std.conv : to;
import std.format : format;
import core.thread : Thread;
import core.time   : dur;

void main() {}

enum baseUrl = "http://localhost:8080";

JSONValue getJson(string p) { return parseJSON(cast(string) get(baseUrl ~ p)); }
JSONValue postJson(string p, string body_) { return parseJSON(cast(string) post(baseUrl ~ p, body_)); }
void cmd(string s) {
    auto j = postJson("/api/command", s);
    assert(j["status"].str == "ok", "cmd `" ~ s ~ "` failed: " ~ j.toString);
}

struct V3 { double x = 0, y = 0, z = 0; }
double dot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
V3 cross(V3 a, V3 b) { return V3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x); }
V3 norm(V3 v) { double L = sqrt(dot(v, v)); return L > 1e-12 ? V3(v.x/L, v.y/L, v.z/L) : V3(0,0,0); }
double[16] lookAt(V3 eye, V3 ctr, V3 up) {
    V3 f = norm(V3(ctr.x-eye.x, ctr.y-eye.y, ctr.z-eye.z));
    V3 r = norm(cross(f, up)); V3 u = cross(r, f);
    return [ r.x,u.x,-f.x,0, r.y,u.y,-f.y,0, r.z,u.z,-f.z,0,
        -(r.x*eye.x+r.y*eye.y+r.z*eye.z), -(u.x*eye.x+u.y*eye.y+u.z*eye.z),
         (f.x*eye.x+f.y*eye.y+f.z*eye.z), 1 ];
}
double[16] persp(double fovY, double asp, double n, double f) {
    double fn = 1.0 / tan(fovY * 0.5); double nf = n - f;
    return [ fn/asp,0,0,0, 0,fn,0,0, 0,0,(f+n)/nf,-1, 0,0,2*f*n/nf,0 ];
}
struct Cam { V3 eye, focus; int w, h, vpX, vpY; }
Cam fetchCam() {
    auto j = getJson("/api/camera"); Cam c;
    c.eye   = V3(j["eye"]["x"].floating, j["eye"]["y"].floating, j["eye"]["z"].floating);
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
    px = (cx/cw*0.5+0.5)*w + vpX; py = (1-(cy/cw*0.5+0.5))*h + vpY; return true;
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
V3 acenCenter() {
    auto a = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
V3 readRight(JSONValue blk) {
    auto a = blk["right"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
V3 readFwd(JSONValue blk) {
    auto a = blk["fwd"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
V3 moveRight()  { return readRight(getJson("/api/toolpipe/eval")["transform"]["moveRenderFrame"]); }
V3 moveFwd()    { return readFwd(getJson("/api/toolpipe/eval")["transform"]["moveRenderFrame"]); }
V3 scaleRight() { return readRight(getJson("/api/toolpipe/eval")["transform"]["scaleRenderFrame"]); }
V3 rotateRight(){ return readRight(getJson("/api/toolpipe/eval")["transform"]["rotateRenderFrame"]); }
double maxDev(V3 a, V3 b) {
    double m = fabs(a.x-b.x);
    m = fabs(a.y-b.y) > m ? fabs(a.y-b.y) : m;
    m = fabs(a.z-b.z) > m ? fabs(a.z-b.z) : m; return m;
}
void selectUpperRegion() {
    auto model = getJson("/api/model");
    auto verts = model["vertices"].array; auto faces = model["faces"].array;
    int[] sel;
    foreach (fi, f; faces) {
        auto idx = f.array; double cy = 0;
        foreach (vi; idx) cy += verts[cast(size_t)vi.integer].array[1].floating;
        cy /= idx.length;
        if (cy > -0.35) sel ~= cast(int)fi;
    }
    assert(sel.length > 30, "expected a large upper-region patch, got " ~ sel.length.to!string);
    string selStr = "[";
    foreach (i, s; sel) selStr ~= (i ? "," : "") ~ s.to!string;
    selStr ~= "]";
    postJson("/api/select", `{"mode":"polygons","indices":` ~ selStr ~ `}`);
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
    auto view = lookAt(cam.eye, cam.focus, V3(0,1,0));
    auto proj = persp(45.0*PI/180.0, cast(double)cam.w/cam.h, 0.001, 100.0);
    return project(pivot, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, ppx, ppy);
}

long undoCount() { return getJson("/api/history")["undo"].array.length; }
void undoStep() {
    postJson("/api/undo", "");
    Thread.sleep(dur!"msecs"(80));
    getJson("/api/toolpipe/eval");   // force an idle update tick
    Thread.sleep(dur!"msecs"(40));
}
void redoStep() {
    postJson("/api/redo", "");
    Thread.sleep(dur!"msecs"(80));
    getJson("/api/toolpipe/eval");
    Thread.sleep(dur!"msecs"(40));
}

// --- principal-ring drag helpers (ported from test_xfrm_flex_rotate_axis_chain.d).
// A fixed-pixel ring grab is reliable for the FIRST gesture only — after a
// rotation the principal rings move on screen, so a chained 2nd gesture needs a
// projected, retried grab to reliably re-engage a principal ring.
double len(V3 v) { return sqrt(dot(v, v)); }
V3 scl(V3 v, double s) { return V3(v.x*s, v.y*s, v.z*s); }
V3 add(V3 a, V3 b) { return V3(a.x+b.x, a.y+b.y, a.z+b.z); }
bool projWorld(Cam cam, V3 w, out double px, out double py) {
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    return project(w, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, px, py);
}
// World-space gizmo radius (matches source/handler.d:gizmoSize, 90px default).
double gizmoRadius(Cam cam, V3 center) {
    double cx, cy;
    if (!projWorld(cam, center, cx, cy)) return 0.5;
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    V3 camRight = V3(view[0], view[4], view[8]);
    double rx, ry;
    if (!projWorld(cam, add(center, camRight), rx, ry)) return 0.5;
    double pxPerUnit = sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
    return pxPerUnit > 1e-6 ? 90.0 / pxPerUnit : 0.5;
}
void localFrame(V3 normal, out V3 right, out V3 up) {
    V3 fwd = norm(normal);
    V3 tmp = fabs(fwd.x) < 0.9 ? V3(1, 0, 0) : V3(0, 1, 0);
    right = norm(cross(fwd, tmp));
    up    = cross(right, fwd);
}
double arcStartAngle(V3 nAxis, V3 camFwd, V3 right, V3 up) {
    V3 dir = cross(nAxis, camFwd);
    double l = len(dir);
    if (l <= 1e-4) return 0.0;
    dir = scl(dir, 1.0 / l);
    V3 mid = cross(nAxis, dir);
    if (dot(mid, camFwd) < 0.0) dir = scl(dir, -1.0);
    return atan2(dot(dir, up), dot(dir, right));
}
// Drive ONE principal-ring ROTATE gesture about world axis `axisVec` at
// `center`, retrying on the undo count (a missed grab records nothing). Returns
// true once an entry is recorded. In a continuous session the rotation CHAINS on
// the persisted frame — exactly the path that exercises the mergeRun
// first.revert / last.apply coherence claim for an already-rotated frame.
bool ringRotate(V3 axisVec, V3 center, long wantCount, double arcDelta) {
    foreach (attempt; 0 .. 16) {
        Thread.sleep(dur!"msecs"(60));
        Cam cam = fetchCam();
        double radius = gizmoRadius(cam, center);
        V3 right, up;
        localFrame(axisVec, right, up);
        auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
        V3 camFwd = V3(-view[2], -view[6], -view[10]);
        double startAngle = arcStartAngle(norm(axisVec), camFwd, right, up);
        double pull = arcDelta + attempt * 0.08;
        double a0 = startAngle + PI / 2.0;
        double a1 = a0 + pull;
        V3 w0 = add(center, add(scl(right, cos(a0) * radius), scl(up, sin(a0) * radius)));
        V3 w1 = add(center, add(scl(right, cos(a1) * radius), scl(up, sin(a1) * radius)));
        double x0, y0, x1, y1;
        if (!projWorld(cam, w0, x0, y0)) continue;
        if (!projWorld(cam, w1, x1, y1)) continue;

        enum int steps = 18;
        play(format(
            `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
            `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            cam.vpX, cam.vpY, cam.w, cam.h, cast(int)x0, cast(int)y0));
        int lastX = cast(int)x0, lastY = cast(int)y0;
        double t = 100.0;
        foreach (i; 1 .. steps + 1) {
            int xx = cast(int)(x0 + (x1 - x0) * i / steps);
            int yy = cast(int)(y0 + (y1 - y0) * i / steps);
            play(format(
                `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
                t, xx, yy, xx - lastX, yy - lastY));
            lastX = xx; lastY = yy; t += 50.0;
        }
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
            t, cast(int)x1, cast(int)y1));
        Thread.sleep(dur!"msecs"(60));
        if (undoCount() >= wantCount) return true;
        // missed grab — nothing recorded; geometry unchanged, retry.
    }
    return false;
}

// Drive ONE flex MOVE arrow drag. Computes the move Z-arrow screen pixel
// dynamically so the hit is valid even after a prior rotate gesture has
// re-oriented the frame (the arrow points along local-fwd, not always world+Y).
void moveDragOnce(Cam cam) {
    V3 center = acenCenter();
    V3 mFwd   = norm(moveFwd());
    double gr = gizmoRadius(cam, center);
    // Arrow tip at center + fwd * gr (≈90 px out from center on screen).
    V3 tipWorld = add(center, scl(mFwd, gr));
    double bx0, by0;
    if (!projWorld(cam, tipWorld, bx0, by0)) { bx0 = 475; by0 = 314; }
    // Drag 60px further along the arrow direction in screen space.
    V3 farWorld = add(center, scl(mFwd, gr * 1.67));
    double bx1, by1;
    if (!projWorld(cam, farWorld, bx1, by1)) { bx1 = bx0; by1 = by0 - 60; }
    double dlen = sqrt((bx1-bx0)*(bx1-bx0) + (by1-by0)*(by1-by0));
    if (dlen > 1e-3) { bx1 = bx0 + (bx1-bx0)/dlen*60; by1 = by0 + (by1-by0)/dlen*60; }
    else { bx1 = bx0; by1 = by0 - 60; }
    int x0 = cast(int)bx0, y0 = cast(int)by0;
    int x1 = cast(int)bx1, y1 = cast(int)by1;
    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));
    int lastX = x0, lastY = y0; double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
    }
    play(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, x1, y1));
}

// =========================================================================
// ROTATE — pre-gesture frame + center vs post-undo frame + center.
// This is the crux: WITHOUT the fix rotFrameGap == the full rotation travel
// (the gizmo basis stays rotated over reverted-to-pristine geometry).
// =========================================================================
unittest {
    setupFlex();
    Cam cam = fetchCam();

    double ppx, ppy;
    assert(projectPivot(cam, ppx, ppy), "gizmo pivot off-camera");
    int x0 = cast(int)(ppx + 95), y0 = cast(int)ppy;
    int y1 = y0 - 70;

    // PRE-gesture pose (before any motion).
    V3 preRotRight  = rotateRight();
    V3 preMoveRight = moveRight();
    V3 preCenter    = acenCenter();

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));
    int lastY = y0; double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x0, yy, 0, yy - lastY));
        lastY = yy; t += 50.0;
    }
    play(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, x0, y1));

    // POST-gesture pose differs (the frame ROTATED).
    V3 postRotRight  = rotateRight();
    V3 postMoveRight = moveRight();
    double frameTravel = maxDev(postMoveRight, preMoveRight);
    assert(frameTravel > 0.1,
        "rotate gesture did not rotate the rendered frame (travel=" ~ frameTravel.to!string ~ ")");

    // In-session Ctrl+Z.
    postJson("/api/undo", "");
    Thread.sleep(dur!"msecs"(80));
    getJson("/api/toolpipe/eval");   // force an idle update tick
    Thread.sleep(dur!"msecs"(40));

    V3 undoRotRight  = rotateRight();
    V3 undoMoveRight = moveRight();
    V3 undoCenter    = acenCenter();

    // CENTER restore (already passing before the fix).
    double centerGap = maxDev(undoCenter, preCenter);
    // FRAME (basis) restore — the crux of this test.
    double rotFrameGap  = maxDev(undoRotRight,  preRotRight);
    double moveFrameGap = maxDev(undoMoveRight, preMoveRight);

    import std.stdio : writeln;
    writeln("[ROTATE] centerGap=", centerGap,
            " rotFrameGap=", rotFrameGap, " moveFrameGap=", moveFrameGap,
            " (post-gesture rotFrame moved by ", maxDev(postRotRight, preRotRight),
            ", moveFrame moved by ", frameTravel, ")");

    assert(centerGap < 1e-2,
        "ROTATE undo: center did NOT return to pre-gesture (gap=" ~ centerGap.to!string ~ ")");
    assert(rotFrameGap < 1e-2,
        "ROTATE undo: rendered ROTATE frame did NOT return to pre-gesture basis (gap="
        ~ rotFrameGap.to!string ~ " pre=" ~ preRotRight.to!string ~ " undo=" ~ undoRotRight.to!string ~ ")");
    assert(moveFrameGap < 1e-2,
        "ROTATE undo: rendered MOVE frame did NOT return to pre-gesture basis (gap="
        ~ moveFrameGap.to!string ~ " pre=" ~ preMoveRight.to!string ~ " undo=" ~ undoMoveRight.to!string ~ ")");
}

// =========================================================================
// MOVE — pre/post-undo frame + center (basis does not rotate during move,
// so the basis splice is restore-to-same; this pins that no-op invariant).
// =========================================================================
unittest {
    setupFlex();
    Cam cam = fetchCam();
    int x0 = 475, y0 = 314;
    int x1 = x0, y1 = y0 - 60;
    double ppx, ppy; assert(projectPivot(cam, ppx, ppy), "pivot off-camera");

    V3 preMoveRight = moveRight();
    V3 preCenter    = acenCenter();

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));
    int lastX = x0, lastY = y0; double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
    }
    play(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, x1, y1));

    V3 postCenter = acenCenter();
    assert(maxDev(postCenter, preCenter) > 0.05, "move gesture did not displace the center");

    postJson("/api/undo", "");
    Thread.sleep(dur!"msecs"(80));
    getJson("/api/toolpipe/eval");
    Thread.sleep(dur!"msecs"(40));

    V3 undoMoveRight = moveRight();
    V3 undoCenter    = acenCenter();
    double centerGap = maxDev(undoCenter, preCenter);
    double frameGap  = maxDev(undoMoveRight, preMoveRight);

    import std.stdio : writeln;
    writeln("[MOVE] centerGap=", centerGap, " frameGap=", frameGap);

    assert(centerGap < 1e-2,
        "MOVE undo: center did NOT return to pre-gesture (gap=" ~ centerGap.to!string
        ~ " pre=" ~ preCenter.to!string ~ " undo=" ~ undoCenter.to!string ~ ")");
    assert(frameGap < 1e-2,
        "MOVE undo: rendered MOVE frame did NOT return to pre-gesture basis (gap=" ~ frameGap.to!string ~ ")");
}

// =========================================================================
// SCALE — pre/post-undo frame + center (basis does not rotate during scale,
// so the basis splice is restore-to-same; this pins that no-op invariant).
// =========================================================================
unittest {
    setupFlex();
    Cam cam = fetchCam();
    double ppx, ppy; assert(projectPivot(cam, ppx, ppy), "pivot off-camera");
    int x0 = 475, y0 = 260;
    int x1 = x0, y1 = y0 - 55;

    V3 preScaleRight = scaleRight();
    V3 preCenter     = acenCenter();

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));
    int lastX = x0, lastY = y0; double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
    }
    play(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, x1, y1));

    auto sc = getJson("/api/toolpipe/eval")["transform"]["scale"].array;
    double scDev = fabs(sc[0].floating-1) + fabs(sc[1].floating-1) + fabs(sc[2].floating-1);
    assert(scDev > 0.05, "scale gesture did not engage (scDev=" ~ scDev.to!string ~ ")");

    postJson("/api/undo", "");
    Thread.sleep(dur!"msecs"(80));
    getJson("/api/toolpipe/eval");
    Thread.sleep(dur!"msecs"(40));

    V3 undoScaleRight = scaleRight();
    V3 undoCenter     = acenCenter();
    double centerGap = maxDev(undoCenter, preCenter);
    double frameGap  = maxDev(undoScaleRight, preScaleRight);

    import std.stdio : writeln;
    writeln("[SCALE] centerGap=", centerGap, " frameGap=", frameGap);

    assert(centerGap < 1e-2,
        "SCALE undo: center did NOT return to pre-gesture (gap=" ~ centerGap.to!string ~ ")");
    assert(frameGap < 1e-2,
        "SCALE undo: rendered SCALE frame did NOT return to pre-gesture basis (gap=" ~ frameGap.to!string ~ ")");
}

// =========================================================================
// ROTATE undo → REDO round-trip — after Ctrl+Z then Ctrl+Y the rendered
// basis must return to the POST-gesture (rotated) frame, not stay reverted.
// Guards the apply-hook end of the splice.
// =========================================================================
unittest {
    setupFlex();
    Cam cam = fetchCam();

    double ppx, ppy;
    assert(projectPivot(cam, ppx, ppy), "gizmo pivot off-camera");
    int x0 = cast(int)(ppx + 95), y0 = cast(int)ppy;
    int y1 = y0 - 70;

    V3 preRotRight = rotateRight();

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));
    int lastY = y0; double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x0, yy, 0, yy - lastY));
        lastY = yy; t += 50.0;
    }
    play(format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n", t, x0, y1));

    V3 postRotRight = rotateRight();
    double travel = maxDev(postRotRight, preRotRight);
    assert(travel > 0.1, "rotate gesture did not rotate the rendered frame");

    // Undo, then redo.
    postJson("/api/undo", "");
    Thread.sleep(dur!"msecs"(80));
    getJson("/api/toolpipe/eval");
    Thread.sleep(dur!"msecs"(40));
    postJson("/api/redo", "");
    Thread.sleep(dur!"msecs"(80));
    getJson("/api/toolpipe/eval");
    Thread.sleep(dur!"msecs"(40));

    V3 redoRotRight = rotateRight();
    double redoGap = maxDev(redoRotRight, postRotRight);

    import std.stdio : writeln;
    writeln("[ROTATE-REDO] redoGap=", redoGap, " (travel=", travel, ")");

    assert(redoGap < 1e-2,
        "ROTATE redo: rendered ROTATE frame did NOT return to post-gesture basis (gap="
        ~ redoGap.to!string ~ " post=" ~ postRotRight.to!string ~ " redo=" ~ redoRotRight.to!string ~ ")");
}

// =========================================================================
// MULTI-GESTURE CHAIN — TWO rotates back-to-back in ONE session (the second
// runs on the PERSISTED rotated frame the first left), then undo / undo /
// redo / redo. This is the path the single-gesture cases above do NOT cover:
// the 2nd gesture's frameStart is the prior gesture's rotated frameEnd, so the
// per-gesture splice must step the basis through the CHAINED frames — NOT jump
// straight to pristine or stay double-rotated. It exercises the mergeRun
// first.revert / last.apply coherence claim for an already-persisted frame.
//
//   pre → [rotate 1] → f1 → [rotate 2] → f2
//   undo  ⇒ basis returns to f1  (post-first, NOT pristine, NOT double-rotated)
//   undo  ⇒ basis returns to pre (pristine)
//   redo  ⇒ basis walks forward to f1
//   redo  ⇒ basis walks forward to f2
//
// Two consecutive same-bank ring drags are TWO in-session entries (no selection
// change / tool drop between them), so each Ctrl+Z pops one gesture.
//
// RED without the 2634ea2 fix: the per-gesture revert/apply hooks do NOT restore
// `frame`, so the idle renderBasis keeps the last persisted (f2) frame across
// every undo/redo step — the f1 and pristine assertions both fire.
// GREEN with the fix: the basis steps to f1, pristine, f1, f2 in lock-step.
// =========================================================================
unittest {
    setupFlex();

    V3 preRot = rotateRight();
    V3 pivot  = acenCenter();
    long c0 = undoCount();

    // GESTURE 1 — principal rotate about world Z, establishes the rotated frame f1.
    bool ok1 = ringRotate(V3(0, 0, 1), pivot, c0 + 1, 0.55);
    assert(ok1, "rotate-1 ring grab never recorded (ring-grab flake)");
    V3 f1Rot = rotateRight();
    long c1 = undoCount();
    double travel1 = maxDev(f1Rot, preRot);
    assert(travel1 > 0.1,
        "rotate-1 did not rotate the rendered frame (travel=" ~ travel1.to!string ~ ")");

    // GESTURE 2 (SAME session, no selection change) — a 2nd world-Z rotation
    // CHAINS on the persisted f1 frame, leaving f2. Pivot is unchanged (rotation
    // about its own pivot), but re-read for safety.
    pivot = acenCenter();
    bool ok2 = ringRotate(V3(0, 0, 1), pivot, c1 + 1, 0.55);
    assert(ok2, "rotate-2 ring grab never recorded — gestures did not chain");
    V3 f2Rot = rotateRight();
    long c2 = undoCount();
    assert(c2 > c1, "rotate-2 recorded no in-session entry — gestures did not chain");
    double travel2 = maxDev(f2Rot, f1Rot);
    assert(travel2 > 0.05,
        "rotate-2 did not further rotate the chained frame (travel=" ~ travel2.to!string ~ ")");

    import std.stdio : writeln;
    writeln("[CHAIN] preRot=", preRot, " f1=", f1Rot, " f2=", f2Rot,
            " travel1=", travel1, " travel2=", travel2);

    // ---- UNDO #1 → back to f1 (post-first), NOT pristine, NOT double-rotated.
    undoStep();
    V3 u1 = rotateRight();
    double gapU1ToF1  = maxDev(u1, f1Rot);
    double gapU1ToPre = maxDev(u1, preRot);
    writeln("[CHAIN] undo1 frame=", u1, " gapToF1=", gapU1ToF1, " gapToPre=", gapU1ToPre);
    assert(gapU1ToF1 < 1e-2,
        "CHAIN undo#1: basis did NOT return to post-FIRST frame (gap=" ~ gapU1ToF1.to!string
        ~ " f1=" ~ f1Rot.to!string ~ " undo1=" ~ u1.to!string ~ ")");
    assert(gapU1ToPre > 0.05,
        "CHAIN undo#1: basis jumped past f1 straight to pristine (it should step one gesture)");

    // ---- UNDO #2 → back to pristine (pre-first).
    undoStep();
    V3 u2 = rotateRight();
    double gapU2ToPre = maxDev(u2, preRot);
    writeln("[CHAIN] undo2 frame=", u2, " gapToPre=", gapU2ToPre);
    assert(gapU2ToPre < 1e-2,
        "CHAIN undo#2: basis did NOT return to PRISTINE pre-gesture frame (gap=" ~ gapU2ToPre.to!string
        ~ " pre=" ~ preRot.to!string ~ " undo2=" ~ u2.to!string ~ ")");

    // ---- REDO #1 → forward to f1.
    redoStep();
    V3 r1 = rotateRight();
    double gapR1ToF1 = maxDev(r1, f1Rot);
    writeln("[CHAIN] redo1 frame=", r1, " gapToF1=", gapR1ToF1);
    assert(gapR1ToF1 < 1e-2,
        "CHAIN redo#1: basis did NOT walk forward to post-FIRST frame (gap=" ~ gapR1ToF1.to!string
        ~ " f1=" ~ f1Rot.to!string ~ " redo1=" ~ r1.to!string ~ ")");

    // ---- REDO #2 → forward to f2.
    redoStep();
    V3 r2 = rotateRight();
    double gapR2ToF2 = maxDev(r2, f2Rot);
    writeln("[CHAIN] redo2 frame=", r2, " gapToF2=", gapR2ToF2);
    assert(gapR2ToF2 < 1e-2,
        "CHAIN redo#2: basis did NOT walk forward to post-SECOND frame (gap=" ~ gapR2ToF2.to!string
        ~ " f2=" ~ f2Rot.to!string ~ " redo2=" ~ r2.to!string ~ ")");
}

// =========================================================================
// CROSS-BANK CHAIN — ROTATE then MOVE in ONE session, then undo / undo. The
// bank switch consolidates the rotate run and opens a fresh move run, so the
// two gestures are two INDEPENDENT undo steps. The move gesture re-settles the
// live handler basis but does not rotate the frame, so:
//
//   pre → [rotate] → fRot → [move] → fRot (basis unchanged by the move)
//   undo (move)   ⇒ rotate basis still fRot (move splice is identity here)
//   undo (rotate) ⇒ rotate basis returns to pristine pre frame
//
// Pins that the basis restore stays coherent across a BANK boundary: the move
// undo must not disturb the persisted rotate frame, and the rotate undo must
// then return it all the way to pristine.
//
// RED without the fix: the rotate undo leaves the basis at the post-rotate
// (rotated) frame over reverted-to-pristine geometry — the pristine assert fires.
// =========================================================================
unittest {
    setupFlex();

    V3 preRot = rotateRight();
    V3 pivot  = acenCenter();
    long c0 = undoCount();

    // GESTURE 1 — rotate (establishes the rotated frame).
    bool okR = ringRotate(V3(0, 0, 1), pivot, c0 + 1, 0.55);
    assert(okR, "rotate ring grab never recorded (ring-grab flake)");
    V3 fRot = rotateRight();
    long c1 = undoCount();
    double travel = maxDev(fRot, preRot);
    assert(travel > 0.1,
        "rotate did not rotate the rendered frame (travel=" ~ travel.to!string ~ ")");

    // GESTURE 2 (SAME session) — move (cross-bank: consolidates the rotate run,
    // opens a fresh move run ⇒ independent undo step).
    Cam cam = fetchCam();
    moveDragOnce(cam);
    long c2 = undoCount();
    assert(c2 > c1, "move recorded no independent entry — bank boundary did not split the run");
    V3 afterMoveRot = rotateRight();
    double moveDisturbed = maxDev(afterMoveRot, fRot);

    import std.stdio : writeln;
    writeln("[XBANK] preRot=", preRot, " fRot=", fRot,
            " afterMoveRot=", afterMoveRot, " moveDisturbedRotFrame=", moveDisturbed);

    // ---- UNDO #1 (move) → rotate basis must stay at fRot (move did not rotate it).
    undoStep();
    V3 u1 = rotateRight();
    double gapU1ToFRot = maxDev(u1, fRot);
    writeln("[XBANK] undo1(move) rotFrame=", u1, " gapToFRot=", gapU1ToFRot);
    assert(gapU1ToFRot < 1e-2,
        "XBANK undo#1 (move): rotate basis drifted off the persisted rotated frame (gap="
        ~ gapU1ToFRot.to!string ~ " fRot=" ~ fRot.to!string ~ " undo1=" ~ u1.to!string ~ ")");

    // ---- UNDO #2 (rotate) → rotate basis returns to pristine pre frame.
    undoStep();
    V3 u2 = rotateRight();
    double gapU2ToPre = maxDev(u2, preRot);
    writeln("[XBANK] undo2(rotate) rotFrame=", u2, " gapToPre=", gapU2ToPre);
    assert(gapU2ToPre < 1e-2,
        "XBANK undo#2 (rotate): basis did NOT return to PRISTINE pre-gesture frame (gap="
        ~ gapU2ToPre.to!string ~ " pre=" ~ preRot.to!string ~ " undo2=" ~ u2.to!string ~ ")");
}
