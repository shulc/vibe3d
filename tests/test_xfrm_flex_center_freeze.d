// Flex gesture-frozen ACTION CENTER — a completed translate / rotate / scale
// leaves the gizmo at its DROP pose, no jump-back to the fractional falloff
// border center (flex_border_handles_plan.md Phase 3, BUG-1, generalized).
//
// Pre-fix: in Flex mode (`xfrm.flex`: actionCenter=border, axis=select,
// falloff=selection) a partial selection's gizmo settled at the full-delta drop
// during a drag, but on LMB-up `computeCenter` (Border) recomputed the border
// bbox center of the now-WEIGHTED (falloff-attenuated) moving set, snapping the
// gizmo back toward the original pivot. The fix generalizes the existing
// `softPlaced` settle: the wrapper's ONE settleGestureCenter() helper pins the
// drop center for ALL completed gestures (no relocate gate, no `mode==border`
// branch — the 2-entry acenSettleAllowed() predicate only excludes Element +
// Local), and computeCenter consults softPlaced ahead of the Border / Select
// live recompute. The pin persists until selection/mode change.
//
// What this asserts, for translate / rotate / scale each on a Border partial
// selection:
//   1. After LMB-up, the published gizmoCenter == the LAST during-drag center
//      within eps (NO jump-back to the fractional border).
//   2. The falloff sphere anchor (actionCenter.center, which FalloffStage reads)
//      MOVED with the gizmo to the frozen drop center (Risk 4 — desired).
//   3. For translate, the drop == the FULL offset (not the attenuated border).
//   4. An in-session Ctrl+Z after a frozen-frame rotate / scale HOLDS the gizmo
//      center (the undo-splice carries the soft pin) — it doesn't float.
//
// Element-move (liveElementCenter precedence intact) is covered by the existing
// test_element_pick_drag_gizmo.d; acen.local pivots by test_acen_local_*.

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

// The live action-center (== falloff sphere anchor) and the live Move-bank
// gizmo center, from the rendered-pose seam.
V3 acenCenter() {
    auto a = getJson("/api/toolpipe/eval")["actionCenter"]["center"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
V3 gizmoCenter() {
    auto a = getJson("/api/toolpipe/eval")["transform"]["gizmoCenter"].array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
// The LIVE rendered bank `right` vectors (rendered-pose seam) — the orientation
// the move / scale / rotate handles actually drew this frame.
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
    m = fabs(a.z-b.z) > m ? fabs(a.z-b.z) : m;
    return m;
}

// Select the upper-region face patch — a PARTIAL set with a moving interior, so
// the Border center is genuinely a fraction of the full selection and the
// falloff attenuates the deeper verts (the snap-back vector pre-fix).
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

void setupFlex() {
    postJson("/api/reset?type=subdivcube&levels=2", "");
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    selectUpperRegion();
    cmd("tool.set xfrm.flex on");
    cmd("tool.attr xfrm.flex T true");
    cmd("tool.attr xfrm.flex R true");
    cmd("tool.attr xfrm.flex S true");
}

// Project the LIVE gizmo pivot to screen pixels (border center for flex).
bool projectPivot(Cam cam, out double ppx, out double ppy) {
    V3 pivot = acenCenter();
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    return project(pivot, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, ppx, ppy);
}

// =========================================================================
// TRANSLATE — Move Z-arrow chunked drag; gizmo must hold at the full drop.
// =========================================================================
unittest {
    setupFlex();
    Cam cam = fetchCam();

    // The move Z-arrow at this camera lands near (418,384) — same hard-coded
    // pixel test_xfrm_flex_drag.d uses (hitPart 2, MoveTool axis-drag path).
    int x0 = 418, y0 = 384;
    int x1 = x0 - 60, y1 = y0;

    double ppx, ppy;
    assert(projectPivot(cam, ppx, ppy), "gizmo pivot off-camera — camera changed");

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    V3 startGizmo = gizmoCenter();
    V3 lastDuringDrag = startGizmo;
    int lastX = x0, lastY = y0;
    double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
        lastDuringDrag = gizmoCenter();   // sample the during-drag gizmo each step
    }

    // The gizmo must have actually followed the drag (settled away from start).
    double dragTravel = maxDev(lastDuringDrag, startGizmo);
    assert(dragTravel > 0.1,
        "Flex move drag did not move the gizmo (travel=" ~ dragTravel.to!string
        ~ ") — handle hit-test / selection setup is wrong");

    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x1, y1));

    // BUG-1: post-release the gizmo HOLDS at the last during-drag center — no
    // jump-back to the fractional border. Pre-fix it snapped a measurable
    // fraction of dragTravel back toward the original pivot.
    V3 afterUp = gizmoCenter();
    double jumpBack = maxDev(afterUp, lastDuringDrag);
    assert(jumpBack < 1e-3,
        "Flex move gizmo JUMPED BACK on release (jump=" ~ jumpBack.to!string
        ~ ", drop=" ~ lastDuringDrag.to!string ~ " after=" ~ afterUp.to!string
        ~ ") — gesture center-freeze regressed (bug 1).");

    // Falloff sphere anchor (FalloffStage reads actionCenter.center) followed the
    // gizmo to the frozen drop center, NOT the recomputed border center.
    V3 anchor = acenCenter();
    assert(maxDev(anchor, afterUp) < 1e-3,
        "falloff anchor (actionCenter.center=" ~ anchor.to!string
        ~ ") did NOT follow the frozen drop center (" ~ afterUp.to!string
        ~ ") — the sphere must move with the dropped gizmo (Risk 4).");

    // The drop is the FULL offset: it sits well off the original border center.
    double fullOffset = maxDev(afterUp, startGizmo);
    assert(fullOffset > 0.1,
        "Flex move drop collapsed back to the border center (offset="
        ~ fullOffset.to!string ~ ") — falloff attenuation snapped the pivot.");
}

