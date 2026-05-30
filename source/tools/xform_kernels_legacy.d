module tools.xform_kernels_legacy;

// FROZEN per-component transform kernels — a VERBATIM copy of the four live
// kernels in `tools.xform_kernels` as they stood at MS-3 sub-task 1 of the
// canonical-matrix applyTRS refactor (doc/modo_transform_model_plan.md).
//
// Why this file exists: the measure-only shadow (`tools.xfrm_shadow`, behind
// `debug(xfrmShadow)`) needs an INDEPENDENT reference to compare the matrix-path
// candidate against. Until now it used `mesh.vertices` — the LIVE applyTRS
// output — as its reference/truth. A LATER MS-3 task will flip `applyTRS` to the
// matrix path; if the shadow still read `mesh.vertices` it would then be
// comparing the matrix path against itself (vacuous). By freezing the legacy
// per-component math here and having the shadow run THESE kernels to build its
// reference, the comparison stays meaningful after the flip: matrix-apply vs
// legacy-frozen-reference.
//
// These bodies are CHARACTER-IDENTICAL to the originals in
// `tools.xform_kernels` modulo:
//   - the `legacy` name prefix on each public kernel, and
//   - `applyTranslatePerCluster`, which in the live code is a METHOD on
//     `XfrmTransformTool` (reading `mesh` / `vertexIndicesToProcess` /
//     `dragSymmetry` / `toProcess` from instance fields). Here it is a free
//     function with those four pulled into explicit parameters; the BODY (the
//     per-cluster signed-frame `+=` loop + symmetry mirror) is byte-identical.
// The private helpers (`rotateVec`, `rotateVecLerp`, `pivotFor`, `axisFor`,
// `axesFor`) are `private` in `tools.xform_kernels` and therefore not
// importable, so they are DUPLICATED here verbatim. The matrix kernel
// (`applyXformMatrix` / `blendToIdentity`) is NOT copied — the shadow imports
// it from `tools.xform_kernels` as the live candidate.
//
// Do NOT "improve" or refactor these bodies: any divergence from the live
// kernels would silently make the shadow's reference wrong. If the live kernels
// legitimately change, re-freeze this copy in the same commit and re-derive the
// shadow tolerance.

import math    : Vec3, Viewport;
import mesh    : Mesh;
import falloff : evaluateFalloff;
import symmetry : applySymmetryMirror;
import toolpipe.packets : FalloffPacket, SymmetryPacket;
import tools.transform : TransformTool;

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
void legacyApplyTranslateIncremental(
    Mesh* mesh,
    const(int)[] indices,
    Vec3 delta,
    const ref FalloffPacket dragFalloff,
    const ref Viewport vp,
    const ref SymmetryPacket dragSymmetry,
    bool[] toProcess)
{
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
    if (dragSymmetry.enabled
        && dragSymmetry.pairOf.length == mesh.vertices.length)
        applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
}

/// Per-cluster translate. FROZEN free-function copy of
/// `XfrmTransformTool.applyTranslatePerCluster` (which in the live code is a
/// method reading `mesh` / `vertexIndicesToProcess` / `dragSymmetry` /
/// `toProcess` from instance fields). Those four are explicit parameters here;
/// the loop body + symmetry mirror are character-identical to the method.
///
/// Per-cluster (ACEN.Local) translate: each vert moves along ITS cluster's
/// signed right/up/fwd frame by (localDelta.x/.y/.z). Falloff-EXEMPT (every
/// processed vert moves at full weight). Verts with no valid cluster / axis
/// frame are skipped. Symmetry mirror runs once at the end over `toProcess`.
void legacyApplyTranslatePerCluster(
    Mesh* mesh,
    const(int)[] vertexIndicesToProcess,
    TransformTool.ClusterPivots cp,
    TransformTool.ClusterAxes   ap,
    Vec3 localDelta,
    const ref SymmetryPacket dragSymmetry,
    bool[] toProcess)
{
    import math : Vec3;
    foreach (vi; vertexIndicesToProcess) {
        if (vi < 0 || vi >= cast(int)cp.clusterOf.length) continue;
        int cid = cp.clusterOf[vi];
        if (cid < 0 || cid >= cast(int)ap.right.length) continue;
        Vec3 cr = ap.right[cid];
        Vec3 cu = ap.up   [cid];
        Vec3 cf = ap.fwd  [cid];
        Vec3 worldDelta = cr * localDelta.x
                        + cu * localDelta.y
                        + cf * localDelta.z;
        mesh.vertices[vi].x += worldDelta.x;
        mesh.vertices[vi].y += worldDelta.y;
        mesh.vertices[vi].z += worldDelta.z;
    }
    if (dragSymmetry.enabled
        && dragSymmetry.pairOf.length == mesh.vertices.length) {
        import symmetry : applySymmetryMirror;
        applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
    }
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
void legacyApplyRotateIncremental(
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
    if (dragSymmetry.enabled
        && dragSymmetry.pairOf.length == mesh.vertices.length)
        applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
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
void legacyApplyScaleFromActivation(
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
    if (dragSymmetry.enabled
        && dragSymmetry.pairOf.length == mesh.vertices.length)
        applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
}
