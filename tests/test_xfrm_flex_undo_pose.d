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
import std.math : fabs, sqrt, tan, PI;
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
V3 moveRight()  { return readRight(getJson("/api/toolpipe/eval")["transform"]["moveRenderFrame"]); }
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
    int x0 = 418, y0 = 384;
    int x1 = x0 - 60, y1 = y0;
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
    int x0 = 400, y0 = 402;
    int x1 = x0 - 55, y1 = y0;

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
