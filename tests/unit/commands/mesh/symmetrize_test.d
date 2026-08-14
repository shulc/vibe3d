// Module unittests for `commands.mesh.symmetrize`, moved verbatim out of source/commands/mesh/symmetrize.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.commands.mesh.symmetrize_test;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math   : Vec3;
import params : Param;
import change_bus : MeshEditScope;
import toolpipe.packets : SymmetryPacket, SubjectPacket;
import symmetry : rebuildPairing, rebuildPairingTopological, applySymmetryMirror;
import math : Vec3;
import mesh : Mesh;
import toolpipe.packets : SymmetryPacket;
import commands.mesh.symmetrize;

unittest {
    import std.math : abs;
    // On-plane projection: a seam vert drifted slightly off the plane should
    // snap back onto the plane after symmetrize.
    Mesh m;
    m.addVertex(Vec3(0.02f,  1.0f, 0.0f));   // v0: seam, drifted 0.02 off X=0
    m.addVertex(Vec3(0.5f,   0.0f, 0.0f));   // v1: +X
    m.addVertex(Vec3(-0.5f,  0.0f, 0.0f));   // v2: -X
    m.addFace([0u, 1u, 2u]);
    m.buildLoops();

    SymmetryPacket sp;
    sp.enabled      = true;
    sp.axisIndex    = 0;
    sp.offset       = 0.0f;
    sp.epsilonWorld = 0.1f;   // v0 within 0.1 → on-plane
    sp.baseSide     = +1;
    sp.planeNormal  = Vec3(1, 0, 0);
    sp.planePoint   = Vec3(0, 0, 0);

    int[]  pairOf; bool[] onPlane; int[] vertSign;
    rebuildPairing(m, sp, pairOf, onPlane, vertSign);
    sp.pairOf = pairOf; sp.onPlane = onPlane; sp.vertSign = vertSign;

    // v0 must be classified as on-plane.
    assert(onPlane[0], "v0 within epsilon should be on-plane");

    auto selected    = new bool[](m.vertices.length);  selected[]    = true;
    auto alsoTouched = new bool[](m.vertices.length);  alsoTouched[] = false;
    applySymmetryMirror(&m, sp, selected, alsoTouched);

    // v0 should be projected back to X=0.
    assert(abs(m.vertices[0].x) < 1e-6f,
        "on-plane vert should be projected onto X=0 plane");
}
