module commands.mesh.axis_slice;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import math : Vec3;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

// ---------------------------------------------------------------------------
// UNDO FOR BOTH CLASSES IN THIS FILE IS THE OPERATION-LOG DELTA (task 1903
// Stage L4-b / L4-c), not a whole-mesh `MeshSnapshot`.
//
// The family built NO publisher: `Mesh.insertEdgePoint` records
// `[AddVerts, ReshapeFaces]` per straddling edge (Stage L2-c) and
// `Mesh.rebuildFacesWithChordSplits` records one `FaceReindex` for the chord
// rebuild (Stage L2-d), so a recording batch around a `cutByPlane` ladder comes
// back with a log `revert()` replays. Measured on `makeTaggedGridFull(3)`, one
// plane:
//
//   [AddVerts MeshMapDelta ReshapeFaces (AddVerts ReshapeFaces) x3 FaceReindex]
//
// and `revert()` reproduces the pre-cut state on every plane of
// `meshPlanesJson` — pinned by `tests/fixtures/undo_parity/slice_cut.json`.
//
// THE TWO BELTS, chosen by MEASUREMENT (drop each and diff against the
// `MeshSnapshot` oracle on the same forward):
//
//   * `preSel_`  — a `DenseSelectionUndo`. Without it `faceMarks` /
//     `edgePlanes` diverge. Dense rather than a bare `SelectionSnapshot`
//     because the dense image copies the three selection-ORDER arrays back
//     wholesale, which is what keeps a stamp on an UNSELECTED element across
//     an undo; with the bare one this family would need a standing per-plane
//     exception in its parity reader, exactly as stages L3 and L5 carry.
//   * `preMaps_` — the mesh-map set by value. The plane cuts are in the
//     documented per-corner DROP set: a splice changes the mesh's corner TOTAL
//     while the PolyVertex maps are still pre-op, so `recordPolyVertexPayload`
//     finds them out of step and DECLINES for the rest of the batch, and the
//     forward zeroes the whole UV plane. `MeshSnapshot` restored it; a bare
//     delta replay cannot invent it. Without the belt this migration would be
//     a REGRESSION against the shipped path, not a gap.
//
// `preMarksWord_` and `preEdgeEnds_` — the other two belts `delete.d` holds —
// are NOT carried, measured inert on every cell of this family (`FaceReindex`
// carries the whole face marks word; the dense image carries the edge
// selection by endpoint pair). A belt runs AFTER `delta_.revert` and
// OVERWRITES what the replay restored, so an inert one makes the payload's
// output UNOBSERVABLE — which is why stage L5-e deleted three of them from
// `delete.d` rather than leaving them as a second line.
// ---------------------------------------------------------------------------

/// DoS backstop (task 0365 P1, Param-layer bound added P2 fast-follow)
/// shared by `MeshAxisSlice` and `MeshJulienne`: each plane cut is an
/// O(mesh) `cutByPlane` call, so `count`/`countA`/`countB` scale the apply
/// loop below directly. Neither command has a shared `mesh.d` kernel to
/// cap, so the evaluate()-time clamp below is an apply-local backstop;
/// each Param also carries `.max(MAX_AXIS_SLICE_COUNT).enforceBounds()` so
/// a raw HTTP `tool.attr`/`/api/command` write is clamped at the Param
/// layer too, not just once evaluate() runs.
private enum int MAX_AXIS_SLICE_COUNT = 256;

// ---------------------------------------------------------------------------
// MeshAxisSlice — cut the mesh with N evenly-spaced planes along a chosen axis.
//
// Params:
//   axis  — 0=X, 1=Y, 2=Z (default 1, Y-axis)
//   count — number of planes (default 1)
//
// No edit-mode gate: the cut is geometry-global and works in any mode.
// Undo = MeshSnapshot (topology rewrite); no snapshot taken if nothing is cut.
// ---------------------------------------------------------------------------
class MeshAxisSlice : Command, Operator {
    mixin OperatorActrCommon;

    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    private MeshMap[]          preMaps_;

    private int axis_  = 1; // 0=X 1=Y 2=Z
    private int count_ = 1;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.axisSlice"; }
    override string label() const { return "Axis Slice"; }

