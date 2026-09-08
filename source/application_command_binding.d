module application_command_binding;

import command : Command, CommandOrigin;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import edit_session : EditSession;
import registry : Registry;
import ui.discard_guard : UiRunOutcome;

/// Call-site facts that affect application dispatch.  The caller identity and
/// continuous-interaction boundary are explicit so neither is inferred from an
/// HTTP-owned latch or from exception control flow (task 4711).
struct CommandInvocationContext {
    CommandOrigin origin;
    bool interactive;
}

enum CommandInvocationOutcome {
    applied,
    refused,
    deferred,
    query,
}

struct CommandInvocationResult {
    CommandInvocationOutcome outcome;
    Command command;
    string queryJson;

    @property bool applied() const {
        return outcome == CommandInvocationOutcome.applied
            || outcome == CommandInvocationOutcome.query;
    }
}

alias UiCommandPolicy = UiRunOutcome delegate(Command, RecordMode, string);
alias CommandNotice = void delegate(Command);
alias TextNotice = void delegate(string);

/// Application-owned command construction and dispatch.  Protocol response
/// delivery and script-refusal exceptions remain adapter responsibilities;
/// this module deliberately has no HTTP dependency (task 4711).
final class ApplicationCommandBinding {
private:
    Registry* registry;
    CommandExecutor executor;
    EditSession session;
    CommandHistory history;
    UiCommandPolicy uiPolicy;
    CommandNotice commandNotice;
    TextNotice textNotice;

    CommandInvocationResult result(CommandInvocationOutcome outcome,
                                   Command command,
                                   string queryJson = "") {
        return CommandInvocationResult(outcome, command, queryJson);
    }

    CommandInvocationResult uiResult(Command command, RecordMode mode,
                                     string dispatchedId) {
        final switch (uiPolicy(command, mode, dispatchedId)) {
            case UiRunOutcome.applied:
                return result(CommandInvocationOutcome.applied, command);
            case UiRunOutcome.refused:
                return result(CommandInvocationOutcome.refused, command);
            case UiRunOutcome.deferred:
                return result(CommandInvocationOutcome.deferred, command);
        }
    }

public:
    this(ref Registry registry, CommandExecutor executor, EditSession session,
         CommandHistory history, UiCommandPolicy uiPolicy,
         CommandNotice commandNotice, TextNotice textNotice) {
        assert(executor !is null, "ApplicationCommandBinding requires CommandExecutor");
        assert(session !is null, "ApplicationCommandBinding requires EditSession");
        assert(history !is null, "ApplicationCommandBinding requires CommandHistory");
        assert(uiPolicy !is null, "ApplicationCommandBinding requires UI policy");
        assert(commandNotice !is null, "ApplicationCommandBinding requires command notice policy");
        assert(textNotice !is null, "ApplicationCommandBinding requires text notice policy");
        this.registry = &registry;
        this.executor = executor;
        this.session = session;
        this.history = history;
        this.uiPolicy = uiPolicy;
        this.commandNotice = commandNotice;
        this.textNotice = textNotice;
    }

    CommandInvocationResult invokeLine(string id, string paramsJson,
                                       CommandInvocationContext context) {
        import command_args : bindArgs;
        import commands.tool.attr : ToolAttrCommand;
        import perf_probe : Cat, g_perf;
        import std.json : JSONType, parseJSON;

        auto factory = id in registry.commandFactories;
        if (factory is null)
            throw new Exception("unknown command id '" ~ id ~ "'");
        auto command = (*factory)();

        if (context.interactive)
            if (auto attr = cast(ToolAttrCommand) command)
                attr.setInteractive(true);

        if (paramsJson.length > 0) {
            auto params = parseJSON(paramsJson);
            bindArgs(command, params);

            if (params.type == JSONType.object) {
                if (auto falloffJson = "falloff" in params.object) {
                    if (falloffJson.type == JSONType.object) {
                        import falloff : IFalloffAware, parseFalloffJson;
                        if (auto aware = cast(IFalloffAware) command)
                            aware.setFalloff(parseFalloffJson(*falloffJson));
                    }
                }
            }
        }

        auto commandApply = g_perf.scope_(Cat.commandApply);
        if (command.isQuery()) {
            if (!command.apply()) {
                if (context.origin == CommandOrigin.ui)
                    commandNotice(command);
                return result(CommandInvocationOutcome.refused, command);
            }
            return result(CommandInvocationOutcome.query, command,
                          command.queryResultJson());
        }

        CommandInvocationResult dispatchResult;
        if (session.tryRefireDispatch(command, id)) {
            dispatchResult = result(CommandInvocationOutcome.applied, command);
        } else if (context.origin == CommandOrigin.ui) {
            dispatchResult = uiResult(command, RecordMode.Coalescing, id);
        } else if (executor.applyOrRefire(command, RecordMode.Coalescing, null)) {
            dispatchResult = result(CommandInvocationOutcome.applied, command);
        } else {
            dispatchResult = result(CommandInvocationOutcome.refused, command);
        }

        // A discrete pipe tweak starts a new refire generation. Continuous UI
        // and automation invocations share one generation until their adapter
        // announces the interaction boundary through endInteractiveTweak().
        if (id == "tool.pipe.attr" && !context.interactive)
            history.bumpTweakGeneration();
        return dispatchResult;
    }

    UiRunOutcome invokeUiCommand(Command command, RecordMode mode,
                                 string dispatchedId = "") {
        return uiPolicy(command, mode, dispatchedId);
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
        import argstring : parseArgstring;

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
