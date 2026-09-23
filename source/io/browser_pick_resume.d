module io.browser_pick_resume;

// ---------------------------------------------------------------------------
// Task 7400 (web file I/O, slice S1a) — the browser's file chooser is
// ASYNCHRONOUS, so an open cannot finish inside the command's `apply`. The
// command that asked is parked here with the context of the UI door that
// applied it; when the browser has written the chosen files into MEMFS, the
// frame drain resumes THAT SAME command object with a `path` argument through
// the SAME door (`GuardedActionController.invoke`), so guard, history and
// notices are the desktop's. Contracts, in the order `drain` applies them:
// base revision taken by the FIRST drain after `start` (never at `start`, which
// runs before the frame's flush) → wait for the browser → wait while a guard
// prompt is pending → a failed pick is a notice → stale (revision moved, or the
// command no longer bound to the live edit target) is a notice → exactly one
// primary file → bind `path` → invoke → the record leaves the queue on EVERY
// outcome, its directory survives unless the resume was refused. Every MEMFS
// path is built from `workRoot()`; the literal lives only there. Design and
// cells: doc/web_file_io_plan_2026-09-23.md §3.1, §3.8; tests in
// tests/unit/browser_pick_resume_test.d.
// ---------------------------------------------------------------------------

import command : Command;
import command_history : RecordMode;
import editmode : EditMode;
import io.formats : FilterSpec;
import mesh : Mesh;
import ui.discard_guard : UiRunOutcome;

// ---------------------------------------------------------------------------
// The UI-apply context: which command the UI door is applying right now.
// ---------------------------------------------------------------------------

struct UiApplyContext {
    Command command;
    RecordMode mode;
    string id;
}

private UiApplyContext g_uiApply;
private bool g_uiApplyActive;

/// Open the context for one UI apply. Depth is exactly one: the door wraps a
/// single `apply` and a nested begin is a wiring error.
void beginUiApply(UiApplyContext ctx) {
    assert(!g_uiApplyActive, "beginUiApply: a UI apply context is already open");
    g_uiApply = ctx;
    g_uiApplyActive = true;
}

/// Close the context opened by `beginUiApply`. The door calls it from
/// `scope (exit)` so a throwing apply cannot leak it.
void endUiApply() {
    g_uiApply = UiApplyContext.init;
    g_uiApplyActive = false;
}

/// The context of the UI apply in progress, or null outside one.
UiApplyContext* currentUiApply() {
    return g_uiApplyActive ? &g_uiApply : null;
}

// ---------------------------------------------------------------------------
// The MEMFS root. The only place its literal may appear (census R19).
// ---------------------------------------------------------------------------

private string g_workRootOverride;

/// Root of every browser-chosen or browser-saved file.
string workRoot() {
    return g_workRootOverride.length ? g_workRootOverride : "/work";
}

version (unittest) {
    /// Point `workRoot()` at a host temp directory; `null` restores it.
    void setWorkRootForTest(string root) {
        g_workRootOverride = root;
    }
}

/// The MEMFS directory a pick with `token` writes its files into.
string workDirFor(uint token) {
    import std.conv : to;
    import std.path : buildPath;
    return buildPath(workRoot(), token.to!string);
}

/// Mirror of the JS bridge's per-pick byte limit, for the notice text only.
enum ulong kMaxWebPickBytes = 256UL * 1024 * 1024;

// ---------------------------------------------------------------------------
// Pure helpers.
// ---------------------------------------------------------------------------

private string[] filterExtensions(const(FilterSpec)[] fs) {
    import std.algorithm : canFind, splitter;
    import std.string : strip;
    import std.uni : toLower;
    string[] exts;
    foreach (ref f; fs)
        foreach (part; f.spec.splitter(',')) {
            auto e = part.strip.toLower;
            if (e.length && !exts.canFind(e)) exts ~= e;
        }
    return exts;
}

/// A document chooser (the filter names `v3d` or `lwo`) lets the user pick the
/// document together with its images; an image chooser takes one file.
bool pickIsMultiple(const(FilterSpec)[] fs) {
    import std.algorithm : canFind;
    auto exts = filterExtensions(fs);
    return exts.canFind("v3d") || exts.canFind("lwo");
}

