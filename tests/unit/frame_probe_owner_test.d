module tests.unit.frame_probe_owner_test;

import tests.unit.http_test_client : receiveUntilClosed;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_server : ClaimProbePoint, HttpServer;
import perf_probe : g_frames, FrameProbe, FrameRec, Phase, toJson;
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
    assert(split >= 0, "6511 response has no body boundary: " ~ wire);
    return wire[split + 4 .. $];
}

private HttpServer startedServer(ushort port) {
    auto server = new HttpServer(port);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    assert(waitUntil(() => server.running), "6511 server did not start");
    return server;
}

version (PerfProbe) {
    private void seed(ref FrameProbe probe, long base = 100) {
        foreach (i; 0 .. 3) {
            probe.beginFrame();
            probe.addPhase(Phase.draw, base + i);
            probe.endFrame();
        }
        assert(probe.stats().frameCount == 3,
            "6511 seeded probe population changed");
    }
}

version (PerfProbe) {} else unittest { // D-1: default answers without bridge work
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    server.setFramesBudgetForTest(100.msecs);
    auto bridge = server.framesBridgeForTest();
    assert(server.running, "6511 default route fixture server is not running");

    auto readReply = new Reply();
    auto readClient = request(port, "GET", "/api/frames", readReply);
    assert(waitUntil(() => atomicLoad(readReply.done)),
        "6511 default GET /api/frames did not answer");
    assert(readReply.wire.canFind("HTTP/1.1 200 OK")
        && readReply.wire.canFind("Content-Type: application/json")
        && body(readReply.wire) == "{}"
        && body(readReply.wire).length == 2,
        "6511 default build must answer {} without touching the bridge");
    readClient.join();

    auto resetReply = new Reply();
    auto resetClient = request(port, "POST", "/api/frames/reset", resetReply);
    assert(waitUntil(() => atomicLoad(resetReply.done)),
        "6511 default POST /api/frames/reset did not answer");
    assert(resetReply.wire.canFind("HTTP/1.1 200 OK")
        && resetReply.wire.canFind("Content-Type: application/json")
        && body(resetReply.wire) == `{"status":"ok"}`,
        "6511 default reset response bytes changed");
    resetClient.join();

    assert(bridge.claimPendingForTest() == 0
        && bridge.ownedTraceForTest().length == 0,
        "6511 default build touched the FrameProbe bridge");
}

version (PerfProbe) unittest { // P-1: only the owner tick serves a read
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.framesBridgeForTest();
    FrameProbe probe;
    seed(probe);
    assert(probe.stats().frameCount == 3,
        "6511 read fixture must start with three frames");

    auto reply = new Reply();
    auto client = request(port, "GET", "/api/frames", reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1),
        "6511 perf build must serve /api/frames through the owner bridge");
    foreach (_; 0 .. 5) {
        server.tickAll();
        assert(bridge.claimPendingForTest() == 1,
            "6511 generic drain served the frame-probe claim");
    }
    server.tickFrames(probe);
    assert(waitUntil(() => atomicLoad(reply.done)),
        "6511 owner-served frame read did not complete");
    auto expected = probe.snapshot();
    assert(reply.wire.canFind("HTTP/1.1 200 OK")
        && reply.wire.canFind("Content-Type: application/json"),
        "6511 owner-served frame read lost its 200/JSON response");
    assert(body(reply.wire) == expected.toJson()
        && body(reply.wire).canFind(`"frameCount":3`),
        "6511 perf build must serve /api/frames through the owner bridge");
    client.join();
}

