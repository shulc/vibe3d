// Task 7420 (web file I/O, slice S2): the desktop half of the browser bridge.
// Behavioural cells first (S2-1 silent cancel, S2-2 the chooser's accept
// attribute, S2-3 the MEMFS sweep on the next open, owner 2026-09-24), then the
// source census of the production wiring LAST (plan S2 п.10 with opponent R2
// fix #5: comment-stripped, and the port check scoped to the arguments of the
// ONE `PickDrainPorts(` construction). Plan: doc/web_file_io_plan_2026-09-23.md
// "S2"; browser witnesses: tools/web_file_io/case_v3d.mjs.
module tests.unit.web_file_io_page_test;

import std.algorithm : canFind;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.format : format;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.process : thisProcessID;
import std.string : indexOf, lastIndexOf, strip;

import command : Command;
import command_history : RecordMode;
import commands.file.load : FileLoad;
import document : Document;
import editmode : EditMode;
import io.browser_pick_resume;
import io.formats : FilterSpec;
import mesh : makeCube;
import tests.unit.census_symbols : balancedSpan, blankNonCode, countOccurrences;
import ui.discard_guard : UiRunOutcome;
import view : View;

private:

enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
enum FilterSpec[] kDocFilters = [FilterSpec("Documents", "v3d,lwo")];

string freshRoot(string tag) {
    auto root = buildPath(tempDir(), format("vibe3d_7420_%s_%d", tag, thisProcessID()));
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    setWorkRootForTest(root);
    return root;
}

void dropRoot(string root) {
    setWorkRootForTest(null);
    resetPickResumesForTest();
    if (exists(root)) rmdirRecurse(root);
}

string mkPickDir(string name) {
    auto dir = buildPath(workRoot(), name);
    mkdirRecurse(dir);
    write(buildPath(dir, "f.bin"), "x");
    return dir;
}

PickDrainPorts ports(ref string[] notices, ref int invokes) {
    PickDrainPorts p;
    p.listDir = (string dir) => listDirNames(dir);
    p.invoke = (Command c, RecordMode m, string id) { ++invokes; return UiRunOutcome.applied; };
    p.notice = (string s) { notices ~= s; };
    p.revision = () => 0UL;
    p.stillBound = (Command c) => true;
    p.guardBusy = () => false;
    return p;
}

// ---------------------------------------------------------------------------
// S2-1 — a cancelled pick (bridge code 0) is silent and leaves nothing behind;
// the rig's notice port is live (a code-3 failure right after is one notice).
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("s2cancel");
    scope (exit) dropRoot(root);
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);
    auto ctx = UiApplyContext(load, RecordMode.Record, "");
    string[] notices;
    int invokes;

    PickResumeQueue q;
    auto t = q.start(ctx, kDocFilters, true);
    mkPickDir(t.to!string);
    q.fail(t, kPickCancelled);
    q.drain(ports(notices, invokes));
    assert(q.length == 0 && invokes == 0 && !exists(buildPath(root, t.to!string)),
        "S2-1: a cancelled pick must leave the queue and its directory");
    assert(notices.length == 0, "S2-1: a cancel is silent, got " ~ notices.to!string);

    t = q.start(ctx, kDocFilters, true);
    q.fail(t, 3);
    q.drain(ports(notices, invokes));
    assert(notices == ["Open: the chosen file could not be stored in memory"],
        "S2-1 control: a real failure right after is one notice, got " ~ notices.to!string);
}

// ---------------------------------------------------------------------------
// S2-2 — the `accept` attribute is every filter extension, dotted.
// ---------------------------------------------------------------------------
unittest {
    assert(acceptAttribute(kDocFilters) == ".v3d,.lwo",
        "S2-2: got " ~ acceptAttribute(kDocFilters));
    assert(acceptAttribute([FilterSpec("Images", "png, JPG"), FilterSpec("More", "png,tga")])
        == ".png,.jpg,.tga", "S2-2: lower-cased, trimmed, deduplicated");
}

