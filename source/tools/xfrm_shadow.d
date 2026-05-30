module tools.xfrm_shadow;

// ---------------------------------------------------------------------------
// MS-2 — Per-pass dual-run shadow (measure-only).
// doc/modo_transform_model_plan.md, MS-2.
// ---------------------------------------------------------------------------
//
// This whole module is compiled ONLY under `debug(xfrmShadow)`. Production
// `dub build`, `dub build --config=with-render`, and the normal `./run_test.d`
// instance (built `-unittest` but NOT `-debug=xfrmShadow`) never compile a byte
// of it — `XfrmTransformTool.applyTRS`'s shadow hook is itself inside a
// `debug(xfrmShadow)` block, so a non-shadow build never imports this module's
// symbols either. The shadow can therefore never affect normal behaviour.
//
// What it does: at the END of `applyTRS`, after the live per-component
// T -> R -> S chain has written `mesh.vertices`, we reconstruct the SAME chain
// pass by pass through the MS-1 matrix kernel (`applyXformMatrix` +
// `blendToIdentity`, BlendMode.MatrixLerp) into a SCRATCH mesh, mirroring each
// pass's exact weight-eval position (T/R/view = LIVE scratch, S = BASELINE —
// the plan's per-pass table), then compare scratch vs an INDEPENDENT reference.
//
// MS-3 sub-task 1: the reference is NO LONGER `mesh.vertices` (the live applyTRS
// output passed in as `live`). Instead the shadow computes its OWN reference by
// running the FROZEN legacy per-component kernels (`tools.xform_kernels_legacy`,
// a verbatim copy of today's live kernels) through the exact same restore ->
// T -> R.x -> R.y -> R.z -> view-ring -> S chain into a REFERENCE mesh. Because
// the legacy kernels are byte-identical to the live ones, this reference equals
// `mesh.vertices` to the bit today, so the gate's maxErr / mismatch counts are
// unchanged. The point is independence: a LATER MS-3 task flips `applyTRS` to the
// matrix path, after which `mesh.vertices` IS the matrix result; comparing the
// matrix candidate against `mesh.vertices` would then be vacuous (matrix vs
// matrix). The legacy-computed reference keeps the comparison meaningful
// (matrix-apply vs legacy-frozen-reference). A
// mismatch is LOGGED to stderr with the `xfrmShadow: SHADOW MISMATCH` prefix; it
// NEVER asserts or aborts (F3) — the green-gate is enforced by the RUNNER
// grepping that prefix (R1), not in-process.
//
// It also accumulates the a/b/c drift report (F4): b = the legacy-computed
// per-component reference (was `live`; identical bits today, see above),
// c = the per-pass MatrixLerp reconstruction (the gate), a = a single
// composed `T·R·S` matrix blended once per vertex (the MS-3 naive candidate).
// b-vs-c runs every call; a-vs-c runs on a COARSER cadence (R2). All stats are
// THREAD-LOCAL (the shadow runs on the same thread as applyTRS — the UI thread);
// nothing is shared with http_server's background thread, and there is NO HTTP
// endpoint (F4). The SUMMARY line is re-emitted live (see emitSummary) so the
// gate counter survives the runner's SIGTERM-kill, and `static ~this()` dumps it
// once more on a clean exit.

debug (xfrmShadow):

import std.math : fabs;
import std.stdio : stderr;

import math : Vec3, Viewport, translationMatrix, pivotRotationMatrix,
              pivotScaleMatrixBasis, matMul4, applyAffine, identityMatrix;
import mesh : Mesh;
import falloff : evaluateFalloff;
import toolpipe.packets : FalloffPacket, SymmetryPacket;
import tools.transform : TransformTool;
import tools.xform_kernels : applyXformMatrix, blendToIdentity, BlendMode;
import tools.xform_kernels_legacy :
    legacyApplyTranslateIncremental, legacyApplyTranslatePerCluster,
    legacyApplyRotateIncremental, legacyApplyScaleFromActivation;

// ---------------------------------------------------------------------------
// Shared tolerance (plan N2 / R3).
// ---------------------------------------------------------------------------
//
// `SHADOW_TOL` is the per-vertex max-abs error above which the b-vs-c equality
// reconstruction is declared a MISMATCH. It is SHARED with the MS-1 unit test
// (tests/test_xform_matrix_kernel.d defines its own `SHADOW_TOL` enum at the
// SAME value; keep them in lockstep — see that test's header).
//
// Derivation (plan R3, measure-then-multiply):
//   measured_max = 5.96046e-08 on 2026-05-30 / Fedora 43 x86_64 via the
//   `./run_test.d --shadow` log-only shadow lane across the whole event-replay
//   transform suite (the WORST per-worker SUMMARY `maxErr` of a clean run on
//   green main). That is the float ULP-scale residue between the live decomposed
//   chain (Rodrigues `rotateVec` + scale + per-axis blends) and the matrix
//   kernel's `pivotRotationMatrix` / `pivotScaleMatrixBasis` / `applyAffine`
//   ordering across a multi-pass T->R->S reconstruction — far under the 1e-3
//   sanity bound the plan sets for "the kernel is wrong". (It is ~3 orders of
//   magnitude smaller than the first measurement: that earlier 3.05e-05 was an
//   artefact of an ordinal-vs-vid indexing bug in the reconstruction, fixed
//   before this measurement — see `ordinalSrc` above.) SHADOW_TOL =
//   measured_max * 16 absorbs platform libm drift without admitting a real
//   divergence (16x safety factor, per N2).
//
// 5.96046e-08 * 16 = 9.537e-07. Rounded slightly up to a clean 1e-6.
enum float SHADOW_TOL = 1e-6f;

