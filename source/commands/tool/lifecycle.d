module commands.tool.lifecycle;

import command;
import mesh;
import view;
import editmode;

// ---------------------------------------------------------------------------
// ToolDeactivationCommand — tool.deactivate
//
// Records that a tool was dropped. Emitted by setActiveTool() (app.d) on every
// tool deactivation, for tools that opt in via Tool.emitsLifecycleUndo().
//
// revert() (undo) = re-activate the dropped tool by id — a stateless re-baseline
//   against post-undo geometry. Geometry no-op.
// apply()  (redo) = re-drop the tool. Geometry no-op.
//
// The undo cursor (R1)+(R2) in command_history.d treats this entry as transparent
// when its own-gesture Model entry sits below it (so undo₁ reverts geometry),
// and as a hard STEP otherwise (so undo₂ re-enters the tool).
// ---------------------------------------------------------------------------
class ToolDeactivationCommand : Command {
    private string droppedId_;

    // Hooks wired by app.d after construction.
    void delegate()         onApply;   // re-drop (redo)
    void delegate(string)   onRevert;  // re-activate by id (undo)

    this(Mesh* mesh, ref View view, EditMode editMode, string droppedId) {
        super(mesh, view, editMode);
        droppedId_ = droppedId;
    }

    override string name()  const { return "tool.deactivate"; }
    override string label() const { return "Deactivate Tool"; }

    override CmdFlags cmdFlags() const { return CmdFlags.ToolLifecycle; }

    // apply() = redo = re-drop the tool (geometry no-op).
    override bool apply() {
        if (onApply !is null) onApply();
        return true;
    }

    // revert() = undo = re-activate the dropped tool by id.
    override bool revert() {
        if (onRevert !is null) onRevert(droppedId_);
        return true;
    }

    string droppedId() const { return droppedId_; }
}
