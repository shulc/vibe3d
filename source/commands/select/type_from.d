module commands.select.type_from;

import command;
import mesh;
import view;
import editmode;

/// select.typeFrom <vertex|edge|polygon>
/// Switches the active EditMode without changing any selection.
/// Not undoable — mode-only, no mesh mutation.
class SelectTypeFromCommand : Command {
    private EditMode* editModePtr;
    private string    targetType;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
    }

    override string name()  const { return "select.typeFrom"; }
    override bool isUndoable() const { return false; }

    void setTargetType(string t) { targetType = t; }

    override bool apply() {
        switch (targetType) {
            case "vertex":  *editModePtr = EditMode.Vertices; break;
            case "edge":    *editModePtr = EditMode.Edges;    break;
            case "polygon": *editModePtr = EditMode.Polygons; break;
            default:
                throw new Exception(
                    "select.typeFrom: unknown type '" ~ targetType ~
                    "' — expected vertex, edge, or polygon");
        }
        return true;
    }
}
