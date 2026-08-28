module commands.mesh.poly_inset;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;

/// Polygon Inset (one-shot, undoable): for each selected face, move each
/// corner along its angle BISECTOR by an absolute distance of `inset` world
/// units (see mesh.insetFacesByMask / insetCornerBisector — task 1190 ported
/// that direction off "toward the polygon centroid", which pointed OUT of the
/// face at a reflex corner) and connect the original boundary to the inset
/// boundary with N ring quads.
/// Polygons-mode only; empty selection ⇒ whole mesh. `inset == 0` is NOT a
/// no-op (task 0359, reference-matched: the split always happens, landing a
/// degenerate zero-width ring at inset=0) — the remaining no-op cases are an
/// empty/undersized selection mask AND, since task 1230, a selection in which
/// every face's ring starts at a COLLINEAR corner: the reference refuses that
/// face outright (ledger row 42), the kernel skips it, and a selection with
/// nothing left to process comes back through the same `evaluate → false`
/// door, i.e. `status:error, "command 'mesh.poly_inset' did not apply"`.
/// The OFFSET SIGN is ring-order dependent for the same reason — see
/// `math.ringStartCornerSign`. Both are deliberate adoptions of the
/// reference's reading of the ring, not repairs.
///
/// Default is deliberately NON-zero (task 0359 review): the reference tool's
/// own default is bit-exact 0.0, but that value is a degenerate zero-area
/// ring (coincident-position boundary verts — a NaN Newell-normal hazard if
/// the result is later subdivided/lit without an intervening edit). The
/// scriptable one-shot command keeps a safe non-zero default so a bare
/// `mesh.poly_inset` invocation never manufactures degenerate geometry by
/// accident; the interactive PolyInsetTool (tools/poly_inset_tool.d) still
/// starts at the reference-matched 0.0 (its activate() does not build a
/// preview, so 0.0 is only ever a transient starting value, never silently
/// applied — see PolyInsetTool's class doc-comment).
/// TASK 1903 STAGE L7-a — UNDO IS THE OPERATION-LOG DELTA; the whole-mesh
/// `MeshSnapshot` is gone. There is no `undoTrackerEnabled()` fork to select
/// between — grep it, this file never carried one — so the recording batch is
/// unconditional, in `commands/mesh/delete.d`'s shape after Stage L3-b.
///
/// THIS IS THE DISCRIMINATING MEMBER OF THE FAMILY, and it migrates first for
/// three reasons. It is the only one whose op-log contained NO face entry at
/// all before Stage L7-P2 (`[AddVerts, AddFaces]` per processed face, and
/// `revert()` THREW: `index [16] is out of bounds for array of length 16`), so
/// it proves the diagnosis "ABSENT publisher, not a disarmed one" end to end.
/// It reaches no `compactUnreferenced` on this path, so its log has no
/// `[RemoveVerts, Reindex]` tail and nothing else can be credited for the
/// restore. And its failure mode is INVISIBLE anywhere else:
/// `Mesh.setFaceWindings` SILENTLY DECLINES an unordered `idx` list — it does
/// not throw, it returns a smaller count — and on the inset path that produces
/// a revert restoring V/F/E, every mark word, `faceMaterial`, `facePart` and
/// both set masks BYTE-IDENTICAL with only the WINDINGS wrong. In the bevel
/// groups the same defect lands beside a `[RemoveVerts, Reindex]` pair and
/// surfaces as a dangling index or a throw — loud, and therefore attributed to
/// something else.
///
/// AND IT CARRIES NO BELT, which is a measurement and not an omission. The
/// EXACT residual of an armed revert on `makeTaggedGridFull(3)`, reported both
/// ways, is EMPTY — all 22 planes byte-identical, Select-class included. The
/// kernel's tail is `syncSelection()`, which RESIZES the selection planes
/// rather than clearing them, so nothing in this path destroys a bit the
/// op-log cannot put back. `MeshBevel` next door DOES carry a
/// `DenseSelectionUndo`, because its edge arm re-derives the selection one
/// dimension down AFTER the batch closes; the difference is per command and
/// is not a style.
class MeshPolygonInset : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta    delta_;
    /// Set once `evaluate` has recorded a delta. It discriminates FIRST RUN
    /// from REDO — `CommandHistory.redo` calls `apply()` again and a second
    /// recording run would lay a second delta over the first — and it is
    /// `revert()`'s guard: an instance whose `evaluate` refused holds an empty
    /// delta and must not replay it, which is what the deleted
    /// `if (!snap.filled) return false;` did.
    private bool             recorded_;
    private float            inset_ = 0.1f;   // safe non-zero default (task 0359 review)

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.poly_inset"; }
    override string label() const { return "Inset"; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kPolyBevelEditScope;
    }

    /// Observable through `/api/history`'s `opInverse` field: an entry that
    /// restores from an op-log must not report itself as a whole-mesh
    /// snapshot. `recorded_` rather than a literal `true` — an instance whose
    /// `evaluate` refused holds no inverse at all.
    override bool isOperationInverse() const { return recorded_; }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log, for the KIND
        /// SEQUENCE assertions in `tests/unit/l7_bevel_inset_delta_test.d`.
        /// A LENGTH is satisfied by a broken log: Stage J made the
        /// `[MeshMapDelta, ReshapeFaces]` ADJACENCY contractual, and an
        /// interposed entry unpairs the corner restore SILENTLY while the
        /// geometry still round-trips.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override Param[] params() {
        return [
            Param.float_("inset", "Inset", &inset_, 0.1f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        auto mask = mesh.operandFaceMask();

        // REDO: `CommandHistory.redo` re-runs `apply()` -> `evaluate`. Re-run
        // the kernel BATCHLESS — an unrecorded batch makes every tracker hook
        // take its `editRecorder_ is null` first line — and KEEP the first
        // delta rather than record a second one over it.
        if (recorded_) {
            size_t nRedo;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kPolyBevelEditScope);
                nRedo = ed.insetFacesByMask(mask, inset_);
                ed.close();
            }
            return nRedo != 0;
        }
        // Task 1903 Stage F2: `insetFacesByMask` is a free function over
        // `ref MeshEditBatch` (source/mesh_ops/poly_bevel.d), so the batch
        // opens HERE — at the command boundary, which is where §4.1 says it
        // belongs. One inset now STAMPS AND DERIVES once at `close()` instead
        // of once per appended corner vertex, once per appended ring quad and
        // once at the kernel's tail.
        //
        // STAMP, NOT DELIVERY. A `MeshEditBatch` (`g_editBatchStack`) and a
        // DELIVERY batch (`g_deliveryDepth`) are different mechanisms and only
        // the second defers a change-bus delivery: `Mesh.deliverPending()`
        // returns early on `g_deliveryDepth > 0` and never consults
        // `g_editBatchStack`. What holds the delivery count down at this call
        // site is `Command.apply`'s own `beginDeliveryBatchGlobal()`.
        // TASK 1903 STAGE L7-a — and it is RECORDING now. Stage L7-P2 gave
        // `insetFacesByMask` its winding publisher (one BULK
        // `Mesh.setFaceWindings` call for the whole processed set), so the
        // op-log this closes on is `[AddVerts, AddFaces]` per processed face
        // followed by ONE `[MeshMapDelta, ReshapeFaces]` pair.
        size_t n;
        {
            auto ed = MeshEditBatch(*mesh, kPolyBevelEditScope);   // RECORDING
            n = ed.insetFacesByMask(mask, inset_);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.cleanup` (Stage L3-a, ruling Q-K6). `n == 0` is the kernel's
        // own refusal — an empty/undersized mask, or every masked face
        // refused at a COLLINEAR ring start (task 1230, ledger row 42) — and
        // `affected == 0` turns it into this command's. `n > 0` over an EMPTY
        // delta is the contradiction: `acceptRecordedEdit` REFUSES it and
        // ticks `changeBus.emptyDeltaOverMutation`, rather than recording a
        // history entry whose undo would do nothing.
        //
        // `delta_.revert` on the refusal arm is a BELT: `insetFacesByMask`
        // decides `processed == 0` only after its loop, and a face that
        // refused on `ringSign == 0` was `continue`d before any mutation, so
        // a refusal that reaches here has an empty log. The belt costs one
        // statement over an empty log and does not rely on that reading.
        if (!acceptRecordedEdit(n, delta_)) {
            delta_.revert(*mesh);
            delta_ = MeshEditDelta.init;
            return false;
        }
        recorded_ = true;
        return true;
    }

    override bool revert() {
        // An instance whose `evaluate` refused holds an empty delta;
        // replaying it would run over a mesh it was never sized against. NOT
        // the spelling for a command that DID record: a `false` there pops the
        // entry off BOTH history stacks and truncates the suffix after it
        // (regression 0099).
        if (!recorded_) return false;
        delta_.revert(*mesh);
        return true;
    }
}
