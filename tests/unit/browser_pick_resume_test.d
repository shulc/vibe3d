// Task 7400 (web file I/O, slice S1a): the browser pick outcome, the resume
// queue and the UI door that parks and resumes a command. Cells R1–R13b, R2s,
// then the two source censuses R11 (the door's wrapping) and R19 (the MEMFS
// root literal) LAST, so a mutation that reddens a behavioural cell and a
// census reports the behavioural one first. Plan:
// doc/web_file_io_plan_2026-09-23.md, section "S1a".
module tests.unit.browser_pick_resume_test;

import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
import std.format : format;
import std.path : buildPath;
import std.process : thisProcessID;

import command : Command, g_testMode;
import command_history : RecordMode;
import commands.file.load : FileLoad;
import commands.image.commands : ImageLoad, ImageReplace;
import document : Document, ItemKind, Layer;
import editmode : EditMode;
import guarded_action_controller;
import io.browser_pick_resume;
import io.file_dialog : PickOutcome, PickResult, pickOpenPath,
                        selectBrowserBackendForTest;
import io.formats : FilterSpec;
import io.image_path : writeTestBmp;
import mesh : Mesh, makeCube;
import params : Param;
import ui.discard_guard : GuardAnswer, GuardRecord, UiRunOutcome;
import view : View;

private:

// ---------------------------------------------------------------------------
// Rig.
// ---------------------------------------------------------------------------

/// A fresh, unique work root under the host temp directory. The caller's
/// `scope (exit)` hands it to `dropRoot`.
string freshRoot(string tag) {
    auto root = buildPath(tempDir(),
        format("vibe3d_7400_%s_%d", tag, thisProcessID()));
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    setWorkRootForTest(root);
    return root;
}

void dropRoot(string root) {
    setWorkRootForTest(null);
    assert(workRoot() == "/work", "rig: the production root is restored");
    if (exists(root)) rmdirRecurse(root);
}

enum FilterSpec[] kDocFilters = [FilterSpec("Documents", "v3d,lwo")];
enum FilterSpec[] kImageFilters = [FilterSpec("Images", "png,jpg,jpeg,tga,bmp")];

/// A command whose schema has no `path` slot (the shape of `generate.open`).
final class NoPathCommand : Command {
    this(Mesh* m, ref View v) { super(m, v, EditMode.Vertices); }
    override string name() const { return "test.no_path"; }
    override Param[] params() { return []; }
    protected override bool applyImpl() {
        return pickOpenPath(kDocFilters).outcome == PickOutcome.chosen;
    }
}

/// Drain ports over counters; `invoke` answers `answer` and counts.
struct FakeDrain {
    int invokes;
    Command lastInvoked;
    RecordMode lastMode;
    string lastId;
    string[] notices;
    ulong rev;
    bool busy;
    bool delegate(Command) bound;
    UiRunOutcome answer = UiRunOutcome.applied;
    UiRunOutcome delegate(Command, RecordMode, string) invokeOverride;

    PickDrainPorts ports() {
        PickDrainPorts p;
        p.listDir = (string dir) => listDirNames(dir);
        p.invoke = (Command c, RecordMode m, string id) {
            ++invokes;
            lastInvoked = c;
            lastMode = m;
            lastId = id;
            return invokeOverride !is null ? invokeOverride(c, m, id) : answer;
        };
        p.notice = (string s) { notices ~= s; };
        p.revision = () => rev;
        p.stillBound = (Command c) => bound is null ? true : bound(c);
        p.guardBusy = () => busy;
        return p;
    }
}

/// The pick directory for `token`, built by the TEST from the root (not by
/// `workDirFor`, so a `workDirFor` that bypasses `workRoot()` is visible).
string pickDir(uint token) {
    return buildPath(workRoot(), token.to!string);
}

/// Write one file into the pick directory for `token`.
void dropDoc(uint token, string name = "scene.v3d") {
    auto dir = pickDir(token);
    mkdirRecurse(dir);
    write(buildPath(dir, name), "{}");
}

GuardedActionController controller(GuardApplyPort apply, bool delegate() dirty,
                                    Command[]* notices) {
    GuardedActionPorts ports;
    ports.apply = apply;
    ports.dirty = dirty;
    ports.save = () => false;
    ports.notice = (Command c) { *notices ~= c; };
    ports.observation.request = (GuardRecord r) {};
    ports.observation.answer = (GuardAnswer a, bool b) {};
    ports.observation.pending = (bool b) {};
    return new GuardedActionController(ports);
}

