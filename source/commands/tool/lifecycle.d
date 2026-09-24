module commands.tool.lifecycle;

import command;
import mesh;
import view;
import editmode;
import std.json : JSONType, JSONValue;

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
    // A switch-restorable predecessor's parameter values (task 7118, gap
    // 221): undo re-arms it through `onRestore` with them.
    private JSONValue previousArgs_;

    // Hooks wired by app.d after construction.
    void delegate(string) onActivate;
    void delegate() onDeactivate;
    void delegate(string, JSONValue) onRestore;

    this(Mesh* mesh, ref View view, EditMode editMode,
         string armedId, string previousId,
         JSONValue previousArgs = JSONValue.init) {
        super(mesh, view, editMode);
        armedId_ = armedId.idup;
        previousId_ = previousId.idup;
        previousArgs_ = previousArgs;
        // The whole undo image is the predecessor identity. It exists from the
        // constructor, so the flag is raised there.
        noteUndoRecorded();
    }

    override string name()  const { return "tool.activate"; }
    override string label() const { return "Activate Tool"; }

    override CmdFlags cmdFlags() const { return CmdFlags.ToolLifecycle; }

    // Redo exists only for the captured none->cutting law (Slice, Edge
    // Slice, Loop Slice — gap row 205). The session's first gesture is NOT re-applied here: the session
    // replays it after this redo (EditSession.navigate, task 7137, §22), so
    // the raw redo doors re-arm bare.
    protected override bool applyImpl() {
        if (onActivate !is null) onActivate(armedId_);
        return true;
    }

    // Undo restores the classified predecessor, or leaves no active family.
    protected override void revertImpl() {
        if (previousId_.length == 0) {
            if (onDeactivate !is null) onDeactivate();
        } else if (onRestore !is null && previousArgs_.type == JSONType.object) {
            onRestore(previousId_, previousArgs_);
        } else if (onActivate !is null) {
            onActivate(previousId_);
        }
    }

    string armedId() const { return armedId_; }
    string previousId() const { return previousId_; }
    bool carriesRedoAfterUndo() const {
        return previousId_.length == 0 &&
            (armedId_ == "mesh.sliceTool" || armedId_ == "mesh.edgeSliceTool" ||
             armedId_ == "mesh.loopSliceTool");
    }
}