/// Index of the single file in `names` whose extension the filter accepts,
/// or -1 with `why` set: none matched, or more than one did.
ptrdiff_t selectPrimary(string[] names, const(FilterSpec)[] fs, out string why) {
    import std.algorithm : canFind;
    import std.array : join;
    import std.path : extension;
    import std.uni : toLower;
    auto exts = filterExtensions(fs);
    ptrdiff_t found = -1;
    string[] hits;
    foreach (i, n; names) {
        auto e = extension(n);
        if (e.length > 1 && exts.canFind(e[1 .. $].toLower)) {
            found = cast(ptrdiff_t) i;
            hits ~= n;
        }
    }
    if (hits.length == 0) {
        why = "no supported file among: " ~ names.join(", ");
        return -1;
    }
    if (hits.length > 1) {
        why = "choose one document (got " ~ hits.join(", ") ~ ")";
        return -1;
    }
    return found;
}

/// Where a browser save writes: beside the open document (its name for a
/// native save, its stem plus the export extension otherwise), or
/// `<root>/untitled/<defaultName>` for an untitled document.
string browserSaveTarget(string root, string defaultName, string currentDocPath) {
    import std.path : baseName, buildPath, dirName, extension, stripExtension;
    if (currentDocPath.length == 0)
        return buildPath(root, "untitled", defaultName);
    return buildPath(dirName(currentDocPath),
        stripExtension(baseName(currentDocPath)) ~ extension(defaultName));
}

/// Whether a parked command still addresses the live edit target: the mesh it
/// bound at construction and the edit mode it was built under. A parked
/// command is never null: `pickOpenPath` refuses a context without one.
bool stillBoundTo(Command command, const(Mesh)* liveMesh, EditMode liveMode) {
    return command.meshPtr() is liveMesh
        && command.editModeVal() == liveMode;
}

/// Base names of the regular files directly under `dir` (sorted); empty when
/// the directory is absent. The production `listDir` port.
string[] listDirNames(string dir) {
    import std.algorithm : sort;
    import std.file : dirEntries, SpanMode;
    import std.path : baseName;
    string[] names;
    try {
        // An absent directory (or a file) throws here and lists nothing.
        foreach (e; dirEntries(dir, SpanMode.shallow))
            if (e.isFile) names ~= baseName(e.name);
    } catch (Exception) {
        return names;
    }
    sort(names);
    return names;
}

private void removeDirQuietly(string dir) nothrow {
    import std.file : rmdirRecurse;
    try rmdirRecurse(dir);   // an absent directory throws, and is ignored
    catch (Exception) {}
}

/// The notice for a pick the browser reported as failed (`code` from the JS
/// bridge: 1 too large, 2 browser read error, 3 MEMFS write error, 4 no user
/// activation).
string pickFailureText(int code) {
    import std.conv : to;
    switch (code) {
        case 1:
            return "Open: the chosen files are larger than "
                ~ (kMaxWebPickBytes / (1024 * 1024)).to!string ~ " MiB";
        case 2: return "Open: the browser could not read the chosen file";
        case 3: return "Open: the chosen file could not be stored in memory";
        case 4: return "Open: the file chooser needs a click or a key press";
        default: return "Open: file transfer failed";
    }
}

private void removePickDir(uint token) nothrow {
    try removeDirQuietly(workDirFor(token));
    catch (Exception) {}
}

enum string kStaleResumeText =
    "the document changed while the file chooser was open; choose the file again";

// ---------------------------------------------------------------------------
// The queue.
// ---------------------------------------------------------------------------

/// What a drain needs from the application. Built by the composition root.
struct PickDrainPorts {
    string[] delegate(string dir) listDir;
    UiRunOutcome delegate(Command, RecordMode, string) invoke;
    void delegate(string) notice;
    ulong delegate() revision;
    bool delegate(Command) stillBound;
    bool delegate() guardBusy;
}

private enum PickState { waiting, done, failed }

private struct PickResumeRecord {
    uint token;
    UiApplyContext ctx;
    FilterSpec[] filters;
    bool multiple;
    bool baseTaken;
    ulong base;
    PickState state;
    int failCode;
}

struct PickResumeQueue {
    private PickResumeRecord[] records_;
    private uint nextToken_;

