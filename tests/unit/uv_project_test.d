// Module unittests for `uv_project`, moved verbatim out of source/uv_project.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.uv_project_test;

import std.math : atan2, hypot, fabs;
import math     : Vec3;
import uv_project;

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
