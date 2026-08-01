module tools.transform.xform_kernels;

// Per-mode transform kernels — pure-ish functions that mutate
// `mesh.vertices` for a transform tool's drag step. Lifted from
// MoveTool.applyDeltaImmediate / applyAbsoluteFromBaseline,
// RotateTool.applyRotationVec / applyAbsoluteFromOrigCpuOnly,
// ScaleTool.applyScaleFromActivationCpuOnly. The original method
// bodies in the tools now delegate to these — the math lives in
// exactly one place so future divergence between Move / Rotate /
// Scale and the unified xfrm.transform tool is impossible.
//
// Side effects: each kernel writes to `mesh.vertices` AND invokes
// the symmetry mirror pass (applySymmetryMirror) when the symmetry
// packet is enabled — mirror writes touch additional indices, so
// callers using a per-vert dirty mask must rebuild it AFTER the
// kernel returns (current callers already re-evaluate
// `needsGpuUpdate` / `toProcess` post-call).
//
// The kernels don't capture the falloff / symmetry packets; callers
// pass the already-captured drag snapshots in. This matches the
// "snapshot at drag start" invariant the tools already maintain via
// captureFalloffForDrag / captureSymmetryForDrag.

import math    : Vec3, Viewport, dot, cross;
import math    : Quat, slerp, quatFromMatrix, matrixFromQuat, applyAffine,
                 matMul4, identityMatrix;
import mesh    : Mesh;
import falloff : evaluateFalloff;
import symmetry : applySymmetryMirror;
import toolpipe.packets : FalloffPacket, SymmetryPacket;
import tools.transform.transform : TransformTool;
import perf_probe : g_perf, Cat;

// Coarse perf instrumentation for the kernels (doc/perf_harness_plan.md).
// One scope at function entry (NEVER inside the per-vertex loop), the
// symmetry mirror call wrapped in its own category, and DERIVED counters
// recorded once after the loop (verts.touched / falloff.evalCount =
// number of vertices processed — not incremented per vertex). All of this
// compiles to no-ops in the default build.

/// Time + mirror the symmetry pass and record the per-call vertex counters.
/// `nVerts` is the number of vertices the kernel processed this call; both
/// vertsTouched and falloffEvalCount are derived from it (one falloff
/// evaluation per processed vertex when falloff is enabled).
private void mirrorAndCount(
    Mesh* mesh,
    const ref SymmetryPacket dragSymmetry,
    bool[] selA, bool[] selB,
    long nVerts, bool falloffEnabled)
{
    g_perf.count(Cat.vertsTouched, nVerts);
    if (falloffEnabled) g_perf.count(Cat.falloffEvalCount, nVerts);
    if (dragSymmetry.enabled
        && dragSymmetry.pairOf.length == mesh.vertices.length) {
        auto zMirror = g_perf.scope_(Cat.symmetryMirror);
        applySymmetryMirror(mesh, dragSymmetry, selA, selB);
    }
}

// ---------------------------------------------------------------
// Translate
// ---------------------------------------------------------------

/// Per-vertex incremental translate. Mirrors the non-baseline branch
/// of MoveTool.applyDeltaImmediate.
///
/// - `dragFalloff.enabled == false`: tight 3-add loop, every index
///   moves by `delta`.
/// - `dragFalloff.enabled == true`: each vert displacement scaled by
///   `evaluateFalloff(dragFalloff, mesh.vertices[vi], vi, vp)` — note
///   the LIVE post-mutation position, used only when no baseline is
///   available (e.g. tests bypassing beginEdit).
///
/// `toProcess` is the same per-vert mask the tool already maintains;
/// it doubles as the "selected" input for the symmetry mirror.
void applyTranslateIncremental(
    Mesh* mesh,
    const(int)[] indices,
    Vec3 delta,
    const ref FalloffPacket dragFalloff,
    const ref Viewport vp,
    const ref SymmetryPacket dragSymmetry,
    bool[] toProcess)
{
    auto zKernel = g_perf.scope_(Cat.kernelApply);
    if (!dragFalloff.enabled) {
        foreach (vi; indices) {
            mesh.vertices[vi].x += delta.x;
            mesh.vertices[vi].y += delta.y;
            mesh.vertices[vi].z += delta.z;
        }
    } else {
        foreach (vi; indices) {
            float w = evaluateFalloff(dragFalloff,
                                       mesh.vertices[vi],
                                       cast(int)vi, vp);
            if (w == 0.0f) continue;
            mesh.vertices[vi].x += delta.x * w;
            mesh.vertices[vi].y += delta.y * w;
            mesh.vertices[vi].z += delta.z * w;
        }
    }
    mirrorAndCount(mesh, dragSymmetry, toProcess, toProcess,
                   cast(long)indices.length, dragFalloff.enabled);
}

// ---------------------------------------------------------------
// Rotate
// ---------------------------------------------------------------

// Rodrigues-style rotation around `pivot + axis`.
private Vec3 rotateVec(Vec3 v, Vec3 pivot, Vec3 axis, float angle) {
    import std.math : cos, sin;
    import math : dot, cross;
    float c = cos(angle), s = sin(angle);
    Vec3 p = v - pivot;
    float d = dot(p, axis);
    Vec3 pcr = cross(axis, p);
    return pivot + p * c + pcr * s + axis * (d * (1.0f - c));
}

// Falloff-WEIGHTED rotation as a linear interpolation of the rotation MATRIX —
// matches the reference engine's soft-rotation / twist:
//   M(w) = (1-w)·I + w·R(angle)
// applied to (v - pivot). At w=0 this is the identity, at w=1 the full rotation
// R(angle); in between M(w) is a blend of two rotation matrices and is no longer
// orthogonal, so the point rotates by an intermediate angle AND its radius
// shrinks (a pinch through the falloff transition that vanishes at w=0 and w=1).
// This unifies with the other tools, which are the same M(w)=(1-w)I+w·T blend:
// translation → linear displacement, scale → 1+w·(factor-1). It is NOT the
// "arc" R(angle·w) (radius-preserving) NOR a non-normalized quaternion lerp
// (which pinches too little). `axis` is unit. (Verified vertex-exact against the
// reference: rotate-X + linear-Z falloff on a segmented cube, angle+radius RMS<2e-3.)
private Vec3 rotateVecLerp(Vec3 v, Vec3 pivot, Vec3 axis, float angle, float w) {
    Vec3 p  = v - pivot;
    Vec3 rp = rotateVec(v, pivot, axis, angle) - pivot;   // R(angle)·(v-pivot)
    return pivot + p * (1.0f - w) + rp * w;                // (1-w)·I + w·R
}

private Vec3 pivotFor(size_t vi,
                      TransformTool.ClusterPivots cp,
                      Vec3 fallback)
{
    if (!cp.active) return fallback;
    if (vi >= cp.clusterOf.length) return fallback;
    int cid = cp.clusterOf[vi];
    if (cid < 0 || cid >= cast(int)cp.centers.length) return fallback;
    return cp.centers[cid];
}

