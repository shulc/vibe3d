module tests.unit.history_http_adapter_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import command : CmdFlags, Command;
import command_history : CommandHistory, HistoryEntry, HistoryFlags;
import edit_session : EditSession;
import editmode : EditMode;
import http_server : BridgeResultKind, HttpServer;
import http_providers : HistoryHttpAdapter;
import mesh : Mesh;
import params : Param;
import step_trace : StepTrace;
import std.algorithm : canFind, count;
import std.conv : to;
import std.file : readText;
import std.json : JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.socket : InternetAddress, Socket, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.string : indexOf, startsWith;
import tool : Tool;
import view : View;

private final class RowCommand : Command {
    private string wireName_;
    private string label_;
    private string value_;
    private CmdFlags flags_;
    private bool operationInverse_;
    private string inverseFailure_;

    this(string wireName, string label, string value, CmdFlags flags,
         bool operationInverse, string inverseFailure = "") {
        static Mesh mesh;
        static View view;
        super(&mesh, view, EditMode.Vertices);
        wireName_ = wireName;
        label_ = label;
        value_ = value;
        flags_ = flags;
        operationInverse_ = operationInverse;
        inverseFailure_ = inverseFailure;
    }

    override string name() const { return wireName_; }
    override string label() const { return label_; }
    override CmdFlags cmdFlags() const { return flags_; }
    override bool isOperationInverse() const {
        if (inverseFailure_.length) throw new Exception(inverseFailure_);
        return operationInverse_;
    }
    override Param[] params() {
        return [Param.string_("value", "Value", &value_, "")];
    }
    protected override bool applyImpl() { return true; }
}

private void record(CommandHistory history, RowCommand command,
                    bool lifecycle = false) {
    assert(command.apply(), "history adapter setup command must apply");
    if (lifecycle) history.recordToolLifecycle(command);
    else history.record(command);
}

private void recordRefire(CommandHistory history, RowCommand command) {
    assert(command.apply(), "history adapter refire setup command must apply");
    const runId = history.nextRun();
    history.bumpTweakGeneration();
    history.replaceInSessionTail(command, runId);
    // RowCommand deliberately has no run-merge interface. Consolidation closes
    // the run while preserving the tagged row used by this serialization test.
    history.consolidate(runId);
}

private void addRows(CommandHistory history, string prefix, bool redoGroup) {
    const modelFlags = redoGroup
        ? CmdFlags.Model | CmdFlags.SideEffect
        : CmdFlags.Model | CmdFlags.Quiet;
    const uiFlags = redoGroup
        ? CmdFlags.UiState | CmdFlags.Quiet
        : CmdFlags.UiState | CmdFlags.SideEffect;
    const lifecycleFlags = redoGroup
        ? CmdFlags.ToolLifecycle | CmdFlags.UndoForce | CmdFlags.Quiet
        : CmdFlags.ToolLifecycle | CmdFlags.UndoForce;
    const refireFlags = redoGroup
        ? CmdFlags.Model | CmdFlags.SideEffect
        : CmdFlags.Model | CmdFlags.UndoBoundary;

    record(history, new RowCommand(prefix ~ ".model", prefix ~ " Model",
        prefix ~ "-model-arg", modelFlags, !redoGroup));
    record(history, new RowCommand(prefix ~ ".ui", prefix ~ " UI",
        prefix ~ "-ui-arg", uiFlags, redoGroup));
    record(history, new RowCommand(prefix ~ ".lifecycle",
        prefix ~ " Lifecycle", prefix ~ "-lifecycle-arg", lifecycleFlags,
        !redoGroup), true);
    recordRefire(history, new RowCommand(prefix ~ ".refire",
        prefix ~ " Refire", prefix ~ "-refire-arg", refireFlags,
        redoGroup));
}

private struct ExpectedRow {
    string label;
    string args;
    string command;
    long flags;
    bool ui;
    bool inSession;
    bool refire;
    long runId;
    long tweakGen;
    bool opInverse;
}