    /// Number of parked picks (at most one).
    @property size_t length() const { return records_.length; }

    /// The parked command, or null.
    Command pendingCommand() {
        return records_.length ? records_[0].ctx.command : null;
    }

    /// Whether the parked pick lets the user choose several files.
    bool pendingMultiple() const {
        return records_.length && records_[0].multiple;
    }

    /// Park `ctx.command` for an asynchronous pick. Takes NO revision: the base
    /// is taken by the first drain, after the frame's flush.
    uint start(UiApplyContext ctx, FilterSpec[] filters, bool multiple) {
        // One pick at a time: a new one evicts the old record and its files.
        foreach (ref r; records_) removeDirQuietly(workDirFor(r.token));
        records_.length = 0;
        const token = ++nextToken_;
        records_ ~= PickResumeRecord(token, ctx, filters.dup, multiple);
        return token;
    }

    private ptrdiff_t indexOf(uint token) const nothrow {
        foreach (i, ref r; records_)
            if (r.token == token) return cast(ptrdiff_t) i;
        return -1;
    }

    /// The browser wrote the pick for `token` (`fileCount` is the bridge's
    /// report; the drain reads the directory itself). Stale tokens are dropped
    /// with their directory. Safe to call from the bridge callback.
    void complete(uint token, uint fileCount) nothrow {
        const i = indexOf(token);
        if (i < 0) { removePickDir(token); return; }
        records_[i].state = PickState.done;
    }

    /// The browser could not deliver the pick for `token`.
    void fail(uint token, int code) nothrow {
        const i = indexOf(token);
        if (i < 0) { removePickDir(token); return; }
        records_[i].state = PickState.failed;
        records_[i].failCode = code;
    }

    private void dropRecord(size_t i, bool removeFiles) {
        const token = records_[i].token;
        records_ = records_[0 .. i] ~ records_[i + 1 .. $];
        if (removeFiles) removeDirQuietly(workDirFor(token));
    }

    /// Resume what the browser has finished. Called once per frame after the
    /// change-bus flush and the guard's settle.
    void drain(in PickDrainPorts ports) {
        if (records_.length == 0) return;
        const rev = ports.revision();
        auto r = &records_[0];
        if (!r.baseTaken) {
            r.base = rev;
            r.baseTaken = true;
        }
        if (r.state == PickState.waiting) return;
        if (ports.guardBusy()) return;

        if (r.state == PickState.failed) {
            const code = r.failCode;
            dropRecord(0, true);
            ports.notice(pickFailureText(code));
            return;
        }
        if (rev != r.base || !ports.stillBound(r.ctx.command)) {
            dropRecord(0, true);
            ports.notice(kStaleResumeText);
            return;
        }

        const token = r.token;
        const dir = workDirFor(token);
        auto names = ports.listDir(dir);
        string why;
        const primary = selectPrimary(names, r.filters, why);
        if (primary < 0) {
            dropRecord(0, true);
            ports.notice("Open: " ~ why);
            return;
        }

        auto ctx = r.ctx;
        {
            import std.json : JSONValue;
            import std.path : buildPath;
            import command_args : bindArgs;
            auto payload = JSONValue(["path": JSONValue(buildPath(dir, names[primary]))]);
            try {
                bindArgs(ctx.command, payload);
            } catch (Exception e) {
                dropRecord(0, true);
                ports.notice("Open: " ~ e.msg);
                return;
            }
        }
        // The record leaves the queue BEFORE the door runs, on every outcome:
        // a deferred resume is owned by the guard from here on.
        dropRecord(0, false);
        const outcome = ports.invoke(ctx.command, ctx.mode, ctx.id);
        if (outcome == UiRunOutcome.refused) removeDirQuietly(dir);
    }
}

private PickResumeQueue g_pickResumes;

/// The process-wide queue the browser callbacks and the frame drain share.
ref PickResumeQueue pickResumes() {
    return g_pickResumes;
}

/// Drain the process-wide queue.
void drainPickResumes(in PickDrainPorts ports) {
    pickResumes().drain(ports);
}

version (unittest) {
    /// Empty the process-wide queue (its directories are left alone).
    void resetPickResumesForTest() {
        g_pickResumes = PickResumeQueue.init;
    }
}