// ---------------------------------------------------------------------------
// R1 — `started` is silent.
// ---------------------------------------------------------------------------
unittest {
    assert(PickResult(PickOutcome.failed).refusalReason().length > 0,
        "R1 control: a failed pick still speaks");
    assert(PickResult(PickOutcome.started).refusalReason() == "",
        "R1: a started browser pick must be silent, got '"
        ~ PickResult(PickOutcome.started).refusalReason() ~ "'");
}

// ---------------------------------------------------------------------------
// R2 — Cancel-shaped path THROUGH the controller: the real FileLoad is parked,
// the same object, and the context is closed afterwards. R3 in the same block:
// outside the controller the chooser refuses loudly and parks nothing.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r2");
    const priorTest = g_testMode;
    scope (exit) {
        selectBrowserBackendForTest(false);
        g_testMode = priorTest;
        resetPickResumesForTest();
        dropRoot(root);
    }
    g_testMode = true;
    resetPickResumesForTest();
    selectBrowserBackendForTest(true);

    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    Command[] notices;
    auto ctl = controller((Command c, RecordMode m) => c.apply(), () => false, &notices);

    const outcome = ctl.invoke(load, RecordMode.Record, "file.open");
    assert(currentUiApply() is null, "R2: the UI-apply context is closed after invoke");
    assert(outcome == UiRunOutcome.refused,
        "R2: a parked open looks like a desktop Cancel to the door, got "
        ~ outcome.to!string);
    assert(notices.length == 1 && notices[0] is load
        && notices[0].refusalReason() == "",
        "R2: the notice port sees the command with an EMPTY reason (no text shown); got '"
        ~ (notices.length ? notices[0].refusalReason() : "<no notice>") ~ "'");
    assert(pickResumes().length == 1,
        "R2: the open must be parked in the queue, length "
        ~ pickResumes().length.to!string);
    assert(pickResumes().pendingCommand() is load,
        "R2: the queue holds the SAME command object");
    assert(pickResumes().pendingMultiple(),
        "R2: a document open lets the user pick the document with its images");
    // The resume carries the door's id and record mode back to the door.
    {
        FakeDrain d;
        const t = cast(uint) 1;
        dropDoc(t);
        pickResumes().complete(t, 1);
        drainPickResumes(d.ports());
        assert(d.invokes == 1 && d.lastInvoked is load, "R2 floor: the parked open resumed");
        assert(d.lastId == "file.open" && d.lastMode == RecordMode.Record,
            "R2: the resume carries id 'file.open' and mode Record, got '"
            ~ d.lastId ~ "' " ~ d.lastMode.to!string);
        assert(load.discardsUnsavedWork() && pickResumes().length == 0,
            "R2: the resumed open carries its path (guarded) and left the queue");
    }

    // R3 — no UI command.
    resetPickResumesForTest();
    const direct = pickOpenPath(kDocFilters);
    assert(direct.outcome == PickOutcome.failed
        && direct.refusalReason().canFind("needs a UI command"),
        "R3: a pick outside the UI door refuses loudly, got '"
        ~ direct.refusalReason() ~ "'");
    assert(pickResumes().length == 0, "R3: nothing parked without a UI command");
    PickResult nullCmd;
    {
        beginUiApply(UiApplyContext(null, RecordMode.Record, ""));
        scope (exit) endUiApply();
        nullCmd = pickOpenPath(kDocFilters);
    }
    assert(nullCmd.outcome == PickOutcome.failed
        && nullCmd.refusalReason().canFind("needs a UI command"),
        "R3: a context without a command is no UI command either");
    assert(pickResumes().length == 0, "R3: still nothing parked");
}

