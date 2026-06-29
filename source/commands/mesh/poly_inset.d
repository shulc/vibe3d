module commands.mesh.poly_inset;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
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

/// Polygon Inset (one-shot, undoable): for each selected face, shrink it
/// inward by `inset` units (perpendicular-offset corner placement via
/// offsetMeet) and connect the original boundary to the inset boundary
/// with N ring quads. Polygons-mode only; empty selection ⇒ whole mesh;
/// `|inset| < 1e-6` is a no-op (snapshot discarded, evaluate returns false).
class MeshPolygonInset : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private float            inset_ = 0.1f;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.poly_inset"; }
    override string label() const { return "Inset"; }

    override Param[] params() {
        return [
            Param.float_("inset", "Inset", &inset_, 0.1f),
        ];
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const all = mesh.nothingSelected(EditMode.Polygons);
        auto mask = all ? allTrue(mesh.faces.length) : mesh.selectedFaces;
        size_t n = mesh.insetFacesByMask(mask, inset_);
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
