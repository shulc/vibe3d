module tests.unit.history_replay_boundary_test;

import ai.exploration : AiExplorationController;
import ai.state : EditorAiState;
import application_command_binding : ApplicationCommandBinding;
import command : CmdFlags, Command, g_testMode;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.tool.attr : ToolAttrCommand;
import commands.tool.host : ToolHost;
import edit_session : EditSession;
import editmode : EditMode;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import http_command_adapter : AutomationResetContext, AutomationResetHook,
    CommandHttpAdapter;
import http_providers : HistoryHttpAdapter;
import http_server : BridgeResultKind, HttpServer;
import mesh : Mesh, makeCube;
import params : Param, wireArgs;
import perf_probe : g_commandGc;
import pipe_gizmo_host : PipeGizmoHost;
import registry : Registry;
import step_trace : StepTrace;
import std.algorithm : canFind, count;
import std.conv : to;
import std.file : exists, readText;
import std.functional : toDelegate;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.socket : InternetAddress, Socket, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.string : indexOf, startsWith;
import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import tool : Tool;
import view : View;

private size_t resetUiCalls;
private size_t clearTraceCalls;
private size_t parkMouseCalls;
private size_t closePieCalls;
private size_t clearInputKeysCalls;

private void resetUiProbe() { ++resetUiCalls; }
private void clearTraceProbe() { ++clearTraceCalls; }
private void parkMouseProbe() { ++parkMouseCalls; }
private void closePieProbe() { ++closePieCalls; }
private void clearInputKeysProbe() { ++clearInputKeysCalls; }

private AutomationResetHook resetHook(void function() hook) {
    static if (is(AutomationResetHook == void function())) return hook;
    else return toDelegate(hook);
}

private final class BoundaryState {
    size_t moveApplies;
    size_t refusalApplies;
    size_t guardedApplies;
    size_t queryApplies;
    size_t throwingApplies;
    size_t notices;
    size_t guardRequests;
    size_t pendingTransitions;
    size_t lastVertex = size_t.max;
    float lastAmount;
}

private final class MoveSelectedCommand : Command {
    BoundaryState state_;
    float amount_;
    size_t changed_ = size_t.max;
    float before_;

    this(Mesh* mesh, ref View view, BoundaryState state, float amount = 0) {
        super(mesh, view, EditMode.Vertices);
        state_ = state;
        amount_ = amount;
    }
    override string name() const { return "probe.moveSelected"; }
    override string label() const { return "Move selected probe"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    override Param[] params() {
        return [Param.float_("amount", "Amount", &amount_, 0.0f)];
    }
    protected override bool applyImpl() {
        auto selected = mesh.selectedVertexView();
        foreach (i; 0 .. selected.length) {
            if (!selected[i]) continue;
            changed_ = i;
            before_ = mesh.vertices[i].x;
            mesh.vertices[i].x += amount_;
            noteUndoRecorded();
            ++state_.moveApplies;
            state_.lastVertex = i;
            state_.lastAmount = amount_;
            return true;
        }
        baseRefusal_ = "no selected vertex";
        return false;
    }
    protected override void revertImpl() {
        mesh.vertices[changed_].x = before_;
    }
}

private final class EmptyLineCommand : Command {
    string id_;
    CmdFlags flags_;
    this(Mesh* mesh, ref View view, string id,
         CmdFlags flags = CmdFlags.Model) {
        super(mesh, view, EditMode.Vertices);
        id_ = id;
        flags_ = flags;
    }
    override string name() const { return id_; }
    override string label() const { return id_ ~ " carrier"; }
    override CmdFlags cmdFlags() const { return flags_; }
    protected override bool applyImpl() { noteUndoRecorded(); return true; }
    protected override void revertImpl() {}
}

private final class RefusingCommand : Command {
    BoundaryState state_;
    this(Mesh* mesh, ref View view, BoundaryState state) {
        super(mesh, view, EditMode.Vertices);
        state_ = state;
    }
    override string name() const { return "probe.refuse"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    protected override bool applyImpl() {
        ++state_.refusalApplies;
        baseRefusal_ = "boundary refusal";
        return false;
    }
}

private final class GuardedCommand : Command {
    BoundaryState state_;
    this(Mesh* mesh, ref View view, BoundaryState state) {
        super(mesh, view, EditMode.Vertices);
        state_ = state;
    }
    override string name() const { return "probe.guarded"; }
    override string label() const { return "Guarded boundary probe"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    override bool discardsUnsavedWork() const { return true; }
    protected override bool applyImpl() {
        ++state_.guardedApplies;
        noteUndoRecorded();
        return true;
    }
    protected override void revertImpl() {}
}

private final class QueryCommand : Command {
    BoundaryState state_;
    this(Mesh* mesh, ref View view, BoundaryState state) {
        super(mesh, view, EditMode.Vertices);
        state_ = state;
        markQuery();
    }
    override string name() const { return "probe.query"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }
    override bool acceptsQuery() const { return true; }
    override string queryResultJson() const {
        return `{"owner":"query-` ~ state_.queryApplies.to!string ~ `"}`;
    }
    protected override bool applyImpl() { ++state_.queryApplies; return true; }
}

private final class ThrowingCommand : Command {
    BoundaryState state_;
    this(Mesh* mesh, ref View view, BoundaryState state) {
        super(mesh, view, EditMode.Vertices);
        state_ = state;
    }
    override string name() const { return "probe.throw"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    protected override bool applyImpl() {
        ++state_.throwingApplies;
        throw new Exception("boundary throw sentinel");
    }
}

private final class ProbeTool : Tool {
    float amount;
    size_t changes;
    size_t interactiveChanges;
    size_t scriptedChanges;
    size_t evaluations;

