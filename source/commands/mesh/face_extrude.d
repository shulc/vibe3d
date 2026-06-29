module commands.mesh.face_extrude;

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

/// Face Extrude (one-shot, undoable): lift the selected polygon region along its
/// averaged face normal by `distance`, cloning caps and bridging the region
/// boundary with side quads. Geometry lives in the reusable kernel
/// Mesh.extrudeFacesByMask. Polygons-mode only; empty selection ⇒ whole mesh;
/// distance==0 or a closed island (no boundary edges) are clean no-ops (snapshot
/// discarded).
class MeshFaceExtrude : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private float            distance_ = 0.5f;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "poly.extrude"; }
    override string label() const { return "Face Extrude"; }

    override Param[] params() {
        return [Param.float_("distance", "Distance", &distance_, 0.5f)];
    }
    void setDistance(float v) { distance_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Polygons) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const all = mesh.nothingSelected(EditMode.Polygons);
        auto mask = all ? allTrue(mesh.faces.length) : mesh.selectedFaces;
        size_t n = mesh.extrudeFacesByMask(mask, distance_);
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