// The measured value, kept beside the constant so a future reader can tell a
// real regression from tolerance drift (plan R3).
enum float SHADOW_MEASURED_MAX = 5.96046e-08f;  // 2026-05-30, Fedora 43 x86_64

// ---------------------------------------------------------------------------
// Thread-local run stats (F4). The shadow only ever runs on the applyTRS thread
// (the UI/main thread), so plain TLS is race-free — do NOT touch these from
// http_server's thread.
// ---------------------------------------------------------------------------

private size_t g_calls;          // total b-vs-c gate runs (every applyTRS)
private size_t g_skipped;        // compoundPasses != 1 SKIPs (F2)
private size_t g_mismatches;     // calls whose maxDiff >= SHADOW_TOL
private float  g_maxErr = 0;     // worst b-vs-c maxDiff seen
private size_t g_caseCounter;    // monotonic, feeds the case-id

// a/b/c drift (a-vs-c sampled on the coarser cadence, R2).
private size_t g_abcSamples;
private float  g_maxAB = 0;      // max|a-b|
private float  g_maxBC = 0;      // max|b-c| (the gate divergence, over a-samples)
private float  g_maxAC = 0;      // max|a-c|  — the MS-3 blend-choice signal
private bool   g_abcFractionalW; // did any a/b/c sample see a vert at 0<w<1?
private bool[16] g_abcFalloffSeen;  // FalloffType ordinals observed in a/b/c

