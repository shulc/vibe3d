module commands.mesh.quadruple;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : MeshEditScope;
import mesh_edit_delta : MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Pair adjacent triangles into convex coplanar quads where possible.
/// The accept predicate requires BOTH coplanarity (dot(nA,nB) > 0.999) and
/// convexity of the merged quad — this prevents cross-face bent-quad merges
/// that would appear geometrically convex in the projected plane but span
/// two non-coplanar mesh faces (e.g. after `mesh.triple` on a cube, every
/// cube edge is shared by two triangles; without the coplanarity gate the
/// greedy matcher could pick cube edges over the intra-face diagonal).
///
/// Selection-aware (Polygons mode + non-empty selection): only the selected
/// faces participate; otherwise the whole active layer.
/// Post-op selection is cleared (no clean origin map through union-find).
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-d; the whole-mesh
/// `MeshSnapshot` is gone. `quadrupleFacesByMask` is one of three kernels that
/// route through `Mesh.removeEdgesByMask`, which already records its own
/// `RemoveFaces` + `AddFaces` pair — so this migration arms nothing and the
/// three land as one shape.
///
/// IT NO LONGER ANSWERS `ok` OVER A NO-OP, and that is a fix this migration
/// FORCED rather than chose. The kernel has always returned a count and this
/// command discarded it. A delta cannot represent "true over a no-op": the
/// post-close ruling is `acceptRecordedEdit`, and feeding it a fabricated
/// non-zero `affected` over an empty delta ticks
/// `changeBus.emptyDeltaOverMutation`, which both gate lanes assert stays 0.
/// So the count is read, `evaluate` returns false on 0, and the funnel answers
/// `status:error` with no history entry — the contract CLAUDE.md states, and
/// the shape three earlier commands in this track were fixed for.
///
/// WHAT IS INERT ON THIS PATH: no weld runs here, so the edge-set MERGE record
/// (task 2310) and the Point-domain map payload (task 2330) on
/// `Kind.RemoveVerts` are never exercised, and this class's green cell says
/// nothing about either.
class MeshQuadruple : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate()    onTopologyChange;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.quadruple"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        bool polygonMode  = editMode == EditMode.Polygons;
        bool hasSelection = polygonMode && mesh.hasAnySelectedFaces();

        // Mode-gated fallback — visibleFaceMask(), not operandFaceMask()
        // (task 0613, S5; see the helper's doc comment in mesh.d).
        bool[] mask = hasSelection
            ? mesh.selectedFaces
            : mesh.visibleFaceMask();

        // TASK 1903 STAGE L10-P0 (axis 0). An UNRECORDED `MeshEditBatch` at
        // the command boundary. Nine of this stage's thirteen commands opened
        // none at all, so every `commitChange` their kernels made stamped the
        // mesh version and delivered on its own — `changeBus`'s
        // `unbatchedGeometryCommits` counted each one. Inside the batch they
        // defer into the frame and stamp ONCE at `close()`.
        //
        // UNRECORDED, not recording: axis 0 is the COMMIT SEAM and moves no
        // undo. Undo here is still the whole-mesh `MeshSnapshot` above.
        //
        // The `publishChange` tail sits INSIDE the batch as of this stage —
        // with a frame open the delivery defers and `close()` makes it, which
        // is the same one delivery by a structural route.
        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (undoRecorded()) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kQuadrupleScope);
                rw = runKernel(ed, mask);
                ed.close();
            }
            return rw != 0;
        }

        preSel_.capture(*mesh);

        // RECORDING as of Stage L10-d — axis 2, the undo. Stage L10-P0 had
        // already given this command the batch (axis 0, the commit seam).
        size_t changed;
        {
            auto ed = MeshEditBatch(*mesh, kQuadrupleScope);
            changed = runKernel(ed, mask);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING (§S-6, ruling Q-K6). `changed == 0` is the
        // refusal this command SHOULD always have made — see the class's doc
        // comment — and it needs no rollback: the kernel touched nothing, and
        // `resetSelection` only resizes over what the kernel produced.
        if (!acceptRecordedEdit(changed, delta_)) {
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        // AFTER the accept, not before it: dropping the active tool is a
        // visible side effect and §S-6 asks a refusal to leave none.
        // `mesh.mergeFaces` already fires its delegate here for that reason.
        if (onTopologyChange !is null) onTopologyChange();
        noteUndoRecorded();
        return true;
    }

    /// The kernel plus its selection tail, written once so the recording run
    /// and the redo run cannot drift. Returns the kernel's own count — the
    /// value this command used to discard.
    private static size_t runKernel(ref MeshEditBatch ed, bool[] mask)
    {
        immutable size_t changed = ed.quadrupleFacesByMask(mask);
        ed.resetSelection();
        ed.publishChange(MeshEditScope.Geometry);
        return changed;
    }

    private enum uint kQuadrupleScope =
        MeshEditScope.Geometry | MeshEditScope.Marks;

    protected override void revertImpl() {
        // An instance whose `evaluate` refused holds an empty delta and a
        // nulled selection image; replaying it would run `preSel_` over a mesh
        // it was never sized against. Answering false here is correct ONLY
        // because the funnel records no history entry for a refused forward.
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
    }
}

