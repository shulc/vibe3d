module commands.mesh.smooth_shift_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// Record-flavor command for an interactive Smooth Shift (+ Thicken) session
/// (see tools.smooth_shift_tool.SmoothShiftTool). The tool captures a full
/// MeshSnapshot at the moment cap topology is first built, mutates the mesh
/// freely while the user drags either handle or tweaks Tool Properties, and
/// on deactivation records this command holding (pre, post) snapshots.
///
/// apply() = restore post; revert() = restore pre. A topology-creating tool
/// (new cap/retained verts + cap/wall/skin faces) cannot use vertex-position-
/// delta undo, so it records a full before/after snapshot pair — one undo
/// step per session. This is a verbatim clone of MeshFaceExtrudeEdit /
/// MeshBevelEdit with name/label changed (task 0358).
class MeshSmoothShiftEdit : Command, Operator {
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

    override string name()  const { return "mesh.smooth_shift_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Smooth Shift";
    }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Smooth Shift") {
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
