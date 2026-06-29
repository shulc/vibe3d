module commands.mesh.bevel;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import params : Param;
import snapshot : MeshSnapshot;

private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// One-shot Bevel command: dispatches by edit mode.
///   Polygons → bevelFacesByMask(mask, inset, shift)  [params: inset, shift]
///   Edges    → bevelEdgesByMask(mask, width)          [param:  width]
/// Empty face-selection ⇒ whole mesh (allTrue mask, per sibling convention).
/// Empty edge-selection ⇒ allTrue mask — but all edges share faces/endpoints
/// under the face-disjoint guard, so the kernel returns 0 → status:error.
/// |inset|<1e-6 && |shift|<1e-6 (polygon) or width<1e-6 (edge) → status:error.
class MeshBevel : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private float            inset_ = 0.1f;
    private float            shift_ = 0.0f;
    private float            width_ = 0.1f;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.bevel"; }
    override string label() const { return "Bevel"; }

    override Param[] params() {
        if (editMode == EditMode.Edges)
            return [Param.float_("width", "Width", &width_, 0.1f)];
        return [
            Param.float_("inset", "Inset", &inset_, 0.1f),
            Param.float_("shift", "Shift", &shift_, 0.0f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t n = 0;

        if (editMode == EditMode.Polygons) {
            const all  = mesh.nothingSelected(EditMode.Polygons);
            auto  mask = all ? allTrue(mesh.faces.length) : mesh.selectedFaces;
            n = mesh.bevelFacesByMask(mask, inset_, shift_);
        } else if (editMode == EditMode.Edges) {
            const all  = mesh.nothingSelected(EditMode.Edges);
            auto  mask = all ? allTrue(mesh.edges.length) : mesh.selectedEdges;
            n = mesh.bevelEdgesByMask(mask, width_);
        }

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
