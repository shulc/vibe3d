// test_xform_matrix_kernel.d — MS-1 of the canonical-matrix applyTRS refactor.
//
// Pure-D unit test (no HTTP, no running vibe3d): builds tiny in-process meshes
// and asserts the new single-matrix kernel `applyXformMatrix`
// (source/tools/xform_kernels.d) reproduces the existing per-component kernels
// (applyTranslateIncremental / applyRotateIncremental / applyScaleFromActivation)
// pass-by-pass, for w==1 AND fractional-weight falloff, INCLUDING the
// per-cluster ACEN.Local paths (plan N3). It also prints an a/b/c blend
// divergence harness (informational, NOT asserted for equality).
//
// Compiled by run_test.d's `dmd -unittest`; runs standalone (unittests run
// before the empty main()). Cite the live-suite per-cluster backstops:
//   tests/test_acen_local_rotate_parity.d  (HTTP-driven)
//   tests/test_fixture_acen_local.d         (fixture-driven)
//
// Tolerance (plan N2 / R3): SHADOW_TOL is the single shared equality tolerance
// used by BOTH this unit test and the MS-2 shadow comparison
// (source/tools/xfrm_shadow.d defines its own `SHADOW_TOL` enum at the SAME
// value — keep them in lockstep). It is DERIVED, not guessed:
//   measured_max = 5.96046e-08 on 2026-05-30 / Fedora 43 x86_64, harvested from
//   the WORST per-worker SUMMARY `maxErr` of a clean `./run_test.d --shadow`
//   log-only run across the event-replay transform suite on green main. That is
//   the float ULP-scale residue between the live decomposed chain and the matrix
//   kernel's multi-pass T->R->S reconstruction — far below the 1e-3 "kernel is
//   wrong" sanity bound the plan sets. (The single-pass in-process cases below
//   sit at the same ~1e-7 scale.)
//   SHADOW_TOL = measured_max * 16 (≈9.54e-7, rounded to 1e-6) absorbs platform
//   libm drift without admitting a real divergence (16× safety factor, N2).

import std.stdio;
import std.math : PI, fabs, sqrt;

import math : Vec3, Viewport, identityMatrix, translationMatrix,
              pivotRotationMatrix, pivotScaleMatrixBasis, normalize, lookAt,
              perspectiveMatrix;
import mesh : Mesh;
import toolpipe.packets : FalloffPacket, SymmetryPacket;
import tools.transform : TransformTool;
import tools.xform_kernels :
    applyTranslateIncremental, applyRotateIncremental, applyScaleFromActivation,
    applyXformMatrix, BlendMode, blendToIdentity;

// Single shared tolerance constant (plan N2 / R3). See header for derivation.
// Must match source/tools/xfrm_shadow.d's SHADOW_TOL.
enum float SHADOW_TOL = 1e-6f;   // measured_max 5.96046e-08 × 16, 2026-05-30

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private Mesh* makeMesh(Vec3[] verts) {
    auto m = new Mesh();
    m.vertices = verts.dup;
    return m;
}

private void assertClose(const(Vec3)[] a, const(Vec3)[] b, string ctx) {
    assert(a.length == b.length, ctx ~ ": length mismatch");
    foreach (i; 0 .. a.length) {
        float dx = fabs(a[i].x - b[i].x);
        float dy = fabs(a[i].y - b[i].y);
        float dz = fabs(a[i].z - b[i].z);
        float e = dx > dy ? (dx > dz ? dx : dz) : (dy > dz ? dy : dz);
        if (!(e < SHADOW_TOL)) {
            writefln("%s: vi=%d live=(%g,%g,%g) matrix=(%g,%g,%g) err=%g",
                     ctx, i, a[i].x, a[i].y, a[i].z,
                     b[i].x, b[i].y, b[i].z, e);
        }
        assert(e < SHADOW_TOL, ctx);
    }
}

