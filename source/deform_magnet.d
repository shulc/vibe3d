module deform_magnet;

import mesh : Mesh;
import math : Vec3, Viewport, AimViewport, aimSpace, ModelSpace;
import falloff : evaluateFalloff;
import toolpipe.packets : FalloffPacket;

/// Pure attraction kernel: moves `pos` toward `target` by a fraction
/// governed by `weight * strength` (clamped to [0, 1]).
///
///   new_pos = pos + (target − pos) * clamp(weight * strength, 0, 1)
///
/// This is a CONVERGENT field: each vertex moves along its own vector
/// `target − pos`, NOT along a shared axis.  Vertices already at
/// `target` are no-ops.
pragma(inline, true)
Vec3 attractToPoint(Vec3 pos, Vec3 target, float weight, float strength) {
    float t = weight * strength;
    if (t <= 0.0f) return pos;
    if (t > 1.0f)  t = 1.0f;
    return Vec3(
        pos.x + (target.x - pos.x) * t,
        pos.y + (target.y - pos.y) * t,
        pos.z + (target.z - pos.z) * t,
    );
}

/// Apply convergent-attraction deformation to the vertex subset `indices`.
///
/// For each vertex i in `indices`:
///   1. Evaluate weight w_i = evaluateFalloff(fp, pos_i, i, aim).
///   2. If w_i > 0: pos_i' = attractToPoint(pos_i, target, w_i, strength).
///
/// Post-conditions (always met, even on early-out):
///   `touchedIdx`  — indices whose position was changed (same order as written).
///   `touchedPrev` — pre-displacement positions, parallel to touchedIdx.
///     Used by MeshMagnet.revert() and MagnetTool.commitEdit() to build
///     the undo delta.
///
/// Returns true iff at least one vertex was displaced.
/// Task 0619 — `aim` replaces what used to be a `Viewport` that both
/// callers filled with a default-constructed value and a comment saying
/// "Element falloff ignores viewport". That reasoning held for the
/// interactive tool, which pins `fp.type = FalloffType.Element`, but NOT for
/// `commands/mesh/magnet.d`: it is an `Operator`, and its `evaluate(vts)`
/// copies the LIVE pipeline `FalloffPacket` over its own — which can be a
/// Screen or Lasso type. So the projection genuinely is reachable here, and
/// the aim space is a required parameter rather than an optional one.
bool applyMagnet(Mesh* mesh, const(int)[] indices,
                 Vec3 target, float strength,
                 const ref FalloffPacket fp, const ref AimViewport aim,
                 ref uint[] touchedIdx, ref Vec3[] touchedPrev) {
    touchedIdx.length  = 0;
    touchedPrev.length = 0;

    if (strength <= 0.0f || indices.length == 0) return false;

    foreach (i; indices) {
        if (i < 0 || cast(size_t)i >= mesh.vertices.length) continue;
        float w = evaluateFalloff(fp, mesh.vertices[i], i, aim);
        if (w <= 0.0f) continue;
        touchedIdx  ~= cast(uint)i;
        touchedPrev ~= mesh.vertices[i];
        mesh.vertices[i] = attractToPoint(mesh.vertices[i], target, w, strength);
    }
    return touchedIdx.length > 0;
}
