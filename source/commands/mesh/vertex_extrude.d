module commands.mesh.vertex_extrude;

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
/// (empty selection ⇒ whole mesh).
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Vertex Extrude (one-shot, undoable): for each selected, interior-
/// manifold vertex, builds an N-gon ring of new vertices around it from
/// its incident edges (see `Mesh.extrudeVerticesByMask`'s doc-comment for
/// the full captured-law writeup, task 0360). `width` (ring radius) alone
/// leaves the apex stationary; `shift` (extrude-along-normal) alone is a
/// confirmed no-op — it only has any effect once `width` is also nonzero.
/// Vertices-mode only; empty selection ⇒ whole mesh; `width`=0 is a no-op
/// (snapshot discarded) regardless of `shift`.
class MeshVertexExtrude : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private float            shift_ = 0.0f;
    private float            width_ = 0.0f;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.vertexExtrude"; }
    override string label() const { return "Vertex Extrude"; }

    override Param[] params() {
        return [
            Param.float_("shift", "Extrude", &shift_, 0.0f),
            Param.float_("width", "Width",   &width_, 0.0f),
        ];
    }

    void setShift(float v) { shift_ = v; }
    void setWidth(float v) { width_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Vertices) return false;
        if (mesh.vertices.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const all = mesh.nothingSelected(EditMode.Vertices);
        auto mask = all ? allTrue(mesh.vertices.length) : mesh.selectedVertices;
        size_t n = mesh.extrudeVerticesByMask(mask, shift_, width_);
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