// =========================================================================
// ROTATE — view-ring chunked drag; gizmo center holds + in-session undo holds.
// =========================================================================
unittest {
    setupFlex();
    Cam cam = fetchCam();

    double ppx, ppy;
    assert(projectPivot(cam, ppx, ppy), "gizmo pivot off-camera — camera changed");
    int x0 = cast(int)(ppx + 95), y0 = cast(int)ppy;   // on the view-ring
    int y1 = y0 - 70;

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    V3 lastDuringDrag = gizmoCenter();
    int lastY = y0;
    double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x0, yy, 0, yy - lastY));
        lastY = yy; t += 50.0;
        lastDuringDrag = gizmoCenter();
    }

    // Confirm the ring engaged (a real rotation accumulated).
    auto rot = getJson("/api/toolpipe/eval")["transform"]["rotate"].array;
    double rotMag = fabs(rot[0].floating) + fabs(rot[1].floating) + fabs(rot[2].floating);
    assert(rotMag > 10.0,
        "flex view-ring drag produced too small a rotation (" ~ rotMag.to!string
        ~ " deg) — ring hit-test / drag is wrong");

    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y1));

    // BUG-1: rotate releases without a center snap-back (it also closes the
    // Phase-2 rotate-release basis revert path for the CENTER; basis is COMMIT B).
    V3 afterUp = gizmoCenter();
    assert(maxDev(afterUp, lastDuringDrag) < 1e-3,
        "Flex rotate gizmo center JUMPED on release (drop=" ~ lastDuringDrag.to!string
        ~ " after=" ~ afterUp.to!string ~ ") — gesture center-freeze regressed.");
    assert(maxDev(acenCenter(), afterUp) < 1e-3,
        "falloff anchor did not follow the frozen rotate drop center.");

    // In-session Ctrl+Z: geometry reverts one gesture, and the soft-pin splice in
    // the rotate undo hook restores the pin in lockstep — the gizmo center HOLDS
    // (a definite point, not floating / NaN). Without the splice the revert hook
    // would leave the soft pin stale, snapping the gizmo to the weighted centroid.
    postJson("/api/undo", "");
    Thread.sleep(dur!"msecs"(60));
    V3 afterUndo = gizmoCenter();
    assert(afterUndo.x == afterUndo.x && afterUndo.y == afterUndo.y
        && afterUndo.z == afterUndo.z,
        "Flex rotate gizmo center is NaN after in-session undo — soft-pin splice "
        ~ "missing on the rotate undo hook.");
    // The undo restores a coherent published center (the pivot the run reverted to)
    // — assert it published a finite point the falloff anchor agrees with.
    assert(maxDev(acenCenter(), afterUndo) < 1e-2,
        "after rotate undo the falloff anchor (" ~ acenCenter().to!string
        ~ ") and gizmo center (" ~ afterUndo.to!string ~ ") diverged — the "
        ~ "undo-splice left the soft pin inconsistent.");
}

