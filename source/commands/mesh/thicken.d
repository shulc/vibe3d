module commands.mesh.thicken;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import mesh_edit_delta : MeshEditScope;
import mesh_ops.bridge : kBridgeEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit, revertMapEditEmptyOk;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Thicken (mesh.thicken): build an offset copy of the whole surface
/// (vertices displaced along averaged vertex normals), reverse its winding
/// to form the inner skin, and stitch every open boundary loop original↔offset
/// with a ring of quads — yielding a closed, watertight shell.
///
/// Self-intersection on tight concavities is a known v1 limitation.
///
/// Parameters:
///   thickness  (float)  Offset distance (default 0.1).
///   symmetric  (bool)   When true, split ±thickness/2; when false (default),
///                       keep the original surface as the outer skin.
/// TASK 1903 STAGE L2-h — UNDO IS THE OPERATION-LOG DELTA, and this command's
/// migration is THREE changes that must land together:
///
///   1. the batch opens here and is RECORDING;
///   2. `Mesh.thickenSurface` takes it as a parameter, which retires the
///      transitional `unrecorded` batch it used to open around its rim bridge
///      (plan §L2.2's P8) — without that, opening a batch here makes it a
///      NESTED open and `tests/test_thicken.d`'s `nestedBatchOpens` delta row
///      reddens; and
///   3. the `symmetric:true` arm's whole-mesh position shift goes through
///      `Mesh.setVertexPositions`, so it produces a `Kind.SetPos`.
///
/// (3) IS INVISIBLE ON THE DEFAULT PARAMETER. `symmetric:false` never runs that
/// arm, so a migration that shipped the appends alone would be green on every
/// default-parameter cell while an undo of a SYMMETRIC thicken left every
/// original vertex at `orig + n·t/2`. The parity fixture's cell drives `true`
/// for that reason, and so does the unit cell.
class MeshThicken : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    /// The pre-op selection — `thickenSurface`'s `syncSelection` resizes every
    /// selection plane over a doubled mesh. See
    /// `commands/mesh/selection_undo.d`.
    private DenseSelectionUndo preSel_;
    /// The forward SUCCEEDED — see `commands/mesh/flip.d`.
    private bool             applied_;
    private float            thickness_ = 0.1f;
    private bool             symmetric_ = false;

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.thicken"; }
    override string label() const { return "Thicken"; }

    override MeshEditScope editScope() const {
        return cast(MeshEditScope) kBridgeEditScope;
    }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    override Param[] params() {
        return [
            Param.float_("thickness", "Thickness", &thickness_, 0.1f),
            Param.bool_("symmetric",  "Symmetric",  &symmetric_, false),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;

        // THE REFUSAL IS PRE-FLIGHT AND ATOMIC: `thickenSurface` answers 0 for
        // a below-epsilon thickness and for a CLOSED surface (no boundary loop
        // to bridge), and both are decided in its step 1, before its first
        // mutation. Nothing to hoist and nothing to roll back.
        applied_ = runMapEdit(mesh, undo_, kBridgeEditScope,
                              (ref MeshEditBatch ed) => runKernel(ed));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed) {
        // Recording arm only — the redo arm keeps the first capture, the hatch
        // has the snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);
        return ed.mesh.thickenSurface(ed, thickness_, symmetric_) != 0;
    }

    override bool revert() {
        // `…EmptyOk`, and the `if (!snap.filled) return false;` this replaces
        // was DELETED rather than translated (regression 0099).
        if (!revertMapEditEmptyOk(mesh, undo_, applied_)) return false;
        // ONLY on the delta arm — the hatch's snapshot already restored every
        // selection plane.
        if (undo_.armed()) preSel_.restore(*mesh);
        return true;
    }
}
