module tests.unit.frame_probe_owner_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_server : HttpServer;
import perf_probe : FrameProbe, FrameRec, Phase, toJson;
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
            ubyte[4096] buffer;
            for (;;) {
                auto n = socket.receive(buffer[]);
                if (n <= 0) break;
                reply.wire ~= cast(string)buffer[0 .. n].idup;
            }
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
        && body(readReply.wire) == "{}"
        && body(readReply.wire).length == 2,
        "6511 default build must answer {} without touching the bridge");
    readClient.join();

    auto resetReply = new Reply();
    auto resetClient = request(port, "POST", "/api/frames/reset", resetReply);
    assert(waitUntil(() => atomicLoad(resetReply.done)),
        "6511 default POST /api/frames/reset did not answer");
    assert(resetReply.wire.canFind("HTTP/1.1 200 OK"));
    assert(body(resetReply.wire) == `{"status":"ok"}`,
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
    assert(waitUntil(() => atomicLoad(reply.done)));
    auto expected = probe.snapshot();
    assert(reply.wire.canFind("HTTP/1.1 200 OK")
        && reply.wire.canFind("Content-Type: application/json"));
    assert(body(reply.wire) == expected.toJson()
        && body(reply.wire).canFind(`"frameCount":3`),
        "6511 perf build must serve /api/frames through the owner bridge");
    client.join();
}

version (PerfProbe) unittest { // P-2/P-4: timeout drops the entire reset
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    server.setFramesBudgetForTest(100.msecs);
    auto bridge = server.framesBridgeForTest();
    FrameProbe probe;
    seed(probe);

    auto reply = new Reply();
    auto client = request(port, "POST", "/api/frames/reset", reply);
    assert(waitUntil(() => atomicLoad(reply.done)));
    assert(reply.wire.canFind("HTTP/1.1 504 Gateway Timeout"));
    assert(body(reply.wire) == `{"error":"timeout waiting for main thread"}`);
    assert(probe.stats().frameCount == 3,
        "6511 timed-out reset changed the probe before service");

    foreach (_; 0 .. 3) server.tickAll();
    assert(probe.stats().frameCount == 3,
        "6511 expired reset was applied by a later generic drain");
    assert(bridge.claimPendingForTest() == 1,
        "6511 expired claimed reset disappeared before its owner tick");
    server.tickFrames(probe);
    assert(probe.stats().frameCount == 3,
        "6511 expired reset was applied on a later frame");
    assert(bridge.claimPendingForTest() == 0,
        "6511 owner tick did not discard the expired reset");

    probe.beginFrame();
    probe.addPhase(Phase.draw, 444);
    probe.endFrame();
    server.tickFrames(probe);
    FrameRec[4] recent;
    assert(probe.copyRecent(recent[]) == 4
        && probe.stats().frameCount == 4,
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
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    auto stopper = new Thread({ server.stop(); });
    stopper.isDaemon = true;
    stopper.start();
    assert(waitUntil(() => !stopper.isRunning));
    assert(waitUntil(() => atomicLoad(reply.done)));
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

version (PerfProbe) unittest { // P-5/P-6: reset boundary then full next frame
    immutable port = freePort();
    auto server = startedServer(port);
    scope(exit) if (server.running) server.stop();
    auto bridge = server.framesBridgeForTest();
    FrameProbe probe;
    seed(probe);

    auto resetReply = new Reply();
    auto resetClient = request(port, "POST", "/api/frames/reset", resetReply);
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    probe.beginFrame();
    probe.addPhase(Phase.draw, 111);
    probe.endFrame();
    FrameRec[4] beforeReset;
    assert(probe.copyRecent(beforeReset[]) == 4
        && probe.stats().frameCount == 4,
        "6511 reset-boundary premise must include the just-finished frame");
    server.tickFrames(probe);
    assert(waitUntil(() => atomicLoad(resetReply.done)));
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
    assert(waitUntil(() => bridge.claimPendingForTest() == 1));
    server.tickFrames(probe);
    assert(waitUntil(() => atomicLoad(readReply.done)));
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
    assert(!allTick.canFind("tickFrames")
        && !allTick.canFind("framesBridge"));
    immutable ownerTick = bodyAt(source,
        "public void tickFrames(ref FrameProbe probe)");
    assert(ownerTick.canFind("framesBridge.tickClaimed("));
    assert(raw.canFind("version (PerfProbe) private enum Answered kFramesAnswered = Answered.mainThread;")
        && raw.canFind("else                private enum Answered kFramesAnswered = Answered.httpThread;"));
    assert(raw.canFind(`RouteSpec("/api/frames/reset",         "POST", Match.exact,  kFramesAnswered`)
        && raw.canFind(`RouteSpec("/api/frames",               "GET",  Match.exact,  kFramesAnswered`));

    size_t files;
    foreach (_; dirEntries(buildPath(root, "source"), "*.d", SpanMode.depth))
        ++files;
    assert(files >= 500, "6511 source census population fell below 500 modules");
}
