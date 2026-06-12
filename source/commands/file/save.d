module commands.file.save;

import std.path : extension;
import std.uni  : toLower;

import nfde;

import command;
import mesh;
import view;
import editmode;
import io.lwo_export : exportLwo;
import io.scene_export : exportViaAssimp;
import io.native : writeV3d;
import io.formats;
import io.doc_state : currentDocPath, hasCurrentDoc, setCurrentDocPath;
import io.assimp_runtime : isAssimpAvailable;

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
    private string       explicitPath;  // set via setPath() to skip the dialog
    private FileSaveMode mode = FileSaveMode.saveAs;
    private string       singleExt;     // export-single target ext (e.g. ".obj")

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "File Save"; }
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
        version (Windows) {
            import std.utf : toUTF16z;
            FilterItem[] items;
            foreach (ref f; fs)
                items ~= FilterItem(cast(const(ushort)*)f.name.toUTF16z,
                                    cast(const(ushort)*)f.spec.toUTF16z);
            auto result = saveDialog(path, items, defaultName);
        } else {
            import std.string : toStringz;
            FilterItem[] items;
            foreach (ref f; fs)
                items ~= FilterItem(f.name.toStringz, f.spec.toStringz);
            auto result = saveDialog(path, items, defaultName);
        }
        assert(result != Result.error, getError());
        return path;
    }

    override bool apply() {
        string path = explicitPath;
        if (path is null) {
            // File → Save with a remembered document writes straight to it,
            // no dialog. Otherwise (untitled, or Save As, or Export) prompt.
            if (mode == FileSaveMode.save && hasCurrentDoc())
                path = currentDocPath();
            else
                path = runSaveDialog();
            if (path is null) return false;
        }
        // Dispatch by extension via the format registry (single source of
        // truth — see io.formats). Native .v3d and unknown / non-exportable
        // rows fall back to writeV3d; .lwo uses our clean-room writer; assimp
        // rows take the registry's exporter id (B4: FBX write is deferred,
        // so the .fbx row is non-exportable and lands in the default).
        const ext = extension(path).toLower;
        const fi  = formatFor(ext);
        if (fi !is null && fi.kind == FormatKind.lwoNative) {
            exportLwo(*mesh, path);
        } else if (fi !is null && fi.kind == FormatKind.assimp && fi.canExport) {
            if (!exportViaAssimp(*mesh, path, fi.assimpExportId)) return false;
        } else {
            writeV3d(*mesh, path);
        }

        // Document-path memory: a successful native Save / Save As becomes
        // the current document so a later plain Save needs no dialog.
        // Interchange exports leave the document path untouched.
        if (mode != FileSaveMode.exportSingle && ext == ".v3d")
            setCurrentDocPath(path);
        return true;
    }
}
