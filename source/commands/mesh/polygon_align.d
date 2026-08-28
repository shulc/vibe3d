module commands.mesh.polygon_align;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit;

/// One-shot command that, for each connected island of selected faces,
/// computes the island's area-weighted average plane and orthogonally
/// projects every vertex touched by that island onto the plane —
/// flattening non-planar / tilted selected faces to coplanar.
///
/// Polygons scope only (a plane requires at least one face).  Returns
/// false (no history entry) when not in Polygon mode, no face is
/// selected, or the selection is already planar within the
/// coordinate-scaled threshold.
///
/// **Shared-vertex semantic**: vertices shared between selected and
/// unselected faces are projected; the adjacent unselected faces
/// connected to them are therefore deformed.  Test fixtures should use
/// topologically isolated geometry to get unambiguous residuals.
///
/// TASK 1903 STAGE L2-h — UNDO IS THE OPERATION-LOG DELTA, AND THE KIND IS
/// `Kind.SetPos`, WHICH THIS COMMAND'S ROW IN §5.5 DOES NOT NAME. `mesh.align`
/// adds no vertex, appends no face and reshapes no winding: it PROJECTS
/// pre-existing vertices onto their island's plane. Its row lists
/// `AddVerts`/`AddFaces`/`ReshapeFaces`, which is simply the wrong family — the
/// migration is L0-d's shape (A), one kernel routed through
/// `Mesh.setVertexPositions`.
///
/// NO DENSE SELECTION IMAGE HERE, and that is a difference from the other nine
/// commands of this stage rather than an omission: this one touches no
/// selection plane at all — no repoint, no reset, no `syncSelection` — so the
/// pre-op selection is still there after the forward AND after the reverse.
/// That is L0-d's shape too, and its nine commands carry no selection image
/// either.
class MeshAlign : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.align"; }
    override string label() const { return "Align Polygons"; }

    override MeshEditScope editScope() const { return MeshEditScope.Position; }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (!mesh.hasAnySelectedFaces()) return false;

        // Read the operand mask BEFORE the batch opens: `selectedFaces` is a
        // materialising VIEW.
        auto sel = mesh.selectedFaces;

        // THE REFUSAL IS PRE-FLIGHT AND ATOMIC — VERIFIED, NOT ASSUMED.
        // `alignFacesByMask` computes every displacement into `dScalar` before
        // it writes anything ("compute-before-write", its own comment) and
        // answers 0 from the counting pass over that array, so the
        // `snap.restore(*mesh)` this replaces was rolling back a mutation that
        // cannot happen. Plan §L2.4 listed this command among the four that
        // might need an explicit `delta.revert` on refusal; measured, none of
        // the four does.
        const bool applied_ = runMapEdit(this, mesh, undo_, MeshEditScope.Position,
                              (ref MeshEditBatch ed) => ed.mesh.alignFacesByMask(sel) != 0);
        return applied_;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
    }
}