    /// Geometry + Marks. NOT `kCutEditScope`'s `Position`: `cutByPlane` moves
    /// no EXISTING vertex — only `cutByPlaneEx`'s Gap option does, and neither
    /// class in this file can reach it. `kCutEditScope` stays the KERNEL's
    /// declared scope (it is shared with the slice tool, which does reach the
    /// position write); narrowing it here is a statement about this command.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }

    override bool isOperationInverse() const { return undoRecorded(); }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log, for the KIND
        /// SEQUENCE assertions in `tests/unit/l4_slice_cut_delta_test.d`.
        /// A LENGTH is satisfied by a broken log: stage J made the
        /// `[MeshMapDelta, <face entry>]` ADJACENCY contractual, and an
        /// interposed entry unpairs the corner restore SILENTLY while the
        /// geometry still round-trips.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override Param[] params() {
        return [
            Param.int_("axis",  "Axis",  &axis_,  1).min(0).max(2),
            // `.max(MAX_AXIS_SLICE_COUNT).enforceBounds()` matches the
            // apply-local clamp in evaluate() below — `.min()`/`.max()`
            // alone are UI-only hints and do not clamp a raw HTTP
            // `tool.attr`/`/api/command` write, so the Param bound is
            // added to agree with the backstop (defense-in-depth).
            Param.int_("count", "Count", &count_, 1)
                .min(1).max(MAX_AXIS_SLICE_COUNT).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (count_ < 1) return false;
        if (count_ > MAX_AXIS_SLICE_COUNT) count_ = MAX_AXIS_SLICE_COUNT;

        // Compute bounding box along the chosen axis.
        if (mesh.vertices.length == 0) return false;
        float minV = axisCoord(mesh.vertices[0], axis_);
        float maxV = minV;
        foreach (v; mesh.vertices) {
            float c = axisCoord(v, axis_);
            if (c < minV) minV = c;
            if (c > maxV) maxV = c;
        }
        float span = maxV - minV;
        if (span < 1e-6f) return false;

        Vec3 planeNormal = axisNormal(axis_);

        // REDO: the delta already recorded the first run; re-run the ladder in
        // an UNRECORDED batch (the Ph1 hooks take their `editRecorder_ is
        // null` first line, so nothing records twice) from the restored
        // pre-op state.
        if (undoRecorded()) {
            size_t rt = 0;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, editScope());
                foreach (k; 0 .. count_) {
                    float p = minV + span * cast(float)(k + 1) / cast(float)(count_ + 1);
                    rt += ed.cutByPlane(planeNormal * p, planeNormal);
                }
                ed.close();
            }
            return rt != 0;
        }

        preSel_.capture(*mesh);
        preMaps_ = new MeshMap[](mesh.meshMaps.length);
        foreach (i, ref m; mesh.meshMaps) preMaps_[i] = m.dup;

        // ONE batch for the whole ladder of cuts (task 1903 Stage E3, made
        // RECORDING at L4-b). The loop body is nothing but kernel calls, so
        // the batch spans exactly what the boundary owns and no more — the
        // narrowing rule §4.4a applied to its own transitional block. Inside
        // it every `commitChange` the kernel makes DEFERS, so N cuts stamp,
        // derive and deliver ONCE at `close()` instead of once per inserted
        // vertex and once per rebuilt face array.
        //
        // ONE BATCH IS ALSO WHAT MAKES THE UNDO ENTRY WHOLE: a `Command` holds
        // ONE `MeshEditDelta`, so a batch per cut would leave the delta
        // describing only the LAST plane. Face count, vertex count, edge count
        // and `opInverse` are all green under that — every plane adds faces —
        // and so are `changeBus.nestedBatchOpens` and `batchLeaks`, because
        // sequential opens are not nested opens. Only a full-plane revert
        // compare sees it, which is `mesh.axisSlice/x3` in
        // `tests/fixtures/undo_parity/slice_cut.json`.
        //
        // No `scope(failure)`: this handle has a destructor, and
        // `MeshEditBatch.~this` pops the frame during unwinding without
        // asserting and ticks `changeBus.batchLeaks`, which the suite asserts
        // stays 0 (plan §2.2c).
        size_t totalSplit = 0;
        {
            auto ed = MeshEditBatch(*mesh, editScope());   // RECORDING
            foreach (k; 0 .. count_) {
                float pos = minV + span * cast(float)(k + 1) / cast(float)(count_ + 1);
                Vec3 planePoint = planeNormal * pos;
                totalSplit += ed.cutByPlane(planePoint, planeNormal);
            }
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.cleanup` / `mesh.bevel` (Stage L3-a, ruling Q-K6).
        //
        // `totalSplit == 0` is this command's own refusal, and it is decided
        // only AFTER the kernel — a plane that crosses edges but splits no
        // face is a real outcome. The pre-flight-atomic rule's second branch
        // therefore applies: revert the delta EXPLICITLY and answer `false`,
        // never `snap.restore` (there is no snapshot any more) and never a
        // `false` out of `revert()`, which would pop the entry off BOTH
        // history stacks. `preSel_.restore` goes with it because the kernel's
        // `syncSelection` / `clearFaceSelectionResize` may already have run.
        if (!acceptRecordedEdit(totalSplit, delta_)) {
            if (totalSplit == 0) {
                delta_.revert(*mesh);
                preSel_.restore(*mesh);
            }
            delta_   = MeshEditDelta.init;
            preSel_  = DenseSelectionUndo.init;
            preMaps_ = null;
            return false;
        }
        noteUndoRecorded();
        return true;
    }

    protected override void revertImpl() {
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        if (preMaps_.length) {    // …then the maps, sized against it…
            mesh.meshMaps.length = preMaps_.length;
            foreach (i, ref m; preMaps_) mesh.meshMaps[i] = m.dup;
        }
        preSel_.restore(*mesh);   // …and last the selection, which touches none
    }
}

// ---------------------------------------------------------------------------
// MeshJulienne — grid cut: axis slice on two axes sequentially.
//
// Params:
//   axisA, countA — first axis and count (default X, 1)
//   axisB, countB — second axis and count (default Z, 1)
//
// Single MeshSnapshot wraps both cuts (one undo entry for both passes).
// ---------------------------------------------------------------------------
class MeshJulienne : Command, Operator {
    mixin OperatorActrCommon;

    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    private MeshMap[]          preMaps_;

    private int axisA_  = 0; // 0=X 1=Y 2=Z
    private int countA_ = 1;
    private int axisB_  = 2; // 0=X 1=Y 2=Z
    private int countB_ = 1;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.julienne"; }
    override string label() const { return "Julienne"; }

    /// As `MeshAxisSlice.editScope` — the same kernel, twice.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }

    override bool isOperationInverse() const { return undoRecorded(); }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log, for the KIND
        /// SEQUENCE assertions in `tests/unit/l4_slice_cut_delta_test.d`.
        /// A LENGTH is satisfied by a broken log: stage J made the
        /// `[MeshMapDelta, <face entry>]` ADJACENCY contractual, and an
        /// interposed entry unpairs the corner restore SILENTLY while the
        /// geometry still round-trips.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override Param[] params() {
        return [
            Param.int_("axisA",  "Axis A",  &axisA_,  0).min(0).max(2),
            // `.max(MAX_AXIS_SLICE_COUNT).enforceBounds()` matches the
            // apply-local clamp in evaluate() below — `.min()`/`.max()`
            // alone are UI-only hints and do not clamp a raw HTTP
            // `tool.attr`/`/api/command` write, so the Param bound is
            // added to agree with the backstop (defense-in-depth).
            Param.int_("countA", "Count A", &countA_, 1)
                .min(1).max(MAX_AXIS_SLICE_COUNT).enforceBounds(),
            Param.int_("axisB",  "Axis B",  &axisB_,  2).min(0).max(2),
            Param.int_("countB", "Count B", &countB_, 1)
                .min(1).max(MAX_AXIS_SLICE_COUNT).enforceBounds(),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (countA_ < 1 || countB_ < 1) return false;
        if (countA_ > MAX_AXIS_SLICE_COUNT) countA_ = MAX_AXIS_SLICE_COUNT;
        if (countB_ > MAX_AXIS_SLICE_COUNT) countB_ = MAX_AXIS_SLICE_COUNT;
        if (mesh.vertices.length == 0) return false;

        // THE BATCH LIFT (task 1903 Stage L4-c), and it is this class's whole
        // content beyond the migration it shares with its neighbour.
        //
        // `sliceAlongAxis` used to open and close its OWN batch, and `evaluate`
        // calls it TWICE. A `Command` holds ONE `MeshEditDelta`, so under the
        // old shape the second `close()` would simply overwrite the first and
        // the undo entry would describe the SECOND axis alone.
        //
        // NAME THE TELL, BECAUSE THE OBVIOUS ONE DOES NOT FIRE. The two opens
        // were SEQUENTIAL, not nested, so `changeBus.nestedBatchOpens` stays 0
        // and `batchLeaks` stays 0 under the broken shape; so do face count,
        // vertex count and `opInverse`, because BOTH axes add faces. Only a
        // full-plane revert compare on a stand cut along both axes sees it —
        // `mesh.julienne/xz` in `tests/fixtures/undo_parity/slice_cut.json`.
        // A HALF-done lift (hoist the handle here, leave `sliceAlongAxis`
        // opening its own) is a DIFFERENT failure and reddens a different
        // instrument: those opens ARE nested, so `nestedBatchOpens` moves.
        if (undoRecorded()) {
            size_t rt = 0;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, editScope());
                rt += sliceAlongAxis(ed, axisA_, countA_);
                if (axisB_ != axisA_) rt += sliceAlongAxis(ed, axisB_, countB_);
                ed.close();
            }
            return rt != 0;
        }

        preSel_.capture(*mesh);
        preMaps_ = new MeshMap[](mesh.meshMaps.length);
        foreach (i, ref m; mesh.meshMaps) preMaps_[i] = m.dup;

        size_t totalSplit = 0;
        {
            auto ed = MeshEditBatch(*mesh, editScope());   // RECORDING, ONE frame
            totalSplit += sliceAlongAxis(ed, axisA_, countA_);
            if (axisB_ != axisA_)
                totalSplit += sliceAlongAxis(ed, axisB_, countB_);
            delta_ = ed.close();
        }

        // The post-close ruling and the explicit revert-on-refusal — see the
        // twin block in `MeshAxisSlice.evaluate`.
        if (!acceptRecordedEdit(totalSplit, delta_)) {
            if (totalSplit == 0) {
                delta_.revert(*mesh);
                preSel_.restore(*mesh);
            }
            delta_   = MeshEditDelta.init;
            preSel_  = DenseSelectionUndo.init;
            preMaps_ = null;
            return false;
        }
        noteUndoRecorded();
        return true;
    }

    protected override void revertImpl() {
        delta_.revert(*mesh);
        if (preMaps_.length) {
            mesh.meshMaps.length = preMaps_.length;
            foreach (i, ref m; preMaps_) mesh.meshMaps[i] = m.dup;
        }
        preSel_.restore(*mesh);
    }

    /// One axis of the grid, INSIDE THE CALLER'S FRAME. The `ref MeshEditBatch`
    /// receiver is the lift: this helper no longer owns a batch, so both axes
    /// land in one delta. Shape copied from `spikey.d`, which had the same
    /// problem first.
    private size_t sliceAlongAxis(ref MeshEditBatch ed, int axis, int count) {
        float minV = axisCoord(mesh.vertices[0], axis);
        float maxV = minV;
        foreach (v; mesh.vertices) {
            float c = axisCoord(v, axis);
            if (c < minV) minV = c;
            if (c > maxV) maxV = c;
        }
        float span = maxV - minV;
        if (span < 1e-6f) return 0;

        Vec3 n = axisNormal(axis);
        size_t total = 0;
        foreach (k; 0 .. count) {
            float pos = minV + span * cast(float)(k + 1) / cast(float)(count + 1);
            total += ed.cutByPlane(n * pos, n);
        }
        return total;
    }
}

// ---------------------------------------------------------------------------
// Helpers shared by both commands
// ---------------------------------------------------------------------------

private float axisCoord(Vec3 v, int axis) {
    if (axis == 0) return v.x;
    if (axis == 2) return v.z;
    return v.y; // default Y (axis==1)
}

private Vec3 axisNormal(int axis) {
    if (axis == 0) return Vec3(1, 0, 0);
    if (axis == 2) return Vec3(0, 0, 1);
    return Vec3(0, 1, 0); // default Y (axis==1)
}
