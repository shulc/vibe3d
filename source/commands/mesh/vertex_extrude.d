module commands.mesh.vertex_extrude;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, acceptRecordedEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Vertex Extrude (one-shot, undoable): for each selected, interior-
/// manifold vertex, builds an N-gon ring of new vertices around it from
/// its incident edges (see `Mesh.extrudeVerticesByMask`'s doc-comment for
/// the full captured-law writeup, task 0360). `width` (ring radius) alone
/// leaves the apex stationary; `shift` (extrude-along-normal) alone is a
/// confirmed no-op — it only has any effect once `width` is also nonzero.
/// Vertices-mode only; empty selection ⇒ whole mesh; `width`=0 is a no-op
/// (the command refuses and records nothing) regardless of `shift`.
/// TASK 1903 STAGE L8-b — UNDO IS THE OPERATION-LOG DELTA; the whole-mesh
/// `MeshSnapshot` is gone. There is no `undoTrackerEnabled()` fork to select
/// between — grep it, this file never carried one; the two hatched
/// `edge_extend`/`edge_extrude` names CLAUDE.md lists are the interactive
/// TOOLS (`source/tools/edit/`), not the commands — so the recording batch is
/// unconditional, in `commands/mesh/poly_inset.d`'s shape after stage L7-a.
///
/// STAGE L8 BUILT NO PUBLISHER AND ARMED NOTHING, and it is the first family
/// of the track that needed neither. ``Mesh.extrudeVerticesByMask`` was already armed
/// at stage K (`tests/unit/face_reindex_arming_test.d`'s `kArmedSites`), so
/// this command's op-log on the frozen stand was ``[AddVerts, SetPos, MeshMapDelta, FaceReindex]``
/// BEFORE the migration began — measured, not assumed. What the migration
/// adds is the `DenseSelectionUndo` below and the deletion of the snapshot.
///
/// THE `DenseSelectionUndo` IS NOT DECORATION — it is the WHOLE residual.
/// Measured plane-for-plane on `makeTaggedGridBent(3)`, reported BOTH ways,
/// an armed revert of this kernel leaves exactly TWO Select-class planes: `edgeMarks` and `faceMarks`. Every other plane —
/// `map:uv`, `map:W`, `faceMaterial`, `facePart`, both set masks, the vertex
/// positions, the windings and all three counts — comes back BYTE-IDENTICAL,
/// and the Subpatch bit on face 1 and the Hide bit on face 5 come back INSIDE
/// `faceMarks`, which is how we know the residue is the SELECT bit and not
/// "the marks word is lost". That is also why this command carries no
/// `preMarksWord_` belt: there is nothing for one to catch.
class MeshVertexExtrude : Command, Operator {
    mixin OperatorActrCommon;
    private MeshEditDelta    delta_;
    private DenseSelectionUndo preSel_;
    /// Set once `evaluate` has recorded a delta. It discriminates FIRST RUN
    /// from REDO — `CommandHistory.redo` calls `apply()` again and a second
    /// recording run would lay a second delta over the first — and it is
    /// `revert()`'s guard: an instance whose `evaluate` refused holds an empty
    /// delta and must not replay it, which is what the deleted
    /// `if (!snap.filled) return false;` did.
    private bool             recorded_;
    private float            shift_ = 0.0f;
    private float            width_ = 0.0f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.vertexExtrude"; }
    override string label() const { return "Vertex Extrude"; }

    override Param[] params() {
        return [
            Param.float_("shift", "Extrude", &shift_, 0.0f),
            Param.float_("width", "Width",   &width_, 0.0f),
        ];
    }

    void setShift(float v) { shift_ = v; }
    void setWidth(float v) { width_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Vertices) return false;
        if (mesh.vertices.length == 0) return false;

        auto mask = mesh.operandVertexMask(EditMode.Vertices);

