// Module unittests for `overlay_space`, moved verbatim out of source/overlay_space.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.overlay_space_test;

import std.math : sqrt, isNaN;
import math     : Vec3, ModelSpace;
import document : primaryModelSpace;
import overlay_space;

unittest { // Identity is byte-identical — the accessor does not round-trip a matrix.
    // The wrong implementation this refuses: "always go through toWorldPoint /
    // always re-normalise". `identityMatrix` multiplication is not guaranteed
    // to reproduce a float bit-for-bit once a denormal or a large exponent is
    // involved, and `normalize` of an already-unit vector is a sqrt away from
    // its input. The whole existing suite runs at identity.
    auto os = OverlaySpace(ModelSpace.world());
    assert(!os.active);
    Vec3 p = Vec3(1.0e-8f, 3.3333333f, -7.7777777f);
    assert(os.pos(p).x == p.x && os.pos(p).y == p.y && os.pos(p).z == p.z);
    Vec3 u = Vec3(0.57735026f, 0.57735026f, 0.57735026f);
    auto ax = os.axis(u);
    assert(ax.dir.x == u.x && ax.dir.y == u.y && ax.dir.z == u.z);
    assert(ax.worldPerLocal == 1.0f);
    assert(os.toLocalDelta(p).y == p.y);
    assert(os.meanWorldPerLocal() == 1.0f);
}
