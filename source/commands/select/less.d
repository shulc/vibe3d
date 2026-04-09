module commands.select.less;

import command;
import mesh;
import view;
import editmode;

// SelectLess: all edit modes.
// Deselects the most recently selected element (highest *SelectionOrder).
class SelectLess : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.less"; }

    override bool apply() {
        if (editMode == EditMode.Polygons) {
            int last = -1, lastOrd = 0;
            foreach (i; 0 .. mesh.selectedFaces.length) {
                if (i >= mesh.faceSelectionOrder.length) break;
                int ord = mesh.faceSelectionOrder[i];
                if (ord > lastOrd) { lastOrd = ord; last = cast(int)i; }
            }
            if (last < 0) return true;
            mesh.deselectFace(last);
        } else if (editMode == EditMode.Edges) {
            int last = -1, lastOrd = 0;
            foreach (i; 0 .. mesh.selectedEdges.length) {
                if (i >= mesh.edgeSelectionOrder.length) break;
                int ord = mesh.edgeSelectionOrder[i];
                if (ord > lastOrd) { lastOrd = ord; last = cast(int)i; }
            }
            if (last < 0) return true;
            mesh.deselectEdge(last);
        } else if (editMode == EditMode.Vertices) {
            int last = -1, lastOrd = 0;
            foreach (i; 0 .. mesh.selectedVertices.length) {
                if (i >= mesh.vertexSelectionOrder.length) break;
                int ord = mesh.vertexSelectionOrder[i];
                if (ord > lastOrd) { lastOrd = ord; last = cast(int)i; }
            }
            if (last < 0) return true;
            mesh.deselectVertex(last);
        }
        return true;
    }
}
