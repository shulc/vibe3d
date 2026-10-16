module vibe3d.apps.desktop.history_macro_registration;

import vibe3d.editing.params.argstring : serializeCommandLine;
import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.editing.commands.runtime.command_history : CommandHistory, HistoryFlags;
import vibe3d.editing.commands.editor.commands.history.clear : HistoryClear;
import vibe3d.runtime.application_core.pilot_command_registration : PilotCommandDeps, registerHistoryNavigationCommands;
import vibe3d.editing.commands.editor.commands.history.save_as_script : HistorySaveAsScript;
import vibe3d.editing.commands.editor.commands.history.show : HistoryShow;
import vibe3d.editing.commands.editor.commands.macros.record : MacroRecord;
import vibe3d.editing.commands.editor.commands.macros.save_recorded : MacroSaveRecorded;
import vibe3d.apps.desktop.commands.test_undo_flags : UndoForceNoop, UndoSuppressNoop;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.editing.commands.editor.macro_recorder : MacroRecorder;
import vibe3d.editing.tools.interactive.registry : Registry;
import vibe3d.ui.editor.ui.history_panel : HistoryPanelState;

/// These factories resolve the live mesh/View/Mode at command creation. Raw
/// history undo/redo deliberately step CommandHistory directly for replay
/// determinism, while the panel cursor remains session-aware through its own
/// navigator; lifecycle rows stay visible but cannot enter script export.
/// Keep those two doors different (task 5810; evidence:
/// history_macro_registration_test and history_panel_test).
void registerHistoryCommands(ref Registry reg,
        LiveSessionRole session,
        LiveViewModeRole live,
        CommandHistory history,
        HistoryPanelState panelState,
        MacroRecorder macroRecorder) {
    assert(history !is null, "history registration requires CommandHistory");
    assert(panelState !is null, "history registration requires panel state");
    assert(macroRecorder !is null, "history registration requires macro recorder");

    import vibe3d.mesh.core.mesh : Mesh;
    import vibe3d.viewport.camera.view : View;
    ref Mesh pilotMesh() { return session.activeMesh(); }
    ref View pilotView() { return live.view(); }
    registerHistoryNavigationCommands(reg,
        PilotCommandDeps(&pilotMesh, &pilotView, live.modeCell()), history);
    reg.registerCommand("history.show", () => cast(Command)
        new HistoryShow(&session.activeMesh(), live.view(), live.mode,
                        () { panelState.visible = !panelState.visible; }));
    reg.registerCommand("history.clear", () => cast(Command)
        new HistoryClear(&session.activeMesh(), live.view(), live.mode,
                         () { history.clear(); }));

    // Test-only lockout is the hard record/undo/redo/fire gate, distinct from
    // Suspend, and /api/undo/status exposes it as lockout:true. HistoryClear's
    // closure wrapper keeps these SideEffect commands unrecorded and out of UI.
    reg.registerCommand("undo.lockout.on", () => cast(Command)
        new HistoryClear(&session.activeMesh(), live.view(), live.mode,
                         () { history.setLockout(true); }));
    reg.registerCommand("undo.lockout.off", () => cast(Command)
        new HistoryClear(&session.activeMesh(), live.view(), live.mode,
                         () { history.setLockout(false); }));
    // These probes drive both isUndoable() overrides through normal dispatch:
    // the Model command opts out; the SideEffect command opts in.
    reg.registerCommand("undo.test.suppress", () => cast(Command)
        new UndoSuppressNoop(&session.activeMesh(), live.view(), live.mode));
    reg.registerCommand("undo.test.force", () => cast(Command)
        new UndoForceNoop(&session.activeMesh(), live.view(), live.mode));

    reg.registerCommand("history.saveAsScript", () => cast(Command)
        new HistorySaveAsScript(&session.activeMesh(), live.view(), live.mode,
            () {
                string[] lines;
                // Lifecycle rows have no registered factory and cannot replay,
                // so script export keeps an independent replayability filter.
                foreach (ref e; history.undoEntriesVisible()) {
                    if (e.flags & (HistoryFlags.ToolLifecycle | HistoryFlags.PressMarker)) continue;
                    lines ~= serializeCommandLine(e.commandName, e.args);
                }
                return lines;
            }));

    reg.registerCommand("macro.record", () => cast(Command)
        new MacroRecord(&session.activeMesh(), live.view(), live.mode,
                        macroRecorder));
    reg.registerCommand("macro.saveRecorded", () => cast(Command)
        new MacroSaveRecorded(&session.activeMesh(), live.view(), live.mode,
                              macroRecorder));
}
