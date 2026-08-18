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
///
/// AND an EMPTY selection means THE WHOLE MESH in Polygons mode (task 1210,
/// ledger rows 13 + 18, frozen in `tests/fixtures/empty_selection_whole_mesh.json`):
/// with nothing selected the reference copies everything and the following
/// paste duplicates the mesh. Set-material is the second, independent witness
/// of the same law. The operand comes from `Mesh.operandFaceMask()`, so
/// "everything" means every VISIBLE face, consistent with the ~40 commands
/// already on that funnel. That law is NOT extended to vertex mode: the
/// reference was never driven with an empty selection there.
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
        // Empty selection => the whole visible mesh, in POLYGONS mode
        // (task 1210, ledger rows 13+18). Vertex mode keeps its explicit
        // guard: the reference was measured copying a vertex SELECTION
        // (row 19, task 1200), never an empty one, so the whole-mesh law is
        // unmeasured there and is deliberately not extended.
        if (editMode == EditMode.Polygons) {
            // No syncSelection() here on purpose: this command is read-only,
            // and operandFaceMask is const and bounds-safe against a marks
            // array that has not caught up with faces.
            geometryClipboard = GeometryClip.fromFaceMask(*mesh, mesh.operandFaceMask());
        } else if (editMode == EditMode.Vertices) {
            if (!mesh.hasAnySelectedVertices()) return false;
            geometryClipboard = GeometryClip.fromSelectedVertices(*mesh);
        } else {
            return false;   // Edges -- unmeasured, see the class doc
        }
        return !geometryClipboard.empty;
    }

    // Never called: CmdFlags.None means the command is not recorded.
}
