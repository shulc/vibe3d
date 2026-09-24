// Task 7450 (web file I/O S4, plan doc/web_file_io_plan_2026-09-23.md "S4"):
// the desktop half of the browser image cells in tools/web_file_io/case_images.mjs.
// (1) The fixture oracle: magenta8.png is the 8x8 magenta the pixel cell counts,
// plane_scene.v3d stores it by its bare FILE NAME, and the REAL `file.load` ->
// `file.save` of the pair writes the committed bytes back (a fixed point: it
// pins the reader and writer on this file, not how the file was generated). (2) `image.replace`,
// which no browser door can reach (no UI row dispatches it and the probe door
// sends `{}`, so its `index` is missing), parks and resumes through the SAME
// UI door and queue as `image.load`. (3) Census of the lane: each case reports
// its cells by the lines that ran, and the lane requires every expected line.
module tests.unit.web_io_image_fixture_test;

import std.algorithm.searching : count, countUntil;
import std.file : copy, exists, mkdirRecurse, read, readText, rmdirRecurse, tempDir;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildPath, dirName;
import std.process : thisProcessID;

import command : Command;
import command_args : bindArgs;
import command_history : RecordMode;
import commands.file.load : FileLoad;
import commands.file.save : FileSave;
import document : ItemKind, Layer;
import file_io_registration : registerFileIoCommands;
import guarded_action_controller;
import io.browser_pick_resume;
import io.file_dialog : selectBrowserBackendForTest;
import io.image_decode : DecodedImage, imageDecode;
import item_command_registration : ItemLifecycleDoors, registerItemCommands;
import live_registration_roles : LiveSessionRole, LiveView, LiveViewModeRole;
import mesh : makeCube;
import registry : Registry;
import session_owner : Session;
import ui.discard_guard : GuardAnswer, GuardRecord, UiRunOutcome;
import view : View;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum fixtures = buildPath(repoRoot, "tests", "fixtures", "web_io");