private Vec3 axisFor(size_t vi, int axisIdx,
                     TransformTool.ClusterAxes ap,
                     TransformTool.ClusterPivots cp,
                     Vec3 fallback)
{
    if (!ap.active) return fallback;
    if (vi >= cp.clusterOf.length) return fallback;
    int cid = cp.clusterOf[vi];
    if (cid < 0 || cid >= cast(int)ap.right.length) return fallback;
    if (axisIdx == 0) return ap.right[cid];
    if (axisIdx == 1) return ap.up   [cid];
    return ap.fwd[cid];
}

private void axesFor(size_t vi,
                     TransformTool.ClusterAxes ap,
                     TransformTool.ClusterPivots cp,
                     ref Vec3 ax, ref Vec3 ay, ref Vec3 az)
{
    if (!ap.active) return;
    if (vi >= cp.clusterOf.length) return;
    int cid = cp.clusterOf[vi];
    if (cid < 0 || cid >= cast(int)ap.right.length) return;
    ax = ap.right[cid];
    ay = ap.up[cid];
    az = ap.fwd[cid];
}

/// Per-vertex incremental rotation around `axisFallback` by `angleRad`.
/// Mirrors RotateTool.applyRotationVec.
///
/// `dragAxisIdx ∈ {0,1,2}` triggers per-cluster axis lookup (the
/// cluster's right / up / fwd at that index replaces `axisFallback`
/// for verts that belong to a cluster). `dragAxisIdx == -1` keeps
/// `axisFallback` for every vertex (screen-ring drag).
///
/// Falloff weight blends via a rotation-MATRIX lerp (rotateVecLerp):
/// M(w)=(1-w)·I+w·R(angle) — intermediate angle + radius pinch (matches the reference, NOT θ·w arc).
void applyRotateIncremental(
    Mesh* mesh,
    const(int)[] indices,
    Vec3 pivotFallback,
    Vec3 axisFallback,
    int dragAxisIdx,
    float angleRad,
    const ref FalloffPacket dragFalloff,
    const ref Viewport vp,
    TransformTool.ClusterPivots clusterPivots,
    TransformTool.ClusterAxes clusterAxes,
    const ref SymmetryPacket dragSymmetry,
    bool[] toProcess)
{
    auto zKernel = g_perf.scope_(Cat.kernelApply);
    foreach (vi; indices) {
        Vec3 pivot = pivotFor(vi, clusterPivots, pivotFallback);
        Vec3 ax = (dragAxisIdx >= 0 && dragAxisIdx <= 2)
            ? axisFor(vi, dragAxisIdx, clusterAxes, clusterPivots, axisFallback)
            : axisFallback;
        float w = dragFalloff.enabled
            ? evaluateFalloff(dragFalloff, mesh.vertices[vi],
                              cast(int)vi, vp)
            : 1.0f;
        if (w == 0.0f) continue;
        mesh.vertices[vi] = rotateVecLerp(mesh.vertices[vi], pivot, ax, angleRad, w);
    }
    mirrorAndCount(mesh, dragSymmetry, toProcess, toProcess,
                   cast(long)indices.length, dragFalloff.enabled);
}

/// X→Y→Z Euler rotation from a captured origVertices snapshot.
/// Mirrors RotateTool.applyAbsoluteFromOrigCpuOnly.
///
/// Per-axis angle scaled by falloff weight evaluated at the ORIGINAL
/// vert position so the weight stays stable across the slider drag.
/// Verts outside `toProcessMask` are reset to their original
/// position (no rotation contribution) — mirrors the existing branch
/// `mesh.vertices[i] = origVertices[i]` in the source method.
void applyRotateFromOrig(
    Mesh* mesh,
    const(Vec3)[] origVerts,
    const(bool)[] toProcessMask,
    Vec3 pivotFallback,
    Vec3 axisXFallback,
    Vec3 axisYFallback,
    Vec3 axisZFallback,
    Vec3 angleAccum,
    const ref FalloffPacket dragFalloff,
    const ref Viewport vp,
    TransformTool.ClusterPivots clusterPivots,
    TransformTool.ClusterAxes clusterAxes,
    const ref SymmetryPacket dragSymmetry,
    bool[] symMask)
{
    if (origVerts.length != mesh.vertices.length) return;
    foreach (i; 0 .. mesh.vertices.length) {
        if (i >= toProcessMask.length || !toProcessMask[i]) {
            mesh.vertices[i] = origVerts[i];
            continue;
        }
        Vec3 pivot = pivotFor(i, clusterPivots, pivotFallback);
        Vec3 axX = axisFor(i, 0, clusterAxes, clusterPivots, axisXFallback);
        Vec3 axY = axisFor(i, 1, clusterAxes, clusterPivots, axisYFallback);
        Vec3 axZ = axisFor(i, 2, clusterAxes, clusterPivots, axisZFallback);
        Vec3 v = origVerts[i];
        float w = dragFalloff.enabled
            ? evaluateFalloff(dragFalloff, origVerts[i], cast(int)i, vp)
            : 1.0f;
        if (w == 0.0f) { mesh.vertices[i] = v; continue; }
        if (angleAccum.x != 0) v = rotateVecLerp(v, pivot, axX, angleAccum.x, w);
        if (angleAccum.y != 0) v = rotateVecLerp(v, pivot, axY, angleAccum.y, w);
        if (angleAccum.z != 0) v = rotateVecLerp(v, pivot, axZ, angleAccum.z, w);
        mesh.vertices[i] = v;
    }
    if (dragSymmetry.enabled
        && dragSymmetry.pairOf.length == mesh.vertices.length)
        applySymmetryMirror(mesh, dragSymmetry, symMask, symMask);
}

// ---------------------------------------------------------------
// Scale
// ---------------------------------------------------------------

