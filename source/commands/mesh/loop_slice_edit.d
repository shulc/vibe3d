module commands.mesh.loop_slice_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// Record-flavor command for an interactive Loop Slice session
/// (LoopSliceTool). Clone of `commands.mesh.bevel_edit.MeshBevelEdit` with a
/// correct `name()` so undo history reads "mesh.loop_slice_edit" rather than
/// "mesh.bevel_edit". One entry per committed cut: the tool captures
/// `before` at session start (or right after the PRIOR cut, re-arming for
/// the next one — see LoopSliceTool.commitEdit), mutates the mesh freely
/// while the user drags the seed-edge slider, and on mouse-up records this
/// command holding (pre-cut, post-cut) snapshots.
///
/// apply() = restore post; revert() = restore pre.
class MeshLoopSliceEdit : Command, Operator {
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

    override string name()  const { return "mesh.loop_slice_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Loop Slice";
    }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Loop Slice") {
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