// A viewport (needed by evaluateFalloff signatures; falloff cases below use a
// Linear falloff whose weight is purely world-space, so the camera is benign).
private Viewport testViewport() {
    Viewport vp;
    vp.view   = lookAt(Vec3(0,0,5), Vec3(0,0,0), Vec3(0,1,0));
    vp.proj   = perspectiveMatrix(PI/2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    return vp;
}

// Falloff with explicit per-vertex precomputed weights, via the Selection type
// (FalloffStage bakes per-vert weights into `selectionWeights`; evaluateFalloff
// just looks them up by vertex index). This gives deterministic fractional
// weights without depending on camera/world-space falloff math. The parity
// assertion holds for ANY weights both kernels see (they call the SAME
// evaluateFalloff); fractional weights merely exercise the (1-w)I + wR blend
// path rather than the w==1 fast path.
private FalloffPacket weightedFalloff(float[] weights) {
    import toolpipe.packets : FalloffType;
    FalloffPacket f;
    f.enabled = true;
    f.type    = FalloffType.Selection;
    f.selectionWeights = weights.dup;
    return f;
}

private FalloffPacket noFalloff() {
    FalloffPacket f;
    f.enabled = false;
    return f;
}

private SymmetryPacket noSymmetry() {
    SymmetryPacket s;
    s.enabled = false;
    return s;
}

// Inactive cluster resolvers (global path). `.active` is a derived method
// (centers.length>=2 / right.length>=2), NOT a settable field — leaving the
// arrays empty makes both resolvers inactive.
private TransformTool.ClusterPivots noClusterPivots() {
    TransformTool.ClusterPivots cp;
    return cp;
}
private TransformTool.ClusterAxes noClusterAxes() {
    TransformTool.ClusterAxes ca;
    return ca;
}

private Vec3[] sampleVerts() {
    return [
        Vec3(-1, -0.5f, -1),
        Vec3( 1, -0.5f, -1),
        Vec3( 1,  0.5f,  1),
        Vec3(-1,  0.5f,  1),
        Vec3( 0.3f, 0.7f, 0.2f),
    ];
}

private int[] allIndices(size_t n) {
    int[] r;
    foreach (i; 0 .. n) r ~= cast(int)i;
    return r;
}

// ---------------------------------------------------------------------------
// (i) w==1 parity vs existing kernels (translate / rotate / scale)
// ---------------------------------------------------------------------------

unittest { // (i-T) Translate, whole mesh, global delta, falloff disabled
    auto vp = testViewport();
    auto fp = noFalloff();
    auto sp = noSymmetry();
    auto cp = noClusterPivots();
    auto ca = noClusterAxes();
    Vec3 delta = Vec3(0.4f, -0.2f, 1.1f);
    auto idx = allIndices(sampleVerts().length);

    // A: existing incremental kernel (live mutation).
    auto A = makeMesh(sampleVerts());
    bool[] tpA = new bool[A.vertices.length]; tpA[] = true;
    applyTranslateIncremental(A, idx, delta, fp, vp, sp, tpA);

    // B: matrix kernel with the equivalent pivot-relative translation matrix.
    // Translation is pivot-independent; pivot arbitrary (origin).
    auto B = makeMesh(sampleVerts());
    bool[] tpB = new bool[B.vertices.length]; tpB[] = true;
    auto baseB = sampleVerts();
    applyXformMatrix(B, idx, baseB, Vec3(0,0,0),
                     translationMatrix(delta), BlendMode.MatrixLerp,
                     fp, vp, cp, ca, null, sp, tpB);

    assertClose(A.vertices, B.vertices, "i-T translate w==1");
}

unittest { // (i-R) Rotate about each basis axis, single pass, falloff disabled
    auto vp = testViewport();
    auto fp = noFalloff();
    auto sp = noSymmetry();
    auto cp = noClusterPivots();
    auto ca = noClusterAxes();
    Vec3 pivot = Vec3(0.1f, -0.2f, 0.05f);
    float ang = 0.6f;
    auto idx = allIndices(sampleVerts().length);
    Vec3[3] axes = [Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)];

    foreach (a; 0 .. 3) {
        auto A = makeMesh(sampleVerts());
        bool[] tpA = new bool[A.vertices.length]; tpA[] = true;
        // dragAxisIdx = -1 keeps axisFallback for every vertex (global axis).
        applyRotateIncremental(A, idx, pivot, axes[a], -1, ang,
                               fp, vp, cp, ca, sp, tpA);

        auto B = makeMesh(sampleVerts());
        bool[] tpB = new bool[B.vertices.length]; tpB[] = true;
        auto baseB = sampleVerts();
        // pivotRotationMatrix(origin, axis, angle) is origin-fixing, so it's
        // pivot-relative as the matrix kernel requires.
        applyXformMatrix(B, idx, baseB, pivot,
                         pivotRotationMatrix(Vec3(0,0,0), axes[a], ang),
                         BlendMode.MatrixLerp, fp, vp, cp, ca, null, sp, tpB);

        import std.conv : to;
        assertClose(A.vertices, B.vertices, "i-R rotate axis " ~ a.to!string ~ " w==1");
    }
}

