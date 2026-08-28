module commands.mesh.vertex_new;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import shader;
import math : Vec3;
import params : Param;
import mesh_edit_delta : MeshEditScope;
import commands.mesh.position_undo  : RecordedUndo;
import commands.mesh.map_edit_undo  : runMapEdit, revertMapEditEmptyOk;
import commands.mesh.selection_undo : DenseSelectionUndo;

/// Add one isolated vertex at an absolute position and auto-select it.
///
/// The new vertex has no edge or face references — it is a free-standing
/// point. Auto-selecting it after insertion enables immediate chaining
/// with position-editing commands without a separate selection step.
///
/// TASK 1903 STAGE L2-g — UNDO IS THE OPERATION-LOG DELTA, and this is one of
/// the two commands in stage L2 that needed NO new publisher: `Mesh.addVertex`
/// has been hooked since the tracker landed, so the topology half was already
/// `[AddVerts]` and its reverse already truncated correctly. What the migration
/// adds is the half the op-log does not carry — the SELECTION this command
/// destroys (`clearVertexSelection` + `selectVertex`), held densely beside the
/// delta; see `commands/mesh/selection_undo.d`.
class MeshVertexNew : Command, Operator {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    private DenseSelectionUndo preSel_;
    /// The forward SUCCEEDED — see `commands/mesh/flip.d`.
    private bool             applied_;

    private Vec3 pos_ = Vec3(0, 0, 0);

    version (unittest) {
        /// TEST-ONLY read-only view of the recorded undo (see `MeshFlip`).
        public ref const(RecordedUndo) recordedUndo() const return { return undo_; }
    }

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.addVertex"; }
    override string label() const { return "Add Vertex"; }

    override MeshEditScope editScope() const { return MeshEditScope.Geometry; }

    /// See `MeshFlip.isOperationInverse` — a cheap tell, not the observable.
    override bool isOperationInverse() const { return undo_.armed(); }

    /// Aim the command at an absolute world position before firing it —
    /// topology-pen P2 (doc/topopen_p2_plan.md): `pos_` is private (only
    /// `params()` exposes it, for the generic Param-driven argstring path),
    /// so a direct caller like `TopologyPenTool.placeVertexAt` needs this
    /// setter rather than reaching into the field or going through
    /// `params()`/setAttr for a single write.
    void setPos(Vec3 p) { pos_ = p; }

    override Param[] params() {
        return [
            Param.vec3_("pos", "Position", &pos_, Vec3(0, 0, 0)),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        if (vts.get!SubjectPacket() is null) return false;

        // This command has NO refusal past its `SubjectPacket` guard —
        // `addVertex` always appends — so there is nothing to hoist and the
        // kernel below always answers true.
        applied_ = runMapEdit(mesh, undo_, MeshEditScope.Geometry,
                              (ref MeshEditBatch ed) => runKernel(ed));
        return applied_;
    }

    /// The one mutating body, under whichever arm `runMapEdit` chose.
    private bool runKernel(ref MeshEditBatch ed) {
        // Recording arm only — the redo arm keeps the first capture, the hatch
        // has the snapshot.
        if (ed.recording() && !preSel_.filled()) preSel_.capture(ed.mesh);

        uint vi = ed.mesh.addVertex(pos_);
        // CRITICAL: `Mesh.addVertex` only appends to vertices[]; it does
        // NOT grow vertexMarks / vertexSelectionOrder. Indexing either array at
        // the new index before resizing causes an out-of-bounds RangeError (an
        // Error, not an Exception — the dispatch catch will NOT swallow it).
        // `Mesh.resizeVertexSelection()` grows both arrays to
        // vertices.length before any selectVertex call.
        ed.mesh.resizeVertexSelection();
        ed.mesh.clearVertexSelection();
        ed.mesh.selectVertex(cast(int)vi);
        return true;
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
