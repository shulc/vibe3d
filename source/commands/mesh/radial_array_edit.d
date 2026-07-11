module commands.mesh.radial_array_edit;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;
import mesh_edit_delta : MeshEditDelta, MeshEditScope;

/// Record-flavor command for an interactive Radial Array session (see
/// RadialArrayTool). The tool captures a full MeshSnapshot at activation,
/// mutates the mesh freely while the user drags the gizmo / tweaks Tool
/// Properties (intermediate revert+reapply cycles within the tool itself,
/// re-running the shared `Mesh.radialArrayFaces` kernel from the clean cage
/// each time), and on deactivation records this command holding
/// (pre-array, post-array) snapshots.
///
/// apply() = restore post; revert() = restore pre. A topology-creating tool
/// (new clone verts + faces) cannot use the vertex-position-delta
/// MeshVertexEdit undo, so it records a full before/after snapshot pair —
/// one undo step per session. Verbatim-style clone of MeshFaceExtrudeEdit /
/// MeshEdgeExtendEdit with the name/label changed.
///
/// Delta-path undo (O(delta) instead of a whole-mesh snapshot pair) is
/// deferred, matching MeshFaceExtrudeEdit's own precedent: `setDelta` is
/// wired for a future phase but the snapshot path is the only one actually
/// used by RadialArrayTool today.
class MeshRadialArrayEdit : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    private MeshSnapshot before;
    private MeshSnapshot after;
    private string editLabel;

    // Deferred (see doc comment above): an optional operation-log delta.
    // When `useDelta_` is set (via setDelta), apply()/revert() replay the
    // delta (O(delta)) instead of restoring the whole-mesh snapshot pair.
    // The snapshot path is the sole wired path today.
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

    override string name()  const { return "mesh.radial_array_edit"; }
    override string label() const {
        return editLabel.length ? editLabel : "Radial Array";
    }

    // Change-scope metadata. Radial array appends clone verts + faces and
    // re-derives the clone selection (deselects the source, selects the new
    // copies) — no source-face reshape, but marks do change.
    override MeshEditScope editScope() const {
        return MeshEditScope.Geometry | MeshEditScope.Marks;
    }
    // True iff this instance is delta-backed (setDelta was called). The
    // snapshot path (setSnapshots — the only path wired today) reports false.
    override bool isOperationInverse() const { return useDelta_; }

    void setSnapshots(MeshSnapshot before_, MeshSnapshot after_, string label_ = "Radial Array") {
        this.before    = before_;
        this.after     = after_;
        this.editLabel = label_;
        this.useDelta_ = false;
    }

    // Deferred: install an operation-log delta for O(delta) undo.
    void setDelta(MeshEditDelta delta_, string label_ = "Radial Array") {
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
