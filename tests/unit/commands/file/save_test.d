// Module unittests for `commands.file.save`, moved verbatim out of source/commands/file/save.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.commands.file.save_test;

import std.path : extension;
import std.uni  : toLower;
import nfde;
import command;
import mesh;
import view;
import editmode;
import document : Document;
import io.scene_ir : flattenDocument;
import io.lwo_export : exportLwoDocument;
import io.scene_export : exportViaAssimp, exportDocumentViaAssimp;
import io.native : writeV3d;
import io.formats;
import io.doc_state : currentDocPath, hasCurrentDoc, setCurrentDocPath, requestDocRebaseline;
import io.assimp_runtime : isAssimpAvailable;
import prefs : g_prefs, prefsNoteRecentFile, prefsNoteLastDir;
import commands.file.save;
import std.conv : to;

// ---------------------------------------------------------------------------
// Task 7400 (web file I/O S1a): the browser save path. Rewrites the task-6870
// block "browser backend refuses before FileSave can manufacture a path" —
// by design a browser save now CHOOSES a MEMFS path (`browserSaveTarget`,
// owner Q2), creates its directory, writes, and hands the file to the browser
// (`deliverSavedFile`) before the document is marked saved. Every path is
// under a per-process temp root through `setWorkRootForTest`.
// ---------------------------------------------------------------------------

private string browserSaveRoot(string tag) {
    import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir;
    import std.format : format;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import io.browser_pick_resume : setWorkRootForTest;
    auto root = buildPath(tempDir(), format("vibe3d_7400_save_%s_%d", tag, thisProcessID()));
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    setWorkRootForTest(root);
    return root;
}

private void dropBrowserSaveRoot(string root) {
    import std.file : exists, rmdirRecurse;
    import io.browser_pick_resume : setWorkRootForTest;
    setWorkRootForTest(null);
    if (exists(root)) rmdirRecurse(root);
}

// R10b — an untitled browser save creates `<root>/untitled/` and writes there.
unittest {
    import command : g_testMode;
    import std.file : exists;
    import std.path : buildPath;
    import io.doc_state : clearCurrentDoc;
    import io.file_dialog : PickOutcome, pickSavePath, selectBrowserBackendForTest,
                            setDeliverSavedFileForTest;
    import mesh : makeCube;

    const root = browserSaveRoot("r10b");
    const priorTestMode = g_testMode;
    string[] delivered;
    scope (exit) {
        selectBrowserBackendForTest(false);
        setDeliverSavedFileForTest(null);
        g_testMode = priorTestMode;
        clearCurrentDoc();
        dropBrowserSaveRoot(root);
    }
    // Keep the native fallback harmless: if the switch is broken the `--test`
    // branch refuses instead of opening a dialog.
    g_testMode = true;
    clearCurrentDoc();
    selectBrowserBackendForTest(true);
    setDeliverSavedFileForTest((string p) { delivered ~= p; return true; });

    const target = buildPath(root, "untitled", "Untitled.v3d");
    assert(!exists(buildPath(root, "untitled")), "R10b floor: no untitled/ before the save");

    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto save = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
    save.configure(FileSaveMode.save);
    bool applied;
    try applied = save.apply();
    catch (Exception e) assert(false, "R10b: untitled browser save threw: " ~ e.msg);
    assert(applied, "R10b: the untitled browser save applies, reason '"
        ~ save.refusalReason() ~ "'");
    assert(exists(target), "R10b: written to " ~ target);
    assert(delivered == [target], "R10b: and handed to the browser once");
    assert(currentDocPath() == target, "R10b: it becomes the current document");

    // Save As with an open document writes beside it (its directory is made).
    import io.doc_state : setCurrentDocPath;
    const beside = buildPath(root, "7", "scene.v3d");
    setCurrentDocPath(beside);
    auto saveAs = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
    assert(saveAs.apply(), "R10b: Save As beside the document, reason '"
        ~ saveAs.refusalReason() ~ "'");
    assert(exists(beside) && delivered[$ - 1] == beside, "R10b: written beside it");
}

