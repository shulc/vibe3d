module http_command_adapter;

import ai.exploration : AiExplorationController;
import ai.state : EditorAiState;
import application_command_binding : ApplicationCommandBinding,
    CommandInvocationContext, CommandInvocationOutcome, CommandInvocationResult;
import command : Command, CommandOrigin, g_testMode;
import guarded_action_controller : GuardedActionController;
import http_server : HttpServer;
import pipe_gizmo_host : PipeGizmoHost;
import step_trace : StepTrace;

alias AutomationResetHook = void function();

/// Concrete application services reset at the test-automation scene boundary.
/// The adapter owns their order; the application supplies only the narrow
/// services, never an aggregate editor capture (task 5680).
struct AutomationResetContext {
    GuardedActionController guardController;
    PipeGizmoHost pipeGizmoHost;
    EditorAiState aiState;
    AiExplorationController exploration;
    StepTrace trace;
    AutomationResetHook resetUiPolicyRecord;
    AutomationResetHook clearAiDebugTraces;
    AutomationResetHook parkMouse;
    AutomationResetHook closePie;

    this(GuardedActionController guardController,
         PipeGizmoHost pipeGizmoHost,
         EditorAiState aiState,
         AiExplorationController exploration,
         StepTrace trace,
         AutomationResetHook resetUiPolicyRecord,
         AutomationResetHook clearAiDebugTraces,
         AutomationResetHook parkMouse,
         AutomationResetHook closePie) {
        assert(guardController !is null,
            "AutomationResetContext requires guarded-action policy");
        assert(pipeGizmoHost !is null,
            "AutomationResetContext requires pipe gizmo host");
        assert(aiState !is null,
            "AutomationResetContext requires AI state");
        assert(exploration !is null,
            "AutomationResetContext requires exploration state");
        assert(resetUiPolicyRecord !is null,
            "AutomationResetContext requires UI-policy reset hook");
        assert(clearAiDebugTraces !is null,
            "AutomationResetContext requires AI-trace reset hook");
        assert(parkMouse !is null,
            "AutomationResetContext requires mouse reset hook");
        assert(closePie !is null,
            "AutomationResetContext requires pie reset hook");
        this.guardController = guardController;
        this.pipeGizmoHost = pipeGizmoHost;
        this.aiState = aiState;
        this.exploration = exploration;
        this.trace = trace;
        this.resetUiPolicyRecord = resetUiPolicyRecord;
        this.clearAiDebugTraces = clearAiDebugTraces;
        this.parkMouse = parkMouse;
        this.closePie = closePie;
    }
}

/// Protocol adapter for `/api/command` and `/api/script`. Command construction
/// stays in ApplicationCommandBinding; this object owns protocol refusal,
/// query delivery and the external automation-reset sequence (task 5680).
final class CommandHttpAdapter {
private:
    HttpServer httpServer_;
    ApplicationCommandBinding binding_;
    AutomationResetContext automation_;

    void refused(Command command, string id) {
        throw new Exception("command '" ~ id ~ "' did not apply"
            ~ (command.refusalReason().length
                ? ": " ~ command.refusalReason() : ""));
    }

    void resetAutomationBefore(string id) {
        if (!g_testMode || id != "scene.reset") return;
        automation_.resetUiPolicyRecord();
        automation_.guardController.dropPending();
    }

    void deliverResult(CommandInvocationResult invocation, string id,
                       CommandOrigin origin) {
        if (invocation.outcome == CommandInvocationOutcome.query) {
            httpServer_.setCmdResult(invocation.queryJson);
            return;
        }
        if (origin == CommandOrigin.script
            && invocation.outcome == CommandInvocationOutcome.refused)
            refused(invocation.command, id);
    }

    void resetAutomationAfter(CommandInvocationResult invocation,
                              string id, CommandOrigin origin) {
        if (!g_testMode || id != "scene.reset"
            || origin != CommandOrigin.script || !invocation.applied)
            return;
        automation_.pipeGizmoHost.cancelDrag();
        automation_.clearAiDebugTraces();
        automation_.aiState.setEnabled(false);
        automation_.parkMouse();
        automation_.closePie();
        automation_.exploration.discardPending();
        if (automation_.trace !is null) automation_.trace.reset();
    }

public:
    this(HttpServer httpServer, ApplicationCommandBinding binding,
         AutomationResetContext automation) {
        assert(httpServer !is null, "CommandHttpAdapter requires HttpServer");
        assert(binding !is null,
            "CommandHttpAdapter requires ApplicationCommandBinding");
        httpServer_ = httpServer;
        binding_ = binding;
        automation_ = automation;
    }

    CommandInvocationResult dispatchScript(string id, string paramsJson,
                                             bool interactive) {
        resetAutomationBefore(id);
        auto invocation = binding_.invokeLine(id, paramsJson,
            CommandInvocationContext(CommandOrigin.script, interactive));
        deliverResult(invocation, id, CommandOrigin.script);
        resetAutomationAfter(invocation, id, CommandOrigin.script);
        return invocation;
    }

    CommandInvocationResult dispatchUi(string id, string paramsJson,
                                       bool interactive) {
        resetAutomationBefore(id);
        auto invocation = binding_.invokeLine(id, paramsJson,
            CommandInvocationContext(CommandOrigin.ui, interactive));
        deliverResult(invocation, id, CommandOrigin.ui);
        return invocation;
    }

    void wire() {
        httpServer_.setCommandHandler(
            (string id, string paramsJson, bool interactive) {
                dispatchScript(id, paramsJson, interactive);
            });
        // Test-only protocol adapter for the same UI policy used by panels.
        // A refusal remains a notice/deferred outcome and therefore does not
        // become the script adapter's status:error.
        httpServer_.setUiCommandHandler(
            (string id, string paramsJson, bool interactive) {
                dispatchUi(id, paramsJson, interactive);
            });
    }
}
