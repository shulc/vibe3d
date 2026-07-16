module commands.file.load;

import display_sync : refreshDisplayActive;
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
import io.native : readV3d;
import io.formats;
import io.doc_state : setCurrentDocPath;
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
    private bool             docSnapped;     // true when prevLayers was captured
    private bool             multiLayer;     // true for a layered (multi-part) interchange import
    private FileLoadMode     mode = FileLoadMode.open;
    private string           singleExt;     // import-single target ext (e.g. ".obj")

    this(Mesh* mesh, ref View view, EditMode editMode, Document* document) {
        super(mesh, view, editMode);
        this.document = document;
    }

    override string name() const { return "file.load"; }

    /// Skip the native file dialog and load from the given path.
    /// Used by /api/command params; leave unset for normal user flow.
    void setPath(string p) { explicitPath = p; }

    /// Configure the dialog framing. `ext` is the single-format target for
    /// `FileLoadMode.importSingle` (ignored for `open`).
    void configure(FileLoadMode m, string ext = null) {
        mode      = m;
        singleExt = ext;
    }

    // Build the nfde filter list for this mode and open the dialog,
    // returning the chosen path (null if cancelled). Centralizes the
    // POSIX/Windows narrow/wide FilterItem split.
    private string runOpenDialog() {
        FilterSpec[] fs = (mode == FileLoadMode.importSingle)
            ? singleFilterSpecs(singleExt)
            : importFilterSpecs(isAssimpAvailable(), /*withAllSupported=*/true);

        string path;
        // Seed the dialog at the last directory the user browsed to (prefs);
        // null on a fresh profile lets nfde pick its platform default.
        const startDir = g_prefs.lastDir;
        version (Windows) {
            import std.utf : toUTF16z;
            FilterItem[] items;
            foreach (ref f; fs)
                items ~= FilterItem(cast(const(ushort)*)f.name.toUTF16z,
                                    cast(const(ushort)*)f.spec.toUTF16z);
            auto result = openDialog(path, items, startDir);
        } else {
            import std.string : toStringz;
            FilterItem[] items;
            foreach (ref f; fs)
                items ~= FilterItem(f.name.toStringz, f.spec.toStringz);
            auto result = openDialog(path, items, startDir);
        }
        assert(result != Result.error, getError());
        return path;
    }

    override bool apply() {
        string path = explicitPath;
        const fromDialog = path is null;
        if (path is null) {
            if (command.g_testMode) {
                import std.stdio : stderr;
                stderr.writeln("file.load: no path in test mode; native dialog suppressed");
                return false;
            }
            path = runOpenDialog();
            if (path is null) return false;
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
            // Native .v3d is the layered source of truth: replace the WHOLE
            // layer list in place. Snapshot the prior document for undo BEFORE
            // the swap (readV3d only mutates `document` atomically on success,
            // so capturing here is safe even when the load rejects).
            prevLayers      = document.layers.dup;   // shallow: Layer refs preserved
            prevActiveIndex = document.activeIndex;
            docSnapped      = true;
            ok = readV3d(path, *document);
            if (!ok) { docSnapped = false; prevLayers = null; return false; }
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

            if (sc.parts.length > 1) {
                // Layered (multi-part) interchange import: replace the document.
                multiLayer      = true;
                prevLayers      = document.layers.dup;   // shallow: Layer refs kept
                prevActiveIndex = document.activeIndex;
                docSnapped      = true;
                *document       = toLayers(sc);
                // toLayers sets primary/selected/activeIndex in lockstep;
                // defensive re-clamp re-establishes the lockstep invariant.
                document.setActive(document.activeIndex);
            } else {
                // Single-part (or empty) import: keep the active-mesh path.
                snap = MeshSnapshot.capture(*mesh);
                *mesh = flattenToMesh(sc);
            }
        }

        // Document-path memory: a successful NATIVE load (File → Open of a
        // .v3d) becomes the current document so plain Save needs no dialog.
        // Interchange imports leave the document untitled (a later Save
        // prompts for a .v3d).
        if (mode == FileLoadMode.open && ext == ".v3d")
            setCurrentDocPath(path);

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
        // the active mesh. Freshly built BACKGROUND layers keep clean
        // pendingChanges_ + unseeded shadow stamps (lazy-seeded on first flush);
        // only the ACTIVE mesh gets noteChange below.
        Mesh* active = docSnapped ? document.activeMesh() : mesh;

        // The reader rebuilt the mesh on a fresh struct (Mesh.init) and applied
        // subpatch flags; grow selection arrays to match but don't clear
        // isSubpatch.
        active.syncSelection();
        // Bulk transition: the load REPLACED the active mesh — every cache must
        // invalidate. noteChange(All) on the NEW active mesh (the fresh struct
        // reset pending + counters to 0). Freshly built background layers (v2
        // multi-layer files) start with clean pendingChanges_ and unseeded
        // shadow stamps; the per-layer flush lazily seeds them on first sight,
        // so a layered load does not trip the MISSED-PUBLISHER check.
        active.noteChange(MeshChangeAll);
        // A document-replacing load (native .v3d, or a multi-part interchange
        // import that built layers) replaces the WHOLE layer list AND changes
        // the active layer — publish the whole-document layer mask. A single-
        // part interchange import mutated only the active mesh in place (no
        // layer-list change), so it emits no layer kind.
        if (docSnapped)
            noteLayerChange(LayerChangeAll);
        refreshActive(active);
        return true;
    }

    override bool revert() {
        if (docSnapped) {
            // Native path: restore the prior layer list + active index in place.
            document.layers      = prevLayers;
            // Restore primary/selected/activeIndex in lockstep BEFORE reading
            // activeMesh() (setActive clamps the index into range).
            document.setActive(prevActiveIndex);
            auto active = document.activeMesh();
            active.noteChange(MeshChangeAll);
            // Undo restores the prior layer list — another whole-document change.
            noteLayerChange(LayerChangeAll);
            refreshActive(active);
            return true;
        }
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshActive(mesh);
        return true;
    }

    private void refreshActive(Mesh* active) {
        refreshDisplayActive(active);
    }
}
