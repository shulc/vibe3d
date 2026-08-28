module commands.mesh.duplicate_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Duplicate the currently selected faces in place. Verts shared by
/// multiple selected faces are cloned once; new faces reference the
/// cloned verts; the selection is switched to the new copies.
///
/// Polygons-mode-only: in vibe3d's face-derived edge model, duplicating
/// vert / edge selections produces orphan topology with no useful
/// downstream semantics, so non-Polygons modes are rejected.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L6-a; the whole-mesh
/// `MeshSnapshot` is gone.
///
/// THIS CLASS IS WHY STAGE L6 NEEDED A PUBLISHER RATHER THAN AN ARMING.
/// `Mesh.duplicateSelectedFaces` has no weld and no compaction, so before
/// `Mesh.recordBulkAppendRound` it reached NO tracker hook of any kind: a
/// recording batch around it closed with an EMPTY op-log over a mesh that
/// really had been duplicated. `acceptRecordedEdit` refuses that pairing by
/// design, so the migration WITHOUT the publisher would not have produced a
/// bad undo — it would have produced `status:error` over a changed document
/// with no history entry at all. That is the worst outcome in the family, and
/// nothing in the three welding members can produce it (they at least emit
/// `[MeshMapDelta, FaceReindex, RemoveVerts, Reindex]` when their weld fires,
/// so "the log is non-empty" — the cheapest thing anyone asserts — is green on
/// them and says nothing).
///
/// NOTHING IS ARMED FOR IT, and the §5.5 row's `arrayFacesGrid` arming is not
/// merely unnecessary here but unreachable: that kernel's only production
/// callers are the interactive Array TOOL (`tools/alignment/array_tool.d`),
/// which is stage M's, and Stage K measured arming it to make the revert WORSE.
///
/// WHAT IS INERT ON THIS PATH, said so a green is not read as coverage: no
/// weld and no `compactUnreferenced` run here, so `Kind.RemoveVerts` never
/// appears and NEITHER of its payloads — the set-mask half (stage L5-b) nor
/// the Point-domain map-value half (task 2330) — is exercised by this command
/// at all.
class MeshDuplicate : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.duplicate"; }
    override string label() const { return "Duplicate Selected"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Polygons];
    }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kDuplicateEditScope;
    }

    /// True iff this instance actually stored an operation-log delta.
    ///
    /// NOT `return true;`, for `MeshDelete.isOperationInverse`'s reason
    /// verbatim: a constant would be a claim about instances the class can
    /// genuinely be in — constructed-but-not-applied, or refused — where no
    /// delta exists. `undoRecorded()` is `true` for every instance that reaches the
    /// history stack, because `acceptRecordedEdit` guarantees a non-empty
    /// delta before it is set.
    override bool isOperationInverse() const { return undoRecorded(); }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log. The cells assert a
        /// KIND SEQUENCE and never a length: stage J made the
        /// `[MeshMapDelta, <face entry>]` adjacency contractual, and an
        /// interposed entry unpairs the corner carry SILENTLY while the
        /// geometry still round-trips — a length check cannot see that.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons)        return false;
        if (mesh.faces.length == 0)               return false;
        if (!mesh.hasAnySelectedFaces())          return false;

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (undoRecorded()) {
            size_t rc;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kDuplicateEditScope);
                rc = ed.duplicateSelectedFaces();
                ed.close();
            }
            return rc != 0;
        }

        // The dense selection image, taken BEFORE the batch opens. The kernel
        // deselects every original and selects the copies, and a delta replay
        // gives the reverted mesh a FRESH edge index space out of `finalize`'s
        // `rebuildEdges` — which is why the edge half of this image is
        // ENDPOINT-keyed rather than index-keyed.
        preSel_.capture(*mesh);

        // TASK 1903 Stage L6-P0 opened this batch (unrecorded, snapshot kept)
        // so the kernel's internal `commitChange` stopped being an UNBATCHED
        // geometry commit; L6-a makes it RECORDING, which is what gives the
        // op-log its reader. Scoped to the kernel call ALONE (§4.4a): the
        // `cloned == 0` rejection below must not run inside the frame.
        //
        // No `scope(failure)`: `MeshEditBatch.~this` pops the frame during
        // unwinding and ticks `changeBus.batchLeaks`, which the suite asserts
        // stays 0.
        size_t cloned;
        {
            auto ed = MeshEditBatch(*mesh, kDuplicateEditScope);
            cloned = ed.duplicateSelectedFaces();
            delta_ = ed.close();
        }
        // THE POST-CLOSE RULING (§S-6). `cloned == 0` is the honest refusal
        // this command has always made and it needs no rollback — a
        // `duplicateSelectedFaces` that duplicated nothing mutated nothing.
        // The OTHER arm — a non-empty mutation with an EMPTY delta — is what
        // `Mesh.recordBulkAppendRound` exists to make unreachable here; if it
        // ever fires, `changeBus.emptyDeltaOverMutation` ticks and both gates
        // hold that counter at 0.
        if (!acceptRecordedEdit(cloned, delta_)) {
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        noteUndoRecorded();
        return true;
    }

    protected override void revertImpl() {
        // An instance whose `evaluate` refused holds an empty delta and a
        // nulled selection image; replaying it would run `preSel_` over a mesh
        // it was never sized against. Answering false here is correct ONLY
        // because the funnel records no history entry for a refused forward.
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
    }
}
