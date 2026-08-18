module commands.mesh.copy_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import geometry_clipboard : geometryClipboard, GeometryClip;

/// Snapshot the current selection into the global geometry clipboard: the
/// selected FACES in Polygons mode, the selected VERTICES in Vertices mode.
///
/// Read-only: the mesh is NOT modified, so no undo entry is created
/// (`cmdFlags = CmdFlags.None`).
///
/// Task 1200 (ledger row 19): vertex-mode copy used to refuse, on the reasoning
/// that a vertex selection "produces no standalone topology in vibe3d's
/// face-derived edge model". It produces standalone POINTS, which is what the
/// reference copies and what its paste puts back — four free vertices from four
/// selected ones. `tests/fixtures/copy_vertex_mode.json` freezes the cell.
///
/// EDGES mode still refuses, and that is an absence of measurement, not a
/// decision: the reference was never driven with an edge selection here. When
/// it is, this is the branch to extend — an edge clip would presumably carry
/// its endpoints, but "presumably" is not a fixture.
class MeshCopy : Command, Operator {
    mixin OperatorActrCommon;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.copy"; }
    override string label() const { return "Copy"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons, EditMode.Vertices];
    }

    // CmdFlags.None → not recorded in the undo stack; read-only operation.
    override CmdFlags cmdFlags() const { return CmdFlags.None; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode == EditMode.Polygons) {
            if (!mesh.hasAnySelectedFaces()) return false;
            geometryClipboard = GeometryClip.fromSelectedFaces(*mesh);
        } else if (editMode == EditMode.Vertices) {
            if (!mesh.hasAnySelectedVertices()) return false;
            geometryClipboard = GeometryClip.fromSelectedVertices(*mesh);
        } else {
            return false;   // Edges — unmeasured, see the class doc
        }
        return !geometryClipboard.empty;
    }

    // Never called: CmdFlags.None means the command is not recorded.
}
