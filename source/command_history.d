module command_history;

import command;
import argstring : serializeParams;

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
// Refire blocks (Phase C) — direct port of MODO's CmdRefireBegin/End pattern
// (LXSDK_661446/include/lxcommand.h:2406-2423). Inside a refire block, each
// fire() reverts the previous live command before applying the new one.
// refireEnd() commits the latest live command as a single undo entry — the
// net effect of an interactive drag is one stack entry, regardless of how
// many sub-fires happened.
// ---------------------------------------------------------------------------

enum UndoState { Invalid, Active, Suspend }

struct HistoryEntry {
    string  label;          // human-readable
    string  args;           // serialized argstring (user-set params only)
    string  commandName;    // internal id (e.g. "mesh.bevel")
    Command cmd;            // owns the snapshot via instance fields
}

final class CommandHistory {
    private HistoryEntry[] undoStack;
    private HistoryEntry[] redoStack;
    private size_t maxDepth = 50;
    private UndoState _state = UndoState.Active;

    // Refire block state. One slot — refire blocks don't nest. fire()
    // checks `refireOpen` to decide whether to revert the previous live
    // command before applying the new one.
    private bool    refireOpen = false;
    private Command liveCmd;

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

        HistoryEntry e = { label: cmd.label,
                           args:  serializeParams(cmd.params()),
                           commandName: cmd.name,
                           cmd: cmd };
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

    // Composed format: "Label  args" (two spaces) for non-empty args,
    // or just "Label" when args is empty. Used by the UI history panel.
    string[] undoLabels() const {
        string[] out_;
        out_.reserve(undoStack.length);
        foreach (e; undoStack)
            out_ ~= e.args.length > 0 ? (e.label ~ "  " ~ e.args) : e.label;
        return out_;
    }

    string[] redoLabels() const {
        string[] out_;
        out_.reserve(redoStack.length);
        foreach (e; redoStack)
            out_ ~= e.args.length > 0 ? (e.label ~ "  " ~ e.args) : e.label;
        return out_;
    }

    // Structured access — used by /api/history JSON serializer.
    const(HistoryEntry)[] undoEntries() const { return undoStack; }
    const(HistoryEntry)[] redoEntries() const { return redoStack; }

    /// Returns the canonical argstring line for undoStack[index]:
    /// `commandName + " " + args` if args is non-empty, else `commandName`.
    /// Returns "" when index is out of range.
    /// Used by /api/history/replay to re-execute past commands through the
    /// same dispatch path as /api/command without modifying the original entry.
    string undoEntryCommandLine(size_t index) const {
        if (index >= undoStack.length) return "";
        auto e = undoStack[index];
        return e.args.length > 0 ? (e.commandName ~ " " ~ e.args) : e.commandName;
    }

    void clear() {
        undoStack.length = 0;
        redoStack.length = 0;
    }

    // ----- refire ----------------------------------------------------------
    // refireBegin / fire / refireEnd model an interactive edit cycle:
    //   begin, fire, fire, fire, ..., end.
    // Each fire reverts the previous one and applies the new (so the mesh
    // walks "from pre-cycle state → newest params" without accumulation).
    // refireEnd pushes the latest live command onto the undo stack as one
    // entry. Outside a refire block, callers should use record() for the
    // post-mutation Record-flavor or apply()+record() for the standard path.

    bool refireActive() const { return refireOpen; }

    void refireBegin() {
        // Defensive: if a prior refire block was left dangling (e.g. tool
        // crashed mid-drag), commit it first so we don't lose the entry.
        if (refireOpen && liveCmd !is null) {
            HistoryEntry e = { label: liveCmd.label,
                               args:  serializeParams(liveCmd.params()),
                               commandName: liveCmd.name,
                               cmd: liveCmd };
            undoStack ~= e;
            if (undoStack.length > maxDepth)
                undoStack = undoStack[$ - maxDepth .. $];
            redoStack.length = 0;
        }
        refireOpen = true;
        liveCmd    = null;
    }

    // Apply cmd. If a live command from a previous fire() is present, its
    // revert() runs first so the mesh walks back to the pre-block state
    // before the new command lays down its mutation. Sub-commands fired
    // during apply()/revert() are suspended so they don't pollute history.
    bool fire(Command cmd) {
        if (cmd is null) return false;
        if (!refireOpen) {
            // Caller forgot refireBegin(); treat as a plain apply+record.
            if (!cmd.apply()) return false;
            record(cmd);
            return true;
        }
        auto prev = _state;
        _state = UndoState.Suspend;
        scope(exit) _state = prev;

        if (liveCmd !is null) {
            if (!liveCmd.revert()) return false;
        }
        if (!cmd.apply()) {
            liveCmd = null;
            return false;
        }
        liveCmd = cmd;
        return true;
    }

    // Closes the refire block. The latest live command (if any) lands on
    // the undo stack as ONE entry. record()'s flag-and-state checks
    // (isUndoable, _state) apply: a non-undoable live command is dropped.
    void refireEnd() {
        if (!refireOpen) return;
        Command final_ = liveCmd;
        refireOpen = false;
        liveCmd    = null;
        if (final_ !is null) record(final_);
    }
}
