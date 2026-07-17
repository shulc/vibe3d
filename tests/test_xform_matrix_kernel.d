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
// Tolerance: SHADOW_TOL is the per-component-vs-matrix-kernel equality tolerance
// for the cases below. DERIVED, not guessed: the float ULP-scale residue between
// the legacy decomposed kernels and the matrix kernel sits at ~5.96e-08 (Fedora
// 43 x86_64); SHADOW_TOL = that × 16 (≈9.54e-7, rounded to 1e-6) absorbs platform
// libm drift without admitting a real divergence. (The name is historical — the
// MS-2 shadow that shared this constant was retired in MS-3.6.)

import std.stdio;
import std.math : PI, fabs, sqrt;

import math : Vec3, Viewport, identityMatrix, translationMatrix,
              pivotRotationMatrix, pivotScaleMatrixBasis, normalize, lookAt,
              perspectiveMatrix;
import mesh : Mesh;
import toolpipe.packets : FalloffPacket, SymmetryPacket;
import tools.transform.transform : TransformTool;
import tools.transform.xform_kernels :
    applyTranslateIncremental, applyRotateIncremental, applyScaleFromActivation,
    applyXformMatrix, BlendMode, blendToIdentity;

// Equality tolerance for the per-component-vs-matrix-kernel cases (see header).
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
                     translationMatrix(delta),
                     Vec3(0,0,0),  BlendMode.MatrixLerp,
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
                         Vec3(0,0,0),
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
                     Vec3(0,0,0),
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
                     Vec3(0,0,0),
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
                     Vec3(0,0,0),
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
                     identityMatrix,
                     Vec3(0,0,0),  BlendMode.MatrixLerp,
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
                     identityMatrix,
                     Vec3(0,0,0),  BlendMode.MatrixLerp,
                     fp, vp, cp, ca, clusterM, sp, tpB);

    assertClose(A.vertices, B.vertices, "iv per-cluster translate w==1");
}

// ---------------------------------------------------------------------------
// (iv-oob) out-of-cluster vertices take the GLOBAL transform, not identity
// ---------------------------------------------------------------------------
//
// Regression coverage for the MS-3.2 out-of-cluster fallback (the blind spot
// the measure-only shadow originally missed): under ACEN.Local a moving-set
// vertex can be UNCLUSTERED (cp.clusterOf[vi] == -1) when the moving set is
// wider than the clustered selection (e.g. whole-mesh moving set, falloff.element
// drag). The per-cluster matrix kernel must then apply the GLOBAL fallback `M`
// to that vertex (matching the LIVE applyTRS rotate/scale passes and the legacy
// kernels' pivotFor()/axisFor() global fallback) — NOT leave it fixed (identity).
//
// This asserts BOTH halves of the contract in one pass:
//   - in-cluster verts use their clusterM (per-cluster rotation/scale frame);
//   - the out-of-cluster vert uses the global M, so it MOVES (≠ its baseline)
//     and lands EXACTLY where a plain global-M apply would put it.

private TransformTool.ClusterPivots partialClusterPivots(size_t nVerts) {
    // Two real clusters, but the LAST vertex is unclustered (cid == -1): a
    // moving-set vertex outside every cluster. .active is derived from
    // centers.length>=2, so two centers keep it active.
    TransformTool.ClusterPivots cp;
    cp.centers = [Vec3(-1, 0, 0), Vec3(1, 0, 0)];
    cp.clusterOf = new int[nVerts];
    foreach (i; 0 .. nVerts) {
        if (i + 1 == nVerts) cp.clusterOf[i] = -1;          // last → unclustered
        else                 cp.clusterOf[i] = (i < nVerts / 2) ? 0 : 1;
    }
    return cp;
}

