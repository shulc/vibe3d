module uv_project;

/// Pure UV projection kernel — maps a 3D vertex position to a (u,v) pair.
///
/// Four projection modes: Planar, Box, Cylindrical, Spherical.
///
/// Shipped conventions (vibe3d-convention v1):
///   Let q = (p − center) / size  (the scaled, centred position).
///
///   Planar — drop the projection axis; map the remaining two coords to (u,v)
///     in cyclic right-handed order:
///       axis=Z → (u,v) = (q.x, q.y)
///       axis=X → (u,v) = (q.y, q.z)
///       axis=Y → (u,v) = (q.z, q.x)
///
///   Box — pick the owning face's dominant normal axis (argmax |n|, tie-break
///     x→y→z = lowest-index), then apply Planar on that axis.
///     The `axis` parameter is ignored; `faceNormal` drives the choice.
///
///   Cylindrical (axis=Y base):
///       u = atan2(q.x, q.z) / (2π) + 0.5    (seam at −z half-plane)
///       v = q.y                               (height)
///     axis=Z and axis=X use the same cyclic substitution rule as Planar.
///
///   Spherical (axis=Y base):
///       u = atan2(q.x, q.z) / (2π) + 0.5
///       v = atan2(q.y, hypot(q.x, q.z)) / π + 0.5   ∈ [0..1]
///     Cyclic substitution applies for axis=Z, axis=X.
///
///   Degenerate guard: atan2(0,0) = 0 (deterministic seam; not special-cased).
///   size guard: if size <= 0, the command clamps it to 1 before calling here.
///
/// Thread-safety: pure functions, no shared state.

import std.math : atan2, hypot, fabs;
import math     : Vec3;

// ---------------------------------------------------------------------------
// Compile-time float approximations of π and 2π (avoids real-promotion from
// std.math.PI which is declared as `real` and would widen the arithmetic).
// ---------------------------------------------------------------------------

private enum float kPI    = 3.14159265358979323846f;
private enum float kTwoPI = 6.28318530717958647692f;

// ---------------------------------------------------------------------------
// Public enums
// ---------------------------------------------------------------------------

/// Projection type for `uv.project`.
enum UvProjMode { Planar, Box, Cylindrical, Spherical }

/// Projection axis (Planar / Cylindrical / Spherical; Box ignores this).
enum UvProjAxis { X, Y, Z }

// ---------------------------------------------------------------------------
// dominantAxis — argmax(|n|), tie-break to lowest index (x=0, y=1, z=2).
//
// Used by Box mode: the owning face's dominant axis selects the planar basis.
// Tie-break is documented and asserted by a synthetic 45° normal unittest so
// the choice is pinned, not incidental.
// ---------------------------------------------------------------------------

uint dominantAxis(Vec3 n) pure nothrow {
    immutable float ax = fabs(n.x), ay = fabs(n.y), az = fabs(n.z);
    if (ax >= ay && ax >= az) return 0; // X wins; equal magnitude → lowest index
    if (ay >= az)             return 1; // Y wins over Z on tie
    return 2;                           // Z
}

// ---------------------------------------------------------------------------
// projectPlanar — internal helper; drop axis, map remaining to (u,v).
// ---------------------------------------------------------------------------

private float[2] projectPlanar(Vec3 q, UvProjAxis axis) pure nothrow {
    final switch (axis) {
        case UvProjAxis.Z: { float[2] r = [q.x, q.y]; return r; }
        case UvProjAxis.X: { float[2] r = [q.y, q.z]; return r; }
        case UvProjAxis.Y: { float[2] r = [q.z, q.x]; return r; }
    }
}

// ---------------------------------------------------------------------------
// projectUv — the public projection entry point.
//
//   p          — 3D world position of the vertex
//   mode       — Planar | Box | Cylindrical | Spherical
//   axis       — projection axis (Box ignores it — uses faceNormal instead)
//   center     — frame origin (world-space); q = (p − center) / size
//   size       — scale denominator (caller ensures > 0)
//   faceNormal — Newell face normal; used only by Box mode
//
// Returns a float[2] = [u, v].
// ---------------------------------------------------------------------------

float[2] projectUv(Vec3 p, UvProjMode mode, UvProjAxis axis,
                   Vec3 center, float size, Vec3 faceNormal) pure nothrow
{
    Vec3 q = Vec3((p.x - center.x) / size,
                  (p.y - center.y) / size,
                  (p.z - center.z) / size);

    final switch (mode) {
        case UvProjMode.Planar:
            return projectPlanar(q, axis);

        case UvProjMode.Box: {
            // Per-face planar using the dominant normal axis.
            uint da = dominantAxis(faceNormal);
            if (da == 0) return projectPlanar(q, UvProjAxis.X);
            if (da == 1) return projectPlanar(q, UvProjAxis.Y);
            return projectPlanar(q, UvProjAxis.Z);
        }

        case UvProjMode.Cylindrical:
            // Base formula (axis=Y, up=y, radial plane=xz):
            //   u = atan2(q.x, q.z) / (2π) + 0.5,  v = q.y
            // Cyclic substitution (x→y→z→x) for other axes:
            //   axis=Z: u = atan2(q.y, q.x) / (2π) + 0.5,  v = q.z
            //   axis=X: u = atan2(q.z, q.y) / (2π) + 0.5,  v = q.x
            final switch (axis) {
                case UvProjAxis.Y: {
                    float[2] r = [atan2(q.x, q.z) / kTwoPI + 0.5f, q.y];
                    return r;
                }
                case UvProjAxis.Z: {
                    float[2] r = [atan2(q.y, q.x) / kTwoPI + 0.5f, q.z];
                    return r;
                }
                case UvProjAxis.X: {
                    float[2] r = [atan2(q.z, q.y) / kTwoPI + 0.5f, q.x];
                    return r;
                }
            }

        case UvProjMode.Spherical:
            // Base formula (axis=Y):
            //   u = atan2(q.x, q.z) / (2π) + 0.5
            //   v = atan2(q.y, hypot(q.x, q.z)) / π + 0.5   ∈ [0..1]
            // Cyclic substitution for axis=Z and axis=X.
            final switch (axis) {
                case UvProjAxis.Y: {
                    float rad = hypot(q.x, q.z);
                    float[2] r = [atan2(q.x, q.z) / kTwoPI + 0.5f,
                                  atan2(q.y, rad)  / kPI    + 0.5f];
                    return r;
                }
                case UvProjAxis.Z: {
                    float rad = hypot(q.y, q.x);
                    float[2] r = [atan2(q.y, q.x) / kTwoPI + 0.5f,
                                  atan2(q.z, rad)  / kPI    + 0.5f];
                    return r;
                }
                case UvProjAxis.X: {
                    float rad = hypot(q.z, q.y);
                    float[2] r = [atan2(q.z, q.y) / kTwoPI + 0.5f,
                                  atan2(q.x, rad)  / kPI    + 0.5f];
                    return r;
                }
            }
    }
}

// ---------------------------------------------------------------------------
// Module-level unittests — analytic golden contracts.
// Run by `dub test --config=tests` (the mandatory gate for new core modules).
// ---------------------------------------------------------------------------
