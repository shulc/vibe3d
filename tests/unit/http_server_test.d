module tests.unit.http_server_test;

import http_server : HttpRequest, HttpResponse, HttpServer,
    InProcessHttpTransport;
import std.algorithm : canFind;
import std.conv : to;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel, TcpSocket;

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
    auto server = new HttpServer();
    server.setPathQueryProvider((float t) {
        calls++;
        return t > 0.24f && t < 0.26f
            ? `{"surface":"submitAndWait"}` : `{"surface":"wrong-t"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    auto response = (new InProcessHttpTransport(server)).request(
        "POST", "/api/path", `{"t":0.25}`);
    assert(calls == 1,
        "6750 submitAndWait identity: the provider did not run exactly once");
    assert(response.statusCode == 200
        && response.body == `{"surface":"submitAndWait"}`,
        "6750 submitAndWait identity: the single-threaded route did not return its provider bytes");
}

unittest { // submitOwned is identity in an in-process single-thread channel
    import core.time : msecs;

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
}

unittest { // submitClaimed is identity after its owner pump has registered
    import core.time : msecs;
    import perf_probe : FrameWorkProbe;
    import std.string : startsWith;

    auto server = new HttpServer();
    server.setFrameCountsBudgetForTest(5.msecs);
    server.markProvidersWired();
    server.tickAll();
    FrameWorkProbe probe;
    probe.beginFrame();
    probe.endFrame();
    server.tickFrameCounts(probe);
    auto response = (new InProcessHttpTransport(server)).request(
        "GET", "/api/frames/counts", "");
    assert(response.statusCode == 200,
        "6750 submitClaimed identity: the registered owner did not answer synchronously");
    assert(response.body.startsWith(`{"frames":1,`),
        "6750 submitClaimed identity: the route did not serialize the owner snapshot: "
        ~ response.body);
}
