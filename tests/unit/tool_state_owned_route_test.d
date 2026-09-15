module tests.unit.tool_state_owned_route_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import command_history : CommandHistory;
import commands.layer.xform_edit : LayerXformEdit;
import commands.mesh.vertex_edit : MeshVertexEdit;
import document : Layer;
import editmode : EditMode;
import http_providers : ToolStateHttpAdapter;
import http_server : BridgeResultKind, HttpServer;
import math : Vec3;
import mesh : makeCube;
import mesh_gpu : GpuMesh;
import operator : VectorStack;
import pipe_gizmo_host : PipeGizmoHost;
import prepared_record_context : PreparedRecordContext, PreparedToolDoorClient;
import prepared_tool_transition : prepareArm;
import record_observer_hub : RecordObserverHub;
import registry : PreparedPipeAttrs, ToolFactory;
import seltype : SelType, SelTypeOrder, currentSelType;
import std.algorithm : canFind, count;
import std.file : readText;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel,
    TcpSocket;
import std.string : indexOf;
import tool : Tool;
import toolpipe.packets : ActionCenterPacket, SubjectPacket;
import toolpipe.pipeline : Pipeline, g_pipeCtx;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.constrain : ConstrainStage;
import toolpipe.stages.falloff : FalloffStage;
import tools.transform.xfrm_transform : XfrmTransformTool;
import tests.unit.census_symbols : blankNonCode;
import view : View;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private final class AsyncHttpReply {
    shared bool done;
    string wire;
    string failure;
}

private size_t threadIdentity() nothrow {
    try return cast(size_t) cast(void*) Thread.getThis();
    catch (Throwable) return 0;
}

private ushort freePort() {
    auto probe = new TcpSocket();
    scope(exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private Thread startHttpGet(ushort port, string path, AsyncHttpReply reply) {
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
            if (socket is null)
                throw new Exception("server did not accept a connection");
            scope(exit) socket.close();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                             12.seconds);
            socket.send("GET " ~ path ~ " HTTP/1.1\r\n"
                      ~ "Host: 127.0.0.1\r\nConnection: close\r\n\r\n");
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

private bool waitUntil(bool delegate() ready, Duration budget) {
    immutable deadline = MonoTime.currTime + budget;
    while (!ready()) {
        if (MonoTime.currTime >= deadline) return false;
        Thread.sleep(1.msecs);
    }
    return true;
}

private void tickUntilDone(HttpServer server, AsyncHttpReply reply) {
    immutable deadline = MonoTime.currTime + 2.seconds;
    while (!atomicLoad(reply.done)) {
        server.tickAll();
        assert(MonoTime.currTime < deadline,
            "5940 real tool-state request did not finish while tickAll ran");
        Thread.sleep(1.msecs);
    }
}

private string responseBody(string wire) {
    immutable split = wire.indexOf("\r\n\r\n");
    assert(split >= 0, "5940 response lacks a header/body boundary: " ~ wire);
    return wire[split + 4 .. $];
}

private void startReady(HttpServer server) {
    server.markProvidersWired();
    server.tickAll();
    server.start();
}

private string bodyAt(string code, string marker) {
    immutable at = code.indexOf(marker);
    assert(at >= 0, "5940 census missing marker " ~ marker);
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "5940 census marker has no body " ~ marker);
    immutable begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "5940 census body is unterminated " ~ marker);
    return null;
}

private final class ToolRig {
    Layer target;
    GpuMesh gpu;
    EditMode mode = EditMode.Vertices;
    SelTypeOrder order;
    XfrmTransformTool tool;
    Tool active;
    ToolStateHttpAdapter adapter;
    SubjectPacket subject;
    ActionCenterPacket action;
    VectorStack vts;
    Vec3 expected = Vec3(4.25f, 1.5f, -2.0f);

