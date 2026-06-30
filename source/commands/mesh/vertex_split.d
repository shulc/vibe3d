module commands.mesh.vertex_split;

import display_sync : refreshDisplay;
import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// `mesh.vertexSplit` — unweld each selected vertex: keep it in its
/// lowest-indexed incident face and give every later incident face its
/// own coincident copy. This is the inverse of weld / `vert.merge`.
///
/// Only the Vertex edit mode is meaningful; the command is a no-op in
/// Edge and Polygon modes (no vertices selected → evaluate returns false).
/// A vertex that is already incident to only one face produces no copies
/// and the command returns an error (no-op).
///
/// Undo: MeshSnapshot-based (same as mesh.collapse).
class MeshVertexSplit : Command, Operator {
    mixin OperatorActrCommon;
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private MeshSnapshot     snap;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name()  const { return "mesh.vertexSplit"; }
    override string label() const { return "Split Vertices"; }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (!mesh.hasAnySelectedVertices()) return false;

        // Capture the selection mask before any mutation (same discipline
        // as evalVertices in collapse.d — the kernel clears nothing here,
        // but the snapshot may change the selection arrays, so read first).
        auto sel = mesh.selectedVertices;
        snap = MeshSnapshot.capture(*mesh);
        const size_t n = mesh.splitVerticesByMask(sel);
        if (n == 0) {
            snap.restore(*mesh);
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
