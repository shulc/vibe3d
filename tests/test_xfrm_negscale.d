// Task 0332 — Negative Scale (`negScale` param on the XfrmTransformTool /
// `scale` tool family).
//
// Capture-settled scope (Phase 0 gate resolved before this landed):
//   - Geometry law (W1): a negative-axis scale factor MIRRORS vertex
//     positions through the pivot with polygon vertex-index order
//     UNCHANGED (winding is NOT auto-reversed) — normals invert on
//     non-perpendicular faces, left as-is (reference-faithful "inside-out",
//     not a bug). This is flag-independent: it is the geometry LAW for any
//     negative scale factor that reaches the kernel, regardless of how it
//     got there.
//   - Clamp gate: `negScale` (default OFF) gates the scale-factor floor on
//     EVERY path that can reach the kernel — source/tools/transform/scale.d's
//     `clampScaleFactor` (gizmo drag) and `applyScalePanelValue` (panel
//     write), source/tools/transform/xfrm_transform.d's uniform-slider
//     post-write clamp and `applyScaleAbsoluteFromRun` (live/panel door), and
//     since task 3310 `applyHeadless` (the NUMERIC door: `tool.attr SX …` +
//     `tool.doApply`).
//
//     TASK 3310 CHANGED WHAT CASE 1 CAN SAY. Until then the numeric door read
//     `run.s.x/y/z` with NO floor at all, so Case 1 could drive a negative
//     factor through it at either flag state and pin the W1 geometry law
//     flag-independently. That was a DIVERGENCE, not a design: the reference
//     accepts a typed negative scale and stores `max(+0.0, v)` while the
//     option is off — measured 2026-08-29, frozen as
//     `tests/fixtures/scale_negative_typed_value.json`, gap-registry row 85.
//     With the numeric door floored, a typed `SX -1` at the DEFAULT flag state
//     no longer mirrors; it collapses to the pivot. So W1 is now exercised with
//     the option explicitly ON (Case 1), and the floor the fix installed is
//     exercised with it OFF (Case 1b) — the same input, the flag the only thing
//     that varies, which is what makes the pair evidence about the flag.
//     Cases 2/3 drive an actual interactive gizmo drag, and Cases 4/5 the
//     live-session panel write.
//
// No reference-editor names appear in this file (project neutrality
// convention) — the frozen capture that settled the W1/clamp verdicts is
// recorded in the (private) task planning doc, not here.

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
void reset() {
    auto r = postJson("/api/reset", "");
    assert(r["status"].str == "ok", "reset failed");
}

double[3][] dumpVerts() {
    double[3][] outv;
    foreach (v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        double toF(JSONValue jv) {
            if (jv.type == JSONType.float_)   return jv.floating;
            if (jv.type == JSONType.integer)  return cast(double) jv.integer;
            if (jv.type == JSONType.uinteger) return cast(double) jv.uinteger;
            assert(false, "unexpected JSON number type");
        }
        outv ~= [toF(a[0]), toF(a[1]), toF(a[2])];
    }
    return outv;
}

long[][] dumpFaces() {
    long[][] outf;
    foreach (f; getJson("/api/model")["faces"].array) {
        long[] idx;
        foreach (vi; f.array) idx ~= vi.integer;
        outf ~= idx;
    }
    return outf;
}

void assertApprox(double actual, double expected, double tol, string msg) {
    assert(fabs(actual - expected) <= tol,
        format("%s: got %.6f, want %.6f (tol %.6f)", msg, actual, expected, tol));
}

