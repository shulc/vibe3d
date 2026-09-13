module history_macro_registration;

import argstring : serializeCommandLine;
import command : Command;
import command_history : CommandHistory, HistoryFlags;
import commands.history.clear : HistoryClear;
import commands.history.redo : HistoryRedo;
import commands.history.save_as_script : HistorySaveAsScript;
import commands.history.show : HistoryShow;
import commands.history.undo : HistoryUndo;
import commands.macros.record : MacroRecord;
import commands.macros.save_recorded : MacroSaveRecorded;
import commands.test_undo_flags : UndoForceNoop, UndoSuppressNoop;
import file_io_registration : FileIoSessionRole, LiveFileViewModeRole;
import macro_recorder : MacroRecorder;
import registry : Registry;
import ui.history_panel : HistoryPanelState;

/// These factories resolve the live mesh/View/Mode at command creation. Raw
/// history undo/redo deliberately step CommandHistory directly for replay
/// determinism, while the panel cursor remains session-aware through its own
/// navigator; lifecycle rows stay visible but cannot enter script export.
/// Keep those two doors different (task 5810; evidence:
/// history_macro_registration_test and history_panel_test).
void registerHistoryCommands(ref Registry reg,
        FileIoSessionRole session,
        LiveFileViewModeRole live,
        CommandHistory history,
        HistoryPanelState panelState,
        MacroRecorder macroRecorder) {
    assert(history !is null, "history registration requires CommandHistory");
    assert(panelState !is null, "history registration requires panel state");
    assert(macroRecorder !is null, "history registration requires macro recorder");

    reg.commandFactories["history.undo"] = () => cast(Command)
        new HistoryUndo(&session.activeMesh(), live.view(), live.mode, history);
    reg.commandFactories["history.redo"] = () => cast(Command)
        new HistoryRedo(&session.activeMesh(), live.view(), live.mode, history);
    reg.commandFactories["history.show"] = () => cast(Command)
        new HistoryShow(&session.activeMesh(), live.view(), live.mode,
                        () { panelState.visible = !panelState.visible; });
    reg.commandFactories["history.clear"] = () => cast(Command)
        new HistoryClear(&session.activeMesh(), live.view(), live.mode,
                         () { history.clear(); });

    // Test-automation lockout and undoability probes remain on the same
    // factories as the production dispatcher, but are absent from menus.
    reg.commandFactories["undo.lockout.on"] = () => cast(Command)
        new HistoryClear(&session.activeMesh(), live.view(), live.mode,
                         () { history.setLockout(true); });
    reg.commandFactories["undo.lockout.off"] = () => cast(Command)
        new HistoryClear(&session.activeMesh(), live.view(), live.mode,
                         () { history.setLockout(false); });
    reg.commandFactories["undo.test.suppress"] = () => cast(Command)
        new UndoSuppressNoop(&session.activeMesh(), live.view(), live.mode);
    reg.commandFactories["undo.test.force"] = () => cast(Command)
        new UndoForceNoop(&session.activeMesh(), live.view(), live.mode);

    reg.commandFactories["history.saveAsScript"] = () => cast(Command)
        new HistorySaveAsScript(&session.activeMesh(), live.view(), live.mode,
            () {
                string[] lines;
                foreach (ref e; history.undoEntriesVisible()) {
                    if (e.flags & HistoryFlags.ToolLifecycle) continue;
                    lines ~= serializeCommandLine(e.commandName, e.args);
                }
                return lines;
            });

    reg.commandFactories["macro.record"] = () => cast(Command)
        new MacroRecord(&session.activeMesh(), live.view(), live.mode,
                        macroRecorder);
    reg.commandFactories["macro.saveRecorded"] = () => cast(Command)
        new MacroSaveRecorded(&session.activeMesh(), live.view(), live.mode,
                              macroRecorder);
}