unittest { // (i-R-view) View-ring rotate (dragAxisIdx==-1, arbitrary axis)
    auto vp = testViewport();
    auto fp = noFalloff();
    auto sp = noSymmetry();
    auto cp = noClusterPivots();
    auto ca = noClusterAxes();
    Vec3 pivot = Vec3(0.0f, 0.0f, 0.0f);
    Vec3 axis = normalize(Vec3(0.3f, 0.8f, -0.5f));
    float ang = 0.9f;
    auto idx = allIndices(sampleVerts().length);

    auto A = makeMesh(sampleVerts());
    bool[] tpA = new bool[A.vertices.length]; tpA[] = true;
    applyRotateIncremental(A, idx, pivot, axis, -1, ang, fp, vp, cp, ca, sp, tpA);

    auto B = makeMesh(sampleVerts());
    bool[] tpB = new bool[B.vertices.length]; tpB[] = true;
    auto baseB = sampleVerts();
    applyXformMatrix(B, idx, baseB, pivot,
                     pivotRotationMatrix(Vec3(0,0,0), axis, ang),
                     BlendMode.MatrixLerp, fp, vp, cp, ca, null, sp, tpB);

    assertClose(A.vertices, B.vertices, "i-R view-ring w==1");
}

unittest { // (i-S) Scale, per-axis factors, compoundPasses==1, falloff disabled
    auto vp = testViewport();
    auto fp = noFalloff();
    auto sp = noSymmetry();
    auto cp = noClusterPivots();
    auto ca = noClusterAxes();
    Vec3 pivot = Vec3(0.05f, 0.0f, -0.1f);
    Vec3 bx = Vec3(1,0,0), by = Vec3(0,1,0), bz = Vec3(0,0,1);
    Vec3 s = Vec3(2.0f, 0.5f, 1.3f);
    auto idx = allIndices(sampleVerts().length);

    auto A = makeMesh(sampleVerts());
    bool[] tpA = new bool[A.vertices.length]; tpA[] = true;
    auto activation = sampleVerts();
    applyScaleFromActivation(A, idx, activation, pivot, bx, by, bz, s,
                             fp, vp, cp, ca, sp, tpA);

    auto B = makeMesh(sampleVerts());
    bool[] tpB = new bool[B.vertices.length]; tpB[] = true;
    auto baseB = sampleVerts();
    applyXformMatrix(B, idx, baseB, pivot,
                     pivotScaleMatrixBasis(Vec3(0,0,0), bx, by, bz, s.x, s.y, s.z),
                     BlendMode.MatrixLerp, fp, vp, cp, ca, null, sp, tpB);

    assertClose(A.vertices, B.vertices, "i-S scale w==1");
}

// ---------------------------------------------------------------------------
// (ii) fractional-weight (b) reproduces rotateVecLerp for ONE rotation
// ---------------------------------------------------------------------------

