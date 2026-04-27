module commands.mesh.split_edge;

import command;
import mesh;
import view;
import editmode;
import shader;
import viewcache;
import math : Vec3;

/// Split the (first) currently selected edge at its midpoint, inserting a
/// new vertex and updating every incident face. Edges are re-derived from
/// faces afterwards. The selection is reset on success.
class MeshSplitEdge : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name() const { return "mesh.split_edge"; }

    override bool apply() {
        if (editMode != EditMode.Edges) return false;
        if (!mesh.hasAnySelectedEdges()) return false;

        int ei = -1;
        foreach (i, sel; mesh.selectedEdges)
            if (sel) { ei = cast(int)i; break; }
        if (ei < 0 || ei >= cast(int)mesh.edges.length) return false;

        uint va = mesh.edges[ei][0];
        uint vb = mesh.edges[ei][1];
        Vec3 mid = (mesh.vertices[va] + mesh.vertices[vb]) * 0.5f;
        uint vm  = mesh.addVertex(mid);

        // Insert vm between (va, vb) (in either traversal direction) in
        // every face containing the edge.
        foreach (ref face; mesh.faces) {
            for (size_t k = 0; k < face.length; k++) {
                uint a = face[k];
                uint b = face[(k + 1) % face.length];
                if ((a == va && b == vb) || (a == vb && b == va)) {
                    face = face[0 .. k + 1] ~ vm ~ face[k + 1 .. $];
                    break;
                }
            }
        }

        // Re-derive edges from faces. addEdge dedupes via edgeIndexMap.
        mesh.edges.length = 0;
        mesh.edgeIndexMap.clear();
        foreach (ref face; mesh.faces) {
            foreach (k; 0 .. face.length) {
                mesh.addEdge(face[k], face[(k + 1) % face.length]);
            }
        }

        mesh.buildLoops();
        mesh.resetSelection();

        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length); vc.invalidate();
        ec.resize(mesh.edges.length);    ec.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length); fc.invalidate();
        return true;
    }
}
