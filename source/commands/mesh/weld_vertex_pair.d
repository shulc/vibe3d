module commands.mesh.weld_vertex_pair;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import change_bus : MeshEditScope;
import mesh_edit_delta : MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Weld vertex `source` into vertex `target`: source is removed and its
/// incident faces are rewritten to reference `target`. The surviving vertex
/// sits at `target`'s original position (target-position rule).
///
/// Reuses mesh.weldVertexPair. Returns false (status:error) when the kernel
/// returns 0: same index, OOB index, shared-face (would yield a self-touching
/// polygon), or both-faceless (both vertices unreferenced by any face).
///
/// Params (injected via /api/command JSON or injectParamsInto):
///   source  — vertex index to remove (the "drop" vertex)
///   target  — vertex index to survive at (the "keep" vertex)
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-b; the whole-mesh
/// `MeshSnapshot` is gone. This class reaches the SAME tail `vert.merge` does
/// — `Mesh.applyVertexRemapAndRebuild`, armed at Stage L10-P2 — through a
/// different door: `weldVertexPairs` rather than `weldVerticesByMask`. That is
/// why the parity fixture carries a cell for each, and why a red on only one
/// of the two names the door rather than the tail.
///
/// THE SELECTION IS `DenseSelectionUndo`, not this file's own belt. The weld's
/// tails (`clearFaceSelectionResize`, `clearEdgeSelectionResize`) run AFTER
/// the face rewrite, so no face entry in the op-log can describe them; and the
/// edge half has to be re-keyed by ENDPOINTS because `finalize`'s
/// `rebuildEdges` hands the reverted mesh a fresh edge index space.
class MeshWeldVertexPair : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta. It discriminates FIRST RUN from
    /// REDO (`CommandHistory.redo` calls `apply()` again, and a second
    /// recording run would record a second delta over the first), and it is
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;

    private int source_ = -1;
    private int target_ = -1;

    this(Mesh* mesh, ref View view, EditMode editMode)
    {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.weldVertexPair"; }
    override string label() const { return "Weld Vertex Pair"; }

    override Param[] params() {
        return [
            Param.int_("source", "Source Vertex", &source_, -1),
            Param.int_("target", "Target Vertex", &target_, -1),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (source_ < 0 || target_ < 0)      return false;
        if (source_ == target_)               return false;
        if (cast(uint)source_ >= mesh.vertices.length) return false;
        if (cast(uint)target_ >= mesh.vertices.length) return false;

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (recorded_) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh,
                              MeshEditScope.Geometry | MeshEditScope.Marks);
                rw = ed.weldVertexPair(cast(uint)target_, cast(uint)source_);
                ed.close();
            }
            return rw != 0;
        }

        // The dense selection image, taken BEFORE the batch opens.
        preSel_.capture(*mesh);

        // TASK 1903 STAGE L10-P0 gave this command its first `MeshEditBatch`
        // (axis 0: the COMMIT SEAM — the weld commits several times on its way
        // through, and inside a frame they defer and stamp ONCE at `close()`).
        // STAGE L10-b makes it RECORDING, which is axis 2: the undo.
        //
        // THE RAII HANDLE, not `beginEditBatch`/`endEditBatch` + a
        // `scope(failure)`: the unwind path is then the destructor's, which
        // pops the frame WITHOUT stamping and ticks `changeBus.batchLeaks` —
        // the suite asserts that stays 0.
        size_t welded;
        {
            auto ed = MeshEditBatch(*mesh,
                          MeshEditScope.Geometry | MeshEditScope.Marks);
            welded = ed.weldVertexPair(cast(uint)target_, cast(uint)source_);
            delta_ = ed.close();
        }
        // THE POST-CLOSE RULING (§S-6, ruling Q-K6). `welded == 0` is the
        // honest refusal this command has always made — and it needs NO
        // rollback for the reason the deleted comment gave: a
        // `weldVertexPair` that welds nothing has mutated nothing. The second
        // arm — mutated but recorded nothing — is the one `acceptRecordedEdit`
        // adds, and it ticks `changeBus.emptyDeltaOverMutation` instead of
        // passing silently.
        if (!acceptRecordedEdit(welded, delta_)) {
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;
        return true;
    }

    override bool revert() {
        // An instance whose `evaluate` refused holds an empty delta and a
        // nulled selection image; replaying it would run `preSel_` over a mesh
        // it was never sized against. Answering false here is correct ONLY
        // because the funnel records no history entry for a refused forward.
        if (!recorded_) return false;
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
        return true;
    }

private:
}
