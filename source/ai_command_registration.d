module ai_command_registration;

import ai.state : EditorAiState;
import command : Command;
import commands.ai.toggle : AiToggleAction, AiToggleCommand;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;

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
