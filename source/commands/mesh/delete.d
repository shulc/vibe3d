module commands.mesh.delete_;

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

/// Tier 1.1: delete the current selection. Dispatches by edit mode:
///   - Vertices: delete every face incident to a selected vert
///   - Edges:    delete every face incident to a selected edge
///   - Polygons: delete the selected faces directly
/// In all cases this funnels through Mesh.deleteFacesByMask, which
/// re-derives edges from the surviving faces and drops orphan verts.
///
/// Revert: full MeshSnapshot of the pre-delete cage. Heavy but a delete
/// is a discrete user action — paid once.
class MeshDelete : Command, Operator {
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

    override string name()  const { return "mesh.delete"; }
    override string label() const {
        final switch (editMode) {
            case EditMode.Vertices: return "Delete Vertices";
            case EditMode.Edges:    return "Delete Edges";
            case EditMode.Polygons: return "Delete Polygons";
        }
    }

    bool evaluate(ref VectorStack vts) {
        import toolpipe.packets : SubjectPacket;
        auto subj = vts.get!SubjectPacket();
        if (subj is null) return false;
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t affected = 0;

        // Empty selection ⇒ operate on the whole mesh: mesh.nothingSelected
        // is the single source of truth for the "everything is selected"
        // convention. In that case feed the *ByMask primitives an all-true
        // mask instead of the (empty) selection.
        const all = mesh.nothingSelected(editMode);

        final switch (editMode) {
            case EditMode.Vertices:
                // Delete-vertex dissolves the vert from every incident
                // face's boundary (quad → triangle), and only kills faces
                // that become degenerate (< 3 verts).
                affected = mesh.dissolveVerticesByMask(
                    all ? allTrue(mesh.vertices.length) : mesh.selectedVertices);
                break;

            case EditMode.Edges:
                // `select.delete` on an edge selection: dissolve the edge
                // (merging adjacent faces) AND dissolve any vert that ends
                // up 2-valent in the result.
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
