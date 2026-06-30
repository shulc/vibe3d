module commands.mesh.clone_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// Record-flavor command for an interactive clone gesture (see CloneTool).
///
/// The tool captures a full MeshSnapshot before the first drag frame, then
/// on drag-release (or deactivate) records this command holding the
/// (pre-clone, post-clone) snapshot pair so the entire gesture is a single
/// undo step.
///
/// apply() = restore post-clone state; revert() = restore pre-clone state.
/// Heavyweight (~MB for large meshes) but clone gestures are discrete user
/// actions, so the snapshot cost is paid once per drag.
class MeshCloneEdit : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private MeshSnapshot before;
    private MeshSnapshot after;
    private string editLabel;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.clone_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Clone";
    }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Clone") {
        this.before    = before_;
        this.after     = after_;
        this.editLabel = label_;
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        after.restore(*mesh);
        refreshCaches();
        return true;
    }

    override bool revert() {
        before.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
