module commands.mesh.loop_slice;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import params : Param;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;
import selection_product : addNewLoopEdges;

// ---------------------------------------------------------------------------
// addNewLoopEdges (selection_product.d) — reference-editor (v11) post-slice
//   selection parity (task 0476). After a loop slice the reference leaves the
//   ACTIVE selection
//   on the freshly-inserted loop: every edge BOTH of whose endpoints is a
//   newly-created loop vertex (index >= `firstNewVert`, the vertex count
//   captured just before the cut). For a single loop this is the 4 transverse
//   loop edges; for count>1 it is every loop's transverse edges PLUS the
//   along-rail segments between consecutive loop midpoints (measured against
//   the reference on the unit cube: count 1 -> 4 edges; count 3 -> 12
//   transverse + 8 along-rail = 20). `insertEdgeLoops` appends every new
//   midpoint via `addVertex` (originals keep their indices) and its internal
//   `resetSelection()` has already cleared the seed selection, so we only ADD
//   the loop edges here, in the caller's current (Edges) mode. The command's
//   snapshot restores the pre-cut selection on undo.
//   TASK 1180 — the body moved to `selection_product.addNewLoopEdges` so this
//   command and the interactive Loop Slice TOOL stop carrying separate ideas of
//   what a slice leaves selected. The TOOL calls the sibling that ALSO selects
//   the loop's vertices, because the row-3 capture
//   (`tests/fixtures/loop_slice_post_selection.json`) measured all three
//   selection layers and found them held; THIS path keeps 0476's edges-only
//   law, because 0476's own capture asserts `selectedVertices == 0` here in so
//   many words. The two claims are in conflict and the conflict is written up
//   at `addNewLoopEdges` rather than settled by guesswork.
//   TASK 1903 STAGE L9 — this call runs AFTER `ed.close()`, i.e. OUTSIDE the
//   recorded batch, and that is correct rather than an oversight: what a
//   revert restores is the PRE-op selection, which `DenseSelectionUndo` holds
//   in full. It is also a deliberate axis-0 residual. Do NOT move it inside
//   to tidy the seam without re-measuring the delivery count: the kernel's
//   tail `resetSelection()` already delivers from inside the batch, and what
//   holds both commands at ONE delivery is `Command.apply`'s own
//   `beginDeliveryBatchGlobal()` (the per-frame preview, which has no such
//   wrapper, measures 19).