    override Param[] params() {
        return [Param.float_("amount", "Amount", &amount, 0.0f)];
    }
    override void onParamChanged(string name) {
        ++changes;
        if (interactiveParamEdit) ++interactiveChanges;
        else ++scriptedChanges;
    }
    override void evaluate() { ++evaluations; }
}

private final class ToolAttrCarrier : Command {
    string tool_ = "probe.tool";
    string attr_ = "amount";
    float value_;
    this(Mesh* mesh, ref View view, float value) {
        super(mesh, view, EditMode.Vertices);
        value_ = value;
    }
    override string name() const { return "tool.attr"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    override Param[] params() {
        return wireArgs(
            Param.string_("tool", "Tool", &tool_, ""),
            Param.string_("attr", "Attribute", &attr_, ""),
            Param.float_("value", "Value", &value_, 0.0f));
    }
    protected override bool applyImpl() { noteUndoRecorded(); return true; }
    protected override void revertImpl() {}
}

private final class AsyncReply {
    shared bool done;
    string wire;
    string failure;
}

private ushort reservedPort() {
    static ushort nextPort = 8720;
    foreach (_; 0 .. 10) {
        immutable candidate = nextPort;
        nextPort = candidate == 8729 ? 8720 : cast(ushort)(candidate + 1);
        auto probe = new TcpSocket();
        try {
            probe.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
            probe.bind(new InternetAddress("127.0.0.1", candidate));
            probe.close();
            return candidate;
        } catch (Exception) {
            probe.close();
        }
    }
    throw new Exception("5820 reserved HTTP ports 8720-8729 are all occupied");
}

private Thread startRequest(ushort port, string method, string path,
                            string body, AsyncReply reply) {
    auto client = new Thread({
        try {
            Socket socket;
            foreach (_; 0 .. 200) {
                try {
                    socket = new TcpSocket();
                    socket.connect(new InternetAddress("127.0.0.1", port));
                    break;
                } catch (Exception) {
                    if (socket !is null) socket.close();
                    socket = null;
                    Thread.sleep(5.msecs);
                }
            }
            if (socket is null) throw new Exception("boundary server unavailable");
            scope(exit) socket.close();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                             10.seconds);
            auto request = method ~ " " ~ path ~ " HTTP/1.1\r\n"
                         ~ "Host: 127.0.0.1\r\nConnection: close\r\n"
                         ~ "Content-Length: " ~ body.length.to!string
                         ~ "\r\n\r\n" ~ body;
            socket.send(request);
            ubyte[8192] buf;
            for (;;) {
                auto n = socket.receive(buf[]);
                if (n <= 0) break;
                reply.wire ~= cast(string) buf[0 .. n].idup;
            }
        } catch (Exception e) {
            reply.failure = e.msg;
        }
        atomicStore(reply.done, true);
    });
    client.start();
    return client;
}

private bool waitUntil(bool delegate() ready, Duration budget = 2.seconds) {
    immutable deadline = MonoTime.currTime + budget;
    while (!ready()) {
        if (MonoTime.currTime >= deadline) return false;
        Thread.sleep(1.msecs);
    }
    return true;
}

private string responseBody(AsyncReply reply) {
    assert(reply.failure.length == 0,
        "5820 HTTP client failure: " ~ reply.failure);
    immutable split = reply.wire.indexOf("\r\n\r\n");
    assert(split >= 0, "5820 HTTP response has no body: " ~ reply.wire);
    return reply.wire[split + 4 .. $];
}

private JSONValue responseJson(AsyncReply reply, string status,
                               string context) {
    assert(reply.wire.startsWith(status ~ "\r\n"),
        context ~ " status changed: " ~ reply.wire);
    assert(reply.wire.canFind("Content-Type: application/json\r\n"),
        context ~ " content type changed: " ~ reply.wire);
    return parseJSON(responseBody(reply));
}

private final class Fixture {
    Mesh mesh;
    View view;
    BoundaryState state;
    CommandHistory history;
    ProbeTool tool;
    CommandExecutor executor;
    EditSession session;
    GuardedActionController guard;
    Registry registry;
    HttpServer server;
    HistoryHttpAdapter historyAdapter;
    PipeGizmoHost pipeGizmo;
    bool dirty;
    ushort port;

