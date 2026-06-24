module commands.ai.toggle;

import command;
import mesh;
import view;
import editmode;
import ai.state : EditorAiState;

enum AiToggleAction {
    toggle,
    enable,
    disable,
}

class AiToggleCommand : Command {
    private EditorAiState aiState;
    private AiToggleAction action;

    this(Mesh* mesh, ref View view, EditMode editMode,
         EditorAiState aiState, AiToggleAction action)
    {
        super(mesh, view, editMode);
        this.aiState = aiState;
        this.action = action;
    }

    override string name() const {
        final switch (action) {
            case AiToggleAction.toggle:  return "ai.toggle";
            case AiToggleAction.enable:  return "ai.enable";
            case AiToggleAction.disable: return "ai.disable";
        }
    }

    override string label() const {
        final switch (action) {
            case AiToggleAction.toggle:  return "Toggle AI";
            case AiToggleAction.enable:  return "Enable AI";
            case AiToggleAction.disable: return "Disable AI";
        }
    }

    override CmdFlags cmdFlags() const {
        return CmdFlags.SideEffect;
    }

    override bool apply() {
        if (aiState is null)
            throw new Exception(name() ~ ": AI state service not initialised");
        final switch (action) {
            case AiToggleAction.toggle:
                aiState.toggle();
                break;
            case AiToggleAction.enable:
                aiState.setEnabled(true);
                break;
            case AiToggleAction.disable:
                aiState.setEnabled(false);
                break;
        }
        return true;
    }

    override bool revert() {
        return false;
    }
}
