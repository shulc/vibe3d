module command_invocation;

import command : Command, CommandOrigin;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import command_registry : CommandRegistry;

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

alias RefireDispatch = bool delegate(Command, string);
alias UiInvocation = CommandInvocationOutcome delegate(Command, RecordMode, string);
alias InteractiveConfiguration = void delegate(Command, bool);
alias RefusalNotice = void delegate(Command);

// One dispatch path owns binding and origin semantics; desktop supplies policy
// capabilities. Task 20261770; doc/application_layers_wave1_plan_2026-10-08.md §1D.
final class CommandInvocationService {
private:
    CommandRegistry* registry;
    CommandExecutor executor;
    CommandHistory history;
    RefireDispatch tryRefireDispatch;
    UiInvocation invokeUi;
    InteractiveConfiguration configureInteractive;
    RefusalNotice noticeRefusal;

    CommandInvocationResult result(CommandInvocationOutcome outcome,
                                   Command command, string queryJson = "") {
        return CommandInvocationResult(outcome, command, queryJson);
    }

public:
    this(ref CommandRegistry registry, CommandExecutor executor,
         CommandHistory history, RefireDispatch tryRefireDispatch = null,
         UiInvocation invokeUi = null,
         InteractiveConfiguration configureInteractive = null,
         RefusalNotice noticeRefusal = null) {
        assert(executor !is null, "CommandInvocationService requires CommandExecutor");
        assert(history !is null, "CommandInvocationService requires CommandHistory");
        this.registry = &registry;
        this.executor = executor;
        this.history = history;
        this.tryRefireDispatch = tryRefireDispatch;
        this.invokeUi = invokeUi;
        this.configureInteractive = configureInteractive;
        this.noticeRefusal = noticeRefusal;
    }

    CommandInvocationResult invokeLine(string id, string paramsJson,
                                       CommandInvocationContext context) {
        import command_args : bindArgs;
        import vibe3d.util.profiling.perf_probe : Cat, g_perf;
        import std.json : JSONType, parseJSON;

        if (context.origin == CommandOrigin.ui && invokeUi is null)
            throw new Exception("UI invocation requires UI policy");
        auto command = registry.makeCommand(id);
        if (command is null)
            throw new Exception("unknown command id '" ~ id ~ "'");
        command.origin = context.origin;

        if (context.interactive && configureInteractive !is null)
            configureInteractive(command, true);

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
                if (context.origin == CommandOrigin.ui && noticeRefusal !is null)
                    noticeRefusal(command);
                return result(CommandInvocationOutcome.refused, command);
            }
            return result(CommandInvocationOutcome.query, command,
                          command.queryResultJson());
        }

        CommandInvocationResult dispatchResult;
        if (tryRefireDispatch !is null && tryRefireDispatch(command, id)) {
            dispatchResult = result(CommandInvocationOutcome.applied, command);
        } else if (context.origin == CommandOrigin.ui) {
            dispatchResult = result(invokeUi(command, RecordMode.Coalescing, id), command);
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

}