private ExpectedRow expected(ref const(HistoryEntry) entry) {
    return ExpectedRow(
        entry.label,
        entry.args,
        entry.commandName,
        cast(long)entry.flags,
        (entry.flags & HistoryFlags.UiUndo) != 0,
        (entry.flags & HistoryFlags.InSession) != 0,
        (entry.flags & HistoryFlags.Refire) != 0,
        cast(long)entry.runId,
        cast(long)entry.tweakGeneration,
        entry.cmd !is null && entry.cmd.isOperationInverse());
}

private ExpectedRow[] expectedRows(const(HistoryEntry)[] entries) {
    ExpectedRow[] result;
    foreach (ref entry; entries) result ~= expected(entry);
    return result;
}

private void assertRow(JSONValue actual, ExpectedRow wanted,
                       string side, size_t index) {
    const where = "history HTTP adapter " ~ side ~ "[" ~ index.to!string ~ "]";
    assert(actual["label"].str == wanted.label,
        where ~ ".label expected '" ~ wanted.label ~ "', got '"
        ~ actual["label"].str ~ "'");
    assert(actual["args"].str == wanted.args,
        where ~ ".args expected '" ~ wanted.args ~ "', got '"
        ~ actual["args"].str ~ "'");
    assert(actual["command"].str == wanted.command,
        where ~ ".command expected '" ~ wanted.command ~ "', got '"
        ~ actual["command"].str ~ "'");
    assert(actual["flags"].integer == wanted.flags,
        where ~ ".flags expected " ~ wanted.flags.to!string ~ ", got "
        ~ actual["flags"].integer.to!string);
    assert(actual["ui"].boolean == wanted.ui, where ~ ".ui changed");
    assert(actual["inSession"].boolean == wanted.inSession,
        where ~ ".inSession changed");
    assert(actual["refire"].boolean == wanted.refire,
        where ~ ".refire changed");
    assert(actual["runId"].integer == wanted.runId,
        where ~ ".runId expected " ~ wanted.runId.to!string ~ ", got "
        ~ actual["runId"].integer.to!string);
    assert(actual["tweakGen"].integer == wanted.tweakGen,
        where ~ ".tweakGen expected " ~ wanted.tweakGen.to!string ~ ", got "
        ~ actual["tweakGen"].integer.to!string);
    assert(actual["opInverse"].boolean == wanted.opInverse,
        where ~ ".opInverse changed");
}

unittest { // both non-empty stacks use the same complete row encoder
    auto history = new CommandHistory();
    addRows(history, "undo", false);
    addRows(history, "redo", true);

    foreach (_; 0 .. 4)
        assert(history.undo(), "history adapter setup undo must succeed");

    // Population floors precede every per-row comparison. Four rows on each
    // side cover Model, UI, lifecycle and refire records without an empty-loop
    // green.
    assert(history.undoEntriesVisible().length == 4,
        "history HTTP adapter source population floor: expected 4 undo rows");
    assert(history.redoEntriesVisible().length == 4,
        "history HTTP adapter source population floor: expected 4 redo rows");
    auto wantedUndo = expectedRows(history.undoEntriesVisible());
    auto wantedRedo = expectedRows(history.redoEntriesVisible());

    foreach (i; 0 .. wantedUndo.length) {
        assert(wantedUndo[i].label != wantedRedo[i].label
            && wantedUndo[i].flags != wantedRedo[i].flags,
            "history adapter stand must distinguish undo and redo row "
            ~ i.to!string);
    }
    foreach (i; [0, 1, 3]) {
        assert(wantedUndo[i].args != wantedRedo[i].args,
            "history adapter stand must distinguish undo and redo args at row "
            ~ i.to!string);
    }
    assert(wantedUndo[2].args.length == 0 && wantedRedo[2].args.length == 0,
        "history adapter lifecycle records must preserve their empty args");
    assert(wantedUndo[3].inSession && wantedUndo[3].refire
        && wantedUndo[1].ui,
        "history adapter stand must exercise true inSession/refire/ui flags");
    assert(wantedUndo[3].runId != wantedRedo[3].runId
        && wantedUndo[3].tweakGen != wantedRedo[3].tweakGen,
        "history adapter stand must distinguish undo and redo refire identity");

    Tool active;
    auto session = new EditSession(() => active, history, () {});
    auto adapter = new HistoryHttpAdapter(history, session, null);
    auto payload = parseJSON(adapter.historyJson());
    auto actualUndo = payload["undo"].array;
    auto actualRedo = payload["redo"].array;

    assert(actualUndo.length == 4,
        "history HTTP adapter JSON population floor: expected 4 undo rows, got "
        ~ actualUndo.length.to!string);
    assert(actualRedo.length == 4,
        "history HTTP adapter JSON population floor: expected 4 redo rows, got "
        ~ actualRedo.length.to!string);

    // These two explicit checks name the high-risk refactor failure before the
    // generic field walk: redo must not reuse the undo source or its flags.
    assert(actualRedo[0]["label"].str == wantedRedo[0].label,
        "history HTTP adapter redo source: expected '" ~ wantedRedo[0].label
        ~ "', got '" ~ actualRedo[0]["label"].str
        ~ "' (redo serialized undo rows)");
    assert(actualRedo[0]["flags"].integer == wantedRedo[0].flags,
        "history HTTP adapter redo flags: expected "
        ~ wantedRedo[0].flags.to!string ~ ", got "
        ~ actualRedo[0]["flags"].integer.to!string);

    foreach (i, row; actualUndo) assertRow(row, wantedUndo[i], "undo", i);
    foreach (i, row; actualRedo) assertRow(row, wantedRedo[i], "redo", i);
}

