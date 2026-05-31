module commands.history.save_as_script;

import command;
import mesh;
import view;
import editmode;
import params : Param;
import std.file : write;
import std.array : appender;

/// Write the undo stack's argstrings to a `.lxm`-style text file
/// (one command per line, with a macro header). Backs the History
/// panel's right-click "Save as Script" item and the
/// `history.saveAsScript path:<file>` shortcut.
///
/// Snapshot-at-execute: captures the undoStack as it stands when
/// apply() runs. Redo entries are NOT written (they're pending,
/// not history); they'd surface if the user redoes them first.
class HistorySaveAsScript : Command {
    private string[] delegate() snapshotLines;
    private string path_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         string[] delegate() snapshotLines) {
        super(mesh, view, editMode);
        this.snapshotLines = snapshotLines;
    }

    override string name()  const { return "history.saveAsScript"; }
    override string label() const { return "Save History as Script"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    override Param[] params() {
        return [Param.string_("path", "Path", &path_, "")];
    }

    override bool apply() {
        if (path_.length == 0) return false;
        if (snapshotLines is null) return false;
        auto lines = snapshotLines();
        auto buf = appender!string();
        buf.put("#LXMacro#\n");
        foreach (line; lines) {
            buf.put(line);
            buf.put("\n");
        }
        write(path_, buf.data);
        return true;
    }
}