/// Scale from a captured activation snapshot.
/// Mirrors ScaleTool.applyScaleFromActivationCpuOnly.
///
/// `weightVerts` is an optional per-vertex source for falloff
/// evaluation. When null/empty, the kernel evaluates the falloff at
/// `activationVerts[vi]` — fine when activation IS the baseline
/// (standalone ScaleTool drag). When non-empty, the kernel evaluates
/// against `weightVerts[vi]` instead — required when the scale stage
/// runs after a translate / rotate in `XfrmTransformTool`'s TRS
/// chain (then `activationVerts` holds POST-T/R positions, but per
/// `xfrm.transform` semantics the per-vert weight must be
/// snapshotted at the pre-chain BASELINE). Falloff packets like
/// Element (sphere around `pickedCenter`) attenuate by distance —
/// reading the weight at a post-translate position shrinks it as
/// the vert moves away from the sphere centre.
///
/// Each axis factor is blended toward 1.0 by the per-vertex falloff
/// weight evaluated at the ACTIVATION-time position so the weight
/// doesn't drift as the slider scales the vert through the field:
///   s_eff = 1 + (scaleAccum_a - 1) · w
void applyScaleFromActivation(
    Mesh* mesh,
    const(int)[] indices,
    const(Vec3)[] activationVerts,
    Vec3 pivotFallback,
    Vec3 axisXFallback,
    Vec3 axisYFallback,
    Vec3 axisZFallback,
    Vec3 scaleAccum,
    const ref FalloffPacket dragFalloff,
    const ref Viewport vp,
    TransformTool.ClusterPivots clusterPivots,
    TransformTool.ClusterAxes clusterAxes,
    const ref SymmetryPacket dragSymmetry,
    bool[] toProcess,
    const(Vec3)[] weightVerts = null)
{
    import math : scaleAlongBasis;
    import std.math : pow, fabs;
    auto zKernel = g_perf.scope_(Cat.kernelApply);
    if (activationVerts.length == 0) return;
    // Float exponent — Selection falloff publishes
    // `Steps · 0.955` (~1.91 for Steps=2), so the compound
    // pass needs a non-integer pow(). Skip the pow() when
    // very close to 1.0 to keep the common path fast.
    float passes = dragFalloff.compoundPasses > 0.0f
                   ? dragFalloff.compoundPasses : 1.0f;
    bool needCompound = fabs(passes - 1.0f) > 1e-4f;
    bool useWeightVerts = (weightVerts.length == activationVerts.length);
    foreach (vi; indices) {
        Vec3 pivot = pivotFor(vi, clusterPivots, pivotFallback);
        Vec3 ax = axisXFallback, ay = axisYFallback, az = axisZFallback;
        axesFor(vi, clusterAxes, clusterPivots, ax, ay, az);
        float w = dragFalloff.enabled
            ? evaluateFalloff(dragFalloff,
                              useWeightVerts ? weightVerts[vi]
                                             : activationVerts[vi],
                              cast(int)vi, vp)
            : 1.0f;
        float sx = 1.0f + (scaleAccum.x - 1.0f) * w;
        float sy = 1.0f + (scaleAccum.y - 1.0f) * w;
        float sz = 1.0f + (scaleAccum.z - 1.0f) * w;
        // D.7: Selection falloff (xfrm.flex) publishes
        // compoundPasses ≈ `steps · 0.955`. Scale is multiplicative,
        // so raising the per-axis factor to that exponent reproduces
        // the empirically observed saturation. Other falloff types
        // ship compoundPasses=1.0, leaving single-application unchanged.
        if (needCompound) {
            // pow() may produce NaN for negative bases — clamp.
            if (sx > 0) sx = pow(sx, passes);
            if (sy > 0) sy = pow(sy, passes);
            if (sz > 0) sz = pow(sz, passes);
        }
        mesh.vertices[vi] = scaleAlongBasis(activationVerts[vi], pivot,
                                             ax, ay, az, sx, sy, sz);
    }
    mirrorAndCount(mesh, dragSymmetry, toProcess, toProcess,
                   cast(long)indices.length, dragFalloff.enabled);
}

// ---------------------------------------------------------------
// Canonical single-matrix kernel (MS-1)
// ---------------------------------------------------------------
//
// The four kernels above re-express the decomposed transform state
// (separate T / R / S passes). MS-1 of the canonical-matrix plan
// (the unified transform-model plan, a private design doc) introduces a SINGLE pivot-relative
// matrix `M` that is applied per vertex, blended toward identity by the
// per-vertex falloff weight. This block adds that kernel WITHOUT touching
// any existing call path — it is additive and used (so far) only by
// tests/test_xform_matrix_kernel.d. MS-2 wires it into a measure-only
// shadow; MS-3 flips the real apply.
//
// Contract:
//   - `M` is a PIVOT-RELATIVE, origin-fixing matrix: it operates on the
//     offset (v - pivot), and the caller adds `pivot` back. Equivalently
//     `v' = pivot + blendToIdentity(M, w) · (v - pivot)`. Builders produce
//     such an M via translationMatrix(delta-in-basis),
//     matrixFromQuat / pivotRotationMatrix(origin, axis, angle) (translation
//     column zero ⇒ origin-fixing), or pivotScaleMatrixBasis(origin, ...).
//   - This kernel models ONLY `compoundPasses == 1`. The scale `pow(s, passes)`
//     path has no matrix expression (see plan F2); callers MUST skip the
//     matrix kernel when `fabs(dragFalloff.compoundPasses - 1) > 1e-4`.
//   - (C2 caveat) Decompose / PolarQuat assume `M = R · diag(s)` — i.e. scale in
//     M's OWN column directions. A rotated-basis stretch, a symmetric (shear)
//     stretch, or a reflection (negative-determinant M) is mis-decomposed by the
//     column-norm + quaternion extraction here; only MatrixLerp is exact for
//     such M. The live builders only ever produce R·diag(s), so this is a
//     documented contract, not a live-reachable bug.

/// Per-vertex falloff-weight blend of a pivot-relative transform matrix
/// toward identity. Three modes, matching the plan's options a / b / c:
///   - Decompose  (a): decompose M's 3×3 into rotation-quat + per-axis scale +
///                     translation; rotate by `w·angle` via AXIS-ANGLE (linear
///                     in angle, NOT slerp); lerp scale toward 1; lerp
///                     translation toward 0; recompose.
///   - MatrixLerp (b): entrywise `(1-w)·I + w·M`. Cheap, but mid-blend the
///                     3×3 is no longer orthogonal (shears) — this is exactly
///                     the current `rotateVecLerp` / `1+(s-1)w` blend the
///                     existing kernels use.
///   - PolarQuat  (c): decompose as in (a) but interpolate the rotation by
///                     SLERP(identity, R, w) (great-circle, radius-preserving)
///                     instead of the axis-angle linear blend. scale + translation
///                     lerp as in (a).
///
/// The precise a-vs-c distinction: BOTH decompose M into R + S + t and lerp the
/// scale (toward 1) and translation (toward 0) identically. They differ ONLY in
/// how the rotation is taken to a fraction `w` of itself —
///   (a) uses the rotation's axis-angle (θ_w = w·θ about the same axis), a LINEAR
///       interpolation of the angle, and
///   (c) uses slerp(identity, R, w), which for a single-axis rotation is the SAME
///       great circle and therefore numerically equal to (a); they diverge only
///       for rotations whose extraction/axis handling differs under float, or
///       when chained with non-uniform scale that makes the decomposition
///       axis ambiguous. (b) is distinct from both: it never re-orthogonalizes.
///
/// `w == 1` returns `M` exactly (all modes); `w == 0` returns identity exactly
/// (all modes).
float[16] blendToIdentity(float[16] M, float w, BlendMode mode)
    @safe pure nothrow @nogc
{
    if (w >= 1.0f) return M;
    if (w <= 0.0f) return identityMatrix;

    final switch (mode) {
    case BlendMode.MatrixLerp:
        float[16] r;
        foreach (i; 0 .. 16)
            r[i] = (1.0f - w) * identityMatrix[i] + w * M[i];
        return r;

    case BlendMode.Decompose:
    case BlendMode.PolarQuat:
        // Decompose the 3×3 into per-axis scale (column norms) + rotation; the
        // 4th column is the translation. Lerp scale → 1 and translation → 0;
        // take the rotation to fraction w.
        import std.math : sqrt;
        float sx = sqrt(M[0]*M[0] + M[1]*M[1] + M[2]*M[2]);
        float sy = sqrt(M[4]*M[4] + M[5]*M[5] + M[6]*M[6]);
        float sz = sqrt(M[8]*M[8] + M[9]*M[9] + M[10]*M[10]);
        float sxW = 1.0f + (sx - 1.0f) * w;
        float syW = 1.0f + (sy - 1.0f) * w;
        float szW = 1.0f + (sz - 1.0f) * w;

        Quat R = quatFromMatrix(M);
        Quat Rw;
        if (mode == BlendMode.PolarQuat) {
            // (c) slerp(identity, R, w): great-circle interpolation of the
            // rotation, radius-preserving.
            Rw = slerp(Quat.identity(), R, w);
        } else {
            // (a) axis-angle LINEAR: extract R's axis-angle (θ, axis) and rebuild
            // the rotation at the LINEARLY-scaled angle w·θ about the same axis.
            // This is genuinely distinct from (c)'s slerp once M carries scale or
            // shear (the decomposition's residual rotation differs); for a SINGLE
            // pure rotation both trace the same great circle and coincide.
            import std.math : acos, sin, cos;
            // q = (w_q, x, y, z) with w_q = cos(θ/2); |q| == 1 (quatFromMatrix
            // normalizes). Use |w_q| so we always extract the shorter-arc angle,
            // matching slerp's shorter-arc choice.
            float qw = R.w < 0.0f ? -R.w : R.w;   // |cos(θ/2)|
            float qx = R.w < 0.0f ? -R.x : R.x;   // flip the vector part with it
            float qy = R.w < 0.0f ? -R.y : R.y;   // so the axis sign stays consistent
            float qz = R.w < 0.0f ? -R.z : R.z;
            if (qw > 1.0f) qw = 1.0f;
            float half = acos(qw);                // θ/2 ∈ [0, π/2]
            float vlen = sqrt(qx*qx + qy*qy + qz*qz);  // = sin(θ/2)
            if (vlen < 1e-7f) {
                // θ ≈ 0: degenerate axis → identity rotation at any w.
                Rw = Quat.identity();
            } else {
                float halfW = half * w;           // (θ·w)/2: linear in the angle
                float s = sin(halfW) / vlen;      // re-spread sin onto the unit axis
                // Assign by name so we don't depend on the positional field order.
                Rw.x = qx * s; Rw.y = qy * s; Rw.z = qz * s; Rw.w = cos(halfW);
            }
        }
        float[16] rot = matrixFromQuat(Rw);

        // Recompose: rotation · diag(scale_w), then weighted translation column.
        float[16] r;
        // Columns 0..2 = rot columns scaled by per-axis weighted scale.
        r[0] = rot[0]*sxW; r[1] = rot[1]*sxW; r[2]  = rot[2]*sxW;  r[3]  = 0;
        r[4] = rot[4]*syW; r[5] = rot[5]*syW; r[6]  = rot[6]*syW;  r[7]  = 0;
        r[8] = rot[8]*szW; r[9] = rot[9]*szW; r[10] = rot[10]*szW; r[11] = 0;
        r[12] = M[12] * w; r[13] = M[13] * w; r[14] = M[14] * w;   r[15] = 1;
        return r;
    }
}