unittest { // nullable, armed and disarmed trace behavior is preserved
    auto history = new CommandHistory();
    Tool active;
    auto session = new EditSession(() => active, history, () {});

    auto absent = new HistoryHttpAdapter(history, session, null);
    assert(parseJSON(absent.traceJson()).array.length == 0,
        "history HTTP adapter null trace must serialize as []");
    absent.armTrace();
    absent.disarmTrace();

    auto trace = new StepTrace();
    auto present = new HistoryHttpAdapter(history, session, trace);
    assert(!trace.armed() && parseJSON(present.traceJson()).array.length == 0,
        "history HTTP adapter trace must start disarmed and empty");
    present.armTrace();
    assert(trace.armed(), "history HTTP adapter trace reset must arm capture");
    trace.append(`{"seq":17,"command":"test.trace"}`);
    auto captured = parseJSON(present.traceJson()).array;
    assert(captured.length == 1,
        "history HTTP adapter armed trace population floor: expected 1 row");
    assert(captured[0]["seq"].integer == 17,
        "history HTTP adapter armed trace lost its row");
    present.disarmTrace();
    assert(!trace.armed() && parseJSON(present.traceJson()).array.length == 0,
        "history HTTP adapter trace disarm must clear and disarm capture");
}

private final class AsyncHistoryReply {
    shared bool done = false;
    string wire = "";
    string failure = "";
}

private size_t threadIdentity() {
    return cast(size_t) cast(void*) Thread.getThis();
}

