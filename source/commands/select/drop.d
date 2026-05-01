module commands.select.drop;

import command;
import mesh;
import view;
import editmode;
import snapshot : SelectionSnapshot;

/// select.drop <vertex|edge|polygon>
/// Clears the selection in the given mode. Does NOT change EditMode.
/// Not undoable (matches MODO's behaviour for select.drop).
class SelectDropCommand : Command {
    private string           targetType;
    private SelectionSnapshot snap;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "select.drop"; }
    override bool isUndoable() const { return false; }

    void setTargetType(string t) { targetType = t; }

    override bool apply() {
        mesh.syncSelection();
        switch (targetType) {
            case "vertex":  mesh.clearVertexSelection(); break;
            case "edge":    mesh.clearEdgeSelection();   break;
            case "polygon": mesh.clearFaceSelection();   break;
            default:
                throw new Exception(
                    "select.drop: unknown type '" ~ targetType ~
                    "' — expected vertex, edge, or polygon");
        }
        return true;
    }
}