version (PerfProbe) unittest { // P-2/P-4: timeout drops the entire reset
    scope(exit) g_frames.reset();
    g_frames.reset();
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    server.setFramesBudgetForTest(100.msecs);
    auto bridge = server.framesBridgeForTest();
    seed(g_frames);

    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/reset", reply);
    assert(waitUntil(() => atomicLoad(reply.done)),
        "6511 timed-out frame reset did not complete its HTTP reply");
    assert(reply.wire.canFind("HTTP/1.1 504 Gateway Timeout"),
        "6511 timed-out frame reset lost its 504 mapping");
    assert(body(reply.wire) == `{"error":"timeout waiting for main thread"}`);
    assert(g_frames.stats().frameCount == 3,
        "6511 timed-out reset changed the probe before service");

    foreach (_; 0 .. 3) server.tickAll();
    assert(g_frames.stats().frameCount == 3,
        "6511 expired reset was applied by a later generic drain");
    assert(bridge.claimPendingForTest() == 1,
        "6511 expired claimed reset disappeared before its owner tick");
    server.tickFrames(g_frames);
    assert(g_frames.stats().frameCount == 3,
        "6511 expired reset was applied on a later frame");
    assert(bridge.claimPendingForTest() == 0,
        "6511 owner tick did not discard the expired reset");

    // Hold the HTTP waiter before it can mark the call expired, then let the
    // owner reach the extracted call before its deadline and claim it after.
    // This isolates tickClaimed's own deadline check from the waiter path.
    bridge.holdClaimForTest(ClaimProbePoint.enqueued, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.enqueued, false);
    bridge.holdClaimForTest(ClaimProbePoint.extracted, true);
    scope(exit) bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    auto controlledReply = new Reply();
    auto controlledClient = request(port, "POST", "/api/frames/reset",
                                    controlledReply);
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.enqueued)),
        "6680 controlled reset did not reach the enqueued claim hold");
    auto owner = new Thread({ server.tickFrames(g_frames); });
    owner.isDaemon = true;
    owner.start();
    assert(waitUntil(() => bridge.claimReachedForTest(ClaimProbePoint.extracted)),
        "6680 reset owner did not reach the extracted claim hold");
    Thread.sleep(150.msecs);
    bridge.holdClaimForTest(ClaimProbePoint.extracted, false);
    assert(waitUntil(() => !owner.isRunning),
        "6680 reset owner did not finish after the extracted hold was released");
    assert(g_frames.stats().frameCount == 3,
        "6511 expired reset was applied on a later frame");
    bridge.holdClaimForTest(ClaimProbePoint.enqueued, false);
    // Two asserts, not one `&&`: a compound red cannot separate "the reply never
    // completed" from "it completed without the 504 mapping", and those are
    // different defects in different code. `:181-184` already splits the identical
    // pair correctly — this site is the same assertion written the worse way.
    assert(waitUntil(() => atomicLoad(controlledReply.done)),
        "6680 controlled expired reset did not complete its HTTP reply");
    assert(controlledReply.wire.canFind("HTTP/1.1 504 Gateway Timeout"),
        "6680 controlled expired reset lost its 504 mapping");
    controlledClient.join();
    owner.join();

    g_frames.beginFrame();
    g_frames.addPhase(Phase.draw, 444);
    g_frames.endFrame();
    server.tickFrames(g_frames);
    FrameRec[4] recent;
    assert(g_frames.copyRecent(recent[]) == 4
        && g_frames.stats().frameCount == 4,
        "6511 probe did not continue after dropping the expired reset");
    client.join();
}

version (PerfProbe) unittest { // P-3: stopping before claim returns 503
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.framesBridgeForTest();
    FrameProbe probe;
    seed(probe);

    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/reset", reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1),
        "6511 stopping fixture never exposed a pending frame reset");
    auto stopper = new Thread({ server.stop(); });
    stopper.isDaemon = true;
    stopper.start();
    assert(waitUntil(() => !stopper.isRunning),
        "6680 server stop did not finish with a pending frame reset");
    assert(waitUntil(() => atomicLoad(reply.done)),
        "6680 stopped frame reset did not complete its HTTP reply");
    assert(reply.wire.canFind("HTTP/1.1 503 Service Unavailable"));
    assert(body(reply.wire) == `{"error":"HTTP server stopping"}`);
    assert(bridge.claimPendingForTest() == 0,
        "6511 stopping retained a pending frame-probe call");
    server.tickFrames(probe);
    assert(probe.stats().frameCount == 3,
        "6511 stopped reset was applied later");
    client.join();
    stopper.join();
}

version (PerfProbe) unittest { // Sweep: a read timeout keeps its HTTP mapping
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    server.setFramesBudgetForTest(100.msecs);

    auto reply = new Reply();
    auto client = request(port, "GET", "/api/frames", reply);
    assert(waitUntil(() => atomicLoad(reply.done)),
        "6511 timed-out frame read did not complete its HTTP reply");
    assert(reply.wire.canFind("HTTP/1.1 504 Gateway Timeout")
        && body(reply.wire) == `{"error":"timeout waiting for main thread"}`,
        "6511 frame read timeout lost its 504 mapping");
    client.join();
}

version (PerfProbe) unittest { // Sweep: stopping a pending read maps to 503
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.framesBridgeForTest();

    auto reply = new Reply();
    auto client = request(port, "GET", "/api/frames", reply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1),
        "6680 stopping-read fixture never exposed a pending frame read");
    auto stopper = new Thread({ server.stop(); });
    stopper.isDaemon = true;
    stopper.start();
    assert(waitUntil(() => !stopper.isRunning),
        "6680 server stop did not finish with a pending frame read");
    assert(waitUntil(() => atomicLoad(reply.done)),
        "6680 stopped frame read did not complete its HTTP reply");
    assert(reply.wire.canFind("HTTP/1.1 503 Service Unavailable")
        && body(reply.wire) == `{"error":"HTTP server stopping"}`,
        "6511 stopped frame read lost its 503 mapping");
    client.join();
    stopper.join();
}

