module tests.unit.model_handles_owned_transport_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_server : BridgeResultKind, HttpServer;
import std.algorithm : canFind;
import std.socket : InternetAddress, Socket, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.string : indexOf, startsWith;

private final class AsyncHttpReply {
    shared bool done = false;
    string wire = "";
    string failure = "";
    MonoTime completedAt;
}

private ushort freePort() {
    auto probe = new TcpSocket();
    scope(exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private size_t threadIdentity() nothrow {
    return cast(size_t) cast(void*) Thread.getThis();
}

private Thread startHttpGet(ushort port, string path, AsyncHttpReply reply) {
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
                throw new Exception("server did not accept a connection");
            scope(exit) socket.close();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                             10.seconds);
            socket.send("GET " ~ path ~ " HTTP/1.1\r\n"
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
        reply.completedAt = MonoTime.currTime;
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

private void startReady(HttpServer server) {
    server.markProvidersWired();
    server.tickAll();
    server.start();
    assert(waitUntil(() => server.running),
        "5950 server setup: HTTP server did not start");
}

private void tickUntilDone(HttpServer server, AsyncHttpReply reply) {
    immutable deadline = MonoTime.currTime + 2.seconds;
    while (!atomicLoad(reply.done)) {
        server.tickAll();
        assert(MonoTime.currTime < deadline,
            "5950 real route did not complete while tickAll was running");
        Thread.sleep(1.msecs);
    }
}

private string responseBody(string wire) {
    immutable split = wire.indexOf("\r\n\r\n");
    assert(split >= 0, "5950 HTTP reply has no header/body boundary: " ~ wire);
    return wire[split + 4 .. $];
}

private void assertReply(AsyncHttpReply reply, string status, string body_,
                         string context) {
    assert(reply.failure.length == 0,
        context ~ " client failure: " ~ reply.failure);
    assert(reply.wire.startsWith(status ~ "\r\n"),
        context ~ " status changed: " ~ reply.wire);
    assert(reply.wire.canFind("Content-Type: application/json\r\n"),
        context ~ " content type changed: " ~ reply.wire);
    assert(responseBody(reply.wire) == body_,
        context ~ " body changed: " ~ responseBody(reply.wire));
}

private AsyncHttpReply tickedGet(HttpServer server, ushort port, string path) {
    auto reply = new AsyncHttpReply();
    auto client = startHttpGet(port, path, reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    tickUntilDone(server, reply);
    client.join();
    return reply;
}

unittest { // model arguments, provider election and callback thread
    {
        shared int layerCalls;
        shared int detailedCalls;
        shared int seenLayer;
        shared size_t callbackThread;
        immutable port = freePort();
        auto server = new HttpServer(port);
        server.setLayerModelProvider((int layer) {
            atomicOp!"+="(layerCalls, 1);
            atomicStore(seenLayer, layer);
            atomicStore(callbackThread, threadIdentity());
            return `{"source":"layer","layer":2}`;
        });
        server.setDetailedModelDataProvider(() {
            atomicOp!"+="(detailedCalls, 1);
            return `{"source":"detailed"}`;
        });
        immutable tickThread = threadIdentity();
        startReady(server);
        auto reply = tickedGet(server, port, "/api/model?layer=2");
        assertReply(reply, "HTTP/1.1 200 OK",
                    `{"source":"layer","layer":2}`, "5950 model layer");
        assert(atomicLoad(layerCalls) == 1 && atomicLoad(detailedCalls) == 0
            && atomicLoad(seenLayer) == 2,
            "5950 model layer floor: provider election or layer argument changed");
        assert(atomicLoad(callbackThread) == tickThread,
            "5950 model thread: layer provider did not run on tickAll thread");
    }
    {
        shared int calls;
        shared int seenLayer;
        immutable port = freePort();
        auto server = new HttpServer(port);
        server.setLayerModelProvider((int layer) {
            atomicOp!"+="(calls, 1);
            atomicStore(seenLayer, layer);
            return `{"source":"bare"}`;
        });
        startReady(server);
        auto reply = tickedGet(server, port, "/api/model");
        assertReply(reply, "HTTP/1.1 200 OK", `{"source":"bare"}`,
                    "5950 model bare");
        assert(atomicLoad(calls) == 1 && atomicLoad(seenLayer) == -1,
            "5950 model bare floor: default layer must be -1 exactly once");
    }
    {
        shared int calls;
        shared size_t callbackThread;
        immutable port = freePort();
        auto server = new HttpServer(port);
        server.setDetailedModelDataProvider(() {
            atomicOp!"+="(calls, 1);
            atomicStore(callbackThread, threadIdentity());
            return `{"source":"detailed"}`;
        });
        immutable tickThread = threadIdentity();
        startReady(server);
        auto reply = tickedGet(server, port, "/api/model");
        assertReply(reply, "HTTP/1.1 200 OK", `{"source":"detailed"}`,
                    "5950 model detailed");
        assert(atomicLoad(calls) == 1,
            "5950 model detailed floor: provider must run exactly once");
        assert(atomicLoad(callbackThread) == tickThread,
            "5950 model thread: detailed provider did not run on tickAll thread");
    }
}

unittest { // handles success uses the real route and tick thread
    shared int calls;
    shared size_t callbackThread;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setToolHandlesDataProvider(() {
        atomicOp!"+="(calls, 1);
        atomicStore(callbackThread, threadIdentity());
        return `{"handles":{"parts":[{"part":7}]}}`;
    });
    immutable tickThread = threadIdentity();
    startReady(server);
    auto reply = tickedGet(server, port, "/api/tool/handles");
    assertReply(reply, "HTTP/1.1 200 OK",
                `{"handles":{"parts":[{"part":7}]}}`,
                "5950 handles success");
    assert(atomicLoad(calls) == 1,
        "5950 handles callback floor: provider must run exactly once");
    assert(atomicLoad(callbackThread) == tickThread,
        "5950 handles thread: provider did not run on tickAll thread");
}

unittest { // absent providers keep their immediate historical replies
    immutable port = freePort();
    auto server = new HttpServer(port);
    startReady(server);
    scope(exit) if (server.running) server.stop();

    auto model = new AsyncHttpReply();
    auto modelClient = startHttpGet(port, "/api/model", model);
    assert(waitUntil(() => atomicLoad(model.done)),
        "5950 model null provider did not reply immediately");
    modelClient.join();
    assertReply(model, "HTTP/1.1 500 Internal Server Error",
        `{"error": "Model data provider not set"}`, "5950 model null");

    auto handles = new AsyncHttpReply();
    auto handlesClient = startHttpGet(port, "/api/tool/handles", handles);
    assert(waitUntil(() => atomicLoad(handles.done)),
        "5950 handles null provider did not reply immediately");
    handlesClient.join();
    assertReply(handles, "HTTP/1.1 200 OK", `{"handles":null}`,
                "5950 handles null");
    assert(server.modelOwnedTraceForTest().length == 0
        && server.toolHandlesOwnedTraceForTest().length == 0,
        "5950 null provider bridge floor: immediate replies must submit no work");
}

unittest { // provider exceptions preserve exact escaped envelopes
    enum sentinel = "sentinel \"q\" \\ back\nline";
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setLayerModelProvider((int unused) {
        throw new Exception(sentinel);
        return "";
    });
    server.setToolHandlesDataProvider(() {
        throw new Exception(sentinel);
        return "";
    });
    startReady(server);
    scope(exit) if (server.running) server.stop();

    auto model = new AsyncHttpReply();
    auto modelClient = startHttpGet(port, "/api/model", model);
    tickUntilDone(server, model);
    modelClient.join();
    assertReply(model, "HTTP/1.1 500 Internal Server Error",
        "{\"error\": \"Failed to retrieve model data\", \"message\": "
        ~ "\"sentinel \\\"q\\\" \\\\ back\\nline\"}",
        "5950 model exception");

    auto handles = new AsyncHttpReply();
    auto handlesClient = startHttpGet(port, "/api/tool/handles", handles);
    tickUntilDone(server, handles);
    handlesClient.join();
    assertReply(handles, "HTTP/1.1 500 Internal Server Error",
        "{\"error\": \"Failed to retrieve tool handles\", \"message\": "
        ~ "\"sentinel \\\"q\\\" \\\\ back\\nline\"}",
        "5950 handles exception");
}

unittest { // a late model completion cannot change the next call
    shared int providerCalls;
    shared int firstLayer;
    shared int secondLayer;
    shared bool entered;
    shared bool release;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setModelBudgetForTest(150.msecs);
    server.setLayerModelProvider((int layer) {
        immutable call = atomicOp!"+="(providerCalls, 1);
        if (call == 1) {
            atomicStore(firstLayer, layer);
            atomicStore(entered, true);
            while (!atomicLoad(release)) Thread.sleep(1.msecs);
            throw new Exception(`late A "x"`);
        }
        atomicStore(secondLayer, layer);
        return `{"layer":1,"call":2}`;
    });
    startReady(server);

    Thread firstClient = null;
    Thread secondClient = null;
    Thread serviceTick = null;
    shared bool serviceDone;
    scope(exit) {
        atomicStore(release, true);
        if (serviceTick !is null && serviceTick.isRunning) serviceTick.join();
        if (server.running) server.stop();
        if (firstClient !is null && firstClient.isRunning) firstClient.join();
        if (secondClient !is null && secondClient.isRunning) secondClient.join();
    }

    auto first = new AsyncHttpReply();
    firstClient = startHttpGet(port, "/api/model?layer=0", first);
    serviceTick = new Thread({
        immutable deadline = MonoTime.currTime + 2.seconds;
        while (!atomicLoad(entered) && MonoTime.currTime < deadline) {
            server.tickAll();
            Thread.sleep(1.msecs);
        }
        atomicStore(serviceDone, true);
    });
    serviceTick.start();
    assert(waitUntil(() => atomicLoad(entered)),
        "5950 model late A setup: provider barrier was not entered");
    assert(waitUntil(() => atomicLoad(first.done), 8.seconds),
        "5950 model late A setup: first request did not time out");
    firstClient.join();
    assertReply(first, "HTTP/1.1 500 Internal Server Error",
        `{"error": "Failed to retrieve model data", "message": "timeout waiting for main thread"}`,
        "5950 model late A timeout");

    server.setModelBudgetForTest(5.seconds);
    auto second = new AsyncHttpReply();
    secondClient = startHttpGet(port, "/api/model?layer=1", second);
    immutable bQueued = waitUntil(
        () => server.modelOwnedPendingForTest() == 1, 1.seconds);
    atomicStore(release, true);
    assert(waitUntil(() => atomicLoad(serviceDone)),
        "5950 model late A setup: held service did not finish after release");
    serviceTick.join();
    tickUntilDone(server, second);
    secondClient.join();

    assertReply(second, "HTTP/1.1 200 OK", `{"layer":1,"call":2}`,
        "5950 late A: a timed-out /api/model request's late completion changed the next request's reply");
    assert(atomicLoad(providerCalls) == 2 && atomicLoad(firstLayer) == 0
        && atomicLoad(secondLayer) == 1 && bQueued,
        "5950 model late A population floor: distinct arguments/calls were not observed");
    auto trace = server.modelOwnedTraceForTest();
    assert(trace.length == 5,
        "5950 model late A trace floor: expected five owned events");
    assert(trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.timedOut
        && trace[2].kind == BridgeResultKind.submitted
        && trace[3].kind == BridgeResultKind.completed
        && trace[4].kind == BridgeResultKind.completed,
        "5950 model late A trace order changed");
    assert(trace[3].result.error == `late A "x"`
        && trace[4].result.result == `{"layer":1,"call":2}`,
        "5950 model late A trace payloads lost call ownership");
    assert(trace[0].stateIdentity != trace[2].stateIdentity
        && trace[1].resultIdentity != trace[3].resultIdentity
        && trace[1].resultIdentity != trace[4].resultIdentity
        && trace[3].resultIdentity != trace[4].resultIdentity,
        "5950 model late A identity floor: calls/results must be distinct");
}

unittest { // a late handles completion cannot change the next call
    shared int providerCalls;
    shared bool entered;
    shared bool release;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setToolHandlesBudgetForTest(150.msecs);
    server.setToolHandlesDataProvider(() {
        immutable call = atomicOp!"+="(providerCalls, 1);
        if (call == 1) {
            atomicStore(entered, true);
            while (!atomicLoad(release)) Thread.sleep(1.msecs);
            throw new Exception(`late A "x"`);
        }
        return `{"handles":{"call":2}}`;
    });
    startReady(server);

    Thread firstClient = null;
    Thread secondClient = null;
    Thread serviceTick = null;
    shared bool serviceDone;
    scope(exit) {
        atomicStore(release, true);
        if (serviceTick !is null && serviceTick.isRunning) serviceTick.join();
        if (server.running) server.stop();
        if (firstClient !is null && firstClient.isRunning) firstClient.join();
        if (secondClient !is null && secondClient.isRunning) secondClient.join();
    }

    auto first = new AsyncHttpReply();
    firstClient = startHttpGet(port, "/api/tool/handles", first);
    serviceTick = new Thread({
        immutable deadline = MonoTime.currTime + 2.seconds;
        while (!atomicLoad(entered) && MonoTime.currTime < deadline) {
            server.tickAll();
            Thread.sleep(1.msecs);
        }
        atomicStore(serviceDone, true);
    });
    serviceTick.start();
    assert(waitUntil(() => atomicLoad(entered)),
        "5950 handles late A setup: provider barrier was not entered");
    assert(waitUntil(() => atomicLoad(first.done), 8.seconds),
        "5950 handles late A setup: first request did not time out");
    firstClient.join();
    assertReply(first, "HTTP/1.1 500 Internal Server Error",
        `{"error": "Failed to retrieve tool handles", "message": "timeout waiting for main thread"}`,
        "5950 handles late A timeout");

    server.setToolHandlesBudgetForTest(5.seconds);
    auto second = new AsyncHttpReply();
    secondClient = startHttpGet(port, "/api/tool/handles", second);
    immutable bQueued = waitUntil(
        () => server.toolHandlesOwnedPendingForTest() == 1, 1.seconds);
    atomicStore(release, true);
    assert(waitUntil(() => atomicLoad(serviceDone)),
        "5950 handles late A setup: held service did not finish after release");
    serviceTick.join();
    tickUntilDone(server, second);
    secondClient.join();

    assertReply(second, "HTTP/1.1 200 OK", `{"handles":{"call":2}}`,
        "5950 late A: a timed-out /api/tool/handles call's late completion changed the next request's reply");
    assert(atomicLoad(providerCalls) == 2 && bQueued,
        "5950 handles late A population floor: two distinct calls did not run");
    auto trace = server.toolHandlesOwnedTraceForTest();
    assert(trace.length == 5,
        "5950 handles late A trace floor: expected five owned events");
    assert(trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.timedOut
        && trace[2].kind == BridgeResultKind.submitted
        && trace[3].kind == BridgeResultKind.completed
        && trace[4].kind == BridgeResultKind.completed,
        "5950 handles late A trace order changed");
    assert(trace[3].result.error == `late A "x"`
        && trace[4].result.result == `{"handles":{"call":2}}`,
        "5950 handles late A trace payloads lost call ownership");
    assert(trace[0].stateIdentity != trace[2].stateIdentity
        && trace[1].resultIdentity != trace[3].resultIdentity
        && trace[1].resultIdentity != trace[4].resultIdentity
        && trace[3].resultIdentity != trace[4].resultIdentity,
        "5950 handles late A identity floor: calls/results must be distinct");
}

unittest { // both production defaults retain the full five-second budget
    shared int modelCalls;
    shared int handlesCalls;
    immutable modelPort = freePort();
    immutable handlesPort = freePort();
    auto modelServer = new HttpServer(modelPort);
    auto handlesServer = new HttpServer(handlesPort);
    modelServer.setLayerModelProvider((int unused) {
        atomicOp!"+="(modelCalls, 1);
        return `{}`;
    });
    handlesServer.setToolHandlesDataProvider(() {
        atomicOp!"+="(handlesCalls, 1);
        return `{"handles":null}`;
    });
    startReady(modelServer);
    startReady(handlesServer);

    auto model = new AsyncHttpReply();
    auto handles = new AsyncHttpReply();
    immutable modelStart = MonoTime.currTime;
    auto modelClient = startHttpGet(modelPort, "/api/model", model);
    immutable handlesStart = MonoTime.currTime;
    auto handlesClient = startHttpGet(handlesPort, "/api/tool/handles", handles);
    scope(exit) {
        if (modelServer.running) modelServer.stop();
        if (handlesServer.running) handlesServer.stop();
        if (modelClient.isRunning) modelClient.join();
        if (handlesClient.isRunning) handlesClient.join();
    }
    modelClient.join();
    immutable modelElapsed = model.completedAt - modelStart;
    handlesClient.join();
    immutable handlesElapsed = handles.completedAt - handlesStart;

    assert(modelElapsed >= 5.seconds && modelElapsed < 9.seconds,
        "5950 model budget: default owned timeout is not five seconds");
    assert(handlesElapsed >= 5.seconds && handlesElapsed < 9.seconds,
        "5950 handles budget: default owned timeout is not five seconds");
    assertReply(model, "HTTP/1.1 500 Internal Server Error",
        `{"error": "Failed to retrieve model data", "message": "timeout waiting for main thread"}`,
        "5950 model budget envelope");
    assertReply(handles, "HTTP/1.1 500 Internal Server Error",
        `{"error": "Failed to retrieve tool handles", "message": "timeout waiting for main thread"}`,
        "5950 handles budget envelope");
    assert(atomicLoad(modelCalls) == 0 && atomicLoad(handlesCalls) == 0,
        "5950 budget service floor: unticked providers must not run");
    auto modelTrace = modelServer.modelOwnedTraceForTest();
    auto handlesTrace = handlesServer.toolHandlesOwnedTraceForTest();
    assert(modelTrace.length == 2 && handlesTrace.length == 2
        && modelTrace[0].kind == BridgeResultKind.submitted
        && modelTrace[1].kind == BridgeResultKind.timedOut
        && handlesTrace[0].kind == BridgeResultKind.submitted
        && handlesTrace[1].kind == BridgeResultKind.timedOut,
        "5950 budget trace floor: both calls need submitted/timedOut events");
}

unittest { // shutdown wakes model and handles with their historical text
    {
        shared int calls;
        immutable port = freePort();
        auto server = new HttpServer(port);
        server.setLayerModelProvider((int unused) {
            atomicOp!"+="(calls, 1);
            return `{}`;
        });
        startReady(server);
        auto reply = new AsyncHttpReply();
        auto client = startHttpGet(port, "/api/model", reply);
        Thread stopper = null;
        scope(exit) {
            if (server.running) server.stop();
            if (stopper !is null && stopper.isRunning) stopper.join();
            if (client.isRunning) client.join();
        }
        assert(waitUntil(() => server.modelOwnedPendingForTest() == 1),
            "5950 model stopping setup: request did not queue");
        shared bool stopDone;
        stopper = new Thread({ server.stop(); atomicStore(stopDone, true); });
        stopper.start();
        immutable stoppedPromptly = waitUntil(() => atomicLoad(stopDone));
        if (!stoppedPromptly) server.tickAll();
        stopper.join();
        client.join();
        assert(stoppedPromptly,
            "5950 model stopping: stop waited on an owned HTTP request");
        assertReply(reply, "HTTP/1.1 500 Internal Server Error",
            `{"error": "Failed to retrieve model data", "message": "timeout waiting for main thread"}`,
            "5950 model stopping envelope");
        auto trace = server.modelOwnedTraceForTest();
        assert(atomicLoad(calls) == 0 && trace.length == 2
            && trace[0].kind == BridgeResultKind.submitted
            && trace[1].kind == BridgeResultKind.stopping,
            "5950 model stopping floor: expected unserviced submit/stopping trace");
    }
    {
        shared int calls;
        immutable port = freePort();
        auto server = new HttpServer(port);
        server.setToolHandlesDataProvider(() {
            atomicOp!"+="(calls, 1);
            return `{"handles":null}`;
        });
        startReady(server);
        auto reply = new AsyncHttpReply();
        auto client = startHttpGet(port, "/api/tool/handles", reply);
        Thread stopper = null;
        scope(exit) {
            if (server.running) server.stop();
            if (stopper !is null && stopper.isRunning) stopper.join();
            if (client.isRunning) client.join();
        }
        assert(waitUntil(() => server.toolHandlesOwnedPendingForTest() == 1),
            "5950 handles stopping setup: request did not queue");
        shared bool stopDone;
        stopper = new Thread({ server.stop(); atomicStore(stopDone, true); });
        stopper.start();
        immutable stoppedPromptly = waitUntil(() => atomicLoad(stopDone));
        if (!stoppedPromptly) server.tickAll();
        stopper.join();
        client.join();
        assert(stoppedPromptly,
            "5950 handles stopping: stop waited on an owned HTTP request");
        assertReply(reply, "HTTP/1.1 500 Internal Server Error",
            `{"error": "Failed to retrieve tool handles", "message": "timeout waiting for main thread"}`,
            "5950 handles stopping envelope");
        auto trace = server.toolHandlesOwnedTraceForTest();
        assert(atomicLoad(calls) == 0 && trace.length == 2
            && trace[0].kind == BridgeResultKind.submitted
            && trace[1].kind == BridgeResultKind.stopping,
            "5950 handles stopping floor: expected unserviced submit/stopping trace");
    }
}

unittest { // providers can disappear after submit but before service
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setLayerModelProvider((int unused) => `{}`);
    server.setDetailedModelDataProvider(() => `{}`);
    server.setToolHandlesDataProvider(() => `{"handles":null}`);
    startReady(server);
    scope(exit) if (server.running) server.stop();

    auto model = new AsyncHttpReply();
    auto modelClient = startHttpGet(port, "/api/model", model);
    assert(waitUntil(() => server.modelOwnedPendingForTest() == 1),
        "5950 model provider-loss setup: request did not queue");
    server.setLayerModelProvider(null);
    server.setDetailedModelDataProvider(null);
    tickUntilDone(server, model);
    modelClient.join();
    assertReply(model, "HTTP/1.1 500 Internal Server Error",
        `{"error": "Failed to retrieve model data", "message": "model data provider not set"}`,
        "5950 model provider loss");

    auto handles = new AsyncHttpReply();
    auto handlesClient = startHttpGet(port, "/api/tool/handles", handles);
    assert(waitUntil(() => server.toolHandlesOwnedPendingForTest() == 1),
        "5950 handles provider-loss setup: request did not queue");
    server.setToolHandlesDataProvider(null);
    tickUntilDone(server, handles);
    handlesClient.join();
    assertReply(handles, "HTTP/1.1 500 Internal Server Error",
        `{"error": "Failed to retrieve tool handles", "message": "tool handles provider not set"}`,
        "5950 handles provider loss");
}

unittest { // an early request remains pending until its ordinary service tick
    immutable modelPort = freePort();
    immutable handlesPort = freePort();
    auto modelServer = new HttpServer(modelPort);
    auto handlesServer = new HttpServer(handlesPort);
    modelServer.setLayerModelProvider((int unused) => `{"model":"early"}`);
    handlesServer.setToolHandlesDataProvider(
        () => `{"handles":{"parts":[{"part":9}]}}`);
    startReady(modelServer);
    startReady(handlesServer);

    auto model = new AsyncHttpReply();
    auto handles = new AsyncHttpReply();
    auto modelClient = startHttpGet(modelPort, "/api/model", model);
    auto handlesClient = startHttpGet(handlesPort, "/api/tool/handles", handles);
    scope(exit) {
        if (modelServer.running) modelServer.stop();
        if (handlesServer.running) handlesServer.stop();
        if (modelClient.isRunning) modelClient.join();
        if (handlesClient.isRunning) handlesClient.join();
    }
    assert(waitUntil(() => modelServer.modelOwnedPendingForTest() == 1)
        && waitUntil(() => handlesServer.toolHandlesOwnedPendingForTest() == 1),
        "5950 early request setup: both requests must queue");
    Thread.sleep(300.msecs);
    assert(modelServer.modelOwnedPendingForTest() == 1
        && handlesServer.toolHandlesOwnedPendingForTest() == 1
        && !atomicLoad(model.done) && !atomicLoad(handles.done),
        "5950 early request: an unticked call completed before service");
    tickUntilDone(modelServer, model);
    tickUntilDone(handlesServer, handles);
    modelClient.join();
    handlesClient.join();
    assertReply(model, "HTTP/1.1 200 OK", `{"model":"early"}`,
                "5950 early model");
    assertReply(handles, "HTTP/1.1 200 OK",
        `{"handles":{"parts":[{"part":9}]}}`, "5950 early handles");
}

unittest { // production bridge array retains the draw-read phase order
    // A second, non-const overload would compile silently beside this one
    // (D overloads on const) and could report a different bridge.
    static assert(__traits(getOverloads, HttpServer,
                           "commandBridgeTickIndexForTest").length == 1,
        "5950 phase: exactly one commandBridgeTickIndexForTest overload");
    auto server = new HttpServer(freePort());
    immutable handlesIndex = server.toolHandlesBridgeTickIndexForTest();
    immutable commandIndex = server.commandBridgeTickIndexForTest();
    assert(handlesIndex != size_t.max && commandIndex != size_t.max,
        "5950 phase population floor: handles and command bridges must be constructed");
    assert(handlesIndex < commandIndex,
        "5950 phase: /api/tool/handles must be serviced before the command bridge in one tickAll pass");
}
