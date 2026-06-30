module commands.mesh.reduce_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// Record-flavor command for an interactive mesh-reduction session (see
/// ReductionTool). The tool captures a full MeshSnapshot at the moment it
/// enters an active preview, then on deactivation records this command with the
/// (pre-reduce, post-reduce) snapshot pair.
///
/// apply() = restore post; revert() = restore pre. Heavyweight (~MB for large
/// meshes) but reduction sessions are discrete user actions, not continuous, so
/// the snapshot cost is paid once per session.
class MeshReduceEdit : Command, Operator {
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

    override string name()  const { return "mesh.reduce_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Reduce";
    }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Reduce") {
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
