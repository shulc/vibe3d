module commands.mesh.vertex_bevel;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import params : Param;
import snapshot : MeshSnapshot;

private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Vertex Bevel (one-shot, undoable): for each selected interior-manifold
/// vertex, split every incident edge at distance `amount` and replace the
/// vertex with an N-gon cap through those split points. Vertices-mode only;
/// empty selection ⇒ whole mesh (greedy vertex-disjoint subset); amount=0
/// is a no-op (snapshot discarded).
class MeshVertexBevel : Command, Operator {
    mixin OperatorActrCommon;
    private MeshSnapshot     snap;
    private float            amount_ = 0.2f;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "mesh.vertexBevel"; }
    override string label() const { return "Vertex Bevel"; }

    override Param[] params() {
        return [
            Param.float_("amount", "Amount", &amount_, 0.2f),
        ];
    }

    void setAmount(float v) { amount_ = v; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (editMode != EditMode.Vertices) return false;
        if (mesh.vertices.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        const all = mesh.nothingSelected(EditMode.Vertices);
        auto mask = all ? allTrue(mesh.vertices.length) : mesh.selectedVertices;
        size_t n = mesh.bevelVerticesByMask(mask, amount_);
        if (n == 0) {
            snap = MeshSnapshot.init;
            return false;
        }
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
}
