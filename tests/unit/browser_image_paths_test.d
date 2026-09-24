// Task 7430 (web file I/O S1b): image paths under the browser file model.
// A saved `.v3d` stores only the image's FILE NAME; on reopen an image is
// looked up only in the document's own folder (no parent anchor, no `..`
// escape, a file-name fallback); two different images sharing a name make
// Save refuse (owner Q7). Plan: doc/web_file_io_plan_2026-09-23.md §3.8 and
// «S1b», cells R16–R20, plus opponent R2 #1 (R18a) and #2 (R18b missing and
// empty rows). Every cell is a pair: switch OFF (the desktop rule, byte for
// byte) above switch ON, so the control line has run when the ON line reddens.
module tests.unit.browser_image_paths_test;

import std.algorithm : canFind;
import std.file : exists, getSize, mkdirRecurse, read, rmdirRecurse, tempDir, write;
import std.format : format;
import std.json : JSONType, parseJSON;
import std.path : buildNormalizedPath, buildPath;
import std.process : thisProcessID;

import command : g_testMode;
import commands.file.save : FileSave, FileSaveMode;
import commands.image.commands : ImageLoad;
import document : Document;
import editmode : EditMode;
import io.browser_pick_resume : setWorkRootForTest;
import io.doc_state : clearCurrentDoc, currentDocPath, hasCurrentDoc;
import io.file_dialog : selectBrowserBackendForTest, setDeliverSavedFileForTest;
import io.image_path : firstCollidingImageName, imageCollisionReadsForTest,
                       resolveStoredPath, storePathFor, writeTestBmp;
import mesh : makeCube;
import view : View;

private string freshRoot(string tag) {
    auto r = buildPath(tempDir(), format("vibe3d_7430_%s_%d", tag, thisProcessID()));
    if (exists(r)) rmdirRecurse(r);
    mkdirRecurse(r);
    return r;
}

private void dropRoot(string r) {
    selectBrowserBackendForTest(false);
    if (exists(r)) rmdirRecurse(r);
}

private void loadImage(ref Document doc, View v, string path) {
    import command_args : bindArgs;
    import std.json : JSONValue;
    auto ld = new ImageLoad(doc.activeMesh(), v, EditMode.Vertices, &doc, null);
    auto j = JSONValue(["path": JSONValue(path)]);
    bindArgs(ld, j);
    assert(ld.apply(), "fixture: image.load " ~ path ~ " — " ~ ld.refusalReason());
}

/// The `"filename"` of every item carrying an `"image"` block, in item order.
private string[] savedImageNames(string v3d) {
    string[] names;
    auto raw = parseJSON(cast(string) read(v3d));
    foreach (l; raw["layers"].array)
        if (l.type == JSONType.object && "image" in l)
            names ~= l["image"]["filename"].str;
    return names;
}

// R16 — the write form.
unittest {
    const r = freshRoot("r16");
    scope (exit) dropRoot(r);
    const img = buildPath(r, "5", "a.png");
    const doc = buildPath(r, "untitled", "U.v3d");

    selectBrowserBackendForTest(false);
    assert(storePathFor(img, doc) == "../5/a.png",
        "R16 control: the desktop parent anchor (the R1 defect), got "
        ~ storePathFor(img, doc));
    selectBrowserBackendForTest(true);
    assert(storePathFor(img, doc) == "a.png",
        "R16: under the browser model only the file name is written, got "
        ~ storePathFor(img, doc));
    assert(storePathFor(img, "") == buildNormalizedPath(img),
        "R16: an untitled document keeps the absolute form, got "
        ~ storePathFor(img, ""));
}

