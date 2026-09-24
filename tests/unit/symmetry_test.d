// Module unittests for `symmetry`, moved verbatim out of source/symmetry.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.symmetry_test;

import std.algorithm : sort, max;
import std.math      : abs;
import math : Vec3, dot;
import mesh : Mesh;
import toolpipe.packets : SymmetryPacket;
import std.conv : to;
import symmetry;


// mirrorEdgePoint (Edge Slice's mirrored chain): the image edge of (v0, v1) is
// (pairOf[v0], pairOf[v1]) when the images are joined, and there is none for
// an unjoined pair, a self-mirroring edge, an unpaired endpoint, or symmetry
// off; an on-plane endpoint is its own image. Hand-built X-symmetric mesh:
//   0 (1,0,0) <-> 2 (-1,0,0),  1 (2,0,0) <-> 3 (-2,0,0),  5 (1,0,1) <-> 6 (-1,0,1),
//   4 (0,0,0) on the plane,    7 (-1.5,0,1) unpaired.
// Faces [0,1,5], [3,2,7], [4,0,2]: (2,3) exists, (2,6) does not.
unittest {
    Mesh m;
    m.vertices = [Vec3(1, 0, 0), Vec3(2, 0, 0), Vec3(-1, 0, 0), Vec3(-2, 0, 0),
                  Vec3(0, 0, 0), Vec3(1, 0, 1), Vec3(-1, 0, 1), Vec3(-1.5f, 0, 1)];
    m.addFace([0u, 1, 5]);
    m.addFace([3u, 2, 7]);
    m.addFace([4u, 0, 2]);
    SymmetryPacket sp;
    sp.enabled = true;
    sp.axisIndex = 0;
    sp.pairOf  = [2, 3, 0, 1, -1, 6, 5, -1];
    sp.onPlane = [false, false, false, false, true, false, false, false];
    assert(m.edgeIndex(2, 3) != ~0u && m.edgeIndex(2, 6) == ~0u
           && m.edgeIndex(0, 2) != ~0u && m.edgeIndex(4, 0) != ~0u,
           "mirrorEdgePoint rig: the hand-built edges are not as drawn");
    uint m0, m1;
    // Joined images: the positive control, in the argument's own order.
    assert(mirrorEdgePoint(m, sp, 0, 1, m0, m1) && m0 == 2 && m1 == 3,
           "mirrorEdgePoint: joined images not found: " ~ m0.to!string ~ "," ~ m1.to!string);
    assert(mirrorEdgePoint(m, sp, 1, 0, m0, m1) && m0 == 3 && m1 == 2,
           "mirrorEdgePoint: reversed argument order not kept");
    // Unjoined images: (0,5) maps to (2,6), which is not an edge.
    assert(!mirrorEdgePoint(m, sp, 0, 5, m0, m1) && m0 == ~0u && m1 == ~0u,
           "mirrorEdgePoint: an unjoined image pair was reported as a mirror edge");
    // Self-mirror: (0,2) maps onto itself.
    assert(!mirrorEdgePoint(m, sp, 0, 2, m0, m1),
           "mirrorEdgePoint: a self-mirroring edge was reported as its own mirror");
    // On-plane endpoint: (4,0) — vertex 4 is its own image, so (4,2).
    assert(mirrorEdgePoint(m, sp, 4, 0, m0, m1) && m0 == 4 && m1 == 2,
           "mirrorEdgePoint: an edge with an on-plane endpoint was not mirrored onto (4,2): "
           ~ m0.to!string ~ "," ~ m1.to!string);
    // Unpaired endpoint off the plane: (2,7).
    assert(!mirrorEdgePoint(m, sp, 2, 7, m0, m1),
           "mirrorEdgePoint: an edge with an unpaired endpoint was mirrored");
    // Symmetry off.
    sp.enabled = false;
    assert(!mirrorEdgePoint(m, sp, 0, 1, m0, m1),
           "mirrorEdgePoint: symmetry off still mirrors");
}