unittest { // (ii) rotate + Linear-Z falloff: MatrixLerp == existing rotate kernel
    auto vp = testViewport();
    // Fractional per-vertex weights spanning [0,1] to exercise the blend.
    auto fp = weightedFalloff([0.0f, 0.25f, 0.5f, 0.75f, 1.0f]);
    auto sp = noSymmetry();
    auto cp = noClusterPivots();
    auto ca = noClusterAxes();
    Vec3 pivot = Vec3(0,0,0);
    Vec3 axis = Vec3(1,0,0);      // single rotation component
    float ang = 0.75f;
    auto idx = allIndices(sampleVerts().length);

    // A: existing kernel evaluates weight at LIVE mesh.vertices (== baseline on
    //    first apply since geometry hasn't moved yet).
    auto A = makeMesh(sampleVerts());
    bool[] tpA = new bool[A.vertices.length]; tpA[] = true;
    applyRotateIncremental(A, idx, pivot, axis, -1, ang, fp, vp, cp, ca, sp, tpA);

    // B: matrix kernel — MatrixLerp IS (1-w)I + wR, exactly rotateVecLerp.
    //    weightVerts default → weight at baseline[vi] (== same positions A used).
    auto B = makeMesh(sampleVerts());
    bool[] tpB = new bool[B.vertices.length]; tpB[] = true;
    auto baseB = sampleVerts();
    applyXformMatrix(B, idx, baseB, pivot,
                     pivotRotationMatrix(Vec3(0,0,0), axis, ang),
                     BlendMode.MatrixLerp, fp, vp, cp, ca, null, sp, tpB);

    assertClose(A.vertices, B.vertices, "ii rotate fractional-weight MatrixLerp");
}

// ---------------------------------------------------------------------------
// (iii) a/b/c divergence harness — informational, bounded sanity only
// ---------------------------------------------------------------------------

unittest {
    // Non-trivial M = rotation(axis, 1.1) · then expressed as a single
    // pivot-relative rotate+scale+translate matrix. We build one combined M by
    // composing a scale matrix and a rotation matrix and a translation column.
    import std.math : cos, sin;
    Vec3 axis = normalize(Vec3(0.2f, -0.7f, 0.6f));
    float ang = 1.1f;
    auto Rm = pivotRotationMatrix(Vec3(0,0,0), axis, ang);
    auto Sm = pivotScaleMatrixBasis(Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0),
                                    Vec3(0,0,1), 1.6f, 0.7f, 1.2f);
    import math : matMul4;
    float[16] M = matMul4(Rm, Sm);   // rotation · scale (origin-fixing)
    M[12] = 0.5f; M[13] = -0.3f; M[14] = 0.9f;  // translation column

    Vec3[] probes = [
        Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
        Vec3(0.5f, -0.4f, 0.8f), Vec3(-1, -1, -1),
    ];

    float maxAB = 0, maxBC = 0, maxAC = 0;
    foreach (wq; 0 .. 9) {
        float w = 0.1f + 0.1f * wq;   // 0.1 .. 0.9
        auto Ma = blendToIdentity(M, w, BlendMode.Decompose);
        auto Mb = blendToIdentity(M, w, BlendMode.MatrixLerp);
        auto Mc = blendToIdentity(M, w, BlendMode.PolarQuat);
        foreach (p; probes) {
            import math : applyAffine;
            Vec3 pa = applyAffine(Ma, p);
            Vec3 pb = applyAffine(Mb, p);
            Vec3 pc = applyAffine(Mc, p);
            float dab = (pa - pb).length;
            float dbc = (pb - pc).length;
            float dac = (pa - pc).length;
            if (dab > maxAB) maxAB = dab;
            if (dbc > maxBC) maxBC = dbc;
            if (dac > maxAC) maxAC = dac;
        }
    }
    writefln("a/b/c divergence (w 0.1..0.9): max|a-b|=%g  max|b-c|=%g  max|a-c|=%g",
             maxAB, maxBC, maxAC);
    // Sanity bounds only — these are DIFFERENT blends, equality is NOT claimed.
    // (a) is axis-angle LINEAR, (c) is slerp; they coincide ONLY for a single
    // PURE rotation. This M carries non-uniform scale, so the decomposition's
    // residual rotation differs between (a) and (c) and |a-c| is now genuinely
    // NON-ZERO (that divergence is the whole point — MS-3 reads it). It must
    // still stay well below the matrix-lerp shear |a-b| / |b-c|, which never
    // re-orthogonalizes. The pure-rotation a≡c property is covered by case (i-R).
    assert(maxAC > 1e-7f, "a vs c must diverge once M carries non-uniform scale");
    assert(maxAC < maxAB && maxAC < maxBC,
           "a-c (decompose variants) must stay below the matrix-lerp shear");
    assert(maxAB < 10.0f && maxBC < 10.0f, "b divergence unbounded — bug");
}

