module io.file_dialog_browser;

import io.formats : FilterSpec;

// Task 7400 widens the task-6870 contract. A browser save is SYNCHRONOUS: the
// target is a MEMFS path chosen without asking (`browserSaveTarget`, owner Q2)
// whose directory is created here, and the written file is handed to the
// browser afterwards by `io.file_dialog.deliverSavedFile`. A browser open is
// ASYNCHRONOUS: it parks the UI command being applied (`started`) and resumes
// it with a path later, so it refuses loudly when there is no UI command or
// the command has no `path` parameter to resume with. Plan:
// doc/web_file_io_plan_2026-09-23.md §3.1–§3.3.
enum BrowserPickOutcome {
    chosen,
    started,
    unavailable,
    failed,
}

struct BrowserPickResult {
    BrowserPickOutcome outcome;
    string detail;
    string path;   /// set iff `outcome == chosen`
}

enum string noUiCommandReason =
    "the browser file chooser needs a UI command to resume";

enum string noPathParamReason =
    "the browser file chooser needs a command with a path parameter";

BrowserPickResult pickOpenPath(FilterSpec[] filters, string startDir = null) {
    import io.browser_pick_resume : currentUiApply, pickIsMultiple, pickResumes;
    auto ctx = currentUiApply();
    if (ctx is null || ctx.command is null)
        return BrowserPickResult(BrowserPickOutcome.failed, noUiCommandReason);
    bool hasPath = false;
    foreach (ref p; ctx.command.params())
        if (p.name == "path") hasPath = true;
    if (!hasPath)
        return BrowserPickResult(BrowserPickOutcome.failed, noPathParamReason);
    const multiple = pickIsMultiple(filters);
    const token = pickResumes().start(*ctx, filters, multiple);
    version (web) {
        // The bridge opens a one-shot `<input type=file>`; its files land in
        // the directory D names (JS composes no path) and the answer comes
        // back through the two exports below (task 7420).
        import std.string : toStringz;
        import io.browser_pick_resume : acceptAttribute, workDirFor;
        vibe3d_web_pick_open(toStringz(acceptAttribute(filters)),
            multiple ? 1 : 0, token, toStringz(workDirFor(token)));
    }
    return BrowserPickResult(BrowserPickOutcome.started);
}

version (web) {
    // The JS library `web/lib/file_bridge.js` (task 7420, plan §3.1/§3.2).
    extern (C) void vibe3d_web_pick_open(const(char)* accept, int multiple,
                                         uint token, const(char)* dir) nothrow @nogc;
    extern (C) int vibe3d_web_offer_download(const(char)* path) nothrow @nogc;

    /// The browser wrote `fileCount` files for `token` into its directory.
    /// Only marks the queue record; the frame drain does the rest.
    export extern (C) void vibe3d_web_pick_done(uint token, uint fileCount) nothrow {
        import io.browser_pick_resume : pickResumes;
        try pickResumes().complete(token, fileCount);
        catch (Throwable) {}
    }

    /// The browser could not deliver the pick for `token` (`code` 0 is a
    /// cancel; see `io.browser_pick_resume.pickFailureText` for the rest).
    export extern (C) void vibe3d_web_pick_failed(uint token, int code) nothrow {
        import io.browser_pick_resume : pickResumes;
        try pickResumes().fail(token, code);
        catch (Throwable) {}
    }
}

BrowserPickResult pickSavePath(FilterSpec[] filters, string defaultName,
                               string startDir = null) {
    import std.file : mkdirRecurse;
    import std.path : dirName;
    import io.browser_pick_resume : browserSaveTarget, workRoot;
    import io.doc_state : currentDocPath;
    const target = browserSaveTarget(workRoot(), defaultName, currentDocPath());
    const dir = dirName(target);
    try {
        mkdirRecurse(dir);
    } catch (Exception e) {
        return BrowserPickResult(BrowserPickOutcome.failed,
            "could not prepare '" ~ dir ~ "': " ~ e.msg);
    }
    return BrowserPickResult(BrowserPickOutcome.chosen, null, target);
}
