module commands.select.invert;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

class SelectInvert : Command {
    private SelectionSnapshot snap;
    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        return true;
    }
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.invert"; }

    override bool apply() {
        // Perf (task 0388): iterate the geometry length and test membership via
        // the non-allocating `isXSelected(i)` scalar accessor. Indexing the
        // `mesh.selectedX` @property inside the loop rebuilt a whole `bool[]`
        // per element — O(n²).
        snap = SelectionSnapshot.capture(*mesh);
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.vertices.length)
                if (mesh.isVertexSelected(i)) mesh.deselectVertex(cast(int)i);
                else                          mesh.selectVertex(cast(int)i);

        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.edges.length)
                if (mesh.isEdgeSelected(i)) mesh.deselectEdge(cast(int)i);
                else                        mesh.selectEdge(cast(int)i);

        } else if (editMode == EditMode.Polygons) {
            foreach (i; 0 .. mesh.faces.length)
                if (mesh.isFaceSelected(i)) mesh.deselectFace(cast(int)i);
                else                        mesh.selectFace(cast(int)i);
        }
        return true;
    }
}
