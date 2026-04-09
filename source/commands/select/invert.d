module commands.select.invert;

import command;
import mesh;
import view;
import editmode;

class SelectInvert : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) { super(mesh, view, editMode); }

    override string name() const { return "select.invert"; }

    override bool apply() {
        if (editMode == EditMode.Vertices) {
            foreach (i; 0 .. mesh.selectedVertices.length)
                if (mesh.selectedVertices[i]) mesh.deselectVertex(cast(int)i);
                else                          mesh.selectVertex(cast(int)i);

        } else if (editMode == EditMode.Edges) {
            foreach (i; 0 .. mesh.selectedEdges.length)
                if (mesh.selectedEdges[i]) mesh.deselectEdge(cast(int)i);
                else                       mesh.selectEdge(cast(int)i);

        } else if (editMode == EditMode.Polygons) {
            foreach (i; 0 .. mesh.selectedFaces.length)
                if (mesh.selectedFaces[i]) mesh.deselectFace(cast(int)i);
                else                       mesh.selectFace(cast(int)i);
        }
        return true;
    }
}
