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
import io.doc_state : currentDocPath, hasCurrentDoc, setCurrentDocPath;
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
            // is Stage 3's job.
            writeV3d(*document, path);
        }

        // Document-path memory: a successful native Save / Save As becomes
        // the current document so a later plain Save needs no dialog.
        // Interchange exports leave the document path untouched.
        if (mode != FileSaveMode.exportSingle && ext == ".v3d")
            setCurrentDocPath(path);

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