// R17 — no parent anchor and no `..` escape.
unittest {
    const r = freshRoot("r17");
    scope (exit) dropRoot(r);
    writeTestBmp(buildPath(r, "5", "a.png"), 2, 2);
    mkdirRecurse(buildPath(r, "9"));
    const doc = buildPath(r, "9", "d.v3d");
    const stale = buildPath(r, "5", "a.png");
    const own = buildPath(r, "9", "a.png");

    selectBrowserBackendForTest(false);
    assert(resolveStoredPath("../5/a.png", doc) == stale,
        "R17 control (..): the desktop rule reaches the sibling copy, got "
        ~ resolveStoredPath("../5/a.png", doc));
    assert(resolveStoredPath("5/a.png", doc) == stale,
        "R17 control (parent): the desktop parent anchor finds it, got "
        ~ resolveStoredPath("5/a.png", doc));
    selectBrowserBackendForTest(true);
    assert(!exists(own), "R17 floor: the document folder has no a.png yet");
    assert(resolveStoredPath("../5/a.png", doc) == own,
        "R17 (..): a `..` form must not leave the document folder, got "
        ~ resolveStoredPath("../5/a.png", doc));
    assert(resolveStoredPath("5/a.png", doc) == own,
        "R17 (parent): the parent folder is never tried, got "
        ~ resolveStoredPath("5/a.png", doc));
    writeTestBmp(own, 2, 2);
    assert(resolveStoredPath("../5/a.png", doc) == own,
        "R17: the document's own copy once it exists, got "
        ~ resolveStoredPath("../5/a.png", doc));
    assert(resolveStoredPath("..", doc) == buildPath(r, "9"),
        "R17: a stored `..` stays in the document folder, got "
        ~ resolveStoredPath("..", doc));
}

// R18 — the file-name fallback for a nested stored form.
unittest {
    const r = freshRoot("r18");
    scope (exit) dropRoot(r);
    const own = buildPath(r, "9", "a.png");
    writeTestBmp(own, 2, 2);
    const doc = buildPath(r, "9", "d.v3d");

    selectBrowserBackendForTest(false);
    assert(resolveStoredPath("tex/a.png", doc) == buildPath(r, "9", "tex", "a.png"),
        "R18 control: the desktop rule keeps the nested form, got "
        ~ resolveStoredPath("tex/a.png", doc));
    selectBrowserBackendForTest(true);
    assert(resolveStoredPath("tex/a.png", doc) == own,
        "R18: a picked-beside file answers a nested stored form, got "
        ~ resolveStoredPath("tex/a.png", doc));
}

// R18a — an ABSOLUTE stored form that does not exist falls back to the file
// name in the document folder (opponent R2 #1); one that exists answers itself.
unittest {
    const r = freshRoot("r18a");
    scope (exit) dropRoot(r);
    const own = buildPath(r, "9", "a.png");
    writeTestBmp(own, 2, 2);
    const doc = buildPath(r, "9", "d.v3d");
    const gone = buildPath(r, "desktop", "pictures", "a.png");
    const there = buildPath(r, "5", "b.png");
    writeTestBmp(there, 2, 2);
    assert(!exists(gone), "R18a floor: the absolute path does not exist");

    selectBrowserBackendForTest(false);
    assert(resolveStoredPath(gone, doc) == gone,
        "R18a control: the desktop rule returns the absolute path, got "
        ~ resolveStoredPath(gone, doc));
    selectBrowserBackendForTest(true);
    assert(resolveStoredPath(gone) == gone && resolveStoredPath(gone, "") == gone,
        "R18a: with no document there is no folder to fall back to, got "
        ~ resolveStoredPath(gone));
    assert(resolveStoredPath(there, doc) == there,
        "R18a: an existing absolute form answers itself, got "
        ~ resolveStoredPath(there, doc));
    assert(resolveStoredPath(gone, doc) == own,
        "R18a: a missing absolute form falls back to the document folder, got "
        ~ resolveStoredPath(gone, doc));
}

