// test_fixture_falloff_multi.d — MS-4.2 of the canonical-matrix applyTRS refactor.
//
// Validates the matrix-state FOLD against the MS-4.1 multi-axis + combined
// reference fixtures, in vibe3d's REAL apply kernels (pure-D, no HTTP, no running
// vibe3d). Ground truth: tests/fixtures/falloff_{rot,trs}_multi.json — each case
// stores the reference engine's per-vertex before->after under a graded linear
// falloff, the recovered composed transform (rotation R, or full affine Mlin+t),
// and the vibe3d-native falloff handles.
//
// Two assertions per case:
//   FOLD (all cases): a SINGLE composed matrix blended toward identity per vertex
//     by the falloff weight — applyXformMatrix with BlendMode.MatrixLerp, the
//     MS-3.5 keep-b decision — reproduces the reference `after` within the fixture
//     tolerance. This is exactly what MS-4.3/4.4 will make the production apply do.
//   PER-PASS (rotate cases): applying the SAME rotation the way vibe3d does TODAY
//     — three sequential per-axis blended passes (applyRotateIncremental about X,
//     then Y, then Z) — DIVERGES from the reference. This proves the current
//     decomposed/sequential model is wrong for multi-axis-under-falloff and the
//     fold is the fix (not mere refactoring).
//
// The falloff weight here is the Selection-baked per-vertex weight computed from
// the fixture's linear handles (the SAME w = 1 - clamp(proj) that source/falloff.d
// produces); the per-vertex weight machinery itself is covered by the HTTP
// falloff_drag fixture, so this test isolates the BLEND/COMPOSITION model.
//
// Compiled by run_test.d's `dmd -unittest -J=tests`; runs standalone.

import std.stdio;
import std.json;
import std.math : fabs, PI, sqrt;

import math : Vec3, Viewport, identityMatrix, lookAt, perspectiveMatrix;
import mesh : Mesh;
import toolpipe.packets : FalloffPacket, FalloffType, SymmetryPacket;
import tools.transform : TransformTool;
import tools.xform_kernels : applyRotateIncremental, applyXformMatrix, BlendMode;

void main() {}

// --- helpers ---------------------------------------------------------------

