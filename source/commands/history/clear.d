module commands.history.clear;

import command;
import mesh;
import view;
import editmode;

/// Wipe both undo + redo stacks. Backs the History panel's
/// right-click "Clear history" menu item (Phase 3 of the
/// history-panel design doc) and the `history.clear`
/// shortcut. Itself isn't recorded — clearing the stack while
/// recording its own entry would be a paradox.
class HistoryClear : Command {
    private void delegate() doClear;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() doClear) {
        super(mesh, view, editMode);
        this.doClear = doClear;
    }

    override string name()  const { return "history.clear"; }
    override string label() const { return "Clear History"; }
    override bool   isUndoable() const { return false; }

    override bool apply() {
        if (doClear !is null) doClear();
        return true;
    }
}
