module commands.mesh.select;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

/// Replace the current selection with the given indices in the given mode.
/// Switches editMode to match (vertices/edges/polygons). Used to be a direct
/// HTTP handler in app.d (setSelectionHandler); now a Command so undo/redo
/// covers selection changes uniformly with the rest of the system.
class MeshSelect : Command {
    private EditMode*         editModePtr;       // app.d's editMode (writable)
    private string            mode;
    private int[]             indices;
    private SelectionSnapshot snap;
    private EditMode          prevEditMode;
    private bool              captured;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name() const { return "mesh.select"; }
    override string label() const { return "Select"; }

    void setMode(string m)         { mode    = m; }
    void setIndices(int[] i)       { indices = i; }

    override bool apply() {
        mesh.syncSelection();
        snap         = SelectionSnapshot.capture(*mesh);
        prevEditMode = *editModePtr;
        captured     = true;

        int max;
        switch (mode) {
            case "vertices":
                *editModePtr = EditMode.Vertices;
                mesh.clearVertexSelection();
                max = cast(int)mesh.vertices.length;
                foreach (i; indices) {
                    if (i < 0 || i >= max)
                        throw new Exception("vertex index out of range");
                    mesh.selectVertex(i);
                }
                break;
            case "edges":
                *editModePtr = EditMode.Edges;
                mesh.clearEdgeSelection();
                max = cast(int)mesh.edges.length;
                foreach (i; indices) {
                    if (i < 0 || i >= max)
                        throw new Exception("edge index out of range");
                    mesh.selectEdge(i);
                }
                break;
            case "polygons":
                *editModePtr = EditMode.Polygons;
                mesh.clearFaceSelection();
                max = cast(int)mesh.faces.length;
                foreach (i; indices) {
                    if (i < 0 || i >= max)
                        throw new Exception("face index out of range");
                    mesh.selectFace(i);
                }
                break;
            default:
                throw new Exception("invalid mode '" ~ mode ~
                                    "', expected vertices/edges/polygons");
        }
        return true;
    }

    override bool revert() {
        if (!captured) return false;
        snap.restore(*mesh);
        *editModePtr = prevEditMode;
        return true;
    }
}
