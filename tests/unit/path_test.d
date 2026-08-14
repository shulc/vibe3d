// Module unittests for `path`, moved verbatim out of source/path.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.path_test;

import math : Vec3, normalize;
import mesh : Mesh;
import path;

unittest {
    // Straight 2-knot path: A=(0,0,0) → B=(2,0,0), total length = 2.
    Vec3[] k = [Vec3(0, 0, 0), Vec3(2, 0, 0)];
    import std.math : fabs;
    enum eps = 1e-5f;

    assert(fabs(pathLengthTotal(k, false) - 2.0f) < eps,
           "straight: total length should be 2");

    Vec3 v0 = pathValue(k, false, 0.0f);
    assert(fabs(v0.x) < eps && fabs(v0.y) < eps && fabs(v0.z) < eps,
           "straight: value(0) should be (0,0,0)");

    Vec3 v1 = pathValue(k, false, 1.0f);
    assert(fabs(v1.x - 2.0f) < eps && fabs(v1.y) < eps && fabs(v1.z) < eps,
           "straight: value(1) should be (2,0,0)");

    Vec3 vmid = pathValue(k, false, 0.5f);
    assert(fabs(vmid.x - 1.0f) < eps && fabs(vmid.y) < eps && fabs(vmid.z) < eps,
           "straight: value(0.5) should be (1,0,0)");

    Vec3 tan = pathTangent(k, false, 0.5f);
    assert(fabs(tan.x - 1.0f) < eps && fabs(tan.y) < eps && fabs(tan.z) < eps,
           "straight: tangent(0.5) should be (1,0,0)");

    float alen = pathLength(k, false, 0.0f, 1.0f);
    assert(fabs(alen - 2.0f) < eps, "straight: pathLength(0,1) should be 2");
}

unittest {
    // Equal-leg L-shaped 3-knot path:
    //   A=(0,0,0) → B=(1,0,0) → C=(1,0,1)
    //   leg-0 = 1, leg-1 = 1, total = 2.
    //   t=0.25 → arc dist 0.5 → mid of AB → (0.5,0,0)
    //   t=0.5  → arc dist 1.0 → knot B    → (1,0,0)
    //   t=0.75 → arc dist 1.5 → mid of BC → (1,0,0.5)
    Vec3[] k = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1)];
    import std.math : fabs;
    enum eps = 1e-5f;

    assert(fabs(pathLengthTotal(k, false) - 2.0f) < eps,
           "L: total length should be 2");

    Vec3 v025 = pathValue(k, false, 0.25f);
    assert(fabs(v025.x - 0.5f) < eps && fabs(v025.y) < eps && fabs(v025.z) < eps,
           "L: value(0.25) should be (0.5,0,0)");

    Vec3 v05 = pathValue(k, false, 0.5f);
    assert(fabs(v05.x - 1.0f) < eps && fabs(v05.y) < eps && fabs(v05.z) < eps,
           "L: value(0.5) should be (1,0,0)");

    Vec3 v075 = pathValue(k, false, 0.75f);
    assert(fabs(v075.x - 1.0f) < eps && fabs(v075.y) < eps &&
           fabs(v075.z - 0.5f) < eps,
           "L: value(0.75) should be (1,0,0.5)");

    Vec3 t025 = pathTangent(k, false, 0.25f);
    assert(fabs(t025.x - 1.0f) < eps && fabs(t025.y) < eps && fabs(t025.z) < eps,
           "L: tangent(0.25) should be (1,0,0)");

    Vec3 t075 = pathTangent(k, false, 0.75f);
    assert(fabs(t075.x) < eps && fabs(t075.y) < eps && fabs(t075.z - 1.0f) < eps,
           "L: tangent(0.75) should be (0,0,1)");

    float total = pathLength(k, false, 0.0f, 1.0f);
    assert(fabs(total - 2.0f) < eps, "L: pathLength(0,1) should be 2");
}
