module commands.select.expand;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

class SelectionExpand : Command {
    private SelectionSnapshot snap;
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.expand"; }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }

    override bool apply() {
        snap = SelectionSnapshot.capture(*mesh);
        if (editMode == EditMode.Vertices) {
            bool[] toAdd = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i])
                    foreach (ni; mesh.verticesAroundVertex(cast(uint)i))
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectVertex(cast(int)i);

        } else if (editMode == EditMode.Edges) {
            auto edgeAdj = mesh.edgeAdjacencySharingVertex();

            bool[] toAdd = new bool[](mesh.edges.length);
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i])
                    foreach (ni; edgeAdj[i])
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectEdge(cast(int)i);

        } else if (editMode == EditMode.Polygons) {
            // Adjacency via shared vertices (includes diagonal neighbours).
            auto faceAdj = mesh.faceAdjacencySharingVertex();

            bool[] toAdd = new bool[](mesh.faces.length);
            foreach (i; 0 .. mesh.selectedFaces.length)
                if (mesh.selectedFaces[i])
                    foreach (ni; faceAdj[i])
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectFace(cast(int)i);
        }
        return true;
    }
}