// R10c — a directory that cannot be made is a loud refusal, not a throw.
unittest {
    import std.file : write, exists;
    import std.path : buildPath;
    import std.algorithm : canFind;
    import io.doc_state : clearCurrentDoc;
    import io.file_dialog : selectBrowserBackendForTest, setDeliverSavedFileForTest;
    import io.browser_pick_resume : setWorkRootForTest;
    import mesh : makeCube;

    const root = browserSaveRoot("r10c");
    const blocked = buildPath(root, "blocked");
    write(blocked, "a file where the root should be a directory");
    setWorkRootForTest(blocked);
    int calls;
    scope (exit) {
        selectBrowserBackendForTest(false);
        setDeliverSavedFileForTest(null);
        clearCurrentDoc();
        dropBrowserSaveRoot(root);
    }
    clearCurrentDoc();
    selectBrowserBackendForTest(true);
    setDeliverSavedFileForTest((string p) { ++calls; return true; });
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    auto save = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
    bool applied = true;
    try applied = save.apply();
    catch (Exception e) assert(false, "R10c: threw: " ~ e.msg);
    assert(!applied && save.refusalReason().canFind("could not prepare '"
        ~ buildPath(blocked, "untitled") ~ "'"),
        "R10c: loud refusal, got '" ~ save.refusalReason() ~ "'");
    assert(calls == 0 && !hasCurrentDoc(), "R10c: nothing handed off, no path adopted");
}

// R9 — the hand-off happens after the write and before the document is marked
// saved; a refused hand-off leaves it dirty. Every dirtiness read follows an
// explicit `syncDocRevision`, the only place `docDirty()` changes.
unittest {
    import std.file : exists, read;
    import std.path : buildPath;
    import io.doc_state : clearCurrentDoc, docDirty, syncDocRevision;
    import io.file_dialog : selectBrowserBackendForTest, setDeliverSavedFileForTest;
    import mesh : makeCube;

    const root = browserSaveRoot("r9");
    scope (exit) {
        selectBrowserBackendForTest(false);
        setDeliverSavedFileForTest(null);
        clearCurrentDoc();
        requestDocRebaseline();
        syncDocRevision(0);
        dropBrowserSaveRoot(root);
    }
    selectBrowserBackendForTest(true);
    bool deliver = true;
    const(ubyte)[] handed;
    int calls;
    setDeliverSavedFileForTest((string p) {
        ++calls;
        handed = null;
        try handed = cast(const(ubyte)[]) read(p);
        catch (Exception) {}
        return deliver;
    });

    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    const path = buildPath(root, "7", "scene.v3d");
    {
        import std.file : mkdirRecurse;
        mkdirRecurse(buildPath(root, "7"));
    }
    auto save = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
    save.setPath(path);

    clearCurrentDoc();
    requestDocRebaseline(); syncDocRevision(10);
    syncDocRevision(11);
    assert(docDirty(), "R9 floor: dirty before save");
    assert(save.apply(), "R9: the save applies");
    assert(calls == 1, "R9 floor: one hand-off");
    assert(handed.length > 0 && handed == cast(const(ubyte)[]) read(path),
        "R9: the hand-off reads the bytes just written");
    syncDocRevision(11);
    assert(!docDirty(), "R9 control: handed-off save is clean (Q6)");

    syncDocRevision(12);
    assert(docDirty(), "R9 floor 2: dirty again");
    clearCurrentDoc();
    deliver = false;
    assert(!save.apply(), "R9: a refused hand-off refuses the save");
    assert(save.refusalReason() == "could not hand 'scene.v3d' to the browser",
        "R9: reason '" ~ save.refusalReason() ~ "'");
    syncDocRevision(12);
    assert(!hasCurrentDoc(), "R9: a refused hand-off must not adopt the path");
    assert(docDirty(), "R9: a refused hand-off must leave the document dirty");
}

// R9b — every write branch hands off (checklist 7): the LWO export.
unittest {
    import std.file : read, mkdirRecurse;
    import std.path : buildPath, extension;
    import io.doc_state : clearCurrentDoc;
    import io.file_dialog : setDeliverSavedFileForTest;
    import mesh : makeCube;

    const root = browserSaveRoot("r9b");
    scope (exit) {
        setDeliverSavedFileForTest(null);
        clearCurrentDoc();
        dropBrowserSaveRoot(root);
    }
    string[] paths;
    const(ubyte)[] handed;
    setDeliverSavedFileForTest((string p) {
        paths ~= p;
        try handed = cast(const(ubyte)[]) read(p);
        catch (Exception) {}
        return true;
    });
    auto doc = Document.bootstrap(makeCube());
    auto v = new View(0, 0, 800, 600);
    mkdirRecurse(buildPath(root, "x"));
    const path = buildPath(root, "x", "scene.lwo");
    auto save = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
    save.configure(FileSaveMode.exportSingle, ".lwo");
    save.setPath(path);
    assert(save.apply(), "R9b: the LWO export applies");
    assert(paths.length == 1, "R9b floor: one hand-off, got " ~ paths.length.to!string);
    assert(paths[0] == path && extension(paths[0]) == ".lwo", "R9b: the .lwo path is handed off");
    assert(handed.length > 0 && handed == cast(const(ubyte)[]) read(path),
        "R9b: the hand-off reads the written LWO bytes");
}

