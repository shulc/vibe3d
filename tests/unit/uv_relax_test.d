// Module unittests for `uv_relax`, moved verbatim out of source/uv_relax.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.uv_relax_test;

import mesh     : Mesh, MeshMap;
import uv_weld  : buildUvClasses, uvEq;
import uv_relax;

unittest {
    // Degenerate: iter=0 or strn=0 → returns false, data untouched.
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

    const float[] saved = uvMap.data.dup;
    assert(!uvRelax(m, uvMap, 0, 1.0f), "iter=0: must return false");
    assert(uvMap.data == saved,          "iter=0: data must be untouched");
    assert(!uvRelax(m, uvMap, 5, 0.0f), "strn=0: must return false");
    assert(uvMap.data == saved,          "strn=0: data must be untouched");
}

unittest {
    // Interior centroid: 3×3 quad grid, center vertex v4 perturbed to (1.3,
    // 1.3).  iter=1, strn=1 → center UV converges to (1,1) (the arithmetic
    // mean of neighbours v1,v3,v5,v7 at UVs (1,0),(0,1),(2,1),(1,2));
    // 12 border loops are byte-unchanged (pinned → never written).
    import mesh          : Mesh, MeshMap, MapDomain, kUvMapName;
    import math          : Vec3;
    import std.math      : fabs;
    import std.format    : format;
    import std.algorithm : canFind;

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
    assert(uvMap.data.length == 32, "3×3 grid: 16 loops × 2 = 32 UV floats");
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        uvMap.data[L * 2]     = m.vertices[vi].x;
        uvMap.data[L * 2 + 1] = m.vertices[vi].y;
    }

    // Center-vertex loops: v4 appears at corner 2 of face 0, corner 3 of
    // face 1, corner 1 of face 2, corner 0 of face 3.
    const size_t cL0 = m.faceCornerLoop(0, 2);
    const size_t cL1 = m.faceCornerLoop(1, 3);
    const size_t cL2 = m.faceCornerLoop(2, 1);
    const size_t cL3 = m.faceCornerLoop(3, 0);
    assert(cL0 != size_t.max && cL1 != size_t.max
        && cL2 != size_t.max && cL3 != size_t.max,
        "center-vertex corner loop indices must be valid");

    // Snapshot entire UV data before perturbation (vertex XY = integers,
    // exactly representable as float; byte compare is valid for border loops).
    const float[] savedData = uvMap.data.dup;

    // Perturb all four center corners.
    foreach (cl; [cL0, cL1, cL2, cL3]) {
        uvMap.data[cl * 2]     = 1.3f;
        uvMap.data[cl * 2 + 1] = 1.3f;
    }

    const bool moved = uvRelax(m, uvMap, 1, 1.0f);
    assert(moved, "interior relax: uvRelax must return true");

    // Center corners must have converged to ≈ (1, 1).
    enum float eps = 1e-4f;
    foreach (cl; [cL0, cL1, cL2, cL3]) {
        const float u = uvMap.data[cl * 2];
        const float v = uvMap.data[cl * 2 + 1];
        assert(fabs(u - 1.0f) < eps,
               format("center u ≈ 1 at loop %d; got %g", cl, u));
        assert(fabs(v - 1.0f) < eps,
               format("center v ≈ 1 at loop %d; got %g", cl, v));
    }

    // All 12 border loops must be byte-unchanged (pinned → never written).
    const size_t[] centerLoops = [cL0, cL1, cL2, cL3];
    foreach (L; 0 .. m.loops.length) {
        if (centerLoops.canFind(L)) continue;
        assert(uvMap.data[L * 2]     == savedData[L * 2],
               format("border u unchanged at loop %d", L));
        assert(uvMap.data[L * 2 + 1] == savedData[L * 2 + 1],
               format("border v unchanged at loop %d", L));
    }
}

unittest {
    // Seam split: giving v4's corner in face 3 a different UV splits it into
    // two UV classes; both touch a seam edge → both are pinned → no-op.
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

    // Perturb face-3, corner-0 (vertex v4) → creates a UV seam.
    const size_t seamL = m.faceCornerLoop(3, 0);
    assert(seamL != size_t.max);
    uvMap.data[seamL * 2]     = 1.5f;
    uvMap.data[seamL * 2 + 1] = 1.5f;

    const float[] before = uvMap.data.dup;
    assert(!uvRelax(m, uvMap, 1, 1.0f),
           "seam-split: uvRelax must return false (no-op)");
    assert(uvMap.data == before,
           "seam-split: uv.data must be byte-unchanged");
}