// ---------------------------------------------------------------------------
// Public hook: called from applyTRS under debug(xfrmShadow) only. Every argument
// is a value already live inside applyTRS at the call site — we reconstruct the
// chain from them so applyTRS's signature is untouched (O1: no committedApply
// param). `live` is `mesh.vertices.dup` captured by the caller AFTER the live
// chain wrote it. As of MS-3 sub-task 1 the shadow NO LONGER uses `live` as its
// reference — it recomputes an independent reference from the frozen legacy
// kernels (see buildLegacyReference below). `live` is retained for context only
// (the caller passes it unchanged) and is no longer read.
// ---------------------------------------------------------------------------
void runShadow(
    Mesh*               mesh,
    const(Vec3)[]       live,        // live per-component result (UNUSED — legacy ref computed below)
    const(Vec3)[]       baseline,    // pre-chain snapshot (== mesh.vertices at restore)
    const(int)[]        indices,     // vertexIndicesToProcess
    bool[]              toProcess,
    Vec3                pivot,
    Vec3                bX, Vec3 bY, Vec3 bZ,
    bool                flagT, bool flagR, bool flagS,
    Vec3                headlessTranslate,
    Vec3                headlessRotate,
    Vec3                headlessRotateViewAxis,
    float               headlessRotateViewAngle,
    Vec3                headlessScale,
    const ref FalloffPacket dragFalloff,
    const ref SymmetryPacket dragSymmetry,
    const ref Viewport  vp,
    TransformTool.ClusterPivots cp,
    TransformTool.ClusterAxes   ap,
    string              presetName)
{
    import std.math : PI;

    // Best-effort case id: preset name + selection hash + monotonic counter.
    immutable size_t caseNo = ++g_caseCounter;
    immutable uint selHash  = selectionHash(indices);
    string caseId() {
        import std.format : format;
        return format("%s#sel%08x#%d", presetName, selHash, caseNo);
    }

    bool hasT = flagT && (headlessTranslate.x != 0 || headlessTranslate.y != 0
                          || headlessTranslate.z != 0);
    bool hasS = flagS && (headlessScale.x != 1 || headlessScale.y != 1
                          || headlessScale.z != 1);

    // ---- F2: SKIP compoundPasses != 1 when an S pass is active. -----------
    // The pow(s, passes) path has no matrix expression; only the SCALE kernel
    // reads compoundPasses, so the SKIP is correctly scale-scoped. A case that
    // publishes compoundPasses != 1 but runs no S pass is fully matrix-verified
    // and is NOT skipped.
    float passes = dragFalloff.compoundPasses > 0.0f
                 ? dragFalloff.compoundPasses : 1.0f;
    if (hasS && fabs(passes - 1.0f) > 1e-4f) {
        ++g_skipped;
        stderr.writefln(
            "xfrmShadow: SKIP compoundPasses=%g (case=%s) — scale pow path "
            ~ "not matrix-expressible; NOT matrix-verified",
            passes, caseId());
        stderr.flush();
        return;
    }

    if (live.length != mesh.vertices.length
        || baseline.length != mesh.vertices.length)
        return;   // defensive; the caller guarantees these, but never gate on it

    // ---- Build the INDEPENDENT legacy reference (the gate's `b`). ----------
    // MS-3 sub-task 1: instead of trusting `mesh.vertices` / `live` (which a
    // later task will make BE the matrix result), recompute the per-component
    // result from the FROZEN legacy kernels through the EXACT same chain
    // applyTRS runs: restore baseline -> T (per-cluster or global) -> R.x ->
    // R.y -> R.z -> view-ring -> S. Byte-identical to the live chain today
    // (legacy kernels are a verbatim copy), so the gate numbers are unchanged;
    // independent of applyTRS so the gate stays meaningful after the flip.
    auto reference = buildLegacyReference(
        baseline, indices, toProcess, pivot, bX, bY, bZ,
        flagT, flagR, hasT, hasS,
        headlessTranslate, headlessRotate,
        headlessRotateViewAxis, headlessRotateViewAngle, headlessScale,
        dragFalloff, dragSymmetry, vp, cp, ap);
    const(Vec3)[] ref_ = reference.vertices;

    // ---- Reconstruct the chain into a scratch mesh (MatrixLerp). ----------
    // The scratch shares the live mirror path: applyXformMatrix runs the SAME
    // applySymmetryMirror at the end of each pass (sharing dragSymmetry +
    // toProcess), exactly like the live kernels do.
    //
    // The scratch buffer is built by explicit element copy (NOT `.dup` of the
    // `const(Vec3)[]` slice) so it is a fresh, unaliased mesh-length buffer.
    auto scratch = new Mesh();
    scratch.vertices = new Vec3[](baseline.length);
    foreach (i; 0 .. baseline.length) scratch.vertices[i] = baseline[i];

    auto idxRef = indices.dup;

    // Array-layout contract (MS-1, applyXformMatrix): the `baseline` argument is
    // ORDINAL-parallel to `indices` — `base[k]` is the source position of vertex
    // `indices[k]`, sized `indices.length`. It is NOT a mesh-length vid-indexed
    // buffer. `ordinalSrc()` gathers the CURRENT scratch positions at each
    // `indices[k]` into that compact per-pass source. (Passing a mesh-length
    // `scratch.vertices.dup` was a real bug for face/edge selections where
    // `indices != [0,1,2,…]` — the kernel then read the wrong source vertex and
    // produced reflected output.)
    Vec3[] ordinalSrc() {
        auto s = new Vec3[](idxRef.length);
        foreach (k, vi; idxRef)
            s[k] = (vi >= 0 && vi < scratch.vertices.length)
                 ? scratch.vertices[vi] : Vec3(0, 0, 0);
        return s;
    }

    // -- T pass -------------------------------------------------------------
    if (hasT) {
        if (cp.active && ap.active) {
            // Per-cluster translate is falloff-EXEMPT (w==1, no falloff), signed
            // per-cluster axes — match applyTranslatePerCluster. Build one
            // translation matrix per cluster from its OWN right/up/fwd frame.
            // The GLOBAL fallback matrix is identityMatrix: a non-cluster vertex
            // (cid < 0) stays FIXED — matching the LIVE applyTRS T pass (which
            // also passes identityMatrix) and the legacy kernel
            // (legacyApplyTranslatePerCluster, which `continue`s on cid < 0). So
            // out-of-cluster translate is faithful as-is.
            float[16][] clusterM;
            clusterM.length = ap.right.length;
            foreach (cid; 0 .. ap.right.length) {
                Vec3 cr = ap.right[cid], cu = ap.up[cid], cf = ap.fwd[cid];
                Vec3 wd = cr * headlessTranslate.x
                        + cu * headlessTranslate.y
                        + cf * headlessTranslate.z;
                clusterM[cid] = translationMatrix(wd);
            }
            FalloffPacket noFo;  noFo.enabled = false;   // w==1 exempt
            applyXformMatrix(scratch, idxRef, ordinalSrc(), pivot,
                             identityMatrix, BlendMode.MatrixLerp,
                             noFo, vp, cp, ap, clusterM, dragSymmetry, toProcess);
        } else {
            // Global basis: delta = bX·TX + bY·TY + bZ·TZ; weight at LIVE scratch.
            Vec3 delta = bX * headlessTranslate.x
                       + bY * headlessTranslate.y
                       + bZ * headlessTranslate.z;
            applyXformMatrix(scratch, idxRef, ordinalSrc(), pivot,
                             translationMatrix(delta), BlendMode.MatrixLerp,
                             dragFalloff, vp, cp, ap, null, dragSymmetry, toProcess);
        }
    }

    // -- R.x / R.y / R.z passes --------------------------------------------
    // Each rotation about a basis axis (or per-cluster axis, dragAxisIdx 0/1/2);
    // weight at LIVE scratch (cluster rotate is LIVE-weighted, NOT exempt — R4).
    if (flagR) {
        if (headlessRotate.x != 0)
            rotatePass(scratch, idxRef, ordinalSrc(), toProcess, pivot, bX, 0,
                       headlessRotate.x * cast(float)(PI / 180.0),
                       dragFalloff, vp, cp, ap, dragSymmetry);
        if (headlessRotate.y != 0)
            rotatePass(scratch, idxRef, ordinalSrc(), toProcess, pivot, bY, 1,
                       headlessRotate.y * cast(float)(PI / 180.0),
                       dragFalloff, vp, cp, ap, dragSymmetry);
        if (headlessRotate.z != 0)
            rotatePass(scratch, idxRef, ordinalSrc(), toProcess, pivot, bZ, 2,
                       headlessRotate.z * cast(float)(PI / 180.0),
                       dragFalloff, vp, cp, ap, dragSymmetry);

        // view-ring pass: rotation about the arbitrary camera-forward axis,
        // dragAxisIdx == -1 (no per-cluster substitution).
        bool hasViewRot = headlessRotateViewAngle != 0
            && (headlessRotateViewAxis.x != 0 || headlessRotateViewAxis.y != 0
                || headlessRotateViewAxis.z != 0);
        if (hasViewRot)
            rotatePass(scratch, idxRef, ordinalSrc(), toProcess, pivot,
                       headlessRotateViewAxis, -1,
                       headlessRotateViewAngle * cast(float)(PI / 180.0),
                       dragFalloff, vp, cp, ap, dragSymmetry);
    }

    // -- S pass -------------------------------------------------------------
    // Geometry source = current scratch (post-T/R); weight at BASELINE
    // (weightVerts == baseline, NOT scratch). Mirrors applyScaleFromActivation
    // (activation = post-T/R, weightVerts = baseline). compoundPasses==1 here
    // (the != 1 case was SKIPped above). The scale matrix is ORIGIN-fixing:
    // applyXformMatrix re-applies the pivot itself (pivot + M·(base - pivot)), so
    // M is built around Vec3(0), matching the MS-1 (i-S) construction. The S
    // weight is at BASELINE, but baseline here is the mesh-length vid-indexed
    // buffer the live scale kernel uses (weightVerts[vi]) — passed as-is.
    if (hasS) {
        // Per-cluster scale uses each cluster's OWN right/up/fwd frame (matching
        // the per-component kernel's axesFor()), selected per vertex via
        // clusterM. The GLOBAL scale matrix (built from bX/bY/bZ) is the fallback
        // `M` for any non-cluster vertex (cid < 0) — matching the LIVE applyTRS
        // S pass. Earlier the shadow passed clusterM=null and only the global
        // matrix, so in-cluster verts would use the global basis instead of their
        // per-cluster frame; the suite never tripped it because ACEN.Local scale
        // was not exercised. Mirror live exactly so the gate covers it.
        float[16][] clusterM = null;
        if (cp.active && ap.active) {
            clusterM = new float[16][](ap.right.length);
            foreach (cid; 0 .. ap.right.length)
                clusterM[cid] = pivotScaleMatrixBasis(
                    Vec3(0, 0, 0),
                    ap.right[cid], ap.up[cid], ap.fwd[cid],
                    headlessScale.x, headlessScale.y, headlessScale.z);
        }
        applyXformMatrix(scratch, idxRef, ordinalSrc(), pivot,
                         pivotScaleMatrixBasis(Vec3(0, 0, 0), bX, bY, bZ,
                                               headlessScale.x, headlessScale.y,
                                               headlessScale.z),
                         BlendMode.MatrixLerp,
                         dragFalloff, vp, cp, ap, clusterM, dragSymmetry, toProcess,
                         /*weightVerts=*/ baseline);
    }

    // ---- b-vs-c equality GATE: scratch (c) vs legacy reference (b). -------
    // Compare on every processed index AND every symmetry-mirror index. The
    // legacy reference ran the SAME applySymmetryMirror chain the live kernels
    // do, and scratch ran the matrix-path mirror, so a plain whole-array compare
    // covers both. `ref_` is the independent legacy result, NOT `live`.
    ++g_calls;
    float maxDiff = 0;
    size_t worstVi = 0;
    foreach (vi; 0 .. mesh.vertices.length) {
        float e = maxAbs(scratch.vertices[vi] - ref_[vi]);
        if (e > maxDiff) { maxDiff = e; worstVi = vi; }
    }
    if (maxDiff > g_maxErr) g_maxErr = maxDiff;

    if (maxDiff >= SHADOW_TOL) {
        ++g_mismatches;
        // Diagnostics (plan F3): worst vertex, the active component(s), falloff
        // type, ACEN mode (the pivot is its observable output), the maxDiff. The
        // literal `SHADOW MISMATCH` substring is what the R1 runner greps.
        // `live=` reports the legacy reference (the gate's `b`).
        stderr.writefln(
            "xfrmShadow: SHADOW MISMATCH case=%s vi=%d live=(%g,%g,%g) "
            ~ "shadow=(%g,%g,%g) err=%g active=[%s] falloff=%s pivot=(%g,%g,%g)",
            caseId(), worstVi,
            ref_[worstVi].x, ref_[worstVi].y, ref_[worstVi].z,
            scratch.vertices[worstVi].x, scratch.vertices[worstVi].y,
            scratch.vertices[worstVi].z,
            maxDiff,
            activeComponents(hasT, flagR, headlessRotate, headlessRotateViewAngle,
                             hasS),
            falloffName(dragFalloff),
            pivot.x, pivot.y, pivot.z);
        stderr.flush();
    }

    // ---- a-vs-c DRIFT report (R2: coarser cadence than the b-vs-c gate). ---
    // first call + every 8th. N=8 keeps a-vs-c (which builds THREE
    // reconstructions) well under the gate's per-call cost while still firing in
    // the small event-replay batches the suite drives (most workers issue only
    // ~10-20 applyTRS calls, so a large N would never sample). It is strictly
    // coarser than the b-vs-c gate and never runs on EVERY per-frame apply.
    if (g_calls == 1 || (g_calls % 8) == 0)
        sampleAbc(mesh, ref_, baseline, idxRef, toProcess, pivot, bX, bY, bZ,
                  flagT, flagR, flagS, headlessTranslate, headlessRotate,
                  headlessRotateViewAxis, headlessRotateViewAngle, headlessScale,
                  hasT, hasS, dragFalloff, dragSymmetry, vp, cp, ap);

    // Live SUMMARY/ABC re-emit so the numbers survive the runner's SIGTERM-kill
    // (no clean exit ⇒ no static ~this()). Emit on the FIRST call (so even a tiny
    // <8-call run leaves a SUMMARY for the gate + maxErr measurement) and every
    // 8th thereafter. The runner greps the LAST SUMMARY line, so the periodic
    // re-emit is correct and monotonic.
    if (g_calls == 1 || (g_calls % 8) == 0)
        emitSummary();
}

