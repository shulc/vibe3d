// Module unittests for `uv_unwrap`, moved verbatim out of source/uv_unwrap.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.uv_unwrap_test;

import mesh    : Mesh, MeshMap;
import math    : Vec3, dot, cross;
import std.math : fabs, sqrt, acos;
import uv_weld : buildUvClasses;
import uv_unwrap;

unittest {
    // "Tent" fixture: 3×3 quad grid with center vertex v4 lifted in Z.
    // Seed UV: planar axis=Z (u=x, v=y for each vertex).
    // Perturbation: v4's 4 corner loops moved to (0.2, 0.8) — away from
    //   the energy minimum.
    // After 30 GS passes:
    //   - Dirichlet energy drops (primary, provable contract).
    //   - Angular distortion drops (correlated on this fixture).
    //   - No NaN/Inf.
    //   - Consistent signed-area sign (no foldover).
    //   - Interior UV within boundary bbox.
    //   - Boundary loops byte-unchanged.

    import mesh        : Mesh, MeshMap, MapDomain, kUvMapName;
    import math        : Vec3;
    import std.math    : isNaN, isInfinity, fabs;
    import std.format  : format;
    import std.algorithm : canFind;

    enum float h = 1.5f;   // lift height for v4 — large enough to create distortion

    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1,1,h), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0), Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();

    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    // Seed: planar axis=Z → u=x, v=y
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    // v4 appears at: corner 2 of face 0, corner 3 of face 1,
    //                corner 1 of face 2, corner 0 of face 3.
    const size_t cL0 = m.faceCornerLoop(0, 2);
    const size_t cL1 = m.faceCornerLoop(1, 3);
    const size_t cL2 = m.faceCornerLoop(2, 1);
    const size_t cL3 = m.faceCornerLoop(3, 0);
    assert(cL0 != size_t.max && cL1 != size_t.max
        && cL2 != size_t.max && cL3 != size_t.max,
        "center-vertex corner loops must be valid");

    // Perturb all four center corners far from the minimum.
    foreach (cl; [cL0, cL1, cL2, cL3]) {
        uvMap.data[cl * 2]     = 0.2f;
        uvMap.data[cl * 2 + 1] = 0.8f;
    }

    // Snapshot boundary UVs before relax.
    const float[] savedData = uvMap.data.dup;

    // Measure pre-relax distortion.
    const double E0   = uvDirichletEnergy(m, uvMap.data);
    const double ang0 = uvAngularDistortion(m, uvMap.data);

    // Run kernel (seams=boundary only → null seamLoop).
    const bool moved = uvUnwrap(m, uvMap, 30, null, null);
    assert(moved, "tent with perturbed center: uvUnwrap must return true");

    const double E1   = uvDirichletEnergy(m, uvMap.data);
    const double ang1 = uvAngularDistortion(m, uvMap.data);

    // Primary: Dirichlet energy drops (provable per-pass monotone contract).
    assert(E1 < E0,
           format("Dirichlet energy must decrease: E0=%g E1=%g", E0, E1));

    // Correlated: angular distortion drops on this fixture.
    assert(ang1 < ang0,
           format("angular distortion must decrease: ang0=%g ang1=%g", ang0, ang1));

    // No NaN / Inf in any UV component.
    foreach (L; 0 .. m.loops.length) {
        const float u = uvMap.data[L * 2];
        const float v = uvMap.data[L * 2 + 1];
        assert(!isNaN(u) && !isInfinity(u),
               format("loop %d u is NaN/Inf: %g", L, u));
        assert(!isNaN(v) && !isInfinity(v),
               format("loop %d v is NaN/Inf: %g", L, v));
    }

    // Consistent signed-area sign (no foldover) — check all UV triangles.
    // Fan-triangulate each face in UV.
    {
        int signFirst = 0;
        bool ok = true;
        outer: foreach (uint fi; 0 .. cast(uint) m.faces.length) {
            const size_t nc   = m.faces[fi].length;
            const size_t base = m.faceLoop[fi];
            foreach (t; 0 .. nc - 2) {
                size_t la = base, lb = base+t+1, lc = base+t+2;
                float ua = uvMap.data[la*2], va_ = uvMap.data[la*2+1];
                float ub = uvMap.data[lb*2], vb  = uvMap.data[lb*2+1];
                float uc = uvMap.data[lc*2], vc  = uvMap.data[lc*2+1];
                float area2 = (ub-ua)*(vc-va_) - (uc-ua)*(vb-va_);
                int sgn = area2 > 1e-9f ? 1 : (area2 < -1e-9f ? -1 : 0);
                if (sgn == 0) continue;
                if (signFirst == 0) { signFirst = sgn; }
                else if (sgn != signFirst) { ok = false; break outer; }
            }
        }
        assert(ok, "UV triangles must have consistent orientation (no foldover)");
    }

    // Interior UVs within boundary bbox: u ∈ [0,2], v ∈ [0,2].
    const size_t[] centerLoops = [cL0, cL1, cL2, cL3];
    foreach (L; 0 .. m.loops.length) {
        if (!centerLoops.canFind(L)) continue;   // skip boundary
        const float u = uvMap.data[L * 2];
        const float v = uvMap.data[L * 2 + 1];
        assert(u >= -1e-6f && u <= 2.0f + 1e-6f,
               format("interior u out of boundary bbox: %g", u));
        assert(v >= -1e-6f && v <= 2.0f + 1e-6f,
               format("interior v out of boundary bbox: %g", v));
    }

    // Boundary loops must be byte-unchanged (pinned → never written).
    foreach (L; 0 .. m.loops.length) {
        if (centerLoops.canFind(L)) continue;
        assert(uvMap.data[L * 2]     == savedData[L * 2],
               format("boundary u changed at loop %d", L));
        assert(uvMap.data[L * 2 + 1] == savedData[L * 2 + 1],
               format("boundary v changed at loop %d", L));
    }
}

