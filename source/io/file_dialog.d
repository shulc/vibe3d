module io.file_dialog;

// ---------------------------------------------------------------------------
// Task 1520 — ONE file chooser, and CANCEL IS NOT A REFUSAL.
//
// THE DEFECT THIS EXISTS FOR. Every caller of the native chooser collapsed
// THREE different outcomes into one empty string: the user pressed Cancel, the
// chooser could not be opened at all, and `--test` suppressed it. All three
// then became the same `refuse("no path given")`. Cancel is not an error — the
// user changed their mind — so even on the notice path (task 1520 Phase 1) a
// cancelled dialog would have popped "Load Image: no path given" at someone
// who had just pressed Cancel.
//
// THE FOURTH OUTCOME NOBODY HANDLED. `nfde.Result` has THREE values —
// `{ error, okay, cancel }` — and the vendor patch for task 0431 makes the
// whole binding return `Result.error` when there is no `DBUS_SESSION_BUS_ADDRESS`
// (the portal backend's autolaunch abort()s the process, so Init is skipped
// entirely). Every call site met that with `assert(result != Result.error,
// getError())`: an abort under `debug`, and silence under `-release`. The path
// is reachable on any session without a bus.
//
// Four outcomes, one type, one place. The POSIX/Windows narrow/wide
// `FilterItem` split — four copies of the same ten lines before this — comes
// with it.
//
// `--test` IS CHECKED FIRST and never touches nfde, which preserves the
// property the whole harness depends on: a headless run cannot open a native
// dialog nobody can click.
// ---------------------------------------------------------------------------

import nfde;
import io.formats : FilterSpec;

/// What the chooser did. The distinction the callers must keep is
/// `cancelled` vs everything else: only `cancelled` is silent.
enum PickOutcome {
    chosen,       /// the user picked a path
    cancelled,    /// the user dismissed the chooser — SILENT, not an error
    unavailable,  /// suppressed before it opened (`--test`)
    failed,       /// the chooser could not run (no session bus, portal error…)
}

struct PickResult {
    PickOutcome outcome;
    string      path;   /// set iff `outcome == chosen`
    string      error;  /// the backend's sentence, iff `outcome == failed`

    /// The refusal sentence a command should report for this outcome, and ""
    /// for a cancel. Handing the caller ONE function keeps the two decisions —
    /// "is this an error" and "what does it say" — from drifting apart, the
    /// same reason `ui/command_notice.d` is one function.
    string refusalReason() const {
        final switch (outcome) {
            case PickOutcome.chosen:      return "";
            case PickOutcome.cancelled:   return "";
            case PickOutcome.unavailable:
                return "no path given: the file dialog is suppressed in --test";
            case PickOutcome.failed:
                return "the file chooser failed: " ~ (error.length ? error
                                                                   : "unknown error");
        }
    }
}

private FilterItem[] toItems(FilterSpec[] fs, ref string[] keepAlive) {
    FilterItem[] items;
    version (Windows) {
        import std.utf : toUTF16z;
        foreach (ref f; fs)
            items ~= FilterItem(cast(const(ushort)*)f.name.toUTF16z,
                                cast(const(ushort)*)f.spec.toUTF16z);
    } else {
        import std.string : toStringz;
        foreach (ref f; fs)
            items ~= FilterItem(f.name.toStringz, f.spec.toStringz);
    }
    return items;
}

private PickResult classify(Result r, string path) {
    final switch (r) {
        case Result.okay:
            // A backend that answers `okay` with no path is answering
            // nonsense; treat it as a cancel rather than handing "" onward as
            // if it were a file name.
            return path.length ? PickResult(PickOutcome.chosen, path)
                               : PickResult(PickOutcome.cancelled);
        case Result.cancel: return PickResult(PickOutcome.cancelled);
        case Result.error:
            string e;
            try e = getError();
            catch (Exception) {}
            return PickResult(PickOutcome.failed, null, e);
    }
}

/// Open-file chooser. `--test` short-circuits to `unavailable`.
PickResult pickOpenPath(FilterSpec[] fs, string startDir = null) {
    import command : g_testMode;
    if (g_testMode) return PickResult(PickOutcome.unavailable);
    string[] keep;
    auto items = toItems(fs, keep);
    string path;
    auto r = openDialog(path, items, startDir);
    return classify(r, path);
}

/// Save-file chooser. `--test` short-circuits to `unavailable`.
PickResult pickSavePath(FilterSpec[] fs, string defaultName, string startDir = null) {
    import command : g_testMode;
    if (g_testMode) return PickResult(PickOutcome.unavailable);
    string[] keep;
    auto items = toItems(fs, keep);
    string path;
    auto r = saveDialog(path, items, defaultName, startDir);
    return classify(r, path);
}

unittest {
    // The whole point, as a table: only `cancelled` is silent, and `chosen`
    // is silent because there is nothing to report.
    assert(PickResult(PickOutcome.cancelled).refusalReason() == "");
    assert(PickResult(PickOutcome.chosen, "/tmp/x.v3d").refusalReason() == "");
    assert(PickResult(PickOutcome.unavailable).refusalReason().length > 0);
    assert(PickResult(PickOutcome.failed, null, "no portal").refusalReason().length > 0);
    // The backend's own sentence survives into the text the user reads.
    import std.algorithm : canFind;
    assert(PickResult(PickOutcome.failed, null, "no portal")
               .refusalReason().canFind("no portal"));
    // A `failed` with no message must still say something.
    assert(PickResult(PickOutcome.failed).refusalReason().length > 0);
}