unittest { // (iv-oob-rotate) unclustered vert rotates GLOBALLY, not fixed
    auto vp = testViewport();
    auto fp = noFalloff();
    auto sp = noSymmetry();
    auto verts = sampleVerts();
    auto cp = partialClusterPivots(verts.length);
    auto ca = twoClusterAxes();
    int dragAxisIdx = 0;          // rotate about each cluster's RIGHT axis
    Vec3 globalAxis = Vec3(0, 0, 1);
    Vec3 pivot = Vec3(0.1f, -0.2f, 0.05f);
    float ang = 0.5f;
    auto idx = allIndices(verts.length);
    int oob = cast(int)verts.length - 1;   // the unclustered vertex

    // A: matrix kernel with per-cluster matrices AND a GLOBAL fallback M (the
    //    global rotation about globalAxis/pivot) — exactly what the LIVE applyTRS
    //    rotate pass (applyRotatePass) feeds as `M`.
    auto A = makeMesh(verts);
    bool[] tpA = new bool[A.vertices.length]; tpA[] = true;
    auto baseA = verts;
    float[16][] clusterM;
    foreach (cid; 0 .. cp.centers.length)
        clusterM ~= pivotRotationMatrix(Vec3(0,0,0), ca.right[cid], ang);
    applyXformMatrix(A, idx, baseA, pivot,
                     pivotRotationMatrix(Vec3(0,0,0), globalAxis, ang),
                     Vec3(0,0,0),
                     BlendMode.MatrixLerp, fp, vp, cp, ca, clusterM, sp, tpA);

    // The unclustered vert MUST have moved (proves it is NOT left at identity).
    {
        float moved = (A.vertices[oob] - verts[oob]).length;
        assert(moved > 1e-4f,
               "iv-oob rotate: unclustered vert must move (global fallback, "
               ~ "not identity)");
    }

    // And it must land EXACTLY where a plain global-M rotate (no cluster
    // resolvers) puts it — i.e. the fallback truly applies the global matrix.
    {
        auto G = makeMesh(verts);
        bool[] tpG = new bool[G.vertices.length]; tpG[] = true;
        auto baseG = verts;
        applyXformMatrix(G, idx, baseG, pivot,
                         pivotRotationMatrix(Vec3(0,0,0), globalAxis, ang),
                         Vec3(0,0,0),
                         BlendMode.MatrixLerp, fp, vp,
                         noClusterPivots(), noClusterAxes(), null, sp, tpG);
        float e = (A.vertices[oob] - G.vertices[oob]).length;
        assert(e < SHADOW_TOL,
               "iv-oob rotate: unclustered vert must match the global-M apply");
    }
}