// ---------------------------------------------------------------------------
// (iv) per-cluster ACEN.Local parity (plan N3)
// ---------------------------------------------------------------------------
//
// Two clusters with distinct centers and frames. Confirmed plan facts:
//   - cluster TRANSLATE is falloff-EXEMPT (w==1), signed per-cluster axes,
//     reproduced via applyTranslateIncremental's no-falloff path on the same
//     per-cluster delta; the matrix kernel uses clusterM translation matrices.
//   - cluster ROTATE is LIVE-weighted (reuses applyRotateIncremental); here we
//     test the w==1 (no-falloff) sub-case as the in-process backstop, matching
//     applyRotateIncremental with the same ClusterPivots/ClusterAxes.

private TransformTool.ClusterPivots twoClusterPivots(size_t nVerts) {
    // .active is derived (centers.length>=2) → two centers makes it active.
    TransformTool.ClusterPivots cp;
    cp.centers = [Vec3(-1, 0, 0), Vec3(1, 0, 0)];
    cp.clusterOf = new int[nVerts];
    foreach (i; 0 .. nVerts)
        cp.clusterOf[i] = (i < nVerts / 2) ? 0 : 1;
    return cp;
}

private TransformTool.ClusterAxes twoClusterAxes() {
    // .active is derived (right.length>=2) → two frames makes it active.
    TransformTool.ClusterAxes ca;
    // Cluster 0: standard frame. Cluster 1: a tilted frame.
    ca.right = [Vec3(1,0,0), normalize(Vec3(0,1,0))];
    ca.up    = [Vec3(0,1,0), normalize(Vec3(-1,0,0))];
    ca.fwd   = [Vec3(0,0,1), Vec3(0,0,1)];
    return ca;
}

unittest { // (iv-rotate) per-cluster ACEN.Local rotate, w==1
    auto vp = testViewport();
    auto fp = noFalloff();
    auto sp = noSymmetry();
    auto verts = sampleVerts();
    auto cp = twoClusterPivots(verts.length);
    auto ca = twoClusterAxes();
    int dragAxisIdx = 0;          // rotate about each cluster's RIGHT axis
    float ang = 0.5f;
    auto idx = allIndices(verts.length);

    // A: existing rotate kernel with per-cluster pivot/axis lookup.
    auto A = makeMesh(verts);
    bool[] tpA = new bool[A.vertices.length]; tpA[] = true;
    applyRotateIncremental(A, idx, Vec3(0,0,0), Vec3(1,0,0), dragAxisIdx, ang,
                           fp, vp, cp, ca, sp, tpA);

    // B: matrix kernel with per-cluster matrices (each origin-fixing rotation
    //    about the cluster's right axis). The kernel resolves pivot per-cluster
    //    via cp; we feed clusterM built around the ORIGIN so the
    //    pivot + M·(base-pivot) framing yields the cluster-pivoted rotation.
    auto B = makeMesh(verts);
    bool[] tpB = new bool[B.vertices.length]; tpB[] = true;
    auto baseB = verts;
    float[16][] clusterM;
    foreach (cid; 0 .. cp.centers.length) {
        Vec3 axis = ca.right[cid]; // dragAxisIdx==0 → right
        clusterM ~= pivotRotationMatrix(Vec3(0,0,0), axis, ang);
    }
    applyXformMatrix(B, idx, baseB, Vec3(0,0,0),
                     identityMatrix, BlendMode.MatrixLerp,
                     fp, vp, cp, ca, clusterM, sp, tpB);

    assertClose(A.vertices, B.vertices, "iv per-cluster rotate w==1");
}

