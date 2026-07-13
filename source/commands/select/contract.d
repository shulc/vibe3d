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
        // Perf (task 0388): iterate the geometry length and test membership via
        // the non-allocating `isXSelected(i)` scalar accessor (bounds-checked,
        // returns false out of range). `mesh.selectedX` is a @property that
        // rebuilds a whole `bool[]` per access, so the old `selectedX[i]` /
        // `selectedX[ni]` / `selectedX.length` uses inside these nested loops
        // were O(n²).
        snap = SelectionSnapshot.capture(*mesh);
        if (editMode == EditMode.Vertices) {
            bool[] toRemove = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.vertices.length)
                if (mesh.isVertexSelected(i))
                    foreach (ni; mesh.verticesAroundVertex(cast(uint)i))
                        if (!mesh.isVertexSelected(ni)) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectVertex(cast(int)i);

        } else if (editMode == EditMode.Edges) {
            auto edgeAdj = mesh.edgeAdjacencySharingVertex();

            bool[] toRemove = new bool[](mesh.edges.length);
            foreach (i; 0 .. mesh.edges.length)
                if (mesh.isEdgeSelected(i))
                    foreach (ni; edgeAdj[i])
                        if (!mesh.isEdgeSelected(ni)) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectEdge(cast(int)i);

        } else if (editMode == EditMode.Polygons) {
            // Adjacency via shared vertices (mirrors SelectionExpand).
            auto faceAdj = mesh.faceAdjacencySharingVertex();

            bool[] toRemove = new bool[](mesh.faces.length);
            foreach (i; 0 .. mesh.faces.length)
                if (mesh.isFaceSelected(i))
                    foreach (ni; faceAdj[i])
                        if (!mesh.isFaceSelected(ni)) {
                            toRemove[i] = true;
                            break;
                        }
            foreach (i; 0 .. toRemove.length)
                if (toRemove[i]) mesh.deselectFace(cast(int)i);
        }
        return true;
    }
}