/// Blend modes for `blendToIdentity` — the plan's options a / b / c.
enum BlendMode { Decompose, MatrixLerp, PolarQuat }

/// Pure single-pass matrix apply (MS-1). Reproduces ONE pass of `applyTRS`
/// expressed as a single pivot-relative matrix blended toward identity per
/// vertex by the falloff weight. No symmetry mirror is run by callers via the
/// SAME `applySymmetryMirror` at the end (sharing the live mirror path).
///
/// Per vertex `vi`:
///   pivot = clusterPivots(vi) when a cluster is active, else `pivotFallback`.
///   Mv    = (clusterM[cid] when the vert's cluster is active and clusterM is
///            non-null) else the global `M`.
///   w     = evaluateFalloff(dragFalloff, weightVerts ? weightVerts[vi]
///                                                     : baseline[i], vi, vp)
///           (1.0 when falloff disabled; verts with w==0 are left untouched).
///           NB: `baseline` is ordinal-indexed (baseline[i] ↔ indices[i]) but
///           `weightVerts` is vertex-id-indexed + mesh-length, matching the live
///           scale kernel so MS-2 can share its buffer. See the body contract.
///   mesh.vertices[vi] = pivot + applyAffine(blendToIdentity(Mv, w, mode),
///                                            baseline[vi] - pivot).
///
/// Contract: models ONLY `compoundPasses == 1` (callers skip otherwise, F2).
/// `M` / `clusterM[cid]` must be PIVOT-RELATIVE (origin-fixing) so the
/// `pivot +  … · (baseline - pivot)` framing holds; see `blendToIdentity`.
void applyXformMatrix(
    Mesh* mesh,
    const(int)[] indices,
    const(Vec3)[] baseline,
    Vec3 pivotFallback,
    float[16] M,
    Vec3 anchor,
    BlendMode mode,
    const ref FalloffPacket dragFalloff,
    const ref Viewport vp,
    TransformTool.ClusterPivots clusterPivots,
    TransformTool.ClusterAxes clusterAxes,
    float[16][] clusterM,
    const ref SymmetryPacket dragSymmetry,
    bool[] toProcess,
    const(Vec3)[] weightVerts = null)
{
    // Array-layout contract (locked by test (v), the non-identity-indices case):
    //   - `baseline` is ORDINAL-parallel to `indices`: baseline[i] is the pre-edit
    //     position of the vertex `indices[i]`. (It only needs to cover the moving
    //     set, so it is sized `indices.length`.)
    //   - `weightVerts`, when supplied, is VERTEX-ID-indexed and mesh-length, to
    //     MATCH the live scale kernel (applyScaleFromActivation reads
    //     weightVerts[vi]). MS-2 can therefore feed the SAME weightVerts buffer
    //     the live scale path uses with no re-indexing. Empty / wrong-length ⇒
    //     fall back to weighting at `baseline[i]`.
    // The asymmetry (baseline ordinal, weightVerts vid) is deliberate: baseline
    // is a compact per-move-set snapshot, weightVerts mirrors a mesh-length live
    // buffer.
    bool useWeightVerts = (weightVerts.length == mesh.vertices.length);
    foreach (i, vi; indices) {
        if (vi >= mesh.vertices.length) continue;
        if (i >= baseline.length) continue;
        Vec3 base  = baseline[i];
        Vec3 pivot = pivotFor(vi, clusterPivots, pivotFallback);

        // Per-cluster matrix override (ACEN.Local). When the vert belongs to
        // an active cluster and a per-cluster matrix array is supplied, use
        // that cluster's matrix; otherwise the global M.
        float[16] Mv = M;
        if (clusterM !is null && clusterPivots.active
            && vi < clusterPivots.clusterOf.length) {
            int cid = clusterPivots.clusterOf[vi];
            if (cid >= 0 && cid < cast(int)clusterM.length)
                Mv = clusterM[cid];
        }

        float w = dragFalloff.enabled
            ? evaluateFalloff(dragFalloff,
                              useWeightVerts ? weightVerts[vi] : base,
                              cast(int)vi, vp)
            : 1.0f;
        if (w == 0.0f) continue;

        float[16] Mw = blendToIdentity(Mv, w, mode);
        // Precision-stable apply: re-center on `anchor` (near the geometry)
        // so `base − anchor` is a small-magnitude difference and avoids the
        // large-minus-large float32 cancellation `base − pivot` suffers at a
        // far pivot. `off = M_lin*(anchor−pivot) + pivot − anchor + t_fold`
        // is computed in double once per (Mw, pivot, anchor); under varying
        // falloff weight Mw is per-vertex so off is per-vertex — CPU-only,
        // never baked into the GPU matrix. The GPU fast-path (no-falloff) uses
        // wrapAboutPivotStable built from the same anchor → matrix-INPUT
        // consistency (not bit-identical apply — scalar CPU vs mat4 GPU).
        {
            double m00 = Mw[0], m10 = Mw[1], m20 = Mw[2];
            double m01 = Mw[4], m11 = Mw[5], m21 = Mw[6];
            double m02 = Mw[8], m12 = Mw[9], m22 = Mw[10];
            double tf0 = Mw[12], tf1 = Mw[13], tf2 = Mw[14];
            // c - pivot (double, small when anchor is near geometry)
            double cpx = cast(double)anchor.x - cast(double)pivot.x;
            double cpy = cast(double)anchor.y - cast(double)pivot.y;
            double cpz = cast(double)anchor.z - cast(double)pivot.z;
            // off = M_lin*(c-pivot) + (pivot-c) + t_fold
            //     = M_lin*(c-pivot) - (c-pivot) + t_fold
            double off0 = m00*cpx + m01*cpy + m02*cpz - cpx + tf0;
            double off1 = m10*cpx + m11*cpy + m12*cpz - cpy + tf1;
            double off2 = m20*cpx + m21*cpy + m22*cpz - cpz + tf2;
            // d = base - anchor (exact, both geometry-scale)
            double dx = cast(double)base.x - cast(double)anchor.x;
            double dy = cast(double)base.y - cast(double)anchor.y;
            double dz = cast(double)base.z - cast(double)anchor.z;
            // v' = anchor + M_lin*d + off
            mesh.vertices[vi] = Vec3(
                cast(float)(cast(double)anchor.x + m00*dx + m01*dy + m02*dz + off0),
                cast(float)(cast(double)anchor.y + m10*dx + m11*dy + m12*dz + off1),
                cast(float)(cast(double)anchor.z + m20*dx + m21*dy + m22*dz + off2));
        }
    }
    // NOTE (doc/symmetry_deform_plan.md Stage 2): the GLOBAL-fold symmetry
    // mirror tail that used to live here was DELETED. The live unified fold
    // (XfrmTransformTool.applyFold) now owns the mirror as an explicit second
    // pass (Pass B: M'=Slin·M·Slin about S·pivot for distance falloffs,
    // position-copy for membership falloffs) and calls this kernel with a
    // DISABLED `dragSymmetry`, so no mirror runs in-kernel. The fold therefore
    // carries exactly ONE symmetry model. The dormant legacy pow-scale chain +
    // per-cluster path retain their own position-copy mirror at their call
    // sites (Stage 2b / Stage 4 scope). `dragSymmetry` / `toProcess` stay in
    // the signature: callers still pass them, and the kernel ignores symmetry.
}