// R18b — the pure collision function. Every row has two paths (the floor).
unittest {
    const r = freshRoot("r18b");
    scope (exit) dropRoot(r);
    const x1 = buildPath(r, "1", "a.png");
    const y2 = buildPath(r, "2", "a.png");
    const x3 = buildPath(r, "3", "a.png");
    const b4 = buildPath(r, "4", "b.png");
    writeTestBmp(x1, 2, 2);
    writeTestBmp(y2, 3, 2);
    writeTestBmp(x3, 2, 2);
    writeTestBmp(b4, 3, 2);
    const missing = buildPath(r, "9", "a.png");
    assert(read(x1) == read(x3) && read(x1) != read(y2),
        "R18b fixture: x1/x3 equal bytes, y2 different");
    assert(!exists(missing), "R18b fixture: the missing entry is absent");

    string call(string[] paths) {
        assert(paths.length == 2, "R18b floor: two paths per row");
        string got = "<threw>";
        try got = firstCollidingImageName(paths);
        catch (Throwable t) assert(false, "R18b: threw " ~ t.msg);
        return got;
    }
    assert(call([x1, y2]) == "a.png", "R18b: different bytes collide, got " ~ call([x1, y2]));
    assert(call([x1, x3]) == "", "R18b: equal bytes do not collide, got " ~ call([x1, x3]));
    assert(call([x1, x1]) == "", "R18b: one path twice does not collide");
    assert(call([x1, b4]) == "", "R18b: different names do not collide");
    assert(call([missing, y2]) == "" && call([y2, missing]) == "",
        "R18b: a missing file has no bytes and collides with nothing");
    assert(call(["", y2]) == "" && call([y2, ""]) == "",
        "R18b: an empty entry names no file and collides with nothing");
    assert(firstCollidingImageName([x1, y2], 10) == "",
        "R18b: a file over the byte bound is not read and collides with nothing");

    // Same size, different bytes: only a byte compare can decide this row.
    const z5 = buildPath(r, "5", "a.png");
    auto flipped = cast(ubyte[]) read(x1).dup;
    flipped[$ - 1] ^= 0xFF;
    mkdirRecurse(buildPath(r, "5"));
    write(z5, flipped);
    assert(getSize(z5) == getSize(x1) && read(z5) != read(x1),
        "R18b fixture: z5 has x1's size and different bytes");
    assert(call([x1, z5]) == "a.png", "R18b: same size, different bytes collide, got "
        ~ call([x1, z5]));

    // A directory with the picture's name is not a readable file (its stat
    // size differs from x1's, so a size-only readability test would collide).
    const d6 = buildPath(r, "6", "a.png");
    mkdirRecurse(d6);
    assert(call([d6, x1]) == "" && call([x1, d6]) == "",
        "R18b: a directory is not a file and collides with nothing");
}

// R18d — the cost contract: reads happen only where a byte compare decides.
unittest {
    const r = freshRoot("r18d");
    scope (exit) dropRoot(r);
    const x1 = buildPath(r, "1", "a.png");
    const y2 = buildPath(r, "2", "a.png");
    writeTestBmp(x1, 2, 2);
    writeTestBmp(y2, 3, 2);
    string[] copies;
    foreach (k; 0 .. 4) {
        copies ~= buildPath(r, format("c%d", k), "a.png");
        mkdirRecurse(buildPath(r, format("c%d", k)));
        write(copies[$ - 1], read(x1));
    }
    size_t readsOf(string[] paths, string want) {
        imageCollisionReadsForTest = 0;
        const got = firstCollidingImageName(paths);
        assert(got == want, "R18d: verdict " ~ got ~ ", want " ~ want);
        return imageCollisionReadsForTest;
    }
    // One picture on four items: the same path is skipped before any I/O.
    const same = readsOf([x1, x1, x1, x1], "");
    assert(same == 0, format("R18d: one path four times read %d files, want 0", same));
    // Unequal sizes decide without reading.
    const sized = readsOf([x1, y2], "a.png");
    assert(sized == 0, format("R18d: unequal sizes read %d files, want 0", sized));
    // Four equal copies: `a` once per outer step plus each `b` = 4+3+2 = 9
    // (12 when `a` is re-read for every pair).
    const equal = readsOf(copies, "");
    assert(equal == 9, format("R18d: four equal copies read %d files, want 9", equal));
}

