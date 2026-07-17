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

import math    : Vec3, Viewport;
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
