module commands.file.load;

import std.path : extension;
import std.uni  : toLower;

import nfde;

import command;
import mesh;
import view;
import editmode;
import document : Document, Layer;
import io.lwo_import    : sceneFromLwo;
import io.scene_import  : importViaAssimp;
import io.scene_ir      : ImportedScene, flattenToMesh, toLayers;
import io.native : readV3d, lastV3dRejectReason;
import io.formats;
import io.file_dialog : pickOpenPath, PickResult, PickOutcome;
import io.doc_state : setCurrentDocPath, requestDocRebaseline;
import io.assimp_runtime : isAssimpAvailable;
import prefs : g_prefs, prefsNoteRecentFile, prefsNoteLastDir;
import snapshot : MeshSnapshot;
import change_bus : MeshChangeAll, noteLayerChange, LayerChangeAll;

/// How the load dialog is framed (asset-I/O Phase 6).
///   open         — File → Open: full "All supported" + native-primary
///                  filter; a successful NATIVE (.v3d) load becomes the
///                  current document.
///   importSingle — Import ▸ X: one-format filter (set via configure);
///                  never changes the current document path.
enum FileLoadMode { open, importSingle }

class FileLoad : Command {
    private Document*        document;      // layered source of truth for native .v3d
    private string           explicitPath;  // set via setPath() to skip the dialog
    private MeshSnapshot     snap;          // interchange path: single-mesh undo
    // Native .v3d load replaces the whole layer list in place; undo restores
    // the prior document state captured before the swap.
    private Layer[]          prevLayers;
    private size_t           prevActiveIndex;
    // ~~Task 0654: the item selection was EMPTY at fire time. `prevActiveIndex`
    // cannot carry that — it is the absent-sentinel, which `setActive` CLAMPS
    // into a real layer — so the fact is stored beside it and revert() reads
    // this one first.
    /// TASK 0671 — the exact prior item-selection state (both lists, the
    /// order, the focus). Replaces the `prevActiveIndex` + `prevSelectionEmpty`
    /// pair, which recorded a DERIVED index plus a flag for the one case that
    /// index could not express; neither could express a latched target, and
    /// the `clearItemSelection()` used to restore the empty case now LATCHES
    /// rather than empties.
    private Document.ItemSelectionState prevSelection;
    private bool             docSnapped;     // true when prevLayers was captured
    private bool             multiLayer;     // true for a layered (multi-part) interchange import
    private FileLoadMode     mode = FileLoadMode.open;
    private string           singleExt;     // import-single target ext (e.g. ".obj")
    // WHY the last apply() declined, in the reader's own words — see
    // refusalReason() below. Reset at the top of every apply().
    private string           refusal_;

    this(Mesh* mesh, ref View view, EditMode editMode, Document* document) {
        super(mesh, view, editMode);
        this.document = document;
    }

    override string name() const { return "file.load"; }

    // Task 1521: opening (or importing) over the current document replaces it.
    // Declared on the CLASS, which is why `file.open` AND all four
    // `file.import.*` ids are covered by one line — they are the same command
    // with a different dialog framing, and the import path is exactly the
    // fourth discard route the card's census found.
    override bool discardsUnsavedWork() const { return true; }

    /// Skip the native file dialog and load from the given path.
    /// Used by /api/command params; leave unset for normal user flow.
    void setPath(string p) { explicitPath = p; }

    /// Configure the dialog framing. `ext` is the single-format target for
    /// `FileLoadMode.importSingle` (ignored for `open`).
    void configure(FileLoadMode m, string ext = null) {
        mode      = m;
        singleExt = ext;
    }

    // Task 1520: the chooser lives in `io/file_dialog.d` now — one
    // implementation of the POSIX/Windows FilterItem split, `--test`
    // suppression and the four-way outcome. The `assert(result != Result.error)`
    // that used to sit here abort()ed the editor on a session with no D-Bus.
    private PickResult runOpenDialog() {
        FilterSpec[] fs = (mode == FileLoadMode.importSingle)
            ? singleFilterSpecs(singleExt)
            : importFilterSpecs(isAssimpAvailable(), /*withAllSupported=*/true);
        // Seed the dialog at the last directory the user browsed to (prefs);
        // null on a fresh profile lets the backend pick its platform default.
        return pickOpenPath(fs, g_prefs.lastDir);
    }

    /// WHY the last apply() declined — the `.v3d` reader's own sentence, with
    /// the file it was reading named in front of it.
    ///
    /// THIS IS THE ONLY ROUTE THE REASON HAS (review B1). `log.d`'s single
    /// sink is a stderr echo; nothing in the UI listens to it. Without this
    /// override the dispatch funnel appends nothing, `runCommand` shows
    /// nothing, and File → Open of a pre-v8 document is indistinguishable from
    /// a menu item that does not work — which is exactly the "went looking for
    /// corruption that isn't there" the version-gate wording was written to
    /// prevent.
    ///
    /// EMPTY ON A CANCELLED DIALOG, on purpose: closing the file chooser also
    /// returns false, and a user who pressed Cancel must not be told anything.
    /// That is why the reason is set only where the reader actually refused.
    override string refusalReason() const { return refusal_; }

