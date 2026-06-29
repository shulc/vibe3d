module commands.mesh.face_extrude_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;

/// Record-flavor command for an interactive Face Extrude session (see
/// PolyExtrudeTool). The tool captures a full MeshSnapshot at the moment extrude
/// topology is first built, mutates the mesh freely while the user drags the
/// gizmo, and on deactivation records this command holding (pre-extrude,
/// post-extrude) snapshots.
///
/// apply() = restore post; revert() = restore pre. A topology-creating tool
/// (new cap verts + bridge faces) cannot use vertex-position-delta undo, so it
/// records a full before/after snapshot pair — one undo step per session.
/// This is a verbatim clone of MeshEdgeExtrudeEdit with name/label changed.
///
/// Phase 5 (delta-path undo) is deferred: `setDelta` is stubbed and the
/// snapshot path is the only wired path in Phases 1-4.
class MeshFaceExtrudeEdit : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private MeshSnapshot before;
    private MeshSnapshot after;
    private string editLabel;

    // Phase 5 (deferred): an optional operation-log delta. When `useDelta_` is
    // set (via setDelta), apply()/revert() replay the delta (O(Δ)) instead of
    // restoring the whole-mesh snapshot pair. The snapshot path is the sole
    // wired path in Phases 1-4.
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

    override string name()  const { return "mesh.face_extrude_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Face Extrude";
    }

    // Change-scope metadata (Phase 4 §b). Face extrude appends cap verts +
    // bridge faces, drops the original selected faces, and re-derives the cap
    // selection.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }
    // True iff this instance is delta-backed (setDelta was called). The snapshot
    // path (setSnapshots / Phase 1-4) reports false.
    override bool isOperationInverse() const { return useDelta_; }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Face Extrude") {
        this.before    = before_;
        this.after     = after_;
        this.editLabel = label_;
        this.useDelta_ = false;
    }

    // Phase 5 (deferred): install an operation-log delta for O(Δ) undo.
    void setDelta(MeshEditDelta delta_, string label_ = "Face Extrude") {
        this.delta_    = delta_;
        this.useDelta_ = true;
        this.editLabel = label_;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (useDelta_) delta_.apply(*mesh);
        else           after.restore(*mesh);
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (useDelta_) delta_.revert(*mesh);
        else           before.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
