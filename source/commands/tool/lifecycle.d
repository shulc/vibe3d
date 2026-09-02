module commands.tool.lifecycle;

import command;
import mesh;
import view;
import editmode;

// ---------------------------------------------------------------------------
// ToolActivationCommand — tool.activate
//
// Records that a tool was armed, with the previously active tool as its undo
// image. Emitted after a prepared tool transition installs successfully.
//
// revert() (undo) = restore the predecessor identity. Geometry no-op.
// apply()  (redo) = re-activate the armed tool. Geometry no-op.
//
// The history cursor treats this entry as an ordinary strict-LIFO step.
// Undo restores the captured predecessor before any earlier UI or Model entry.
// ---------------------------------------------------------------------------
interface ToolArmLifecyclePolicy {
    string armedId() const;
    string previousId() const;
    bool carriesRedoAfterUndo() const;
}

class ToolActivationCommand : Command, ToolArmLifecyclePolicy {
    private string armedId_;
    private string previousId_;

    // Hooks wired by app.d after construction.
    void delegate(string) onActivate;
    void delegate() onDeactivate;

    this(Mesh* mesh, ref View view, EditMode editMode,
         string armedId, string previousId) {
        super(mesh, view, editMode);
        armedId_ = armedId.idup;
        previousId_ = previousId.idup;
        // The whole undo image is the predecessor identity. It exists from the
        // constructor, so the flag is raised there.
        noteUndoRecorded();
    }

    override string name()  const { return "tool.activate"; }
    override string label() const { return "Activate Tool"; }

    override CmdFlags cmdFlags() const { return CmdFlags.ToolLifecycle; }

    // Redo exists only for the captured none->cutting law.
    protected override bool applyImpl() {
        if (onActivate !is null) onActivate(armedId_);
        return true;
    }

    // Undo restores the classified predecessor, or leaves no active family.
    protected override void revertImpl() {
        if (previousId_.length == 0) {
            if (onDeactivate !is null) onDeactivate();
        } else if (onActivate !is null) {
            onActivate(previousId_);
        }
    }

    string armedId() const { return armedId_; }
    string previousId() const { return previousId_; }
    bool carriesRedoAfterUndo() const {
        return previousId_.length == 0 && armedId_ == "mesh.sliceTool";
    }
}
