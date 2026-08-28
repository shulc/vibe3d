module commands.mesh.radial_array_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Radial array — insert `count-1` rotated copies of the selected
/// faces (or the whole mesh on empty selection). Each step rotates
/// the source by `i * total_angle / count` around an X/Y/Z axis
/// through `center`, plus an optional `i * extra_step_translate`
/// shift (for helices). `weld > 0` welds coincident verts and drops
/// duplicate seam faces — useful for closed 360° rings.
///
/// Axis is restricted to the principal axes (X/Y/Z). Arbitrary axis
/// vectors are a follow-up; their main downstream use case is the
/// helix sweep, which currently uses extra_step_translate instead.
///
/// `total_angle` semantics: the default 2π (full ring, step = 2π/count)
/// is the interoperable mode and matches external reference editors
/// exactly. A `total_angle < 2π` selects a PARTIAL (open) arc sweep
/// (step = total_angle/count, copies span [0, total_angle) leaving the
/// closing gap open) — this is a vibe3d-only extension with no external
/// reference equivalent (legacy reference radial-array commands expose no
/// sweep-angle argument and always fill a full 360°). Do NOT "fix" a
/// partial-sweep parity divergence by forcing step = 2π/count: that would
/// delete this feature. See task 0472 (radial-array-quarter-winding).
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L6-b; the whole-mesh
/// `MeshSnapshot` is gone. Nothing is armed for it — the `FaceReindex` its
/// op-log carries when the weld fires is stage L5-a's arming of
/// `Mesh.applyVertexRemap`, INHERITED through `weldCoincidentVertices`. The
/// appends are published by `Mesh.recordBulkAppendRound`, one `AddVerts` and
/// one `AddFaces` for the whole round rather than one pair per copy: a
/// `count`-step radial over a 2 000-face selection appends `(count-1) * 2 000`
/// faces, and card 2260 measured the per-element shape at 31x/66x.
///
/// ONE POST-CARRY PLANE EDIT, recorded rather than discovered: this kernel runs
/// `clearEdgeSelectionResize()` AFTER the weld's `rewriteFaces`, so an armed
/// entry's reverse restores the pre-clear edge-selection value and the tail
/// re-clears it. That is a Select-class plane, i.e. inside the arming rule, and
/// `DenseSelectionUndo` is what puts it back.
///
/// WHAT IS INERT ON THIS PATH: both `Kind.RemoveVerts` payloads (the set-mask
/// half, stage L5-b; the Point-domain map-value half, task 2330). Measured —
/// this family's weld only ever merges a CLONE into an ORIGINAL, so the
/// compaction drops only APPENDED slots, which carry neither set membership
/// nor a Point-map value.
class MeshRadialArray : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;

    private int    count_        = 6;
    private string axis_         = "Y";
    private Vec3   center_       = Vec3(0, 0, 0);
    // 2π in radians — full circle (the default for a radial array).
    private float  totalAngle_   = 6.2831853f;
    private Vec3   extraShift_   = Vec3(0, 0, 0);
    private float  weld_         = 0.001f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.radial_array"; }
    override string label() const { return "Radial Array"; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kDuplicateEditScope;
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
            // `.max(256).enforceBounds()` matches Mesh.radialArrayFaces'
            // internal `MAX_RADIAL_ARRAY_COUNT` cap — added for read-back-
            // clamp parity with the kernel's already-present cap.
            Param.int_  ("count",       "Count", &count_, 6).min(1).max(256).enforceBounds(),
            Param.enum_ ("axis",        "Axis",  &axis_,
                         [["X","X"], ["Y","Y"], ["Z","Z"]], "Y"),
            Param.vec3_ ("center",      "Center", &center_, Vec3(0, 0, 0)),
            Param.float_("total_angle", "Total Angle (rad)", &totalAngle_, 6.2831853f),
            Param.vec3_ ("extra_step_translate", "Extra Step Translate",
                         &extraShift_, Vec3(0, 0, 0)),
            Param.float_("weld",        "Weld Distance", &weld_, 0.001f).min(0.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;
        if (count_ <= 1)            return false;
        if (axis_.length != 1
         || (axis_[0] != 'X' && axis_[0] != 'Y' && axis_[0] != 'Z'))
            return false;

        // L1 funnel (task 0613, S5): selected faces, else every VISIBLE face.
        bool[] mask = mesh.operandFaceMask();

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS and keep the FIRST delta.
        if (recorded_) {
            size_t ri;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kDuplicateEditScope);
                ri = ed.radialArrayFaces(mask, count_, axis_[0], center_,
                                         totalAngle_, extraShift_, weld_);
                ed.close();
            }
            return ri != 0;
        }

        preSel_.capture(*mesh);

        size_t inserted;
        {
            auto ed = MeshEditBatch(*mesh, kDuplicateEditScope);
            inserted = ed.radialArrayFaces(mask, count_, axis_[0], center_,
                                           totalAngle_, extraShift_, weld_);
            delta_ = ed.close();
        }
        if (!acceptRecordedEdit(inserted, delta_)) {
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;
        return true;
    }

    override bool revert() {
        if (!recorded_) return false;
        delta_.revert(*mesh);     // LIFO inverse replay restores geometry
        preSel_.restore(*mesh);   // …then the three selection domains
        return true;
    }
}