// ─────────────────────────────────────────────────────────────────────────
// Off-handle PLANE scale — which axis each screen component drives.
//
// A press that misses every handle, in an action-centre mode that lets the
// pivot relocate, scales in a PLANE rather than along one axis: the drag's
// horizontal component drives one basis axis, its vertical component drives
// another, and the third is left at exactly 1. That much is measured — the map
// is rank 2, and a reference drag deliberately aimed exactly along one axis's
// screen projection left THAT axis untouched and scaled the other two, so the
// assignment cannot be a function of the drag direction.
//
// ── THE ELECTION IS A READ, NOT A FIT ────────────────────────────────────
//
// An earlier version of this function asked "which world axis is the most
// screen-HORIZONTAL?" and gave that axis to the horizontal drag component.
// That rule was chosen by scoring three candidates against captured legs; it
// won 6 of 7 cameras and was shipped. It is the wrong rule, and the reference
// was subsequently read rather than scored — statically for the structure, and
// then on a recorded execution of the gesture itself.
//
// The reference never asks which axis is most screen-horizontal. It asks
// **which axis to LEAVE ALONE**, answers with the **eye ray at the action
// centre**, and hands the two survivors to the two screen components by a
// **fixed permutation**:
//
//     press:  E        = the unit eye ray at the action centre C
//             A_k      = basis axis k = column k of the TOOL AXIS FRAME
//                        (ours: the AXIS stage's packet, per action-centre
//                        mode — NOT the world axes; see below)
//             excluded = argmax_k |A_k . E|      -- held for the whole drag
//
//     drag:   excluded 0 (X):  horizontal -> Z,  vertical -> Y   (no compare)
//             excluded 2 (Z):  horizontal -> X,  vertical -> Y   (no compare)
//             excluded 1 (Y):  |A0.R| > |A2.R| ? (h->X, v->Z)
//                                              : (h->Z, v->X)
//
// World Y takes the vertical component in two of the three branches,
// unconditionally. A screen projection is compared in EXACTLY ONE branch — the
// one where Y is itself the axis being dropped, i.e. the only case where both
// survivors are horizontal-ish and a comparison is actually needed.
//
// Evidence, term by term:
//
//  * `E` — recorded on five presses, `|E| == 1.000000` each time and 15.6 deg
//    off the view direction on every one, consistently in the direction of the
//    press offset. It is the eye ray AT THE ACTION CENTRE, not the camera
//    forward axis. That 15.6 deg is the whole finding, because it is enough to
//    move the argmax: at the reference-comparison camera the view direction's
//    argmax is z by 0.359544 while `E`'s is x by 0.013749, and the reference
//    elected x.
//  * the permutation — read off the write sites, and confirmed live on the two
//    branches that executed (`excluded 0` on four presses, `excluded 2` on one).
//  * the tie rule — 22 instructions, no epsilon, strict `>` at index 0 and at
//    index 1's second test. An exact tie goes to the HIGHER index. Read, not
//    fitted; never reached on the recorded corpus.
//  * `A_k` — columns of the tool axis frame. A LATER READ CORRECTED THIS TERM,
//    and the correction is the reason this function takes the axes as
//    parameters instead of assuming them. The first read recorded the matrix
//    as exactly identity (`max|dev| = 0.000e+00`) on all five presses and this
//    docstring generalised that to "-> the world axes". It was five readings
//    of ONE action-centre mode. A second read put six presses through five
//    modes in one execution and found the mode changes TWO inputs, not one:
//    the centre `C` **and** the frame `A_k`. Three of the four pinned modes
//    installed a NON-IDENTITY frame.
//
//    `A_k` IS ALSO SUBJECT-DEPENDENT, NOT JUST MODE-DEPENDENT. A third read ran
//    the same three modes on a DIFFERENT subject and got a different frame: a
//    bare grid with nothing selected gave a 45-degree in-plane pair, while a
//    single selected face gave an edge-aligned `(+X, -Z, +Y)`. Same modes, same
//    camera, different frames — so no constant is the answer, and none is
//    written down here. The frame's own writer has since been read: the engine
//    copies it out of the AXIS packet's matrix field, and forces the identity
//    when that packet names a single axis index (which is why the single-axis
//    modes measure as the identity). It comes from the axis slot and nowhere
//    else.
//
//    So `A_k` must be READ from the axis stage, never assumed. Ours comes from
//    exactly there (`ScaleTool.pickPlaneAxes` -> `currentBasis` ->
//    `AxisPacket`), and the reference pairs an axis tool with each
//    action-centre tool in its shipped presets just as our `actr.*` table pairs
//    an AXIS mode with each ACEN mode — the same two-input shape. If you are
//    ever tempted to "simplify" the call site to world axes because this
//    comment used to say the matrix was the identity: that is the bug the
//    correction exists to prevent.
//
//    WHAT OUR FRAME IS NOT. We consume ours; its CONTENT is not the
//    reference's. On the corpus rig the reference's `select`/`local`/`border`
//    frame is the selected face's own (normal in slot 2), while our AXIS
//    stage's selection basis comes out as the world axes for an axis-aligned
//    face. Both then scale world X on that rig's horizontal drag, by different
//    routes — ours elects index 2, the reference elects index 1 and reaches it
//    through the comparison — and the two agree on the horizontal survivor but
//    NOT on the vertical one. Closing that is a question for the axis stage's
//    `select` basis, not for this function, and the read that measured the
//    reference's frame explicitly does not name the rule that fills it.
//
// The consequence for the retracted rule is not that it lost a close call. At
// the reference-comparison camera the two leading screen projections differ by
// 0.00026 — but that is the margin of a comparison THE REFERENCE DOES NOT MAKE
// there. The quantity it does compare has a margin 53x larger and on the other
// side. The unittest below carries all five recorded presses and scores the
// retracted rule on them, in the reference's OWN basis: 1 of 5.
//
// ── WHAT THE ELECTION DOES *NOT* DEPEND ON, AND WHY THAT MATTERS HERE ────
//
// `E` is the ray from the eye through the action centre. It does not read the
// view's up vector, so it is **ROLL-INVARIANT**. That property is
// unconditional and is why this rule ports at all.
//
// The sentence that used to sit here said our screen "can never carry a roll"
// while the reference's does (6.4 to 27.5 deg across the measured cameras,
// sign-changing, and real rather than a recording artefact). THAT IS NO LONGER
// TRUE: `View` carries a bank (`view.d`, the "Camera BANK" section), so a
// perspective viewport is no longer forced to `lookAt(eye, focus, Vec3(0,1,0))`
// and screen-right is no longer pinned to the world XZ plane. Default is still
// a level horizon, so nothing here moves unless a camera is deliberately banked.
//
// The previous rule read a screen basis and was refused as structurally
// unportable. That refusal's PREMISE is now gone. It is not re-opened here:
// the refusal was about a DIFFERENT rule, and this one is elected on `E`.
//
// It does not apply to this one. Two of the three branches read no basis at
// all, so on those the port is exact regardless of our camera model. The
// refusal survives on the `excluded == 1` branch, whose single comparison is
// the one place a bank could change the answer — and THAT BRANCH IS NOT THE
// RARE ONE. See below; the scoping sentence that used to sit here was written
// on a sample that could not see it.
//
// `excluded == 1` IS THE MAJORITY PATH, NOT AN EDGE CASE. Two traces put 11
// presses through this election and the branch fired 0 times, so an earlier
// version of this comment called it "the unconfirmed leg", implemented but
// unverified. A third read then ran the REFERENCE-COMPARISON CORPUS'S OWN RIG
// at its own camera — a unit cube with its +Y face selected — and the branch
// fired 15 times: it is the branch `select`, `local` and `border` all take
// there. Those three modes install a frame with the face normal in slot 2
// (`A = (+X, -Z, +Y)` on that rig), which puts the eye ray's argmax on index 1
// and routes the election straight into the comparison. The clause was read at
// its own site on all 15 hits, identical every time:
//
//     |A0 . N0| = 0.817569  >  |A2 . N0| = 0.186885   ->  h -> A0, v -> A2
//
// which is the first arm implemented below.
//
// WHERE THE BANK ENTERS, PLAINLY. This branch is on a LIVE path, not a dead
// one: three of the shipped action-centre modes reach a comparison against a
// screen-right vector that the reference's view banks (11.778 deg at the corpus
// camera). The exposure has a precise shape, and it is worth stating rather
// than waving at.
//
// The branch is only entered when index 1 is elected, which happens when the
// eye ray lies most along `A1`. On the rigs measured so far that is a frame
// with the face normal in slot 2 — i.e. `A2` is (near) world Y. AT A LEVEL
// HORIZON — still the default — `screenRight` is perpendicular to +Y, so
// `|A2 . screenRight|` is ~0 and the comparison degenerates to "is
// `|A0 . screenRight|` greater than nothing": we take the first arm essentially
// always. The reference takes the first arm only while its bank keeps that same
// quantity small: at the corpus camera its numbers are 0.817569 against
// 0.186885, the first arm, agreeing with us; a level camera gives 0.8756
// against 0.0000, the same arm by a wider margin.
//
// WHAT CHANGED, AND WHAT DID NOT. The degenerate operand was a property of the
// camera model, not of this rule, and the camera model no longer imposes it: at
// the reference's own recorded bank our basis reproduces BOTH of its operands
// (a `view.d` unittest pins 0.817569 / 0.186885 against the trace's
// 0.817568576 / 0.186884795). So the cell is no longer unreachable for us to
// test, and the clause is no longer being ported against a structurally zero
// quantity.
//
// The ELECTION IS DELIBERATELY UNCHANGED, and the reason is measured rather
// than assumed: at the corpus camera 0.817569 > 0.186885 picks the same arm the
// degenerate 0.817569 > 0 picked, so every corpus row keeps its outcome. The
// flip point at that camera is a bank of 0.66801 rad = 38.27 deg; the reference
// view carries 11.78 deg. A bank-capable camera by itself therefore moves no
// scale-parity row. Divergence still needs a cell whose bank wins the
// comparison outright, and none has been recorded.
//
// `screenRight` is the view's own right direction. The reference obtains it by
// unprojecting two pixels 0.01 px apart at the action centre; for a symmetric
// frustum that difference IS the view matrix's right row at any depth, which is
// what we pass, so the construction matches — and now matches at a non-zero
// bank too, not only at a level one.
//
// Returns false only when the eye ray is degenerate (the action centre sitting
// exactly on the eye). The reference has no failure path here.
bool pickScalePlaneAxes(Vec3 eyeVec, Vec3 screenRight,
                        Vec3 axisX, Vec3 axisY, Vec3 axisZ,
                        out int hIdx, out int vIdx,
                        out int excludedIdx, out float electMargin)
{
    import std.math : abs, sqrt;
    hIdx = vIdx = excludedIdx = -1;
    electMargin = 0.0f;

    immutable float el = sqrt(eyeVec.x * eyeVec.x + eyeVec.y * eyeVec.y
                            + eyeVec.z * eyeVec.z);
    if (!(el > 1e-6f)) return false;
    immutable Vec3 e = Vec3(eyeVec.x / el, eyeVec.y / el, eyeVec.z / el);

    Vec3[3] ax = [axisX, axisY, axisZ];
    float[3] d = [dot(ax[0], e), dot(ax[1], e), dot(ax[2], e)];

    // The elector, transcribed. Strict `>` at index 0 and at index 1's second
    // test, `>=` at index 1's first: an exact tie goes to the HIGHER index,
    // with no tolerance anywhere.
    immutable float a0 = abs(d[0]), a1 = abs(d[1]), a2 = abs(d[2]);
    if      (a0 >  a1 && a0 >  a2) excludedIdx = 0;
    else if (a1 >= a0 && a1 >  a2) excludedIdx = 1;
    else                           excludedIdx = 2;

    // How far the excluded axis beat its nearest rival, on the quantity the
    // reference actually compares. Reported so a caller (and the tests) can
    // say when the election was decided by a margin too small to trust.
    {
        float top = -1.0f, second = -1.0f;
        foreach (i; 0 .. 3) {
            immutable float v = abs(d[i]);
            if (v > top) { second = top; top = v; }
            else if (v > second) second = v;
        }
        electMargin = top - second;
    }

    final switch (excludedIdx) {
        case 0: hIdx = 2; vIdx = 1; break;   // X out: h->Z, v->Y
        case 2: hIdx = 0; vIdx = 1; break;   // Z out: h->X, v->Y
        case 1:                              // index 1 out: THE COMMON PATH
            // The only comparison in the whole election, and the only place a
            // camera bank can move the answer. Read at its own site on 15 hits
            // of the reference-comparison corpus's own rig, where it is the
            // branch three of the shipped action-centre modes take. Strict `>`;
            // a tie takes the second arm.
            if (abs(dot(ax[0], screenRight)) > abs(dot(ax[2], screenRight))) {
                hIdx = 0; vIdx = 2;
            } else {
                hIdx = 2; vIdx = 0;
            }
            break;
    }
    return true;
}

