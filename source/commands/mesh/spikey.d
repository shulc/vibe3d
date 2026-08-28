module commands.mesh.spikey;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Spikey (one-shot, undoable): for each selected face, add an apex vertex at
/// the face centroid displaced along the face normal by `amount * (perimeter/N)`
/// (D1-B: amount is percent of average edge length), then replace the face with
/// a triangle fan to that apex — one tri per original edge. The parent face's
/// material and subpatch flag are carried to every fan tri. Polygons mode only;
/// empty selection ⇒ whole mesh; `amount == 0` still fans (in-place triangulate).
/// Returns status:error only when no face in the selection has ≥ 3 verts.
/// TASK 1903 STAGE L2-f — UNDO IS THE OPERATION-LOG DELTA. Stage F2 had already
/// moved the batch to the command boundary; this flips it from `unrecorded` to
/// RECORDING and pairs it with publisher P7 inside `spikeFacesByMask`, which
/// records the parent slot's replacement. Both halves are needed and neither is
/// visible from the other's lane: the kernel cell in
/// `tests/unit/mesh_ops/poly_bevel_test.d` drives the kernel under its own
/// recording batch and is green with the COMMAND still unrecorded, and
/// `tests/test_poly_bevel_seam_counters.d` is the only row that sees this
/// constructor — in the suite lane, not the unit one.
class MeshSpikey : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    /// The pre-op selection — the kernel SELECTS every appended fan triangle
    /// and `syncSelection` resizes the planes; the op-log has nothing that
    /// puts the pre-op bits back. See `commands/mesh/selection_undo.d`.
    private DenseSelectionUndo preSel_;
    private float            amount_ = 0.5f;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.spikey"; }
    override string label() const { return "Spikey"; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kPolyBevelEditScope;
    }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    override Param[] params() {
        return [
            Param.float_("amount", "Amount", &amount_, 0.5f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        auto mask = mesh.operandFaceMask();
        // Task 1903 Stage F2 put the batch at the command boundary, for the
        // reason `mesh.poly_inset`'s is there (§4.1): one spike stamps once at
        // `close()` instead of once per apex vertex, once per appended fan
        // triangle and once at the tail. Stage L2-f makes it RECORDING.
        //
        // THE REFUSAL IS PRE-FLIGHT AND ATOMIC — and at L2-f it became so BY
        // CONSTRUCTION: `spikeFacesByMask` counts its eligible faces before its
        // first `addVertex` and answers 0 from there, so the kernel below
        // cannot refuse after mutating and no snapshot has to be dropped.
        const bool applied_ = runMapEdit(this, mesh, undo_, kPolyBevelEditScope,
                              (ref MeshEditBatch ed) => runKernel(ed, mask));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed, bool[] mask) {
        // Recording arm only — the redo arm keeps the first capture, the hatch
        // has the snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);
        return ed.spikeFacesByMask(mask, amount_) != 0;
    }

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
        preSel_.restore(*mesh);
    }
}