// ---------------------------------------------------------------------------
// Case 1 — geometry law (W1): SX=-1 mirrors X through the origin pivot,
// polygon vertex-index order is byte-identical before/after (winding
// unchanged). Drives the headless numeric path (`tool.attr` + `tool.doApply`)
// with `negScale` explicitly ON, which is the only flag state under which a
// negative factor still reaches the kernel from that door (task 3310 — see the
// file header; before it, this case drove the same path with the flag OFF and
// the mirror happened only because the floor was missing). W1 itself is
// flag-independent: it is the law for ANY negative factor that reaches the
// kernel, however it got there — the flag only decides whether one does.
// ---------------------------------------------------------------------------
unittest {
    reset();
    auto before = dumpVerts();
    auto facesBefore = dumpFaces();
    assert(before.length == 8, "expected 8-vertex cube, got "
        ~ before.length.to!string);

    // Default cube is centred at the origin with no selection -> whole-mesh
    // moving set, ACEN pivot at (0,0,0) (same assumption test_uniform_scale.d
    // makes for its analytic uniform-scale cases).
    cmd("tool.set scale on");
    // negScale is per-activation tool state: set it INSIDE this activation,
    // after `tool.set` and before the value writes (same rule
    // dragCenterDiscThroughZero documents below).
    cmd("tool.attr scale negScale true");
    cmd("tool.attr scale SX -1");
    cmd("tool.attr scale SY 1");
    cmd("tool.attr scale SZ 1");
    cmd("tool.doApply");
    cmd("tool.set scale off");

    auto after = dumpVerts();
    auto facesAfter = dumpFaces();
    assert(after.length == before.length, "vertex count changed after SX=-1");
    enum double tol = 1e-4;
    foreach (i, v; after) {
        assertApprox(v[0], -before[i][0], tol, format("vert[%d].x mirrored", i));
        assertApprox(v[1],  before[i][1], tol, format("vert[%d].y unchanged", i));
        assertApprox(v[2],  before[i][2], tol, format("vert[%d].z unchanged", i));
    }

    // Winding unchanged (W1): every face's vertex-index order is
    // byte-identical, not reversed. (The mirror still flips the SIGNED
    // volume / face normals — that is the intended "inside-out" result of a
    // negative scale, left as-is; only the index ORDER is asserted here.)
    assert(facesAfter.length == facesBefore.length, "face count changed after SX=-1");
    foreach (fi, idx; facesAfter)
        assert(idx == facesBefore[fi],
            format("face %d vertex order changed after SX=-1 (winding must stay "
                ~ "UNCHANGED per the W1 capture verdict): before=%s after=%s",
                fi, facesBefore[fi], idx));
}

// ---------------------------------------------------------------------------
// Case 1b — the NUMERIC door's floor (task 3310). The SAME typed write as Case
// 1, through the SAME path, with `negScale` OFF instead of ON: the stored scale
// is floored at +0.0, so every vertex's X collapses onto the pivot instead of
// mirroring. The measured law is in
// `tests/fixtures/scale_negative_typed_value.json` (gap-registry row 85); this
// case is the local witness for the line that implements it,
// `XfrmTransformTool.applyHeadless`'s `run.s = floorNegativeScale(run.s)`.
//
// Case 1 and Case 1b differ in the FLAG and in nothing else, which is what
// makes the pair evidence about the flag rather than about the value. The
// second half below writes a POSITIVE value at the same flag state and requires
// it to pass through untouched — without it, a "floor" that clamped every axis
// to zero unconditionally would satisfy the first half.
// ---------------------------------------------------------------------------
unittest {
    reset();
    auto before = dumpVerts();
    assert(before.length == 8, "expected 8-vertex cube, got "
        ~ before.length.to!string);
    foreach (i, v; before)
        assert(fabs(v[0]) > 0.1,
            format("stand is degenerate: vert[%d].x is %.6f, so a collapse to the "
                ~ "pivot would be indistinguishable from no change at all", i, v[0]));

    cmd("tool.set scale on");
    cmd("tool.attr scale negScale false");
    cmd("tool.attr scale SX -1");
    cmd("tool.attr scale SY 1");
    cmd("tool.attr scale SZ 1");
    cmd("tool.doApply");
    cmd("tool.set scale off");

    auto after = dumpVerts();
    assert(after.length == before.length, "vertex count changed after SX=-1");
    enum double tol = 1e-4;
    foreach (i, v; after) {
        assertApprox(v[0], 0.0, tol,
            format("negScale-off numeric vert[%d].x must FLOOR to the pivot, not "
                ~ "mirror", i));
        assertApprox(v[1], before[i][1], tol, format("vert[%d].y unchanged", i));
        assertApprox(v[2], before[i][2], tol, format("vert[%d].z unchanged", i));
    }

    // Anti-vacuity: a POSITIVE typed value at the same flag state is stored
    // verbatim. The floor is on the SIGN, not on the write.
    reset();
    auto posBefore = dumpVerts();
    cmd("tool.set scale on");
    cmd("tool.attr scale negScale false");
    cmd("tool.attr scale SX 2");
    cmd("tool.attr scale SY 1");
    cmd("tool.attr scale SZ 1");
    cmd("tool.doApply");
    cmd("tool.set scale off");
    auto posAfter = dumpVerts();
    foreach (i, v; posAfter)
        assertApprox(v[0], posBefore[i][0] * 2.0, tol,
            format("negScale-off numeric vert[%d].x: a POSITIVE typed value must "
                ~ "pass through the floor untouched", i));
}

