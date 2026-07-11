module commands.mesh.array_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// Record-flavor command for an interactive Array gesture (see ArrayTool,
/// task 0355). Same shape as `commands.mesh.clone_edit.MeshCloneEdit` /
/// `commands.mesh.loop_slice_edit.MeshLoopSliceEdit`: the tool captures a
/// full MeshSnapshot before the first drag frame (or before the numeric
/// panel edit re-runs the grid kernel), then on commit (drag-release /
/// deactivate) records this command holding the (pre-array, post-array)
/// snapshot pair so the entire gesture is a single undo step — matching
/// the reference's "Post-Mode" continuous-commit-per-drag-step collapsing
/// to ONE undoable action from the user's perspective (Ctrl+Z once undoes
/// the whole drag), consistent with vibe3d's established per-gesture undo
/// granularity (see memory: project_per_gesture_commit).
///
/// apply() = restore post-array state; revert() = restore pre-array state.
class MeshArrayEdit : Command, Operator {
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

    override string name()  const { return "mesh.array_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Array";
    }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Array") {
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
