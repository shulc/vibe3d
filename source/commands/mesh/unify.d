module commands.mesh.unify;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Remove faces whose unordered vertex set duplicates an earlier face.
/// The first occurrence (lowest index) is kept; all later duplicates are
/// dropped. Operates on the whole active mesh regardless of selection.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L10-c; the whole-mesh
/// `MeshSnapshot` is gone. Nothing is armed for it: `unifyFaces` reaches
/// `Mesh.deleteFacesByMask`, which already describes its own face change, and
/// it is on the §5.3 audit's **do-not-arm** list. THAT LIST IS LOAD-BEARING
/// HERE and Stage K measured why — arming `wantsFaceReindex` batch-wide over
/// this kernel makes the revert DOUBLE-revert and overshoot to F=3 against a
/// pre-op F=2. The parity cell for this command keeps that red available: it
/// asserts F after the revert equals the pre-op F, which is the one shape a
/// count assertion CAN see, because the count goes past its starting value.
///
/// WHAT IS INERT ON THIS PATH: no weld runs here, so the edge-set MERGE record
/// (task 2310) and the Point-domain map payload (task 2330) on
/// `Kind.RemoveVerts` are never exercised, and this cell's green says nothing
/// about either.
class MeshUnify : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "poly.unify"; }
    override string label() const { return "Unify Polygons"; }

    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length < 2) return false;

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS — no recording frame means every tracker hook takes its
        // `editRecorder_ is null` early-out — and keep the FIRST delta rather
        // than record a second one over it.
        if (recorded_) {
            size_t rw;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kCleanupEditScope);
                rw = ed.unifyFaces();
                ed.close();
            }
            return rw != 0;
        }

        // The dense selection image, taken BEFORE the batch opens: dropping a
        // face resizes every mark array, and the reverted mesh gets a FRESH
        // edge index space out of `finalize`'s `rebuildEdges`.
        preSel_.capture(*mesh);

        // TASK 1903 Stage E1 — the kernel takes `ref MeshEditBatch`, so the
        // batch opens HERE, at the command boundary, and never inside the
        // kernel (plan §4.1). One unify now bumps its version stamp,
        // re-derives hidden geometry and delivers to the change bus ONCE at
        // `close()` instead of once per internal commit
        // (`deleteFacesByMask` → Geometry, its `compactUnreferenced` → Points).
        //
        // RECORDING as of Stage L10-c — axis 2, the undo. E1's comment here
        // said the batch was UNRECORDED *"so a RECORDING batch would build a
        // full op-log that nothing reads and `close()` would drop"*; the delta
        // is now what `revert()` replays, so the op-log has its reader.
        //
        // Scoped to the kernel call ALONE (§4.4a's narrowing rule): the
        // `removed == 0` rejection below must not run inside the frame.
        //
        // No `scope(failure)`, unlike the older `beginEditBatch`/
        // `endEditBatch` spelling at delete.d / remove.d: that pair has no
        // destructor, this handle does. `MeshEditBatch.~this` pops the frame
        // during unwinding — without asserting, because it runs while an
        // exception is in flight — and ticks `changeBus.batchLeaks`, which the
        // suite asserts stays 0.
        //
        // The result is declared MUTABLE and outside the block, and that is the
        // whole cost of scoping the batch: a `const` binding cannot be assigned
        // across the closing brace. It is not re-`const`-ed into a second name
        // afterwards, at any of this family's three call sites, because each
        // reads its value EXACTLY ONCE — in the rejection `if` on the very next
        // line. A shadow `const` there would add a name to protect a value that
        // has no second reader; if a later edit gives one a second read, that is
        // when it earns the extra binding.
        size_t removed;
        {
            auto ed = MeshEditBatch(*mesh, kCleanupEditScope);
            removed = ed.unifyFaces();
            delta_ = ed.close();
        }
        // THE POST-CLOSE RULING (§S-6, ruling Q-K6). `removed == 0` is the
        // honest refusal this command has always made, and it needs no
        // rollback: a `unifyFaces` that unifies nothing has mutated nothing.
        if (!acceptRecordedEdit(removed, delta_)) {
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