// ---------------------------------------------------------------------------
// R3b — a command without a `path` parameter cannot be resumed: refuse loudly.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r3b");
    scope (exit) {
        selectBrowserBackendForTest(false);
        resetPickResumesForTest();
        dropRoot(root);
    }
    resetPickResumesForTest();
    selectBrowserBackendForTest(true);

    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    {
        beginUiApply(UiApplyContext(load, RecordMode.Record, ""));
        scope (exit) endUiApply();
        const ok = pickOpenPath(kDocFilters);
        assert(ok.outcome == PickOutcome.started,
            "R3b control: FileLoad has a path parameter and is parked");
    }
    assert(pickResumes().length == 1, "R3b control: one record");

    resetPickResumesForTest();
    auto noPath = new NoPathCommand(doc.activeMesh(), v);
    PickResult got;
    {
        beginUiApply(UiApplyContext(noPath, RecordMode.Record, ""));
        scope (exit) endUiApply();
        got = pickOpenPath(kDocFilters);
    }
    assert(got.outcome == PickOutcome.failed
        && got.refusalReason().canFind("needs a command with a path parameter"),
        "R3b: a command with no path slot must refuse loudly, got "
        ~ got.outcome.to!string ~ " '" ~ got.refusalReason() ~ "'");
    assert(pickResumes().length == 0, "R3b: nothing parked for it");
}

// ---------------------------------------------------------------------------
// R4 — a stale token (evicted by a newer pick) resumes nothing.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r4");
    scope (exit) dropRoot(root);
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    auto ctx = UiApplyContext(load, RecordMode.Record, "");

    PickResumeQueue q;
    FakeDrain d;
    const t1 = q.start(ctx, kDocFilters, true);
    dropDoc(t1);
    const t2 = q.start(ctx, kDocFilters, true);
    assert(t1 != t2 && q.length == 1, "R4 floor: the newer pick evicts the older");
    assert(!exists(pickDir(t1)), "R4: eviction drops the older pick's files");
    dropDoc(t1);                                  // a late write for the old pick
    dropDoc(t2);
    q.complete(t1, 1);
    assert(!exists(pickDir(t1)), "R4: a stale completion drops its files");
    q.drain(d.ports());
    assert(d.invokes == 0, "R4: a stale token must not resume, invokes "
        ~ d.invokes.to!string);
    q.complete(t2, 1);
    q.drain(d.ports());
    assert(d.invokes == 1, "R4: the live token resumes once, invokes "
        ~ d.invokes.to!string);
}

// ---------------------------------------------------------------------------
// R5 / R5m — staleness by revision, and the MOMENT its base is taken.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r5");
    scope (exit) dropRoot(root);
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    auto ctx = UiApplyContext(load, RecordMode.Record, "");

    // Control: unchanged revision resumes.
    {
        PickResumeQueue q;
        FakeDrain d;
        d.rev = 5;
        const t = q.start(ctx, kDocFilters, true);
        q.drain(d.ports());                       // base := 5
        assert(d.invokes == 0 && q.length == 1, "R5 control: waiting for the browser");
        dropDoc(t);
        q.complete(t, 1);
        q.drain(d.ports());
        assert(d.invokes == 1, "R5 control: same revision resumes");
    }
    // R5m — complete before any drain; the base is the FIRST drain's revision.
    {
        PickResumeQueue q;
        FakeDrain d;
        d.rev = 7;
        const t = q.start(ctx, kDocFilters, true);
        dropDoc(t);
        q.complete(t, 1);
        q.drain(d.ports());
        assert(d.invokes == 1,
            "R5m: the base must be taken by the first drain (after the flush), "
            ~ "not at start; invokes " ~ d.invokes.to!string);
    }
    // R5 — the revision moved between the base and the resume.
    {
        PickResumeQueue q;
        FakeDrain d;
        d.rev = 5;
        const t = q.start(ctx, kDocFilters, true);
        q.drain(d.ports());                       // base := 5
        dropDoc(t);
        q.complete(t, 1);
        d.rev = 6;
        q.drain(d.ports());
        assert(d.invokes == 0, "R5: a changed document must not resume, invokes "
            ~ d.invokes.to!string);
        assert(d.notices.length == 1 && d.notices[0].canFind("document changed"),
            "R5: the user is told why");
        assert(q.length == 0 && !exists(pickDir(t)),
            "R5: the stale record and its files are gone");
    }
}