private Viewport testViewport() {
    Viewport vp;
    vp.view   = lookAt(Vec3(0,0,5), Vec3(0,0,0), Vec3(0,1,0));
    vp.proj   = perspectiveMatrix(PI/2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800; vp.height = 800;
    return vp;
}
private SymmetryPacket noSymmetry() { SymmetryPacket s; s.enabled = false; return s; }
private TransformTool.ClusterPivots noCP() { TransformTool.ClusterPivots cp; return cp; }
private TransformTool.ClusterAxes  noCA() { TransformTool.ClusterAxes  ca; return ca; }

private double asD(JSONValue v) {
    final switch (v.type) {
        case JSONType.float_:   return v.floating;
        case JSONType.integer:  return cast(double) v.integer;
        case JSONType.uinteger: return cast(double) v.uinteger;
        case JSONType.string: case JSONType.array: case JSONType.object:
        case JSONType.true_:  case JSONType.false_: case JSONType.null_:
            assert(false, "expected number");
    }
}
private Vec3 jvec(JSONValue v) {
    auto a = v.array;
    return Vec3(cast(float)asD(a[0]), cast(float)asD(a[1]), cast(float)asD(a[2]));
}

// Selection falloff carrying explicit per-vertex weights (looked up by vertex id
// in evaluateFalloff) — the deterministic, position-independent way to feed the
// kernels the fixture's graded weights.
private FalloffPacket weightedFalloff(float[] w) {
    FalloffPacket f; f.enabled = true; f.type = FalloffType.Selection;
    f.selectionWeights = w.dup; return f;
}

// vibe3d linear falloff weight (mirrors source/falloff.d): w = 1 - clamp(t,0,1),
// t = proj of (p-start) onto (end-start).
private float[] linearWeights(Vec3[] before, Vec3 start, Vec3 end) {
    Vec3 seg = Vec3(end.x-start.x, end.y-start.y, end.z-start.z);
    float seg2 = seg.x*seg.x + seg.y*seg.y + seg.z*seg.z;
    auto w = new float[](before.length);
    foreach (i, p; before) {
        float t = ((p.x-start.x)*seg.x + (p.y-start.y)*seg.y + (p.z-start.z)*seg.z) / seg2;
        if (t < 0) t = 0; else if (t > 1) t = 1;
        w[i] = 1.0f - t;
    }
    return w;
}

// Pack a row-major 3x3 `R` (after = R·v) + translation `t` into vibe3d's
// column-major float[16] (m[row + col*4]); applyAffine(M,v) == R·v + t.
private float[16] packAffine(double[3][3] R, Vec3 t) {
    return [
        cast(float)R[0][0], cast(float)R[1][0], cast(float)R[2][0], 0,
        cast(float)R[0][1], cast(float)R[1][1], cast(float)R[2][1], 0,
        cast(float)R[0][2], cast(float)R[1][2], cast(float)R[2][2], 0,
        t.x, t.y, t.z, 1,
    ];
}
private double[3][3] jmat3(JSONValue m) {
    auto a = m.array;
    double[3][3] R;
    foreach (i; 0 .. 3) { auto r = a[i].array;
        foreach (j; 0 .. 3) R[i][j] = asD(r[j]); }
    return R;
}

private Vec3[] readPairs(JSONValue pairs, string which) {
    auto a = pairs.array;
    auto v = new Vec3[](a.length);
    foreach (i, p; a) v[i] = jvec(p[which]);
    return v;
}

private float maxErr(const(Vec3)[] got, const(Vec3)[] want) {
    float e = 0;
    foreach (i; 0 .. got.length) {
        float dx = fabs(got[i].x-want[i].x), dy = fabs(got[i].y-want[i].y),
              dz = fabs(got[i].z-want[i].z);
        float m = dx > dy ? (dx > dz ? dx : dz) : (dy > dz ? dy : dz);
        if (m > e) e = m;
    }
    return e;
}

private int[] allIdx(size_t n) { int[] r; foreach (i; 0..n) r ~= cast(int)i; return r; }

// --- FOLD: single composed matrix reproduces the reference -----------------

private void assertFold(string caseName, JSONValue op, JSONValue pairs, double tol) {
    Vec3[] before = readPairs(pairs, "before");
    Vec3[] after  = readPairs(pairs, "after");
    auto idx = allIdx(before.length);
    auto vp = testViewport(); auto sp = noSymmetry();
    auto cp = noCP(); auto ca = noCA();

    Vec3 pivot, t = Vec3(0,0,0);
    double[3][3] R;
    JSONValue fo;
    if ("falloff_rotate_matrix" in op) {
        auto o = op["falloff_rotate_matrix"];
        pivot = jvec(o["pivot"]); R = jmat3(o["rotation"]); fo = o["falloff"];
    } else {
        auto o = op["falloff_affine_matrix"];
        pivot = jvec(o["pivot"]); R = jmat3(o["linear"]); t = jvec(o["translation"]);
        fo = o["falloff"];
    }
    float[16] M = packAffine(R, t);
    float[] w = linearWeights(before, jvec(fo["start"]), jvec(fo["end"]));
    auto fp = weightedFalloff(w);

    auto m = new Mesh(); m.vertices = before.dup;
    bool[] tp = new bool[](before.length); tp[] = true;
    applyXformMatrix(m, idx, before, pivot, M, BlendMode.MatrixLerp,
                     fp, vp, cp, ca, null, sp, tp);

    float e = maxErr(m.vertices, after);
    if (!(e <= tol))
        writefln("FOLD %s: max err %.6g > tol %.1e", caseName, e, tol);
    assert(e <= tol, "FOLD mismatch: " ~ caseName);
}

// --- PER-PASS (rotate): sequential per-axis blend DIVERGES ------------------

private void assertPerPassDiverges(string caseName, JSONValue op,
                                   JSONValue pairs, double gapMin) {
    auto o = op["falloff_rotate_matrix"];
    Vec3 pivot = jvec(o["pivot"]);
    auto eul = o["euler_deg"];
    float rx = cast(float)(asD(eul["rx"]) * PI/180.0);
    float ry = cast(float)(asD(eul["ry"]) * PI/180.0);
    float rz = cast(float)(asD(eul["rz"]) * PI/180.0);
    Vec3[] before = readPairs(pairs, "before");
    Vec3[] after  = readPairs(pairs, "after");
    auto idx = allIdx(before.length);
    auto vp = testViewport(); auto sp = noSymmetry();
    auto cp = noCP(); auto ca = noCA();
    float[] w = linearWeights(before, jvec(o["falloff"]["start"]),
                              jvec(o["falloff"]["end"]));
    auto fp = weightedFalloff(w);

    // vibe3d's current applyTRS rotate: three sequential per-axis passes about the
    // world basis through the pivot (each pass blended toward identity by w).
    auto m = new Mesh(); m.vertices = before.dup;
    if (rx != 0) applyRotateIncremental(m, idx, pivot, Vec3(1,0,0), -1, rx, fp, vp, cp, ca, sp, null);
    if (ry != 0) applyRotateIncremental(m, idx, pivot, Vec3(0,1,0), -1, ry, fp, vp, cp, ca, sp, null);
    if (rz != 0) applyRotateIncremental(m, idx, pivot, Vec3(0,0,1), -1, rz, fp, vp, cp, ca, sp, null);

    float e = maxErr(m.vertices, after);
    writefln("PER-PASS %s: max err vs reference = %.5f (fold reproduces; "
             ~ "sequential blend diverges)", caseName, e);
    assert(e > gapMin,
        "PER-PASS unexpectedly matched reference (" ~ caseName ~ "): the "
        ~ "multi-axis fold gap closed — re-check the fixture / model");
}

// --- cases -----------------------------------------------------------------

unittest { // FOLD reproduces every multi-axis rotate + combined T+R+S case
    foreach (jsonText; [import("fixtures/falloff_rot_multi.json"),
                        import("fixtures/falloff_trs_multi.json")]) {
        auto fx = parseJSON(jsonText);
        double tol = ("tolerance" in fx) ? asD(fx["tolerance"]) : 1e-3;
        foreach (cs; fx["cases"].array) {
            string nm = fx["name"].str ~ "/" ~ cs["name"].str;
            // op is a 1-element array
            assertFold(nm, cs["op"].array[0], cs["expected_pairs"], tol);
        }
    }
}

unittest { // PER-PASS sequential blend diverges on the multi-axis rotate cases
    auto fx = parseJSON(import("fixtures/falloff_rot_multi.json"));
    foreach (cs; fx["cases"].array)
        assertPerPassDiverges(fx["name"].str ~ "/" ~ cs["name"].str,
                              cs["op"].array[0], cs["expected_pairs"], 0.005);
}
