module application_command_binding_ownership_test;

import std.file : exists, readText;
import std.functional : toDelegate;
import std.path : buildPath, dirName;
import std.algorithm.searching : canFind;
import std.string : indexOf;

import ai.exploration : AiExplorationController;
import ai.state : EditorAiState;
import application_command_binding : ApplicationCommandBinding,
    CommandInvocationOutcome;
import command : CmdFlags, Command, g_testMode;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import edit_session : EditSession;
import editmode : EditMode;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import http_command_adapter : AutomationResetContext, AutomationResetHook,
    CommandHttpAdapter;
import http_server : HttpServer;
import mesh : Mesh;
import pipe_gizmo_host : PipeGizmoHost;
import registry : Registry;
import step_trace : StepTrace;
import tool : Tool;
import ui.discard_guard : UiRunOutcome;
import view : View;

private size_t uiResetCalls;
private size_t aiTraceResetCalls;
private size_t parkMouseCalls;
private size_t closePieCalls;

private void resetUiRecordProbe() { ++uiResetCalls; }
private void clearAiTraceProbe() { ++aiTraceResetCalls; }
private void parkMouseProbe() { ++parkMouseCalls; }
private void closePieProbe() { ++closePieCalls; }

private AutomationResetHook resetHook(void function() hook) {
    static if (is(AutomationResetHook == void function())) {
        return hook;
    } else {
        return toDelegate(hook);
    }
}

private final class AdapterProbeCommand : Command {
    private bool succeeds_;
    private bool discards_;
    private string queryJson_;

    this(bool succeeds, bool discards = false, string queryJson = "") {
        static Mesh mesh;
        static View view;
        if (view is null) view = new View(0, 0, 1, 1);
        super(&mesh, view, EditMode.Vertices);
        succeeds_ = succeeds;
        discards_ = discards;
        queryJson_ = queryJson;
        if (queryJson_.length) markQuery();
    }

