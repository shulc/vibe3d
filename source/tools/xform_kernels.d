module tools.xform_kernels;

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
void applyTranslateIncremental(
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

/// Translate from a captured baseline (editBefore + dragDelta) —
/// MoveTool.applyAbsoluteFromBaseline. Re-runnable: a second call
/// with a NEW dragFalloff produces correctly re-weighted output.
/// Per-vert weight is evaluated at the BASELINE position so verts on
/// the falloff boundary don't drift through the field mid-drag.
void applyTranslateFromBaseline(
    Mesh* mesh,
    const(uint)[] editIndices,
    const(Vec3)[] editBefore,
    Vec3 dragDelta,
    const ref FalloffPacket dragFalloff,
    const ref Viewport vp,
    const ref SymmetryPacket dragSymmetry,
    bool[] toProcess)
{
    if (editIndices.length != editBefore.length) return;
    foreach (i; 0 .. editIndices.length) {
        uint vi = editIndices[i];
        if (vi >= mesh.vertices.length) continue;
        Vec3 baseline = editBefore[i];
        float w = dragFalloff.enabled
            ? evaluateFalloff(dragFalloff, baseline, cast(int)vi, vp)
            : 1.0f;
        mesh.vertices[vi].x = baseline.x + dragDelta.x * w;
        mesh.vertices[vi].y = baseline.y + dragDelta.y * w;
        mesh.vertices[vi].z = baseline.z + dragDelta.z * w;
    }
    if (dragSymmetry.enabled
        && dragSymmetry.pairOf.length == mesh.vertices.length)
        applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
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
/// Falloff weight scales the angle (soft-twist): θ_eff = θ · w.
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
        mesh.vertices[vi] = rotateVec(mesh.vertices[vi], pivot, ax, angleRad * w);
    }
    if (dragSymmetry.enabled
        && dragSymmetry.pairOf.length == mesh.vertices.length)
        applySymmetryMirror(mesh, dragSymmetry, toProcess, toProcess);
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
        if (angleAccum.x != 0) v = rotateVec(v, pivot, axX, angleAccum.x * w);
        if (angleAccum.y != 0) v = rotateVec(v, pivot, axY, angleAccum.y * w);
        if (angleAccum.z != 0) v = rotateVec(v, pivot, axZ, angleAccum.z * w);
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