// ---- shared camera/projection helpers for the drag cases (duplicated
//      locally, matching the existing convention in
//      tests/test_xfrm_scale_flip_drag.d) -------------------------------
struct V3 { double x = 0, y = 0, z = 0; }
V3 vsub(V3 a, V3 b) { return V3(a.x-b.x, a.y-b.y, a.z-b.z); }
double vdot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
double vlen(V3 a) { return sqrt(vdot(a, a)); }
V3 vcross(V3 a, V3 b) {
    return V3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}
V3 vnorm(V3 v) {
    double L = vlen(v);
    return L > 1e-12 ? V3(v.x/L, v.y/L, v.z/L) : V3(0, 0, 0);
}
double[16] lookAt(V3 eye, V3 ctr, V3 up) {
    V3 f = vnorm(vsub(ctr, eye));
    V3 r = vnorm(vcross(f, up));
    V3 u = vcross(r, f);
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

// Drag the SCALE tool's uniform CENTER-DISC handle (dragAxis==3 — the
// disc/uniform path, immune to axis-basis bookkeeping) with one big
// single-shot motion far enough to blow `1.0 + dragScaleScalarDelta` well
// past -1 regardless of the projected gizmo size. Activates `scale` fresh
// and sets `negScale` (if requested) inside that SAME activation before the
// drag starts — negScale is per-activation tool state, so it must be set
// after `tool.set scale on` and before the drag, not left over from a prior
// activation.
double[3][] dragCenterDiscThroughZero(bool negScale) {
    postJson("/api/camera", `{"azimuth":0.785,"elevation":0.6,"distance":3.2}`);
    cmd("tool.set scale on");
    if (negScale) cmd("tool.attr scale negScale true");

    auto tp = getJson("/api/toolpipe/eval");
    auto ac = tp["actionCenter"]["center"].array;
    V3 pivot = V3(ac[0].floating, ac[1].floating, ac[2].floating);

    Cam cam = fetchCam();
    auto view = lookAt(cam.eye, cam.focus, V3(0, 1, 0));
    auto proj = persp(45.0 * PI / 180.0, cast(double)cam.w / cam.h, 0.001, 100.0);
    double px, py;
    assert(project(pivot, view, proj, cam.w, cam.h, cam.vpX, cam.vpY, px, py),
        "gizmo pivot projects off-camera — camera setup changed");
    int x0 = cast(int)px, y0 = cast(int)py;

    play(format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n" ~
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        cam.vpX, cam.vpY, cam.w, cam.h, x0, y0));
    // One huge single-shot drag: comfortably crosses zero (|xrel| far exceeds
    // any plausible on-screen gizmo radius) regardless of exact gizmo size.
    play(format(
        `{"t":100.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":%d,"yrel":0,"state":1,"mod":0}` ~ "\n",
        x0 - 20000, y0, -20000));
    play(format(
        `{"t":150.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}` ~ "\n",
        x0 - 20000, y0));

    auto after = dumpVerts();
    cmd("tool.set scale off");
    return after;
}

// ---------------------------------------------------------------------------
// Case 2 — negScale OFF (default): the interactive drag clamps the scale
// factor at exactly 0 (not epsilon) once it crosses zero, so a
// uniform-disc drag collapses every vertex EXACTLY onto the pivot.
// ---------------------------------------------------------------------------
unittest {
    reset();
    auto after = dragCenterDiscThroughZero(false);
    assert(after.length == 8);
    enum double tol = 1e-3;
    foreach (i, v; after) {
        assertApprox(v[0], 0.0, tol, format("negScale-off vert[%d].x should collapse to pivot", i));
        assertApprox(v[1], 0.0, tol, format("negScale-off vert[%d].y should collapse to pivot", i));
        assertApprox(v[2], 0.0, tol, format("negScale-off vert[%d].z should collapse to pivot", i));
    }
}

// ---------------------------------------------------------------------------
// Case 3 — negScale ON: the SAME drag is allowed to cross zero into a
// mirrored (negative) factor instead of clamping at 0 — verts must NOT
// collapse to the pivot, and each vertex ends up on the OPPOSITE side of the
// pivot from where it started (sign of the offset flips), confirming the
// factor actually went negative rather than merely failing to clamp exactly
// at 0.
// ---------------------------------------------------------------------------
unittest {
    reset();
    auto before = dumpVerts();
    auto after = dragCenterDiscThroughZero(true);
    // Every vertex must have flipped to the opposite octant relative to the
    // origin pivot (dot(after, before) < 0) — proof the factor went
    // negative, not just "failed to clamp at exactly 0".
    foreach (i; 0 .. before.length) {
        V3 b = V3(before[i][0], before[i][1], before[i][2]);
        V3 a = V3(after[i][0],  after[i][1],  after[i][2]);
        assert(vdot(a, b) < -1e-6,
            format("negScale-on vert[%d] did not flip sign relative to pivot: "
                ~ "before=%s after=%s", i, before[i], after[i]));
    }
    // And it must not have merely clamped to (near) zero either.
    double meanDist = 0;
    foreach (v; after) meanDist += sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
    meanDist /= after.length;
    assert(meanDist > 0.05,
        format("negScale-on drag collapsed to the pivot (meanDist=%.6f) — "
            ~ "the clamp was not actually bypassed", meanDist));
}

