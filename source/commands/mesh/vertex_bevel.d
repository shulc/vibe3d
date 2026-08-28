module commands.mesh.vertex_bevel;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Vertex Bevel (one-shot, undoable): for each selected interior-manifold
/// vertex, split every incident edge at distance `amount` and replace the
/// vertex with an N-gon cap through those split points. Vertices-mode only;
/// empty selection ⇒ whole mesh (greedy vertex-disjoint subset); amount=0
/// is a no-op.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L7-d; the whole-mesh
/// `MeshSnapshot` is gone. `mesh_ops/bevel_vertex.bevelVerticesByMask` is
/// ARMED for `Kind.FaceReindex`, and this class is the reason that arming
/// could finally land.
///
/// THE ARMING INVERTS STAGE K'S REFUSAL, AND THE INVERSION IS A MEASUREMENT.
/// Stage K measured this kernel armed on 2026-08-27 and refused it under one
/// stated rule — *do not arm when a VALUE is lost*. Its residual then held
/// three planes that are not Select bits: the bevelled vertex's Point-domain
/// `meshMaps["W"]` value zeroed, its `vertexSetMask` bit cleared, and one
/// `edgeSetMask` entry gone. All three ride `compactUnreferenced`'s
/// `[RemoveVerts, Reindex]` pair, which at the time restored positions and
/// nothing else per vertex — so no `FaceReindex` could ever have carried them
/// and the refusal was right.
///
/// What changed is that OTHER entry. `Kind.RemoveVerts` gained the set-mask
/// payload at stage L5-b and the Point-domain map-value payload at L7-P3
/// (task 2330). Re-measured before arming, three operands, EXACT residual both
/// ways on `makeTaggedGridFull(3)`: the armed revert loses FIVE planes and
/// every one of them is Select-class (`vertexMarks`, `vertexSelectionOrder`,
/// `edgeMarks`, `faceMarks`, `orderCounters`). The weight map, both set masks,
/// the per-corner UV map, every position, every winding and all three counts
/// come back BYTE-IDENTICAL. The row lives in
/// `tests/unit/face_reindex_arming_test.d`'s `bevelVerticesByMask` cell.
///
/// THIS CLASS IS THE SECOND-FAMILY WITNESS FOR BOTH `RemoveVerts` PAYLOADS,
/// and it inherited that job from stage L6 by measurement: no weld in the
/// duplication family ever drops an ORIGINAL vertex, so both payload arms are
/// inert there. Here the chamfer CONSUMES an original that is in a named
/// vertex set and is an endpoint of a named edge-set entry.
/// `tests/unit/undo_parity_l7d_test.d` asserts all three before it compares
/// anything.
///
/// THE EDGE ARM OF `mesh.bevel` IS STILL DECLINED and this class does not
/// change that: `bevelEdgesByMask` rewrites `faces` TWICE under ONE
/// `beginCornerRewrite` handle, so it records one corner payload for two face
/// entries and the reverse zeroes the UV map. That is the corner half, a
/// different blocker from the value half this class closed, and the two halves
/// of the bevel family are separable — see `commands/mesh/bevel.d`.
class MeshVertexBevel : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;
    private float              amount_ = 0.2f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.vertexBevel"; }
    override string label() const { return "Vertex Bevel"; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kBevelVertexEditScope;
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
            Param.float_("amount", "Amount", &amount_, 0.2f),
        ];
    }

    void setAmount(float v) { amount_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Vertices) return false;
        if (mesh.vertices.length == 0) return false;

        auto mask = mesh.operandVertexMask(EditMode.Vertices);

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out, INCLUDING the `faceReindexScope()`
        // arm inside the kernel, which captures a null tracker and does
        // nothing — and keep the FIRST delta rather than record a second one
        // over it.
        if (recorded_) {
            size_t rn;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kBevelVertexEditScope);
                rn = ed.bevelVerticesByMask(mask, amount_);
                ed.close();
            }
            return rn != 0;
        }

        // The dense selection image, taken BEFORE the batch opens. The kernel's
        // tail clears the vertex selection outright and re-masks the face marks
        // word, and a delta replay gives the reverted mesh a FRESH edge index
        // space out of `finalize`'s `rebuildEdges` — which is why the edge half
        // of this image is ENDPOINT-keyed.
        preSel_.capture(*mesh);

        // Task 1903 Stage E4 opened this batch at the command boundary (§4.1)
        // because `bevelVerticesByMask` is a free function over
        // `ref MeshEditBatch`. E4's comment here said it was UNRECORDED "so a
        // RECORDING batch would build a full op-log that nothing reads and
        // `close()` would drop"; stage L7-d gives that op-log its reader, so
        // the constructor is the recording one.
        size_t n;
        {
            auto ed = MeshEditBatch(*mesh, kBevelVertexEditScope);
            n = ed.bevelVerticesByMask(mask, amount_);
            delta_ = ed.close();
        }
        // THE POST-CLOSE RULING (§S-6). `n == 0` is the honest refusal this
        // command has always made — no accepted vertex, or `amount` too small
        // to split anything — and it needs no rollback, because a chamfer that
        // processed nothing mutated nothing.
        if (!acceptRecordedEdit(n, delta_)) {
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
}
