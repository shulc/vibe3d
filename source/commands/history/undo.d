module commands.history.undo;

import command;
import command_history : CommandHistory;
import mesh;
import view;
import editmode;

/// Pop the top entry off the undo stack and revert it. Wired to Ctrl+Z
/// via shortcuts.yaml. Itself never lands on the undo stack
/// (isUndoable = false) — undo cannot undo itself.
class HistoryUndo : Command {
    private CommandHistory history;

    this(Mesh* mesh, ref View view, EditMode editMode, CommandHistory history) {
        super(mesh, view, editMode);
        this.history = history;
    }

    override string name()  const { return "history.undo"; }
    override string label() const { return "Undo"; }
    override bool   isUndoable() const { return false; }

    override bool apply() {
        return history.undo();
    }
}