// ---------------------------------------------------------------------------
// R5b — the edit target: the parked command must still address the live mesh
// and mode (a primary switch does not move the revision).
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r5b");
    scope (exit) dropRoot(root);
    Mesh meshA = makeCube();
    Mesh meshB = makeCube();
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(&meshA, v, EditMode.Vertices, &doc);

    assert(stillBoundTo(load, &meshA, EditMode.Vertices), "R5b control: bound to meshA");
    assert(!stillBoundTo(load, &meshB, EditMode.Vertices), "R5b: another mesh");
    assert(!stillBoundTo(load, &meshA, EditMode.Polygons), "R5b: another mode");

    PickResumeQueue q;
    FakeDrain d;
    d.bound = (Command c) => stillBoundTo(c, &meshB, EditMode.Vertices);
    const t = q.start(UiApplyContext(load, RecordMode.Record, ""), kDocFilters, true);
    dropDoc(t);
    q.complete(t, 1);
    q.drain(d.ports());
    assert(d.invokes == 0,
        "R5b: a command bound to the old edit target must not resume, invokes "
        ~ d.invokes.to!string);
    assert(d.notices.length == 1 && d.notices[0].canFind("document changed"),
        "R5b: the user is told why");
}

// ---------------------------------------------------------------------------
// R6 — the primary file and the multiple-selection rule.
// ---------------------------------------------------------------------------
unittest {
    string why;
    assert(selectPrimary(["a.v3d", "tex.png"], kDocFilters, why) == 0, "R6: one document");
    assert(selectPrimary(["tex.png", "a.v3d"], kDocFilters, why) == 1, "R6: index into the input");
    assert(selectPrimary(["a.v3d", "b.lwo"], kDocFilters, why) == -1
        && why.canFind("choose one document"), "R6: two documents, got '" ~ why ~ "'");
    assert(selectPrimary(["x.txt"], kDocFilters, why) == -1
        && why.canFind("no supported file"), "R6: none, got '" ~ why ~ "'");
    assert(selectPrimary(["A.V3D"], kDocFilters, why) == 0, "R6: case-insensitive");
    assert(pickIsMultiple(kDocFilters), "R6: document picks are multiple");
    assert(!pickIsMultiple(kImageFilters), "R6: image picks take one file");
    assert(selectPrimary(["README", "a."], kDocFilters, why) == -1
        && why == "no supported file among: README, a.", "R6: extensionless names, got '"
        ~ why ~ "'");
}

// ---------------------------------------------------------------------------
// R6b — the production `listDir` port: regular files only, sorted; an absent
// directory lists nothing.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r6b");
    scope (exit) dropRoot(root);
    const dir = buildPath(root, "9");
    mkdirRecurse(buildPath(dir, "sub"));
    write(buildPath(dir, "b.v3d"), "{}");
    write(buildPath(dir, "a.png"), "x");
    assert(listDirNames(dir) == ["a.png", "b.v3d"],
        "R6b: files only, sorted; got " ~ listDirNames(dir).to!string);
    assert(listDirNames(buildPath(root, "absent")).length == 0, "R6b: absent directory");
}