// R18c — the collision refusal through the real commands.
unittest {
    const r = freshRoot("r18c");
    const priorTestMode = g_testMode;
    int delivered;
    scope (exit) {
        setDeliverSavedFileForTest(null);
        g_testMode = priorTestMode;
        clearCurrentDoc();
        dropRoot(r);
    }
    g_testMode = true;
    clearCurrentDoc();
    setDeliverSavedFileForTest((string p) { ++delivered; return true; });
    const p1 = buildPath(r, "1", "a.png");
    const p2 = buildPath(r, "2", "a.png");
    mkdirRecurse(buildPath(r, "out"));
    auto v = new View(0, 0, 800, 600);

    // Control: equal bytes save, and both items carry the one name.
    writeTestBmp(p1, 2, 2);
    writeTestBmp(p2, 2, 2);
    auto same = Document.bootstrap(makeCube());
    loadImage(same, v, p1);
    loadImage(same, v, p2);
    selectBrowserBackendForTest(true);
    const ok = buildPath(r, "out", "d.v3d");
    auto s1 = new FileSave(same.activeMesh(), v, EditMode.Vertices, &same);
    s1.setPath(ok);
    assert(s1.apply(), "R18c control: equal bytes save, reason '"
        ~ s1.refusalReason() ~ "'");
    assert(savedImageNames(ok) == ["a.png", "a.png"],
        format("R18c control: two items named a.png, got %s", savedImageNames(ok)));

    // Different bytes. The desktop saves them (its paths keep them apart),
    // and so does a browser LWO export (the rule is the native writer's only).
    clearCurrentDoc();
    selectBrowserBackendForTest(false);
    writeTestBmp(p2, 3, 2);
    auto diff = Document.bootstrap(makeCube());
    loadImage(diff, v, p1);
    loadImage(diff, v, p2);
    auto desk = new FileSave(diff.activeMesh(), v, EditMode.Vertices, &diff);
    desk.setPath(buildPath(r, "out", "desk.v3d"));
    assert(desk.apply(), "R18c control: the desktop saves different bytes, reason '"
        ~ desk.refusalReason() ~ "'");
    clearCurrentDoc();
    selectBrowserBackendForTest(true);
    auto lwo = new FileSave(diff.activeMesh(), v, EditMode.Vertices, &diff);
    lwo.configure(FileSaveMode.exportSingle, ".lwo");
    lwo.setPath(buildPath(r, "out", "d.lwo"));
    assert(lwo.apply(), "R18c control: a browser LWO export is not checked, reason '"
        ~ lwo.refusalReason() ~ "'");

    // The browser `.v3d` save refuses before anything is written or handed off.
    const refused = buildPath(r, "out", "d2.v3d");
    assert(!exists(refused), "R18c floor: d2.v3d does not exist before");
    const handedBefore = delivered;
    auto s2 = new FileSave(diff.activeMesh(), v, EditMode.Vertices, &diff);
    s2.setPath(refused);
    bool applied = true;
    try applied = s2.apply();
    catch (Exception e) assert(false, "R18c: threw " ~ e.msg);
    assert(!applied && s2.refusalReason().canFind("both named 'a.png'"),
        "R18c: different bytes refuse, reason '" ~ s2.refusalReason() ~ "'");
    assert(!exists(refused) && delivered == handedBefore && !hasCurrentDoc(),
        "R18c: nothing written, handed off or adopted");

    // An unknown extension falls through to the same native writer, so the
    // same refusal applies there.
    const unknown = buildPath(r, "out", "d3.v3dx");
    auto s3 = new FileSave(diff.activeMesh(), v, EditMode.Vertices, &diff);
    s3.setPath(unknown);
    bool appliedUnknown = true;
    try appliedUnknown = s3.apply();
    catch (Exception e) assert(false, "R18c: threw " ~ e.msg);
    assert(!appliedUnknown && s3.refusalReason().canFind("both named 'a.png'")
        && !exists(unknown),
        "R18c: an unknown extension refuses too, reason '" ~ s3.refusalReason() ~ "'");
}

// R20 — the write through the production save path.
unittest {
    const r = freshRoot("r20");
    const priorTestMode = g_testMode;
    scope (exit) {
        setDeliverSavedFileForTest(null);
        setWorkRootForTest(null);
        g_testMode = priorTestMode;
        clearCurrentDoc();
        dropRoot(r);
    }
    g_testMode = true;
    clearCurrentDoc();
    setWorkRootForTest(r);
    setDeliverSavedFileForTest((string p) => true);
    selectBrowserBackendForTest(true);
    const src = buildPath(r, "5", "magenta8.png");
    writeTestBmp(src, 8, 8);
    auto v = new View(0, 0, 800, 600);
    auto doc = Document.bootstrap(makeCube());
    loadImage(doc, v, src);
    auto save = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
    save.configure(FileSaveMode.save);
    assert(save.apply(), "R20: untitled save, reason '" ~ save.refusalReason() ~ "'");
    const target = buildPath(r, "untitled", "Untitled.v3d");
    assert(currentDocPath() == target, "R20: saved as " ~ currentDocPath());
    const names = savedImageNames(target);
    assert(names.length == 1, format("R20 floor: one image item, got %s", names));
    assert(names[0] == "magenta8.png",
        "R20: the file carries the name only, got " ~ names[0]);
}