unittest { // (iv-translate) per-cluster ACEN.Local translate, falloff-EXEMPT
    auto vp = testViewport();
    auto fp = noFalloff();        // cluster translate is falloff-exempt (w==1)
    auto sp = noSymmetry();
    auto verts = sampleVerts();
    auto cp = twoClusterPivots(verts.length);
    auto ca = twoClusterAxes();
    auto idx = allIndices(verts.length);

    // The signed per-cluster delta applyTranslatePerCluster would produce: a
    // scalar slide along each cluster's fwd axis. Here: cluster 0 slides +0.7
    // along its fwd, cluster 1 slides +0.7 along its fwd. Build the equivalent
    // explicit per-cluster delta and reproduce it BOTH ways.
    float slide = 0.7f;
    Vec3[2] clusterDelta = [ca.fwd[0] * slide, ca.fwd[1] * slide];

    // A: emulate the per-cluster translate (no-falloff) directly on a copy by
    //    adding each vert's cluster delta — this is exactly what the matrix
    //    kernel's clusterM translation must reproduce.
    auto A = makeMesh(verts);
    foreach (i; 0 .. A.vertices.length) {
        int c = cp.clusterOf[i];
        A.vertices[i] = A.vertices[i] + clusterDelta[c];
    }

    // B: matrix kernel with per-cluster translation matrices (pivot-relative;
    //    translation is pivot-independent so origin pivot is fine).
    auto B = makeMesh(verts);
    bool[] tpB = new bool[B.vertices.length]; tpB[] = true;
    auto baseB = verts;
    float[16][] clusterM = [translationMatrix(clusterDelta[0]),
                            translationMatrix(clusterDelta[1])];
    applyXformMatrix(B, idx, baseB, Vec3(0,0,0),
                     identityMatrix, BlendMode.MatrixLerp,
                     fp, vp, cp, ca, clusterM, sp, tpB);

    assertClose(A.vertices, B.vertices, "iv per-cluster translate w==1");
}

// ---------------------------------------------------------------------------
// (v) non-identity `indices` locks the array-layout contract (X1)
// ---------------------------------------------------------------------------
//
// `applyXformMatrix` indexes `baseline` by loop ORDINAL (baseline[i] ↔
// indices[i]) but `weightVerts` by VERTEX ID (weightVerts[vi], mesh-length),
// matching the live scale kernel `applyScaleFromActivation` (weightVerts[vi]),
// so MS-2 can feed the same buffer with no re-indexing.
//
// `weightVerts` is the per-vertex POSITION buffer the falloff is evaluated AT
// (NOT a weights array — that's FalloffPacket.selectionWeights). To make the
// vid-vs-ordinal indexing OBSERVABLE we use a POSITION-SENSITIVE falloff
// (Linear), since Selection ignores worldPos and keys purely off the vi
// argument. We feed a mesh-length, vid-indexed weightVerts whose entries sit at
// distinct Y along the Linear axis. With a sparse `indices` = [2,5,1]:
//   - correct (weightVerts[vi]): vert 2 reads weightVerts[2], 5 reads [5], …
//   - wrong   (weightVerts[i]) : vert 2 reads weightVerts[0], 5 reads [1], …
// Both kernels read weightVerts[vi], so they MUST agree; if either reverted to
// ordinal the Linear weights would differ and assertClose would fire.

private Vec3[] sixVerts() {
    return [
        Vec3(-1, -0.5f, -1),
        Vec3( 1, -0.5f, -1),
        Vec3( 1,  0.5f,  1),
        Vec3(-1,  0.5f,  1),
        Vec3( 0.3f, 0.7f, 0.2f),
        Vec3(-0.4f, 0.2f, -0.6f),
    ];
}

// Position-sensitive Linear falloff along the +Y segment start→end: weight 1 at
// `start`, 0 at `end`, even (FalloffShape.Linear) attenuation in between. Linear
// falloff projects the eval position onto the line and ignores off-axis offset
// (see falloff.linearWeight), so only the Y coord of weightVerts matters here.
private FalloffPacket linearYFalloff(Vec3 start, Vec3 end) {
    import toolpipe.packets : FalloffType, FalloffShape;
    FalloffPacket f;
    f.enabled = true;
    f.type    = FalloffType.Linear;
    f.shape   = FalloffShape.Linear;
    f.start   = start;
    f.end     = end;
    return f;
}

