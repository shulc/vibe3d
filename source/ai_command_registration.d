module ai_command_registration;

import ai.state : EditorAiState;
import command : Command;
import commands.ai.toggle : AiToggleAction, AiToggleCommand;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;

/// Registers the three AI state toggles. The policy gate stays at the caller.
/// Task 6354: factory bodies remain typed while the registration call is gated.
void registerAiToggleCommands(ref Registry reg, LiveSessionRole owner,
                              LiveViewModeRole live, EditorAiState aiState) {
    Command delegate() makeAiFactory(AiToggleAction action) {
        return () => cast(Command)
            new AiToggleCommand(&owner.activeMesh(), live.view(), live.mode,
                                aiState, action);
    }
    reg.commandFactories["ai.toggle"] = makeAiFactory(AiToggleAction.toggle);
    reg.commandFactories["ai.enable"] = makeAiFactory(AiToggleAction.enable);
    reg.commandFactories["ai.disable"] = makeAiFactory(AiToggleAction.disable);
}
