module commands.mesh.triple;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import change_bus : MeshEditScope;
import mesh_edit_delta : MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Split every selected (or whole-mesh) n-gon into triangles by fanning from
/// the first vertex. Convex polygons (quads, convex n-gons) are handled
/// correctly; concave polygons are a documented v1 limitation (ear-clip
/// follow-up). Already-triangles are left untouched.
///
/// Selection-aware (Polygons mode + non-empty selection): only the selected
/// faces are triangulated; children of selected parents are re-selected.
/// Otherwise: whole active layer (same convention as mesh.delete).
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-c; the whole-mesh
/// `MeshSnapshot` is gone. This is the cheapest member of the family to
/// migrate and the reason is measured, not assumed: `triangulateFacesByMask`
/// was ARMED at Stage K, and K measured its residual as *"the shortest of any
/// family"* — the Select bit of `edgeMarks` / `faceMarks` and nothing else,
/// which is exactly what `DenseSelectionUndo` restores.
///
/// IT NO LONGER ANSWERS `ok` OVER A NO-OP, and that is a fix this migration
/// FORCED rather than chose. `triangulateFacesByMask` has always returned a
/// count and this command discarded it, so tripling an already-triangulated
/// mesh landed a history entry describing no change — the shape three earlier
/// commands in this track were fixed for. A delta cannot represent it: the
/// post-close ruling is `acceptRecordedEdit`, and feeding it a fabricated
/// non-zero `affected` over an empty delta ticks
/// `changeBus.emptyDeltaOverMutation`, which both gate lanes assert stays 0.
/// So the count is read, `evaluate` returns false on 0, and the funnel answers
/// `status:error` with no history entry — the contract CLAUDE.md states.
///
/// WHAT IS INERT ON THIS PATH, said out loud so a green here is not read as
/// coverage of it: this kernel does not weld, so the edge-set MERGE record
/// (task 2310) and the Point-domain map payload (task 2330) on
/// `Kind.RemoveVerts` are never exercised by this class.
class MeshTriple : Command, Operator {
    mixin OperatorActrCommon;
    private void delegate()    onTopologyChange;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onTopologyChange) {
        super(mesh, view, editMode);
        this.onTopologyChange = onTopologyChange;
    }

    override string name() const { return "mesh.triple"; }

    override EditMode[] supportedModes() const {
        return [EditMode.Vertices, EditMode.Edges, EditMode.Polygons];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        bool   polygonMode        = editMode == EditMode.Polygons;
        bool   hasSelection       = polygonMode && mesh.hasAnySelectedFaces();
        bool[] prevSelectedFaces  = hasSelection ? mesh.selectedFaces.dup : null;

        // Whole-mesh: every VISIBLE face (NOT null — length-checked kernel).
        // Mode-gated fallback — visibleFaceMask(), not operandFaceMask()
        // (task 0613, S5; see the helper's doc comment in mesh.d).
        bool[] mask = hasSelection
            ? mesh.selectedFaces
            : mesh.visibleFaceMask();

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (undoRecorded()) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kTripleScope);
                rw = runKernel(ed, mask, hasSelection, prevSelectedFaces);
                ed.close();
            }
            return rw != 0;
        }

        preSel_.capture(*mesh);

        // TASK 1903 STAGE L10-P0 gave this command its first `MeshEditBatch`
        // (axis 0, the commit seam); STAGE L10-c makes it RECORDING — axis 2,
        // the undo.
        //
        // THE RAII HANDLE, not `beginEditBatch`/`endEditBatch` + a
        // `scope(failure)`: the unwind path is then the destructor's, which
        // pops the frame WITHOUT stamping and ticks `changeBus.batchLeaks` —
        // the suite asserts that stays 0.
        size_t changed;
        {
            auto ed = MeshEditBatch(*mesh, kTripleScope);
            changed = runKernel(ed, mask, hasSelection, prevSelectedFaces);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING (§S-6, ruling Q-K6). `changed == 0` is the
        // refusal this command SHOULD always have made — see the class's doc
        // comment. There is nothing to roll back on it: the kernel touched
        // nothing, and neither did the selection tail, which runs only under
        // `hasSelection` and only over what the kernel produced.
        if (!acceptRecordedEdit(changed, delta_)) {
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        // AFTER the accept, not before it, and that is a change of ORDER this
        // migration makes deliberately: dropping the active tool is a visible
        // side effect, and §S-6 asks a refusal to leave none. `mesh.mergeFaces`
        // already fires its delegate here for the same reason.
        if (onTopologyChange !is null) onTopologyChange();
        noteUndoRecorded();
        return true;
    }

    /// The kernel plus its selection tail, written once so the recording run
    /// and the redo run cannot drift. Returns the kernel's own count — the
    /// value this command used to discard.
    private static size_t runKernel(ref MeshEditBatch ed, bool[] mask,
                                    bool hasSelection, bool[] prevSelectedFaces)
    {
        uint[] faceOrigin;
        immutable size_t changed = ed.triangulateFacesByMask(mask, &faceOrigin);

        // Re-select children of originally-selected parents.
        if (hasSelection) {
            ed.resetSelection();
            foreach (k, parentFi; faceOrigin) {
                if (parentFi < prevSelectedFaces.length
                    && prevSelectedFaces[parentFi])
                    ed.selectFace(cast(int)k);
            }
        }

        // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`: this is the
        // command's LAST mesh publisher, and a command's tail must DELIVER. It
        // sits INSIDE the batch as of Stage L10-P0: with a frame open the
        // delivery defers and `close()` makes it, which is the same one
        // delivery by a structural route instead of an incidental one.
        ed.publishChange(MeshEditScope.Geometry);
        return changed;
    }

    private enum uint kTripleScope =
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

