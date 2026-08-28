module commands.mesh.mirror_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import math    : Vec3;
import params  : Param;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Mirror the selected polygons across an axis-aligned plane (axis
/// passed through `center`). Reflects every cloned vert; winding is
/// reversed when `flipNormals` is on so the mirrored surface has
/// outward-facing normals; a non-zero `weld` folds coincident seam
/// verts into one vertex (the canonical "symmetric duplicate" mode).
///
/// Empty face selection ⇒ mirror the whole mesh.
///
/// UNDO IS THE OPERATION-LOG DELTA since task 1903 Stage L6-c; the whole-mesh
/// `MeshSnapshot` is gone. (The doc line that used to sit here — "Revert via
/// full MeshSnapshot — same shape as MeshDelete / MeshDuplicate" — had been
/// false about `MeshDelete` since stage L3 and is now false about all three.
/// It is deleted rather than amended, because a stale "same shape as X" line
/// is what carries one family's obsolete answer into the next one's file.)
///
/// NOTHING IS ARMED FOR IT. The `FaceReindex` its op-log carries when the weld
/// fires is stage L5-a's arming of `Mesh.applyVertexRemap`, INHERITED through
/// `weldCoincidentVertices`; the appends are published by
/// `Mesh.recordBulkAppendRound`, whose call in `Mesh.mirrorFacesPlane` sits
/// AFTER the reflection loop so the recorded positions are the reflected ones
/// and no `Kind.SetPos` is owed.
///
/// THE `isEmpty()` ROLLBACK ARM IN THE KERNEL IS UNREACHABLE FROM HERE, and
/// that is a measurement rather than a reading — see `Mesh.mirrorFacesPlane`'s
/// own comment at the arm for the sweep and its positive control. It matters
/// to THIS class specifically: that arm restores fifteen arrays by direct
/// assignment while the weld's `[..., RemoveVerts, Reindex]` entries survive
/// in the log, so if it ever became reachable the revert would re-insert
/// phantom vertices — and no invariant counter would fire, because the batch
/// still opens once and closes once. `tests/unit/l6_duplicate_delta_test.d`
/// carries the consequence-level guard: a huge-weld mirror inside a RECORDING
/// batch must land back on exactly the pre-op V/F/E.
///
/// WHAT IS INERT ON THIS PATH: both `Kind.RemoveVerts` payloads (set masks,
/// stage L5-b; Point-domain map values, task 2330). `mirrorFacesPlane` passes
/// `pairsMustCrossBound = true`, so an eligible weld pair must join a CLONE to
/// an ORIGINAL — an original can never be welded away — and the compaction
/// therefore drops only APPENDED slots, which carry no set membership and no
/// Point-map value.
class MeshMirror : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta      delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` recorded a delta: FIRST RUN vs REDO, and
    /// `revert()`'s guard — the role the deleted `if (!snap.filled)` played.
    private bool               recorded_;

    // Param-backed schema fields. Stored as plain T so &field works.
    private string axis_         = "X";
    private Vec3   center_       = Vec3(0, 0, 0);
    private float  weld_         = 0.001f;
    private bool   flipNormals_  = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.mirror"; }
    override string label() const { return "Mirror"; }

    // Mirror operates on the face selection (or whole mesh when no faces
    // are selected) — orthogonal to the current edit mode. It's a
    // topology op that doesn't care whether the user is in vert/edge/poly
    // select mode.

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
            Param.enum_("axis", "Axis", &axis_,
                        [["X","X"], ["Y","Y"], ["Z","Z"]], "X"),
            Param.vec3_("center", "Center", &center_, Vec3(0, 0, 0)),
            Param.float_("weld", "Weld Distance", &weld_, 0.001f).min(0.0f),
            Param.bool_("flip_normals", "Flip Normals", &flipNormals_, true),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0)               return false;
        if (axis_.length != 1
         || (axis_[0] != 'X' && axis_[0] != 'Y' && axis_[0] != 'Z'))
            return false;

        // Build face mask. Empty user selection ⇒ mirror the whole mesh
        // ("no selection ⇒ act on everything", as in mesh.quantize /
        // mesh.smooth).
        // L1 funnel (task 0613, S5): selected faces, else every VISIBLE face.
        bool[] mask = mesh.operandFaceMask();

        // REDO: `CommandHistory.redo` re-runs `apply()`. Re-run the kernel
        // BATCHLESS and keep the FIRST delta.
        if (recorded_) {
            size_t ri;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kDuplicateEditScope);
                ri = ed.mirrorFaces(mask, axis_[0], center_, weld_, flipNormals_);
                ed.close();
            }
            return ri != 0;
        }

        preSel_.capture(*mesh);

        size_t inserted;
        {
            auto ed = MeshEditBatch(*mesh, kDuplicateEditScope);
            inserted = ed.mirrorFaces(mask, axis_[0], center_, weld_, flipNormals_);
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
