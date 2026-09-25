module tests.unit.frame_counts_owner_test;

import tests.unit.http_test_client : receiveUntilClosed;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_server : BridgeResultKind, ClaimProbePoint, HttpServer;
import perf_probe : DrawPass, FrameWorkProbe, g_fc;
import std.algorithm : canFind, count;
import std.file : readText;
import std.path : buildPath, dirName;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel,
                    TcpSocket;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode;

private final class Reply {
    shared bool done;
    string wire;
    string failure;
}

private final class OwnedReply {
    shared bool done;
    BridgeResultKind kind;
    string json;
}

private auto snapshotNoGc(ref FrameWorkProbe probe) nothrow @nogc {
    return probe.snapshot();
}

private void resetNoGc(ref FrameWorkProbe probe) nothrow @nogc {
    probe.reset();
}

private ushort freePort() {
    auto socket = new TcpSocket();
    scope(exit) socket.close();
    socket.bind(new InternetAddress("127.0.0.1", cast(ushort)0));
    return (cast(InternetAddress)socket.localAddress).port;
}

private bool waitUntil(bool delegate() predicate, Duration budget = 2.seconds) {
    immutable deadline = MonoTime.currTime + budget;
    while (!predicate()) {
        if (MonoTime.currTime >= deadline) return false;
        Thread.sleep(1.msecs);
    }
    return true;
}

private Thread request(ushort port, string method, string path, Reply reply) {
    auto thread = new Thread({
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
            if (socket is null) throw new Exception("server did not accept connection");
            scope(exit) socket.close();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                             10.seconds);
            socket.send(method ~ " " ~ path ~ " HTTP/1.1\r\n"
                      ~ "Host: 127.0.0.1\r\nContent-Length: 0\r\n"
                      ~ "Connection: close\r\n\r\n");
            receiveUntilClosed(socket, reply.wire);
        } catch (Exception error) {
            reply.failure = error.msg;
        }
        atomicStore(reply.done, true);
    });
    thread.isDaemon = true;
    thread.start();
    return thread;
}

private string body(string wire) {
    immutable split = wire.indexOf("\r\n\r\n");
    assert(split >= 0, "6357 response has no body boundary: " ~ wire);
    return wire[split + 4 .. $];
}

private void seed(ref FrameWorkProbe probe) {
    foreach (frame; 0 .. 3) {
        probe.beginFrame();
        foreach (_; 0 .. 7) probe.bumpCellConsidered();
        probe.bumpCellRendered();
        probe.draw(DrawPass.faces, 36);
        {
            auto pass = probe.handlePass();
            auto leaf = probe.handleDraw(cast(size_t)(0x100 + frame));
            probe.draw(DrawPass.handles, 6);
        }
        probe.endFrame();
    }
    assert(probe.totals().seq == 3, "6357 seeded probe population changed");
}

private HttpServer startedServer(ushort port) {
    auto server = new HttpServer(port);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    assert(waitUntil(() => server.running), "6357 server did not start");
    return server;
}

private Thread submitRead(HttpServer server, OwnedReply reply,
                          Duration budget = 5.seconds) {
    auto bridge = server.frameCountsBridgeForTest();
    auto thread = new Thread({
        auto result = bridge.submitClaimed(
            HttpServer.FrameCountsReq(HttpServer.FrameCountsOp.read), budget);
        reply.kind = result.kind;
        if (result.kind == BridgeResultKind.completed)
            reply.json = result.result.snapshot.toJson();
        atomicStore(reply.done, true);
    });
    thread.isDaemon = true;
    thread.start();
    return thread;
}

private Thread submitReset(HttpServer server, OwnedReply reply,
                           Duration budget = 5.seconds) {
    auto bridge = server.frameCountsBridgeForTest();
    auto thread = new Thread({
        auto result = bridge.submitClaimed(
            HttpServer.FrameCountsReq(HttpServer.FrameCountsOp.reset), budget);
        reply.kind = result.kind;
        atomicStore(reply.done, true);
    });
    thread.isDaemon = true;
    thread.start();
    return thread;
}