/// Gain on one of the plane's two axes for an accumulated drag component.
/// Linear in the pixels and passing through zero — a long enough drag the other
/// way MIRRORS rather than clamping.
///
/// `sign` carries the SCREEN CONVENTION, not the elected axis's orientation.
/// The reference accumulates `cur.x - last.x` for the horizontal and
/// `last.y - cur.y` for the vertical, and writes both straight into the elected
/// attributes with no per-axis sign at all: an elected axis whose screen
/// projection points LEFT still grows on a rightward drag. So the caller passes
/// `+1` for the horizontal and `-1` for the vertical (our deltas are y-down),
/// and nothing here consults the geometry.
float screenPlaneScaleGain(float pixels, float sign, float pixelsPerUnit) {
    return 1.0f + pixels * sign / pixelsPerUnit;
}

unittest {
    import std.math : abs, sqrt;

    // ── THE FIVE RECORDED PRESSES ─────────────────────────────────────────
    //
    // `eye` and `screenRight` are the reference's OWN values at the instant of
    // the press, read off a recorded execution — not reconstructed from a
    // camera, not fitted. `excluded` / `h` / `v` are what the reference then
    // did, read at its write sites. Press 0 and 1 are two presses that landed
    // on identical inputs and are kept as two rows because that is what was
    // recorded.
    //
    // Press 0/1 sit on the reference-comparison camera — the one the corpus
    // uses and the one where every miss of the retracted rule lives. There the
    // view direction's argmax is z and the EYE RAY's is x; the reference
    // elected x, gave the horizontal to Z, and the corpus recorded z scaling.
    //
    // If a row here has to change, the recording is what says so. Re-read it;
    // do not edit a row to make a rule pass.
    static struct Press {
        string name;
        Vec3   eye;           // E,  the unit eye ray at the action centre
        Vec3   screenRight;   // N0, the view's own right (banked)
        Vec3   screenDown;    // N1, the view's own down  (banked)
        int    excluded;      // what the reference left alone
        int    h, v;          // which axis each screen component drove
    }
    immutable Press[5] presses = [
        Press("press 0 (corpus camera)",
              Vec3(+0.632126f, -0.466933f, -0.618377f),
              Vec3(+0.817569f, -0.186885f, +0.544661f),
              Vec3(-0.368870f, -0.896293f, +0.246158f), 0, 2, 1),
        Press("press 1 (corpus camera)",
              Vec3(+0.632126f, -0.466933f, -0.618377f),
              Vec3(+0.817569f, -0.186885f, +0.544661f),
              Vec3(-0.368870f, -0.896293f, +0.246158f), 0, 2, 1),
        Press("press 2",
              Vec3(+0.912497f, -0.401305f, +0.079394f),
              Vec3(+0.269283f, +0.148164f, +0.951596f),
              Vec3(-0.371322f, -0.895723f, +0.244541f), 0, 2, 1),
        Press("press 3",
              Vec3(+0.656215f, -0.116679f, +0.745499f),
              Vec3(-0.434452f, +0.398292f, +0.807846f),
              Vec3(-0.372142f, -0.896155f, +0.241696f), 2, 0, 1),
        Press("press 4",
              Vec3(+0.748319f, +0.330960f, +0.574877f),
              Vec3(-0.435557f, +0.395600f, +0.808573f),
              Vec3(+0.086892f, -0.875582f, +0.475191f), 0, 2, 1),
    ];

    // The retracted rule, kept executable so its retraction is a MEASUREMENT
    // rather than a sentence: "the axis whose unit screen projection is the
    // most horizontal takes the horizontal component". This is what shipped
    // for two commits, scored 6 of 7 cameras on a camera-only corpus, and is
    // what the read replaced. It runs here on the reference's OWN recorded
    // basis — the most favourable input it could be given — and it is the
    // per-axis NORMALISATION that decides three of its four misses, so the
    // body is reproduced faithfully rather than shortened to an argmax.
    static int retractedHorizontalAxis(Vec3 camRight, Vec3 camUp,
                                       out float nearTieMargin) {
        Vec3[3] ax = [Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1)];
        float[3] sx;
        foreach (i, a; ax) {
            immutable float px =  dot(camRight, a);
            immutable float py = -dot(camUp,    a);
            immutable float m  = sqrt(px * px + py * py);
            sx[i] = px / m;
        }
        int best = 0;
        foreach (i; 1 .. 3) if (abs(sx[i]) > abs(sx[best])) best = cast(int)i;
        float top = -1.0f, second = -1.0f;
        foreach (i; 0 .. 3) {
            immutable float v = abs(sx[i]);
            if (v > top) { second = top; top = v; }
            else if (v > second) second = v;
        }
        nearTieMargin = top - second;
        return best;
    }

    int reproduced, retractedHits;
    foreach (p; presses) {
        int h, v, ex; float margin;
        assert(pickScalePlaneAxes(p.eye, p.screenRight,
                                  Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                  h, v, ex, margin),
               "the election must resolve on " ~ p.name);
        assert(ex == p.excluded,
               "the excluded axis on " ~ p.name ~ " does not match the "
               ~ "recording — re-read the trace, do not edit this row");
        assert(h == p.h && v == p.v,
               "the screen-component assignment on " ~ p.name ~ " does not "
               ~ "match the recording");
        reproduced++;
        // The reference never dropped world Y on any recorded press, so the
        // one branch that reads a basis never ran. That is the unconfirmed leg.
        assert(ex != 1, "no recorded press elected Y — see the unconfirmed leg");

        // Score the retracted rule on the same press, in the reference's own
        // basis (both rows recorded, so nothing here is reconstructed).
        float unused;
        if (retractedHorizontalAxis(p.screenRight, p.screenDown, unused) == p.h)
            retractedHits++;
    }
    assert(reproduced == 5,
           "the read rule reproduces the reference on 5 of 5 recorded presses");
    assert(retractedHits == 1,
           "the retracted screen-horizontal rule reproduces 1 of the 5 recorded "
           ~ "presses, in the reference's OWN basis. That number replaces "
           ~ "'6 of 7 cameras', which was a per-CAMERA score of a camera-only "
           ~ "rule against a reference whose election is per-PRESS");

    // The 0.00026 the campaign spent three phases on, located exactly: it is
    // the retracted rule's own margin at the corpus camera. The reference does
    // not make that comparison there, so the near-tie was never a tie in
    // anything the reference computes.
    {
        float m; retractedHorizontalAxis(presses[0].screenRight,
                                         presses[0].screenDown, m);
        assert(m < 0.0003f,
               "the retracted rule reads the corpus camera as a 0.00026 "
               ~ "near-tie — that is where the campaign's famous number "
               ~ "lived, and it belongs to a comparison the reference skips");
    }

    // The margin at the corpus camera, on the quantity the reference compares.
    // 0.013749, against the 0.00026 the campaign spent three phases on — which
    // was the margin of a comparison the reference does not make there.
    {
        int h, v, ex; float margin;
        pickScalePlaneAxes(presses[0].eye, presses[0].screenRight,
                           Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                           h, v, ex, margin);
        assert(abs(margin - 0.013749f) < 1e-5f,
               "the corpus camera's election margin is 0.013749 on the eye "
               ~ "ray — 53x the 0.00026 near-tie it was mistaken for");
    }

    // ── ROLL-INVARIANCE ───────────────────────────────────────────────────
    //
    // The reason the basis refusal does NOT carry over to this rule. Roll the
    // screen-right arbitrarily about the eye ray: the two branches that make no
    // comparison must not move. This is what makes our unbanked viewport
    // irrelevant to them.
    foreach (p; presses) {
        Vec3 rolled = cross(p.eye, p.screenRight);   // 90 deg of roll
        immutable float rl = sqrt(dot(rolled, rolled));
        rolled = Vec3(rolled.x / rl, rolled.y / rl, rolled.z / rl);
        int h0, v0, e0, h1, v1, e1; float m0, m1;
        pickScalePlaneAxes(p.eye, p.screenRight, Vec3(1,0,0), Vec3(0,1,0),
                           Vec3(0,0,1), h0, v0, e0, m0);
        pickScalePlaneAxes(p.eye, rolled, Vec3(1,0,0), Vec3(0,1,0),
                           Vec3(0,0,1), h1, v1, e1, m1);
        assert(e0 == e1 && h0 == h1 && v0 == v1 && m0 == m1,
               "a roll must not move the election on " ~ p.name);
    }

    // ── THE TIE RULE ──────────────────────────────────────────────────────
    //
    // Strict `>` at index 0 and at index 1's second test, no epsilon: an exact
    // tie goes to the HIGHER index. Read off 22 instructions; never reached on
    // the recorded corpus, so this is the decode's own claim and nothing else.
    {
        static int electedFor(Vec3 e) {
            int h, v, ex; float m;
            pickScalePlaneAxes(e, Vec3(1,0,0), Vec3(1,0,0), Vec3(0,1,0),
                               Vec3(0,0,1), h, v, ex, m);
            return ex;
        }
        assert(electedFor(Vec3(1, 1, 0)) == 1, "x==y ties to y");
        assert(electedFor(Vec3(0, 1, 1)) == 2, "y==z ties to z");
        assert(electedFor(Vec3(1, 0, 1)) == 2, "x==z ties to z");
        assert(electedFor(Vec3(1, 1, 1)) == 2, "a three-way tie goes to z");
        // Signs are irrelevant — the elector compares magnitudes.
        assert(electedFor(Vec3(-1, 1, 0)) == 1, "the elector is sign-blind");
        assert(electedFor(Vec3(0.9f, 0, -1)) == 2, "the largest magnitude wins");
    }

    // ── THE UNCONFIRMED LEG (excluded == 1) ───────────────────────────────
    //
    // Decoded statically, executed zero times on the recording. Both arms are
    // asserted so a rule change is visible, but neither is confirmed against
    // the reference and neither should be cited as measured.
    {
        immutable Vec3 nearTop = Vec3(0.1f, 0.99f, 0.05f);   // |E_y| dominates
        int h, v, ex; float m;
        // Arm 1: X projects more strongly onto screen-right than Z does.
        assert(pickScalePlaneAxes(nearTop, Vec3(0.9f, 0.0f, 0.1f),
                                  Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                  h, v, ex, m));
        assert(ex == 1, "a near-top eye ray must drop world Y");
        assert(h == 0 && v == 2, "|X.R| > |Z.R| gives h=X, v=Z");
        // Arm 2: Z wins the same comparison.
        assert(pickScalePlaneAxes(nearTop, Vec3(0.1f, 0.0f, 0.9f),
                                  Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                  h, v, ex, m));
        assert(ex == 1 && h == 2 && v == 0, "|Z.R| > |X.R| gives h=Z, v=X");
        // Arm 2 again by the tie: the comparison is strict, so an exact tie
        // takes the second arm.
        assert(pickScalePlaneAxes(nearTop, Vec3(0.5f, 0.0f, -0.5f),
                                  Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                  h, v, ex, m));
        assert(ex == 1 && h == 2 && v == 0,
               "an exact tie in the Y-out comparison takes the second arm");
    }

    // ── DEGENERACY ────────────────────────────────────────────────────────
    {
        int h, v, ex; float m;
        assert(!pickScalePlaneAxes(Vec3(0, 0, 0), Vec3(1, 0, 0),
                                   Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                                   h, v, ex, m),
               "an action centre sitting on the eye has no eye ray");
    }

    // ── THE FACTOR LAW — unchanged, and measured ──────────────────────────
    //
    // 200 px on a component gives 1.64 / 0.36; the recording's own writes were
    // 1.10 1.14 1.20 1.28 1.32 on +100 px horizontal and 0.90 0.86 0.80 0.72
    // 0.68 on +100 px down, i.e. 1 +/- px/312.5 exactly.
    assert(abs(screenPlaneScaleGain( 200.0f,  1.0f, 312.5f) - 1.64f) < 1e-6f);
    assert(abs(screenPlaneScaleGain( 200.0f, -1.0f, 312.5f) - 0.36f) < 1e-6f);
    assert(abs(screenPlaneScaleGain(-200.0f, -1.0f, 312.5f) - 1.64f) < 1e-6f);
    assert(abs(screenPlaneScaleGain( 100.0f,  1.0f, 312.5f) - 1.32f) < 1e-6f);
    assert(abs(screenPlaneScaleGain( 100.0f, -1.0f, 312.5f) - 0.68f) < 1e-6f);
    // It passes through zero and goes negative rather than clamping.
    assert(screenPlaneScaleGain(-400.0f, 1.0f, 312.5f) < 0.0f);
}