// ---------------------------------------------------------------------------
// MeshAddLoop — insert one edge loop at a parametric position on the ring
//               crossed by the first selected edge.  Default position = 0.5
//               (midpoint).
//
// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L9-b; the whole-mesh
// `MeshSnapshot` is gone. There is no `undoTrackerEnabled()` fork to select
// between — grep it, this file never carried one — so the recording batch is
// unconditional, exactly as in `commands/mesh/delete.d` after Stage L3-b and
// `commands/mesh/cleanup.d` after L5-c. Redo re-runs the kernel BATCHLESS
// from the restored pre-op state.
//
// WHAT THE DELTA CANNOT CARRY, AND THEREFORE WHAT THE ONE BELT IS FOR.
// Measured 2026-08-28 on `makeTaggedGridFull(3)`, at the kernel, under a
// RECORDING batch, for N = 1 and N = 3, as the EXACT residual of an armed
// revert — reported both ways, so nothing is missing from this list and
// nothing on it is spurious:
//
//     edgeMarks, edgeSelectionOrder, faceMarks (the Select bit alone;
//     Subpatch and Hide come back), faceSelectionOrder, the three order
//     counters, vertexMarks, vertexSelectionOrder
//
// SEVEN planes, all Select-class, and they are exactly `SelectionSnapshot`'s
// field list — i.e. exactly what `commands/mesh/selection_undo.d`'s
// `DenseSelectionUndo` restores. Everything else round-trips: `meshMaps`'s
// per-corner UV comes back BYTE-IDENTICAL (Stage J's `recordPolyVertexPayload`
// beside the face entry) and `vertexSetMask` comes back at the PRE-op length
// (Stage L2-c's `finalize` fix). Those two are §F1's loss-list rows 9 and 8
// and both are closed on this tree.
//
// AND WHAT IS *NOT* HERE, stated because its absence is a measurement rather
// than an oversight:
//
//   * NO Marks publisher. `Kind.SelectionDelta` cannot carry the plane — its
//     restore re-selects through `Mesh.selectEdge`, which mints a FRESH order
//     stamp off the counter, and no delta kind carries a selection-order
//     stamp at all. A publisher for the kernel's
//     `setFaceMarksFrom(newWord, ~Marks.Select)`
//     (`mesh_ops/loop_slice.d:1630`) would be a SECOND writer over a plane
//     the dense image already owns.
//   * NO `preMarksWord_` belt. `applyFaceReindexReverse` reads the survivor
//     word off the LIVE mesh and restores Subpatch and Hide faithfully; only
//     the Select bit is missing when the replay ends, and `preSel_.restore`
//     puts it back one statement later.
//   * NO `preMaps_` belt, for the byte-identical UV measured above.
//
// ONE THING RECORDED RATHER THAN "FIXED". `setFaceMarksFrom` at
// `mesh_ops/loop_slice.d:1630` is a POST-CARRY plane edit, and §5.3's
// standing instruction says an armed op with one is "declined, not fudged".
// That instruction is about a lost VALUE; here the edit touches only the
// Select bit, which is inside Stage K's ARM rule and is covered by the dense
// image. Stage K armed the site knowing this. Do not disarm the kernel to
// obey a rule that does not apply to it.
// ---------------------------------------------------------------------------
class MeshAddLoop : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    /// The pre-op selection of all three domains, their order stamps and all
    /// three counters. THE ONLY BELT THIS CLASS HOLDS, and its content is a
    /// measurement rather than a precaution — see the class doc comment.
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` has recorded a delta. It discriminates FIRST RUN
    /// from REDO (`CommandHistory.redo` calls `apply()` again, and a second
    /// recording run would lay a second delta over the first) and it is
    /// `revert()`'s guard: an instance whose `evaluate` refused holds an empty
    /// delta and must not replay it. That is exactly what the deleted
    /// `if (!snap.filled) return false;` did.
    private bool               recorded_;

    private float position_ = 0.5f;  // `position` attr — 0 = start, 1 = end

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.addLoop"; }
    override string label() const { return "Add Loop"; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kLoopSliceEditScope;
    }

    /// Observable through `/api/history`'s `opInverse` field
    /// (`http_providers.d`), so it is not decoration: an entry restoring from
    /// an op-log must not report itself as a whole-mesh snapshot. `recorded_`
    /// rather than a literal `true`, for `delete.d`'s reason — an instance
    /// whose `evaluate` refused holds no inverse at all.
    override bool isOperationInverse() const { return recorded_; }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log, for the KIND
        /// SEQUENCE assertions in `tests/unit/l9_loop_slice_delta_test.d`.
        /// A LENGTH is satisfied by a broken log — Stage J made the
        /// `[MeshMapDelta, FaceReindex]` ADJACENCY contractual, and an
        /// interposed entry unpairs the corner restore SILENTLY while the
        /// geometry still round-trips — so the cells assert the sequence.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override Param[] params() {
        return [
            Param.float_("position", "Position", &position_, 0.5f)
                 .min(0.001f).max(0.999f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (editMode != EditMode.Edges)       return false;
        if (!mesh.hasAnySelectedEdges())      return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        // Enforce open-interval: position 0 or 1 is coincident with a corner.
        if (position_ <= 0.0f || position_ >= 1.0f) return false;

        // Dry-run: check that a ring exists before anything is captured.
        // `(*mesh).`, not `mesh.`: task 1903 Stage F1 made `collectEdgeRing` a
        // free function over `ref const(Mesh)`, and UFCS does NOT auto-deref a
        // pointer the way member lookup did.
        bool closed;
        auto ring = (*mesh).collectEdgeRing(cast(uint)ei, closed);
        if (ring.length == 0) return false;

        immutable uint firstNewVert = cast(uint)mesh.vertices.length;

        // REDO: `CommandHistory.redo` re-runs `apply()` -> `evaluate`. Re-run
        // the kernel BATCHLESS — an unrecorded batch makes every tracker hook
        // take its `editRecorder_ is null` first line — and KEEP the first
        // delta rather than record a second one over it (`cleanup.d`'s
        // `recorded_` arm).
        if (recorded_) {
            bool okRedo;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kLoopSliceEditScope);
                okRedo = ed.insertEdgeLoops(cast(uint)ei, [position_]);
                ed.close();
            }
            if (!okRedo) return false;
            addNewLoopEdges(mesh, firstNewVert);
            return true;
        }

        // THE ONE BELT, captured on the recording arm only — see the class
        // doc comment for the seven planes it is the measured answer to.
        preSel_.capture(*mesh);

        // Task 1903 Stage F1: `insertEdgeLoops` is a free function over
        // `ref MeshEditBatch` (source/mesh_ops/loop_slice.d), so the batch
        // opens HERE — at the command boundary, which is where §4.1 says it
        // belongs. One loop insert now STAMPS AND DERIVES once at `close()`
        // instead of once per appended rail vertex and once per face rebuild.
        //
        // SAY STAMP, NOT DELIVERY — corrected at the F1 review. A
        // `MeshEditBatch` (`g_editBatchStack`) and a DELIVERY batch
        // (`g_deliveryDepth`) are different mechanisms, and only the second
        // defers a change-bus delivery: `Mesh.deliverPending()` returns early
        // on `g_deliveryDepth > 0` and never consults `g_editBatchStack`, and
        // every selection writer — `clearVertexSelection` /
        // `clearEdgeSelection` / `clearFaceSelection` among them — calls
        // `noteSelectionChange(...); deliverPending();` unconditionally. So
        // the kernel's tail `resetSelection()` DELIVERS FROM INSIDE this
        // batch; opening one here does not fold that delivery into `close()`.
        // What holds the delivery count down at this call site is
        // `Command.apply`'s own `beginDeliveryBatchGlobal()`, which is why
        // both slice commands measure 1 delivery and the per-frame preview
        // (which has no such wrapper) measures 19.
        //
        // TASK 1903 STAGE L9-b — and it is RECORDING now.
        // `insertEdgeLoopsMulti` has carried `faceReindexScope()` since Stage
        // K (`mesh_ops/loop_slice.d:1615`) and Stage J made its single
        // `rewriteFaces` record the per-corner payload immediately before the
        // face entry, so the op-log this closes on is
        // `[AddVerts, MeshMapDelta, FaceReindex]` and its reverse restores
        // every plane except the Select-class ones the belt above owns.
        bool ok;
        {
            auto ed = MeshEditBatch(*mesh, kLoopSliceEditScope);   // RECORDING
            ok = ed.insertEdgeLoops(cast(uint)ei, [position_]);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.cleanup` (Stage L3-a, ruling Q-K6). `ok == false` is the
        // kernel's own refusal and `affected == 0` turns it into this
        // command's; `ok == true` over an EMPTY delta is the contradiction,
        // and it ticks `changeBus.emptyDeltaOverMutation` rather than passing
        // silently.
        //
        // `delta_.revert` on the refusal arm is a BELT, not a load-bearing
        // rollback: every refusal inside `insertEdgeLoopsMulti` is
        // PRE-MUTATION (`mesh_ops/loop_slice.d:663`, `:664`, `:708`, `:774`,
        // `:1289`, `:1314` — whose own comment says "no mutation yet" —
        // `:1359`), and the empty-op-log half of that is MEASURED rather than
        // read: a recording batch over `insertEdgeLoops(seed, [])` closes
        // with ZERO entries. The belt ships anyway, because "measured by
        // reading" is not measured and it costs one statement over an empty
        // log.
        if (!acceptRecordedEdit(ok ? 1 : 0, delta_)) {
            delta_.revert(*mesh);
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;

        // Reference parity (task 0476): select the newly-inserted loop.
        addNewLoopEdges(mesh, firstNewVert);
        return true;
    }

    override bool revert() {
        // An instance whose `evaluate` refused holds an empty delta and an
        // unfilled belt; replaying it would run the restore over a mesh the
        // capture was never sized against. It is NOT the spelling for a
        // command that DID record: a `false` there pops the entry off BOTH
        // history stacks and truncates the suffix after it (regression 0099).
        if (!recorded_) return false;

        // ORDER IS LOAD-BEARING: the delta replay FIRST, the dense selection
        // SECOND. `applyFaceReindexReverse` installs a WHOLE `faceMarks`
        // array and `MeshEditDelta.finalize` rebuilds `edges`, so a selection
        // restore running first would be overwritten by the one and would
        // have keyed on the wrong edge index space for the other.
        delta_.revert(*mesh);
        preSel_.restore(*mesh);
        return true;
    }
}

