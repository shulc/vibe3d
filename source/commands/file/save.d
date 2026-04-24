module commands.file.save;

import nfde;

import command;
import mesh;
import view;
import editmode;
import lwo;

class FileSave : Command {
    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name() const { return "File Save"; }

    override bool apply() {
        string path;
        version (Windows)
            auto result = saveDialog(path,
                [FilterItem(cast(const(ushort)*)"LWO"w.ptr, cast(const(ushort)*)"lwo"w.ptr)],
                "Untitled.lwo");
        else
            auto result = saveDialog(path, [FilterItem("LWO", "lwo")], "Untitled.lwo");
        assert(result != Result.error, getError());
        if (path is null) return false;
        exportLWO(*mesh, path);
        return true;
    }
}
