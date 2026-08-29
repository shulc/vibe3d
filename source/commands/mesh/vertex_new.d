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
import commands.mesh.map_edit_undo  : runMapEdit;
import commands.mesh.selection_undo : DenseSelectionUndo;
import commands.mesh.gesture_payload : GesturePayload;

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
class MeshVertexNew : Command, Operator, GesturePayload {
    mixin OperatorActrCommon;
    private RecordedUndo     undo_;
    private DenseSelectionUndo preSel_;

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

    /// GesturePayload (task 1905, group G7) — the FOURTH carrier class to
    /// implement it, and the one the seam's own header predicted would turn up
    /// ("a fifth payload form implements one method and breaks nothing",
    /// `commands/mesh/gesture_payload.d`). `TopologyPenTool.placeVertexAt`
    /// hands this command to `Tool.recordGestureEdit`; without this method the
    /// recorder's `cast(GesturePayload)` comes back null, the belt refuses, and
    /// the placed vertex would stay on the mesh with no undo entry.
    ///
    /// TWO ARMS, and the second one is a BELT rather than a measured need —
    /// said plainly so nobody reads it as a discovered case. `undo_` is armed
    /// only when `runMapEdit` came back with a NON-EMPTY delta; `preSel_` is
    /// filled by the recording arm of `runKernel` BEFORE the mutation. A
    /// carrier that was built and never `evaluate`d answers false on both,
    /// which is the programming error the belt exists for. `Mesh.addVertex`
    /// always appends, so no path I can name reaches "evaluated, delta empty"
    /// — but if one ever did, this command would still own the selection it
    /// destroyed (`clearVertexSelection` + `selectVertex`), so undo would still
    /// have work to do. The pre-seam site recorded UNCONDITIONALLY; a
    /// single-arm predicate would make the seam strictly stricter than what it
    /// replaced, which is a behaviour change smuggled inside a migration.
    override bool hasGesturePayload() const {
        return undo_.armed() || preSel_.filled();
    }

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
        const bool applied_ = runMapEdit(this, mesh, undo_, MeshEditScope.Geometry,
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

    protected override void revertImpl() {
        // Armed by construction (task 2500): `runMapEdit` raises the flag only
        // when the delta came back NON-EMPTY, and `Command.revert` answers the
        // empty case — and the never-applied case — before this body is entered.
        undo_.revert(*mesh);
        preSel_.restore(*mesh);
    }
}
