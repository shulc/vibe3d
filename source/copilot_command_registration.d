module copilot_command_registration;

version (WithAI) {
import ai.state : EditorAiState;
import command : Command;
import commands.copilot.analyze : CopilotAnalyzeCommand;
import commands.copilot.cycle_finding : CopilotCycleFindingCommand;
import commands.copilot.select_finding : CopilotSelectFindingCommand;
import commands.ui.copilot_panel : UiCopilotPanelCommand;
import copilot_panel : CopilotPanel;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;

/// Registers the four WithAI-only findings-panel commands.
/// Task 6354: named collaborators replace the former broad app capture.
void registerCopilotCommands(ref Registry reg, LiveSessionRole owner,
                             LiveViewModeRole live, EditorAiState aiState,
                             CopilotPanel copilotPanel,
                             Command delegate() meshSelectFactory) {
    reg.registerCommand("copilot.analyze", () => cast(Command)
        new CopilotAnalyzeCommand(&owner.activeMesh(), live.view(), live.mode,
                                  copilotPanel));
    reg.registerCommand("copilot.selectFinding", () => cast(Command)
        new CopilotSelectFindingCommand(&owner.activeMesh(), live.view(),
            live.mode, copilotPanel, aiState, meshSelectFactory));
    // Prev/Next delegates the actual act-on to the same lazy mesh.select door.
    reg.registerCommand("copilot.cycleFinding", () => cast(Command)
        new CopilotCycleFindingCommand(&owner.activeMesh(), live.view(),
            live.mode, copilotPanel, aiState, meshSelectFactory));
    reg.registerCommand("ui.copilotPanel", () => cast(Command)
        new UiCopilotPanelCommand(&owner.activeMesh(), live.view(), live.mode));
}
}