    this() {
        target = new Layer;
        target.meshRef() = makeCube();
        target.xform.pos = Vec3(4.0f, 1.5f, -2.0f);
        target.xform.pivot = Vec3(0.25f, 0, 0);
        order.touch(SelType.Item);
        tool = new XfrmTransformTool(
            () => &target.meshRef(), &gpu, &mode,
            () => currentSelType(order),
            (ref Layer[] targets) { targets = [target]; });
        tool.flagT = true;
        tool.flagR = false;
        tool.flagS = false;
        active = tool;
        adapter = new ToolStateHttpAdapter(() => active);
        subject.mesh = &target.meshRef();
        subject.editMode = mode;
        subject.selType = SelType.Item;
        action.center = expected;
        vts.put(&subject);
        vts.put(&action);
    }

    void activateAndUpdate() {
        tool.activate();
        tool.update(vts);
    }
}

private JSONValue state(string body) { return parseJSON(body); }

// S: production construction and frame order are separate from request-level
// behavior. The app-order mutation has no HTTP cell that can observe it.
unittest {
    auto app = blankNonCode(readText(buildPath(repoRoot, "source", "app.d")));
    auto mainBody = bodyAt(app, "void main(string[] args)");
    immutable tick = mainBody.indexOf("httpServer.tickAll()");
    immutable stall = mainBody.indexOf("preToolTickStall.waitAtSeam()");
    immutable update = mainBody.indexOf("activeTool.update(vts)");
    assert(tick >= 0 && stall > tick && update > stall,
        "5940 S source order: tickAll must precede the stall and activeTool.update");
    assert(mainBody.count("activeTool.update(vts)") == 1,
        "5940 S population floor: main must contain exactly one active-tool update");

    auto registration = blankNonCode(readText(
        buildPath(repoRoot, "source", "registration.d")));
    auto factories = bodyAt(registration,
        "private void registerTransformTools(EditorApp app)");
    assert(factories.count("new XfrmTransformTool(") == 4,
        "5940 S production constructor floor: expected four Xfrm factories");
    assert(factories.count("() => currentSelType(selTypeOrder)") >= 4,
        "5940 S production constructor wiring lost the live subject source");
}

// K: constructor subject seeding and first update are different boundaries.
unittest {
    auto rig = new ToolRig;
    assert(rig.expected != Vec3(0, 0, 0)
        && rig.target.xform.pos + rig.target.xform.pivot == rig.expected,
        "5940 K population floor: item world pivot must be non-zero and independent");

    auto before = state(rig.adapter.read());
    assert(before["subject"].str == "item",
        "5940 K constructor must seed the live item subject");
    assert(before["pivot"].array == [JSONValue(0.0), JSONValue(0.0), JSONValue(0.0)],
        "5940 K(a) phase discriminator: the zero constructor pivot must keep "
        ~ "pre-update and post-update states distinct; backlog 6111 must update "
        ~ "K(a) and L1 together");

    rig.activateAndUpdate();
    auto after = state(rig.adapter.read());
    assert(after["subject"].str == "item"
        && after["pivot"].array == [JSONValue(4.25), JSONValue(1.5), JSONValue(-2.0)],
        "5940 K first active update did not publish the item pivot and subject");
}

// U3: an unwired route keeps the old immediate empty-object contract.
unittest {
    immutable port = freePort();
    auto server = new HttpServer(port);
    startReady(server);
    auto reply = new AsyncHttpReply;
    auto client = startHttpGet(port, "/api/tool/state", reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => atomicLoad(reply.done), 2.seconds),
        "5940 U3 unwired route did not answer immediately");
    client.join();
    assert(reply.failure.length == 0
        && reply.wire.canFind("HTTP/1.1 200 OK")
        && responseBody(reply.wire) == "{}",
        "5940 U3 unwired route changed its exact 200 {} response");
    assert(server.toolStateOwnedTraceForTest().length == 0
        && server.toolStateOwnedPendingForTest() == 0,
        "5940 U3 unwired route must not touch the owned bridge");
}

