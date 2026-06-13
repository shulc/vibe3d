module commands.mesh.edge_extend;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import math : Vec3;
import view;
import editmode;
import viewcache;
import params : Param;
import snapshot : MeshSnapshot;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh). Mirrors the helper in edge_extrude.d.
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Edge Extend (one-shot, undoable): ADDITIVE, non-manifold. Per selected edge
/// (with ≥1 adjacent face) spawn 2 ridge verts + 1 bridge quad WITHOUT modifying
/// the source mesh; vertices shared by multiple selected edges WELD to one new
/// vert (chains / loops / star junctions). Each new vert is positioned by a
/// world-frame TRS law (Offset world-axis applied last; Rotate then Scale about
/// the world origin; world-frame inset/shift drop from the original geometry).
/// Geometry lives in the standalone kernel Mesh.extendEdgesByMask. Edges-mode
/// only; empty selection ⇒ whole mesh; a 0-result (no edge with an adjacent
/// face) is a no-op (snapshot discarded).
class MeshEdgeExtend : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private float            inset_   = 0.1f;
    private float            shift_   = 0.0f;
    private float            offsetX_ = 0.0f, offsetY_ = 0.0f, offsetZ_ = 0.0f;
    private float            rotateX_ = 0.0f, rotateY_ = 0.0f, rotateZ_ = 0.0f;
    private float            scaleX_  = 1.0f, scaleY_  = 1.0f, scaleZ_  = 1.0f;
    private int              segments_ = 1;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.edge_extend"; }
    override string label() const { return "Edge Extend"; }

    override Param[] params() {
        return [
            Param.float_("inset",    "Local Inset", &inset_,   0.1f),
            Param.float_("shift",    "Local Shift", &shift_,   0.0f),
            Param.float_("offsetX",  "Offset X",    &offsetX_, 0.0f),
            Param.float_("offsetY",  "Offset Y",    &offsetY_, 0.0f),
            Param.float_("offsetZ",  "Offset Z",    &offsetZ_, 0.0f),
            Param.float_("rotateX",  "Rotate X",    &rotateX_, 0.0f).angle(),
            Param.float_("rotateY",  "Rotate Y",    &rotateY_, 0.0f).angle(),
            Param.float_("rotateZ",  "Rotate Z",    &rotateZ_, 0.0f).angle(),
            Param.float_("scaleX",   "Scale X",     &scaleX_,  1.0f),
            Param.float_("scaleY",   "Scale Y",     &scaleY_,  1.0f),
            Param.float_("scaleZ",   "Scale Z",     &scaleZ_,  1.0f),
            Param.int_("segments",   "Segments",    &segments_, 1),
        ];
    }
    // For a future tool's drag path.
    void setInset(float v)  { inset_ = v; }
    void setShift(float v)  { shift_ = v; }
    void setOffset(Vec3 v)  { offsetX_ = v.x; offsetY_ = v.y; offsetZ_ = v.z; }
    void setRotate(Vec3 v)  { rotateX_ = v.x; rotateY_ = v.y; rotateZ_ = v.z; }
    void setScale(Vec3 v)   { scaleX_  = v.x; scaleY_  = v.y; scaleZ_  = v.z; }
    void setSegments(int v) { segments_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Edges) return false;
        if (mesh.edges.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const all = mesh.nothingSelected(EditMode.Edges);
        auto mask = all ? allTrue(mesh.edges.length) : mesh.selectedEdges;
        size_t n = mesh.extendEdgesByMask(
            mask, inset_, shift_,
            Vec3(offsetX_, offsetY_, offsetZ_),
            Vec3(rotateX_, rotateY_, rotateZ_),
            Vec3(scaleX_,  scaleY_,  scaleZ_),
            segments_);
        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        refreshDisplay(mesh, gpu, vc, ec, fc);
    }
}