// ---------------------------------------------------------------------------
// R7 — the resume binds `path` and KEEPS the other arguments: a real
// `image.replace index=<second image>` replaces that item and no other.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r7");
    scope (exit) dropRoot(root);
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    const p0 = buildPath(root, "src", "zero.bmp");
    const p1 = buildPath(root, "src", "one.bmp");
    writeTestBmp(p0, 3, 2);
    writeTestBmp(p1, 5, 7);
    foreach (p; [p0, p1]) {
        auto ld = new ImageLoad(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
        import command_args : bindArgs;
        import std.json : JSONValue;
        auto j = JSONValue(["path": JSONValue(p)]);
        bindArgs(ld, j);
        assert(ld.apply(), "R7 fixture: image.load " ~ p);
    }
    Layer[] images;
    foreach (l; doc.layers) if (l.kind == ItemKind.Image) images ~= l;
    assert(images.length == 2, "R7 floor: two image items");

    auto rep = new ImageReplace(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    {
        import command_args : bindArgs;
        import std.json : JSONValue;
        auto j = JSONValue(["index": JSONValue(cast(long) doc.indexOf(images[1]))]);
        bindArgs(rep, j);
    }
    PickResumeQueue q;
    FakeDrain d;
    d.invokeOverride = (Command c, RecordMode m, string id)
        => c.apply() ? UiRunOutcome.applied : UiRunOutcome.refused;
    const t = q.start(UiApplyContext(rep, RecordMode.Record, ""), kImageFilters, false);
    writeTestBmp(buildPath(pickDir(t), "fresh.bmp"), 9, 4);
    q.complete(t, 1);
    q.drain(d.ports());
    assert(d.invokes == 1 && d.notices.length == 0,
        "R7: the resume ran without a notice; notices: "
        ~ d.notices.to!string);
    assert(images[0].imageOrNull().storedPath == p0,
        "R7: item #0 untouched, got '" ~ images[0].imageOrNull().storedPath ~ "'");
    assert(images[1].imageOrNull().storedPath == buildPath(pickDir(t), "fresh.bmp"),
        "R7: item #1 replaced from the pick directory, got '"
        ~ images[1].imageOrNull().storedPath ~ "'");
}

// ---------------------------------------------------------------------------
// R8 — the discard guard predicate (divergence 1 of 2: asked AFTER the pick).
// ---------------------------------------------------------------------------
unittest {
    scope (exit) selectBrowserBackendForTest(false);
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto noPath = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    auto withPath = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    withPath.setPath("/somewhere/a.v3d");

    selectBrowserBackendForTest(false);
    assert(noPath.discardsUnsavedWork(), "R8 control: the desktop asks before the dialog");
    selectBrowserBackendForTest(true);
    assert(withPath.discardsUnsavedWork(), "R8: the resumed open (with a path) is guarded");
    assert(!noPath.discardsUnsavedWork(),
        "R8: a pathless browser open replaces nothing and must not prompt");
}

// ---------------------------------------------------------------------------
// R12 — a throwing apply cannot leak the UI-apply context.
// ---------------------------------------------------------------------------
unittest {
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    bool sawContext = false;
    bool boom = true;
    Command[] notices;
    auto ctl = controller((Command c, RecordMode m) {
        sawContext = currentUiApply() !is null && currentUiApply().command is c;
        if (boom) throw new Exception("R12 boom");
        return true;
    }, () => false, &notices);

    bool threw = false;
    try ctl.invoke(load, RecordMode.Record, "");
    catch (Exception e) threw = e.msg == "R12 boom";
    assert(threw && sawContext, "R12 floor: the context WAS open during the apply");
    assert(currentUiApply() is null, "R12: context leaked after a throwing apply");
    boom = false;
    assert(ctl.invoke(load, RecordMode.Record, "") == UiRunOutcome.applied,
        "R12: the next UI apply opens its context normally");

    // R12b — depth is exactly one: a nested begin is a wiring error.
    import core.exception : AssertError;
    bool nested = false;
    {
        beginUiApply(UiApplyContext(load, RecordMode.Record, ""));
        scope (exit) endUiApply();
        try beginUiApply(UiApplyContext(load, RecordMode.Record, ""));
        catch (AssertError) nested = true;
    }
    assert(nested, "R12b: a nested beginUiApply must assert");
    assert(currentUiApply() is null, "R12b: closed afterwards");
}

// ---------------------------------------------------------------------------
// R13 / R13b — a pending guard prompt holds the resume; the record leaves the
// queue on EVERY outcome, including a deferred one.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r13");
    scope (exit) dropRoot(root);
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    auto ctx = UiApplyContext(load, RecordMode.Record, "");

    PickResumeQueue q;
    FakeDrain d;
    const t = q.start(ctx, kDocFilters, true);
    dropDoc(t);
    q.complete(t, 1);
    d.busy = true;
    q.drain(d.ports());
    assert(d.invokes == 0 && q.length == 1 && exists(pickDir(t)),
        "R13: a pending guard holds the resume; invokes " ~ d.invokes.to!string
        ~ ", length " ~ q.length.to!string);
    d.busy = false;
    q.drain(d.ports());
    assert(d.invokes == 1, "R13: resumes once the guard is free");

    // R13b — deferred.
    PickResumeQueue q2;
    FakeDrain d2;
    d2.answer = UiRunOutcome.deferred;
    const t2 = q2.start(ctx, kDocFilters, true);
    dropDoc(t2);
    q2.complete(t2, 1);
    q2.drain(d2.ports());
    assert(d2.invokes == 1, "R13b floor: the deferred resume was invoked");
    assert(q2.length == 0, "R13b: a deferred resume leaves the queue");
    assert(exists(pickDir(t2)), "R13b: its files live on (the guard owns the path)");
    q2.drain(d2.ports());
    assert(d2.invokes == 1, "R13b: no second invoke after the guard settles, got "
        ~ d2.invokes.to!string);

    // The directory's fate follows the outcome: applied keeps, refused drops.
    assert(exists(pickDir(t)), "R13c: an applied resume keeps its files");
    PickResumeQueue q3;
    FakeDrain d3;
    d3.answer = UiRunOutcome.refused;
    const t3 = q3.start(ctx, kDocFilters, true);
    dropDoc(t3);
    q3.complete(t3, 1);
    q3.drain(d3.ports());
    assert(d3.invokes == 1 && q3.length == 0, "R13c floor: refused resume ran once");
    assert(!exists(pickDir(t3)), "R13c: a refused resume drops its files");
}