// E0: completion publishes before waking a waiter already parked in wait().
unittest {
    auto server = new HttpServer(freePort());
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    auto reply = new OwnedReply();
    auto waiter = submitRead(server, reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1
                           && bridge.pendingWaitsForTest() >= 1),
        "6357 completion setup: waiter did not park on pending");
    server.tickFrameCounts(probe);
    assert(waitUntil(() => atomicLoad(reply.done)),
        "6357 completion did not wake the pending waiter");
    assert(reply.kind == BridgeResultKind.completed);
    assert(probe.totals().seq == 3, "6357 read reset the probe");
    assert(reply.json == probe.snapshot().toJson());
    auto trace = bridge.ownedTraceForTest();
    assert(trace.length == 2 && trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.completed,
        "6357 completed trace publication changed");
    waiter.join();
}

// E1: Error still publishes failed before it is rethrown to the owner.
unittest {
    auto server = new HttpServer(freePort());
    auto bridge = server.frameCountsBridgeForTest();
    auto reply = new OwnedReply();
    auto waiter = submitReset(server, reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1
                           && bridge.pendingWaitsForTest() >= 1));
    bool caught;
    try bridge.tickClaimed((ref HttpServer.FrameCountsReq,
                            ref HttpServer.FrameCountsResp) nothrow {
        throw new Error("6357 injected service failure");
    });
    catch (Error error) caught = error.msg == "6357 injected service failure";
    assert(caught,
        "6357 error path: the owner swallowed or replaced the service Error");
    assert(waitUntil(() => atomicLoad(reply.done)),
        "6357 error path: a claimed call whose service threw did not publish completion; waiter still blocked");
    assert(reply.kind == BridgeResultKind.failed,
        "6357 error path reported the wrong owner outcome");
    auto trace = bridge.ownedTraceForTest();
    assert(trace.length == 2 && trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.failed,
        "6357 failed trace publication changed");
    waiter.join();
}

// U5p: a call revoked while extracted cannot be claimed after bridge restart.
unittest {
    auto server = new HttpServer(freePort());
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    bridge.holdClaimForTest(ClaimProbePoint.extracted, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    auto reply = new OwnedReply();
    auto waiter = submitReset(server, reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1
                           && bridge.pendingWaitsForTest() >= 1));
    auto owner = new Thread({ server.tickFrameCounts(probe); });
    owner.isDaemon = true; owner.start();
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.extracted)));
    bridge.notifyStopping();
    assert(waitUntil(() => atomicLoad(reply.done))
        && reply.kind == BridgeResultKind.stopping,
        "6357 stop did not revoke a pending frame-count call");
    bridge.notifyStarted();
    bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    assert(waitUntil(() => !owner.isRunning));
    assert(probe.totals().seq == 3,
        "6357 claim was not won from pending: a call revoked by stop was serviced after restart");
    waiter.join(); owner.join();
}

// U3: service after the general drain would erase work from the first frame.
unittest {
    scope(exit) g_fc.reset();
    g_fc.reset(); seed(g_fc);
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.frameCountsBridgeForTest();

    auto resetReply = new Reply();
    auto resetClient = request(port, "POST", "/api/frames/counts/reset", resetReply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1),
        "6357 POST reset did not reach the frame-count owner queue");
    g_fc.beginFrame();
    foreach (_; 0 .. 5) g_fc.bumpCellConsidered();
    server.tickAll();
    g_fc.bumpCellRendered();
    g_fc.draw(DrawPass.faces, 36);
    g_fc.endFrame();
    server.tickFrameCounts(g_fc);
    assert(waitUntil(() => atomicLoad(resetReply.done)));
    assert(resetReply.wire.canFind("HTTP/1.1 200 OK")
        && body(resetReply.wire) == `{"status":"ok"}`);
    resetClient.join();

    auto readReply = new Reply();
    auto readClient = request(port, "GET", "/api/frames/counts", readReply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1),
        "6357 GET did not reach the frame-count owner queue");
    g_fc.beginFrame();
    foreach (_; 0 .. 5) g_fc.bumpCellConsidered();
    server.tickAll();
    g_fc.bumpCellRendered();
    g_fc.draw(DrawPass.faces, 36);
    g_fc.endFrame();
    assert(g_fc.last().cellsConsidered == 5);
    server.tickFrameCounts(g_fc);
    assert(waitUntil(() => atomicLoad(readReply.done)));
    assert(readReply.wire.canFind(`"frames":1`)
        && readReply.wire.canFind(`"last":{"seq":1`));
    assert(readReply.wire.canFind(`"cellsConsidered":5`),
        "6357 first post-reset frame lost its pre-drain work: cellsConsidered != 5");
    assert(readReply.wire.canFind(`"faces":{"calls":1`));
    readClient.join();
}