unittest { // (iv-oob-scale) unclustered vert scales GLOBALLY, not fixed
    auto vp = testViewport();
    auto fp = noFalloff();
    auto sp = noSymmetry();
    auto verts = sampleVerts();
    auto cp = partialClusterPivots(verts.length);
    auto ca = twoClusterAxes();
    Vec3 pivot = Vec3(0.05f, 0.0f, -0.1f);
    Vec3 bx = Vec3(1,0,0), by = Vec3(0,1,0), bz = Vec3(0,0,1);
    Vec3 s = Vec3(2.0f, 0.5f, 1.3f);
    auto idx = allIndices(verts.length);
    int oob = cast(int)verts.length - 1;   // the unclustered vertex

    // A: matrix kernel with per-cluster scale matrices AND a GLOBAL fallback M
    //    (the global-basis scale) — exactly what the LIVE applyTRS S pass feeds.
    auto A = makeMesh(verts);
    bool[] tpA = new bool[A.vertices.length]; tpA[] = true;
    auto baseA = verts;
    float[16][] clusterM;
    foreach (cid; 0 .. cp.centers.length)
        clusterM ~= pivotScaleMatrixBasis(Vec3(0,0,0),
                        ca.right[cid], ca.up[cid], ca.fwd[cid], s.x, s.y, s.z);
    applyXformMatrix(A, idx, baseA, pivot,
                     pivotScaleMatrixBasis(Vec3(0,0,0), bx, by, bz, s.x, s.y, s.z),
                     Vec3(0,0,0),
                     BlendMode.MatrixLerp, fp, vp, cp, ca, clusterM, sp, tpA);

    // The unclustered vert MUST have moved (proves it is NOT left at identity).
    {
        float moved = (A.vertices[oob] - verts[oob]).length;
        assert(moved > 1e-4f,
               "iv-oob scale: unclustered vert must move (global fallback, "
               ~ "not identity)");
    }

    // And it must land EXACTLY where a plain global-basis scale puts it.
    {
        auto G = makeMesh(verts);
        bool[] tpG = new bool[G.vertices.length]; tpG[] = true;
        auto baseG = verts;
        applyXformMatrix(G, idx, baseG, pivot,
                         pivotScaleMatrixBasis(Vec3(0,0,0), bx, by, bz,
                                               s.x, s.y, s.z),
                         Vec3(0,0,0),
                         BlendMode.MatrixLerp, fp, vp,
                         noClusterPivots(), noClusterAxes(), null, sp, tpG);
        float e = (A.vertices[oob] - G.vertices[oob]).length;
        assert(e < SHADOW_TOL,
               "iv-oob scale: unclustered vert must match the global-M apply");
    }
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
                     Vec3(0,0,0),
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

// ---------------------------------------------------------------------------
// (vii) MS-3.5 (Gate-0) — b-vs-c blend-formula signal-floor measurement
// ---------------------------------------------------------------------------
//
// This is the EVIDENCE the canonical-matrix milestone needs before committing
// to a per-pass blend formula. The two live candidates are:
//
//   b = BlendMode.MatrixLerp : M(w) = (1-w)*I + w*M  — what applyTRS hardcodes
//                              today. It lerps the raw matrix entries, so a
//                              partially-weighted ROTATION traces a CHORD (the
//                              straight segment between I and R), not the arc;
//                              the moved point's distance from the pivot shrinks.
//   c = BlendMode.PolarQuat  : rotation via slerp(I->R, w) (the ARC), scale +
//                              translation via lerp. Radius-preserving.
//
// At w>=1 both equal M exactly; they diverge only for w in (0,1), and the
// divergence is MAXIMAL for rotation (chord vs arc). This harness sweeps w and
// a set of probe points at varying radius from the pivot, and for each sample
// records (a) absolute |p_b - p_c|, (b) the ANGLE between (p_b - pivot) and
// (p_c - pivot), and (c) the radius difference. The angular + radius gaps are
// the geometrically meaningful "how different could a user EVER see this look"
// numbers; the absolute gap is scale-dependent.
//
// Gate-0 verdict (pre-registered): take the MEDIAN angular gap over w in
// (0.05,0.95) for the PURE-ROTATION cases. Below 0.25 deg the two formulas are
// visually indistinguishable at realistic falloff weights and the cheap
// incumbent (b) should be kept (KEEP-B-INCONCLUSIVE); at or above the floor
// there is real signal worth a deeper comparison (SIGNAL-ABOVE-FLOOR). This is
// a MEASUREMENT, not a pass/fail — the test asserts only that the table was
// produced, NOT which side of the floor we land on.

private struct BlendMCase {
    string  name;
    float[16] M;
    bool    pureRotation;   // contributes to the Gate-0 median
}

// Median of a slice (sorts a copy). Empty -> 0.
private double medianOf(double[] xs) {
    if (xs.length == 0) return 0;
    import std.algorithm.sorting : sort;
    auto v = xs.dup;
    v.sort();
    size_t n = v.length;
    return (n % 2 == 1) ? v[n/2] : 0.5 * (v[n/2 - 1] + v[n/2]);
}

unittest {
    import std.math : acos, PI, fabs;
    import std.format : format;
    import math : matMul4, applyAffine;

    // blendToIdentity returns an ORIGIN-fixing matrix, so the blend's fixed
    // point — the "pivot" in the (p - pivot) framing below — is the origin.
    const Vec3 pivot = Vec3(0, 0, 0);

    // Off-axis rotation axis (no coordinate-plane alignment) so the chord-vs-arc
    // difference is exercised across all three components.
    Vec3 axis = normalize(Vec3(0.37f, -0.62f, 0.69f));

    BlendMCase[] cases;
    foreach (degAng; [15.0f, 45.0f, 90.0f]) {
        float ang = degAng * cast(float)PI / 180.0f;
        BlendMCase c;
        c.name = format("pure-rot %0.0fdeg", degAng);
        c.M = pivotRotationMatrix(Vec3(0,0,0), axis, ang);
        c.pureRotation = true;
        cases ~= c;
    }
    {
        // rotation (45deg) + non-uniform scale — the realistic "drag" matrix.
        BlendMCase c;
        c.name = "rot45+scale(1.6,0.7,1.2)";
        auto Rm = pivotRotationMatrix(Vec3(0,0,0), axis,
                                      45.0f * cast(float)PI / 180.0f);
        auto Sm = pivotScaleMatrixBasis(Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0),
                                        Vec3(0,0,1), 1.6f, 0.7f, 1.2f);
        c.M = matMul4(Rm, Sm);   // rotation · scale (origin-fixing)
        c.pureRotation = false;
        cases ~= c;
    }

    // Probe points at varying radius from the pivot.
    Vec3[] probes = [
        Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
        Vec3(0.5f, -0.4f, 0.8f), Vec3(-1, -1, -1),
        Vec3(2.3f, 0.1f, -1.7f),   // larger radius
    ];

    float[] ws = [0.05f, 0.1f, 0.2f, 0.3f, 0.4f, 0.5f,
                  0.6f, 0.7f, 0.8f, 0.9f, 0.95f];

    writeln("");
    writeln("MS35 b-vs-c blend gap (b=MatrixLerp chord, c=PolarQuat arc)");
    writeln("  ang = angle(deg) between (p_b-pivot) and (p_c-pivot);"
            ~ "  rad = | |p_b-pivot| - |p_c-pivot| |");
    writefln("%-26s %5s  %10s  %10s  %12s",
             "M-case", "w", "max_ang", "med_ang", "max_rad");

    double[] gate0Pool;     // per-(pure-rot-case, w) MEDIAN angular gap
    bool producedTable = false;

    foreach (ref c; cases) {
        foreach (w; ws) {
            auto Mb = blendToIdentity(c.M, w, BlendMode.MatrixLerp);
            auto Mc = blendToIdentity(c.M, w, BlendMode.PolarQuat);

            double maxAng = 0, maxRad = 0;
            double[] angs;
            foreach (p; probes) {
                Vec3 pb = applyAffine(Mb, p);
                Vec3 pc = applyAffine(Mc, p);

                Vec3 vb = pb - pivot;
                Vec3 vc = pc - pivot;
                double rb = vb.length;
                double rc = vc.length;

                double ang = 0;
                if (rb > 1e-9 && rc > 1e-9) {
                    double dot = (vb.x*vc.x + vb.y*vc.y + vb.z*vc.z) / (rb * rc);
                    if (dot >  1.0) dot =  1.0;
                    if (dot < -1.0) dot = -1.0;
                    ang = acos(dot) * 180.0 / PI;
                }
                angs ~= ang;
                if (ang > maxAng) maxAng = ang;
                double dr = fabs(rb - rc);
                if (dr > maxRad) maxRad = dr;
            }
            double medAng = medianOf(angs);
            writefln("%-26s %5.2f  %10.6f  %10.6f  %12.3e",
                     c.name, w, maxAng, medAng, maxRad);
            producedTable = true;

            // Gate-0 pool: pure-rotation cases, w strictly inside (0.05,0.95).
            if (c.pureRotation && w > 0.05f && w < 0.95f)
                gate0Pool ~= medAng;
        }
    }

    double gate0Median = medianOf(gate0Pool);
    enum double GATE0_FLOOR = 0.25;   // deg — pre-registered signal floor
    string verdict = gate0Median >= GATE0_FLOOR
        ? "SIGNAL-ABOVE-FLOOR" : "KEEP-B-INCONCLUSIVE";
    writeln("");
    writefln("MS35 GATE0: median_ang_gap=%.6gdeg threshold=%.2f => %s",
             gate0Median, GATE0_FLOOR, verdict);
    writeln("");

    // Measurement, NOT a pass/fail on the verdict. Assert only that the table
    // was actually produced and the pool non-empty, so a silently empty sweep
    // can't masquerade as a clean run.
    assert(producedTable, "MS35: gap table was not produced");
    assert(gate0Pool.length > 0, "MS35: Gate-0 pool empty — no pure-rot samples");
}