private string freshDir(string tag) {
    const dir = buildPath(tempDir(), format("vibe3d_7450_%s_%d", tag, thisProcessID()));
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

private Layer[] imagesOf(Session* session) {
    Layer[] images;
    foreach (l; session.document.layers) if (l.kind == ItemKind.Image) images ~= l;
    return images;
}

// ---------------------------------------------------------------------------
// (1) Fixture oracle.
// ---------------------------------------------------------------------------
unittest {
    import io.doc_state : clearCurrentDoc, requestDocRebaseline;

    // magenta8.png: 8x8, every pixel (255,0,255,255) — what cell I3 counts.
    {
        DecodedImage img;
        const bytes = cast(const(ubyte)[]) read(buildPath(fixtures, "magenta8.png"));
        assert(imageDecode(bytes, img), "7450 oracle: magenta8.png does not decode");
        scope (exit) img.free();
        assert(img.width == 8 && img.height == 8,
            format("7450 oracle: magenta8.png is %dx%d, not 8x8", img.width, img.height));
        size_t magenta;
        foreach (i; 0 .. 64)
            if (img.pixels[i * 4 .. i * 4 + 4] == [255, 0, 255, 255]) ++magenta;
        assert(magenta == 64, format("7450 oracle: %d of 64 pixels are magenta", magenta));
    }

    // plane_scene.v3d stores the image by its bare file name, once.
    const scene = parseJSON(readText(buildPath(fixtures, "plane_scene.v3d")));
    JSONValue[] imageBlocks, planes;
    foreach (l; scene["layers"].array) {
        if ("image" in l.object) imageBlocks ~= l;
        if (l["type"].str == "imagePlane") planes ~= l;
    }
    assert(imageBlocks.length == 1,
        format("7450 oracle: plane_scene.v3d has %d \"image\" blocks, not 1", imageBlocks.length));
    assert(imageBlocks[0]["image"]["filename"].str == "magenta8.png",
        "7450 oracle: plane_scene.v3d stores the image as "
        ~ imageBlocks[0]["image"]["filename"].str ~ ", not the bare name magenta8.png");
    assert(planes.length == 1 && planes[0]["links"].array.length == 1
        && planes[0]["links"][0]["slot"].str == "image",
        "7450 oracle: plane_scene.v3d must carry one image plane linked to its image");
    // The I3 pixel floor was measured on THIS plane size (make_fixtures.sh sets
    // it); the load -> save below is a fixed point of any committed bytes, so it
    // cannot see a changed fixture — this literal does.
    const pixelSize = planes[0]["channels"]["pixelSize"].floating;
    assert(pixelSize > 0.2999 && pixelSize < 0.3001,
        format("7450 oracle: the plane's pixelSize is %s, the pixel floor in case_images.mjs "
             ~ "was measured at 0.3 (re-measure with tools/web_file_io/measure_plane_pixels.sh)",
               pixelSize));

    // The REAL load -> save of the pair, both in one folder, writes the
    // committed bytes back; the same file ALONE in another folder loads missing (I4).
    const scratch = freshDir("fixture");
    scope (exit) {
        if (exists(scratch)) rmdirRecurse(scratch);
        clearCurrentDoc();
        requestDocRebaseline();
    }
    const pair = buildPath(scratch, "pair");
    const alone = buildPath(scratch, "alone");
    mkdirRecurse(pair);
    mkdirRecurse(alone);
    copy(buildPath(fixtures, "plane_scene.v3d"), buildPath(pair, "plane_scene.v3d"));
    copy(buildPath(fixtures, "magenta8.png"), buildPath(pair, "magenta8.png"));
    copy(buildPath(fixtures, "plane_scene.v3d"), buildPath(alone, "plane_scene.v3d"));

    auto session = Session.bootstrap(makeCube());
    auto camera = new View(0, 0, 800, 600);
    ref View liveView() { return camera; }
    Registry reg;
    registerFileIoCommands(reg, LiveSessionRole(session),
        LiveViewModeRole(cast(LiveView)&liveView, session.editModePtr()));

    auto load = cast(FileLoad) reg.makeCommand("file.load");
    load.setPath(buildPath(pair, "plane_scene.v3d"));
    assert(load.apply(), "7450 oracle: file.load of plane_scene.v3d refused: " ~ load.refusalReason());
    auto images = imagesOf(session);
    assert(images.length == 1, format("7450 oracle: %d image items after the load", images.length));
    auto img = images[0].imageOrNull();
    assert(!img.missing && img.width == 8 && img.height == 8
        && img.storedPath == buildPath(pair, "magenta8.png"),
        format("7450 oracle: the picked-beside image loads as %s missing=%s %dx%d",
               img.storedPath, img.missing, img.width, img.height));

    const outPath = buildPath(pair, "plane_scene.resave.v3d");
    auto save = cast(FileSave) reg.makeCommand("file.save");
    save.setPath(outPath);
    assert(save.apply(), "7450 oracle: file.save refused: " ~ save.refusalReason());
    const written = cast(const(ubyte)[]) read(outPath);
    const expected = cast(const(ubyte)[]) read(buildPath(fixtures, "plane_scene.v3d"));
    assert(written.length > 0 && written == expected,
        format("7450 oracle: file.load -> file.save of plane_scene.v3d wrote %d bytes that "
             ~ "differ from tests/fixtures/web_io/plane_scene.v3d (%d bytes); regenerate "
             ~ "with tools/web_file_io/make_fixtures.sh and read the diff",
               written.length, expected.length));

    auto loadAlone = cast(FileLoad) reg.makeCommand("file.load");
    loadAlone.setPath(buildPath(alone, "plane_scene.v3d"));
    assert(loadAlone.apply(), "7450 oracle: file.load of the lone plane_scene.v3d refused: "
        ~ loadAlone.refusalReason());
    images = imagesOf(session);
    assert(images.length == 1 && images[0].imageOrNull().missing,
        "7450 oracle: plane_scene.v3d without its PNG must load the image MISSING");
}

// ---------------------------------------------------------------------------
// (2) `image.replace` through the UI door: parked (a single-file chooser),
// then resumed with the pick's path, replacing the item its `index` named.
// ---------------------------------------------------------------------------
unittest {
    import io.doc_state : clearCurrentDoc;

    const root = freshDir("replace");
    setWorkRootForTest(root);
    scope (exit) {
        selectBrowserBackendForTest(false);
        resetPickResumesForTest();
        setWorkRootForTest(null);
        if (exists(root)) rmdirRecurse(root);
        clearCurrentDoc();
    }
    resetPickResumesForTest();

    auto session = Session.bootstrap(makeCube());
    auto camera = new View(0, 0, 800, 600);
    ref View liveView() { return camera; }
    Registry reg;
    registerItemCommands(reg, LiveSessionRole(session),
        LiveViewModeRole(cast(LiveView)&liveView, session.editModePtr()),
        ItemLifecycleDoors((size_t a, size_t b) {}, () {}));

    // A loaded image to replace, loaded on the desktop path from a real file.
    const src = buildPath(root, "src");
    mkdirRecurse(src);
    import io.image_path : writeTestBmp;
    writeTestBmp(buildPath(src, "first.bmp"), 3, 2);
    auto ld = reg.makeCommand("image.load");
    auto loadArgs = JSONValue(["path": JSONValue(buildPath(src, "first.bmp"))]);
    bindArgs(ld, loadArgs);
    assert(ld.apply(), "7450 replace fixture: image.load refused");
    auto images = imagesOf(session);
    assert(images.length == 1 && images[0].imageOrNull().width == 3, "7450 replace floor: one 3x2 image");

    selectBrowserBackendForTest(true);
    auto rep = reg.makeCommand("image.replace");
    auto replaceArgs = JSONValue(["index": JSONValue(cast(long) session.document.indexOf(images[0]))]);
    bindArgs(rep, replaceArgs);
    GuardedActionPorts ports;
    ports.apply = (Command c, RecordMode m) => c.apply();
    ports.dirty = () => false;
    ports.save = () => false;
    Command[] notices;
    ports.notice = (Command c) { notices ~= c; };
    ports.observation.request = (GuardRecord r) {};
    ports.observation.answer = (GuardAnswer a, bool b) {};
    ports.observation.pending = (bool b) {};
    auto door = new GuardedActionController(ports);

    const outcome = door.invoke(rep, RecordMode.Record, "image.replace");
    assert(outcome == UiRunOutcome.refused && notices.length == 1
        && notices[0].refusalReason() == "",
        "7450 replace: a pathless replace in the browser parks silently (a desktop Cancel to the door)");
    assert(pickResumes().length == 1 && pickResumes().pendingCommand() is rep,
        "7450 replace: the SAME image.replace object is parked");
    assert(!pickResumes().pendingMultiple(),
        "7450 replace: an image chooser takes ONE file");
    assert(images[0].imageOrNull().storedPath == buildPath(src, "first.bmp"),
        "7450 replace: nothing is replaced before the pick");

    // The browser writes the pick; the next frame's drain resumes it.
    const dir = pickResumes().parkedDir();
    mkdirRecurse(dir);
    copy(buildPath(fixtures, "magenta8.png"), buildPath(dir, "magenta8.png"));
    import std.conv : to;
    pickResumes().complete(baseName(dir).to!uint, 1);
    PickDrainPorts drain;
    int invokes;
    drain.listDir = (string d) => listDirNames(d);
    drain.invoke = (Command c, RecordMode m, string id) {
        ++invokes;
        return door.invoke(c, m, id);
    };
    string[] texts;
    drain.notice = (string s) { texts ~= s; };
    drain.revision = () => 0UL;
    drain.stillBound = (Command c) => true;
    drain.guardBusy = () => false;
    drainPickResumes(drain);
    assert(invokes == 1 && texts.length == 0 && pickResumes().length == 0,
        format("7450 replace: the pick resumed once without a notice (invokes %d, notices %s)",
               invokes, texts));
    auto replaced = images[0].imageOrNull();
    assert(replaced.storedPath == buildPath(dir, "magenta8.png") && !replaced.missing
        && replaced.width == 8 && replaced.height == 8,
        format("7450 replace: the item now reads %s missing=%s %dx%d",
               replaced.storedPath, replaced.missing, replaced.width, replaced.height));
}

// ---------------------------------------------------------------------------
// (3) Census of the browser lane (task 7450; the v3d half closes the S3
// finding that case_v3d.mjs printed a fixed `cells=C0..C8,C4b` summary).
// ---------------------------------------------------------------------------
unittest {
    const lane = readText(buildPath(repoRoot, "tools", "test_web_file_io.sh"));
    const loop = lane.countUntil("for mode in normal spreset; do");
    assert(loop >= 0, "7450 census: the lane has no `for mode in normal spreset` loop");

    static struct Case { string file, expected; string[] cells; }
    const Case[2] cases = [
        Case("case_v3d.mjs", `[[ $v3d_cells != "C0 C1 C2 C3 C4 C4b C5 C6 C7 C8 " ]]`,
             ["C0", "C1", "C2", "C3", "C4", "C4b", "C5", "C6", "C7", "C8"]),
        Case("case_images.mjs", `[[ $img_cells != "I0 I1 I2 I3 I4 I5 I6 " ]]`,
             ["I0", "I1", "I2", "I3", "I4", "I5", "I6"]),
    ];
    foreach (c; cases) {
        // The WHOLE call line, so a `true || ` in front cannot keep a pin green.
        const call = "\n    timeout 240 node \"$repo_root/tools/web_file_io/" ~ c.file ~ "\" \\\n";
        const at = lane.countUntil(call);
        assert(lane.count(call) == 1 && at > loop && lane[loop .. at].count("\ndone") == 0,
            "7450 census: tools/test_web_file_io.sh must run " ~ c.file
            ~ " exactly once, inside the mode loop");
        const check = lane.countUntil(c.expected);
        assert(lane.count(c.expected) == 1 && check > at && lane[at .. check].count("\ndone") == 0,
            "7450 census: tools/test_web_file_io.sh must check the " ~ c.file
            ~ " cell lines after its call, inside the mode loop");
        const text = readText(buildPath(repoRoot, "tools", "web_file_io", c.file));
        foreach (cell; c.cells)
            assert(text.count("ok('" ~ cell ~ "', ") == 1,
                "7450 census: " ~ c.file ~ " must report cell " ~ cell ~ " exactly once");
        assert(text.count("cells=${ran.join(',')} ok") == 1 && text.count("cells=C0..") == 0,
            "7450 census: " ~ c.file ~ " must print its summary from the cells that ran");
    }

    // The probe door stands in for the Images panel's Load button: both send
    // `image.load {}`. What stays unwitnessed is the button HIT itself.
    const panel = readText(buildPath(repoRoot, "source", "ui", "image_list_panel.d"));
    assert(panel.count(`dispatch("image.load", "{}");`) == 1,
        "7450 census: the Images panel's Load button must dispatch image.load {} once");
    const images = readText(buildPath(repoRoot, "tools", "web_file_io", "case_images.mjs"));
    assert(images.count("&dispatch=image.load`") == 1,
        "7450 census: case_images.mjs must dispatch image.load through the probe door");
}