// ---------------------------------------------------------------------------
// The dirty-flag gate, at the two ends of the change task 0616 Ph6 made.
//
// HISTORY, because it is what this test is for. A native `.v3d` save used to
// SKIP any layer v7 could not represent (a non-mesh item) and rebaseline the
// dirty flag anyway — so the UI showed "saved" over a document whose Empty
// item was simply gone from disk. The fix threaded `writeV3d`'s `bool` return
// through as `wroteComplete` and rebaselined only on true.
//
// v8 represents every item kind, so the skip is gone and the mixed document
// now saves COMPLETELY and legitimately goes clean — which is the assertion
// this case now makes. That is not the guard being deleted: the guard is still
// wired, and the reason its trigger disappeared is that the underlying loss
// was fixed. The all-mesh control below is unchanged and still proves the
// rebaseline itself works.
//
// Discriminating: the mixed case asserts the document goes CLEAN *and* that
// the saved file really carries the Empty item. "Clean" alone would also be
// what a writer that silently dropped the item and returned true produces —
// which is exactly the bug the original guard existed for.
// ---------------------------------------------------------------------------
unittest {
    import std.file   : tempDir, remove, exists;
    import std.path   : buildPath;
    import std.format : format;
    import std.random : uniform;
    import mesh        : makeCube;
    import document     : Layer, ItemKind;
    import view         : View;
    import io.doc_state : syncDocRevision, docDirty, clearCurrentDoc,
                          requestDocRebaseline;

    // Isolate from whatever revision state an earlier module's unittest (or
    // a later one, in a different `dub test` run order) may have left
    // behind — `io.doc_state` is process-global, main-thread-only state.
    scope(exit) { clearCurrentDoc(); requestDocRebaseline(); syncDocRevision(0); }

    auto pathMixed = buildPath(tempDir(),
        format("vibe3d_filesave_ut_mixed_%d.v3d", uniform(0, int.max)));
    auto pathClean = buildPath(tempDir(),
        format("vibe3d_filesave_ut_clean_%d.v3d", uniform(0, int.max)));
    scope(exit) if (exists(pathMixed)) remove(pathMixed);
    scope(exit) if (exists(pathClean)) remove(pathClean);

    auto v = new View(0, 0, 800, 600);

    // Case 1: a MIXED document. Prime a baseline, then simulate an edit since
    // that baseline so the document starts dirty — mirroring the state a real
    // user is in right before hitting Save.
    {
        auto doc = Document.bootstrap(makeCube());
        auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
        doc.layers ~= empty;                          // [meshA(primary), empty]

        syncDocRevision(100);                          // baseline @ 100
        syncDocRevision(101);                           // "edited since" -> dirty
        assert(docDirty(), "setup: document is dirty before the save");

        auto save = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
        save.setPath(pathMixed);
        assert(save.apply(), "save must succeed");

        // Feed the SAME live revision through another sync, as the next
        // frame's syncDocRevision(rev) call would.
        syncDocRevision(101);
        assert(!docDirty(),
            "a v8 save covers the non-mesh item too, so the document is "
            ~ "legitimately CLEAN afterwards — this used to stay dirty because "
            ~ "the item was dropped from the file");

        // …and the reason it is clean is that the item is really there. Without
        // this, "clean" would also be what a writer that silently dropped the
        // item and reported success produces — the exact bug the dirty-flag
        // gate was added for.
        import std.json : parseJSON;
        import std.file : readText;
        auto saved = parseJSON(readText(pathMixed));
        assert(saved["layers"].array.length == 2,
            "the saved file carries BOTH items");
        assert(saved["layers"].array[1]["type"].str == "empty",
            "…and the second one is still the Empty");
    }

    // Case 2 (control): an all-mesh document — nothing skipped — must still
    // rebaseline exactly as before (task 0434's original behaviour).
    {
        auto doc = Document.bootstrap(makeCube());     // one mesh layer only

        syncDocRevision(200);                           // baseline @ 200
        syncDocRevision(201);                            // "edited since" -> dirty
        assert(docDirty(), "setup: document is dirty before the save");

        auto save = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
        save.setPath(pathClean);
        assert(save.apply(), "a complete native save must succeed");

        syncDocRevision(201);
        assert(!docDirty(),
            "control: a save with nothing skipped must still clear the "
            ~ "dirty flag exactly as before should-fix 4");
    }
}
