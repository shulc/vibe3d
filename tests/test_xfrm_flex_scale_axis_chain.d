// Flex (acen=border, axis=select) SCALE AXIS CHAINING + no-oscillation — the
// applied single-axis scale must stay along the DISPLAYED (frozen, rotated)
// handle axis for the WHOLE drag, never flipping to another axis mid-drag.
//
// flex_border_handles_plan.md gesture-chaining follow-up, scale arm. In ONE
// continuous tool session (no reset / selection change / tool drop between
// gestures — the GUI flow), a flex rotate about Z then a single-axis scale on
// the displayed rotated Z box: the Z box is DRAWN in the Z-rotated frame
// (R_gesture·softBasis) and the scale INPUT basis (scaleSub.inputBasis* in
// beginScaleDragSession) chains off the same softBasis — but BEFORE the fix the
// APPLY axis was read from the LIVE select-derived currentBasis (bX/bY/bZ) in
// the global fold, NOT the frozen softBasis-chained run frame.
//
// Root cause (xfrm_transform.d applyFold GLOBAL path): the fold's TRANSLATE term
// already projects run.t along the FROZEN runFrame (P-F), and the ROTATE term
// chains via rotateChain* (d4e0ea0) — but the SCALE term was handed the live
// `bX/bY/bZ` (currentBasis re-derived per applyTRS frame from the DEFORMING
// mesh). axis.d computeSelectionBboxBasis world-snaps `right` to the world axis
// of LARGEST in-plane bbox extent; a single-axis scale changes the selection's
// bbox aspect ratio, so as the drag crosses an extent tie that axis SWAPS and
// swaps BACK → the applied scale axis OSCILLATES A→B→A within one drag (the
// user-found scale-after-rotate flip). Render chained + input chained, APPLY
// not — and apply additionally flipped.
//
// The fix sources the global fold's scale axes (ax/ay/az) from the SAME frozen
// runFrame the translate term uses, so render + input + APPLY all agree on one
// frozen, possibly-rotated frame for the whole drag.
//
// What this asserts — a single-axis scale along unit axis `a` about pivot `p`
// moves each vertex by a displacement PARALLEL to `a`
// (disp = (s-1)·((v-p)·a)·a). So the moved-set displacement DIRECTION is the
// engine-independent witness of the applied axis. The displayed scale-Z axis is
// `scaleRenderFrame.fwd` (frozen, softBasis-chained — verified stable here). Per
// step we assert the incremental displacement is CLEAN along that displayed Z:
// |disp·Z| beats 2× the larger in-plane sibling (|disp·X|,|disp·Y| ~ 0). The
// rotate gesture is dropped (R off) before the scale so the Z box grab is
// unambiguous AND the displayed Z stays world-aligned (a Z-rotation fixes Z), so
// the apply-axis CONTAMINATION the bug introduces is an X/Y leak, not a rotation.
// The very first motion step (button-down center-settle) is skipped.
//
//   RED   without the fix (HEAD d4e0ea0): the global fold's scale axis reads the
//         live world-snapped currentBasis (axis.d computeSelectionBboxBasis),
//         which is NOT the run's frozen frame — a chained scale reuses the prior
//         gesture's still-open run whose runFrame is the original world frame, and
//         the live read additionally leaks/flips its largest-extent axis as the
//         bbox deforms → every step's displacement carries a large, growing in-
//         plane (X) component (~80% of Z) → 19/19 steps fail the clean-Z margin.
//   GREEN with the fix: the scale axis is sourced from softBasis (same frozen,
//         rotated frame the displayed boxes + the input projection use), so every
//         step's displacement is clean Z (|disp·X|=|disp·Y|~0), no flip/leak.
//
// Modeled on tests/test_xfrm_flex_rotate_axis_chain.d (chunked-drag harness +
// principal-ring gesture) and tests/test_xfrm_scale_flip_drag.d (scale Z box
// grab pixel 400,402 on the deforming Border patch).

