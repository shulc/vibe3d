module vibe3d.apps.desktop.ai_command_registration;

import vibe3d.runtime.ai_advisor.ai.state : EditorAiState;
import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.apps.desktop.commands.ai.toggle : AiToggleAction, AiToggleCommand;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.editing.tools.interactive.registry : Registry;

/// Registers the three AI state toggles. The policy gate stays at the caller
/// and gates all THREE together, so nothing re-arms the advisor while the
/// copilot is paused (task 0422; task 6354 moved the gate to the call site so
/// these factory bodies stay typed).
void registerAiToggleCommands(ref Registry reg, LiveSessionRole owner,
                              LiveViewModeRole live, EditorAiState aiState) {
    Command delegate() makeAiFactory(AiToggleAction action) {
        return () => cast(Command)
            new AiToggleCommand(&owner.activeMesh(), live.view(), live.mode,
                                aiState, action);
    }
    reg.registerCommand("ai.toggle", makeAiFactory(AiToggleAction.toggle));
    reg.registerCommand("ai.enable", makeAiFactory(AiToggleAction.enable));
    reg.registerCommand("ai.disable", makeAiFactory(AiToggleAction.disable));
}
