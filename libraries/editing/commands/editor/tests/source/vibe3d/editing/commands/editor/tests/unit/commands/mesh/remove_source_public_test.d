module vibe3d.editing.commands.editor.tests.unit.commands.mesh.remove_source_public_test;

import vibe3d.editing.commands.editor.commands.mesh.remove_;
import vibe3d.mesh.edit_replay.mesh_edit_replay : captureSelectedEdgeEnds, restoreSelectedEdgeEnds, apply, revert;

import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.pipeline.contracts.operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;
import vibe3d.mesh.snapshot.snapshot : SelectionSnapshot;
import vibe3d.mesh.edit_log.mesh_edit_delta : MeshEditDelta, MeshEditTracker, MeshEditScope, acceptRecordedEdit;

// ---------------------------------------------------------------------------
// Task 0502 — the SHIPPED COMMANDS, not just the kernel under them.
//
// `mesh.remove` and `mesh.delete` in Edges mode both run
// `removeEdgesByMask` + `dissolveDegree2Verts`, and both tails used to
// re-derive edges[] and vertices[] from faces[] MESH-WIDE. So one edge
// dissolve wiped every bare wire edge and every loose point in the document,
// arbitrarily far from the selection — vibe3d builds both as ordinary
// intermediate retopo state, so this destroyed in-progress work silently.
//
// The kernel unittests in mesh.d pin the primitives. This block pins the
// COMMANDS, through `Command.apply()` — the real dispatch entry — because the
// commands are what the bug was reported against and because the mode
// redirect, the empty-selection fallback and the two-kernel sequence all sit
// between the user and the primitive.
// ---------------------------------------------------------------------------
version (unittest) {
    import vibe3d.editing.commands.editor.commands.mesh.delete_ : MeshDelete;
    import vibe3d.util.math.math : Vec3;

    private enum Vec3 kRemoveTestPoint = Vec3(10, 10, 10);
    private enum Vec3 kRemoveTestWireA = Vec3(20, 0, 0);
    private enum Vec3 kRemoveTestWireB = Vec3(21, 0, 0);

    private int removeTestVertAt(in Mesh m, Vec3 p) {
        foreach (i, ref v; m.vertices)
            if (v.x == p.x && v.y == p.y && v.z == p.z) return cast(int)i;
        return -1;
    }

    private bool removeTestHasWire(in Mesh m, Vec3 a, Vec3 b) {
        immutable int ia = removeTestVertAt(m, a), ib = removeTestVertAt(m, b);
        if (ia < 0 || ib < 0) return false;
        foreach (ref e; m.edges)
            if ((e[0] == ia && e[1] == ib) || (e[0] == ib && e[1] == ia)) return true;
        return false;
    }

    /// A 3x3 grid of quads plus, FAR from it, one loose point and one bare
    /// wire edge. Distance is the point: nothing here is adjacent to the
    /// edited edge, so surviving cannot be an accident of locality.
    private Mesh makeRemoveTestGrid() {
        import vibe3d.mesh.core.mesh : makeGridPlane;
        Mesh m = makeGridPlane(2);
        m.addVertex(kRemoveTestPoint);
        immutable uint w0 = m.addVertex(kRemoveTestWireA);
        immutable uint w1 = m.addVertex(kRemoveTestWireB);
        m.addEdge(w0, w1);
        m.buildLoops();
        m.syncSelection();
        assert(removeTestVertAt(m, kRemoveTestPoint) >= 0, "fixture: the loose point");
        assert(removeTestHasWire(m, kRemoveTestWireA, kRemoveTestWireB),
            "fixture: the bare wire edge");
        return m;
    }
}

unittest { // edge removal leaves unrelated loose geometry alone
    import vibe3d.viewport.camera.view : View;

    foreach (isDelete; [false, true]) {
        Mesh m = makeRemoveTestGrid();
        View view = new View(0, 0, 100, 100);

        // An INTERIOR grid edge — the only kind that dissolves at all.
        immutable uint ei = m.edgeIndex(1, 4);
        assert(ei != uint.max, "setup: the interior grid edge");
        m.selectEdge(cast(int)ei);

        Command cmd = isDelete
            ? cast(Command)new MeshDelete(&m, view, EditMode.Edges)
            : cast(Command)new MeshRemove(&m, view, EditMode.Edges);
        assert(cmd.apply(), "setup: the command must report work done");
        assert(m.faces.length == 3, "setup: the two quads either side merged");

        immutable string who = isDelete ? "mesh.delete" : "mesh.remove";
        assert(removeTestVertAt(m, kRemoveTestPoint) >= 0,
            who ~ " FAILS ON THE OLD BEHAVIOUR: the kernel tail's mesh-wide "
          ~ "compactUnreferenced took a loose point 10 units from the edit");
        assert(removeTestHasWire(m, kRemoveTestWireA, kRemoveTestWireB),
            who ~ " FAILS ON THE OLD BEHAVIOUR: the kernel tail's mesh-wide "
          ~ "rebuildEdges re-derived edges[] from faces[] and wiped a bare wire "
          ~ "edge 20 units from the edit");
    }
}