    this(bool withUiHandler = true) {
        mesh = makeCube();
        mesh.buildLoops();
        mesh.syncSelection();
        mesh.selectVertex(0);
        view = new View(0, 0, 800, 600);
        state = new BoundaryState();
        history = new CommandHistory();
        tool = new ProbeTool();
        executor = new CommandExecutor(history, () => false, (transition) {});
        Tool active = tool;
        session = new EditSession(() => active, history, () { active = null; });
        guard = new GuardedActionController(GuardedActionPorts(
            (Command command, RecordMode mode) =>
                executor.applyOrRefire(command, mode, null),
            () => dirty,
            () => true,
            (Command command) { ++state.notices; },
            GuardObservationPorts(
                (record) { ++state.guardRequests; },
                (answer, performed) {},
                (pending) { ++state.pendingTransitions; })));

        ToolHost host;
        host.getActiveTool = () => active;
        host.getActiveToolId = () => "probe.tool";
        host.activate = (id) {};
        host.activatePrepared = (id, ref JSONValue params) {};
        host.deactivate = () { active = null; };
        host.resetActiveTool = (id) => false;
        host.session = () => session;

        registry.registerCommand("probe.moveSelected", () =>
            cast(Command)new MoveSelectedCommand(&mesh, view, state));
        registry.registerCommand("probe.refuse", () =>
            cast(Command)new RefusingCommand(&mesh, view, state));
        registry.registerCommand("probe.guarded", () =>
            cast(Command)new GuardedCommand(&mesh, view, state));
        registry.registerCommand("probe.query", () =>
            cast(Command)new QueryCommand(&mesh, view, state));
        registry.registerCommand("probe.throw", () =>
            cast(Command)new ThrowingCommand(&mesh, view, state));
        registry.registerCommand("tool.attr", () =>
            cast(Command)new ToolAttrCommand(&mesh, view, EditMode.Vertices, host));
        registry.registerCommand("scene.reset", () =>
            cast(Command)new GuardedCommand(&mesh, view, state));

        auto binding = new ApplicationCommandBinding(
            registry, executor, session, history, guard,
            (Command command) { ++state.notices; },
            (string message) {});
        port = reservedPort();
        server = new HttpServer(port);
        server.setTestMode(true);
        auto commandAdapter = new CommandHttpAdapter(
            server, binding,
            AutomationResetContext(
                guard,
                pipeGizmo = new PipeGizmoHost(),
                new EditorAiState(),
                new AiExplorationController(0.0f, 5820u),
                new StepTrace(),
                resetHook(&resetUiProbe),
                resetHook(&clearTraceProbe),
                resetHook(&parkMouseProbe),
                resetHook(&closePieProbe),
                resetHook(&clearInputKeysProbe)));
        commandAdapter.wire();
        if (!withUiHandler) server.setUiCommandHandler(null);
        historyAdapter = new HistoryHttpAdapter(history, session, null);
        historyAdapter.wire(server);
        server.markProvidersWired();
        server.tickAll();
        server.start();
    }

    void stop() {
        if (server.running) server.stop();
    }

    void record(Command command, bool lifecycle = false) {
        assert(command.apply(), "5820 carrier setup did not apply");
        if (lifecycle) history.recordToolLifecycle(command);
        else history.record(command);
    }

    AsyncReply request(string method, string path, string body,
                       bool delegate() pending) {
        auto reply = new AsyncReply();
        auto client = startRequest(port, method, path, body, reply);
        scope(exit) if (client.isRunning) client.join();
        assert(waitUntil(() => pending() || atomicLoad(reply.done)),
            "5820 request did not reach its service boundary: " ~ path);
        if (!atomicLoad(reply.done)) server.tickAll();
        assert(waitUntil(() => atomicLoad(reply.done)),
            "5820 serviced request did not complete: " ~ path);
        client.join();
        return reply;
    }

    AsyncReply command(string path, string body) {
        return request("POST", path, body,
            () => server.commandPendingForTest());
    }

    AsyncReply replay(size_t index) {
        return request("POST", "/api/history/replay",
            `{"index":` ~ index.to!string ~ `}`,
            () => server.replayOwnedPendingForTest() == 1);
    }