// U1/U2: tickAll never services the claim queue; the owner tick reads/resets.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);

    auto readReply = new Reply();
    auto readClient = request(port, "GET", "/api/frames/counts", readReply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    foreach (_; 0 .. 5) {
        server.tickAll();
        assert(bridge.claimPendingForTest() == 1,
            "6357 tickAll serviced a frame-count call");
    }
    server.tickFrameCounts(probe);
    assert(waitUntil(() => atomicLoad(readReply.done)));
    assert(readReply.wire.canFind("HTTP/1.1 200 OK")
        && readReply.wire.canFind("Content-Type: application/json")
        && body(readReply.wire) == probe.snapshot().toJson());
    assert(probe.totals().seq == 3);
    readClient.join();

    auto resetReply = new Reply();
    auto resetClient = request(port, "POST", "/api/frames/counts/reset", resetReply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    foreach (_; 0 .. 3) server.tickAll();
    assert(probe.totals().seq == 3);
    server.tickFrameCounts(probe);
    assert(probe.totals().seq == 0 && probe.last().seq == 0
        && probe.lastHandlePass().generation == 0);
    assert(waitUntil(() => atomicLoad(resetReply.done))
        && body(resetReply.wire) == `{"status":"ok"}`);
    resetClient.join();
}

// U4: a pending deadline returns 504 and the late owner tick does no work.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    server.setFrameCountsBudgetForTest(100.msecs);
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/counts/reset", reply);
    assert(waitUntil(() => atomicLoad(reply.done)));
    assert(reply.wire.canFind("HTTP/1.1 504 Gateway Timeout"));
    assert(reply.wire.canFind("Content-Type: application/json"));
    assert(body(reply.wire) == `{"error":"timeout waiting for main thread"}`);
    assert(bridge.claimPendingForTest() == 1);
    server.tickFrameCounts(probe);
    assert(probe.totals().seq == 3,
        "6357 expired reset executed after its 504");
    client.join();
}

// U5a: expiry while extracted revokes the call before its service starts.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    server.setFrameCountsBudgetForTest(1.seconds);
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    bridge.holdClaimForTest(ClaimProbePoint.extracted, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/counts/reset", reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    auto owner = new Thread({ server.tickFrameCounts(probe); });
    owner.isDaemon = true; owner.start();
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.extracted)));
    assert(waitUntil(() => atomicLoad(reply.done), 3.seconds));
    assert(reply.wire.canFind("HTTP/1.1 504 Gateway Timeout"));
    bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    assert(waitUntil(() => !owner.isRunning));
    assert(probe.totals().seq == 3,
        "6357 extracted expired call was serviced");
    client.join(); owner.join();
}

// U5d: deadline is checked at claim time under the state mutex.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    enum budget = 1.seconds;
    server.setFrameCountsBudgetForTest(budget);
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    bridge.holdClaimForTest(ClaimProbePoint.enqueued, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.enqueued, false);
    bridge.holdClaimForTest(ClaimProbePoint.extracted, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    immutable before = MonoTime.currTime;
    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/counts/reset", reply);
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.enqueued)));
    assert(bridge.claimPendingForTest() == 1);
    auto owner = new Thread({ server.tickFrameCounts(probe); });
    owner.isDaemon = true; owner.start();
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.extracted)));
    immutable extracted = MonoTime.currTime;
    assert(extracted < before + budget,
        "PREMISE: extraction after the deadline — cell cannot separate claim-time from extraction-time checks");
    while (MonoTime.currTime < extracted + budget + 50.msecs)
        Thread.sleep(1.msecs);
    bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    assert(waitUntil(() => !owner.isRunning));
    assert(probe.totals().seq == 3,
        "6357 claim-time deadline: a call whose deadline passed between extraction and claim was serviced");
    bridge.holdClaimForTest(ClaimProbePoint.enqueued, false);
    assert(waitUntil(() => atomicLoad(reply.done))
        && reply.wire.canFind("HTTP/1.1 504 Gateway Timeout"));
    client.join(); owner.join();
}

