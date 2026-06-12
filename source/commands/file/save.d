module commands.file.save;

import std.path : extension;
import std.uni  : toLower;

import nfde;

import command;
import mesh;
import view;
import editmode;
import lwo;
import io.native : writeV3d;

class FileSave : Command {
    private string explicitPath;  // set via setPath() to skip the dialog

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "File Save"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }   // file output, no mesh state change

    /// Skip the native file dialog and save to the given path.
    /// Used by /api/command params; leave unset for normal user flow.
    void setPath(string p) { explicitPath = p; }

    override bool apply() {
        string path = explicitPath;
        if (path is null) {
            // Native .v3d is the source-of-truth format and the dialog's
            // primary filter; LWO stays a secondary interchange option.
            version (Windows)
                auto result = saveDialog(path,
                    [FilterItem(cast(const(ushort)*)"V3D"w.ptr, cast(const(ushort)*)"v3d"w.ptr),
                     FilterItem(cast(const(ushort)*)"LWO"w.ptr, cast(const(ushort)*)"lwo"w.ptr)],
                    "Untitled.v3d");
            else
                auto result = saveDialog(path,
                    [FilterItem("V3D", "v3d"), FilterItem("LWO", "lwo")],
                    "Untitled.v3d");
            assert(result != Result.error, getError());
            if (path is null) return false;
        }
        // Dispatch by extension: native .v3d vs. the LWO interchange bridge.
        // Default (unknown / no extension) is native .v3d.
        if (extension(path).toLower == ".lwo")
            exportLWO(*mesh, path);
        else
            writeV3d(*mesh, path);
        return true;
    }
}
