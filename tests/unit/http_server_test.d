module tests.unit.http_server_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_server : BridgeResultKind, HttpRequest, HttpResponse, HttpServer,
    InProcessHttpTransport, MainThreadBridge;
import std.algorithm : canFind;
import std.conv : to;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, TcpSocket;
import std.string : indexOf;

private final class AsyncResponse {
    shared bool done;
    HttpResponse response;
    string wire;
    string failure;
}

private bool waitUntil(bool delegate() predicate,
                       Duration budget = 2.seconds) {
    immutable deadline = MonoTime.currTime + budget;
    while (!predicate()) {
        if (MonoTime.currTime >= deadline) return false;
        Thread.sleep(1.msecs);
    }
    return true;
}

private ushort freePort() {
    auto socket = new TcpSocket();
    scope(exit) socket.close();
    socket.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) socket.localAddress).port;
}

private Thread requestInProcess(InProcessHttpTransport transport,
                                string method, string path, string body_,
                                AsyncResponse reply) {
    auto thread = new Thread({
        try reply.response = transport.request(method, path, body_);
        catch (Throwable error) reply.failure = error.msg;
        atomicStore(reply.done, true);
    });
    thread.isDaemon = true;
    thread.start();
    return thread;
}

private Thread requestSocket(ushort port, string method, string path,
                             string body_, AsyncResponse reply) {
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
                             5.seconds);
            socket.send(method ~ " " ~ path ~ " HTTP/1.1\r\n"
                      ~ "Host: 127.0.0.1\r\nContent-Length: "
                      ~ to!string(body_.length) ~ "\r\n"
                      ~ "Connection: close\r\n\r\n" ~ body_);
            ubyte[4096] buffer;
            for (;;) {
                auto n = socket.receive(buffer[]);
                if (n <= 0) break;
                reply.wire ~= cast(string) buffer[0 .. n].idup;
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

private string responseBody(string wire) {
    immutable split = wire.indexOf("\r\n\r\n");
    assert(split >= 0, "6750 HTTP response has no body boundary: " ~ wire);
    return wire[split + 4 .. $];
}

private HttpResponse dispatch(InProcessHttpTransport transport, HttpRequest request)
{
    return transport.request(request.method, request.path, request.body);
}

// Task 0615: test-only routes stay forbidden outside test mode and reach their
// handler/provider branches inside it. This moved here once task 6720 exposed
// the dispatcher through a reusable in-process transport.
unittest {
    auto srv = new HttpServer();                // testMode defaults false
    auto transport = new InProcessHttpTransport(srv);
    // Task 1740: `handleRequest` now refuses every `/api/*` route with 503
    // until the server is ready, and that gate sits ABOVE this one. Lift it
    // first — a 503 here would be a true answer to a different question and
    // would say nothing about the testMode gate this block exists to pin.
    srv.markProvidersWired();
    srv.tickAll();
    auto req = new HttpRequest("POST", "/api/test/layer", "HTTP/1.1");
    req.body = `{"kind":"empty"}`;

    auto resp = dispatch(transport, req);
    assert(resp.statusCode == 403,
        "blocker 1: /api/test/layer must 403 outside --test mode, exactly "
        ~ "like /api/changes and /api/play-events (got "
        ~ to!string(resp.statusCode) ~ ")");

    auto frameProbe = new HttpRequest(
        "GET", "/api/viewport/probe?target=frame", "HTTP/1.1");
    auto frameOutsideTest = dispatch(transport, frameProbe);
    assert(frameOutsideTest.statusCode == 403,
        "target=frame must refuse outside --test, where GL_BACK after swap "
        ~ "has no defined completed-frame meaning (got "
        ~ to!string(frameOutsideTest.statusCode) ~ ": "
        ~ frameOutsideTest.body ~ ")");

    // With testMode on, the gate must NOT block it — the request should
    // fall through to the (unset-handler) branch instead of another
    // refusal, proving this is a testMode gate and not an unconditional one.
    srv.setTestMode(true);
    auto resp2 = dispatch(transport, req);
    assert(resp2.statusCode == 200,
        "with testMode on, /api/test/layer must pass the gate (got "
        ~ to!string(resp2.statusCode) ~ ")");
    assert(resp2.body.canFind("handler not set"),
        "with no handler installed this must reach the null-handler "
        ~ "branch, not another refusal: " ~ resp2.body);

    auto badProbe = new HttpRequest(
        "GET", "/api/viewport/probe?target=not-a-target", "HTTP/1.1");
    auto badProbeResp = dispatch(transport, badProbe);
    assert(badProbeResp.statusCode == 400
        && badProbeResp.body.canFind("unknown viewport probe target"),
        "an unknown viewport probe target must fail explicitly instead of "
        ~ "falling through to the cell path (got "
        ~ to!string(badProbeResp.statusCode) ~ ": "
        ~ badProbeResp.body ~ ")");

    auto frameInsideTest = dispatch(transport, frameProbe);
    assert(frameInsideTest.statusCode == 500
        && frameInsideTest.body.canFind("provider not set"),
        "inside --test, target=frame must pass its mode gate and reach the "
        ~ "provider path (got " ~ to!string(frameInsideTest.statusCode)
        ~ ": " ~ frameInsideTest.body ~ ")");
}

// Task 1740: readiness is server-wide, requires both provider wiring and one
// bridge drain, lifts afterward, and gates only /api paths.
unittest {
    import std.algorithm : canFind;

    auto srv = new HttpServer();
    auto transport = new InProcessHttpTransport(srv);
    srv.setTestMode(true);   // so cell 4's path is not refused for other reasons

    assert(!srv.ready(),
        "1740: a freshly constructed server must not claim readiness — "
        ~ "nothing has been wired and no frame has drained the bridges");

    auto cmd = new HttpRequest("POST", "/api/command", "HTTP/1.1");
    cmd.body = `{"id":"vibe3d.readiness.probe","params":{}}`;
    auto r1 = dispatch(transport, cmd);
    assert(r1.statusCode == 503,
        "1740 cell 1: before readiness /api/command must answer 503, not a "
        ~ "200 carrying `command handler not set` — a probe has to tell "
        ~ "'still starting' from 'refused' by the CODE (got "
        ~ to!string(r1.statusCode) ~ ": " ~ r1.body ~ ")");
    assert(!r1.body.canFind("command handler not set"),
        "1740 cell 1: the old body must be gone from the wire, or callers "
        ~ "keep matching on it and there are two readiness signals again");

    auto cam = new HttpRequest("GET", "/api/camera", "HTTP/1.1");
    auto r2 = dispatch(transport, cam);
    assert(r2.statusCode == 503,
        "1740 cell 2: the gate is per-server — an httpThread route must give "
        ~ "the same 503 as a bridged one before readiness (got "
        ~ to!string(r2.statusCode) ~ ")");

    // Cell 3 — and it needs BOTH halves of the predicate, so check that each
    // alone is insufficient. Wiring without a drained frame is exactly the
    // state in which `/api/command` used to spin 5 s and return a timeout
    // body: a third "not ready" shape, which is what this refuses to have.
    srv.markProvidersWired();
    assert(!srv.ready(),
        "1740 cell 3a: providers wired is NOT ready — until the main loop has "
        ~ "drained the bridges once, a bridged request times out instead of "
        ~ "being serviced");
    assert(dispatch(transport, cmd).statusCode == 503,
        "1740 cell 3a: and the gate must still stand in that state");

    srv.tickAll();
    assert(srv.ready(), "1740 cell 3b: wired + drained is ready");
    auto r3 = dispatch(transport, cam);
    assert(r3.statusCode != 503,
        "1740 cell 3b: the gate must LIFT — a gate that never lifts satisfies "
        ~ "cells 1 and 2 and is useless (got " ~ to!string(r3.statusCode) ~ ")");

    // Cell 4 — scope. Checked on a NOT-ready server, which is the only state
    // in which the gate can be observed at all.
    auto fresh = new HttpServer();
    auto freshTransport = new InProcessHttpTransport(fresh);
    auto root = new HttpRequest("GET", "/", "HTTP/1.1");
    auto r4 = dispatch(freshTransport, root);
    assert(r4.statusCode != 503,
        "1740 cell 4: the gate is scoped to /api/* — refusing the index page "
        ~ "too would make 'is anything alive on this port' unanswerable, "
        ~ "which is the one question the 503 exists to keep answerable (got "
        ~ to!string(r4.statusCode) ~ ")");
}

// Task 0652: a silent accepted peer cannot park the serial accept loop forever;
// the next complete request is answered and abandoning the silent peer is loud.
// The oracle is the received status line and body, never connect() succeeding.
unittest {
    import core.time    : msecs, seconds;
    import core.thread  : Thread;
    import std.algorithm: canFind;
    import log          : snapshot, LogLevel;

    // Take a free port the way the OS offers one: bind ephemeral, read the
    // number back, release it.
    ushort freePort;
    {
        auto probe = new TcpSocket();
        probe.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
        freePort = (cast(InternetAddress) probe.localAddress).port;
        probe.close();
    }

    auto srv = new HttpServer(freePort);
    // Production budgets are 5 s / 15 s; shrink them so this costs ~0.5 s.
    srv.clientIoTimeout    = 500.msecs;
    srv.clientReadDeadline = 1500.msecs;
    // Task 1740: without this the well-behaved peer below is answered 503 by
    // the readiness gate, not by the route. It would still be an ANSWER, so
    // the accept-loop property under test would survive — but the assertion
    // reads the status line, so it would fail for a reason that has nothing
    // to do with 0652. Declare the server ready; this block is about the
    // per-connection I/O budget, not about startup order.
    srv.markProvidersWired();
    srv.tickAll();
    srv.start();
    scope(exit) srv.stop();

    Socket connectOnce() {
        auto s = new TcpSocket();
        try { s.connect(new InternetAddress("127.0.0.1", freePort)); }
        catch (Exception) { s.close(); return null; }
        return s;
    }

    Socket silent;
    foreach (_; 0 .. 200) {
        silent = connectOnce();
        if (silent !is null) break;
        Thread.sleep(10.msecs);
    }
    assert(silent !is null, "0652: the test server never started listening");
    scope(exit) silent.close();
    // `silent` now holds an accepted connection and deliberately says nothing.

    auto client = connectOnce();
    assert(client !is null, "0652: the well-behaved peer could not connect");
    scope(exit) client.close();
    client.send("GET /api/ping HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    // Bound the read so a regression FAILS here rather than hanging the suite.
    client.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 10.seconds);

    string reply;
    ubyte[2048] buf;
    for (;;) {
        auto n = client.receive(buf[]);
        if (n <= 0) break;
        reply ~= cast(string) buf[0 .. n].idup;
    }

    assert(reply.canFind("HTTP/1.1 200 OK"),
        "0652: a silent peer must not stop a well-behaved peer being ANSWERED"
        ~ " — expected a 200 status line, got: "
        ~ (reply.length ? reply : "<no answer at all>"));
    assert(reply.canFind(`{"status": "ok"}`),
        "0652: the answer must carry the /api/ping body, got: " ~ reply);

    bool saidSoOutLoud = false;
    foreach (e; snapshot()) {
        if (e.level == LogLevel.Warn && e.subsystem == "http"
            && e.msg.canFind("WITHOUT a response")) { saidSoOutLoud = true; break; }
    }
    assert(saidSoOutLoud,
        "0652: closing an accepted connection without answering it must be"
        ~ " reported — an unreported give-up is invisible to the caller,"
        ~ " whose connect() succeeded and whose request never returns");
}

// Task 6750 pins the native timeout contract beside the new single-threaded
// branch. These are three independent claims: the ordinary default, the
// command override, and both call sites that opt into the override.
unittest {
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : count;

    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable source = readText(buildPath(root, "source", "http_server.d"));
    assert(source.count("bool submitAndWait(int maxIters = 2500) {") == 1,
        "6750 native spin pin: submitAndWait must retain its 2500-iteration default");
    assert(source.count("enum int kCommandBridgeMaxIters = 60_000;") == 1,
        "6750 native spin pin: the command bridge must retain its 60_000-iteration override");
    assert(source.count("commandBridge.submitAndWait(kCommandBridgeMaxIters)") == 2,
        "6750 native spin pin: both command submit sites must retain the long override");

    auto fresh = new HttpServer();
    assert(fresh.unwiredEndpoints().length == 39,
        "6750 readiness pin: expected all 39 provider/handler slots on a fresh server");
}

unittest { // submitAndWait is identity in an in-process single-thread channel
    int calls;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setPathQueryProvider((float t) {
        calls++;
        return t > 0.24f && t < 0.26f
            ? `{"surface":"submitAndWait"}` : `{"surface":"wrong-t"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();
    assert(waitUntil(() => server.running),
        "6750 submitAndWait parity: socket server did not start");

    auto socketReply = new AsyncResponse();
    auto socketClient = requestSocket(port, "POST", "/api/path",
                                      `{"t":0.25}`, socketReply);
    assert(waitUntil(() {
        server.tickAll();
        return atomicLoad(socketReply.done);
    }), "6750 submitAndWait parity: socket request needed tickAll but did not finish");
    socketClient.join();
    assert(socketReply.failure.length == 0
        && socketReply.wire.canFind("HTTP/1.1 200 OK"),
        "6750 submitAndWait parity: socket request failed: "
        ~ socketReply.failure ~ socketReply.wire);

    auto response = (new InProcessHttpTransport(server)).request(
        "POST", "/api/path", `{"t":0.25}`);
    assert(calls == 2,
        "6750 submitAndWait parity: the socket and in-process providers did not run once each");
    assert(response.statusCode == 200
        && response.body == `{"surface":"submitAndWait"}`,
        "6750 submitAndWait identity: the single-threaded route did not return its provider bytes");
    assert(response.body == responseBody(socketReply.wire),
        "6750 submitAndWait transport parity: /api/path bodies differ between socket and in-process transports");
}

unittest { // a foreign in-process submitAndWait uses the queue
    shared int calls;
    auto server = new HttpServer();
    server.setPathQueryProvider((float) {
        atomicStore(calls, atomicLoad(calls) + 1);
        return `{"surface":"queued-submitAndWait"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    auto transport = new InProcessHttpTransport(server);
    auto queued = new AsyncResponse();
    auto client = requestInProcess(transport, "POST", "/api/path",
                                   `{"t":0.25}`, queued);
    assert(waitUntil(() => server.pathPendingForTest()
                           || atomicLoad(queued.done)),
        "6750 foreign submitAndWait queue: request neither queued nor completed");
    assert(server.pathPendingForTest() && !atomicLoad(queued.done)
        && atomicLoad(calls) == 0,
        "6750 foreign submitAndWait queue: a non-tick thread serviced /api/path inline");
    server.tickAll();
    assert(waitUntil(() => atomicLoad(queued.done)),
        "6750 foreign submitAndWait queue: tickAll did not complete /api/path");
    client.join();
    assert(queued.failure.length == 0
        && queued.response.statusCode == 200
        && queued.response.body == `{"surface":"queued-submitAndWait"}`
        && atomicLoad(calls) == 1,
        "6750 foreign submitAndWait queue: queued /api/path response changed: "
        ~ queued.failure);
}

unittest { // direct dispatch on the tick thread still needs the channel marker
    int calls;
    auto server = new HttpServer();
    server.setPathBridgeMaxItersForTest(0);
    server.setPathQueryProvider((float) {
        calls++;
        return `{"surface":"unexpected-inline"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    auto response = server.handleRequestForTest(
        "POST", "/api/path", `{"t":0.25}`);
    assert(server.pathPendingForTest() && calls == 0
        && response.statusCode == 500
        && response.body.canFind("timeout waiting for main thread"),
        "6750 submitAndWait channel gate: direct tick-thread dispatch bypassed the queue without a transport marker");
    server.tickAll();
    assert(calls == 1,
        "6750 submitAndWait channel gate: queued direct dispatch was not serviceable");
}

unittest { // submitOwned is identity in an in-process single-thread channel
    int calls;
    auto server = new HttpServer();
    server.setModelBudgetForTest(5.msecs);
    server.setDetailedModelDataProvider(() {
        calls++;
        return `{"surface":"submitOwned"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    auto response = (new InProcessHttpTransport(server)).request(
        "GET", "/api/model", "");
    assert(calls == 1,
        "6750 submitOwned identity: the provider did not run exactly once");
    assert(response.statusCode == 200
        && response.body == `{"surface":"submitOwned"}`,
        "6750 submitOwned identity: the single-threaded route did not return its owned bytes");
    auto trace = server.modelOwnedTraceForTest();
    assert(trace.length == 2
        && trace[0].kind == BridgeResultKind.submitted
        && trace[1].kind == BridgeResultKind.completed,
        "6750 submitOwned trace: inline completion was not recorded");

    server.modelBridgeForTest().notifyStopping();
    auto stopped = (new InProcessHttpTransport(server)).request(
        "GET", "/api/model", "");
    assert(calls == 1,
        "6750 submitOwned stopping: inline service ran after stopping");
    trace = server.modelOwnedTraceForTest();
    assert(stopped.statusCode == 500
        && trace.length == 4
        && trace[2].kind == BridgeResultKind.submitted
        && trace[3].kind == BridgeResultKind.stopping,
        "6750 submitOwned stopping: the inline branch lost its stopping result");
}

unittest { // direct submitOwned dispatch also needs the channel marker
    int calls;
    auto server = new HttpServer();
    server.setModelBudgetForTest(Duration.zero);
    server.setDetailedModelDataProvider(() {
        calls++;
        return `{"surface":"unexpected-inline"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    auto response = server.handleRequestForTest("GET", "/api/model");
    assert(server.modelOwnedPendingForTest() == 1 && calls == 0
        && response.statusCode == 500
        && response.body.canFind("timeout waiting for main thread"),
        "6750 submitOwned channel gate: direct tick-thread dispatch bypassed the queue without a transport marker");
    server.tickAll();
    assert(calls == 1,
        "6750 submitOwned channel gate: queued direct dispatch was not serviceable");
}

unittest { // a claimed bridge must not swallow Error
    auto server = new HttpServer();
    auto claimed = new MainThreadBridge!(int, int)(server,
        (ref int, ref int) { throw new Error("6750 claimed Error sentinel"); });
    server.setPathQueryProvider((float) {
        claimed.withClaimedServiceReadyForTest({
            cast(void) claimed.submitClaimed(0, 1.seconds);
        });
        return `{"surface":"unreachable"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    Throwable escaped;
    try {
        cast(void) (new InProcessHttpTransport(server)).request(
            "POST", "/api/path", `{"t":0.25}`);
    } catch (Throwable error) {
        escaped = error;
    }
    assert(escaped !is null && escaped.msg == "6750 claimed Error sentinel",
        "6750 claimed Error boundary: submitClaimed swallowed an Error as a bridge result");
}

unittest { // direct submitClaimed dispatch also needs the channel marker
    import perf_probe : FrameWorkProbe;

    auto server = new HttpServer();
    server.setFrameCountsBudgetForTest(Duration.zero);
    server.markProvidersWired();
    server.tickAll();
    auto response = server.handleRequestForTest("GET", "/api/frames/counts");
    assert(server.frameCountsClaimPendingForTest() == 1
        && response.statusCode == 504
        && response.body == `{"error":"timeout waiting for main thread"}`,
        "6750 submitClaimed channel gate: direct tick-thread dispatch bypassed the queue without a transport marker");
    FrameWorkProbe probe;
    server.tickFrameCounts(probe);
}

unittest { // submitClaimed distinguishes owner absence and preserves the frame fence
    import perf_probe : FrameWorkProbe;

    auto server = new HttpServer();
    server.setFrameCountsBudgetForTest(5.msecs);
    server.markProvidersWired();
    server.tickAll();
    auto transport = new InProcessHttpTransport(server);
    auto beforeOwnerReset = transport.request(
        "POST", "/api/frames/counts/reset", "");
    assert(beforeOwnerReset.statusCode == 503
        && beforeOwnerReset.body == `{"error":"frame-count owner unavailable"}`,
        "6750 frame-count reset owner gate: an unregistered owner must return 503");
    auto beforeOwner = transport.request("GET", "/api/frames/counts", "");
    assert(beforeOwner.statusCode == 503
        && beforeOwner.body == `{"error":"frame-count owner unavailable"}`,
        "6750 submitClaimed owner gate: an unregistered owner must report its own kind and body");

    auto timedOut = new AsyncResponse();
    auto timeoutClient = requestInProcess(transport, "GET",
                                          "/api/frames/counts", "", timedOut);
    assert(waitUntil(() => atomicLoad(timedOut.done)),
        "6750 submitClaimed timeout control did not finish");
    timeoutClient.join();
    assert(timedOut.failure.length == 0
        && timedOut.response.statusCode == 504
        && timedOut.response.body == `{"error":"timeout waiting for main thread"}`,
        "6750 submitClaimed timeout control: a real unserviced deadline was not distinct from owner absence");

    FrameWorkProbe probe;
    probe.beginFrame();
    probe.endFrame();
    server.tickFrameCounts(probe);
    HttpResponse response;
    Throwable escaped;
    try {
        response = transport.request("GET", "/api/frames/counts", "");
    } catch (Throwable error) {
        escaped = error;
    }
    assert(escaped is null,
        "6750 claimed owner catch: the owner fence escaped the bridge result mapping: "
        ~ (escaped is null ? "" : escaped.msg));
    assert(response.statusCode == 503
        && response.body == `{"error":"frame-count owner unavailable"}`,
        "6750 claimed owner scope: readiness survived tickFrameCounts return");
    assert(probe.totals().seq == 1,
        "6750 claimed owner fence: an inline request changed the retained owner probe");

    auto bridge = server.frameCountsBridgeForTest();
    bridge.notifyStopping();
    bridge.notifyStarted();
    auto afterRestart = transport.request("GET", "/api/frames/counts", "");
    assert(afterRestart.statusCode == 503
        && afterRestart.body == `{"error":"frame-count owner unavailable"}`,
        "6750 claimed lifecycle: restart retained owner readiness without a new owner tick");
}

version (PerfProbe) unittest { // FrameProbe has the same owner-frame fence
    import perf_probe : FrameProbe;

    auto server = new HttpServer();
    server.markProvidersWired();
    server.tickAll();
    auto transport = new InProcessHttpTransport(server);
    auto beforeOwnerReset = transport.request("POST", "/api/frames/reset", "");
    assert(beforeOwnerReset.statusCode == 503
        && beforeOwnerReset.body == `{"error":"frame probe owner unavailable"}`,
        "6750 frame-probe reset owner gate: an unregistered owner must return 503");
    auto beforeOwnerRead = transport.request("GET", "/api/frames", "");
    assert(beforeOwnerRead.statusCode == 503
        && beforeOwnerRead.body == `{"error":"frame probe owner unavailable"}`,
        "6750 frame-probe read owner gate: an unregistered owner must return 503");
    FrameProbe probe;
    probe.beginFrame();
    probe.endFrame();
    server.tickFrames(probe);
    auto response = transport.request("GET", "/api/frames", "");
    assert(response.statusCode == 503
        && response.body == `{"error":"frame probe owner unavailable"}`,
        "6750 frame-probe owner scope: readiness survived tickFrames return");
    assert(probe.stats().frameCount == 1,
        "6750 frame-probe owner fence: an inline request changed the retained owner probe");
}

unittest { // foreign in-process callers queue; TLS depth never leaks between requests or threads
    shared int calls;
    shared bool firstSawChannel;
    shared bool queuedSawChannel;
    auto server = new HttpServer();
    server.setDetailedModelDataProvider(() {
        immutable call = atomicLoad(calls) + 1;
        atomicStore(calls, call);
        if (call == 1)
            atomicStore(firstSawChannel,
                        server.singleThreadedChannelForTest());
        else if (call == 2)
            atomicStore(queuedSawChannel,
                        server.singleThreadedChannelForTest());
        return call == 1 ? `{"call":1}` : `{"call":2}`;
    });
    server.markProvidersWired();
    server.tickAll();
    auto transport = new InProcessHttpTransport(server);

    auto first = transport.request("GET", "/api/model", "");
    assert(first.statusCode == 200 && first.body == `{"call":1}`
        && atomicLoad(firstSawChannel),
        "6750 channel depth control: the tick-thread request did not enter the in-process marker");
    assert(!server.singleThreadedChannelForTest(),
        "6750 channel depth release: the tick thread retained its marker after request return");

    auto queued = new AsyncResponse();
    auto client = requestInProcess(transport, "GET", "/api/model", "", queued);
    assert(waitUntil(() => server.modelOwnedPendingForTest() == 1
                           || atomicLoad(queued.done)),
        "6750 foreign in-process queue: request neither queued nor completed");
    assert(server.modelOwnedPendingForTest() == 1
        && !atomicLoad(queued.done),
        "6750 foreign in-process queue: a non-tick thread serviced the bridge inline");
    server.tickAll();
    assert(waitUntil(() => atomicLoad(queued.done)),
        "6750 foreign in-process queue: tickAll did not complete the queued request");
    client.join();
    assert(queued.failure.length == 0
        && queued.response.statusCode == 200
        && queued.response.body == `{"call":2}`,
        "6750 foreign in-process queue: queued response bytes changed: "
        ~ queued.failure);
    assert(!atomicLoad(queuedSawChannel),
        "6750 channel depth isolation: the tick thread observed a prior or foreign request marker");
}

unittest { // tick identity is stable until stop and republished after restart
    shared int calls;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setModelBudgetForTest(5.msecs);
    server.setDetailedModelDataProvider(() {
        atomicStore(calls, atomicLoad(calls) + 1);
        return `{"surface":"restart-owner"}`;
    });
    server.markProvidersWired();
    server.start();
    scope(exit) if (server.running) server.stop();
    assert(waitUntil(() => server.running),
        "6750 tick identity lifecycle: first server start did not finish");

    auto firstOwner = new Thread({ server.tickAll(); });
    firstOwner.start();
    firstOwner.join();

    auto stolen = new AsyncResponse();
    auto contender = new Thread({
        server.tickAll();
        try stolen.response = (new InProcessHttpTransport(server)).request(
            "GET", "/api/model", "");
        catch (Throwable error) stolen.failure = error.msg;
        atomicStore(stolen.done, true);
    });
    contender.start();
    assert(waitUntil(() => atomicLoad(stolen.done)),
        "6750 tick identity lifecycle: contender request did not finish");
    contender.join();
    assert(stolen.failure.length == 0 && stolen.response.statusCode == 500
        && atomicLoad(calls) == 0,
        "6750 tick identity stability: a later tickAll stole the live owner's inline identity");

    server.stop();
    server.start();
    assert(waitUntil(() => server.running),
        "6750 tick identity lifecycle: restarted server did not finish");
    auto restarted = new AsyncResponse();
    auto replacement = new Thread({
        server.tickAll();
        try restarted.response = (new InProcessHttpTransport(server)).request(
            "GET", "/api/model", "");
        catch (Throwable error) restarted.failure = error.msg;
        atomicStore(restarted.done, true);
    });
    replacement.start();
    assert(waitUntil(() => atomicLoad(restarted.done)),
        "6750 tick identity lifecycle: restarted owner request did not finish");
    replacement.join();
    assert(restarted.failure.length == 0
        && restarted.response.statusCode == 200
        && restarted.response.body == `{"surface":"restart-owner"}`
        && atomicLoad(calls) == 1,
        "6750 tick identity restart: stop retained the dead owner's identity");
}
