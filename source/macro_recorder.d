module macro_recorder;

// ---------------------------------------------------------------------------
// MacroRecorder — captures the canonical argstring of every successful
// command record() while active. Phase 7 of the history-panel design doc.
//
// Lifecycle (driven by macro.record / macro.saveRecorded commands +
// History panel toolbar buttons):
//   start() → onCommandRecorded(line) × N → stop() → saveAs(path)
//
// Capture sits OUTSIDE CommandHistory's stack. So:
//   - Macro buffer survives Undo/Redo (an undone command stays in the
//     captured macro).
//   - history.clear does NOT wipe the macro buffer.
//
// Output format mirrors HistorySaveAsScript's `.lxm` shape so the two
// paths can share script execution downstream.
// ---------------------------------------------------------------------------

import std.array : appender;
import std.file  : write;
import record_observer_hub : RecordObserverHub;

final class MacroRecorder {
    private RecordObserverHub observerHub_;

    /// The hub IS the recorder's storage: every read and write below forwards
    /// to it. It is required at construction. The former unbound arm — an
    /// `observerHub_ is null` branch on every method over a private `active_`
    /// flag and `lines_` buffer — had exactly one caller shape in the tree,
    /// app.d's `new MacroRecorder()` followed on the next line by
    /// `bindObserverHub(hub)`, and no test constructed one at all
    /// (`grep -rn 'new MacroRecorder' source tests` → app.d only; task 4066).
    this(RecordObserverHub hub) {
        assert(hub !is null, "MacroRecorder needs its RecordObserverHub");
        observerHub_ = hub;
    }

    bool   active() const { return observerHub_.macroActive; }
    size_t length() const { return observerHub_.macroLength; }

    /// Start a new recording. Clears any prior buffer — `macro.record 1`
    /// always begins a fresh sequence.
    void start() { observerHub_.startMacro(); }

    void stop() { observerHub_.stopMacro(); }

    /// Drop the captured buffer without changing active state.
    /// Backs the History panel's "clear macro" affordance.
    void clear() { observerHub_.clearMacro(); }

    /// Hook target for `CommandHistory.onRecord`. No-op when inactive.
    /// `_flags` reserved for future filtering (e.g. skip quiet/side-
    /// effect commands), unused today.
    void onCommandRecorded(string commandLine, uint /+flags+/ _flags) {
        observerHub_.observeLegacy(commandLine, _flags);
    }

    /// Snapshot of the captured lines (defensive dup so callers can
    /// keep reading after subsequent record() calls extend the buffer).
    string[] recordedLines() const { return observerHub_.macroLines(); }

    /// Write captured lines as a `.lxm` macro file. Returns false when
    /// path is empty (apply() can surface this as a command failure).
    /// Empty buffer is OK — produces a header-only file.
    bool saveAs(string path) {
        if (path.length == 0) return false;
        auto buf = appender!string();
        buf.put("#LXMacro#\n");
        foreach (line; recordedLines()) {
            buf.put(line);
            buf.put("\n");
        }
        write(path, buf.data);
        return true;
    }
}
