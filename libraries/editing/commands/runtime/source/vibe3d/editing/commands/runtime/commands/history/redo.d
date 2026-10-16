module vibe3d.editing.commands.runtime.commands.history.redo;

import vibe3d.editing.commands.runtime.command;
import vibe3d.editing.commands.runtime.command_history : CommandHistory;
import vibe3d.mesh.core.mesh;
import vibe3d.viewport.camera.view;
import vibe3d.editing.contracts.editmode;

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
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    protected override bool applyImpl() {
        return history.redo();
    }
}