// U5s: stopping is checked at claim time while the waiter is still enqueued.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    bridge.holdClaimForTest(ClaimProbePoint.enqueued, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.enqueued, false);
    bridge.holdClaimForTest(ClaimProbePoint.extracted, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/counts/reset", reply);
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.enqueued)));
    auto owner = new Thread({ server.tickFrameCounts(probe); });
    owner.isDaemon = true; owner.start();
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.extracted)));
    auto stopper = new Thread({ server.stop(); });
    stopper.isDaemon = true; stopper.start();
    assert(waitUntil(() => !server.running));
    bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    assert(waitUntil(() => !owner.isRunning));
    assert(probe.totals().seq == 3,
        "6357 claim-time stop: a call claimed after stop was serviced");
    bridge.holdClaimForTest(ClaimProbePoint.enqueued, false);
    assert(waitUntil(() => atomicLoad(reply.done))
        && reply.wire.canFind("HTTP/1.1 503 Service Unavailable"));
    assert(reply.wire.canFind("Content-Type: application/json"));
    assert(waitUntil(() => !stopper.isRunning));
    client.join(); owner.join(); stopper.join();
}

// U6: after claim, deadline and stopping are ignored until completion.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    server.setFrameCountsBudgetForTest(1.seconds);
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    bridge.holdClaimForTest(ClaimProbePoint.claimed, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.claimed, false);
    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/counts/reset", reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    auto owner = new Thread({ server.tickFrameCounts(probe); });
    owner.isDaemon = true; owner.start();
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.claimed)));
    assert(waitUntil(() => bridge.claimedWaitsPastDeadlineForTest() >= 1
                           || atomicLoad(reply.done), 3.seconds));
    assert(!atomicLoad(reply.done),
        "6357 claimed reset answered before completion");
    assert(probe.totals().seq == 3);
    bridge.holdClaimForTest(ClaimProbePoint.claimed, false);
    assert(waitUntil(() => !owner.isRunning));
    assert(waitUntil(() => atomicLoad(reply.done), 1.seconds)
        && reply.wire.canFind("HTTP/1.1 200 OK"));
    assert(probe.totals().seq == 0);
    client.join(); owner.join();
}

// U8: stopping wakes a claimed waiter, which keeps waiting for completion.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    bridge.holdClaimForTest(ClaimProbePoint.claimed, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.claimed, false);
    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/counts/reset", reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    auto owner = new Thread({ server.tickFrameCounts(probe); });
    owner.isDaemon = true; owner.start();
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.claimed)));
    auto stopper = new Thread({ server.stop(); });
    stopper.isDaemon = true; stopper.start();
    assert(waitUntil(() => bridge.claimedWaitsWhileStoppingForTest() >= 1
                           || atomicLoad(reply.done)));
    assert(!atomicLoad(reply.done), "6357 stop revoked a claimed reset");
    assert(stopper.isRunning, "6357 stop did not wait for claimed completion");
    bridge.holdClaimForTest(ClaimProbePoint.claimed, false);
    assert(waitUntil(() => !owner.isRunning));
    assert(waitUntil(() => atomicLoad(reply.done))
        && reply.wire.canFind("HTTP/1.1 200 OK"));
    assert(waitUntil(() => !stopper.isRunning));
    assert(probe.totals().seq == 0);
    client.join(); owner.join(); stopper.join();
}

