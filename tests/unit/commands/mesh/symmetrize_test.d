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

// M3b-7 (task 7144) — the pair write rule refuses a HIDDEN partner even when
// every vertex is in the operand (Symmetrize's own mask "all"): the +X member
// would copy onto the -X one, but a hidden partner is not written (task 0613
// R3, kept inside `mirrorStepFor`). The control row proves the copy is live.
unittest {
    Mesh mk() {
        Mesh m;
        m.addVertex(Vec3( 0.0f, 0.0f, 0.0f));   // 0 seam
        m.addVertex(Vec3( 0.0f, 1.0f, 0.0f));   // 1 seam
        m.addVertex(Vec3( 0.6f, 0.5f, 0.0f));   // 2 +X (drifted off 0.5)
        m.addVertex(Vec3(-0.5f, 0.5f, 0.0f));   // 3 -X partner
        m.addFace([0u, 2u, 1u]);
        m.addFace([0u, 1u, 3u]);
        m.buildLoops();
        m.syncSelection();
        return m;
    }
    SymmetryPacket sp;
    sp.enabled = true; sp.axisIndex = 0; sp.epsilonWorld = 0.2f; sp.baseSide = +1;
    sp.planeNormal = Vec3(1, 0, 0); sp.planePoint = Vec3(0, 0, 0);
    {
        auto m = mk();
        rebuildPairing(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);
        assert(sp.pairOf[2] == 3, "rig: v2 must pair with v3");
        auto sel = new bool[](4); sel[] = true;
        auto t = new bool[](4);
        applySymmetryMirror(&m, sp, sel, t);
        assert(m.vertices[3].x < -0.55f, "control: the +X member's copy must reach the partner");
    }
    {
        auto m = mk();
        rebuildPairing(m, sp, sp.pairOf, sp.onPlane, sp.vertSign);
        m.setFaceHidden(1, true);
        assert(m.isVertexHidden(3) && !m.isVertexHidden(2), "rig: v3 hidden, v2 visible");
        auto sel = new bool[](4); sel[] = true;
        auto t = new bool[](4);
        applySymmetryMirror(&m, sp, sel, t);
        assert(m.vertices[3].x == -0.5f && !t[3], "symmetrize wrote a HIDDEN partner");
    }
}