private ushort freePort() {
    auto probe = new TcpSocket();
    scope(exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private Thread startHistoryGet(ushort port, AsyncHistoryReply reply) {
    auto client = new Thread({
        try {
            Socket socket = null;
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
                throw new Exception("history server did not accept a connection");
            scope(exit) socket.close();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                             10.seconds);
            socket.send("GET /api/history HTTP/1.1\r\n"
                      ~ "Host: 127.0.0.1\r\nConnection: close\r\n\r\n");
            ubyte[4096] buf;
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

private string responseBody(string wire) {
    immutable split = wire.indexOf("\r\n\r\n");
    assert(split >= 0,
        "5800 HTTP reply has no header/body boundary: " ~ wire);
    return wire[split + 4 .. $];
}

private void assertJsonResponse(AsyncHistoryReply reply, string status,
                                JSONValue expected, string context) {
    assert(reply.failure.length == 0,
        context ~ " client failure: " ~ reply.failure);
    assert(reply.wire.startsWith(status ~ "\r\n"),
        context ~ " status changed: " ~ reply.wire);
    assert(reply.wire.canFind("Content-Type: application/json\r\n"),
        context ~ " content type changed: " ~ reply.wire);
    assert(parseJSON(responseBody(reply.wire)) == expected,
        context ~ " parsed JSON changed: " ~ responseBody(reply.wire));
}

unittest { // populated real handler uses the production adapter callback on tick
    auto history = new CommandHistory();
    addRows(history, "undo", false);
    addRows(history, "redo", true);
    foreach (_; 0 .. 4)
        assert(history.undo(), "5800 populated setup undo must succeed");
    assert(history.undoEntriesVisible().length == 4
        && history.redoEntriesVisible().length == 4,
        "5800 populated source floor: both history stacks need four rows");

    Tool active;
    auto session = new EditSession(() => active, history, () {});
    auto adapter = new HistoryHttpAdapter(history, session, null);
    auto expectedPayload = parseJSON(adapter.historyJson());
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();

    auto reply = new AsyncHistoryReply();
    auto client = startHistoryGet(port, reply);
    scope(exit) if (client.isRunning) client.join();
    immutable tickThread = threadIdentity();
    assert(tickThread != 0,
        "5800 success tick floor: independently known tick identity is zero");
    assert(waitUntil(() => server.historyOwnedPendingForTest() == 1
                          || atomicLoad(reply.done), 2.seconds),
        "5800 success handler floor: real history request reached no handler");
    if (server.historyOwnedPendingForTest() == 1) server.tickAll();
    assert(waitUntil(() => atomicLoad(reply.done), 2.seconds),
        "5800 success completion floor: serviced history request did not reply");
    client.join();

    auto payload = parseJSON(responseBody(reply.wire));
    auto undoRows = payload["undo"].array;
    auto redoRows = payload["redo"].array;
    assert(undoRows.length == 4 && redoRows.length == 4,
        "5800 success data floor: real handler needs non-empty undo and redo");
    assert(adapter.historyProviderCallsForTest() == 1,
        "5800 success callback floor: production provider callback must run once");
    assert(adapter.historyProviderThreadForTest() == tickThread,
        "5800 thread identity: production history-provider callback did not "
        ~ "run on the independently known tick thread");
    auto undo = undoRows[3];
    auto redo = redoRows[3];
    assert(undo["label"] != redo["label"]
        && undo["args"] != redo["args"]
        && undo["flags"] != redo["flags"]
        && undo["runId"] != redo["runId"]
        && undo["tweakGen"] != redo["tweakGen"],
        "5800 parsed payload: undo/redo refire rows must differ in label, "
        ~ "args, flags, runId and tweakGeneration");
    assertJsonResponse(reply, "HTTP/1.1 200 OK", expectedPayload,
                       "5800 populated success");
}

unittest { // null provider remains an immediate real-handler success
    immutable port = freePort();
    auto server = new HttpServer(port);
    assert(!server.historyProviderPresentForTest(),
        "5800 null floor: history provider must be absent before the request");
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();

    auto reply = new AsyncHistoryReply();
    auto client = startHistoryGet(port, reply);
    scope(exit) if (client.isRunning) client.join();
    assert(waitUntil(() => atomicLoad(reply.done), 2.seconds),
        "5800 null fallback floor: absent provider did not reply immediately");
    client.join();
    assert(server.historyOwnedPendingForTest() == 0
        && server.historyOwnedTraceForTest().length == 0,
        "5800 null immediacy floor: fallback must not submit bridge work");
    assertJsonResponse(reply, "HTTP/1.1 200 OK",
        parseJSON(`{"undo":[],"redo":[]}`), "5800 null fallback");
}

unittest { // provider exception is caught by the history service
    enum failure = `history provider sentinel "<&>" failure`;
    auto history = new CommandHistory();
    record(history, new RowCommand("throwing.history", "Throwing history",
        "exception-arg", CmdFlags.Model, false, failure));
    assert(history.undoEntriesVisible().length == 1,
        "5800 exception source floor: throwing history row was not recorded");
    Tool active;
    auto session = new EditSession(() => active, history, () {});
    auto adapter = new HistoryHttpAdapter(history, session, null);
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();

    auto reply = new AsyncHistoryReply();
    auto client = startHistoryGet(port, reply);
    scope(exit) if (client.isRunning) client.join();
    assert(waitUntil(() => server.historyOwnedPendingForTest() == 1,
                     2.seconds),
        "5800 exception submission floor: request was not queued");
    server.tickAll();
    assert(waitUntil(() => atomicLoad(reply.done), 2.seconds),
        "5800 exception completion floor: caught provider failure did not reply");
    client.join();
    assert(adapter.historyProviderCallsForTest() == 1,
        "5800 exception provider floor: production callback was not reached");
    JSONValue expected = JSONValue.emptyObject;
    expected["error"] = JSONValue("Failed to retrieve history");
    expected["message"] = JSONValue(failure);
    assertJsonResponse(reply, "HTTP/1.1 500 Internal Server Error", expected,
                       "5800 provider exception");
}

unittest { // no-service request owns a real five-second timeout result
    auto history = new CommandHistory();
    addRows(history, "timeout", false);
    Tool active;
    auto session = new EditSession(() => active, history, () {});
    auto adapter = new HistoryHttpAdapter(history, session, null);
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();

    auto reply = new AsyncHistoryReply();
    immutable started = MonoTime.currTime;
    auto client = startHistoryGet(port, reply);
    scope(exit) if (client.isRunning) client.join();
    assert(waitUntil(() => server.historyOwnedPendingForTest() == 1,
                     2.seconds),
        "5800 timeout submission floor: real request was not submitted");
    client.join(); // deliberately no tickAll: only the deadline may answer
    immutable elapsed = MonoTime.currTime - started;
    auto trace = server.historyOwnedTraceForTest();
    assert(trace.length == 2
        && trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.timedOut
        && trace[0].requestIdentity == trace[1].requestIdentity,
        "5800 timeout submission floor: owned trace needs submit then timeout");
    assert(adapter.historyProviderCallsForTest() == 0,
        "5800 timeout service floor: provider ran without a service tick");
    assert(elapsed >= 5.seconds && elapsed < 9.seconds,
        "5800 timeout deadline floor: five-second submit deadline did not expire");
    JSONValue expected = JSONValue.emptyObject;
    expected["error"] = JSONValue("Failed to retrieve history");
    expected["message"] = JSONValue("timeout waiting for main thread");
    assertJsonResponse(reply, "HTTP/1.1 500 Internal Server Error", expected,
                       "5800 no-service timeout");
}

unittest { // shutdown uses the route-specific caller-owned error envelope
    auto history = new CommandHistory();
    Tool active;
    auto session = new EditSession(() => active, history, () {});
    auto adapter = new HistoryHttpAdapter(history, session, null);
    immutable port = freePort();
    auto server = new HttpServer(port);
    adapter.wire(server);
    server.markProvidersWired();
    server.tickAll();
    server.start();

    auto reply = new AsyncHistoryReply();
    auto client = startHistoryGet(port, reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.historyOwnedPendingForTest() == 1,
                     2.seconds),
        "5800 shutdown submission floor: real request was not submitted");
    server.stop();
    client.join();
    assert(adapter.historyProviderCallsForTest() == 0,
        "5800 shutdown service floor: provider ran without a service tick");
    JSONValue expected = JSONValue.emptyObject;
    expected["error"] = JSONValue("Failed to retrieve history");
    expected["message"] = JSONValue("HTTP server stopping");
    assertJsonResponse(reply, "HTTP/1.1 500 Internal Server Error", expected,
                       "5800 server stopping");
}

unittest { // production handler and RouteSpec agree on the owned main-thread door
    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable source = readText(buildPath(root, "source", "http_server.d"));
    assert(!source.canFind("historyBridge.submitAndWait"),
        "5800 surface coexistence: historyBridge must not use submitAndWait");
    immutable submitCount = source.count("historyBridge.submitOwned(");
    assert(submitCount == 1,
        "5800 production wiring floor: expected one historyBridge.submitOwned call");
    immutable routeStart = source.indexOf(`RouteSpec("/api/history"`);
    assert(routeStart >= 0,
        "5800 route census floor: /api/history RouteSpec is absent");
    immutable routeEnd = source.indexOf('\n', cast(size_t) routeStart);
    assert(routeEnd > routeStart,
        "5800 route census floor: /api/history RouteSpec has no complete line");
    auto routeLine = source[routeStart .. routeEnd];
    assert(routeLine.canFind(`"GET"`)
        && routeLine.canFind("Match.exact")
        && routeLine.canFind("Answered.mainThread")
        && routeLine.canFind(`"route_apiHistory"`),
        "5800 route census: /api/history RouteSpec must claim mainThread");
}