// U1: the production adapter callback runs on the unconditional tick identity.
unittest {
    auto rig = new ToolRig;
    rig.activateAndUpdate();
    immutable expected = rig.tool.toolStateJson().toString();
    immutable port = freePort();
    auto server = new HttpServer(port);
    rig.adapter.wire(server);
    startReady(server);
    immutable tickThread = threadIdentity();
    assert(tickThread != 0, "5940 U1 tick-thread identity floor is zero");
    auto reply = new AsyncHttpReply;
    auto client = startHttpGet(port, "/api/tool/state", reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1
                           || atomicLoad(reply.done), 2.seconds),
        "5940 U1 request reached neither owned queue nor reply");
    if (server.toolStateOwnedPendingForTest() == 1) server.tickAll();
    assert(rig.adapter.providerCallsForTest() == 1,
        "5940 U1 provider population floor: production adapter must run once");
    assert(rig.adapter.providerThreadForTest() == tickThread,
        "5940 thread identity: production tool-state adapter callback did not run on the tick thread");
    assert(waitUntil(() => atomicLoad(reply.done), 2.seconds),
        "5940 U1 reply did not finish after service");
    client.join();
    assert(reply.failure.length == 0 && reply.wire.canFind("HTTP/1.1 200 OK")
        && reply.wire.canFind("Content-Type: application/json")
        && responseBody(reply.wire) == expected,
        "5940 U1 success response differs from the adapter payload");
    auto trace = server.toolStateOwnedTraceForTest();
    assert(trace.length == 2
        && trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.completed
        && trace[1].result.result == expected,
        "5940 U1 owned trace must be submitted then completed with exact body");
}

