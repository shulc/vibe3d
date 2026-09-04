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
    private bool     active_;        // start()/stop() toggles
    private string[] lines_;         // captured command-line buffer
    private RecordObserverHub observerHub_;

    void bindObserverHub(RecordObserverHub hub) nothrow @nogc {
        observerHub_ = hub;
    }

    bool active() const { return observerHub_ is null ? active_ : observerHub_.macroActive; }
    size_t length() const {
        return observerHub_ is null ? lines_.length : observerHub_.macroLength;
    }

    /// Start a new recording. Clears any prior buffer — `macro.record 1`
    /// always begins a fresh sequence.
    void start() {
        if (observerHub_ !is null) { observerHub_.startMacro(); return; }
        active_ = true;
        lines_.length = 0;
    }

    void stop() {
        if (observerHub_ !is null) { observerHub_.stopMacro(); return; }
        active_ = false;
    }

    /// Drop the captured buffer without changing active state.
    /// Backs the History panel's "clear macro" affordance.
    void clear() {
        if (observerHub_ !is null) { observerHub_.clearMacro(); return; }
        lines_.length = 0;
    }

    /// Hook target for `CommandHistory.onRecord`. No-op when inactive.
    /// `_flags` reserved for future filtering (e.g. skip quiet/side-
    /// effect commands), unused today.
    void onCommandRecorded(string commandLine, uint /+flags+/ _flags) {
        if (observerHub_ !is null) {
            observerHub_.observeLegacy(commandLine, _flags); return;
        }
        if (!active_) return;
        if (commandLine.length == 0) return;
        lines_ ~= commandLine;
    }

    /// Snapshot of the captured lines (defensive dup so callers can
    /// keep reading after subsequent record() calls extend the buffer).
    string[] recordedLines() const {
        return observerHub_ is null ? lines_.dup : observerHub_.macroLines();
    }

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
