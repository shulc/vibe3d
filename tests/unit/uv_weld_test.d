// Module unittests for `uv_weld`, moved verbatim out of source/uv_weld.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.uv_weld_test;

import mesh    : Mesh;
import std.math : fabs;
import uv_weld;

unittest {
    // 3×3 quad grid seeded from vertex XY: all interior edges agree in UV
    // → center v4 forms one class.  9 distinct 3D vertices → 9 UV classes.
    import mesh      : Mesh, MapDomain, kUvMapName;
    import math      : Vec3;
    import std.conv  : to;

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

    float[] data = new float[](m.loops.length * 2);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        data[L * 2]     = m.vertices[vi].x;
        data[L * 2 + 1] = m.vertices[vi].y;
    }

    auto cls = buildUvClasses(m, data, null);
    assert(cls.nClasses == 9,
           "3×3 grid: expected 9 UV classes (one per unique vertex), got "
           ~ cls.nClasses.to!string);
}

unittest {
    // Cut predicate on one interior edge → one extra class vs baseline.
    import mesh : Mesh;
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

    float[] data = new float[](m.loops.length * 2);
    foreach (L; 0 .. m.loops.length) {
        const uint vi = m.loops[L].vert;
        data[L * 2]     = m.vertices[vi].x;
        data[L * 2 + 1] = m.vertices[vi].y;
    }

    auto cls0 = buildUvClasses(m, data, null);
    assert(cls0.nClasses == 9, "baseline: 9 classes");

    // Find first interior loop.
    uint cutL = uint.max;
    foreach (L; 0 .. m.loops.length) {
        if (m.loops[L].twin != uint.max) { cutL = cast(uint)L; break; }
    }
    assert(cutL != uint.max, "must find an interior loop");

    const uint cutT = m.loops[cutL].twin;
    auto cls1 = buildUvClasses(m, data,
                               L => L == cutL || L == cutT);
    assert(cls1.nClasses == cls0.nClasses + 1,
           "cutting one interior edge must add exactly 1 class");
}