// U2: a wired adapter with a live null slot differs from an unwired route.
unittest {
    Tool active;
    auto adapter = new ToolStateHttpAdapter(() => active);
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    startReady(server);
    immutable tickThread = threadIdentity();
    auto reply = new AsyncHttpReply;
    auto client = startHttpGet(port, "/api/tool/state", reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U2 wired null request did not queue");
    tickUntilDone(server, reply);
    client.join();
    assert(adapter.providerCallsForTest() == 1
        && adapter.providerThreadForTest() == tickThread,
        "5940 U2 wired null slot must be read once on the tick thread");
    assert(responseBody(reply.wire) == "{}",
        "5940 U2 live null slot changed its exact body");
    auto trace = server.toolStateOwnedTraceForTest();
    assert(trace.length == 2 && trace[1].kind == BridgeResultKind.completed,
        "5940 U2 wired null slot must complete through the bridge");
}

private final class ThrowingStateTool : Tool {
    string message;
    this(string message) { this.message = message; }
    override JSONValue toolStateJson() const {
        throw new Exception(message);
    }
}

private string driveError(string message) {
    Tool active = new ThrowingStateTool(message);
    auto adapter = new ToolStateHttpAdapter(() => active);
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    startReady(server);
    auto reply = new AsyncHttpReply;
    auto client = startHttpGet(port, "/api/tool/state", reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U4 throwing request did not queue");
    tickUntilDone(server, reply);
    client.join();
    assert(adapter.providerCallsForTest() == 1,
        "5940 U4 throwing adapter must be called exactly once");
    return reply.wire;
}

// U4: exception state is independent of message emptiness.
unittest {
    auto escaped = driveError("tool \"state\" \\ back\nline");
    assert(escaped.canFind("HTTP/1.1 500 Internal Server Error")
        && responseBody(escaped) ==
           `{"error": "Failed to retrieve tool state", "message": "tool \"state\" \\ back\nline"}`,
        "5940 U4 exception escaping changed: " ~ escaped);
    auto empty = driveError("");
    assert(empty.canFind("HTTP/1.1 500 Internal Server Error")
        && responseBody(empty) ==
           `{"error": "Failed to retrieve tool state", "message": ""}`,
        "5940 U4 empty exception message must remain a 500");
}

// U5: submit captures no tool state and adds no readiness barrier.
unittest {
    auto rig = new ToolRig;
    immutable port = freePort();
    auto server = new HttpServer(port);
    rig.adapter.wire(server);
    startReady(server);
    scope(exit) if (server.running) server.stop();

    auto first = new AsyncHttpReply;
    auto firstClient = startHttpGet(port, "/api/tool/state", first);
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U5 GET#1 did not queue before activation");
    Thread.sleep(300.msecs);
    assert(!atomicLoad(first.done) && rig.adapter.providerCallsForTest() == 0,
        "5940 U5 an early request answered without its ordinary tickAll service");
    server.tickAll();
    assert(waitUntil(() => atomicLoad(first.done), 2.seconds),
        "5940 U5 GET#1 did not finish after tickAll");
    firstClient.join();
    auto firstState = state(responseBody(first.wire));
    assert(firstState["tool"].str == "xfrm"
        && firstState["subject"].str == "item",
        "5940 U5 GET#1 must read the inactive resident tool at service time");

    auto second = new AsyncHttpReply;
    auto secondClient = startHttpGet(port, "/api/tool/state", second);
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U5 GET#2 did not queue");
    rig.activateAndUpdate();
    server.tickAll();
    assert(waitUntil(() => atomicLoad(second.done), 2.seconds),
        "5940 U5 GET#2 did not finish after update and service");
    secondClient.join();
    auto secondState = state(responseBody(second.wire));
    assert(secondState["pivot"].array ==
           [JSONValue(4.25), JSONValue(1.5), JSONValue(-2.0)],
        "5940 U5 GET#2 must read the update made after submit");
    auto trace = server.toolStateOwnedTraceForTest();
    assert(trace.length == 4 && trace[3].kind == BridgeResultKind.completed
        && trace[3].result.result == responseBody(second.wire),
        "5940 U5 two calls need four owned events and the second exact body");
}

private final class RefusingPreparedStateTool : Tool, PreparedToolDoorClient {
    size_t* activationCalls;

    this(size_t* activationCalls) { this.activationCalls = activationCalls; }

    override bool prepareDoorDeactivate(PreparedRecordContext context,
            Layer, ulong, ulong) {
        return context !is null && context.markNoHistoryInstall();
    }

    override bool prepareDoorActivate(PreparedRecordContext,
            Layer, ulong, ulong) {
        ++*activationCalls;
        return false;
    }

    override JSONValue toolStateJson() const {
        return parseJSON(`{"tool":"refused.candidate"}`);
    }
}

// U6: a failed prepared switch never publishes its candidate into the live slot.
unittest {
    auto savedPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedPipe;
    g_pipeCtx = null;

    auto layer = new Layer;
    layer.meshRef() = makeCube();
    GpuMesh gpu;
    EditMode mode = EditMode.Polygons;
    auto view = new View(0, 0, 800, 600);
    auto history = new CommandHistory;
    auto outgoing = new XfrmTransformTool(
        () => &layer.meshRef(), &gpu, &mode, () => SelType.Item,
        (ref Layer[] targets) { targets = [layer]; });
    outgoing.flagR = true;
    outgoing.setUndoBindings(history,
        () => new MeshVertexEdit(&layer.meshRef(), view, mode));
    outgoing.setItemUndoFactory(
        () => new LayerXformEdit(&layer.meshRef(), view, mode));
    outgoing.activate();
    VectorStack pose;
    SubjectPacket subject;
    subject.mesh = &layer.meshRef();
    subject.editMode = mode;
    subject.selType = SelType.Item;
    pose.put(&subject);
    outgoing.update(pose);
    outgoing.openLiveSessionForTest();
    layer.xform.rot = Vec3(0, 40, 0);
    assert(outgoing.publicEditIsOpen() && layer.xform.rot != Vec3(0, 0, 0),
        "5940 U6 refusal stand must begin with a live outgoing item edit");

    Tool active = outgoing;
    string activeId = "rotate";
    Pipeline pipeline;
    pipeline.add(new ActionCenterStage(() => &layer.meshRef(), &mode));
    pipeline.add(new AxisStage);
    pipeline.add(new ConstrainStage);
    pipeline.add(new FalloffStage(() => &layer.meshRef(), &mode));
    PreparedPipeAttrs attrs;
    auto host = new PipeGizmoHost;
    auto observers = new RecordObserverHub;
    JSONValue args = JSONValue.emptyObject;
    size_t activationCalls;
    ToolFactory refusingFactory = () =>
        new RefusingPreparedStateTool(&activationCalls);
    string refusal;
    try {
        auto ignored = prepareArm(refusingFactory, "refused.candidate",
            outgoing, history, observers, layer, pipeline, attrs, host, args,
            pose, 17, 23, &layer.meshRef(), view, mode, activeId,
            (string id) {}, () {});
    } catch (Exception e) {
        refusal = e.msg;
    }
    assert(activationCalls == 1,
        "5940 U6 refusing candidate activation was not reached");
    assert(refusal == "prepared candidate activation refused for "
            ~ "'refused.candidate' (lifecycleReplay=false)",
        "5940 U6 candidate refusal changed: " ~ refusal);
    assert(active is outgoing && activeId == "rotate"
        && outgoing.publicEditIsOpen(),
        "5940 U6 prepare refusal replaced or closed the outgoing live tool");
}

private final class FixedStateTool : Tool {
    string payload;
    this(string payload) { this.payload = payload; }
    override JSONValue toolStateJson() const { return parseJSON(payload); }
}

private final class BlockingStateTool : Tool {
    shared bool entered;
    shared bool release;
    override JSONValue toolStateJson() const {
        atomicStore((cast(BlockingStateTool)this).entered, true);
        while (!atomicLoad((cast(BlockingStateTool)this).release))
            Thread.sleep(1.msecs);
        return parseJSON(`{"tool":"late-a"}`);
    }
}

// U9: a late completion retains its own state and cannot overwrite request B.
unittest {
    auto a = new BlockingStateTool;
    Tool active = a;
    auto adapter = new ToolStateHttpAdapter(() => active);
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setToolStateBudgetForTest(150.msecs);
    adapter.wire(server);
    startReady(server);
    Thread serviceThread;
    scope(exit) {
        atomicStore(a.release, true);
        if (serviceThread !is null && serviceThread.isRunning) serviceThread.join();
        if (server.running) server.stop();
    }

    auto first = new AsyncHttpReply;
    auto firstClient = startHttpGet(port, "/api/tool/state", first);
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U9 request A did not queue");
    serviceThread = new Thread({ server.tickAll(); });
    serviceThread.start();
    assert(waitUntil(() => atomicLoad(a.entered), 2.seconds),
        "5940 U9 blocking provider A was not entered");
    assert(waitUntil(() => atomicLoad(first.done), 2.seconds),
        "5940 U9 request A did not time out while service remained live");
    firstClient.join();
    assert(responseBody(first.wire) ==
           `{"error": "Failed to retrieve tool state", "message": "timeout waiting for main thread"}`,
        "5940 U9 request A changed its timeout envelope");

    server.setToolStateBudgetForTest(5.seconds);
    active = new FixedStateTool(`{"tool":"b"}`);
    auto second = new AsyncHttpReply;
    auto secondClient = startHttpGet(port, "/api/tool/state", second);
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U9 request B did not queue behind the live A service");
    atomicStore(a.release, true);
    serviceThread.join();
    tickUntilDone(server, second);
    secondClient.join();
    assert(responseBody(second.wire) == `{"tool":"b"}`,
        "5940 U9 late A completion changed request B's body");
    auto trace = server.toolStateOwnedTraceForTest();
    assert(trace.length == 5
        && trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.timedOut
        && trace[2].kind == BridgeResultKind.submitted
        && trace[3].kind == BridgeResultKind.completed
        && trace[4].kind == BridgeResultKind.completed,
        "5940 U9 owned-event population/order changed");
    assert(trace[1].resultIdentity != trace[3].resultIdentity
        && trace[1].resultIdentity != trace[4].resultIdentity
        && trace[3].resultIdentity != trace[4].resultIdentity,
        "5940 U9 timeout, late A and B need distinct result identities");
}

// U10: provider presence is re-read by the service, not captured at submit.
unittest {
    Tool active = new FixedStateTool(`{"tool":"gone"}`);
    auto adapter = new ToolStateHttpAdapter(() => active);
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    startReady(server);
    auto reply = new AsyncHttpReply;
    auto client = startHttpGet(port, "/api/tool/state", reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U10 request did not queue");
    server.setToolStateDataProvider(null);
    tickUntilDone(server, reply);
    client.join();
    assert(responseBody(reply.wire) == "{}"
        && adapter.providerCallsForTest() == 0,
        "5940 U10 disappearing provider must produce 200 {} at service time");
    auto trace = server.toolStateOwnedTraceForTest();
    assert(trace.length == 2 && trace[1].kind == BridgeResultKind.completed,
        "5940 U10 disappearing provider must still complete its owned call");
}

// U8: stopping is a separate synthetic outcome and never calls the provider.
unittest {
    Tool active = new FixedStateTool(`{"tool":"must-not-run"}`);
    auto adapter = new ToolStateHttpAdapter(() => active);
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    startReady(server);
    auto reply = new AsyncHttpReply;
    immutable started = MonoTime.currTime;
    auto client = startHttpGet(port, "/api/tool/state", reply);
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U8 request did not queue before stop");
    auto stopper = new Thread({ server.stop(); });
    stopper.start();
    assert(waitUntil(() => atomicLoad(reply.done), 2.seconds),
        "5940 U8 stopping did not wake the HTTP response within two seconds");
    client.join();
    stopper.join();
    assert(MonoTime.currTime - started <= 2.seconds,
        "5940 U8 stopping response exceeded its two-second witness budget");
    assert(responseBody(reply.wire) ==
           `{"error": "Failed to retrieve tool state", "message": "HTTP server stopping"}`,
        "5940 U8 stopping must use its separate exact envelope");
    assert(adapter.providerCallsForTest() == 0,
        "5940 U8 stopping must not enter the provider");
    auto trace = server.toolStateOwnedTraceForTest();
    assert(trace.length == 2
        && trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.stopping,
        "5940 U8 trace must be submitted then stopping");
}

// U11: construction order is relative and never depends on numeric indices.
unittest {
    auto server = new HttpServer(freePort());
    immutable toolState = server.toolStateBridgeTickIndexForTest();
    immutable command = server.commandBridgeTickIndexForTest();
    assert(toolState != size_t.max && command != size_t.max,
        "5940 U11 construction-order population floor: both bridges must exist");
    assert(toolState < command,
        "5940 U11 construction order: tool-state bridge must precede command bridge");
}

// U7: production budget is five seconds from submit and a wake cannot renew it.
unittest {
    Tool active = new FixedStateTool(`{"tool":"must-not-run"}`);
    auto adapter = new ToolStateHttpAdapter(() => active);
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    startReady(server);
    auto reply = new AsyncHttpReply;
    immutable started = MonoTime.currTime;
    auto client = startHttpGet(port, "/api/tool/state", reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.toolStateOwnedPendingForTest() == 1, 2.seconds),
        "5940 U7 request did not reach the owned queue");
    Thread.sleep(4.seconds);
    server.wakeToolStateOwnedWaiterForTest();
    assert(waitUntil(() => atomicLoad(reply.done), 4500.msecs),
        "5940 U7 production timeout did not finish by 8.5 seconds");
    client.join();
    immutable elapsed = MonoTime.currTime - started;
    assert(elapsed >= 5.seconds,
        "5940 U7 five-second production budget shortened");
    assert(elapsed < 8500.msecs,
        "5940 U7 wake restarted the submit-time deadline");
    assert(responseBody(reply.wire) ==
           `{"error": "Failed to retrieve tool state", "message": "timeout waiting for main thread"}`
        && adapter.providerCallsForTest() == 0,
        "5940 U7 timeout envelope/provider floor changed");
    auto trace = server.toolStateOwnedTraceForTest();
    assert(trace.length == 2
        && trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.timedOut
        && trace[0].requestIdentity == trace[1].requestIdentity,
        "5940 U7 timeout must retain one request identity");
}
