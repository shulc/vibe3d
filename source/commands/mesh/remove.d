module commands.mesh.remove_;

import command;
import mesh;
import view;
import editmode;
import viewcache;
import snapshot : MeshSnapshot;

/// Tier 1.1: MODO-style "Remove" (`vert.remove` / `edge.remove false` /
/// `poly.remove`, dispatched by edit mode). In practice modo_cl's Remove
/// produces the same geometry as Delete (`select.delete`) for every
/// selection mode — the docs claim they differ on edges, but
/// modo_cl headless treats them identically. We keep both as separate
/// commands to mirror the MODO menu structure and shortcut layout.
/// See tools/modo_diff/cases/{delete,remove}_*.json for bit-for-bit
/// proofs against MODO 9.
class MeshRemove : Command {
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

    override bool apply() {
        if (mesh.faces.length == 0) return false;

        // For Verts and Polygons modes, Remove is identical to Delete:
        // build a face mask, drop those faces. Only Edges mode dissolves
        // (merges adjacent faces) instead of deleting them.
        snap = MeshSnapshot.capture(*mesh);

        size_t affected = 0;

        final switch (editMode) {
            case EditMode.Vertices:
                if (!mesh.hasAnySelectedVertices()) { snap = MeshSnapshot.init; return false; }
                // MODO docs: Delete and Remove differ ONLY for edges. For
                // vertices both dissolve the vert from incident faces.
                affected = mesh.dissolveVerticesByMask(mesh.selectedVertices);
                break;

            case EditMode.Edges:
                if (!mesh.hasAnySelectedEdges()) { snap = MeshSnapshot.init; return false; }
                // modo_cl `edge.remove false`: dissolve edge + cleanup
                // 2-valent verts. Equivalent to `select.delete` on the
                // same selection — both produce identical geometry per
                // tools/modo_diff/cases/{delete,remove}_edge_back_left.json.
                affected = mesh.removeEdgesByMask(mesh.selectedEdges);
                if (affected > 0) mesh.dissolveDegree2Verts();
                break;

            case EditMode.Polygons:
                if (!mesh.hasAnySelectedFaces()) { snap = MeshSnapshot.init; return false; }
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
