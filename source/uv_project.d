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
// Run by `dub test --config=modeling` (the mandatory gate for new core modules).
// ---------------------------------------------------------------------------

unittest {
    import std.math  : fabs, sqrt;
    import std.format : format;

    enum float eps = 1e-5f;
    bool feq(float a, float b) pure { return fabs(a - b) < eps; }

    Vec3 zeroN = Vec3(0, 0, 1); // dummy face normal (ignored by non-Box modes)

    // -----------------------------------------------------------------------
    // Planar axis=Z: (u,v) = (x,y)
    // -----------------------------------------------------------------------
    {
        auto r = projectUv(Vec3(0.5f, -0.5f, 0.3f), UvProjMode.Planar, UvProjAxis.Z,
                           Vec3(0,0,0), 1.0f, zeroN);
        assert(feq(r[0],  0.5f), "planar-Z: u = x");
        assert(feq(r[1], -0.5f), "planar-Z: v = y");
    }

    // Planar axis=X: (u,v) = (y,z)
    {
        auto r = projectUv(Vec3(0.1f, 0.3f, 0.7f), UvProjMode.Planar, UvProjAxis.X,
                           Vec3(0,0,0), 1.0f, zeroN);
        assert(feq(r[0], 0.3f), "planar-X: u = y");
        assert(feq(r[1], 0.7f), "planar-X: v = z");
    }

    // Planar axis=Y: (u,v) = (z,x)
    {
        auto r = projectUv(Vec3(0.4f, 0.8f, 0.2f), UvProjMode.Planar, UvProjAxis.Y,
                           Vec3(0,0,0), 1.0f, zeroN);
        assert(feq(r[0], 0.2f), "planar-Y: u = z");
        assert(feq(r[1], 0.4f), "planar-Y: v = x");
    }

    // size=2 halves the coords
    {
        auto r = projectUv(Vec3(1.0f, 0.5f, 0.0f), UvProjMode.Planar, UvProjAxis.Z,
                           Vec3(0,0,0), 2.0f, zeroN);
        assert(feq(r[0], 0.5f),  "size=2: u halved");
        assert(feq(r[1], 0.25f), "size=2: v halved");
    }

    // center shifts coords
    {
        auto r = projectUv(Vec3(1.0f, 1.0f, 0.0f), UvProjMode.Planar, UvProjAxis.Z,
                           Vec3(1.0f, 0.5f, 0.0f), 1.0f, zeroN);
        assert(feq(r[0], 0.0f), "center: u = x - cx");
        assert(feq(r[1], 0.5f), "center: v = y - cy");
    }

    // -----------------------------------------------------------------------
    // Box: six axis-aligned normals select the correct planar basis.
    // -----------------------------------------------------------------------
    {
        // +Z face: dominant=Z → planar-Z → (u,v) = (x,y)
        auto rPZ = projectUv(Vec3(0.3f, 0.7f, 0.5f), UvProjMode.Box, UvProjAxis.Z,
                             Vec3(0,0,0), 1.0f, Vec3(0,0,1));
        assert(feq(rPZ[0], 0.3f) && feq(rPZ[1], 0.7f), "box +Z: (u,v)=(x,y)");

        // +Y face: dominant=Y → planar-Y → (u,v) = (z,x)
        auto rPY = projectUv(Vec3(0.2f, 0.5f, 0.6f), UvProjMode.Box, UvProjAxis.Z,
                             Vec3(0,0,0), 1.0f, Vec3(0,1,0));
        assert(feq(rPY[0], 0.6f) && feq(rPY[1], 0.2f), "box +Y: (u,v)=(z,x)");

        // +X face: dominant=X → planar-X → (u,v) = (y,z)
        auto rPX = projectUv(Vec3(0.5f, 0.4f, 0.8f), UvProjMode.Box, UvProjAxis.Z,
                             Vec3(0,0,0), 1.0f, Vec3(1,0,0));
        assert(feq(rPX[0], 0.4f) && feq(rPX[1], 0.8f), "box +X: (u,v)=(y,z)");

        // -Z face: normal=(0,0,-1), dominant=Z → same planar-Z basis
        auto rNZ = projectUv(Vec3(0.1f, 0.2f, -0.5f), UvProjMode.Box, UvProjAxis.Z,
                             Vec3(0,0,0), 1.0f, Vec3(0,0,-1));
        assert(feq(rNZ[0], 0.1f) && feq(rNZ[1], 0.2f), "box -Z: dominant=Z");
    }

    // -----------------------------------------------------------------------
    // Box tie-break: equal components → lowest index wins (x→y→z priority).
    // This is the load-bearing assertion that pins the documented convention.
    // -----------------------------------------------------------------------
    {
        float v2 = 1.0f / cast(float)sqrt(2.0);
        float v3 = 1.0f / cast(float)sqrt(3.0);

        // (1/√2, 1/√2, 0): |x|=|y| > |z| → X wins (index 0)
        assert(dominantAxis(Vec3(v2, v2, 0)) == 0,
               "tie x=y: x wins (index 0)");

        // (0, 1/√2, 1/√2): |y|=|z| > |x| → Y wins (index 1)
        assert(dominantAxis(Vec3(0, v2, v2)) == 1,
               "tie y=z: y wins (index 1)");

        // (1/√3, 1/√3, 1/√3): all equal → X wins
        assert(dominantAxis(Vec3(v3, v3, v3)) == 0,
               "tie x=y=z: x wins (index 0)");
    }

    // -----------------------------------------------------------------------
    // Cylindrical axis=Y: u=atan2(x,z)/(2π)+0.5, v=y.
    // -----------------------------------------------------------------------
    {
        import std.math : atan2 = atan2;

        // Point at +X: q=(1,0,0) → u=atan2(1,0)/(2π)+0.5 = 0.25+0.5 = 0.75
        auto rX = projectUv(Vec3(1.0f, 0.0f, 0.0f), UvProjMode.Cylindrical, UvProjAxis.Y,
                            Vec3(0,0,0), 1.0f, zeroN);
        assert(feq(rX[0], 0.75f), "cyl axis=Y at +X: u=0.75");
        assert(feq(rX[1],  0.0f), "cyl axis=Y at +X: v=0");

        // Point at +Z: q=(0,0.5,1) → u=atan2(0,1)/(2π)+0.5=0.5, v=0.5
        auto rZ = projectUv(Vec3(0.0f, 0.5f, 1.0f), UvProjMode.Cylindrical, UvProjAxis.Y,
                            Vec3(0,0,0), 1.0f, zeroN);
        assert(feq(rZ[0], 0.5f), "cyl axis=Y at +Z: u=0.5");
        assert(feq(rZ[1], 0.5f), "cyl axis=Y at +Z: v=0.5");
    }

    // -----------------------------------------------------------------------
    // Spherical axis=Y: north pole v=1, equator v=0.5, south pole v=0.
    // -----------------------------------------------------------------------
    {
        // North pole (0,1,0)
        auto rN = projectUv(Vec3(0.0f, 1.0f, 0.0f), UvProjMode.Spherical, UvProjAxis.Y,
                            Vec3(0,0,0), 1.0f, zeroN);
        assert(feq(rN[1], 1.0f), "spherical: north pole v=1");

        // Equator point +Z (0,0,1) → v=atan2(0,1)/π+0.5=0.5
        auto rE = projectUv(Vec3(0.0f, 0.0f, 1.0f), UvProjMode.Spherical, UvProjAxis.Y,
                            Vec3(0,0,0), 1.0f, zeroN);
        assert(feq(rE[1], 0.5f), "spherical: equator v=0.5");

        // South pole (0,-1,0) → v=atan2(-1,0)/π+0.5=-0.5+0.5=0
        auto rS = projectUv(Vec3(0.0f, -1.0f, 0.0f), UvProjMode.Spherical, UvProjAxis.Y,
                            Vec3(0,0,0), 1.0f, zeroN);
        assert(feq(rS[1], 0.0f), "spherical: south pole v=0");
    }
}