import std.net.curl;
import std.json;
import std.math : fabs, sqrt, sin, cos, atan2, PI, tan;
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
double len(V3 v) { return sqrt(dot(v, v)); }
V3 norm(V3 v) { double L = len(v); return L > 1e-12 ? V3(v.x/L, v.y/L, v.z/L) : V3(0, 0, 0); }
V3 scl(V3 v, double s) { return V3(v.x*s, v.y*s, v.z*s); }
V3 add(V3 a, V3 b) { return V3(a.x+b.x, a.y+b.y, a.z+b.z); }

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
bool projWorld(Cam cam, V3 w, out double px, out double py) {
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    return project(w, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, px, py);
}
// World units per 90px (matches source/handler.d:gizmoSize default), so a
// gizmo handle drawn at `center + axis * gizmoUnits` projects ~90px out.
double gizmoUnits(Cam cam, V3 center) {
    double cx, cy;
    if (!projWorld(cam, center, cx, cy)) return 0.5;
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    V3 camRight = V3(view[0], view[4], view[8]);
    double rx, ry;
    if (!projWorld(cam, add(center, camRight), rx, ry)) return 0.5;
    double pxPerUnit = sqrt((rx-cx)*(rx-cx) + (ry-cy)*(ry-cy));
    return pxPerUnit > 1e-6 ? 90.0 / pxPerUnit : 0.5;
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

V3 readVec(JSONValue arr) {
    auto a = arr.array;
    return V3(a[0].floating, a[1].floating, a[2].floating);
}
V3 scaleFwd() { return readVec(getJson("/api/toolpipe/eval")["transform"]["scaleRenderFrame"]["fwd"]); }
V3 scaleRight() { return readVec(getJson("/api/toolpipe/eval")["transform"]["scaleRenderFrame"]["right"]); }
V3 scaleUp()  { return readVec(getJson("/api/toolpipe/eval")["transform"]["scaleRenderFrame"]["up"]); }
V3 rotateRight() { return readVec(getJson("/api/toolpipe/eval")["transform"]["rotateRenderFrame"]["right"]); }
V3 acenCenter() {
    return readVec(getJson("/api/toolpipe/eval")["actionCenter"]["center"]);
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
long undoCount() { return getJson("/api/history")["undo"].array.length; }

// Mean incremental displacement between pre and now, restricted to verts that
// actually moved this step. Returns the moved-set mean delta as a vector.
V3 meanDelta(double[3][] pre, double[3][] now, out int n) {
    V3 acc; n = 0;
    foreach (k; 0 .. pre.length) {
        V3 d = V3(now[k][0]-pre[k][0], now[k][1]-pre[k][1], now[k][2]-pre[k][2]);
        if (len(d) < 5e-4) continue;
        acc = add(acc, d);
        n++;
    }
    return n > 0 ? scl(acc, 1.0 / n) : V3(0, 0, 0);
}
// Mean |component of disp along axis| over the moved set (axis assumed unit).
double meanAlong(double[3][] pre, double[3][] now, V3 axis, out int n) {
    double acc = 0; n = 0;
    foreach (k; 0 .. pre.length) {
        V3 d = V3(now[k][0]-pre[k][0], now[k][1]-pre[k][1], now[k][2]-pre[k][2]);
        if (len(d) < 5e-4) continue;
        acc += fabs(dot(d, axis));
        n++;
    }
    return n > 0 ? acc / n : 0;
}

// ---- principal ring drag (replica of test_xfrm_flex_rotate_axis_chain) -------
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
bool ringGesture(V3 axisVec, V3 center, long wantCount, double arcDelta) {
    foreach (attempt; 0 .. 16) {
        Thread.sleep(dur!"msecs"(60));
        Cam cam = fetchCam();
        double radius = gizmoUnits(cam, center);
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
    }
    return false;
}

// Select the upper region of the subdivcube — a large patch giving a stable
// Border pivot AND enough moved verts that the displacement direction is well
// above noise (mirrors the rotate-axis-chain + scale-flip tests).
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
    // T OFF so no move arrows occlude the scale Z box; R ON so the rotate
    // gesture can establish softBasis; S ON for the chained scale.
    cmd("tool.attr xfrm.flex T false");
    cmd("tool.attr xfrm.flex R true");
    cmd("tool.attr xfrm.flex S true");
}

unittest {
    setupFlex();

    V3 pivot = acenCenter();

    // ---- GESTURE 1: principal rotate about WORLD Z (establishes softBasis) ----
    long want = undoCount() + 1;
    bool ok1 = ringGesture(V3(0, 0, 1), pivot, want, 0.55);
    assert(ok1, "gesture-1 (rotate Z) ring grab never recorded (ring-grab flake)");

    // The Z rotation re-oriented the in-plane handle axes: the rendered scale
    // RIGHT (= rotated X) is now off world X. (Rotated Z ~ world Z, since a
    // Z-rotation fixes Z — the apply-axis FLIP this test catches is a swap of
    // the largest-extent in-plane axis, independent of that.)
    V3 srRight = scaleRight();
    double rotDev = maxDev(srRight, V3(1, 0, 0));
    assert(rotDev > 0.15,
        "gesture-1 did not rotate the scale frame off world (dev=" ~ rotDev.to!string
        ~ ") — softBasis precondition failed.");
    pivot = acenCenter();

    // Drop the rotate bank now that softBasis is established: a same-session attr
    // toggle (NOT a tool drop / re-activate) leaves softBasis intact (clearSoftBasis
    // fires only on activate / selection / ACEN-mode change), but removes the rotate
    // RING from the gizmo so the scale-Z box grab below is unambiguous (the ring sits
    // at ~gizmo radius, overlapping the Z arrow's screen projection — with R on the
    // grab would land on the ring and run a ROTATE, not the scale we mean to test).
    cmd("tool.attr xfrm.flex R false");

    // The DISPLAYED scale axes (frozen, softBasis-chained render frame). The
    // single-axis Z scale must apply along scaleZ for the whole drag.
    V3 scaleZ = norm(scaleFwd());
    V3 scaleX = norm(scaleRight());
    V3 scaleY = norm(scaleUp());

    // ---- GESTURE 2 (SAME SESSION): drag the DISPLAYED scale Z box -------------
    // No reset / selection change / tool drop. Use the proven scale Z-arrow shaft
    // pixel (400,402 — see test_xfrm_scale_flip_drag.d: hitPart 2, the single-axis
    // scale path, NOT the uniform centre disc) at the SAME camera. Drag 70px toward
    // screen-left (scale up) in CHUNKS — one play-events per step, button held.
    Cam cam = fetchCam();
    // Confirm the scale pivot projects on-camera (camera-setup guard).
    double px, py;
    assert(projWorld(cam, pivot, px, py), "scale pivot off-camera — camera changed");
    int x0 = 400, y0 = 402;
    int x1 = x0 - 70, y1 = y0;
    enum int steps = 20;

    want = undoCount() + 1;
    double[3][] gestureStart = dumpVerts();   // whole-gesture pre dump
    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));

    // Per-step incremental displacement direction witness.
    double[3][] prev = gestureStart;
    int lastX = x0, lastY = y0;
    double t = 100.0;
    int flips = 0;          // steps whose dominant axis was NOT the displayed Z
    int measured = 0;       // steps with enough motion to witness
    double[3][] postSettle = gestureStart;   // baseline after the step-1 settle
    foreach (i; 1 .. steps + 1) {
        int xx = x0 + cast(int)(cast(double)(x1 - x0) * i / steps);
        int yy = y0 + cast(int)(cast(double)(y1 - y0) * i / steps);
        play(format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":%d,"state":1,"mod":0}` ~ "\n",
            t, xx, yy, xx - lastX, yy - lastY));
        lastX = xx; lastY = yy; t += 50.0;

        double[3][] now = dumpVerts();
        // Skip the FIRST motion step: the button-down → first-motion transition
        // carries a one-frame center-settle / click-relocate transient (a whole-
        // selection shift as the Border pivot re-pins on the run's first apply),
        // present on HEAD and with the fix alike — not the apply-axis we test.
        // Pin the post-settle dump as the cumulative baseline so that transient is
        // excluded from the whole-gesture check too.
        if (i == 1) { prev = now; postSettle = now; continue; }
        int nz, nx, ny;
        double alongZ = meanAlong(prev, now, scaleZ, nz);
        double alongX = meanAlong(prev, now, scaleX, nx);
        double alongY = meanAlong(prev, now, scaleY, ny);
        if (nz >= 5) {
            measured++;
            // The dominant per-step displacement axis must be the DISPLAYED Z.
            // A mid-drag apply-axis flip points the increment along an in-plane
            // sibling (X or Y) instead → dominant axis != Z on that step. Use a
            // clear MARGIN (Z beats 2× the larger sibling) so a contaminated apply
            // axis (HEAD reads the live world-snapped basis → a persistent ~80%-of-Z
            // X leak that grows with the deformation) trips it, not just an exact tie.
            double sib = alongX > alongY ? alongX : alongY;
            bool zClean = alongZ > 2.0 * sib;
            if (!zClean) flips++;
        }
        prev = now;
    }
    play(format(
        `{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        t, x1, y1));
    Thread.sleep(dur!"msecs"(60));

    assert(measured >= 8,
        "scale drag moved too few verts across steps (" ~ measured.to!string
        ~ ") to witness the apply axis — drag missed the scale Z box.");

    // THE FIX: the applied scale axis is the frozen displayed Z on EVERY step.
    //
    // RED without the fix: the global fold's scale axis reads the live
    // world-snapped basis (axis.d computeSelectionBboxBasis), whose largest-
    // in-plane-extent axis swaps as the bbox deforms → on the flip steps the
    // dominant displacement axis is an in-plane sibling, not Z → flips > 0.
    assert(flips == 0,
        "scale apply axis FLIPPED on " ~ flips.to!string ~ " of " ~ measured.to!string
        ~ " steps — the applied single-axis scale did not stay along the displayed "
        ~ "(frozen, rotated) Z box (scale-axis chaining / frozen-frame missing; the "
        ~ "global fold read the live select-derived basis).");

    // And the cumulative motion from the post-settle baseline to gesture end is
    // clearly Z-dominant (a strong check that the apply axis was Z throughout, not
    // a near-tie the per-step test could pass by noise). HEAD's growing X leak makes
    // cumX rival cumZ; the fix keeps cumX/cumY ~0.
    double[3][] gestureEnd = dumpVerts();
    int nzAll, nxAll, nyAll;
    double cumZ = meanAlong(postSettle, gestureEnd, scaleZ, nzAll);
    double cumX = meanAlong(postSettle, gestureEnd, scaleX, nxAll);
    double cumY = meanAlong(postSettle, gestureEnd, scaleY, nyAll);
    assert(nzAll >= 8, "cumulative scale moved too few verts (" ~ nzAll.to!string ~ ")");
    double cumSib = cumX > cumY ? cumX : cumY;
    assert(cumZ > 2.0 * cumSib,
        "cumulative scale displacement is not Z-dominant (|·Z|=" ~ cumZ.to!string
        ~ ", |·X|=" ~ cumX.to!string ~ ", |·Y|=" ~ cumY.to!string
        ~ ") — the applied scale axis was not the displayed Z.");
}