unittest {
    // No-pin guard: closed mesh (cube) + continuous seed → zero pinned classes
    // → uvUnwrap must return false (no collapse).
    import mesh : Mesh, MeshMap, MapDomain, kUvMapName, makeCube;
    import math : Vec3;

    auto m = makeCube();
    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);

    // Seed: planar axis=Z, continuous (no UV seams → no pinned classes).
    // Assign u=x, v=y for every loop vertex.
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    const float[] before = uvMap.data.dup;
    const bool moved = uvUnwrap(m, uvMap, 30, null, null);
    assert(!moved,
           "closed mesh + continuous seed: uvUnwrap must return false (no-pin guard)");
    assert(uvMap.data == before,
           "no-pin guard: UV data must be byte-unchanged");
}

unittest {
    // Seam cut: mark one interior edge as a seam → those corners get pinned.
    // With the entire grid's interior pinned via seam, nothing relaxes → false.
    import mesh : Mesh, MeshMap, MapDomain, kUvMapName;
    import math : Vec3;

    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0),
        Vec3(0,1,0), Vec3(1,1,0), Vec3(2,1,0),
        Vec3(0,2,0), Vec3(1,2,0), Vec3(2,2,0),
    ];
    m.addFace([0u,1u,4u,3u]);
    m.addFace([1u,2u,5u,4u]);
    m.addFace([3u,4u,7u,6u]);
    m.addFace([4u,5u,8u,7u]);
    m.buildLoops();

    auto uvMap = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
    assert(uvMap !is null);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    // Mark ALL interior loops as seams → every class is pinned.
    bool[] seams = new bool[](m.loops.length);
    foreach (L; 0 .. m.loops.length)
        if (m.loops[L].twin != uint.max) seams[L] = true;

    // Perturb center to ensure relax would fire if not all-pinned.
    const size_t cl0 = m.faceCornerLoop(0, 2);
    uvMap.data[cl0 * 2] = 0.3f;

    const float[] before = uvMap.data.dup;
    const bool moved = uvUnwrap(m, uvMap, 10, seams, null);
    assert(!moved,
           "all-seam interior: uvUnwrap must return false when nothing can relax");
    assert(uvMap.data == before, "all-seam: UV data must be byte-unchanged");
}
