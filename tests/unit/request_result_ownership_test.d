module tests.unit.request_result_ownership_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_server : BridgeResultKind, HttpServer;
import std.algorithm : canFind;
import std.file : readText;
import std.path : buildPath, dirName;
import std.socket : InternetAddress, Socket, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.string : indexOf;

private final class AsyncHttpReply {
    shared bool done = false;
    string wire = "";
    string failure = "";
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
            "5730: real HTTP request did not complete while tickAll was running");
        Thread.sleep(1.msecs);
    }
}

private string responseBody(string wire) {
    immutable split = wire.indexOf("\r\n\r\n");
    assert(split >= 0, "5730: HTTP reply has no header/body boundary: " ~ wire);
    return wire[split + 4 .. $];
}

private size_t occurrences(string source, string needle) {
    size_t result = 0;
    size_t from = 0;
    while (from < source.length) {
        immutable hit = source.indexOf(needle, from);
        if (hit < 0) break;
        ++result;
        from = hit + needle.length;
    }
    return result;
}

unittest {
    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable source = readText(buildPath(root, "source", "http_server.d"));
    assert(occurrences(source, "selectionBridge.submitOwned(") == 1,
        "5730 production wiring: route_apiSelection must contain the one "
        ~ "selectionBridge.submitOwned call; the helper alone is not evidence");
    assert(occurrences(source, "layersBridge.submitOwned(") == 1,
        "5730 production wiring: route_apiLayers must contain the one "
        ~ "layersBridge.submitOwned call; the helper alone is not evidence");

    enum int kRigMaxIters = 50;
    shared int providerCalls = 0;
    shared bool firstServiceEntered = false;
    shared bool releaseFirstService = false;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setSelectionBridgeMaxItersForTest(kRigMaxIters);
    server.setSelectionDataProvider(() {
        immutable call = atomicOp!"+="(providerCalls, 1);
        if (call == 1) {
            atomicStore(firstServiceEntered, true);
            while (!atomicLoad(releaseFirstService)) Thread.sleep(1.msecs);
            return `{"payload":"late-first"}`;
        }
        return `{"payload":"second-only"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    server.start();

    Thread serviceTick = null;
    shared bool serviceTickDone = false;
    scope(exit) {
        atomicStore(releaseFirstService, true);
        if (serviceTick !is null && serviceTick.isRunning) serviceTick.join();
        if (server.running) server.stop();
    }

    auto firstReply = new AsyncHttpReply();
    auto firstClient = startHttpGet(port, "/api/selection", firstReply);
    assert(waitUntil(() => server.selectionOwnedPendingForTest() == 1,
                     2.seconds),
        "5730 order 1: first selection request never reached the owned queue");

    serviceTick = new Thread({
        server.tickAll();
        atomicStore(serviceTickDone, true);
    });
    serviceTick.start();
    assert(waitUntil(() => atomicLoad(firstServiceEntered), 2.seconds),
        "5730 order 1: controlled provider barrier was not entered");
    assert(waitUntil(() => atomicLoad(firstReply.done), 2.seconds),
        "5730 order 1: HTTP timeout did not occur while service was held");
    firstClient.join();
    assert(firstReply.failure.length == 0,
        "5730 order 1: first HTTP client failed: " ~ firstReply.failure);
    assert(firstReply.wire.canFind("HTTP/1.1 500 Internal Server Error")
        && responseBody(firstReply.wire).canFind(
            `"message": "timeout waiting for main thread"`),
        "5730 order 1: service entered -> HTTP timeout must return the "
        ~ "selection timeout envelope: " ~ firstReply.wire);
    assert(atomicLoad(providerCalls) == 1,
        "5730 order 1 population floor: exactly one non-empty provider "
        ~ "payload must be held behind the first barrier");

    auto secondReply = new AsyncHttpReply();
    auto secondClient = startHttpGet(port, "/api/selection", secondReply);
    assert(waitUntil(() => server.selectionOwnedPendingForTest() == 1,
                     2.seconds),
        "5730 order 1: next request did not queue while the old service was held");
    atomicStore(releaseFirstService, true);
    assert(waitUntil(() => atomicLoad(serviceTickDone), 2.seconds),
        "5730 order 1: late service did not resume after its barrier release");
    serviceTick.join();
    tickUntilDone(server, secondReply);
    secondClient.join();
    assert(secondReply.failure.length == 0,
        "5730 order 1: second HTTP client failed: " ~ secondReply.failure);
    assert(responseBody(secondReply.wire) == `{"payload":"second-only"}`,
        "5730 payload: the second response must contain only the second "
        ~ "provider result, never the late first completion: " ~ secondReply.wire);
    assert(atomicLoad(providerCalls) == 2,
        "5730 payload population floor: both distinct provider calls must run");

    auto trace = server.selectionOwnedTraceForTest();
    assert(trace.length == 5,
        "5730 identity population floor: expected submit/timeout/submit/"
        ~ "late-complete/next-complete, got a different event count");
    assert(trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.timedOut
        && trace[2].kind == BridgeResultKind.submitted
        && trace[3].kind == BridgeResultKind.completed
        && trace[4].kind == BridgeResultKind.completed,
        "5730 identity: controlled event order changed");
    assert(trace[0].requestIdentity == trace[1].requestIdentity
        && trace[0].requestIdentity == trace[3].requestIdentity,
        "5730 identity: timeout and late completion must remain attributable "
        ~ "to the first request");
    assert(trace[2].requestIdentity == trace[4].requestIdentity
        && trace[2].requestIdentity != trace[0].requestIdentity,
        "5730 identity: the next request must own a different request identity");
    assert(trace[0].stateIdentity != 0
        && trace[2].stateIdentity != 0
        && trace[0].stateIdentity != trace[2].stateIdentity,
        "5730 identity: each request must have a distinct non-null state object");
    assert(trace[1].resultIdentity != trace[3].resultIdentity
        && trace[1].resultIdentity != trace[4].resultIdentity
        && trace[3].resultIdentity != trace[4].resultIdentity,
        "5730 identity: timeout, late completion and next completion must "
        ~ "have three different result identities");
    assert(trace[1].result.error == "timeout waiting for main thread",
        "5730 timeout payload: the synthetic timeout result changed");
    assert(trace[3].result.result == `{"payload":"late-first"}`
        && trace[3].result.error.length == 0,
        "5730 late payload: timeout must not write into the service result "
        ~ "that the main-thread callback resumes filling");
    assert(trace[4].result.result == `{"payload":"second-only"}`
        && trace[4].result.error.length == 0,
        "5730 next payload: next completion must contain only its own result");
}

unittest {
    enum int kRigMaxIters = 50;
    shared int providerCalls = 0;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setSelectionBridgeMaxItersForTest(kRigMaxIters);
    server.setSelectionDataProvider(() {
        immutable call = atomicOp!"+="(providerCalls, 1);
        return call == 1
            ? `{"payload":"late-unserviced-first"}`
            : `{"payload":"after-timeout-second"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();

    auto firstReply = new AsyncHttpReply();
    auto firstClient = startHttpGet(port, "/api/selection", firstReply);
    assert(waitUntil(() => server.selectionOwnedPendingForTest() == 1,
                     2.seconds),
        "5730 order 2: first request never reached the owned queue");
    assert(waitUntil(() => atomicLoad(firstReply.done), 2.seconds),
        "5730 order 2: first request did not time out before service");
    firstClient.join();
    assert(firstReply.failure.length == 0
        && responseBody(firstReply.wire).canFind(
            `"message": "timeout waiting for main thread"`),
        "5730 order 2: timeout-before-service did not return its own error: "
        ~ firstReply.wire);
    assert(atomicLoad(providerCalls) == 0,
        "5730 order 2: provider ran before the deliberately absent tick");

    auto secondReply = new AsyncHttpReply();
    auto secondClient = startHttpGet(port, "/api/selection", secondReply);
    assert(waitUntil(() => server.selectionOwnedPendingForTest() == 2,
                     2.seconds),
        "5730 order 2 population floor: timed-out and next request must both "
        ~ "remain queued before the first tick");
    server.tickAll();
    assert(atomicLoad(providerCalls) == 1,
        "5730 order 2: first tick must late-complete exactly the first request");
    assert(server.selectionOwnedPendingForTest() == 1,
        "5730 order 2: first tick must leave the next request pending");
    server.tickAll();
    assert(atomicLoad(providerCalls) == 2,
        "5730 order 2 population floor: second tick must service the second request");
    assert(waitUntil(() => atomicLoad(secondReply.done), 2.seconds),
        "5730 order 2: second HTTP response did not complete after its tick");
    secondClient.join();
    assert(secondReply.failure.length == 0,
        "5730 order 2: second HTTP client failed: " ~ secondReply.failure);
    assert(responseBody(secondReply.wire) ==
           `{"payload":"after-timeout-second"}`,
        "5730 order 2 payload: next response must match only the second "
        ~ "request after timeout-before-service: " ~ secondReply.wire);

    auto trace = server.selectionOwnedTraceForTest();
    assert(trace.length == 5,
        "5730 order 2 identity population floor: expected five owned events");
    assert(trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.timedOut
        && trace[2].kind == BridgeResultKind.submitted
        && trace[3].kind == BridgeResultKind.completed
        && trace[4].kind == BridgeResultKind.completed,
        "5730 order 2 identity: controlled event order changed");
    assert(trace[0].stateIdentity != trace[2].stateIdentity
        && trace[0].requestIdentity != trace[2].requestIdentity,
        "5730 order 2 identity: a later request must not reuse timed-out state");
    assert(trace[1].resultIdentity != trace[3].resultIdentity
        && trace[1].resultIdentity != trace[4].resultIdentity
        && trace[3].resultIdentity != trace[4].resultIdentity,
        "5730 order 2 identity: timeout, late completion and next completion "
        ~ "must remain distinct");
    assert(trace[3].result.result == `{"payload":"late-unserviced-first"}`
        && trace[4].result.result == `{"payload":"after-timeout-second"}`,
        "5730 order 2 payload: each queued state must retain its own result");
}

unittest {
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setLayersDataProvider(() => `{"layers":[{"name":"owned"}]}`);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();

    auto okReply = new AsyncHttpReply();
    auto okClient = startHttpGet(port, "/api/layers", okReply);
    assert(waitUntil(() => server.layersOwnedPendingForTest() == 1, 2.seconds),
        "5730 layers: real route did not submit through the owned bridge");
    tickUntilDone(server, okReply);
    okClient.join();
    assert(okReply.failure.length == 0,
        "5730 layers: success client failed: " ~ okReply.failure);
    assert(responseBody(okReply.wire) == `{"layers":[{"name":"owned"}]}`,
        "5730 layers: success payload changed: " ~ okReply.wire);

    server.setLayersDataProvider(() {
        throw new Exception("owned layers provider failure");
        return "";
    });
    auto errorReply = new AsyncHttpReply();
    auto errorClient = startHttpGet(port, "/api/layers", errorReply);
    assert(waitUntil(() => server.layersOwnedPendingForTest() == 1, 2.seconds),
        "5730 layers exception: request did not reach the owned bridge");
    tickUntilDone(server, errorReply);
    errorClient.join();
    assert(errorReply.failure.length == 0,
        "5730 layers exception: HTTP client failed: " ~ errorReply.failure);
    assert(errorReply.wire.canFind("HTTP/1.1 500 Internal Server Error")
        && responseBody(errorReply.wire).canFind(
            `"error": "Failed to retrieve layers"`)
        && responseBody(errorReply.wire).canFind(
            `"message": "owned layers provider failure"`),
        "5730 layers exception: existing protocol envelope changed: "
        ~ errorReply.wire);

    server.setLayersDataProvider(() => `{"layers":[{"name":"too-late"}]}`);
    auto stoppingReply = new AsyncHttpReply();
    auto stoppingClient = startHttpGet(
        port, "/api/layers", stoppingReply);
    assert(waitUntil(() => server.layersOwnedPendingForTest() == 1, 2.seconds),
        "5730 layers shutdown: request did not become pending");
    shared bool stopDone = false;
    auto stopper = new Thread({
        server.stop();
        atomicStore(stopDone, true);
    });
    stopper.start();
    immutable stoppedPromptly = waitUntil(() => atomicLoad(stopDone), 2.seconds);
    if (!stoppedPromptly) {
        server.tickAll();
        assert(waitUntil(() => atomicLoad(stopDone), 2.seconds),
            "5730 layers shutdown cleanup: stop remained blocked after tick");
    }
    stopper.join();
    stoppingClient.join();
    assert(stoppedPromptly,
        "5730 layers shutdown: stop().join waited on a migrated HTTP request "
        ~ "instead of waking it");
    assert(stoppingReply.failure.length == 0,
        "5730 layers shutdown: HTTP client failed: " ~ stoppingReply.failure);
    assert(stoppingReply.wire.canFind("HTTP/1.1 500 Internal Server Error")
        && responseBody(stoppingReply.wire).canFind(
            `"error": "Failed to retrieve layers"`)
        && responseBody(stoppingReply.wire).canFind(
            `"message": "HTTP server stopping"`),
        "5730 layers shutdown: waiting request must receive its endpoint "
        ~ "500 stopping envelope while its socket is available: "
        ~ stoppingReply.wire);
}

unittest {
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setSelectionDataProvider(() => `{"selectedVertices":[7]}`);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();

    auto stoppingReply = new AsyncHttpReply();
    auto stoppingClient = startHttpGet(
        port, "/api/selection", stoppingReply);
    assert(waitUntil(() => server.selectionOwnedPendingForTest() == 1,
                     2.seconds),
        "5730 selection shutdown: request did not become pending");
    shared bool stopDone = false;
    auto stopper = new Thread({
        server.stop();
        atomicStore(stopDone, true);
    });
    stopper.start();
    immutable stoppedPromptly = waitUntil(() => atomicLoad(stopDone), 2.seconds);
    if (!stoppedPromptly) {
        server.tickAll();
        assert(waitUntil(() => atomicLoad(stopDone), 2.seconds),
            "5730 selection shutdown cleanup: stop remained blocked after tick");
    }
    stopper.join();
    stoppingClient.join();
    assert(stoppedPromptly,
        "5730 selection shutdown: stop().join waited on a migrated HTTP "
        ~ "request instead of waking it");
    assert(stoppingReply.failure.length == 0,
        "5730 selection shutdown: HTTP client failed: " ~ stoppingReply.failure);
    assert(stoppingReply.wire.canFind("HTTP/1.1 500 Internal Server Error")
        && responseBody(stoppingReply.wire).canFind(
            `"error": "Failed to retrieve selection data"`)
        && responseBody(stoppingReply.wire).canFind(
            `"message": "HTTP server stopping"`),
        "5730 selection shutdown: waiting request must receive its endpoint "
        ~ "500 stopping envelope while its socket is available: "
        ~ stoppingReply.wire);
}