        // REDO: `CommandHistory.redo` re-runs `apply()` -> `evaluate`. Re-run
        // the kernel BATCHLESS — an unrecorded batch makes every tracker hook
        // take its `editRecorder_ is null` first line — and KEEP the first
        // delta rather than record a second one over it.
        if (recorded_) {
            size_t nRedo;
            {
                auto ed = MeshEditBatch.unrecorded(*mesh, kExtrudeEditScope);
                nRedo = ed.extrudeVerticesByMask(mask, shift_, width_);
                ed.close();
            }
            return nRedo != 0;
        }

        // The selection image is taken BEFORE the kernel and only on the
        // recording run — `DenseSelectionUndo.capture` is idempotent by CALLER
        // contract, not by construction, and a second capture on the redo arm
        // would image the POST-op selection.
        preSel_.capture(*mesh);

        // TASK 1903 STAGE H opened this batch (axis 0, the commit seam);
        // STAGE L8-b makes it RECORDING — axis 2, the undo. The RAII handle,
        // not `beginEditBatch`/`endEditBatch` + a `scope(failure)`: the unwind
        // path is then the destructor's, which pops the frame WITHOUT stamping
        // and ticks `changeBus.batchLeaks` — the suite asserts that stays 0.
        size_t n;
        {
            auto ed = MeshEditBatch(*mesh, kExtrudeEditScope);   // RECORDING
            n = ed.extrudeVerticesByMask(mask, shift_, width_);
            delta_ = ed.close();
        }

        // THE POST-CLOSE RULING, shared with `mesh.delete` / `mesh.remove` /
        // `mesh.poly_inset` (stage L3-a, ruling Q-K6). `n == 0` is the kernel's
        // own refusal — a `width` of 0 (documented: `shift` alone is a
        // confirmed no-op), or no selected interior-manifold vertex — and it is this
        // command's too. `n > 0` over an EMPTY delta is the contradiction:
        // `acceptRecordedEdit` REFUSES it and ticks
        // `changeBus.emptyDeltaOverMutation`, rather than recording a history
        // entry whose undo would do nothing. On this family that second arm is
        // UNREACHABLE on today's tree and the belt is deliberate: every kernel
        // here was measured to publish before stage L8 began, so the arm exists
        // to catch a LATER edit that moves a `rewriteFaces` out from under its
        // `faceReindexScope()` — which would otherwise ship `status:error` over
        // an extruded mesh.
        if (!acceptRecordedEdit(n, delta_)) {
            delta_.revert(*mesh);
            delta_  = MeshEditDelta.init;
            preSel_ = DenseSelectionUndo.init;
            return false;
        }
        recorded_ = true;
        return true;
    }

    /// Observable through `/api/history`'s `opInverse` field: an entry that
    /// restores from an op-log must not report itself as a whole-mesh
    /// snapshot. `recorded_` rather than a literal `true` — an instance whose
    /// `evaluate` refused holds no inverse at all.
    override bool isOperationInverse() const { return recorded_; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kExtrudeEditScope;
    }

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded op-log, for the KIND
        /// SEQUENCE assertions in `tests/unit/l8_extrude_delta_test.d`.
        /// A LENGTH is satisfied by a broken log: stage J made the
        /// `[MeshMapDelta, FaceReindex]` ADJACENCY contractual, and an
        /// interposed entry unpairs the corner restore SILENTLY while the
        /// geometry still round-trips.
        public ref const(MeshEditDelta) recordedDelta() const return {
            return delta_;
        }
    }

    override bool revert() {
        // An instance whose `evaluate` refused holds an empty delta and a
        // nulled selection image; replaying it would run `preSel_` over a mesh
        // it was never sized against. NOT the spelling for a command that DID
        // record: a `false` there pops the entry off BOTH history stacks and
        // truncates the suffix after it (regression 0099).
        if (!recorded_) return false;
        delta_.revert(*mesh);     // LIFO inverse replay restores the geometry
        preSel_.restore(*mesh);   // …then the three selection domains
        return true;
    }
}
