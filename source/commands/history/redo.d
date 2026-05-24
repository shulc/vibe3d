module commands.history.redo;

import command;
import command_history : CommandHistory;
import mesh;
import view;
import editmode;

/// Pop the top entry off the redo stack and re-apply it. Wired to
/// Ctrl+Shift+Z via shortcuts.yaml. Itself never lands on the undo
/// stack (isUndoable = false) — redo isn't undoable.
class HistoryRedo : Command {
    private CommandHistory history;

    this(Mesh* mesh, ref View view, EditMode editMode, CommandHistory history) {
        super(mesh, view, editMode);
        this.history = history;
    }

    override string name()  const { return "history.redo"; }
    override string label() const { return "Redo"; }
    override bool   isUndoable() const { return false; }

    override bool apply() {
        return history.redo();
    }
}
