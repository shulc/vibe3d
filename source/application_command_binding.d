module application_command_binding;

import command : Command, CommandOrigin;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import edit_session : EditSession;
import guarded_action_controller : GuardedActionController;
import registry : Registry;
import ui.discard_guard : UiRunOutcome;

public import command_invocation : CommandInvocationContext,
    CommandInvocationOutcome, CommandInvocationResult;
import command_invocation : CommandInvocationService;

alias CommandNotice = void delegate(Command);
alias TextNotice = void delegate(string);

/// Application-owned command construction and dispatch.  Protocol response
/// delivery and script-refusal exceptions remain adapter responsibilities;
/// this module deliberately has no HTTP dependency (task 4711).
final class ApplicationCommandBinding {
private:
    CommandInvocationService invocation;
    CommandHistory history;
    GuardedActionController uiPolicy;
    TextNotice textNotice;

    CommandInvocationOutcome uiResult(Command command, RecordMode mode,
                                      string dispatchedId) {
        final switch (uiPolicy.invoke(command, mode, dispatchedId)) {
            case UiRunOutcome.applied: return CommandInvocationOutcome.applied;
            case UiRunOutcome.refused: return CommandInvocationOutcome.refused;
            case UiRunOutcome.deferred: return CommandInvocationOutcome.deferred;
        }
    }

public:
    this(ref Registry registry, CommandExecutor executor, EditSession session,
         CommandHistory history, GuardedActionController uiPolicy,
         CommandNotice commandNotice, TextNotice textNotice) {
        assert(executor !is null, "ApplicationCommandBinding requires CommandExecutor");
        assert(session !is null, "ApplicationCommandBinding requires EditSession");
        assert(history !is null, "ApplicationCommandBinding requires CommandHistory");
        assert(uiPolicy !is null, "ApplicationCommandBinding requires UI policy");
        assert(commandNotice !is null, "ApplicationCommandBinding requires command notice policy");
        assert(textNotice !is null, "ApplicationCommandBinding requires text notice policy");
        this.history = history;
        this.uiPolicy = uiPolicy;
        this.textNotice = textNotice;
        invocation = registry.createCommandInvocationService(executor, history,
            (Command command, string id) => session.tryRefireDispatch(command, id),
            (Command command, RecordMode mode, string id) => uiResult(command, mode, id),
            (Command command, bool interactive) {
                import commands.tool.attr : ToolAttrCommand;
                if (auto attr = cast(ToolAttrCommand) command)
                    attr.setInteractive(interactive);
            }, commandNotice);
    }

    CommandInvocationResult invokeLine(string id, string paramsJson,
                                       CommandInvocationContext context) {
        return invocation.invokeLine(id, paramsJson, context);
    }

    UiRunOutcome invokeUiCommand(Command command, RecordMode mode,
                                 string dispatchedId = "") {
        return uiPolicy.invoke(command, mode, dispatchedId);
    }

    void dispatchUi(string id, string paramsJson) {
        invokeLine(id, paramsJson,
            CommandInvocationContext(CommandOrigin.ui, false));
    }

    void dispatchInteractiveUi(string id, string paramsJson) {
        invokeLine(id, paramsJson,
            CommandInvocationContext(CommandOrigin.ui, true));
    }

    void endInteractiveTweak() {
        history.bumpTweakGeneration();
    }

    void replayHistoryEntry(size_t index) {
        import vibe3d.editing.params.argstring : parseArgstring;

        string line = history.undoEntryCommandLine(index);
        if (line.length == 0) return;
        auto parsed = parseArgstring(line);
        if (parsed.isEmpty) return;
        try {
            invokeLine(parsed.commandId, parsed.params.toString(),
                CommandInvocationContext(CommandOrigin.ui, false));
        } catch (Exception error) {
            textNotice(error.msg);
        }
    }
}