// U7/U9: pending stop returns 503; completed read does not obstruct stop/join.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.frameCountsBridgeForTest();
    FrameWorkProbe probe; seed(probe);
    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/counts/reset", reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    auto stopper = new Thread({ server.stop(); });
    stopper.isDaemon = true; stopper.start();
    assert(waitUntil(() => !stopper.isRunning));
    assert(bridge.claimPendingForTest() == 0,
        "6357 stopping retained a pending frame-count call");
    assert(waitUntil(() => atomicLoad(reply.done))
        && reply.wire.canFind("HTTP/1.1 503 Service Unavailable"));
    assert(body(reply.wire) == `{"error":"HTTP server stopping"}`);
    server.tickFrameCounts(probe);
    assert(probe.totals().seq == 3);
    client.join(); stopper.join();

    immutable port2 = freePort();
    auto server2 = startedServer(port2);
    scope(exit) if (server2.running) server2.stop();
    auto readReply = new Reply();
    auto readClient = request(port2, "GET", "/api/frames/counts", readReply);
    assert(waitUntil(() => server2.frameCountsBridgeForTest().claimPendingForTest() == 1));
    server2.tickFrameCounts(probe);
    assert(waitUntil(() => atomicLoad(readReply.done)));
    auto stopper2 = new Thread({ server2.stop(); });
    stopper2.isDaemon = true; stopper2.start();
    assert(waitUntil(() => !stopper2.isRunning));
    readClient.join(); stopper2.join();
}

// E2: the wire maps a claimed owner failure to the fixed 500 envelope.
unittest {
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.frameCountsBridgeForTest();
    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/counts/reset", reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    bool caught;
    try bridge.tickClaimed((ref HttpServer.FrameCountsReq,
                            ref HttpServer.FrameCountsResp) nothrow {
        throw new Error("6357 wire failure");
    });
    catch (Error error) caught = error.msg == "6357 wire failure";
    assert(caught);
    assert(waitUntil(() => atomicLoad(reply.done)));
    assert(reply.wire.canFind("HTTP/1.1 500 Internal Server Error"));
    assert(reply.wire.canFind("Content-Type: application/json"));
    assert(body(reply.wire) == `{"error":"frame-count owner failed"}`);
    client.join();
}

private size_t occurrences(string haystack, string needle) {
    return haystack.count(needle);
}

private string bodyAt(string code, string marker) {
    immutable at = code.indexOf(marker);
    assert(at >= 0, "6357 census missing marker: " ~ marker);
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6357 census marker has no body: " ~ marker);
    immutable begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    assert(false, "6357 census unterminated body: " ~ marker);
    return null;
}

// U10: production wiring owns both operations and no generic drain can see them.
unittest {
    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable raw = readText(buildPath(root, "source", "http_server.d"));
    immutable source = blankNonCode(raw);
    assert(!source.canFind("g_fc"), "6357 HTTP source still names the live probe");
    immutable readRoute = bodyAt(source,
        "private void route_apiFramesCounts(HttpRequest request, HttpResponse response)");
    immutable resetRoute = bodyAt(source,
        "private void route_apiFramesCountsReset(HttpRequest request, HttpResponse response)");
    assert(occurrences(readRoute, "frameCountsBridge.submitClaimed(") == 1
        && readRoute.canFind(".snapshot.toJson()"));
    assert(occurrences(resetRoute, "frameCountsBridge.submitClaimed(") == 1
        && !resetRoute.canFind(".reset("));
    assert(occurrences(source, ".submitClaimed(") == 4);
    immutable allTick = bodyAt(source, "public void tickAll()");
    assert(!allTick.canFind("tickFrameCounts")
        && !allTick.canFind("tickClaimed")
        && !allTick.canFind("frameCountsBridge"));
    immutable bridgeTick = bodyAt(source, "void tick()");
    assert(!bridgeTick.canFind("claimPending"));
    assert(occurrences(source, "tickClaimed(") == 3);
    immutable ownerTick = bodyAt(source,
        "public void tickFrameCounts(ref FrameWorkProbe probe)");
    assert(ownerTick.canFind("frameCountsBridge.tickClaimed("));
    assert(raw.canFind(`RouteSpec("/api/frames/counts/reset",  "POST", Match.exact,  Answered.mainThread`)
        && raw.canFind(`RouteSpec("/api/frames/counts",        "GET",  Match.exact,  Answered.mainThread`));
    FrameWorkProbe probe;
    auto detached = snapshotNoGc(probe);
    resetNoGc(probe);
    assert(detached.totals.seq == 0,
        "6357 nothrow/@nogc compile witness default snapshot changed");
}
