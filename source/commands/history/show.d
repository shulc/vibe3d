module commands.history.show;

import command;
import mesh;
import view;
import editmode;

/// Toggle the floating Command-History panel. Wired to a button in
/// buttons.yaml; the actual visibility flag lives in app.d, mutated via
/// the toggle delegate. Itself never lands on the undo stack
/// (isUndoable = false) — it's a UI-only command.
class HistoryShow : Command {
    private void delegate() toggle;

    this(Mesh* mesh, ref View view, EditMode editMode, void delegate() toggle) {
        super(mesh, view, editMode);
        this.toggle = toggle;
    }

    override string name()  const { return "history.show"; }
    override string label() const { return "History Panel"; }
    override bool   isUndoable() const { return false; }

    override bool apply() {
        if (toggle !is null) toggle();
        return true;
    }
}
