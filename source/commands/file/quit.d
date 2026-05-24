module commands.file.quit;

import command;
import mesh;
import view;
import editmode;

/// "File → Quit" — terminates the main loop cleanly. Wired in
/// app.d to a `() { running = false; }` delegate so the next pass
/// through `while (running)` falls out and the normal SDL / OpenGL
/// teardown runs. Not undoable; not history-tracked.
class FileQuit : Command {
    private void delegate() onQuit_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         void delegate() onQuit) {
        super(mesh, view, editMode);
        this.onQuit_ = onQuit;
    }

    override string name()  const { return "file.quit"; }
    override string label() const { return "Quit"; }
    override bool isUndoable() const { return false; }

    override bool apply() {
        if (onQuit_ !is null) onQuit_();
        return true;
    }
}