// ---------------------------------------------------------------------------
// S2-3 — the MEMFS sweep on the next open, through the production wrapper
// `sweepPickDirsOnOpen` (its gate, its guard wait and the parked record's
// directory all belong to it). Controls come BEFORE the sweep they gate.
// ---------------------------------------------------------------------------
unittest {
    const root = freshRoot("s2sweep");
    scope (exit) dropRoot(root);
    resetPickResumesForTest();
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto load = new FileLoad(doc.activeMesh(), v, EditMode.Vertices, &doc);

    const oldDoc = mkPickDir("11");      // the previous document
    const newDoc = mkPickDir("12");      // the document just opened
    const newImg = mkPickDir("13");      // an image of the new document
    const oldImg = mkPickDir("15");      // an image only the old one used
    const untitled = mkPickDir("untitled");
    const parked = pickResumes().start(UiApplyContext(load, RecordMode.Record, ""),
        kDocFilters, true);
    const parkedDir = mkPickDir(parked.to!string);
    assert(pickDirNames().length == 6, "S2-3 floor: six directories, got "
        ~ pickDirNames().to!string);

    const doc2 = buildPath(newDoc, "b.v3d");
    const img2 = [buildPath(newImg, "i.png")];

    // No document yet: nothing to sweep.
    assert(sweepPickDirsOnOpen(true, "", null, false) == 0, "S2-3: no document, no sweep");
    // Off the browser model the disk is the user's: never touched.
    assert(sweepPickDirsOnOpen(false, doc2, img2, false) == 0
        && pickDirNames().length == 6, "S2-3: the desktop model must not sweep");
    // A pending guard owns a deferred open's directory: wait.
    assert(sweepPickDirsOnOpen(true, doc2, img2, true) == 0
        && pickDirNames().length == 6, "S2-3: a busy guard must hold the sweep");

    const removed = sweepPickDirsOnOpen(true, doc2, img2, false);
    assert(!exists(oldDoc) && !exists(oldImg) && !exists(untitled),
        "S2-3: the previous document's directories must go, left "
        ~ pickDirNames().to!string);
    assert(exists(newDoc) && exists(newImg) && exists(parkedDir),
        "S2-3: the open document, its image and the parked pick stay, left "
        ~ pickDirNames().to!string);
    assert(removed == 3, format("S2-3: removed %d, expected 3", removed));

    // Only on a CHANGE of the document's directory.
    const later = mkPickDir("19");
    assert(sweepPickDirsOnOpen(true, doc2, img2, false) == 0 && exists(later),
        "S2-3: the same document again sweeps nothing");
    // A save of an untitled document is not an open.
    assert(sweepPickDirsOnOpen(true, buildPath(root, "untitled", "Untitled.v3d"),
        img2, false) == 0 && exists(later),
        "S2-3: a save into <root>/untitled sweeps nothing");
}

// ---------------------------------------------------------------------------
// Census of the production wiring (plan S2 п.10; opponent R2 fix #5).
// ---------------------------------------------------------------------------

/// Offsets of `needle` in the code projection `code`.
size_t[] codeHits(string code, string needle) {
    size_t[] hits;
    for (ptrdiff_t i = code.indexOf(needle); i >= 0;
         i = code.indexOf(needle, i + needle.length))
        hits ~= cast(size_t) i;
    return hits;
}

/// Offset of the `{` that opens the innermost block around `pos`.
size_t enclosingOpen(string code, size_t pos) {
    int depth;
    for (size_t i = pos; i-- > 0;) {
        if (code[i] == '}') ++depth;
        else if (code[i] == '{') {
            if (depth == 0) return i;
            --depth;
        }
    }
    assert(false, "census: no enclosing block");
}

/// Top-level comma-separated arguments of the parenthesised span `args`.
string[] splitArgs(string args) {
    string[] out_;
    int depth;
    size_t start = 1;
    foreach (i; 1 .. args.length - 1) {
        const c = args[i];
        if (c == '(' || c == '[' || c == '{') ++depth;
        else if (c == ')' || c == ']' || c == '}') --depth;
        else if (c == ',' && depth == 0) {
            out_ ~= args[start .. i].strip;
            start = i + 1;
        }
    }
    out_ ~= args[start .. $ - 1].strip;
    return out_;
}