// =========================================================================
// SCALE — center-disk-adjacent box chunked drag; gizmo holds + undo holds.
// =========================================================================
unittest {
    setupFlex();
    Cam cam = fetchCam();

    double ppx, ppy;
    assert(projectPivot(cam, ppx, ppy), "gizmo pivot off-camera — camera changed");
    // The scale Z-box at this camera lands near the move Z-arrow tip; the scale
    // bank draws at the same shared basis. Grab the Z-box at the move-arrow pixel
    // region but route via the scale bank by offsetting onto the box past the
    // arrow tip (empirically ~ (400,402)). Drag toward screen-left to scale up.
    int x0 = 400, y0 = 402;
    int x1 = x0 - 55, y1 = y0;

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    V3 lastDuringDrag = gizmoCenter();
    int lastX = x0, lastY = y0;
    double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;
        lastDuringDrag = gizmoCenter();
    }

    // Confirm the scale bank engaged (run scale moved off identity).
    auto sc = getJson("/api/toolpipe/eval")["transform"]["scale"].array;
    double scDev = fabs(sc[0].floating - 1) + fabs(sc[1].floating - 1) + fabs(sc[2].floating - 1);
    assert(scDev > 0.05,
        "flex scale drag produced too small a scale (" ~ scDev.to!string
        ~ ") — scale-box hit-test / drag is wrong");

    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x1, y1));

    // BUG-1: scale releases without a center jump-back (scale never translates the
    // pivot, so the drop == the pivot; the soft pin holds it through the post-up
    // border recompute that would otherwise drift on the deformed selection).
    V3 afterUp = gizmoCenter();
    assert(maxDev(afterUp, lastDuringDrag) < 1e-3,
        "Flex scale gizmo center JUMPED on release (drop=" ~ lastDuringDrag.to!string
        ~ " after=" ~ afterUp.to!string ~ ") — gesture center-freeze regressed.");
    assert(maxDev(acenCenter(), afterUp) < 1e-3,
        "falloff anchor did not follow the frozen scale drop center.");

    // In-session undo: the soft-pin splice in the scale undo hook keeps the gizmo
    // center finite + consistent with the falloff anchor (mirror of rotate).
    postJson("/api/undo", "");
    Thread.sleep(dur!"msecs"(60));
    V3 afterUndo = gizmoCenter();
    assert(afterUndo.x == afterUndo.x && afterUndo.y == afterUndo.y
        && afterUndo.z == afterUndo.z,
        "Flex scale gizmo center is NaN after in-session undo — soft-pin splice "
        ~ "missing on the scale undo hook.");
    assert(maxDev(acenCenter(), afterUndo) < 1e-2,
        "after scale undo the falloff anchor and gizmo center diverged — the "
        ~ "undo-splice left the soft pin inconsistent.");
}

