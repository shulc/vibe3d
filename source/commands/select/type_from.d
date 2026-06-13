module commands.select.type_from;

import command;
import mesh;
import view;
import editmode;

/// select.typeFrom <vertex|edge|polygon>
/// Switches the active EditMode without changing any selection.
/// Not undoable — mode-only, no mesh mutation.
///
/// Selection-types Stage 1: when an `applyHook` is supplied (the app wires it
/// to its geometry-type switch funnel), `apply()` routes the switch through it
/// so the SelType recent-ordering, the lockstep editMode write, the tool-drop
/// on a front-flip, and the `currentTypeChanged` bus note all happen in ONE
/// place — keyboard keys 1/2/3 and this command share that single funnel.
/// Without a hook (e.g. a standalone/headless construction) it falls back to
/// writing `*editModePtr` directly, preserving the original behavior.
class SelectTypeFromCommand : Command {
    private EditMode*               editModePtr;
    private string                  targetType;
    private void delegate(EditMode) applyHook;

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr,
         void delegate(EditMode) applyHook = null) {
        super(mesh, view, editMode);
        this.editModePtr = editModePtr;
        this.applyHook   = applyHook;
    }

    this(Mesh* mesh, ref View view, EditMode editMode, EditMode* editModePtr,
         string targetType, void delegate(EditMode) applyHook = null) {
        this(mesh, view, editMode, editModePtr, applyHook);
        this.targetType = targetType;
    }

    override string name()  const { return "select.typeFrom"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    void setTargetType(string t) { targetType = t; }

    override bool apply() {
        EditMode mode;
        switch (targetType) {
            case "vertex":  mode = EditMode.Vertices; break;
            case "edge":    mode = EditMode.Edges;    break;
            case "polygon": mode = EditMode.Polygons; break;
            default:
                throw new Exception(
                    "select.typeFrom: unknown type '" ~ targetType ~
                    "' — expected vertex, edge, or polygon");
        }
        if (applyHook !is null) applyHook(mode);
        else                    *editModePtr = mode;
        return true;
    }
}