// ---------------------------------------------------------------------------
// R14 — a failed pick and a pick with no primary file are notices that drop
// the record and its files; a stale failure drops its files too.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r14");
    scope (exit) dropRoot(root);
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    auto ctx = UiApplyContext(load, RecordMode.Record, "");

    PickResumeQueue q;
    FakeDrain d;
    auto t = q.start(ctx, kDocFilters, true);
    dropDoc(t);
    q.fail(t, 1);
    q.drain(d.ports());
    assert(d.invokes == 0 && q.length == 0 && !exists(pickDir(t)),
        "R14: a failed pick resumes nothing and drops its files");
    assert(d.notices == ["Open: the chosen files are larger than 256 MiB"],
        "R14: the size notice, got " ~ d.notices.to!string);

    t = q.start(ctx, kDocFilters, true);
    q.fail(t, 99);
    q.drain(d.ports());
    assert(d.notices[$ - 1] == "Open: file transfer failed", "R14: unknown code");

    t = q.start(ctx, kDocFilters, true);
    const stale = q.start(ctx, kDocFilters, true);
    dropDoc(t);
    q.fail(t, 2);
    assert(!exists(pickDir(t)) && q.length == 1, "R14: a stale failure drops its files only");

    dropDoc(stale, "notes.txt");
    q.complete(stale, 1);
    q.drain(d.ports());
    assert(d.invokes == 0 && q.length == 0 && !exists(pickDir(stale)),
        "R14: no primary file resumes nothing and drops the files");
    assert(d.notices[$ - 1] == "Open: no supported file among: notes.txt",
        "R14: the no-primary notice, got '" ~ d.notices[$ - 1] ~ "'");
}

// ---------------------------------------------------------------------------
// R2s — the `settle` door (its second surface): a command deferred by the
// guard and performed at settle is applied inside the UI-apply context too.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("r2s");
    const priorTest = g_testMode;
    scope (exit) {
        selectBrowserBackendForTest(false);
        g_testMode = priorTest;
        resetPickResumesForTest();
        dropRoot(root);
    }
    g_testMode = true;
    resetPickResumesForTest();
    selectBrowserBackendForTest(false);

    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    Command[] notices;
    auto ctl = controller((Command c, RecordMode m) => c.apply(), () => true, &notices);
    assert(ctl.invoke(load, RecordMode.Record, "file.open") == UiRunOutcome.deferred
        && ctl.pending, "R2s floor: the desktop guard defers the open");
    ctl.answerDiscard();
    selectBrowserBackendForTest(true);
    ctl.settle();
    assert(currentUiApply() is null, "R2s: the context is closed after settle");
    assert(pickResumes().length == 1 && pickResumes().pendingCommand() is load,
        "R2s: the open performed at settle is parked, length "
        ~ pickResumes().length.to!string);
}

// ---------------------------------------------------------------------------
// R10 — the browser save target (root is a parameter).
// ---------------------------------------------------------------------------
unittest {
    assert(browserSaveTarget("/r", "Untitled.v3d", "") == "/r/untitled/Untitled.v3d",
        "R10: untitled");
    assert(browserSaveTarget("/r", "Untitled.v3d", "/w/7/scene.v3d") == "/w/7/scene.v3d",
        "R10: beside the open document, its own name");
    assert(browserSaveTarget("/r", "Untitled.lwo", "/w/7/scene.v3d") == "/w/7/scene.lwo",
        "R10: an export takes the document's stem");
}

// ---------------------------------------------------------------------------
// The D lexer both censuses use: comments blanked, every string literal
// form's CONTENT collected (checklist 3: every spelling).
// ---------------------------------------------------------------------------

struct Lexed {
    string code;          /// source with comments replaced by spaces
    string[] literals;    /// contents of every string literal
}

bool identChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