    protected override bool applyImpl() {
        // The value must describe the LATEST call: a command object is applied
        // more than once (redo, re-dispatch), and a reason kept from a prior
        // failure would be reported against a call that succeeded.
        refusal_ = null;

        string path = explicitPath;
        const fromDialog = path is null;
        if (path is null) {
            // CANCEL IS SILENT, EVERYTHING ELSE SPEAKS (task 1520). The three
            // outcomes used to collapse into one bare `return false`, which is
            // why `--test` suppression and a broken chooser were indistinguish-
            // able from "the user changed their mind".
            auto pick = runOpenDialog();
            if (pick.outcome != PickOutcome.chosen) {
                refusal_ = pick.refusalReason();
                return false;
            }
            path = pick.path;
        }
        // Dispatch by extension: native .v3d vs. the LWO / assimp bridges.
        // Default (unknown / no extension) is native .v3d. Interchange
        // imports go through the scene-IR seam (parse -> ImportedScene ->
        // flattenToMesh).
        bool ok;
        const ext = extension(path).toLower;
        const isNative = !(ext == ".lwo" || ext == ".obj" || ext == ".gltf"
                           || ext == ".glb" || ext == ".fbx");

        if (isNative) {
            // Parse and validate into a temporary document first. The live
            // document must remain under an armed tool until success is known,
            // but the tool must be gone before either the undo snapshot or the
            // whole-document assignment below.
            Document parsed;
            ok = readV3d(path, parsed);
            if (!ok) {
                auto why = lastV3dRejectReason();
                refusal_ = why.length ? (path ~ " — " ~ why)
                                      : ("could not read " ~ path);
                return false;
            }
            {
                import tool_disarm : DisarmMode,
                    disarmActiveToolBeforeDocumentReplace;
                disarmActiveToolBeforeDocumentReplace(DisarmMode.cancelAndDrop);
            }
            prevLayers      = document.layers.dup;   // shallow: Layer refs preserved
            prevActiveIndex = document.activeIndex;
            prevSelection   = document.captureItemSelection();   // task 0671
            docSnapped      = true;
            noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
            *document = parsed;
            // readV3d (Stage 3) already re-asserts the full selection-set
            // invariants via the Document mutators: the persisted multi-select
            // SET is restored, the primary is forced selected + visible, and
            // ≥1 layer is selected. Do NOT re-clamp with setActive here — that
            // would collapse the restored multi-select set back to one layer.
        } else {
            // Interchange import through the scene-IR seam (Stage 3): parse the
            // file into an ImportedScene, THEN decide how to land it.
            //   * parts.length <= 1 → flatten into the active mesh, exactly as
            //     before (single-part imports are byte-identical to pre-Stage-3).
            //   * parts.length  > 1 → build a layered document via `toLayers`
            //     (first part active/foreground, the rest visible background)
            //     and replace the WHOLE layer list in place — the same pattern
            //     as the native .v3d load above.
            ImportedScene sc;
            if (ext == ".lwo")
                ok = sceneFromLwo(path, sc);
            else
                ok = importViaAssimp(path, sc);   // OBJ / glTF / FBX via assimp
            if (!ok) return false;

            // One call dominates both interchange landing paths. Parsing has
            // succeeded; neither the old snapshot nor the replacement has
            // happened yet.
            {
                import tool_disarm : DisarmMode,
                    disarmActiveToolBeforeDocumentReplace;
                disarmActiveToolBeforeDocumentReplace(DisarmMode.cancelAndDrop);
            }
            if (sc.parts.length > 1) {
                // Layered (multi-part) interchange import: replace the document.
                multiLayer      = true;
                prevLayers      = document.layers.dup;   // shallow: Layer refs kept
                prevActiveIndex = document.activeIndex;
                prevSelection   = document.captureItemSelection();   // task 0671
                docSnapped      = true;
                noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
                *document       = toLayers(sc);
                // toLayers sets primary/selected/activeIndex in lockstep;
                // defensive re-clamp re-establishes the lockstep invariant.
                document.setActive(document.activeIndex);
            } else {
                // Single-part (or empty) import: keep the active-mesh path.
                snap = MeshSnapshot.capture(*mesh);
                noteUndoRecorded();   // task 2500 — the flag and the image, one statement apart
                *mesh = flattenToMesh(sc);
            }
        }

        // The load succeeded, so the document the morph ROUTING TARGET was
        // bound against is gone (task 1073, review B2). The binding is a NAME
        // resolved per use, so leaving it standing means the next edit lands
        // in whatever same-named map the loaded file happens to carry — a map
        // the user never selected, in a document they have not looked at yet.
        // Dropping it degrades to "editing the base", which the whole routing
        // seam already handles. Deliberately AFTER the parse: a load that
        // rejected has returned above and must leave the session untouched.
        {
            import morph_target : clearMorphTarget;
            clearMorphTarget();
        }

        // Document-path memory: a successful NATIVE load (File → Open of a
        // .v3d) becomes the current document so plain Save needs no dialog.
        // Interchange imports leave the document untitled (a later Save
        // prompts for a .v3d).
        if (mode == FileLoadMode.open && ext == ".v3d") {
            setCurrentDocPath(path);
            // A freshly opened native document starts clean (task 0434). The
            // load's own mesh mutation flushes AFTER this command, so the
            // rebaseline is applied by the next syncDocRevision, not now.
            // Interchange imports deliberately stay dirty (untitled, unsaved).
            requestDocRebaseline();
        }

        // Prefs: MRU-push every successful load (open + import); remember the
        // directory only for dialog-driven loads (HTTP file.load with an
        // explicit path must not move the user's last-dir). g_prefs mutators
        // are inert when prefs is gated off — the globals just default-init.
        prefsNoteRecentFile(path);
        if (fromDialog) {
            import std.path : dirName;
            prefsNoteLastDir(dirName(path));
        }

        // From here on operate on the NEW active mesh. For a document-replacing
        // load (native .v3d, or a multi-part interchange import that built
        // layers) the layer list was replaced, so the active mesh sits at a
        // fresh heap address — resolve it through the document rather than the
        // fire-time `*mesh` pointer (which still points at the prior layer).
        // A single-part interchange import mutated `*mesh` in place, so it stays
        // the active mesh. Only the ACTIVE mesh gets the bulk publish below.
        Mesh* active = docSnapped ? document.activeMesh() : mesh;

        // Task 0654: a `.v3d` saved with an empty item selection loads with no
        // primary, so there is no ACTIVE mesh to sync or to note a change on.
        // The load still SUCCEEDED — the document is exactly what the file
        // says — so this returns true rather than refusing; the per-layer
        // change publication below is what tells the caches to rebuild.
        if (active is null) {
            if (docSnapped) noteLayerChange(LayerChangeAll);
            return true;
        }

        // The reader rebuilt the mesh on a fresh struct (Mesh.init) and applied
        // subpatch flags; grow selection arrays to match but don't clear
        // isSubpatch.
        active.syncSelection();
        // Bulk transition: the load REPLACED the active mesh — every cache must
        // invalidate. The All class goes on the NEW active mesh (the fresh
        // struct reset the accumulators + counters to 0). A freshly built
        // background layer (v2 multi-layer files) starts with `mutationVersion`
        // and `stampedVersion_` both at whatever its factory left them — equal,
        // because both move only through `commitStamps` — so a layered load
        // does not trip the MISSED-PUBLISHER check.
        //
        // TASK 1906 STAGE 2 — `publishChange`, not `noteChange`, and this site
        // is the one that was MEASURED blind (review of stage 2a/2b). It is the
        // command's LAST mesh publisher and `syncSelection()` above delivers
        // nothing, so `file.load` produced ZERO subject-carrying deliveries —
        // only the subject-less per-frame aggregate, which `mesh_dirty`
        // deliberately ignores. Since stage 2a the display family keys on the
        // bus epoch instead of pulling a per-frame word, so a load that
        // delivers nothing leaves `ensureDisplayCurrent` — the mid-batch pull
        // guard in front of every VBO reader that runs before the frame's flush
        // — with no reason to re-upload for the rest of that frame. The
        // SINGLE-PART interchange path above mutates `*mesh` IN PLACE, so the
        // key's mesh-ADDRESS term does not rescue that case the way it rescues
        // a document-replacing `.v3d` load. Same flags, same absence of a
        // version bump, one delivery at the batch close; see
        // `Mesh.publishChange`'s doc comment for the whole rule and
        // `tests/test_bus_display_guard_after_load.d` for the witness.
        active.publishChange(MeshChangeAll);
        // A document-replacing load (native .v3d, or a multi-part interchange
        // import that built layers) replaces the WHOLE layer list AND changes
        // the active layer — publish the whole-document layer mask. A single-
        // part interchange import mutated only the active mesh in place (no
        // layer-list change), so it emits no layer kind.
        if (docSnapped)
            noteLayerChange(LayerChangeAll);
        return true;
    }

    protected override void revertImpl() {
        if (docSnapped) {
            // Native path: restore the prior layer list + active index in place.
            document.layers      = prevLayers;
            // TASK 0671 — one exact restore, BEFORE reading activeMesh(). The
            // `setActive(prevActiveIndex)` + `clearItemSelection()` pair this
            // replaces reconstructed the selection from a derived index and a
            // flag; it could not express a latched target at all, and its
            // empty-case repair would now LATCH rather than empty.
            document.resetSelectionState();
            document.restoreItemSelection(prevSelection);
            auto active = document.activeMesh();
            // TASK 1906 STAGE 2 — `publishChange` for the same reason as the
            // apply tail above: this is the revert's last mesh publisher and
            // nothing before it delivers.
            if (active !is null) active.publishChange(MeshChangeAll);
            // Undo restores the prior layer list — another whole-document change.
            noteLayerChange(LayerChangeAll);
            return;
        }
        snap.restore(*mesh);
    }
}
