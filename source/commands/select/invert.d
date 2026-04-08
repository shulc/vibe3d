module commands.select.invert;

import command;
import mesh;
import view;
import editmode;

class SelectInvert : Command {
    this(ref Mesh mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.invert"; }

    override bool apply() {
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.selectedVertices.length)
                mesh.selectedVertices[i] = !mesh.selectedVertices[i];

        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.selectedEdges.length)
                mesh.selectedEdges[i] = !mesh.selectedEdges[i];

        } else if (editMode == EditMode.Polygons) {
            foreach (i; 0 .. mesh.selectedFaces.length)
                mesh.selectedFaces[i] = !mesh.selectedFaces[i];
        }
        return true;
    }
}
