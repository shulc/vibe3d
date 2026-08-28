module commands.mesh.merge;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : MeshEditScope;
import mesh_edit_delta : MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;
import selection_product : repointToFaces;

/// Merge selected adjacent faces into one polygon per connected group by
/// dissolving EVERY interior edge shared by two selected faces, regardless
/// of coplanarity (selection is the only criterion).
///
/// Differs from `mesh.detriangulate` in three ways:
///   - No coplanarity criterion: non-coplanar adjacent faces are merged.
///   - No whole-mesh fallback: an empty selection is a no-op (returns false).
///   - Selection is re-pointed at the merged polygon only after a successful
///     merge, never on a no-op (task 1180 — it used to be cleared outright).
///
/// Requires Polygons edit mode with at least one selected face. Non-adjacent
/// or empty selections return false without mutating the mesh or clearing
/// the selection (no undo entry recorded).
///
/// v1 limitations (inherited from `removeEdgesByMask`): collinear 2-valent
/// boundary vertices on the merged n-gon are NOT removed (e.g. two coplanar
/// quads sharing one edge merge to a 6-corner n-gon, not a 4-corner rect).
/// Concave / non-coplanar / non-simply-connected (holed) selections produce
/// a single boundary walk that may be non-planar or self-intersecting.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-d; the whole-mesh
/// `MeshSnapshot` is gone. `mergeFacesByMask` routes through
/// `Mesh.removeEdgesByMask`, which already records its own `RemoveFaces` +
/// `AddFaces` pair, so this migration arms nothing.
///
/// THE SELECTION IS `DenseSelectionUndo`, and it is load-bearing rather than a
/// belt: `repointToFaces` opens with `repointToNothing`, which clears ALL
/// THREE domains before re-pointing at the product — so after the revert there
/// is nothing left in the mesh for an index-keyed re-derive to read.
///
/// WHAT IS INERT ON THIS PATH: no weld runs here, so the edge-set MERGE record
/// (task 2310) and the Point-domain map payload (task 2330) on
/// `Kind.RemoveVerts` are never exercised, and this class's green cell says
/// nothing about either.
class MeshMergeFaces : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate()    onTopologyChange;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.mergeFaces"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;

        // Step 1: require a live pipe subject.
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // Step 2: gate — must be in Polygons mode with at least one selected face.
        // Return false before any snapshot or side-effect.
        if (editMode != EditMode.Polygons) return false;
        if (!mesh.hasAnySelectedFaces())   return false;

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (recorded_) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kMergeScope);
                rw = runKernel(ed);
                ed.close();
            }
            return rw != 0;
        }

        // Step 3: the dense selection image for undo, taken BEFORE the batch
        // opens.
        preSel_.capture(*mesh);

        // TASK 1903 STAGE L10-P0 gave this command its first `MeshEditBatch`
        // (axis 0, the commit seam: the kernel and the re-point each stamped
        // and delivered on their own before it). STAGE L10-d makes it
        // RECORDING — axis 2, the undo.
        //
        // THE BATCH CLOSES BEFORE THE ROLLBACK, deliberately: the refusal path
        // must leave the process in the state §S-6 describes — no history
        // entry, no leaked frame, `changeBus.batchLeaks` unmoved. Closing
        // first is the spelling that says so; leaving the rollback inside
        // would work today (the depth counter is at module scope) and would be
        // one refactor away from not working.
        size_t dissolved;
        {
            auto ed = MeshEditBatch(*mesh, kMergeScope);
            dissolved = runKernel(ed);
            delta_ = ed.close();
        }

        // Step 5, and THE POST-CLOSE RULING (§S-6, ruling Q-K6).
        // `dissolved == 0` — a non-adjacent or disjoint selection — is this
        // class's GIGO case. The kernel can have mutated before deciding it
        // dissolved nothing, so the partial edit is replayed BACKWARDS and
        // every image dropped, which is what the deleted `snap.restore` did.
        // The second arm behind the same `false` — mutated, recorded nothing —
        // ticks `changeBus.emptyDeltaOverMutation` and is NOT rolled back:
        // there is nothing to replay, and re-imposing the pre-op selection
        // over a mesh whose arrays have already moved would resize the mark
        // arrays back to the pre-op length.
        if (!acceptRecordedEdit(dissolved, delta_)) {
            if (dissolved == 0) {
                delta_.revert(*mesh);
                preSel_.restore(*mesh);
            }
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }

        // Step 6: topology changed — drop active tool.
        if (onTopologyChange !is null) onTopologyChange();
        recorded_ = true;
        return true;
    }

    private enum uint kMergeScope =
        MeshEditScope.Geometry | MeshEditScope.Marks;

    /// Steps 4 and 7-9, written once so the recording run and the redo run
    /// cannot drift.
    private size_t runKernel(ref MeshEditBatch ed)
    {
        // Step 4: run the kernel.
        immutable size_t dissolved = ed.mergeFacesByMask(mesh.selectedFaces);

        if (dissolved != 0) {
            // Step 7: re-point the selection at the PRODUCT — the merged
            // face(s) (task 1180). `resetSelection` is kept for its RESIZE
            // half (the face arrays shrank under us) and for the clear; the
            // kernel then names the merged polygons it appended, which is what
            // the reference leaves selected. Before 1180 this step ended at
            // the clear, and the merged polygon — the whole result of the
            // command — was selected by nothing.
            ed.resetSelection();
            repointToFaces(mesh, mesh.dissolveProductFaces());

            // Steps 8-9: notify bus + refresh GPU/caches.
            // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`: this is
            // the command's LAST mesh publisher, and a command's tail must
            // DELIVER. Inside the batch it defers and `close()` makes it.
            ed.publishChange(MeshEditScope.Geometry);
        }
        return dissolved;
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
