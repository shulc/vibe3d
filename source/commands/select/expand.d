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
        // Perf (task 0388): iterate the geometry length and test membership via
        // the non-allocating `isXSelected(i)` scalar accessor. `mesh.selectedX`
        // is a @property that rebuilds a whole `bool[]` per access, so both the
        // loop bound and the per-element test used to allocate — the latter,
        // inside the loop, was O(n²).
        snap = SelectionSnapshot.capture(*mesh);
        if (editMode == EditMode.Vertices) {
            bool[] toAdd = new bool[](mesh.vertices.length);
            foreach (i; 0 .. mesh.vertices.length)
                if (mesh.isVertexSelected(i))
                    foreach (ni; mesh.verticesAroundVertex(cast(uint)i))
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectVertex(cast(int)i);

        } else if (editMode == EditMode.Edges) {
            auto edgeAdj = mesh.edgeAdjacencySharingVertex();

            bool[] toAdd = new bool[](mesh.edges.length);
            foreach (i; 0 .. mesh.edges.length)
                if (mesh.isEdgeSelected(i))
                    foreach (ni; edgeAdj[i])
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectEdge(cast(int)i);

        } else if (editMode == EditMode.Polygons) {
            // Adjacency via shared vertices (includes diagonal neighbours).
            auto faceAdj = mesh.faceAdjacencySharingVertex();

            bool[] toAdd = new bool[](mesh.faces.length);
            foreach (i; 0 .. mesh.faces.length)
                if (mesh.isFaceSelected(i))
                    foreach (ni; faceAdj[i])
                        toAdd[ni] = true;
            foreach (i; 0 .. toAdd.length)
                if (toAdd[i]) mesh.selectFace(cast(int)i);
        }
        return true;
    }
}