// ---------------------------------------------------------------------------
// MeshLoopSlice — insert N evenly-spaced edge loops on the ring crossed by
//                 the first selected edge.  Default count = 3 (→ 4 equal
//                 segments; positions = 1/4, 2/4, 3/4).
// ---------------------------------------------------------------------------
class MeshLoopSlice : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    /// See `MeshAddLoop.preSel_`. THE ONE BELT, and this class is the reason
    /// it is not a per-domain one: the kernel's tail `resetSelection()` and
    /// `setFaceMarksFrom(newWord, ~Marks.Select)` clear all three domains.
    private DenseSelectionUndo preSel_;
    /// See `MeshAddLoop.recorded_`.
    private bool               recorded_;

    private int count_ = 3;  // `count` attr — number of loops to insert

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.loopSlice"; }
    override string label() const { return "Loop Slice"; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kLoopSliceEditScope;
    }

    /// See `MeshAddLoop.isOperationInverse`.
    override bool isOperationInverse() const { return recorded_; }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log, for the KIND
        /// SEQUENCE assertions in `tests/unit/l9_loop_slice_delta_test.d`.
        /// A LENGTH is satisfied by a broken log — Stage J made the
        /// `[MeshMapDelta, FaceReindex]` ADJACENCY contractual, and an
        /// interposed entry unpairs the corner restore SILENTLY while the
        /// geometry still round-trips — so the cells assert the sequence.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override Param[] params() {
        return [
            // `.max(256).enforceBounds()` matches Mesh.insertEdgeLoopsMulti's
            // internal `MAX_LOOP_SLICE_COUNT` cap — the Param bound alone is
            // a UI-only hint and does not clamp a raw HTTP write.
            Param.int_("count", "Count", &count_, 3).min(1).max(256).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (editMode != EditMode.Edges)       return false;
        if (!mesh.hasAnySelectedEdges())      return false;
        if (count_ < 1)                       return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        // Dry-run ring check, before anything is captured. `(*mesh).` for the same reason
        // as MeshAddLoop above (Stage F1: a free function over
        // `ref const(Mesh)`, and UFCS does not auto-deref a pointer).
        bool closed;
        auto ring = (*mesh).collectEdgeRing(cast(uint)ei, closed);
        if (ring.length == 0) return false;

        // Evenly-spaced positions: (k+1) / (count+1) for k in 0..count.
        float[] pos;
        pos.reserve(count_);
        foreach (k; 0 .. count_)
            pos ~= (k + 1.0f) / (count_ + 1.0f);

        immutable uint firstNewVert = cast(uint)mesh.vertices.length;

        // REDO — see `MeshAddLoop.evaluate`.
        if (recorded_) {
            bool okRedo;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kLoopSliceEditScope);
                okRedo = ed.insertEdgeLoops(cast(uint)ei, pos);
                ed.close();
            }
            if (!okRedo) return false;
            addNewLoopEdges(mesh, firstNewVert);
            return true;
        }

        preSel_.capture(*mesh);

        // Task 1903 Stage F1 — the batch opens at the command boundary, for
        // the reason MeshAddLoop's does. The whole LADDER of `count_`
        // positions is ONE `insertEdgeLoops` call, so this is one batch
        // either way — the scale check that matters here is the per-position
        // rail append, and it is pinned on `mutationVersion` in the unit lane.
        //
        // TASK 1903 STAGE L9-a, and THIS class is the discriminating one.
        // `MeshLoopSlice` takes N positions where `MeshAddLoop` takes exactly
        // one, so at N >= 2 one old quad becomes THREE OR MORE fragments and
        // the corner on the far rail lives in the LAST fragment, not the
        // first. At N == 1 every fragment restores SLOT FOR SLOT, so a
        // corner-payload pairing or fragment-ordering defect is invisible in
        // `MeshAddLoop` entirely — its geometry round-trips and its UV map
        // compares equal. `tests/unit/undo_parity_l9_test.d`'s N=3 cell is
        // the one that can fail, and it asserts its own fragment count.
        bool ok;
        {
            auto ed = MeshEditBatch(*mesh, kLoopSliceEditScope);   // RECORDING
            ok = ed.insertEdgeLoops(cast(uint)ei, pos);
            delta_ = ed.close();
        }

        // The post-close ruling and the refusal belt — see
        // `MeshAddLoop.evaluate`, which carries the argument for both.
        if (!acceptRecordedEdit(ok ? 1 : 0, delta_)) {
            delta_.revert(*mesh);
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;

        // Reference parity (task 0476): select every newly-inserted loop.
        addNewLoopEdges(mesh, firstNewVert);
        return true;
    }

    override bool revert() {
        // See `MeshAddLoop.revert` — the guard, the order, and why neither is
        // decoration.
        if (!recorded_) return false;
        delta_.revert(*mesh);
        preSel_.restore(*mesh);
        return true;
    }
}
