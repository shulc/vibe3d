module commands.mesh.stroke_extrude_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;

/// Record-flavor command for an interactive Stroke Extrude session (see
/// StrokeExtrudeTool, task 0323). Mirrors MeshRadialArrayEdit /
/// MeshFaceExtrudeEdit / MeshEdgeExtendEdit: the tool mutates the mesh
/// live during the drag (restore-and-rerun cycles against a captured
/// pre-gesture MeshSnapshot, re-running the shared `Mesh.extrudeAlongPath`
/// kernel from the clean cage each time), and on commit records this
/// command holding (pre-stroke, post-stroke) snapshots as ONE undo entry.
///
/// apply() = restore post; revert() = restore pre. A topology-creating
/// tool (new band verts + faces) cannot use the vertex-position-delta
/// MeshVertexEdit undo, so it records a full before/after snapshot pair —
/// one undo step per session.
///
/// Delta-path undo (O(delta) instead of a whole-mesh snapshot pair) is
/// deferred, matching MeshRadialArrayEdit's own precedent: `setDelta` is
/// wired for a future phase but the snapshot path is the only one
/// actually used by StrokeExtrudeTool today.
class MeshStrokeExtrudeEdit : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private MeshSnapshot before;
    private MeshSnapshot after;
    private string editLabel;

    // Deferred (see doc comment above): an optional operation-log delta.
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

    override string name()  const { return "mesh.strokeExtrude_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Stroke Extrude";
    }

    // Change-scope metadata. Stroke extrude appends band verts + faces and
    // re-derives the tip-band selection — no source-face reshape, but
    // marks do change.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }
    override bool isOperationInverse() const { return useDelta_; }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Stroke Extrude") {
        this.before    = before_;
        this.after     = after_;
        this.editLabel = label_;
        this.useDelta_ = false;
    }

    void setDelta(MeshEditDelta delta_, string label_ = "Stroke Extrude") {
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