// ---------------------------------------------------------------------------
// One rotation pass into the scratch buffer. `base` is ORDINAL-parallel to
// `idxRef` (base[k] ↔ idxRef[k]) — the caller gathers the current scratch
// positions for the moving set. Leaving weightVerts null makes applyXformMatrix
// weight at base[k], i.e. the LIVE scratch position for this pass (R4: cluster
// rotate is LIVE-weighted, NOT falloff-exempt). The matrix is ORIGIN-fixing;
// applyXformMatrix re-applies the (possibly per-cluster) pivot. For the
// per-cluster branch the GLOBAL fallback `M` is the global rotation about
// `axis`/`pivot` (NOT identity) so non-cluster verts (cid < 0) rotate globally,
// matching the LIVE applyTRS rotate pass exactly.
// ---------------------------------------------------------------------------
private void rotatePass(
    Mesh* scratch, const(int)[] idxRef, Vec3[] base, bool[] toProcess,
    Vec3 pivot, Vec3 axis, int dragAxisIdx, float angleRad,
    const ref FalloffPacket dragFalloff, const ref Viewport vp,
    TransformTool.ClusterPivots cp, TransformTool.ClusterAxes ap,
    const ref SymmetryPacket dragSymmetry)
{
    if (dragAxisIdx >= 0 && dragAxisIdx <= 2 && ap.active) {
        // Per-cluster rotate: one origin-fixing rotation matrix per cluster about
        // that cluster's axis (right/up/fwd at dragAxisIdx). The kernel resolves
        // the per-cluster pivot via cp; M is built around the ORIGIN so
        // pivot + M·(base - pivot) yields the cluster-pivoted rotation (matches
        // the MS-1 (iv-rotate) construction). The GLOBAL fallback matrix (passed
        // as `M`) rotates any non-cluster vertex (cid < 0) about the global
        // `axis`/`pivot` — matching the LIVE applyTRS rotate pass
        // (applyRotatePass) and the legacy rotate kernel, whose
        // pivotFor()/axisFor() fall back to the global axis/pivot for verts
        // outside every cluster (NOT identity). Earlier this passed
        // identityMatrix, which left out-of-cluster verts fixed and diverged
        // from live; the suite never tripped it because every moving vert was
        // in a cluster.
        float[16][] clusterM;
        clusterM.length = ap.right.length;
        foreach (cid; 0 .. ap.right.length) {
            Vec3 ca = dragAxisIdx == 0 ? ap.right[cid]
                    : dragAxisIdx == 1 ? ap.up[cid]
                                       : ap.fwd[cid];
            clusterM[cid] = pivotRotationMatrix(Vec3(0, 0, 0), ca, angleRad);
        }
        applyXformMatrix(scratch, idxRef, base, pivot,
                         pivotRotationMatrix(Vec3(0, 0, 0), axis, angleRad),
                         BlendMode.MatrixLerp,
                         dragFalloff, vp, cp, ap, clusterM, dragSymmetry, toProcess);
    } else {
        // Global / view-ring: single origin-fixing rotation about `axis`.
        applyXformMatrix(scratch, idxRef, base, pivot,
                         pivotRotationMatrix(Vec3(0, 0, 0), axis, angleRad),
                         BlendMode.MatrixLerp,
                         dragFalloff, vp, cp, ap, null, dragSymmetry, toProcess);
    }
}

