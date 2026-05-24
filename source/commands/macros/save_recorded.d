module commands.macros.save_recorded;

import command;
import mesh;
import view;
import editmode;
import params : Param;
import macro_recorder : MacroRecorder;

/// `macro.saveRecorded path:S` — write the recorder's captured
/// buffer to a `.lxm`-style macro file. Phase 7 of the history-panel
/// design doc (Save button in the History panel's recorder strip).
///
/// Stops the recorder as a side effect, finalizing the session. Empty
/// buffer is allowed — produces a header-only file.
class MacroSaveRecorded : Command {
    private MacroRecorder recorder;
    private string path_;

    this(Mesh* mesh, ref View view, EditMode editMode,
         MacroRecorder recorder) {
        super(mesh, view, editMode);
        this.recorder = recorder;
    }

    override string name()  const { return "macro.saveRecorded"; }
    override string label() const { return "Save Recorded Macro"; }
    override bool   isUndoable() const { return false; }

    override Param[] params() {
        return [Param.string_("path", "Path", &path_, "")];
    }

    override bool apply() {
        if (recorder is null) return false;
        if (path_.length == 0) return false;
        if (!recorder.saveAs(path_)) return false;
        recorder.stop();
        return true;
    }
}
