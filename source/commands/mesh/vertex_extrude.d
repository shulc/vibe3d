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

/// Vertex Extrude (one-shot, undoable): for each selected vertex, spawn a
/// duplicate offset along the averaged face normal and connect
/// original→duplicate with a new wire edge. Moves selection to new vertices.
/// Vertices-mode only; empty selection ⇒ whole mesh; offset=0 is a no-op
/// (snapshot discarded).
class MeshVertexExtrude : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;
    private float            offset_ = 0.2f;

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
            Param.float_("offset", "Offset", &offset_, 0.2f),
        ];
    }

    void setOffset(float v) { offset_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Vertices) return false;
        if (mesh.vertices.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const all = mesh.nothingSelected(EditMode.Vertices);
        auto mask = all ? allTrue(mesh.vertices.length) : mesh.selectedVertices;
        size_t n = mesh.extrudeVerticesByMask(mask, offset_);
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