// ---------------------------------------------------------------------------
// Independent legacy reference (MS-3 sub-task 1, the gate's `b`).
//
// Runs the FROZEN legacy per-component kernels (tools.xform_kernels_legacy)
// through the EXACT chain `applyTRS` executes:
//   restore baseline -> T (per-cluster OR global) -> R.x -> R.y -> R.z ->
//   view-ring -> S
// into a fresh REFERENCE mesh, and returns it. This is a verbatim mirror of the
// live `applyTRS` body (xfrm_transform.d) but calling the `legacyApply*`
// kernels, so it is byte-identical to `mesh.vertices` today AND independent of
// whatever applyTRS does after the MS-3 flip.
//
// The reference buffer is built by explicit element copy from the
// `const(Vec3)[] baseline` (NOT `.dup` of the const slice — same unaliasing rule
// as the scratch buffer). `toProcess` is dup'd so the legacy kernels (which take
// a mutable `bool[]` for the symmetry mirror) never alias the caller's array.
// ---------------------------------------------------------------------------
private Mesh* buildLegacyReference(
    const(Vec3)[] baseline, const(int)[] indices, bool[] toProcess,
    Vec3 pivot, Vec3 bX, Vec3 bY, Vec3 bZ,
    bool flagT, bool flagR, bool hasT, bool hasS,
    Vec3 headlessTranslate, Vec3 headlessRotate,
    Vec3 headlessRotateViewAxis, float headlessRotateViewAngle, Vec3 headlessScale,
    const ref FalloffPacket dragFalloff, const ref SymmetryPacket dragSymmetry,
    const ref Viewport vp,
    TransformTool.ClusterPivots cp, TransformTool.ClusterAxes ap)
{
    import std.math : PI;

    // Restore baseline into a fresh mesh-length buffer (== applyTRS's
    // unconditional whole-baseline restore prologue).
    auto refMesh = new Mesh();
    refMesh.vertices = new Vec3[](baseline.length);
    foreach (i; 0 .. baseline.length) refMesh.vertices[i] = baseline[i];

    auto idxRef = indices.dup;
    auto tp     = toProcess.dup;   // legacy kernels need a mutable bool[]

    // -- T pass (applyTRS: flagT && hasT branch). ---------------------------
    if (flagT && hasT) {
        if (cp.active && ap.active) {
            legacyApplyTranslatePerCluster(refMesh, idxRef, cp, ap,
                                           headlessTranslate,
                                           dragSymmetry, tp);
        } else {
            Vec3 delta = bX * headlessTranslate.x
                       + bY * headlessTranslate.y
                       + bZ * headlessTranslate.z;
            legacyApplyTranslateIncremental(refMesh, idxRef, delta,
                                            dragFalloff, vp,
                                            dragSymmetry, tp);
        }
    }

    // -- R.x / R.y / R.z + view-ring passes (applyTRS: flagR branch). -------
    if (flagR) {
        if (headlessRotate.x != 0)
            legacyApplyRotateIncremental(refMesh, idxRef, pivot, bX, 0,
                                         headlessRotate.x * cast(float)(PI / 180.0),
                                         dragFalloff, vp, cp, ap, dragSymmetry, tp);
        if (headlessRotate.y != 0)
            legacyApplyRotateIncremental(refMesh, idxRef, pivot, bY, 1,
                                         headlessRotate.y * cast(float)(PI / 180.0),
                                         dragFalloff, vp, cp, ap, dragSymmetry, tp);
        if (headlessRotate.z != 0)
            legacyApplyRotateIncremental(refMesh, idxRef, pivot, bZ, 2,
                                         headlessRotate.z * cast(float)(PI / 180.0),
                                         dragFalloff, vp, cp, ap, dragSymmetry, tp);

        bool hasViewRot = headlessRotateViewAngle != 0
            && (headlessRotateViewAxis.x != 0 || headlessRotateViewAxis.y != 0
                || headlessRotateViewAxis.z != 0);
        if (hasViewRot)
            legacyApplyRotateIncremental(refMesh, idxRef, pivot,
                                         headlessRotateViewAxis, -1,
                                         headlessRotateViewAngle * cast(float)(PI / 180.0),
                                         dragFalloff, vp, cp, ap, dragSymmetry, tp);
    }

    // -- S pass (applyTRS: flagS && hasS branch). ---------------------------
    // Mirrors the live S call: activation = current (post-T/R) positions,
    // weightVerts = baseline (so the per-vert weight is at the pre-chain pos).
    if (hasS) {
        Vec3[] activation = refMesh.vertices.dup;
        legacyApplyScaleFromActivation(refMesh, idxRef, activation, pivot,
                                       bX, bY, bZ, headlessScale,
                                       dragFalloff, vp, cp, ap, dragSymmetry, tp,
                                       baseline);
    }

    return refMesh;
}