// ---------------------------------------------------------------------------
// Cases 4/5 — the PANEL-WRITE path (`applyScalePanelValue`'s clamp,
// source/tools/scale.d, the exact site the historical bug lived at as the
// ImGui `v_min` floor). Reviewer NIT: Cases 2/3 above only exercise the
// gizmo-drag `clampScaleFactor` path; this pins the SEPARATE
// `applyScalePanelValue` clamp too.
//
// `applyScalePanelValue` is reached through `XfrmTransformTool.reEvaluate()`,
// which `ToolAttrCommand.apply()` (source/commands/tool/attr.d) triggers
// whenever `t.hasLiveAttrEval()` is true at the moment of a raw HTTP
// `tool.attr` write — i.e. a value edit that lands INSIDE an already-live
// transform session, not a fresh tool's first attr write (which is
// deliberately inert — see the ToolAttrCommand doc comment). `tool.beginSession`
// (test-mode-only; `XfrmTransformTool.openLiveSessionForTest()`) opens that
// live session with NO geometry change — the same proven idiom
// `tests/test_rs_insession_cancel.d` uses to reach this exact seam
// (`tool.set TransformScale` -> `tool.beginSession` -> `tool.attr … SX 2` ->
// v6.x becomes 1.0). So: open the session, THEN write `SX` — that write both
// sets `run.s.x` AND (because the session is live) re-triggers `reEvaluate()`
// -> `scaleSub.applyScalePanelValue(run.s)`, landing on the exact clamp this
// case pins.
//
// NOTE on what stays UNTESTED: the actual ImGui `DragFloat` `v_min` floor
// (`scale.d`'s panel sliders, `xfrm_transform.d`'s uniform slider) requires a
// live ImGui mouse-drag on a rendered widget, which this headless HTTP
// harness cannot drive (no GUI event loop in `--test` mode) — that specific
// site is verified by code review only, not by an automated regression test.
// `applyScalePanelValue` is the programmatic twin of that same clamp law
// (both guard "the panel value must not go negative unless negScale"), and
// IS headlessly reachable, so it is regression-tested here as the closest
// available proxy for the historically-missed floor.
// ---------------------------------------------------------------------------

// Open a live scale session with NO geometry change (`tool.beginSession`),
// then write `SX` as a raw HTTP `tool.attr` — landing inside the live
// session, this write re-triggers `reEvaluate()` -> `applyScalePanelValue(run.s)`
// (NOT just the raw unclamped Param-pointer write Case 1 exercises).
double[3][] setSXViaPanelPath(bool negScale, double sx) {
    cmd("tool.set scale on");
    if (negScale) cmd("tool.attr scale negScale true");
    cmd("tool.beginSession");
    cmd(format("tool.attr scale SX %s", sx));

    auto after = dumpVerts();
    cmd("tool.set scale off");
    return after;
}

unittest { // Case 4 — negScale OFF: the panel-write path clamps SX to 0.
    reset();
    auto after = setSXViaPanelPath(false, -5.0);
    assert(after.length == 8);
    // World-aligned basis on a fresh whole-mesh scale (pivot == origin): a
    // clamped-to-0 X factor collapses every vertex's X coordinate to
    // pivot.x == 0 (SY/SZ stay at their identity default 1 — beginSession
    // opens the session with no geometry change, and this case only writes SX).
    enum double tol = 1e-3;
    foreach (i, v; after)
        assertApprox(v[0], 0.0, tol,
            format("negScale-off panel-write vert[%d].x should clamp to 0", i));
}

unittest { // Case 5 — negScale ON: the panel-write path lets SX go negative.
    reset();
    auto before = dumpVerts();
    auto after = setSXViaPanelPath(true, -5.0);
    assert(after.length == 8);
    // Every vertex's X must have flipped sign relative to the origin pivot
    // (all 8 cube corners have x == ±0.5, never 0) — proof the panel-write
    // path actually let the factor go negative instead of clamping.
    foreach (i, v; after)
        assert(v[0] * before[i][0] < 0,
            format("negScale-on panel-write vert[%d].x did not flip sign: "
                ~ "before=%.4f after=%.4f", i, before[i][0], v[0]));
}