// =========================================================================
// COMMIT B — gesture-end BASIS persists post-release (no rotate-release snap).
//
// After a flex ROTATE LMB-up, the rendered move / scale / rotate triples must
// STAY at their gesture-end (rotated) orientation — NOT snap back to the
// world-snapped idle currentBasis — until a selection change, after which they
// re-derive. The persistence rides the same softPlaced lifecycle (one clear on
// selection/mode change), and is captured EXPLICITLY at mouse-up so a boundary
// resetRun cannot strand it.
// =========================================================================
unittest {
    setupFlex();
    Cam cam = fetchCam();

    double ppx, ppy;
    assert(projectPivot(cam, ppx, ppy), "gizmo pivot off-camera — camera changed");
    int x0 = cast(int)(ppx + 95), y0 = cast(int)ppy;   // on the view-ring
    int y1 = y0 - 70;

    enum int steps = 20;
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    // Drag-start rendered move/scale right (button down, before motion) — the
    // pre-rotation (idle B0) orientation, so we can prove the siblings MOVED.
    V3 moveStart  = moveRight();
    V3 scaleStart = scaleRight();

    V3 moveLastDrag = moveStart, scaleLastDrag = scaleStart, rotLastDrag;
    int lastY = y0;
    double t = 100.0;
    foreach (i; 1 .. steps + 1) {
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, x0, yy, 0, yy - lastY));
        lastY = yy; t += 50.0;
        moveLastDrag  = moveRight();
        scaleLastDrag = scaleRight();
        rotLastDrag   = rotateRight();
    }

    // The siblings followed the rotation during the drag (bug-3 path, sanity).
    assert(maxDev(moveLastDrag, moveStart) > 0.1,
        "flex rotate: move sibling did not follow during the drag (basis-persist "
        ~ "test precondition) — Phase 2 follow regressed.");

    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x0, y1));

    // COMMIT B: after release the rendered triples HOLD at the gesture-end
    // orientation — no snap back to the world-snapped idle currentBasis.
    enum double holdEps = 5e-3;
    V3 moveAfter  = moveRight();
    V3 scaleAfter = scaleRight();
    V3 rotAfter   = rotateRight();
    assert(maxDev(moveAfter, moveLastDrag) < holdEps,
        "flex rotate-release: MOVE rendered basis SNAPPED back (drop="
        ~ moveLastDrag.to!string ~ " after=" ~ moveAfter.to!string
        ~ ") — gesture-end basis persistence regressed (Commit B).");
    assert(maxDev(scaleAfter, scaleLastDrag) < holdEps,
        "flex rotate-release: SCALE rendered basis SNAPPED back (drop="
        ~ scaleLastDrag.to!string ~ " after=" ~ scaleAfter.to!string
        ~ ") — gesture-end basis persistence regressed (Commit B).");
    assert(maxDev(rotAfter, rotLastDrag) < holdEps,
        "flex rotate-release: ROTATE rendered basis SNAPPED back (drop="
        ~ rotLastDrag.to!string ~ " after=" ~ rotAfter.to!string
        ~ ") — gesture-end basis persistence regressed (Commit B).");
    // And it really moved off the pre-rotation idle basis (so the hold is the
    // ROTATED frame, not a coincidental world-snap match).
    assert(maxDev(moveAfter, moveStart) > 0.1,
        "flex rotate-release: persisted MOVE basis equals the PRE-rotation basis "
        ~ "(" ~ moveAfter.to!string ~ ") — it snapped to idle after all.");

    // After a SELECTION change the persisted basis is dropped and the gizmo
    // re-derives from the new selection (the one-lifecycle clear). Reselect a
    // DIFFERENT partial patch and confirm the rendered basis is no longer pinned
    // to the rotated frame (it now reflects the fresh selection's world-snap).
    auto model = getJson("/api/model");
    auto verts = model["vertices"].array;
    auto faces = model["faces"].array;
    int[] sel2;
    foreach (fi, f; faces) {
        auto idx = f.array;
        double cx = 0;
        foreach (vi; idx) cx += verts[cast(size_t)vi.integer].array[0].floating;
        cx /= idx.length;
        if (cx > 0.1) sel2 ~= cast(int)fi;     // a different (right-side) patch
    }
    assert(sel2.length > 10, "expected a right-side patch for the re-derive check");
    string s2 = "[";
    foreach (i, s; sel2) s2 ~= (i ? "," : "") ~ s.to!string;
    s2 ~= "]";
    postJson("/api/select", `{"mode":"polygons","indices":` ~ s2 ~ `}`);
    Thread.sleep(dur!"msecs"(80));
    // Force an idle update tick so the selection-change boundary fires its clear.
    getJson("/api/toolpipe/eval");
    Thread.sleep(dur!"msecs"(40));

    V3 moveReDerive = moveRight();
    assert(maxDev(moveReDerive, moveAfter) > 1e-3,
        "flex: a selection change did NOT re-derive the rendered basis (still "
        ~ "pinned to the rotated frame " ~ moveAfter.to!string ~ ") — the "
        ~ "soft-basis clear hook is not firing on selection change (Commit B).");
}