// ---------------------------------------------------------------------------
// a-vs-c drift sample (R2). Builds a SINGLE composed M = T·R·S (the MS-3 naive
// single-matrix candidate, blended once per vertex by the baseline weight) and
// compares it to the faithful per-pass reconstruction c (and to live b). This
// quantifies how far the naive single-matrix model drifts on cases the suite
// exercises — the input MS-3 needs to choose its blend.
//
// Composed-M is built ONLY for the non-per-cluster case (the only case where one
// global M is meaningful); per-cluster a/b/c is skipped (no single global M) but
// b-vs-c still gated it above.
// ---------------------------------------------------------------------------
private void sampleAbc(
    Mesh* mesh, const(Vec3)[] live /* b = legacy reference, see runShadow */,
    const(Vec3)[] baseline,
    const(int)[] indices, bool[] toProcess,
    Vec3 pivot, Vec3 bX, Vec3 bY, Vec3 bZ,
    bool flagT, bool flagR, bool flagS,
    Vec3 headlessTranslate, Vec3 headlessRotate,
    Vec3 headlessRotateViewAxis, float headlessRotateViewAngle, Vec3 headlessScale,
    bool hasT, bool hasS,
    const ref FalloffPacket dragFalloff, const ref SymmetryPacket dragSymmetry,
    const ref Viewport vp,
    TransformTool.ClusterPivots cp, TransformTool.ClusterAxes ap)
{
    import std.math : PI;

    if (cp.active && ap.active) return;   // no single global M for per-cluster
    if (indices.length == 0) return;

    auto ir = indices.dup;

    // c = the faithful per-pass reconstruction (same as the b-vs-c gate's
    // scratch, rebuilt locally — a-vs-c is rare, R2). `cOrdinalSrc` gathers the
    // CURRENT cMesh positions for the moving set, ordinal-parallel to `ir`.
    auto cMesh = new Mesh();
    cMesh.vertices = new Vec3[](baseline.length);
    foreach (i; 0 .. baseline.length) cMesh.vertices[i] = baseline[i];
    Vec3[] cOrdinalSrc() {
        auto s = new Vec3[](ir.length);
        foreach (k, vi; ir)
            s[k] = (vi >= 0 && vi < cMesh.vertices.length)
                 ? cMesh.vertices[vi] : Vec3(0, 0, 0);
        return s;
    }
    if (hasT) {
        Vec3 delta = bX * headlessTranslate.x + bY * headlessTranslate.y
                   + bZ * headlessTranslate.z;
        applyXformMatrix(cMesh, ir, cOrdinalSrc(), pivot, translationMatrix(delta),
                         BlendMode.MatrixLerp, dragFalloff, vp, cp, ap, null,
                         dragSymmetry, toProcess);
    }
    if (flagR) {
        if (headlessRotate.x != 0)
            rotatePass(cMesh, ir, cOrdinalSrc(), toProcess, pivot, bX, -1,
                       headlessRotate.x * cast(float)(PI/180.0),
                       dragFalloff, vp, cp, ap, dragSymmetry);
        if (headlessRotate.y != 0)
            rotatePass(cMesh, ir, cOrdinalSrc(), toProcess, pivot, bY, -1,
                       headlessRotate.y * cast(float)(PI/180.0),
                       dragFalloff, vp, cp, ap, dragSymmetry);
        if (headlessRotate.z != 0)
            rotatePass(cMesh, ir, cOrdinalSrc(), toProcess, pivot, bZ, -1,
                       headlessRotate.z * cast(float)(PI/180.0),
                       dragFalloff, vp, cp, ap, dragSymmetry);
        bool hasViewRot = headlessRotateViewAngle != 0
            && (headlessRotateViewAxis.x != 0 || headlessRotateViewAxis.y != 0
                || headlessRotateViewAxis.z != 0);
        if (hasViewRot)
            rotatePass(cMesh, ir, cOrdinalSrc(), toProcess, pivot,
                       headlessRotateViewAxis, -1,
                       headlessRotateViewAngle * cast(float)(PI/180.0),
                       dragFalloff, vp, cp, ap, dragSymmetry);
    }
    if (hasS) {
        applyXformMatrix(cMesh, ir, cOrdinalSrc(), pivot,
                         pivotScaleMatrixBasis(Vec3(0, 0, 0), bX, bY, bZ,
                             headlessScale.x, headlessScale.y, headlessScale.z),
                         BlendMode.MatrixLerp, dragFalloff, vp, cp, ap, null,
                         dragSymmetry, toProcess, baseline);
    }

    // a = single composed M = T · R · S (pivot-relative), blended once per vertex.
    float[16] M = identityMatrix;
    if (hasT) {
        Vec3 delta = bX * headlessTranslate.x + bY * headlessTranslate.y
                   + bZ * headlessTranslate.z;
        M = matMul4(translationMatrix(delta), M);
    }
    if (flagR) {
        if (headlessRotate.x != 0)
            M = matMul4(pivotRotationMatrix(Vec3(0,0,0), bX,
                        headlessRotate.x * cast(float)(PI/180.0)), M);
        if (headlessRotate.y != 0)
            M = matMul4(pivotRotationMatrix(Vec3(0,0,0), bY,
                        headlessRotate.y * cast(float)(PI/180.0)), M);
        if (headlessRotate.z != 0)
            M = matMul4(pivotRotationMatrix(Vec3(0,0,0), bZ,
                        headlessRotate.z * cast(float)(PI/180.0)), M);
        bool hasViewRot = headlessRotateViewAngle != 0
            && (headlessRotateViewAxis.x != 0 || headlessRotateViewAxis.y != 0
                || headlessRotateViewAxis.z != 0);
        if (hasViewRot)
            M = matMul4(pivotRotationMatrix(Vec3(0,0,0), headlessRotateViewAxis,
                        headlessRotateViewAngle * cast(float)(PI/180.0)), M);
    }
    if (hasS)
        M = matMul4(pivotScaleMatrixBasis(Vec3(0,0,0), bX, bY, bZ,
                    headlessScale.x, headlessScale.y, headlessScale.z), M);

    ++g_abcSamples;
    g_abcFalloffSeen[falloffOrdinal(dragFalloff) & 15] = true;

    foreach (vi; ir) {
        if (vi < 0 || vi >= cast(int)mesh.vertices.length
            || vi >= cast(int)baseline.length) continue;
        // `baseline` is mesh-length / vid-indexed: index by vi, NOT loop ordinal.
        Vec3 base = baseline[vi];
        float w = dragFalloff.enabled
            ? evaluateFalloff(dragFalloff, base, vi, vp) : 1.0f;
        if (w == 0.0f) continue;
        if (w > 0.0f && w < 1.0f) {
            g_abcFractionalW = true;
            g_abcFalloffSeen[falloffOrdinal(dragFalloff) & 15] = true;
        }
        float[16] Mw = blendToIdentity(M, w, BlendMode.MatrixLerp);
        Vec3 a = pivot + applyAffine(Mw, base - pivot);
        Vec3 c = cMesh.vertices[vi];
        Vec3 b = live[vi];
        float ab = maxAbs(a - b), bc = maxAbs(b - c), ac = maxAbs(a - c);
        if (ab > g_maxAB) g_maxAB = ab;
        if (bc > g_maxBC) g_maxBC = bc;
        if (ac > g_maxAC) g_maxAC = ac;
    }
}

