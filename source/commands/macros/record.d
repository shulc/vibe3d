module commands.macros.record;

import command;
import mesh;
import view;
import editmode;
import params : Param;
import macro_recorder : MacroRecorder;

/// `macro.record state:N` — N=1 starts recording (fresh buffer);
/// N=0 stops. Backs the History panel's Record/Stop buttons
/// (Phase 7 of the history-panel design doc). A `macro.record ?`
/// toggle.
///
/// Not undoable: toggling the recorder is a session-state change,
/// not a mesh mutation, and rolling back a "stop" by re-arming the
/// recorder mid-undo would silently start capturing replayed
/// commands.
///
/// The module is `commands.macros.record` (plural) — `macro` alone
/// is a reserved word in the D lexer, even in package position.
class MacroRecord : Command {
    private MacroRecorder recorder;
    private int state_ = 1;

    this(Mesh* mesh, ref View view, EditMode editMode,
         MacroRecorder recorder) {
        super(mesh, view, editMode);
        this.recorder = recorder;
    }

    override string name()  const { return "macro.record"; }
    override string label() const { return "Macro Record"; }
    override bool   isUndoable() const { return false; }

    override Param[] params() {
        return [Param.int_("state", "State", &state_, 1)];
    }

    override bool apply() {
        if (recorder is null) return false;
        if (state_ != 0) recorder.start();
        else             recorder.stop();
        return true;
    }
}