Lexed lexD(string s) {
    Lexed r;
    char[] code = s.dup;
    size_t i = 0;
    void blank(size_t a, size_t b) {
        foreach (k; a .. b) if (code[k] != '\n') code[k] = ' ';
    }
    size_t quoted(size_t start, char close, bool escapes) {
        size_t j = start;
        while (j < s.length && s[j] != close) j += (escapes && s[j] == '\\') ? 2 : 1;
        r.literals ~= s[start .. (j < s.length ? j : s.length)];
        return j + 1;
    }
    while (i < s.length) {
        const c = s[i];
        if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
            size_t j = i;
            while (j < s.length && s[j] != '\n') ++j;
            blank(i, j); i = j;
        } else if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
            size_t j = i + 2;
            while (j + 1 < s.length && !(s[j] == '*' && s[j + 1] == '/')) ++j;
            j = j + 2 > s.length ? s.length : j + 2;
            blank(i, j); i = j;
        } else if (c == '/' && i + 1 < s.length && s[i + 1] == '+') {
            size_t j = i + 2, depth = 1;
            while (j + 1 < s.length && depth > 0) {
                if (s[j] == '/' && s[j + 1] == '+') { ++depth; j += 2; }
                else if (s[j] == '+' && s[j + 1] == '/') { --depth; j += 2; }
                else ++j;
            }
            blank(i, j); i = j;
        } else if (c == '"') {
            i = quoted(i + 1, '"', true);
        } else if (c == '`') {
            i = quoted(i + 1, '`', false);
        } else if (c == '\'') {
            size_t j = i + 1;
            while (j < s.length && s[j] != '\'') j += s[j] == '\\' ? 2 : 1;
            i = j + 1;
        } else if (identChar(c)) {
            size_t j = i;
            while (j < s.length && identChar(s[j])) ++j;
            const word = s[i .. j];
            if (j < s.length && s[j] == '"' && (word == "r" || word == "x")) {
                i = quoted(j + 1, '"', false);
            } else if (j < s.length && word == "q" && s[j] == '"') {
                size_t k = j + 1;
                const open = k < s.length ? s[k] : '\0';
                char close = open == '(' ? ')' : open == '[' ? ']'
                    : open == '{' ? '}' : open == '<' ? '>' : open;
                if (identChar(open)) {
                    // heredoc: q"ID\n ... \nID"
                    size_t e = k;
                    while (e < s.length && s[e] != '\n') ++e;
                    const id = s[k .. e];
                    size_t m = e + 1, bodyStart = m;
                    while (m < s.length) {
                        size_t ls = m;
                        while (m < s.length && s[m] != '\n') ++m;
                        if (s[ls .. m].length > id.length && s[ls .. ls + id.length] == id
                            && s[ls + id.length] == '"') {
                            r.literals ~= s[bodyStart .. ls];
                            m = ls + id.length + 1;
                            break;
                        }
                        ++m;
                    }
                    i = m;
                } else {
                    size_t depth = 1, m = k + 1;
                    while (m < s.length) {
                        if (open != close && s[m] == open) ++depth;
                        else if (s[m] == close && --depth == 0) break;
                        ++m;
                    }
                    r.literals ~= s[k + 1 .. m];
                    i = m + 2;   // closer and the quote
                }
            } else if (j < s.length && word == "q" && s[j] == '{') {
                size_t depth = 1, m = j + 1;
                while (m < s.length && depth > 0) {
                    if (s[m] == '{') ++depth;
                    else if (s[m] == '}') --depth;
                    if (depth > 0) ++m;
                }
                r.literals ~= s[j + 1 .. m];
                i = m + 1;
            } else {
                i = j;
            }
        } else {
            ++i;
        }
    }
    r.code = code.idup;
    return r;
}

bool isWorkRootLiteral(string content) {
    import std.regex : ctRegex, matchFirst;
    return !matchFirst(content, ctRegex!`^/work(/|$)`).empty;
}

size_t workLiteralCount(string src) {
    size_t n;
    foreach (lit; lexD(src).literals) if (isWorkRootLiteral(lit)) ++n;
    return n;
}

