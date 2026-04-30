module commands.mesh.delete_;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// Tier 1.1: delete the current selection. Dispatches by edit mode:
///   - Vertices: delete every face incident to a selected vert
///   - Edges:    delete every face incident to a selected edge
///   - Polygons: delete the selected faces directly
/// In all cases this funnels through Mesh.deleteFacesByMask, which
/// re-derives edges from the surviving faces and drops orphan verts.
///
/// Revert: full MeshSnapshot of the pre-delete cage. Heavy but a delete
/// is a discrete user action — paid once.
class MeshDelete : Command {
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

    override bool apply() {
        if (mesh.faces.length == 0) return false;

        snap = MeshSnapshot.capture(*mesh);
        size_t affected = 0;

        final switch (editMode) {
            case EditMode.Vertices:
                if (!mesh.hasAnySelectedVertices()) {
                    snap = MeshSnapshot.init; return false;
                }
                // MODO Delete-vertex dissolves the vert from every incident
                // face's boundary (quad → triangle), and only kills faces
                // that become degenerate (< 3 verts).
                affected = mesh.dissolveVerticesByMask(mesh.selectedVertices);
                break;

            case EditMode.Edges:
                if (!mesh.hasAnySelectedEdges()) {
                    snap = MeshSnapshot.init; return false;
                }
                // modo_cl `select.delete` on an edge selection: dissolve
                // the edge (merging adjacent faces) AND dissolve any vert
                // that ends up 2-valent in the result. Verified bit-for-bit
                // via tools/modo_diff/cases/delete_edge_back_left.json.
                affected = mesh.removeEdgesByMask(mesh.selectedEdges);
                if (affected > 0) mesh.dissolveDegree2Verts();
                break;

            case EditMode.Polygons:
                if (!mesh.hasAnySelectedFaces()) {
                    snap = MeshSnapshot.init; return false;
                }
                affected = mesh.deleteFacesByMask(mesh.selectedFaces);
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
