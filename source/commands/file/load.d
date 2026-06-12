module commands.file.load;

import std.path : extension;
import std.uni  : toLower;

import nfde;

import command;
import mesh;
import view;
import editmode;
import io.lwo_import    : sceneFromLwo;
import io.scene_import  : importViaAssimp;
import io.scene_ir      : ImportedScene, flattenToMesh;
import io.native : readV3d;
import io.formats;
import io.doc_state : setCurrentDocPath;
import io.assimp_runtime : isAssimpAvailable;
import prefs : g_prefs, prefsNoteRecentFile, prefsNoteLastDir;
import viewcache;
import snapshot : MeshSnapshot;
import change_bus : MeshChangeAll;

/// How the load dialog is framed (asset-I/O Phase 6).
///   open         — File → Open: full "All supported" + native-primary
///                  filter; a successful NATIVE (.v3d) load becomes the
///                  current document.
///   importSingle — Import ▸ X: one-format filter (set via configure);
///                  never changes the current document path.
enum FileLoadMode { open, importSingle }

class FileLoad : Command {
    private GpuMesh*         gpu;
    private VertexCache*     vc;
    private EdgeCache*       ec;
    private FaceBoundsCache* fc;
    private string           explicitPath;  // set via setPath() to skip the dialog
    private MeshSnapshot     snap;
    private FileLoadMode     mode = FileLoadMode.open;
    private string           singleExt;     // import-single target ext (e.g. ".obj")

    this(Mesh* mesh, ref View view, EditMode editMode,
         GpuMesh* gpu, VertexCache* vc, EdgeCache* ec, FaceBoundsCache* fc) {
        super(mesh, view, editMode);
        this.gpu = gpu;
        this.vc  = vc;
        this.ec  = ec;
        this.fc  = fc;
    }

    override string name() const { return "File Load"; }

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
            path = runOpenDialog();
            if (path is null) return false;
        }
        // Snapshot the current mesh BEFORE replacing it, so undo restores
        // whatever was open before the load. Heavy but file.load is a
        // discrete user action — paid once per load.
        snap = MeshSnapshot.capture(*mesh);
        // Dispatch by extension: native .v3d vs. the LWO / assimp bridges.
        // Default (unknown / no extension) is native .v3d. Interchange
        // imports go through the scene-IR seam (parse -> ImportedScene ->
        // flattenToMesh).
        bool ok;
        const ext = extension(path).toLower;
        if (ext == ".lwo") {
            ImportedScene sc;
            ok = sceneFromLwo(path, sc);
            if (ok) *mesh = flattenToMesh(sc);
        } else if (ext == ".obj" || ext == ".gltf" || ext == ".glb"
                   || ext == ".fbx") {
            // Interchange import (OBJ / glTF / FBX) through assimp -> scene-IR.
            ImportedScene sc;
            ok = importViaAssimp(path, sc);
            if (ok) *mesh = flattenToMesh(sc);
        } else {
            ok = readV3d(path, *mesh);
        }
        if (!ok) return false;

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

        // The reader has already rebuilt the mesh on a fresh struct (Mesh.init)
        // and applied subpatch flags; grow selection arrays to match but don't
        // clear isSubpatch.
        mesh.syncSelection();
        // Bulk transition: the loaded file REPLACED the whole mesh — every cache
        // must invalidate. noteChange(All), after the reader rebuilt the mesh
        // (the fresh struct reset pending + counters to 0).
        mesh.noteChange(MeshChangeAll);
        refreshCaches();
        return true;
    }

    override bool revert() {
        if (!snap.filled) return false;
        snap.restore(*mesh);
        refreshCaches();
        return true;
    }

    private void refreshCaches() {
        gpu.upload(*mesh);
        vc.resize(mesh.vertices.length);
        vc.invalidate();
        fc.resize(mesh.vertices.length, mesh.faces.length);
        fc.invalidate();
        ec.resize(mesh.edges.length);
        ec.invalidate();
    }
}