// ---------------------------------------------------------------------------
// Lexer controls (checklist 5: a negative needs a positive control).
// ---------------------------------------------------------------------------
unittest {
    enum sample = q"SAMPLE
auto a = "/work";
auto b = "/work/" ~ t;
auto c = r"/work/x";
auto d = `/work`;
auto e = q"(/work/y)";
auto f = q{/work};
auto g = "doc/tasks/work/note.md";
auto h = "snap/types/workplane";
auto i = "/workplane";
auto j = '"';
auto k = "\"/work\"";
auto o = r"a\" ~ "/work/z";
// auto l = "/work";
/* auto m = "/work"; */
/+ /+ nested +/ auto n = "/work"; +/
SAMPLE";
    assert(workLiteralCount(sample) == 7,
        "R19 lexer control: seven spellings of the root, none of the rest; got "
        ~ workLiteralCount(sample).to!string);
    assert(workLiteralCount(`x = "/workshop";`) == 0, "R19 lexer control: a prefix is not the root");
}

// ---------------------------------------------------------------------------
// R11 — the door's wrapping, read from the PRODUCTION source (not a stand-in
// controller): each `ports_.apply(command, mode)` sits in its own block that
// opens the UI-apply context and closes it with `scope (exit)`, and that block
// ends before the observation/notice ports run.
// ---------------------------------------------------------------------------
unittest {
    import std.file : readText;
    import std.regex : regex, matchAll, matchFirst;
    import std.string : indexOf, lastIndexOf;

    const code = lexD(readText("source/guarded_action_controller.d")).code;
    enum needle = "ports_.apply(command, mode)";
    size_t[] hits;
    for (ptrdiff_t p = code.indexOf(needle); p >= 0;
         p = code.indexOf(needle, p + 1))
        hits ~= cast(size_t) p;
    assert(hits.length == 2,
        "R11 floor: ports_.apply(command, mode) occurs in invoke and settle, got "
        ~ hits.length.to!string);

    foreach (p; hits) {
        const before = code[0 .. p];
        const inv = before.lastIndexOf("UiRunOutcome invoke(");
        const set = before.lastIndexOf("bool settle(");
        const surface = inv > set ? "invoke" : "settle";

        ptrdiff_t open = -1;
        {
            int depth = 0;
            for (ptrdiff_t k = cast(ptrdiff_t) p - 1; k >= 0; --k) {
                if (code[k] == '}') ++depth;
                else if (code[k] == '{') { if (depth == 0) { open = k; break; } --depth; }
            }
        }
        ptrdiff_t close = -1;
        {
            int depth = 0;
            foreach (k; p .. code.length) {
                if (code[k] == '{') ++depth;
                else if (code[k] == '}') { if (depth == 0) { close = cast(ptrdiff_t) k; break; } --depth; }
            }
        }
        assert(open >= 0 && close > cast(ptrdiff_t) p, "R11 (" ~ surface ~ "): block not found");
        const head = code[open .. p];
        auto begin = matchFirst(head, regex(`beginUiApply\s*\(`));
        auto guard = matchFirst(head, regex(`scope\s*\(\s*exit\s*\)\s*endUiApply\s*\(\s*\)\s*;`));
        assert(!begin.empty,
            "R11 (" ~ surface ~ "): the apply's block must open the UI-apply context");
        assert(!guard.empty,
            "R11 (" ~ surface ~ "): the context must be closed by scope (exit) endUiApply();");
        assert(begin.pre.length < guard.pre.length,
            "R11 (" ~ surface ~ "): beginUiApply precedes its scope (exit)");
        const after = code[p .. $];
        ptrdiff_t nextPort = -1;
        foreach (port; ["ports_.observation", "ports_.notice"]) {
            const q = after.indexOf(port);
            if (q >= 0 && (nextPort < 0 || q < nextPort)) nextPort = q;
        }
        assert(nextPort >= 0 && cast(ptrdiff_t) p + nextPort > close,
            "R11 (" ~ surface ~ "): the context block must close before the "
            ~ "observation/notice ports run");
    }
}

// ---------------------------------------------------------------------------
// R19 — the MEMFS root literal lives in exactly one place in source/.
// ---------------------------------------------------------------------------
unittest {
    import std.file : dirEntries, readText, SpanMode;
    string[] where;
    size_t files;
    foreach (e; dirEntries("source", "*.d", SpanMode.depth)) {
        ++files;
        const n = workLiteralCount(readText(e.name));
        foreach (_; 0 .. n) where ~= e.name;
    }
    assert(files > 500, "R19 floor: the scan reached source/, files " ~ files.to!string);
    assert(where == ["source/io/browser_pick_resume.d"],
        "R19: the \"/work\" root literal must appear exactly once, in "
        ~ "source/io/browser_pick_resume.d; found " ~ where.to!string);
}
