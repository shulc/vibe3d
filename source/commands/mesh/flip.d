module commands.mesh.flip;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo : RecordedUndo;
import commands.mesh.map_edit_undo : runMapEdit, revertMapEditEmptyOk;

/// Reverse the winding order of selected polygons, inverting their normals.
/// Empty face-selection flips every face of the active layer (matching the
/// `mesh.delete` empty-selection convention). Always operates in the face
/// domain regardless of the current edit mode — editMode is NOT branched on
/// (R3: flip is a polygon-domain operation only).
///
/// TASK 1903 STAGE L2-a — UNDO IS THE OPERATION-LOG DELTA. R4's old note
/// ("snapshot-only path; MeshEditDelta has no winding-reverse op today") is
/// retired: `Mesh.flipFacesByMask` now routes its winding writes through
/// `Mesh.setFaceWindings`, so a recording batch around it comes back with
/// `[MeshMapDelta, ReshapeFaces]` and its reverse restores both the winding
/// and the per-corner plane.
///
/// WHY THIS COMMAND WENT FIRST OF THE TWELVE, and it is the one thing to keep
/// in mind before touching it: **an equal-arity corner PERMUTATION is the only
/// L2 edit that leaves every count byte-identical.** A revert that puts the
/// winding back but not the corner order leaves `vertices`, `faces`, every
/// mark word, every material/part value and every count exactly right, and is
/// wrong only in the per-corner (UV) map. No geometry assertion, no count
/// assertion and no `opInverse` bit can see that — only a map-plane compare
/// can, which is why `tests/unit/flip_and_spin_delta_test.d` asserts the two
/// side by side in ONE cell.
class MeshFlip : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    /// The forward SUCCEEDED. NOT derivable from `undo_`/`snap` — see
    /// `revert()` below, and `map_edit_undo.revertMapEditEmptyOk`'s note on
    /// why "no delta and no snapshot" is two states with opposite answers.
    private bool             applied_;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo. Every RESULT-shaped
        /// assertion about this command is green over a deleted recorder,
        /// because the hatch's snapshot restores every plane correctly; only
        /// reading the op-log is not.
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.flip"; }
    override string label() const { return "Flip Polygons"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    /// True iff this instance actually stored an operation-log delta. A cheap
    /// tell and NOT the observable: it reports a bit the command sets about
    /// itself, so a class whose delta is empty answers `false` honestly but a
    /// class whose delta is WRONG still answers `true`.
    override bool isOperationInverse() const { return undo_.armed(); }

    // The kernel mutation: always face-domain, never editMode-dependent (R3).
    private size_t runKernel(ref MeshEditBatch ed) {
        return ed.mesh.flipFacesByMask(ed.mesh.operandFaceMask());
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // THE REFUSAL IS ATOMIC ALREADY, and that is why nothing is hoisted
        // here. `flipFacesByMask` answers 0 only on a mask that names no
        // flippable face, and in that case it has written nothing — it returns
        // BEFORE the first winding write. So the kernel below may simply
        // answer false from inside the batch: `runMapEdit` closes the batch,
        // disarms the (empty) delta and `applyImpl` lands no history entry.
        // This command is NOT one of the four that `snap.restore` on a kernel
        // refusal (`polygon_align`, `split_face`, `vertex_split`,
        // `make_polygon` are), so the L8 pre-flight rule costs it nothing.
        applied_ = runMapEdit(mesh, undo_, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed) != 0);
        return applied_;
    }

    override bool revert() {
        // `…EmptyOk`, NOT `revertMapEdit`, and the empty case is REACHABLE
        // here rather than theoretical: `setFaceWindings` drops an IDENTITY
        // write from both the record and the write, and a winding that is its
        // own reverse exists — a face carrying a repeated vertex, `[a, b, a]`,
        // on a mesh the cleanup sweep has not been over. `flipFacesByMask`
        // still counts such a face as flipped (behaviour preserved), so the
        // forward succeeds with an EMPTY delta.
        //
        // Answering `false` there is the regression-0099 shape and the plan's
        // refusal ruling forbids it in as many words: `CommandHistory.undo`
        // discards an entry whose `revert()` answers false AND its whole
        // trailing suffix (`command_history.d`'s `undoStack.length = mi`), so
        // a `false` here does not "decline to undo" — it silently destroys
        // every older entry. The `if (!snap.filled) return false;` this
        // replaces was deleted, not translated.
        return revertMapEditEmptyOk(mesh, undo_, applied_);
    }
}