    override string name() const { return "scene.reset"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    override bool discardsUnsavedWork() const { return discards_; }
    override bool acceptsQuery() const { return queryJson_.length > 0; }
    override string queryResultJson() const { return queryJson_; }

    protected override bool applyImpl() {
        baseRefusal_ = succeeds_ ? "" : "probe refused";
        return succeeds_;
    }
}

private string repoFile(string relative) {
    auto root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    auto path = buildPath(root, relative);
    assert(exists(path), "application binding ownership: missing " ~ relative);
    return readText(path);
}

private size_t occurrences(string source, string needle) {
    size_t count;
    size_t offset;
    while (offset < source.length) {
        auto found = source[offset .. $].indexOf(needle);
        if (found < 0) break;
        ++count;
        offset += cast(size_t)found + needle.length;
    }
    return count;
}

unittest {
    auto binding = repoFile("source/application_command_binding.d");
    auto controller = repoFile("source/guarded_action_controller.d");
    auto executor = repoFile("source/command_executor.d");
    auto http = repoFile("source/http_providers.d");
    auto httpCommand = repoFile("source/http_command_adapter.d");
    auto app = repoFile("source/app.d");

    assert(binding.length > 4_000,
        "application binding ownership: binding population is implausibly small");
    assert(binding.canFind("Registry* registry")
        && binding.canFind("CommandExecutor executor")
        && binding.canFind("EditSession session")
        && binding.canFind("CommandInvocationContext")
        && binding.canFind("GuardedActionController uiPolicy"),
        "application binding ownership: required binding inputs disappeared");
    assert(!binding.canFind("import http_server"),
        "application binding ownership: common binding must not depend on HTTP");
    assert(!executor.canFind("import editor_app"),
        "application binding ownership: CommandExecutor regained EditorApp");
    assert(controller.canFind("Command pendingCommand_")
        && controller.canFind("RecordMode pendingMode_")
        && controller.canFind("GuardSettle settle_"),
        "guard action ownership: controller lost owned pending state");
    immutable string[] forbiddenControllerImports = [
        "editor_app", "http_server", "bindbc.sdl", "d_imgui",
    ];
    foreach (needle; forbiddenControllerImports)
        assert(!controller.canFind(needle),
            "guard action ownership: controller gained forbidden dependency '"
            ~ needle ~ "'");

    immutable string[] retiredHttpOwners = [
        "formsInteractiveLatch",
        "setInteractiveLatchHook",
        "formsPanel.setTweakEndHook",
        "replayUndoEntry =",
        "uiCommandDelegate =",
        "formsInteractiveDispatch =",
        "new ApplicationCommandBinding",
    ];
    foreach (needle; retiredHttpOwners)
        assert(!http.canFind(needle),
            "application binding ownership: HTTP still owns '" ~ needle ~ "'");

    assert(!httpCommand.canFind("editor_app")
        && !httpCommand.canFind("EditorApp"),
        "HTTP command adapter regained a dependency on EditorApp");
    assert(httpCommand.canFind(
            "alias AutomationResetHook = void function();"),
        "HTTP command adapter reset hooks must remain plain function pointers");
    assert(!httpCommand.canFind("http_providers"),
        "HTTP command adapter must not depend on legacy HTTP providers");
    assert(httpCommand.canFind("HttpServer httpServer_")
        && httpCommand.canFind("ApplicationCommandBinding binding_")
        && httpCommand.canFind("AutomationResetContext automation_"),
        "HTTP command adapter lost one of its three explicit owners");
    immutable string[] retiredCommandBody = [
        "void resetAutomationBefore(",
        "void resetAutomationAfter(",
        "void refused(Command",
        "setCommandHandler(",
        "setUiCommandHandler(",
    ];
    foreach (needle; retiredCommandBody)
        assert(!http.canFind(needle),
            "HTTP providers retained command-adapter body '" ~ needle ~ "'");

    assert(occurrences(app, "    uiCommandDelegate = (") == 1
        && occurrences(app, "    formsInteractiveDispatch = (") == 1
        && occurrences(app, "    replayUndoEntry = (") == 1,
        "application binding ownership: application delegates are not each bound once");
    assert(occurrences(app, "new CommandHttpAdapter(") == 1
        && occurrences(app,
            "wireHttpProviders(httpServer, app, ifs, executor, commandHttpAdapter)") == 1,
        "application binding ownership: HTTP adapter is not consuming the application binding");
    const bindingAt = app.indexOf("commandBinding = new ApplicationCommandBinding(");
    const adapterAt = app.indexOf("auto commandHttpAdapter = new CommandHttpAdapter(");
    const wireAt = app.indexOf(
        "wireHttpProviders(httpServer, app, ifs, executor, commandHttpAdapter);");
    assert(bindingAt >= 0 && adapterAt > bindingAt && wireAt > adapterAt,
        "application binding must exist before the listener-independent HTTP wiring");
    const adapterRegion = app[cast(size_t)bindingAt ..
        cast(size_t)wireAt +
        "wireHttpProviders(httpServer, app, ifs, executor, commandHttpAdapter);".length];
    assert(!adapterRegion.canFind("if (startHttpServer)"),
        "HTTP command adapter construction and wiring must remain available under --no-http");

    immutable string[] retiredGuardLocals = [
        "pendingGuardedCmd", "pendingGuardedMode", "guardSettle",
        "void guardAnswerSave()", "void guardAnswerDiscard()",
        "void guardAnswerCancel()", "void settleGuardedAction()",
    ];
    foreach (needle; retiredGuardLocals)
        assert(!app.canFind(needle),
            "guard action ownership: app.d retained '" ~ needle ~ "'");
    assert(occurrences(app, "guardController.dropPending();") == 1,
        "primary switch forgot the pending guarded action");

    // This byte-offset check pins only the calls' order within app.d; it does
    // not claim which ImGui phase contains them.
    const syncAt = app.indexOf("syncDocRevision(changeBus.docRevision());");
    const settleAt = app.indexOf("guardController.settle();");
    assert(syncAt >= 0 && settleAt > syncAt,
        "guard action ownership: settle must remain after syncDocRevision");
}

unittest { // command adapter owns reset policy without an EditorApp capture
    const previousTestMode = g_testMode;
    scope(exit) g_testMode = previousTestMode;
    g_testMode = true;

    uiResetCalls = 0;
    aiTraceResetCalls = 0;
    parkMouseCalls = 0;
    closePieCalls = 0;

    auto history = new CommandHistory();
    Tool activeTool;
    auto executor = new CommandExecutor(
        history,
        () => activeTool !is null,
        (transition) { activeTool = null; });
    auto session = new EditSession(
        () => activeTool,
        history,
        () { activeTool = null; });
    bool dirty;
    auto guard = new GuardedActionController(GuardedActionPorts(
        (Command command, RecordMode mode) =>
            executor.applyOrRefire(command, mode, null),
        () => dirty,
        () => true,
        (Command command) {},
        GuardObservationPorts(
            (record) {},
            (answer, performed) {},
            (pending) {})));

    bool resetSucceeds = true;
    Registry registry;
    registry.commandFactories["scene.reset"] = () =>
        cast(Command)new AdapterProbeCommand(resetSucceeds, true);
    registry.commandFactories["probe.query"] = () =>
        cast(Command)new AdapterProbeCommand(true, false, `{"value":7}`);
    auto binding = new ApplicationCommandBinding(
        registry, executor, session, history, guard,
        (Command command) {},
        (string message) {});
    auto server = new HttpServer(8580);
    auto pipeGizmo = new PipeGizmoHost();
    auto aiState = new EditorAiState();
    auto exploration = new AiExplorationController(0.0f, 42u);
    auto trace = new StepTrace();
    auto adapter = new CommandHttpAdapter(
        server,
        binding,
        AutomationResetContext(
            guard,
            pipeGizmo,
            aiState,
            exploration,
            trace,
            resetHook(&resetUiRecordProbe),
            resetHook(&clearAiTraceProbe),
            resetHook(&parkMouseProbe),
            resetHook(&closePieProbe)));
    adapter.wire();

    // Seed a real pending guard, then drive scene.reset through the UI door.
    // before() must drop it; after() must not run on this origin.
    dirty = true;
    assert(guard.invoke(new AdapterProbeCommand(true, true),
        RecordMode.Record, "file.new") == UiRunOutcome.deferred,
        "adapter UI-before setup must create a pending guarded action");
    assert(guard.pending,
        "adapter UI-before population floor: pending action was not seeded");
    dirty = false;
    trace.arm();
    trace.append(`{"door":"ui"}`);
    assert(trace.snapshotJson() != "[]",
        "adapter UI reset population floor: trace was not populated");
    aiState.setEnabled(true);
    const pipeBeforeUi = pipeGizmo.preparedCancelCountForTest();
    auto uiResult = adapter.dispatchUi("scene.reset", "", false);
    assert(uiResult.outcome == CommandInvocationOutcome.applied,
        "adapter UI scene.reset did not apply");
    assert(!guard.pending && uiResetCalls == 1,
        "adapter UI scene.reset did not run automation-before");
    assert(trace.snapshotJson() != "[]"
        && pipeGizmo.preparedCancelCountForTest() == pipeBeforeUi
        && aiState.enabled
        && aiTraceResetCalls == 0 && parkMouseCalls == 0 && closePieCalls == 0,
        "adapter UI scene.reset incorrectly ran automation-after");

    // Successful script reset runs before and then the complete after policy.
    dirty = true;
    assert(guard.invoke(new AdapterProbeCommand(true, true),
        RecordMode.Record, "file.new") == UiRunOutcome.deferred,
        "adapter script-before setup must create a pending guarded action");
    assert(guard.pending,
        "adapter script-before population floor: pending action was not seeded");
    dirty = false;
    trace.reset();
    trace.append(`{"door":"script"}`);
    assert(trace.snapshotJson() != "[]",
        "adapter script reset population floor: trace was not populated");
    const pipeBeforeScript = pipeGizmo.preparedCancelCountForTest();
    auto scriptResult = adapter.dispatchScript("scene.reset", "", false);
    assert(scriptResult.outcome == CommandInvocationOutcome.applied,
        "adapter script scene.reset did not apply");
    assert(!guard.pending && uiResetCalls == 2,
        "adapter script scene.reset did not run automation-before");
    assert(pipeGizmo.preparedCancelCountForTest() == pipeBeforeScript + 1
        && !aiState.enabled
        && aiTraceResetCalls == 1 && parkMouseCalls == 1 && closePieCalls == 1,
        "successful script scene.reset did not run the complete automation-after policy");
    assert(trace.snapshotJson() == "[]",
        "successful script scene.reset left non-empty automation trace state");

    // A refused script reset still runs before, but the adapter-owned protocol
    // exception prevents after. The trace floor makes survival non-vacuous.
    dirty = true;
    assert(guard.invoke(new AdapterProbeCommand(true, true),
        RecordMode.Record, "file.new") == UiRunOutcome.deferred,
        "adapter refused-reset setup must create a pending guarded action");
    dirty = false;
    trace.append(`{"door":"refused"}`);
    assert(trace.snapshotJson() != "[]",
        "adapter refused-reset population floor: trace was not populated");
    aiState.setEnabled(true);
    resetSucceeds = false;
    const historyBefore = history.undoEntriesVisible().length;
    const pipeBeforeRefusal = pipeGizmo.preparedCancelCountForTest();
    bool threw;
    try {
        adapter.dispatchScript("scene.reset", "", false);
    } catch (Exception error) {
        threw = true;
        assert(error.msg.canFind("probe refused"),
            "adapter refusal lost the command reason: " ~ error.msg);
    }
    assert(threw, "refused script scene.reset must throw a protocol error");
    assert(!guard.pending && uiResetCalls == 3,
        "refused script scene.reset did not run automation-before");
    assert(history.undoEntriesVisible().length == historyBefore,
        "refused script scene.reset added a history entry");
    assert(trace.snapshotJson() != "[]"
        && pipeGizmo.preparedCancelCountForTest() == pipeBeforeRefusal
        && aiState.enabled
        && aiTraceResetCalls == 1 && parkMouseCalls == 1 && closePieCalls == 1,
        "refused script scene.reset incorrectly ran automation-after");

    resetSucceeds = true;
    auto query = adapter.dispatchScript("probe.query", "", false);
    assert(query.outcome == CommandInvocationOutcome.query
        && query.queryJson == `{"value":7}`,
        "command adapter did not preserve the query's own JSON");

    // Outside test automation, neither reset gate may touch its context.
    g_testMode = false;
    dirty = true;
    assert(guard.invoke(new AdapterProbeCommand(true, true),
        RecordMode.Record, "file.new") == UiRunOutcome.deferred,
        "non-test reset setup must create a pending guarded action");
    assert(guard.pending,
        "non-test reset population floor: pending action was not seeded");
    dirty = false;
    trace.append(`{"door":"non-test"}`);
    assert(trace.snapshotJson() != "[]",
        "non-test reset population floor: trace was not populated");
    aiState.setEnabled(true);
    const uiCallsBeforeNonTest = uiResetCalls;
    const pipeBeforeNonTest = pipeGizmo.preparedCancelCountForTest();
    const aiTraceBeforeNonTest = aiTraceResetCalls;
    const parkBeforeNonTest = parkMouseCalls;
    const pieBeforeNonTest = closePieCalls;
    auto nonTestResult = adapter.dispatchScript("scene.reset", "", false);
    assert(nonTestResult.outcome == CommandInvocationOutcome.applied,
        "non-test scene.reset did not apply");
    assert(guard.pending && uiResetCalls == uiCallsBeforeNonTest,
        "non-test scene.reset incorrectly ran automation-before");
    assert(trace.snapshotJson() != "[]"
        && pipeGizmo.preparedCancelCountForTest() == pipeBeforeNonTest
        && aiState.enabled
        && aiTraceResetCalls == aiTraceBeforeNonTest
        && parkMouseCalls == parkBeforeNonTest
        && closePieCalls == pieBeforeNonTest,
        "non-test scene.reset incorrectly ran automation-after");
}
