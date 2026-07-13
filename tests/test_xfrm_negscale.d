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
//   - Clamp gate: `negScale` (default OFF) gates the scale-factor clamp at
//     TWO layers — source/tools/scale.d's `clampScaleFactor` + the panel
//     post-write clamps, and source/tools/xfrm_transform.d's uniform-slider
//     post-write clamp. Both only fire on the INTERACTIVE paths (gizmo drag
//     / ImGui panel widget). The headless numeric attr + `tool.doApply`
//     path (`XfrmTransformTool.applyHeadless` -> `applyTRS`) reads
//     `run.s.x/y/z` directly with NO clamp at all, on either side of this
//     flag — Case 1 below deliberately drives THAT path to pin the
//     flag-independent geometry law; Cases 2/3 drive an actual interactive
//     gizmo drag (the only path the clamp gates) to prove the flag toggles
//     clamp-at-zero vs. cross-zero-to-mirror.
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
// unchanged). Drives the UNCLAMPED headless numeric path
// (`tool.attr` + `tool.doApply`) — this path never gates on `negScale`, by
// design (see file header) — so this case is flag-independent and pins the
// geometry law alone.
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
