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
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    // Task 1521: quitting makes unsaved work unreachable, which is the same
    // question File → New asks — so it answers through the same predicate and
    // is guarded at the same single point (`runUiCommand`). The bespoke
    // `quitRequested` + modal-entry pair that task 0434 built is GONE; leaving
    // it in place would have asked twice, and — measured on rev.1 of the plan
    // — would have kept the guard at TWO points, so the mutation that removes
    // the guard reddened two of three paths instead of three.
    override bool discardsUnsavedWork() const { return true; }

    /// The window [X] / SIGINT route sets this. It changes exactly one thing:
    /// whether `--test` suppresses the exit (see `apply()`).
    void setFromWindowClose(bool v) { fromWindowClose_ = v; }
    private bool fromWindowClose_;

    override bool apply() {
        // --test SUPPRESSES THE COMMAND QUIT, AND ONLY THE COMMAND QUIT.
        // The harness closes the WINDOW to shut a session down, so that route
        // must still exit or every run hangs; a `file.quit` dispatched by a
        // test must not take the shared --test instance with it. This is what
        // unblocks the note at the head of tests/test_commands_file_misc.d.
        if (command.g_testMode && !fromWindowClose_) return true;
        if (onQuit_ !is null) onQuit_();
        return true;
    }
}
