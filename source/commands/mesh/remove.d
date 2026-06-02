module commands.mesh.remove_;

import command;
import operator : Operator, Task, VectorStack, PacketKind, OperatorActrCommon;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// All-true selection mask of length `n`, used when nothing is selected
/// (empty selection ⇒ whole mesh).
private bool[] allTrue(size_t n) {
    auto m = new bool[](n);
    m[] = true;
    return m;
}

/// Tier 1.1: "Remove" (`vert.remove` / `edge.remove false` /
/// `poly.remove`, dispatched by edit mode). In practice Remove produces
/// the same geometry as Delete (`select.delete`) for every selection
/// mode. We keep both as separate commands so the menu structure and
/// shortcut layout can distinguish them.
class MeshRemove : Command, Operator {
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

    override string name()  const { return "mesh.remove"; }
    override string label() const {
        final switch (editMode) {
            case EditMode.Vertices: return "Remove Vertices";
            case EditMode.Edges:    return "Remove Edges";
            case EditMode.Polygons: return "Remove Polygons";
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        // For Verts and Polygons modes, Remove is identical to Delete:
        // build a face mask, drop those faces. Only Edges mode dissolves
        // (merges adjacent faces) instead of deleting them.
        snap = MeshSnapshot.capture(*mesh);

        size_t affected = 0;

        // Empty selection ⇒ operate on the whole mesh: mesh.nothingSelected
        // is the single source of truth for the "everything is selected"
        // convention. Feed an all-true mask in that case.
        const all = mesh.nothingSelected(editMode);

        final switch (editMode) {
            case EditMode.Vertices:
                // Delete and Remove differ ONLY for edges. For vertices
                // both dissolve the vert from incident faces.
                affected = mesh.dissolveVerticesByMask(
                    all ? allTrue(mesh.vertices.length) : mesh.selectedVertices);
                break;

            case EditMode.Edges:
                // `edge.remove false`: dissolve edge + cleanup 2-valent
                // verts. Equivalent to `select.delete` on the same
                // selection — both produce identical geometry.
                affected = mesh.removeEdgesByMask(
                    all ? allTrue(mesh.edges.length) : mesh.selectedEdges);
                if (affected > 0) mesh.dissolveDegree2Verts();
                break;

            case EditMode.Polygons:
                affected = mesh.deleteFacesByMask(
                    all ? allTrue(mesh.faces.length) : mesh.selectedFaces);
                break;
        }

        if (affected == 0) {
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
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }
}
