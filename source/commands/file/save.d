module commands.file.save;

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

/// How the save dialog is framed (asset-I/O Phase 6).
///   save         — File → Save: write to the remembered document path
///                  with no dialog; if none is remembered, behaves like
///                  saveAs.
///   saveAs       — File → Save As: native .v3d dialog; a successful save
///                  becomes the current document.
///   exportSingle — Export ▸ X: one-format dialog (set via configure);
///                  never changes the current document path.
enum FileSaveMode { save, saveAs, exportSingle }

class FileSave : Command {
    private Document*    document;       // layered source of truth for native .v3d
    private string       explicitPath;  // set via setPath() to skip the dialog
    private FileSaveMode mode = FileSaveMode.saveAs;
    private string       singleExt;     // export-single target ext (e.g. ".obj")

    this(Mesh* mesh, ref View view, EditMode editMode, Document* document) {
        super(mesh, view, editMode);
        this.document = document;
    }

    override string name() const { return "file.save"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }   // file output, no mesh state change

    /// Skip the native file dialog and save to the given path.
    /// Used by /api/command params; leave unset for normal user flow.
    void setPath(string p) { explicitPath = p; }

    /// Configure the dialog framing. `ext` is the single-format target for
    /// `FileSaveMode.exportSingle` (ignored for save / saveAs).
    void configure(FileSaveMode m, string ext = null) {
        mode      = m;
        singleExt = ext;
    }

    // Build the nfde filter list for this mode and open the save dialog,
    // returning the chosen path (null if cancelled). Centralizes the
    // POSIX/Windows narrow/wide FilterItem split.
    private string runSaveDialog() {
        FilterSpec[] fs;
        string defaultName;
        if (mode == FileSaveMode.exportSingle) {
            fs = singleFilterSpecs(singleExt);
            defaultName = "Untitled" ~ normExt(singleExt);
        } else {
            // save (fallthrough, no path) and saveAs both use the native
            // .v3d dialog. The native row is exportFilterSpecs' first entry.
            fs = exportFilterSpecs(isAssimpAvailable());
            defaultName = "Untitled.v3d";
        }

        string path;
        // Seed the dialog at the last directory the user browsed to (prefs).
        // saveDialog's signature is (path, filters, defaultName, defaultPath).
        const startDir = g_prefs.lastDir;
        version (Windows) {
            import std.utf : toUTF16z;
            FilterItem[] items;
            foreach (ref f; fs)
                items ~= FilterItem(cast(const(ushort)*)f.name.toUTF16z,
                                    cast(const(ushort)*)f.spec.toUTF16z);
            auto result = saveDialog(path, items, defaultName, startDir);
        } else {
            import std.string : toStringz;
            FilterItem[] items;
            foreach (ref f; fs)
                items ~= FilterItem(f.name.toStringz, f.spec.toStringz);
            auto result = saveDialog(path, items, defaultName, startDir);
        }
        assert(result != Result.error, getError());
        return path;
    }

    // True for assimp's FBX exporter ids. FBX write is deferred for the
    // layer-aware path, so its dispatch falls back to the flatten exporter.
    private static bool isFbxFormat(string assimpExportId) {
        return assimpExportId == "fbx" || assimpExportId == "fbxa";
    }

