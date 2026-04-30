module command_history;

import command;

// ---------------------------------------------------------------------------
// CommandHistory — linear undo/redo stack of Command instances.
//
// Lifecycle: a Command is created via the registry, its apply() is invoked
// (possibly by the HTTP dispatcher or interactive tool), and on success the
// dispatcher passes the command to record(). The history retains the
// instance for the lifetime of the entry; revert() / re-apply() are called
// directly on it.
//
// State machine (mirrors LXSDK_661446/include/lxundo.h):
//   - Active   — record() pushes new entries, redo stack cleared on push.
//   - Suspend  — record() silently drops entries (no stack mutation). Used
//                during file load / internal sub-commands so they don't
//                pollute the undo timeline.
//   - Invalid  — record() refuses; treated as a programming error in
//                debug builds.
//
// Refire blocks (interactive tool drag / slider edit cycle) are deferred to
// Phase C of the plan; this Phase A implementation tracks individual
// records only.
// ---------------------------------------------------------------------------

enum UndoState { Invalid, Active, Suspend }

struct HistoryEntry {
    string  label;          // human-readable
    string  commandName;    // internal id (e.g. "mesh.bevel")
    Command cmd;            // owns the snapshot via instance fields
}

final class CommandHistory {
    private HistoryEntry[] undoStack;
    private HistoryEntry[] redoStack;
    private size_t maxDepth = 50;
    private UndoState _state = UndoState.Active;

    // ----- state -----------------------------------------------------------

    UndoState state() const { return _state; }
    void setState(UndoState s) { _state = s; }

    // RAII helper for "suspend during this scope, restore on exit".
    struct Suspend {
        private CommandHistory h;
        private UndoState prev;
        @disable this(this);
        ~this() { h._state = prev; }
    }
    Suspend suspended() {
        Suspend s = { h: this, prev: _state };
        _state = UndoState.Suspend;
        return s;
    }

    // ----- recording -------------------------------------------------------

    // Called by the HTTP dispatcher AFTER a successful apply(). The command
    // must already be holding its pre-apply snapshot in instance fields.
    void record(Command cmd) {
        if (cmd is null) return;
        if (!cmd.isUndoable) return;
        if (_state != UndoState.Active) return;

        HistoryEntry e = { label: cmd.label, commandName: cmd.name, cmd: cmd };
        undoStack ~= e;
        if (undoStack.length > maxDepth) {
            undoStack = undoStack[$ - maxDepth .. $];
        }
        // Any new action invalidates the redo timeline.
        redoStack.length = 0;
    }

    // ----- navigation ------------------------------------------------------

    bool canUndo() const { return undoStack.length > 0; }
    bool canRedo() const { return redoStack.length > 0; }

    bool undo() {
        if (undoStack.length == 0) return false;
        auto e = undoStack[$ - 1];
        undoStack.length -= 1;
        // Suspend recording while reverting so any internal sub-commands
        // the revert path triggers (e.g. selection/edge cache invalidate)
        // don't pollute the redo timeline.
        auto prev = _state;
        _state = UndoState.Suspend;
        scope(exit) _state = prev;
        if (!e.cmd.revert()) {
            // Revert failed; drop the entry (don't put back) to avoid a
            // stuck stack. Caller can detect via state changes.
            return false;
        }
        redoStack ~= e;
        return true;
    }

    bool redo() {
        if (redoStack.length == 0) return false;
        auto e = redoStack[$ - 1];
        redoStack.length -= 1;
        auto prev = _state;
        _state = UndoState.Suspend;
        scope(exit) _state = prev;
        if (!e.cmd.apply()) {
            return false;
        }
        undoStack ~= e;
        return true;
    }

    // ----- inspection (Edit menu, /api/history) ---------------------------

    string[] undoLabels() const {
        string[] out_;
        out_.reserve(undoStack.length);
        foreach (e; undoStack) out_ ~= e.label;
        return out_;
    }

    string[] redoLabels() const {
        string[] out_;
        out_.reserve(redoStack.length);
        foreach (e; redoStack) out_ ~= e.label;
        return out_;
    }

    void clear() {
        undoStack.length = 0;
        redoStack.length = 0;
    }
}