/// Offsets where `needle` sits inside a STRING literal of `raw` (not code,
/// not a comment).
size_t[] literalHits(string raw, string needle) {
    const code = blankNonCode(raw);
    const withComments = blankNonCode(raw, true);
    size_t[] hits;
    for (ptrdiff_t i = raw.indexOf(needle); i >= 0; i = raw.indexOf(needle, i + 1))
        if (code[i] == ' ' && withComments[i] == ' ') hits ~= cast(size_t) i;
    return hits;
}

unittest {
    const raw = readText(buildPath(repoRoot, "source", "app.d"));
    const code = blankNonCode(raw);
    assert(code.length == raw.length && raw.length > 100_000,
        "census floor: app.d projection");

    // The ONE drain, after the flush, the sync and the settle, in the settle's block.
    const drains = codeHits(code, "drainPickResumes(");
    assert(drains.length == 1, format("census: app.d must call drainPickResumes( once, got %d",
        drains.length));
    const drain = drains[0];
    const settles = codeHits(code, "guardController.settle();");
    assert(settles.length == 1, format("census: one guardController.settle(); got %d",
        settles.length));
    const settle = settles[0];
    const syncs = codeHits(code, "syncDocRevision(");
    const flushes = codeHits(code, "changeBus.flush(");
    assert(syncs.length == 1 && flushes.length == 1,
        format("census: one syncDocRevision( and one changeBus.flush(, got %d and %d",
            syncs.length, flushes.length));
    const blockOpen = enclosingOpen(code, settle);
    const block = balancedSpan(code, blockOpen, '{', '}');
    assert(block.length > 0, "census: the settle block is unbalanced");
    const blockEnd = blockOpen + block.length;
    // WEB-DOC-STATE: printed once, after the sync, from the document itself
    // (above the ordering assert so a print moved before the sync reddens HERE).
    const states = literalHits(raw, "WEB-DOC-STATE layers=");
    assert(states.length == 1, format("census: one WEB-DOC-STATE literal, got %d", states.length));
    assert(syncs[0] < states[0] && states[0] < blockEnd,
        "census: WEB-DOC-STATE must be printed after syncDocRevision( in the same block");
    const probeOpen = enclosingOpen(code, states[0]);
    const probe = code[probeOpen .. states[0]];
    assert(probe.canFind("sessionOwner.documentPtr()"),
        "census: WEB-DOC-STATE must read the live document");

    assert(flushes[0] < blockOpen && blockOpen < syncs[0] && syncs[0] < settle,
        "census: the settle block must follow the flush and sync before settling");
    assert(settle < drain && drain < blockEnd,
        "census: drainPickResumes( must follow guardController.settle(); in the same block");
    assert(code[drain .. $].indexOf("drainPickResumes(pickDrainPorts)") == 0,
        "census: the drain must take the ports built at init");

    // The sweep: once, after the drain, in the same block, gated on the model.
    const sweeps = codeHits(code, "sweepPickDirsOnOpen(");
    assert(sweeps.length == 1 && drain < sweeps[0] && sweeps[0] < blockEnd,
        "census: one sweepPickDirsOnOpen( after the drain in the settle block");
    const sweepArgs = splitArgs(balancedSpan(code, sweeps[0] + "sweepPickDirsOnOpen".length,
        '(', ')'));
    assert(sweepArgs.length == 4 && sweepArgs[0] == "browserFileModel()"
        && sweepArgs[1] == "currentDocPath()" && sweepArgs[3] == "guardController.pending",
        "census: sweep arguments " ~ sweepArgs.to!string);

    // The ports: ONE construction, before the frame function, six arguments in
    // the struct's field order, each reading the live production object.
    const ctors = codeHits(code, "PickDrainPorts(");
    assert(ctors.length == 1, format("census: one PickDrainPorts( construction, got %d",
        ctors.length));
    const frameFn = codeHits(code, "void frame()");
    assert(frameFn.length == 1 && ctors[0] < frameFn[0],
        "census: the ports are built once at init, not per frame");
    const args = splitArgs(balancedSpan(code, ctors[0] + "PickDrainPorts".length, '(', ')'));
    assert(args.length == 6, "census: PickDrainPorts takes six ports, got " ~ args.to!string);
    assert(args[0].canFind("listDirNames("), "census: listDir port " ~ args[0]);
    assert(args[1].canFind("commandBinding.invokeUiCommand("), "census: invoke port " ~ args[1]);
    assert(args[2].canFind("raiseNotice("), "census: notice port " ~ args[2]);
    assert(args[3].canFind("changeBus.docRevision()"), "census: revision port " ~ args[3]);
    assert(args[4].canFind("stillBoundTo(") && args[4].canFind("&sessionOwner.editMesh()")
        && args[4].canFind("editMode)"), "census: stillBound port " ~ args[4]);
    assert(args[5].canFind("guardController.pending"), "census: guardBusy port " ~ args[5]);

    // The probe dispatch door and the notice/guard witnesses.
    assert(literalHits(raw, "WEB-NOTICE text=").length == 1
        && literalHits(raw, "WEB-GUARD verdict=").length == 1
        && literalHits(raw, "WEB-PROBE-DISPATCH id=").length == 1,
        "census: one WEB-NOTICE, WEB-GUARD and WEB-PROBE-DISPATCH literal each");
    assert(countOccurrences(code, "commandBinding.dispatchUi(webProbeDispatchId, ") == 1,
        "census: the probe dispatch goes through the UI button door");
}

