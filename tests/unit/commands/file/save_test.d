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