// ---------------------------------------------------------------------------
// Helpers.
// ---------------------------------------------------------------------------

private float maxAbs(Vec3 d) {
    float ax = fabs(d.x), ay = fabs(d.y), az = fabs(d.z);
    return ax > ay ? (ax > az ? ax : az) : (ay > az ? ay : az);
}

private uint selectionHash(const(int)[] indices) {
    // FNV-1a over the moving set — stable, cheap, just for the case-id.
    uint h = 2166136261u;
    foreach (vi; indices) {
        h ^= cast(uint)vi;
        h *= 16777619u;
    }
    return h;
}

private string activeComponents(bool hasT, bool flagR, Vec3 rot, float viewAng,
                                bool hasS) {
    string s;
    void add(string c) { if (s.length) s ~= ","; s ~= c; }
    if (hasT) add("T");
    if (flagR && rot.x != 0) add("R.x");
    if (flagR && rot.y != 0) add("R.y");
    if (flagR && rot.z != 0) add("R.z");
    if (flagR && viewAng != 0) add("view");
    if (hasS) add("S");
    return s.length ? s : "(none)";
}

private string falloffName(const ref FalloffPacket f) {
    import std.conv : to;
    if (!f.enabled) return "off";
    return f.type.to!string;
}

private int falloffOrdinal(const ref FalloffPacket f) {
    if (!f.enabled) return 0;
    return cast(int)f.type;
}

