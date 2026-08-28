module commands.mesh.screen_slice;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import math : Vec3, cameraPlaneFromScreenLine;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

// ---------------------------------------------------------------------------
// MeshScreenSlice — cut the mesh with the camera plane defined by a dragged
// screen-space line segment.
//
// Given two screen endpoints (ax,ay)→(bx,by) and the current camera, the cut
// plane is the plane through the camera eye that contains both screen rays.
// Under a perspective camera every ray shares the eye as origin, so the two
// endpoint rays uniquely span a plane; cutByPlane then cuts every mesh face
// the infinite plane crosses.
//
// Params:
//   ax, ay — first  screen endpoint (pixels, Y-down)
//   bx, by — second screen endpoint (pixels, Y-down)
//
// Degenerate guard (fires BEFORE any snapshot):
//   - screen endpoints closer than 1 px  → no-op (no snapshot, no undo entry)
//   - cross-product of rays near-zero    → no-op (numerical backstop)
//
// If the plane is valid but misses every face, the recorded delta is reverted
// and the command returns false (same behaviour as mesh.axisSlice).
//
// UNDO IS THE OPERATION-LOG DELTA (task 1903 Stage L4-b). Same kernel, same
// publishers and the same two belts as `MeshAxisSlice` — the reasoning for
// both, and the measurement that chose them, is at the head of
// `commands/mesh/axis_slice.d` and is deliberately not copied here: this
// class differs from that one only in how the plane is derived.
// ---------------------------------------------------------------------------
class MeshScreenSlice : Command, Operator {
    mixin OperatorActrCommon;

    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    private MeshMap[]          preMaps_;

    private float ax_ = 0, ay_ = 0, bx_ = 0, by_ = 0;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.screenSlice"; }
    override string label() const { return "Screen Slice"; }

    /// As `MeshAxisSlice.editScope` — the same kernel through a camera plane.
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
            Param.float_("ax", "Ax", &ax_, 0),
            Param.float_("ay", "Ay", &ay_, 0),
            Param.float_("bx", "Bx", &bx_, 0),
            Param.float_("by", "By", &by_, 0),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;
        if (mesh.vertices.length == 0) return false;

        auto vp = effectiveViewport();

        // Build the camera plane BEFORE capturing a snapshot so that a
        // degenerate short line produces no undo entry and leaves the mesh
        // completely intact.
        Vec3 p, n;
        if (!cameraPlaneFromScreenLine(vp, ax_, ay_, bx_, by_, p, n))
            return false;

        // REDO: re-run the cut in an UNRECORDED batch from the restored
        // pre-op state — the delta already holds the first run.
        if (undoRecorded()) {
            size_t rn;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, editScope());
                rn = ed.cutByPlane(p, n);
                ed.close();
            }
            return rn != 0;
        }

        preSel_.capture(*mesh);
        preMaps_ = new MeshMap[](mesh.meshMaps.length);
        foreach (i, ref m; mesh.meshMaps) preMaps_[i] = m.dup;

        // The batch spans the kernel call and nothing else (task 1903 Stage
        // E3, made RECORDING at L4-b): inside it every `commitChange` the cut
        // makes DEFERS, so one screen slice stamps, derives and delivers once
        // at `close()` instead of once per inserted crossing vertex and once
        // per face rebuild — and the log it collects is this command's undo.
        size_t nSplit;
        {
            auto ed = MeshEditBatch(*mesh, editScope());   // RECORDING
            nSplit = ed.cutByPlane(p, n);
            delta_ = ed.close();
        }

        // The post-close ruling and the explicit revert-on-refusal — see the
        // twin block in `MeshAxisSlice.evaluate`. The degenerate-line guard
        // above is PRE-FLIGHT and needs none of this; `nSplit == 0` is decided
        // only after the kernel and does.
        if (!acceptRecordedEdit(nSplit, delta_)) {
            if (nSplit == 0) {
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
}