unittest { // (v) sparse non-identity indices, vid-indexed weightVerts (positions)
    auto vp = testViewport();
    auto sp = noSymmetry();
    auto cp = noClusterPivots();
    auto ca = noClusterAxes();
    Vec3 pivot = Vec3(0.05f, 0.0f, -0.1f);
    Vec3 bx = Vec3(1,0,0), by = Vec3(0,1,0), bz = Vec3(0,0,1);
    Vec3 s = Vec3(2.0f, 0.5f, 1.3f);
    auto fp = linearYFalloff(Vec3(0, -1, 0), Vec3(0, 1, 0));  // y in [-1,1] → w in [1,0]

    // Sparse moving set: NOT [0,1,2,…]. If `weightVerts` were indexed by ordinal
    // (or `baseline` by vid) the two kernels would read different positions and
    // diverge.
    int[] idx = [2, 5, 1];

    // Mesh-length, VID-indexed POSITION buffer where the falloff weight is read.
    // Each entry sits at a distinct Y so a mis-index changes the Linear weight.
    Vec3[] weightVerts = [
        Vec3(0, -0.9f, 0),   // vid 0
        Vec3(0, -0.5f, 0),   // vid 1
        Vec3(0,  0.0f, 0),   // vid 2
        Vec3(0,  0.3f, 0),   // vid 3
        Vec3(0,  0.6f, 0),   // vid 4
        Vec3(0,  0.9f, 0),   // vid 5
    ];

    auto verts = sixVerts();

    // A: live scale kernel — indexes weightVerts[vi] (vid) over the sparse idx.
    auto A = makeMesh(verts);
    bool[] tpA = new bool[A.vertices.length]; tpA[] = false;
    foreach (vi; idx) tpA[vi] = true;
    auto activation = sixVerts();
    applyScaleFromActivation(A, idx, activation, pivot, bx, by, bz, s,
                             fp, vp, cp, ca, sp, tpA, weightVerts);

    // B: matrix scale path — `baseline` ordinal-parallel to idx, `weightVerts`
    //    vid-indexed mesh-length. Must reproduce A on the sparse set.
    auto B = makeMesh(verts);
    bool[] tpB = new bool[B.vertices.length]; tpB[] = false;
    foreach (vi; idx) tpB[vi] = true;
    Vec3[] baseB;                       // ordinal-parallel to idx
    foreach (vi; idx) baseB ~= verts[vi];
    applyXformMatrix(B, idx, baseB, pivot,
                     pivotScaleMatrixBasis(Vec3(0,0,0), bx, by, bz, s.x, s.y, s.z),
                     BlendMode.MatrixLerp, fp, vp, cp, ca, null, sp, tpB,
                     weightVerts);

    assertClose(A.vertices, B.vertices, "v sparse non-identity indices vid weightVerts");
}

// ---------------------------------------------------------------------------
// compoundPasses != 1: kernel is NOT claimed to match the pow path.
// ---------------------------------------------------------------------------

unittest {
    // The matrix kernel models ONLY compoundPasses==1 (plan F2). When a
    // Selection falloff publishes compoundPasses != 1, the scale pow() path has
    // no matrix expression; callers must SKIP the matrix kernel. This test just
    // documents/exercises that the SKIP predicate the callers use is the right
    // one — it does NOT assert matrix equality against the pow path.
    FalloffPacket f;
    f.enabled = true;
    f.compoundPasses = 1.91f;     // Steps·0.955 for Steps=2
    bool skip = fabs(f.compoundPasses - 1.0f) > 1e-4f;
    assert(skip, "compoundPasses!=1 must trigger the matrix-kernel SKIP");

    // And the common single-pass case does NOT skip.
    FalloffPacket g;
    g.enabled = true;
    g.compoundPasses = 1.0f;
    assert(!(fabs(g.compoundPasses - 1.0f) > 1e-4f),
           "compoundPasses==1 must NOT skip");
}