unittest {
    // The JS bridge: keys, the byte limit, and no composed MEMFS path.
    const js = readText(buildPath(repoRoot, "web", "lib", "file_bridge.js"));
    assert(countOccurrences(js, "preventDefault()") == 1
        && countOccurrences(js, "{capture: true}") == 1
        && countOccurrences(js, "['Ctrl+O', 'Ctrl+S', 'Ctrl+Shift+S']") == 1,
        "census: the capture keydown guard over the three browser-dialog chords");
    assert(countOccurrences(js, "/work") == 0,
        "census: the bridge must not compose a MEMFS path (R19 continued)");
    assert(countOccurrences(js, "FS.mkdirTree(dir)") == 1
        && countOccurrences(js, "const dir = UTF8ToString(dirPtr);") == 1,
        "census: the pick directory is the one D passes");
    const lim = js.indexOf("$vibe3dMaxPickBytes: ");
    assert(lim >= 0, "census: the bridge's byte limit");
    const limText = js[lim + "$vibe3dMaxPickBytes: ".length .. $];
    assert(limText[0 .. limText.indexOf(",")] == "256 * 1024 * 1024"
        && kMaxWebPickBytes == 256UL * 1024 * 1024,
        "census: the JS limit and kMaxWebPickBytes must agree");

    // dub: the library is linked into the web build, and D's callbacks exported.
    string[] dflags;
    foreach (c; parseJSON(readText(buildPath(repoRoot, "dub.json")))["configurations"].array)
        if (c["name"].str == "web")
            foreach (f; c["dflags-wasm"].array) dflags ~= f.str;
    const lib = dflags.length ? cast(ptrdiff_t) dflags.length : -1;
    bool linked;
    foreach (i; 0 .. dflags.length)
        if (dflags[i] == "-Xcc=--js-library" && i + 1 < dflags.length
            && dflags[i + 1] == "-Xcc=$PACKAGE_DIR/web/lib/file_bridge.js") linked = true;
    assert(lib > 0 && linked, "census: dub web links web/lib/file_bridge.js");
    assert(dflags.canFind("-Xcc=-sEXPORTED_FUNCTIONS=_main,_vibe3d_web_pick_done,_vibe3d_web_pick_failed"),
        "census: the two D callbacks are exported");

    // The lane runs both artifacts, once each.
    const lane = readText(buildPath(repoRoot, "tools", "test_web_file_io.sh"));
    assert(countOccurrences(lane, "for mode in normal spreset") == 1
        && countOccurrences(lane, "node \"$repo_root/tools/web_file_io/case_v3d.mjs\"") == 1,
        "census: the browser lane covers normal and spreset");
}