version (PerfProbe) unittest { // P-5/P-6: reset boundary then full next frame
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.framesBridgeForTest();
    FrameProbe probe;
    seed(probe);

    auto resetReply = new Reply();
    auto resetClient = request(port, "POST", "/api/frames/reset", resetReply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1),
        "6680 reset-boundary fixture never exposed a pending frame reset");
    probe.beginFrame();
    probe.addPhase(Phase.draw, 111);
    probe.endFrame();
    FrameRec[4] beforeReset;
    assert(probe.copyRecent(beforeReset[]) == 4
        && probe.stats().frameCount == 4,
        "6511 reset-boundary premise must include the just-finished frame");
    server.tickFrames(probe);
    assert(waitUntil(() => atomicLoad(resetReply.done)),
        "6680 owner-served frame reset did not complete its HTTP reply");
    assert(resetReply.wire.canFind("HTTP/1.1 200 OK")
        && body(resetReply.wire) == `{"status":"ok"}`);
    FrameRec[1] cleared;
    assert(probe.stats().frameCount == 0 && probe.copyRecent(cleared[]) == 0,
        "6511 owner reset did not discard the completed prior window");
    resetClient.join();

    probe.beginFrame();
    probe.addPhase(Phase.draw, 222);
    probe.endFrame();
    auto readReply = new Reply();
    auto readClient = request(port, "GET", "/api/frames", readReply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1),
        "6680 next-frame fixture never exposed a pending frame read");
    server.tickFrames(probe);
    assert(waitUntil(() => atomicLoad(readReply.done)),
        "6680 owner-served next-frame read did not complete its HTTP reply");
    FrameRec[1] next;
    assert(probe.copyRecent(next[]) == 1 && next[0].drawNs == 222,
        "6511 next frame after reset was not counted completely");
    assert(body(readReply.wire).canFind(`"frameCount":1`)
        && body(readReply.wire).canFind(`"drawNs":{"p95_ns":222}`),
        "6511 next-frame wire lost its complete draw phase");
    readClient.join();
}

private size_t occurrences(string haystack, string needle) {
    return haystack.count(needle);
}

private string bodyAt(string code, string marker) {
    immutable at = code.indexOf(marker);
    assert(at >= 0, "6511 census missing marker: " ~ marker);
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6511 census marker has no body: " ~ marker);
    immutable begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    assert(false, "6511 census unterminated body: " ~ marker);
    return null;
}

unittest { // C-1: production wiring owns exactly these two routes
    import std.file : dirEntries, SpanMode;

    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable serverPath = buildPath(root, "source", "http_server.d");
    immutable raw = readText(serverPath);
    immutable source = blankNonCode(raw);
    assert(!source.canFind("g_frames"),
        "6511 HTTP source still names the live FrameProbe");
    immutable readRoute = bodyAt(source,
        "private void route_apiFrames(HttpRequest request, HttpResponse response)");
    immutable resetRoute = bodyAt(source,
        "private void route_apiFramesReset(HttpRequest request, HttpResponse response)");
    assert(occurrences(readRoute, "framesBridge.submitClaimed(") == 1
        && readRoute.canFind(".snapshot.toJson()"));
    assert(occurrences(resetRoute, "framesBridge.submitClaimed(") == 1
        && !resetRoute.canFind(".reset("));
    assert(occurrences(source, ".submitClaimed(") == 4);
    assert(occurrences(source, "tickClaimed(") == 3);
    immutable allTick = bodyAt(source, "public void tickAll()");
    assert(allTick.canFind("foreach (b; bridges) b.tick();"),
        "6511 tickAll floor: the generic drain vanished, the negations below "
        ~ "hold over an empty body");
    assert(!allTick.canFind("tickFrames")
        && !allTick.canFind("framesBridge"));
    immutable ownerTick = bodyAt(source,
        "public void tickFrames(ref FrameProbe probe)");
    assert(ownerTick.canFind("framesBridge.tickClaimed("));
    assert(raw.canFind("version (PerfProbe) {")
        && raw.canFind("private enum Answered kFramesAnswered = Answered.mainThread;")
        && raw.canFind("else {")
        && raw.canFind("private enum Answered kFramesAnswered = Answered.httpThread;")
        && raw.canFind("6730 PerfProbe frame routes must answer on the main thread")
        && raw.canFind("6730 default frame routes must answer on the HTTP thread"));
    assert(raw.canFind("private Duration framesBudget_ = 5.seconds;"),
        "6511 FrameProbe routes must retain the owner-approved five-second deadline");
    assert(raw.canFind(`RouteSpec("/api/frames/reset",         "POST", Match.exact,  kFramesAnswered`)
        && raw.canFind(`RouteSpec("/api/frames",               "GET",  Match.exact,  kFramesAnswered`));

    size_t files;
    foreach (_; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth))
        ++files;
    assert(files >= 500, "6511 source census population fell below 500 modules");
}
