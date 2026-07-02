module commands.select.contract;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

class SelectionContract : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.contract"; }

    override bool apply() {
        snap = SelectionSnapshot.capture(*mesh);
        if (editMode == EditMode.Vertices) {
            bool[] toRemove = new bool[](mesh.selectedVertices.length);
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i])
                    foreach (ni; mesh.verticesAroundVertex(cast(uint)i))
                        if (ni >= mesh.selectedVertices.length || !mesh.selectedVertices[ni]) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectVertex(cast(int)i);

        } else if (editMode == EditMode.Edges) {
            auto edgeAdj = mesh.edgeAdjacencySharingVertex();

            bool[] toRemove = new bool[](mesh.selectedEdges.length);
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i])
                    foreach (ni; edgeAdj[i])
                        if (ni >= cast(int)mesh.selectedEdges.length || !mesh.selectedEdges[ni]) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectEdge(cast(int)i);

        } else if (editMode == EditMode.Polygons) {
            // Adjacency via shared vertices (mirrors SelectionExpand).
            auto faceAdj = mesh.faceAdjacencySharingVertex();

            bool[] toRemove = new bool[](mesh.selectedFaces.length);
            foreach (i; 0 .. mesh.selectedFaces.length)
                if (mesh.selectedFaces[i])
                    foreach (ni; faceAdj[i])
                        if (ni >= cast(int)mesh.selectedFaces.length || !mesh.selectedFaces[ni]) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectFace(cast(int)i);
        }
        return true;
    }
}