// ---------------------------------------------------------------------------
// SUMMARY dump (F4). The final SUMMARY line is machine-greppable for the R1
// runner counter assertion — it reads `mismatches=<m>` and reds the lane if
// m != 0. See the module header for why it is re-emitted live (the runner
// SIGTERM-kills vibe3d, so `static ~this()` does not fire under the lane).
// ---------------------------------------------------------------------------
private void emitSummary() {
    string falloffList() {
        import toolpipe.packets : FalloffType;
        import std.conv : to;
        string s;
        foreach (i; 0 .. 16) {
            if (!g_abcFalloffSeen[i]) continue;
            if (s.length) s ~= ",";
            s ~= i == 0 ? "off" : (cast(FalloffType)i).to!string;
        }
        return s.length ? s : "(none)";
    }

    // a/b/c drift detail line (the documented MS-2 deliverable).
    stderr.writefln(
        "xfrmShadow: ABC samples=%d maxAB=%g maxBC=%g maxAC=%g "
        ~ "fractionalW=%s falloffTypes=[%s]",
        g_abcSamples, g_maxAB, g_maxBC, g_maxAC,
        g_abcFractionalW ? "yes" : "no", falloffList());

    // The machine-greppable SUMMARY line (R1 reads mismatches=<m>).
    stderr.writefln(
        "xfrmShadow: SUMMARY calls=%d skipped=%d mismatches=%d maxErr=%g",
        g_calls, g_skipped, g_mismatches, g_maxErr);
    stderr.flush();
}

static ~this() {
    if (g_calls == 0 && g_skipped == 0) return;   // shadow never ran
    emitSummary();
}
