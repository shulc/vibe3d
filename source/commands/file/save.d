module commands.file.save;

import nfde;

import command;
import mesh;
import view;
import editmode;
import lwo;

class FileSave : Command {
    private string explicitPath;  // set via setPath() to skip the dialog

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "File Save"; }

    /// Skip the native file dialog and save to the given path.
    /// Used by /api/command params; leave unset for normal user flow.
    void setPath(string p) { explicitPath = p; }

    override bool apply() {
        string path = explicitPath;
        if (path is null) {
            version (Windows)
                auto result = saveDialog(path,
                    [FilterItem(cast(const(ushort)*)"LWO"w.ptr, cast(const(ushort)*)"lwo"w.ptr)],
                    "Untitled.lwo");
            else
                auto result = saveDialog(path, [FilterItem("LWO", "lwo")], "Untitled.lwo");
            assert(result != Result.error, getError());
            if (path is null) return false;
        }
        exportLWO(*mesh, path);
        return true;
    }
}