    override bool apply() {
        string path = explicitPath;
        bool fromDialog = false;
        if (path is null) {
            // File → Save with a remembered document writes straight to it,
            // no dialog. Otherwise (untitled, or Save As, or Export) prompt.
            if (mode == FileSaveMode.save && hasCurrentDoc())
                path = currentDocPath();
            else {
                if (command.g_testMode) {
                    import std.stdio : stderr;
                    stderr.writeln("file.save: no path in test mode; native dialog suppressed");
                    return false;
                }
                path = runSaveDialog();
                fromDialog = true;
            }
            if (path is null) return false;
        }
        // Dispatch by extension via the format registry (single source of
        // truth — see io.formats). Native .v3d and unknown / non-exportable
        // rows fall back to writeV3d; .lwo uses our clean-room writer; assimp
        // rows (obj/gltf/glb/fbx) take the registry's exporter id.
        const ext = extension(path).toLower;
        const fi  = formatFor(ext);
        // Whether the write covered the WHOLE document. Only the native
        // .v3d branch below can leave this `false` — `writeV3d` skips any
        // layer v7 cannot yet represent (a non-mesh item) rather than
        // crashing or rejecting the whole file (task 0615 Stage 6/7 review
        // round 2, should-fix 4). Gates the dirty-flag rebaseline below: a
        // skip means the on-disk file no longer matches the in-memory
        // document, so the document must NOT be marked clean.
        bool wroteComplete = true;
        if (fi !is null && fi.kind == FormatKind.lwoNative) {
            // LWO export is LAYER-AWARE (Stage 2): one LAYR per Document layer
            // (visible AND hidden), each layer's per-item xform baked into its
            // points, ONE global surface table. A single-VISIBLE-layer document
            // with identity xform exports BYTE-IDENTICAL to the old flatten
            // path (N=1 case of the multi-layer builder).
            exportLwoDocument(*document, path);
        } else if (fi !is null && fi.kind == FormatKind.assimp && fi.canExport) {
            // OBJ / glTF export is LAYER-AWARE (Stage 4): one aiMesh per Document
            // layer on its own child node (N>=2), or today's exact root-mesh shape
            // (N==1, byte-identical single-layer export). Per-layer xform rides the
            // child node's transform; hidden layers carry an ml_visible=false node
            // metadata (glTF extras; OBJ drops it — documented loss).
            //
            // FBX is SPECIAL-CASED to the flatten path: FBX write stays deferred
            // (its node-graph / visibility semantics through assimp's FBX exporter
            // were never probed), so multi-layer FBX is NOT exposed — it keeps
            // today's single flattened-mesh behaviour byte-for-byte.
            if (isFbxFormat(fi.assimpExportId)) {
                auto flat = flattenDocument(*document);
                if (!exportViaAssimp(flat, path, fi.assimpExportId)) return false;
            } else {
                if (!exportDocumentViaAssimp(*document, path, fi.assimpExportId))
                    return false;
            }
        } else {
            // Native .v3d is the layered source of truth: serialize the WHOLE
            // document (every layer + the active index) as formatVersion 2.
            // Interchange exports above stay single-mesh (active layer) — that
            // is Stage 3's job. writeV3d returns false when a non-mesh layer
            // had to be skipped (v7 cannot represent it yet) — see
            // `wroteComplete`'s doc comment above.
            wroteComplete = writeV3d(*document, path);
        }

        // Document-path memory: a successful native Save / Save As becomes
        // the current document so a later plain Save needs no dialog.
        // Interchange exports leave the document path untouched.
        if (mode != FileSaveMode.exportSingle && ext == ".v3d") {
            setCurrentDocPath(path);
            // The on-disk document now matches memory → clear the dirty flag
            // (task 0434) — but ONLY when the write was complete. A skipped
            // layer (should-fix 4) means the file does not actually match
            // memory, so a rebaseline here would make the UI claim "saved"
            // over a document that still has an unsaved (unrepresentable)
            // layer in it. Leave the dirty flag exactly as it was; the
            // document stays (or remains) dirty until a write covers
            // everything.
            if (wroteComplete)
                requestDocRebaseline();
        }

        // Prefs: MRU-push a native Save / Save As (a real document the user
        // would want in Recent); interchange exports are excluded (they leave
        // the document untitled). Remember the directory for any dialog-driven
        // save. Mutators are inert when prefs is gated off.
        if (mode != FileSaveMode.exportSingle && ext == ".v3d")
            prefsNoteRecentFile(path);
        if (fromDialog) {
            import std.path : dirName;
            prefsNoteLastDir(dirName(path));
        }
        return true;
    }
}

// ---------------------------------------------------------------------------
// Task 0615 Stage 6/7 review round 2, SHOULD-FIX 4: a native .v3d save that
// has to SKIP a non-mesh layer (v7 cannot represent one yet, `writeV3d`
// omits it with a warning rather than crashing or rejecting the whole file)
// used to unconditionally `requestDocRebaseline()` regardless — the UI would
// then show the document as "saved" even though the file on disk no longer
// matches the in-memory document (the skipped layer is simply gone from
// disk). The fix threads `writeV3d`'s new `bool` return (true == every
// layer was written) through as `wroteComplete`, and only rebaselines when
// it is true. Pinned here via `io.doc_state`'s dirty-flag API — the only
// place this decision is externally observable — contrasted against a
// clean all-mesh save, which must still rebaseline exactly as before.
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

    // Case 1: a MIXED document (a non-mesh layer will be skipped). Prime a
    // baseline, then simulate an edit since that baseline so the document
    // starts dirty — mirroring the state a real user is in right before
    // hitting Save.
    {
        auto doc = Document.bootstrap(makeCube());
        auto empty = new Layer; empty.name = "Empty"; empty.kind = ItemKind.Empty;
        doc.layers ~= empty;                          // [meshA(primary), empty]

        syncDocRevision(100);                          // baseline @ 100
        syncDocRevision(101);                           // "edited since" -> dirty
        assert(docDirty(), "setup: document is dirty before the save");

        auto save = new FileSave(doc.activeMesh(), v, EditMode.Vertices, &doc);
        save.setPath(pathMixed);
        assert(save.apply(),
            "save must still succeed even though a layer is skipped");

        // Feed the SAME live revision through another sync, as the next
        // frame's syncDocRevision(rev) call would — should-fix 4 says this
        // must NOT clear the dirty flag when a layer was skipped.
        syncDocRevision(101);
        assert(docDirty(),
            "should-fix 4: a save that skipped a non-mesh layer must leave "
            ~ "the document DIRTY — the file on disk does not match memory");
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
