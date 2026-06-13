module commands.mesh.edge_extrude_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;

/// Record-flavor command for an interactive Edge Extrude session (see
/// EdgeExtrudeTool, Phase 3). The tool captures a full MeshSnapshot at the
/// moment extrude topology is first built, mutates the mesh freely while the
/// user drags the gizmo and tweaks Tool Properties (intermediate
/// revert+reapply cycles within the tool itself), and on deactivation records
/// this command holding (pre-extrude, post-extrude) snapshots.
///
/// apply() = restore post; revert() = restore pre. A topology-creating tool
/// (new ridge/inset verts + bridge faces) cannot use the vertex-position-delta
/// MeshVertexEdit undo, so it records a full before/after snapshot pair — one
/// undo step per session. This is a verbatim clone of MeshBevelEdit with the
/// name/label changed.
class MeshEdgeExtrudeEdit : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private MeshSnapshot before;
    private MeshSnapshot after;
    private string editLabel;

    // Phase 2 (doc/undo_change_tracker_plan.md): an optional operation-log delta.
    // When `useDelta_` is set (via setDelta), apply()/revert() replay the delta
    // (O(Δ)) instead of restoring the whole-mesh snapshot pair. The snapshot path
    // stays intact as the fallback (VIBE3D_UNDO_TRACKER=off / degenerate delta).
    private MeshEditDelta delta_;
    private bool          useDelta_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.edge_extrude_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Edge Extrude";
    }

    // Change-scope metadata (Phase 4 §b). Extrude appends ridge/inset verts +
    // bridge faces, reshapes neighbour faces, and re-derives the ridge selection.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }
    // True iff this instance is delta-backed (setDelta was called). The snapshot
    // path (setSnapshots / escape hatch) reports false honestly.
    override bool isOperationInverse() const { return useDelta_; }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Edge Extrude") {
        this.before    = before_;
        this.after     = after_;
        this.editLabel = label_;
        this.useDelta_ = false;
    }

    // Phase 2: install an operation-log delta. The tool builds this by re-running
    // the extrude kernel once inside a Mesh edit batch (see EdgeExtrudeTool.
    // commitEdit). `before` is still kept so a degenerate (empty) delta could
    // fall back to the snapshot path, but with a real delta the snapshot pair is
    // never touched at apply/revert.
    void setDelta(MeshEditDelta delta_, string label_ = "Edge Extrude") {
        this.delta_    = delta_;
        this.useDelta_ = true;
        this.editLabel = label_;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (useDelta_) delta_.apply(*mesh);   // forward replay (redo)
        else           after.restore(*mesh);
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (useDelta_) delta_.revert(*mesh);  // LIFO inverse replay (undo)
        else           before.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
