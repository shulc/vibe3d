module commands.select.ring;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

// SelectRing: Edges and Vertices modes.
//
// Edges: for each selected edge, selects all edges in the ring —
//        edges on the opposite side of connected quad polygons.
//
// Vertices: if exactly 2 vertices are selected and a mesh edge connects them,
//           selects the vertices of the corresponding edge ring.
class SelectRing : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.ring"; }

    override bool apply() {
        snap = SelectionSnapshot.capture(*mesh);
        if (editMode != EditMode.Edges && editMode != EditMode.Vertices) return true;

        if (editMode == EditMode.Edges) {
            if (mesh.selectedEdges.length < mesh.edges.length)
                mesh.selectedEdges.length = mesh.edges.length;

            bool[] initSel = mesh.selectedEdges.dup;
            foreach (i; 0 .. initSel.length) {
                if (!initSel[i]) continue;
                foreach (fi; mesh.facesAroundEdge(cast(uint)i))
                    foreach (ei; mesh.walkEdgeRing(cast(int)i, cast(int)fi))
                        mesh.selectEdge(ei);
            }
        } else { // Vertices
            if (mesh.selectedVertices.length < mesh.vertices.length)
                mesh.selectedVertices.length = mesh.vertices.length;

            bool[] initSel = mesh.selectedVertices.dup;
            foreach (i; 0 .. mesh.edges.length) {
                uint va = mesh.edges[i][0], vb = mesh.edges[i][1];
                if (va >= initSel.length || !initSel[va]) continue;
                if (vb >= initSel.length || !initSel[vb]) continue;
                foreach (fi; mesh.facesAroundEdge(cast(uint)i))
                    foreach (ei; mesh.walkEdgeRing(cast(int)i, cast(int)fi)) {
                        mesh.selectVertex(cast(int)mesh.edges[ei][0]);
                        mesh.selectVertex(cast(int)mesh.edges[ei][1]);
                    }
            }
        }

        return true;
    }
}
