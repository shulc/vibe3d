// Module unittests for `tools.transform.transform`, moved verbatim out of source/tools/transform/transform.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.transform.transform_test;

import tool;
import operator : VectorStack;
import mesh;
import editmode;
import seltype : SelType;
import math : Vec3, Viewport, AimViewport, aimSpace;
import change_bus : MeshEditScope;
import command : Command;
import command_history : CommandHistory;
import commands.mesh.vertex_edit : MeshVertexEdit;
import snap : SnapResult;
import toolpipe.packets : FalloffPacket, FalloffType, SymmetryPacket, SnapPacket, SubjectPacket;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.stages.snap : SnapStage;
import toolpipe.stages.symmetry : SymmetryStage;
import falloff : evaluateFalloff;
import symmetry : applySymmetryMirror;
import pipe_gizmo_host : PipeGizmoHost;
import document : primaryModelSpace;
import tools.transform.transform;

// ---------------------------------------------------------------------------
// THE MOVING SET IS THE OPERAND (task 7144; the old helper returned the processed
// verts UNION their mirror partners, and is deleted). Under the
// captured law a transform writes ONLY its operand (gap 316): the mirror pass
// writes a partner only when the partner is itself in the operand. So the
// exclusion snapping needs — "every vertex this drag moves" — is the processed
// list. CROSS-CHECK against the pass itself: run `applySymmetryMirror` and diff
// the mesh; every written index must be processed. Population floor: the pass
// wrote the in-operand partner of a pair, so the loop is not vacuous.
// ---------------------------------------------------------------------------
unittest {
    import std.algorithm : canFind;
    Mesh m;
    m.vertices = [
        Vec3( 0.30f, 0, 0),   // 0 — processed (+X member of a pair)
        Vec3(-0.30f, 0, 0),   // 1 — its partner, ALSO processed
        Vec3( 0.90f, 0, 0),   // 2 — processed, partner 3 NOT processed
        Vec3(-0.90f, 0, 0),   // 3 — static
    ];
    SymmetryPacket sym;
    sym.enabled     = true;
    sym.axisIndex   = 0;
    sym.planePoint  = Vec3(0, 0, 0);
    sym.planeNormal = Vec3(1, 0, 0);
    sym.pairOf      = [1, 0, 3, 2];
    sym.onPlane     = [false, false, false, false];
    sym.vertSign    = [+1, -1, +1, -1];
    sym.baseSide    = +1;
    immutable int[] processed = [0, 1, 2];
    auto pre = m.vertices.dup;
    m.vertices[0] = Vec3(0.45f, 0.1f, 0);   // the drag moved the operand
    m.vertices[2] = Vec3(1.05f, 0.1f, 0);
    auto afterDrag = m.vertices.dup;
    bool[] procMask = new bool[](4);
    foreach (vi; processed) procMask[vi] = true;
    bool[] touched = new bool[](4);
    applySymmetryMirror(&m, sym, procMask, touched);
    int wrote;
    foreach (i; 0 .. m.vertices.length) {
        if (m.vertices[i] == afterDrag[i]) continue;
        ++wrote;
        assert(processed.canFind(cast(int)i),
            "the mirror pass wrote a vertex outside the operand — the moving "
            ~ "set is no longer the processed list, and snapping would offer "
            ~ "the drag its own geometry");
    }
    assert(wrote == 1, "floor: the pass must copy the in-operand pair partner (1 write)");
    assert(m.vertices[3] == pre[3], "the unselected partner of vertex 2 was written");
}