    AsyncReply status() {
        return request("GET", "/api/undo/status", "",
            () => server.undoStatusOwnedPendingForTest() == 1);
    }
}

private void resetGlobalProbes() {
    resetUiCalls = 0;
    clearTraceCalls = 0;
    parkMouseCalls = 0;
    closePieCalls = 0;
    clearInputKeysCalls = 0;
}

unittest { // source wiring closes both production entries over one port
    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    auto source = readText(buildPath(root, "source", "http_server.d"));
    auto adapter = readText(buildPath(root, "source", "http_command_adapter.d"));
    assert(source.length > 100_000,
        "5820 source census population floor: http_server.d is implausibly small");
    assert(source.count("executeCommand(req.id, req.params, req.interactive,") == 1,
        "5820 production wiring: legacy command service must call executeCommand once");
    assert(source.count("executeCommand(parsed.commandId, parsed.params.toString(),") == 1,
        "5820 production wiring: replay service must call executeCommand once");
    assert(adapter.count("httpServer_.setCommandHandler(") == 1
        && adapter.count("httpServer_.setUiCommandHandler(") == 1
        && adapter.count("dispatchScript(id, paramsJson, interactive);") == 1
        && adapter.count("dispatchUi(id, paramsJson, interactive);") == 1,
        "5820 production wiring: CommandHttpAdapter.wire must install both "
      ~ "real dispatch callbacks into the shared execution port");
    assert(!source.canFind("commandBridge.submitAndWait(kCommandBridgeMaxIters)\n"
                         ~ "                        commandBridge.resp.error"),
        "5820 replay wiring: replay must not wait on commandBridge from main thread");
    assert(source.count(
        "struct CmdReq  { string id; string params; bool interactive; bool uiOrigin; }") == 1
        && source.count("struct ReplayReq {") == 1,
        "5820 compatibility carrier population floor: command/replay requests missing");
    assert(!source.canFind("replayInteractiveLatch")
        && !source.canFind("replayUiOriginLatch"),
        "5820 compatibility carrier gained a second independently maintained latch");
    immutable routeAt = source.indexOf(`RouteSpec("/api/undo/status"`);
    assert(routeAt >= 0, "5820 status RouteSpec is absent");
    immutable routeEnd = source.indexOf('\n', cast(size_t) routeAt);
    auto route = source[routeAt .. routeEnd];
    assert(route.canFind("Answered.mainThread")
        && route.canFind(`"route_apiUndoStatus"`),
        "5820 status RouteSpec must claim its main-thread handler");
    assert(source.canFind("private Duration replayBudget_ = 120.seconds;")
        && source.canFind("private Duration undoStatusBudget_ = 5.seconds;"),
        "5820 status/replay budgets must remain 5/120 seconds");
}

unittest { // populated status is encoded on one known tick thread, lockout both ways
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    resetGlobalProbes();
    auto f = new Fixture();
    scope(exit) f.stop();
    f.record(new EmptyLineCommand(&f.mesh, f.view, "status.model", CmdFlags.Model));
    f.record(new EmptyLineCommand(&f.mesh, f.view, "status.ui", CmdFlags.UiState));
    f.record(new EmptyLineCommand(&f.mesh, f.view, "status.lifecycle",
        CmdFlags.ToolLifecycle | CmdFlags.UndoForce), true);
    assert(f.history.undoEntriesVisible().length == 3,
        "5820 status population floor: Model/UI/lifecycle rows are required");
    immutable tickThread = cast(size_t) cast(void*) Thread.getThis();
    auto unlocked = responseJson(f.status(), "HTTP/1.1 200 OK",
                                 "5820 status unlocked");
    assert(f.historyAdapter.undoStatusProviderCallsForTest() == 1,
        "5820 status callback floor: production provider did not run once");
    assert(f.historyAdapter.undoStatusProviderThreadForTest() == tickThread,
        "5820 status thread identity: first status read was not on tick thread");
    assert(unlocked["state"].str == "active"
        && !unlocked["lockout"].boolean
        && unlocked["canUndo"].boolean
        && !unlocked["canRedo"].boolean
        && unlocked["modelDepth"].integer == 1
        && unlocked["uiDepth"].integer == 1
        && unlocked["toolLifecycleCount"].integer == 1
        && unlocked["canUndoLifecycle"].boolean,
        "5820 status payload did not describe populated Model/UI/lifecycle history: "
        ~ unlocked.toString());

    f.history.setLockout(true);
    auto locked = responseJson(f.status(), "HTTP/1.1 200 OK",
                               "5820 status locked");
    assert(locked["lockout"].boolean
        && locked["modelDepth"].integer == 1
        && locked["uiDepth"].integer == 1
        && locked["toolLifecycleCount"].integer == 1,
        "5820 status lockout=true lost the same service-state depths: "
        ~ locked.toString());
}

unittest { // raw index, current target, one tick and a new history record
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    resetGlobalProbes();
    auto f = new Fixture();
    scope(exit) f.stop();
    f.record(new MoveSelectedCommand(&f.mesh, f.view, f.state, 1.0f));
    f.record(new MoveSelectedCommand(&f.mesh, f.view, f.state, 4.0f));
    assert(f.history.undoEntriesVisible().length == 2,
        "5820 replay index floor: two genuinely different command rows required");
    f.state.moveApplies = 0;
    f.mesh.clearVertexSelection();
    f.mesh.selectVertex(1);
    const v0Before = f.mesh.vertices[0].x;
    const v1Before = f.mesh.vertices[1].x;
    const historyBefore = f.history.undoEntriesVisible().length;
    immutable tickThread = cast(size_t) cast(void*) Thread.getThis();

    auto reply = new AsyncReply();
    auto client = startRequest(f.port, "POST", "/api/history/replay",
        `{"index":0}`, reply);
    scope(exit) if (client.isRunning) client.join();
    assert(waitUntil(() => f.server.replayOwnedPendingForTest() == 1),
        "5820 replay submission floor: request did not queue");
    {
        f.server.tickAll();
    }
    assert(waitUntil(() => atomicLoad(reply.done)),
        "5820 replay no-frame: one tick did not both read and execute");
    client.join();
    auto body = responseJson(reply, "HTTP/1.1 200 OK", "5820 replay success");
    assert(body["status"].str == "ok"
        && body["line"].str.canFind("amount:1"),
        "5820 replay payload/index: raw index 0 did not execute its 1-unit row: "
        ~ body.toString());
    assert(f.historyAdapter.replayProviderCallsForTest() == 1,
        "5820 replay callback floor: production history reader did not run once");
    assert(f.historyAdapter.replayProviderThreadForTest() == tickThread,
        "5820 replay thread identity: first history read was not on tick thread");
    assert(f.state.moveApplies == 1 && f.state.lastVertex == 1
        && f.state.lastAmount == 1.0f,
        "5820 replay current-target floor: wrong command or selected vertex applied");
    assert(f.mesh.vertices[0].x == v0Before
        && f.mesh.vertices[1].x == v1Before + 1.0f,
        "5820 replay current-target geometry: replay used captured rather than current selection");
    assert(f.history.undoEntriesVisible().length == historyBefore + 1,
        "5820 replay record: successful apply did not append one new history row");
}

unittest { // null fallbacks, invalid index and HTTP-side index validation
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;

    immutable barePort = reservedPort();
    auto bare = new HttpServer(barePort);
    bare.markProvidersWired();
    bare.tickAll();
    bare.start();
    scope(exit) if (bare.running) bare.stop();

    auto statusReply = new AsyncReply();
    auto statusClient = startRequest(barePort, "GET", "/api/undo/status", "",
                                     statusReply);
    assert(waitUntil(() => atomicLoad(statusReply.done)),
        "5820 null status fallback did not answer without a bridge tick");
    statusClient.join();
    assert(responseBody(statusReply) ==
        `{"state":"invalid","lockout":false,"canUndo":false,"canRedo":false}`,
        "5820 null status fallback changed: " ~ responseBody(statusReply));

    auto replayReply = new AsyncReply();
    auto replayClient = startRequest(barePort, "POST", "/api/history/replay",
                                     `{"index":0}`, replayReply);
    assert(waitUntil(() => atomicLoad(replayReply.done)),
        "5820 null replay fallback did not answer without a bridge tick");
    replayClient.join();
    auto nullReplay = responseJson(replayReply, "HTTP/1.1 200 OK",
                                   "5820 null replay");
    assert(nullReplay["status"].str == "error"
        && nullReplay["message"].str == "replay provider not set",
        "5820 null replay fallback changed: " ~ nullReplay.toString());
    bare.stop();

    auto f = new Fixture();
    scope(exit) f.stop();
    auto missing = responseJson(f.replay(99), "HTTP/1.1 200 OK",
                                "5820 invalid replay index");
    assert(missing["status"].str == "error"
        && missing["message"].str == "no entry at given index",
        "5820 invalid replay index contract changed: " ~ missing.toString());
    auto malformedReply = f.request("POST", "/api/history/replay",
        `{"index":"zero"}`, () => f.server.replayOwnedPendingForTest() == 1);
    auto malformed = responseJson(malformedReply, "HTTP/1.1 200 OK",
                                  "5820 malformed replay index");
    assert(malformed["status"].str == "error"
        && malformed["message"].str.canFind("missing 'index' integer field"),
        "5820 HTTP index validation changed: " ~ malformed.toString());
}

unittest { // status provider exception, owned timeout and shutdown envelopes
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;

    auto failed = new Fixture();
    scope(exit) failed.stop();
    failed.historyAdapter.setUndoStatusFailureForTest("status boundary sentinel");
    auto exceptionBody = responseJson(failed.status(),
        "HTTP/1.1 500 Internal Server Error", "5820 status provider exception");
    assert(exceptionBody["error"].str == "Failed to retrieve undo status"
        && exceptionBody["message"].str == "status boundary sentinel",
        "5820 status exception envelope changed: " ~ exceptionBody.toString());
    failed.stop();

    auto timed = new Fixture();
    scope(exit) timed.stop();
    timed.server.setUndoStatusBudgetForTest(30.msecs);
    auto timeoutReply = new AsyncReply();
    auto timeoutClient = startRequest(timed.port, "GET", "/api/undo/status", "",
                                      timeoutReply);
    assert(waitUntil(() => timed.server.undoStatusOwnedPendingForTest() == 1),
        "5820 status timeout floor: request did not queue");
    assert(waitUntil(() => atomicLoad(timeoutReply.done)),
        "5820 status owned deadline did not wake the HTTP waiter");
    timeoutClient.join();
    auto timeoutBody = responseJson(timeoutReply,
        "HTTP/1.1 500 Internal Server Error", "5820 status timeout");
    assert(timeoutBody["error"].str == "Failed to retrieve undo status"
        && timeoutBody["message"].str == "timeout waiting for main thread",
        "5820 status timeout envelope changed: " ~ timeoutBody.toString());
    auto statusTrace = timed.server.undoStatusOwnedTraceForTest();
    assert(statusTrace.length == 2
        && statusTrace[0].kind == BridgeResultKind.submitted
        && statusTrace[1].kind == BridgeResultKind.timedOut,
        "5820 status timeout ownership trace changed");
    timed.stop();

    auto stopping = new Fixture();
    scope(exit) stopping.stop();
    auto stoppingReply = new AsyncReply();
    auto stoppingClient = startRequest(stopping.port, "GET", "/api/undo/status", "",
                                       stoppingReply);
    assert(waitUntil(() => stopping.server.undoStatusOwnedPendingForTest() == 1),
        "5820 status shutdown floor: request did not queue");
    stopping.server.stop();
    assert(waitUntil(() => atomicLoad(stoppingReply.done)),
        "5820 status shutdown did not wake the owned waiter");
    stoppingClient.join();
    auto stoppingBody = responseJson(stoppingReply,
        "HTTP/1.1 500 Internal Server Error", "5820 status shutdown");
    assert(stoppingBody["error"].str == "Failed to retrieve undo status"
        && stoppingBody["message"].str == "HTTP server stopping",
        "5820 status shutdown envelope changed: " ~ stoppingBody.toString());
}

unittest { // replay timeout is owned, non-cancelling, and shutdown stays HTTP 200
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;

    auto timed = new Fixture();
    scope(exit) timed.stop();
    timed.record(new EmptyLineCommand(&timed.mesh, timed.view, "probe.query"));
    timed.server.setReplayBudgetForTest(30.msecs);
    auto timeoutReply = new AsyncReply();
    auto timeoutClient = startRequest(timed.port, "POST", "/api/history/replay",
                                      `{"index":0}`, timeoutReply);
    assert(waitUntil(() => timed.server.replayOwnedPendingForTest() == 1),
        "5820 replay timeout floor: request did not queue");
    assert(waitUntil(() => atomicLoad(timeoutReply.done)),
        "5820 replay owned deadline did not wake the HTTP waiter");
    timeoutClient.join();
    auto timeoutBody = responseJson(timeoutReply, "HTTP/1.1 200 OK",
                                    "5820 replay timeout");
    assert(timeoutBody["status"].str == "error"
        && timeoutBody["message"].str == "timeout waiting for main thread",
        "5820 replay timeout envelope changed: " ~ timeoutBody.toString());
    {
        timed.server.tickAll();
    }
    auto replayTrace = timed.server.replayOwnedTraceForTest();
    assert(replayTrace.length == 3
        && replayTrace[0].kind == BridgeResultKind.submitted
        && replayTrace[1].kind == BridgeResultKind.timedOut
        && replayTrace[2].kind == BridgeResultKind.completed,
        "5820 replay timeout must not cancel the already queued service");
    assert(replayTrace[2].result.result == `{"owner":"query-1"}`,
        "5820 late replay query did not stay in its request-owned result");
    assert(!timed.server.commandResultSinkActiveForTest(),
        "5820 late replay query left its scoped result sink installed");
    timed.stop();

    auto stopping = new Fixture();
    scope(exit) stopping.stop();
    stopping.record(new EmptyLineCommand(&stopping.mesh, stopping.view,
                                         "probe.moveSelected"));
    auto stoppingReply = new AsyncReply();
    auto stoppingClient = startRequest(stopping.port, "POST",
        "/api/history/replay", `{"index":0}`, stoppingReply);
    assert(waitUntil(() => stopping.server.replayOwnedPendingForTest() == 1),
        "5820 replay shutdown floor: request did not queue");
    stopping.server.stop();
    assert(waitUntil(() => atomicLoad(stoppingReply.done)),
        "5820 replay shutdown did not wake the owned waiter");
    stoppingClient.join();
    auto stoppingBody = responseJson(stoppingReply, "HTTP/1.1 200 OK",
                                     "5820 replay shutdown");
    assert(stoppingBody["status"].str == "error"
        && stoppingBody["message"].str == "HTTP server stopping",
        "5820 replay shutdown envelope changed: " ~ stoppingBody.toString());
}

unittest { // interactive is the last assignment, including an execution error
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    auto f = new Fixture();
    scope(exit) f.stop();
    f.record(new ToolAttrCarrier(&f.mesh, f.view, 1.25f));
    assert(f.history.undoEntryCommandLine(0).canFind("tool.attr")
        && f.history.undoEntryCommandLine(0).canFind("1.25"),
        "5820 interactive population floor: replayable ToolAttr row missing");

    auto trueSetter = responseJson(
        f.command("/api/script?interactive=true", "probe.unknown"),
        "HTTP/1.1 200 OK", "5820 interactive=true setter error");
    assert(trueSetter["status"].str == "error",
        "5820 setter->error floor: unknown command unexpectedly succeeded");
    auto interactiveReplay = responseJson(f.replay(0), "HTTP/1.1 200 OK",
                                           "5820 inherited interactive replay");
    assert(interactiveReplay["status"].str == "ok"
        && f.tool.interactiveChanges == 1
        && f.tool.scriptedChanges == 0
        && f.tool.evaluations == 1,
        "5820 interactive compatibility: setter -> error -> replay did not "
      ~ "take the production interactive ToolAttr trajectory: response="
      ~ interactiveReplay.toString() ~ ", interactive="
      ~ f.tool.interactiveChanges.to!string ~ ", scripted="
      ~ f.tool.scriptedChanges.to!string ~ ", evaluations="
      ~ f.tool.evaluations.to!string ~ ", line="
      ~ f.history.undoEntryCommandLine(0));

    auto falseSetter = responseJson(
        f.command("/api/script", "probe.stillUnknown"),
        "HTTP/1.1 200 OK", "5820 interactive=false setter error");
    assert(falseSetter["status"].str == "error",
        "5820 interactive=false error floor unexpectedly succeeded");
    auto scriptedReplay = responseJson(f.replay(0), "HTTP/1.1 200 OK",
                                       "5820 inherited scripted replay");
    assert(scriptedReplay["status"].str == "ok"
        && f.tool.interactiveChanges == 1
        && f.tool.scriptedChanges == 1
        && f.tool.evaluations == 2,
        "5820 interactive compatibility: replay reset or remembered success "
      ~ "instead of the last false assignment");
}

unittest { // script-origin refusal is an HTTP error and records nothing
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    auto f = new Fixture();
    scope(exit) f.stop();
    f.record(new EmptyLineCommand(&f.mesh, f.view, "probe.refuse"));
    auto originSetter = responseJson(f.command("/api/command", "probe.query"),
        "HTTP/1.1 200 OK", "5820 script origin setter");
    assert(originSetter["status"].str == "ok",
        "5820 script origin population floor did not set uiOrigin=false");
    const historyBefore = f.history.undoEntriesVisible().length;
    auto refusal = responseJson(f.replay(0), "HTTP/1.1 200 OK",
                                "5820 script replay refusal");
    assert(f.state.refusalApplies == 1,
        "5820 script refusal callback floor: refusing apply was not reached");
    assert(refusal["status"].str == "error"
        && refusal["message"].str.canFind("boundary refusal"),
        "5820 script refusal surface did not remain HTTP status:error: "
      ~ refusal.toString());
    assert(f.history.undoEntriesVisible().length == historyBefore
        && f.state.notices == 0,
        "5820 script refusal recorded history or emitted the UI notice");
}

unittest { // 403 resets only interactive; inherited UI refusal still notices
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    auto f = new Fixture();
    scope(exit) f.stop();
    f.record(new ToolAttrCarrier(&f.mesh, f.view, 2.5f));
    f.record(new EmptyLineCommand(&f.mesh, f.view, "probe.refuse"));

    auto uiSetter = responseJson(
        f.command("/api/command?origin=ui", "probe.query"),
        "HTTP/1.1 200 OK", "5820 UI origin setter");
    assert(uiSetter["status"].str == "ok",
        "5820 UI setter floor did not succeed");
    auto scriptSetter = responseJson(
        f.command("/api/script?interactive=true", "probe.unknown"),
        "HTTP/1.1 200 OK", "5820 UI -> script setter error");
    assert(scriptSetter["status"].str == "error",
        "5820 UI -> script population floor did not reach execution error");

    f.server.setTestMode(false);
    auto forbidden = f.command("/api/command?origin=ui", "probe.query");
    assert(forbidden.wire.startsWith("HTTP/1.1 403 Forbidden\r\n"),
        "5820 403 population floor: origin guard did not refuse outside test mode");
    f.server.setTestMode(true);

    auto attrReplay = responseJson(f.replay(0), "HTTP/1.1 200 OK",
                                   "5820 post-403 ToolAttr replay");
    assert(attrReplay["status"].str == "ok"
        && f.tool.scriptedChanges == 1
        && f.tool.interactiveChanges == 0,
        "5820 403 compatibility: guard must reset only interactive before returning");
    const historyBefore = f.history.undoEntriesVisible().length;
    auto refusal = responseJson(f.replay(1), "HTTP/1.1 200 OK",
                                "5820 post-403 UI refusal replay");
    assert(f.state.refusalApplies == 1,
        "5820 inherited UI refusal callback floor was not reached");
    assert(refusal["status"].str == "ok" && f.state.notices == 1,
        "5820 origin compatibility: UI -> script -> 403 -> replay did not "
      ~ "preserve UI notice/ok policy: " ~ refusal.toString());
    assert(f.history.undoEntriesVisible().length == historyBefore,
        "5820 inherited UI refusal added a history record");
}

unittest { // inherited UI guard defers, then applies exactly at settle
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    auto f = new Fixture();
    scope(exit) f.stop();
    f.record(new EmptyLineCommand(&f.mesh, f.view, "probe.guarded"));
    auto uiSetter = responseJson(
        f.command("/api/command?origin=ui", "probe.query"),
        "HTTP/1.1 200 OK", "5820 guard UI setter");
    assert(uiSetter["status"].str == "ok",
        "5820 guard UI population floor did not set UI origin");
    f.dirty = true;
    const historyBefore = f.history.undoEntriesVisible().length;
    auto deferred = responseJson(f.replay(0), "HTTP/1.1 200 OK",
                                 "5820 guarded UI replay");
    assert(f.state.guardRequests == 1 && f.guard.pending,
        "5820 guarded UI callback floor: production guard did not defer");
    assert(deferred["status"].str == "ok"
        && f.state.guardedApplies == 0
        && f.history.undoEntriesVisible().length == historyBefore,
        "5820 guarded UI replay applied or recorded before settle: "
      ~ deferred.toString());
    f.guard.answerDiscard();
    {
        assert(f.guard.settle(),
            "5820 guarded UI settle did not perform the deferred command");
    }
    assert(!f.guard.pending && f.state.guardedApplies == 1
        && f.history.undoEntriesVisible().length == historyBefore + 1,
        "5820 guarded UI command did not apply and record exactly after settle");
}

unittest { // a missing UI callback deliberately falls back to script policy
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    auto f = new Fixture(false);
    scope(exit) f.stop();
    const historyBefore = f.history.undoEntriesVisible().length;
    auto refusal = responseJson(
        f.command("/api/command?origin=ui", "probe.refuse"),
        "HTTP/1.1 200 OK", "5820 null UI callback fallback");
    assert(f.state.refusalApplies == 1,
        "5820 null UI fallback callback floor: script handler was not reached");
    assert(refusal["status"].str == "error"
        && refusal["message"].str.canFind("boundary refusal")
        && f.state.notices == 0
        && f.history.undoEntriesVisible().length == historyBefore,
        "5820 null UI callback did not use the script refusal contract: "
      ~ refusal.toString());
}

unittest { // scoped query owners, stale clearing, exception unwind and GC brace
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    auto f = new Fixture();
    scope(exit) f.stop();
    f.record(new EmptyLineCommand(&f.mesh, f.view, "probe.query"));
    f.record(new EmptyLineCommand(&f.mesh, f.view, "probe.moveSelected"));
    f.record(new EmptyLineCommand(&f.mesh, f.view, "probe.throw"));

    immutable legacyGcBefore = g_commandGc.commands;
    {
        auto legacy = responseJson(f.command("/api/command", "probe.query"),
            "HTTP/1.1 200 OK", "5820 legacy query owner");
        assert(legacy["status"].str == "ok"
            && legacy["value"]["owner"].str == "query-1",
            "5820 legacy command query lost its value owner: " ~ legacy.toString());
    }
    assert(g_commandGc.commands == legacyGcBefore + 1,
        "5820 GC closing brace: legacy query did not close one port bracket");
    assert(!f.server.commandResultSinkActiveForTest(),
        "5820 legacy query left its scoped result sink installed");

    string priorOwner = "prior-owner";
    f.server.installCommandResultSinkForTest(priorOwner);
    immutable replayGcBefore = g_commandGc.commands;
    {
        auto replay = responseJson(f.replay(0), "HTTP/1.1 200 OK",
                                   "5820 replay query owner");
        assert(replay["status"].str == "ok"
            && replay["line"].str == "probe.query"
            && "value" !in replay,
            "5820 replay query must keep line and omit value: " ~ replay.toString());
    }
    assert(g_commandGc.commands == replayGcBefore + 1,
        "5820 GC closing brace: replay query did not close one port bracket");
    auto queryTrace = f.server.replayOwnedTraceForTest();
    assert(queryTrace[$ - 1].kind == BridgeResultKind.completed
        && queryTrace[$ - 1].result.result == `{"owner":"query-2"}`,
        "5820 replay query result did not land in its distinguishable owner");
    assert(f.server.commandResultSinkActiveForTest(),
        "5820 sink closing brace: replay did not restore the previous sink");
    f.server.setCmdResult(`{"owner":"restored-after-query"}`);
    assert(priorOwner == `{"owner":"restored-after-query"}`,
        "5820 sink restoration after query did not restore the prior owner");
    f.server.clearCommandResultSinkForTest();

    immutable writeGcBefore = g_commandGc.commands;
    {
        auto write = responseJson(f.replay(1), "HTTP/1.1 200 OK",
                                  "5820 replay write after query");
        assert(write["status"].str == "ok" && "value" !in write,
            "5820 replay write exposed a stale query value: " ~ write.toString());
    }
    assert(g_commandGc.commands == writeGcBefore + 1,
        "5820 GC closing brace: replay write did not close one port bracket");
    auto writeTrace = f.server.replayOwnedTraceForTest();
    assert(writeTrace[$ - 1].result.result.length == 0,
        "5820 stale query leaked from query owner into the following write");
    assert(!f.server.commandResultSinkActiveForTest(),
        "5820 replay write left the scoped result sink installed");

    priorOwner = "prior-before-exception";
    f.server.installCommandResultSinkForTest(priorOwner);
    immutable exceptionGcBefore = g_commandGc.commands;
    {
        auto failure = responseJson(f.replay(2), "HTTP/1.1 200 OK",
                                    "5820 replay exception owner");
        assert(failure["status"].str == "error"
            && failure["message"].str == "boundary throw sentinel"
            && f.state.throwingApplies == 1,
            "5820 exception path did not reach/catch the real command: "
          ~ failure.toString());
    }
    assert(g_commandGc.commands == exceptionGcBefore + 1,
        "5820 GC exception brace: scope(exit) end did not publish after throw");
    assert(f.server.commandResultSinkActiveForTest(),
        "5820 sink exception brace: previous sink was not restored after throw");
    f.server.setCmdResult(`{"owner":"restored-after-throw"}`);
    assert(priorOwner == `{"owner":"restored-after-throw"}`,
        "5820 sink restoration after exception did not restore the prior owner");
    f.server.clearCommandResultSinkForTest();
}

unittest { // replay traverses the adapter-owned automation hooks
    const oldTestMode = g_testMode;
    scope(exit) g_testMode = oldTestMode;
    g_testMode = true;
    resetGlobalProbes();
    auto f = new Fixture();
    scope(exit) f.stop();
    f.record(new EmptyLineCommand(&f.mesh, f.view, "scene.reset"));
    const pipeBefore = f.pipeGizmo.preparedCancelCountForTest();
    const historyBefore = f.history.undoEntriesVisible().length;
    immutable gcBefore = g_commandGc.commands;
    {
        auto reset = responseJson(f.replay(0), "HTTP/1.1 200 OK",
                                  "5820 replay automation policy");
        assert(reset["status"].str == "ok" && f.state.guardedApplies == 1,
            "5820 automation callback floor: reset command did not apply: "
          ~ reset.toString());
    }
    assert(g_commandGc.commands == gcBefore + 1,
        "5820 automation GC brace: shared execution port did not close");
    assert(resetUiCalls == 1
        && f.pipeGizmo.preparedCancelCountForTest() == pipeBefore + 1
        && clearTraceCalls == 1 && parkMouseCalls == 1 && closePieCalls == 1
        && clearInputKeysCalls == 1,
        "5820 production policy: replay bypassed an adapter automation hook");
    assert(f.history.undoEntriesVisible().length == historyBefore + 1,
        "5820 automation replay did not record its successful apply");
}
