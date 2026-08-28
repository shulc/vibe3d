module commands.mesh.reduce;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;
import std.math : lround;

/// One-shot polygon reduction command. Collapses edges iteratively using a
/// greedy priority queue until the mesh reaches `targetFaces` alive faces or
/// no valid collapse remains. Operates on the whole active mesh (no
/// selection-subset; v1 scope).
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-f; the whole-mesh
/// `MeshSnapshot` is gone. It went LAST of the thirteen and for two reasons
/// that are both measurements:
///
///   * IT IS A WELD-GROUP MEMBER. `mesh_ops/decimate.d:564` finalises through
///     `weldVerticesByMask`, so this command could not move before Stage
///     L10-P2 armed `Mesh.applyVertexRemapAndRebuild`'s `rewriteFaces`. The
///     D2 review measured what the unarmed version did: a recording batch
///     yielded `[SetPos, Reindex, RemoveVerts]` and a `revert()` that answered
///     TRUE while restoring the vertices and only HALF the faces — 96 of 192
///     on a subdivided-cube stand. `tests/unit/mesh_ops/decimate_test.d`
///     pinned that as a DEFICIT and Stage L10-P2 flipped the pin;
///   * IT CARRIES M-D2. Reverting `decimate.d`'s `ed.setVertexPositions` back
///     to the raw `vertices[i] = …` loop it replaced now reddens
///     `weld_merge.json`'s `mesh.reduce` cell on the `vertices` plane. That
///     red did not exist at Stage D2, whose own gate was forward
///     byte-identity — and a raw write and `setVertexPositions` produce
///     identical positions.
///
/// Params:
///   ratio           — fraction of original faces to keep (0..1). Default 0.5.
///   count           — absolute target face count; overrides ratio when > 0.
///   preserveBoundary — when true, boundary edges and vertices are not collapsed.
class MeshReduce : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// The full face marks word by PRE-OP face index — the Subpatch and Hide
    /// planes, which the Select bit is masked out of on the way back.
    ///
    /// THIS BELT IS NOT DECORATION AND IT IS NOT SPECULATIVE: it is the one
    /// plane the frozen `weld_merge.json` oracle caught this command losing
    /// and the other twelve cells keeping. Measured 2026-08-28 on
    /// `makeTaggedGridWeldSets(3)`: without it the `mesh.reduce` cell's
    /// `faceMarks` came back `[0,2,0,0,0,0,0,1,0,1,0,0]` against a frozen
    /// `[0,2,0,0,0,4,0,1,0,1,0,0]` — face 5's HIDE bit gone, face 1's SUBPATCH
    /// bit intact, every count and every other plane equal. Delete it and that
    /// cell reddens on exactly that character.
    ///
    /// It is on THIS command and not on the family, deliberately: the other
    /// eleven round-trip the whole word through the delta on this stand, and
    /// an inert belt is green that looks like coverage — the sentence
    /// `commands/mesh/vert_merge.d` already writes about its own absent
    /// `preMaps_`. The shipped precedent for the belt itself is
    /// `commands/mesh/delete.d` and `commands/mesh/cleanup.d`, which hold the
    /// identical `preMarksWord_`.
    private uint[]             preMarksWord_;
    private float            ratio_  = 0.5f;
    private int              count_  = 0;
    private bool             pb_     = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.reduce"; }
    override string label() const { return "Reduce"; }

    override Param[] params() {
        return [
            Param.float_("ratio",            "Ratio",            &ratio_, 0.5f).min(0).max(1),
            Param.int_  ("count",            "Target Faces",     &count_, 0).min(0),
            Param.bool_ ("preserveBoundary", "Preserve Boundary", &pb_,    true),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        size_t origFaces = mesh.faces.length;
        size_t target;
        if (count_ > 0)
            target = cast(size_t)(count_ < cast(int)origFaces ? count_ : origFaces);
        else
            target = cast(size_t)lround(ratio_ * cast(double)origFaces);
        if (target < 1) target = 1;
        if (target >= origFaces) return false; // no-op

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (undoRecorded()) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kReduceEditScope);
                rw = ed.reduceToTarget(target, pb_);
                ed.close();
            }
            return rw != 0;
        }

        // The dense selection image, taken BEFORE the batch opens: the weld's
        // resize tails clear selection AFTER the face rewrite, so no face
        // entry in the op-log can describe them.
        preSel_.capture(*mesh);
        preMarksWord_ = mesh.faceMarks.dup;

        // TASK 1903 Stage D2 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). What that buys is not tidiness: one reduce now
        // bumps its version stamp, re-derives hidden geometry and delivers to
        // the change bus ONCE at `close()`, instead of once per
        // `commitChange` the finalising weld makes on its way through.
        //
        // RECORDING as of Stage L10-f, and the constructor was never the whole
        // of it — measured at the D2 review (MAJOR-2). On the UNARMED tree a
        // recording batch over this kernel yielded
        // `[SetPos:1, Reindex:1, RemoveVerts:1]` and a `revert()` that returned
        // true while restoring the vertices and only HALF the faces (96 of
        // 192 on a subdivided-cube stand): the face drops leave through
        // `rewriteFaces`, whose `FaceReindex` publisher was armed by no
        // production code. Swapping the constructor alone, before Stage
        // L10-P2's arming, would have replaced the whole-mesh snapshot with an
        // undo that silently drops faces. See source/mesh_ops/decimate.d's
        // header, decision (3).
        //
        // No `scope(failure)` here, unlike the older
        // `beginEditBatch`/`endEditBatch` spelling at delete.d / remove.d:
        // that pair has no destructor, this handle does. `MeshEditBatch.~this`
        // pops the frame during unwinding — without asserting, because it runs
        // while an exception is in flight — and ticks `changeBus.batchLeaks`,
        // which the suite asserts stays 0.
        size_t n;
        {
            auto ed = MeshEditBatch(*mesh, kReduceEditScope);
            n = ed.reduceToTarget(target, pb_);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING (§S-6, ruling Q-K6). `n == 0` is the refusal
        // this command has always made — no valid collapse remained. It now
        // ROLLS BACK rather than merely dropping the image: the greedy queue
        // can have collapsed and then run out before reaching the target, and
        // replaying an empty delta backwards is a no-op that answers true, so
        // the branch is safe on the arm where nothing moved and correct on the
        // arm where something did. The other arm — mutated, recorded nothing —
        // ticks `changeBus.emptyDeltaOverMutation`.
        if (!acceptRecordedEdit(n, delta_)) {
            if (n == 0) {
                delta_.revert(*mesh);
                preSel_.restore(*mesh);
            }
            delta_        = MeshEditDelta.init;
            preSel_       = DenseSelectionUndo.init;
            preMarksWord_ = null;
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

        // …then the Subpatch + Hide plane, BEFORE the selection restore and
        // never after it. `setFaceMarksFrom` is a FULL-WORD ASSIGN, not a
        // merge, so running it second would clobber the Select bits
        // `preSel_.restore` had just written — the code-review BLOCKER task
        // 0613 found at `delete.d`. `~Marks.Select` drops the Select bit from
        // the captured word, so this write can never itself resurrect a stale
        // Select bit ahead of the restore below.
        if (preMarksWord_.length) {
            assert(preMarksWord_.length == mesh.faces.length,
                "MeshReduce.revert: preMarksWord_ length != restored face "
              ~ "count — the delta revert did not land on the exact pre-op "
              ~ "face index space this capture assumes");
            mesh.setFaceMarksFrom(preMarksWord_, ~Mesh.Marks.Select);
        }
        preSel_.restore(*mesh);   // …then the three selection domains
    }
}
