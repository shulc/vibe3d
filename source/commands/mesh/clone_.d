module commands.mesh.clone_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Single-copy placement — duplicate the selected faces (or the whole mesh
/// when nothing is selected) and offset the copy by `offset`.
///
/// Distinct from `mesh.array` in two ways:
///   - `count` is fixed at 2 (one original + exactly one copy).
///   - `weld` is pinned to 0.0f so a zero-offset clone keeps the coincident
///     copy rather than welding it back into the original.  This is the only
///     thing distinguishing `mesh.clone` from a careless `mesh.array{count:2}`
///     call, and the reason the dedicated command + the zero-offset test exist.
///
/// Edit-mode-orthogonal: reads the face selection (empty ⇒ whole-mesh
/// fallback, same as mesh.array / mesh.mirror).  Interactive tools that
/// want a selection-required policy gate upstream in the tool handler.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L6-a; the whole-mesh
/// `MeshSnapshot` is gone.
///
/// THE `weld = 0` PIN IS LOAD-BEARING FOR THE UNDO TOO, not only for the
/// geometry. It is what makes `arrayFaces`' weld branch unreachable from this
/// command, so this class — with `mesh.duplicate` — is one of the only two
/// members of the family whose op-log is `[AddVerts, AddFaces]` and NOTHING
/// ELSE. That is what makes it the family's UNCONDITIONAL witness for
/// `Mesh.recordBulkAppendRound`: the three welding members emit a
/// `[MeshMapDelta, FaceReindex, RemoveVerts, Reindex]` tail when their weld
/// fires, so a bug in the append publisher shows up there as a partial restore
/// that reads like the weld's known residual. Here there is no weld to blame.
/// Relaxing the pin would silently move this cell onto the weld publisher; the
/// parity reader asserts the zero-offset behaviour the pin produces
/// (`tests/unit/undo_parity_l6_test.d`).
///
/// WHAT IS INERT ON THIS PATH: with no weld there is no `compactUnreferenced`,
/// so `Kind.RemoveVerts` never appears and neither of its payloads — the
/// set-mask half (stage L5-b) nor the Point-domain map-value half (task 2330)
/// — is exercised here at all.
class MeshClone : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;

    private Vec3 offset_ = Vec3(1, 0, 0);

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.clone"; }
    override string label() const { return "Clone"; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kDuplicateEditScope;
    }

    /// True iff this instance actually stored an operation-log delta — see
    /// `MeshDelete.isOperationInverse` for why this is not `return true;`.
    override bool isOperationInverse() const { return recorded_; }

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

    override Param[] params() {
        return [
            Param.vec3_("offset", "Offset", &offset_, Vec3(1, 0, 0)),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // Build face mask — empty selection ⇒ whole mesh (same convention
        // as mesh.array / mesh.mirror).
        // L1 funnel (task 0613, S5): selected faces, else every VISIBLE face.
        bool[] mask = mesh.operandFaceMask();

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS and keep the FIRST delta rather than record a second one
        // over it.
        if (recorded_) {
            size_t ri;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kDuplicateEditScope);
                ri = ed.arrayFaces(mask, 2, offset_, 0.0f);
                ed.close();
            }
            return ri != 0;
        }

        preSel_.capture(*mesh);

        // weld=0 PINNED — a zero-offset clone must keep the coincident copy
        // rather than collapsing it back to the original (the default
        // array weld of 0.001 would do that).
        size_t inserted;
        {
            auto ed = MeshEditBatch(*mesh, kDuplicateEditScope);
            inserted = ed.arrayFaces(mask, 2, offset_, 0.0f);
            delta_ = ed.close();
        }
        if (!acceptRecordedEdit(inserted, delta_)) {
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;
        return true;
    }

    override bool revert() {
        if (!recorded_) return false;
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
        return true;
    }
}
