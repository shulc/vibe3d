// Module unittests for `uv_island`, moved verbatim out of source/uv_island.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.uv_island_test;

import mesh        : Mesh, MeshMap, MapDomain;
import uv_transform : UvAffine;
import uv_island;

unittest {
    import std.math : fabs, isNaN, isInfinity;
    enum float eps = 1e-5f;
    bool feq(float a, float b) { return fabs(a - b) < eps; }

    float applyU(in UvAffine a, float u, float v) {
        return a.lin[0][0]*u + a.lin[0][1]*v + a.trans[0];
    }
    float applyV(in UvAffine a, float u, float v) {
        return a.lin[1][0]*u + a.lin[1][1]*v + a.trans[1];
    }

    // ----------------------------------------------------------------
    // computeFitAffine — fill mode, known bbox.
    //
    // bbox = [-0.5, 0.5] × [-0.5, 0.5]: fill should scale by 1/1 = 1
    // and translate by +0.5 → maps (-0.5,-0.5)→(0,0) and (0.5,0.5)→(1,1).
    {
        UvBBox bb;
        bb.umin = -0.5f; bb.umax = 0.5f;
        bb.vmin = -0.5f; bb.vmax = 0.5f;
        auto a = computeFitAffine(bb, false);
        assert(feq(applyU(a, -0.5f, -0.5f), 0.0f), "fill: corner (-0.5,-0.5) u=0");
        assert(feq(applyV(a, -0.5f, -0.5f), 0.0f), "fill: corner (-0.5,-0.5) v=0");
        assert(feq(applyU(a,  0.5f,  0.5f), 1.0f), "fill: corner (0.5,0.5) u=1");
        assert(feq(applyV(a,  0.5f,  0.5f), 1.0f), "fill: corner (0.5,0.5) v=1");
    }

    // computeFitAffine — fill, non-square bbox [0,4]×[0,2].
    {
        UvBBox bb;
        bb.umin = 0.0f; bb.umax = 4.0f;
        bb.vmin = 0.0f; bb.vmax = 2.0f;
        auto a = computeFitAffine(bb, false);
        // su=0.25, tu=0; sv=0.5, tv=0
        assert(feq(applyU(a, 0.0f, 0.0f), 0.0f), "fill non-sq: (0,0) u=0");
        assert(feq(applyV(a, 0.0f, 0.0f), 0.0f), "fill non-sq: (0,0) v=0");
        assert(feq(applyU(a, 4.0f, 2.0f), 1.0f), "fill non-sq: (4,2) u=1");
        assert(feq(applyV(a, 4.0f, 2.0f), 1.0f), "fill non-sq: (4,2) v=1");
    }

    // computeFitAffine — degenerate u-axis (collapsed).
    {
        UvBBox bb;
        bb.umin = 0.3f; bb.umax = 0.3f; // collapsed
        bb.vmin = 0.0f; bb.vmax = 2.0f;
        auto a = computeFitAffine(bb, false);
        // u: scale=1, trans= 0.5 - 0.3 = 0.2 → collapsed coord maps to 0.5
        // v: scale=0.5, trans=0 → [0,2]→[0,1]
        assert(feq(applyU(a, 0.3f, 0.0f), 0.5f), "degenerate-u: maps to 0.5");
        assert(feq(applyV(a, 0.3f, 0.0f), 0.0f), "degenerate-u: v min=0");
        assert(feq(applyV(a, 0.3f, 2.0f), 1.0f), "degenerate-u: v max=1");
        // No NaN / infinity.
        assert(!isNaN(a.trans[0]) && !isInfinity(a.trans[0]), "degenerate-u: no NaN in trans[0]");
    }

    // computeFitAffine — keepAspect, non-square bbox.
    {
        UvBBox bb;
        bb.umin = 0.0f; bb.umax = 2.0f; // w=2, h=1
        bb.vmin = 0.0f; bb.vmax = 1.0f;
        auto a = computeFitAffine(bb, true);
        // s = 1/max(2,1) = 0.5; scaled = (1,0.5); offset = (0, 0.25)
        // u' = 0.5*u + 0; v' = 0.5*v + 0.25
        assert(feq(applyU(a, 0.0f, 0.0f), 0.0f),  "keepAspect: umin→0");
        assert(feq(applyU(a, 2.0f, 0.0f), 1.0f),  "keepAspect: umax→1");
        assert(feq(applyV(a, 0.0f, 0.0f), 0.25f), "keepAspect: vmin→0.25 (centred)");
        assert(feq(applyV(a, 0.0f, 1.0f), 0.75f), "keepAspect: vmax→0.75 (centred)");
    }

    // ----------------------------------------------------------------
    // computeShelfPack — single unit-square island.
    //
    // w==h==1 → s = 1/max(1,1) = 1 → maps bbox exactly to [0,1]².
    {
        UvBBox b;
        b.umin = 0.0f; b.umax = 1.0f;
        b.vmin = 0.0f; b.vmax = 1.0f;
        auto affines = computeShelfPack([b], 0.0f);
        assert(affines.length == 1);
        // Mapped corners:
        assert(feq(applyU(affines[0], 0.0f, 0.0f), 0.0f), "single: (0,0) u=0");
        assert(feq(applyV(affines[0], 0.0f, 0.0f), 0.0f), "single: (0,0) v=0");
        assert(feq(applyU(affines[0], 1.0f, 1.0f), 1.0f), "single: (1,1) u=1");
        assert(feq(applyV(affines[0], 1.0f, 1.0f), 1.0f), "single: (1,1) v=1");
    }

    // computeShelfPack — two unit-square boxes, no overlap, both in [0,1]².
    {
        UvBBox b0; b0.umin = 0.0f; b0.umax = 1.0f; b0.vmin = 0.0f; b0.vmax = 1.0f;
        UvBBox b1; b1.umin = 2.0f; b1.umax = 3.0f; b1.vmin = 0.0f; b1.vmax = 1.0f;
        auto affines = computeShelfPack([b0, b1], 0.0f);
        assert(affines.length == 2);

        // Map each bbox through its affine to get the packed bbox.
        float u0min = applyU(affines[0], b0.umin, b0.vmin);
        float u0max = applyU(affines[0], b0.umax, b0.vmin);
        float v0min = applyV(affines[0], b0.umin, b0.vmin);
        float v0max = applyV(affines[0], b0.umin, b0.vmax);

        float u1min = applyU(affines[1], b1.umin, b1.vmin);
        float u1max = applyU(affines[1], b1.umax, b1.vmin);
        float v1min = applyV(affines[1], b1.umin, b1.vmin);
        float v1max = applyV(affines[1], b1.umin, b1.vmax);

        // Both within [0,1]².
        assert(u0min >= -eps && u0max <= 1.0f + eps, "pack2: island 0 u in [0,1]");
        assert(v0min >= -eps && v0max <= 1.0f + eps, "pack2: island 0 v in [0,1]");
        assert(u1min >= -eps && u1max <= 1.0f + eps, "pack2: island 1 u in [0,1]");
        assert(v1min >= -eps && v1max <= 1.0f + eps, "pack2: island 1 v in [0,1]");

        // Non-overlap: positive-area intersection must be zero (touching at edge = ok).
        float overlapU = (u0max < u1min || u1max < u0min)
            ? 0.0f : ((u0max < u1max ? u0max : u1max) - (u0min > u1min ? u0min : u1min));
        float overlapV = (v0max < v1min || v1max < v0min)
            ? 0.0f : ((v0max < v1max ? v0max : v1max) - (v0min > v1min ? v0min : v1min));
        float area = (overlapU > 0 ? overlapU : 0.0f) * (overlapV > 0 ? overlapV : 0.0f);
        assert(area <= eps, "pack2: islands must not overlap");
    }

    // computeShelfPack — all-degenerate (every box w==h==0, Σarea=0).
    // s must be 1 (zero-guard), output must be finite.
    {
        UvBBox b0; b0.umin = 0.5f; b0.umax = 0.5f; b0.vmin = 0.5f; b0.vmax = 0.5f;
        UvBBox b1; b1.umin = 1.0f; b1.umax = 1.0f; b1.vmin = 1.0f; b1.vmax = 1.0f;
        auto affines = computeShelfPack([b0, b1], 0.0f);
        foreach (i, ref a; affines) {
            assert(!isNaN(a.lin[0][0])  && !isInfinity(a.lin[0][0]),  "degenPack: lin finite");
            assert(!isNaN(a.trans[0])   && !isInfinity(a.trans[0]),   "degenPack: trans finite");
            // s == 1 (zero-guard fired)
            assert(feq(a.lin[0][0], 1.0f), "degenPack: s==1");
        }
    }
}
