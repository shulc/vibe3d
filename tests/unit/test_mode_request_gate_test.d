// Task 6790: every test-mode gate is exercised through both request
// transports. The aggregate keeps all route/transport verdicts visible when
// one production condition is mutated; D's default runner would otherwise
// stop this module at the first failed assert.
module tests.unit.test_mode_request_gate_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_server : HttpRequestContext, HttpResponse, HttpServer,
    InProcessHttpTransport;
import std.algorithm : canFind;
import std.conv : to;
import std.format : format;
import std.socket : InternetAddress, Socket, SocketOption, SocketOptionLevel,
    TcpSocket;
import std.string : indexOf, join;

private enum TransportKind { inProcess, socket }

private struct Observation
{
    int status;
    string body;
}

private final class AsyncWire
{
    shared bool done;
    string wire;
    string failure;
}

private final class AsyncResponse
{
    shared bool done;
    HttpResponse response;
    string failure;
}

private bool waitUntil(bool delegate() predicate,
                       Duration budget = 2.seconds)
{
    immutable deadline = MonoTime.currTime + budget;
    while (!predicate()) {
        if (MonoTime.currTime >= deadline) return false;
        Thread.sleep(1.msecs);
    }
    return true;
}

private ushort freePort()
{
    auto socket = new TcpSocket();
    scope(exit) socket.close();
    socket.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) socket.localAddress).port;
}

private Thread requestSocket(ushort port, string method, string path,
                             string body_, AsyncWire reply)
{
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
            if (socket is null)
                throw new Exception("server did not accept connection");
            scope(exit) socket.close();
            socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                             5.seconds);
            socket.send(method ~ " " ~ path ~ " HTTP/1.1\r\n"
                      ~ "Host: 127.0.0.1\r\nContent-Length: "
                      ~ to!string(body_.length) ~ "\r\n"
                      ~ "Connection: close\r\n\r\n" ~ body_);
            ubyte[4096] buffer;
            for (;;) {
                immutable n = socket.receive(buffer[]);
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

private Observation observationFromWire(string wire)
{
    immutable bodyAt = wire.indexOf("\r\n\r\n");
    assert(wire.length >= 12 && wire[0 .. 9] == "HTTP/1.1 "
        && bodyAt >= 0,
        "6790 socket response was not a complete HTTP/1.1 message: " ~ wire);
    return Observation(wire[9 .. 12].to!int,
                       wire[bodyAt + 4 .. $]);
}

private final class GateFixture
{
    ushort port;
    HttpServer server;
    InProcessHttpTransport inProcess;

    this(bool listen)
    {
        port = freePort();
        server = new HttpServer(port);
        server.setCommandHandler((string id, string paramsJson,
                                  bool interactive) {});
        server.markProvidersWired();
        server.tickAll();
        inProcess = new InProcessHttpTransport(server);
        if (listen) {
            server.start();
            assert(waitUntil(() => server.running),
                "6790 socket fixture did not start");
        }
    }

    void close()
    {
        if (server.running) server.stop();
    }

    Observation request(TransportKind transport, string method, string path,
                        string body_)
    {
        if (transport == TransportKind.inProcess) {
            auto response = inProcess.request(method, path, body_);
            return Observation(response.statusCode, response.body);
        }

        auto reply = new AsyncWire();
        auto client = requestSocket(port, method, path, body_, reply);
        scope(exit) {
            if (client.isRunning) {
                if (server.running) server.stop();
                client.join();
            }
        }
        assert(waitUntil({
            server.tickAll();
            return atomicLoad(reply.done);
        }, 5.seconds),
            "6790 socket request did not finish: " ~ method ~ " " ~ path);
        client.join();
        assert(reply.failure.length == 0,
            "6790 socket request failed: " ~ reply.failure);
        return observationFromWire(reply.wire);
    }
}

private struct GateCase
{
    string name;
    string method;
    string path;
    string body;
    int admittedStatus;
    string admittedBodyNeedle;
}

private immutable GateCase[] kGateCases = [
    GateCase("mesh-planes", "GET", "/api/mesh/planes", "", 500,
             "mesh-planes provider not set"),
    GateCase("cache-rebuilds", "GET", "/api/cache/rebuilds", "", 200,
             `"snapGridBuilds":`),
    GateCase("gc-commands", "GET", "/api/gc/commands", "", 200,
             `"commands":`),
    GateCase("changes", "GET", "/api/changes", "", 200,
             `"flushCount":`),
    GateCase("viewport-frame", "GET",
             "/api/viewport/probe?target=frame", "", 500,
             "viewport-probe provider not set"),
    GateCase("subpatch-hold", "POST", "/api/subpatch/hold", `{}`, 500,
             "subpatch-hold action not installed"),
    GateCase("test-layer", "POST", "/api/test/layer", `{}`, 200,
             "inject-layer handler not set"),
    GateCase("command-ui", "POST", "/api/command?origin=ui",
             `{"id":"task6790.probe","params":{}}`, 200,
             `"status":"ok"`),
    GateCase("play-events", "POST", "/api/play-events", `{}`, 400,
             "Failed to parse events"),
];

private string[] checkGateCase(GateFixture fixture, GateCase gate)
{
    string[] failures;
    foreach (transport; [TransportKind.inProcess, TransportKind.socket]) {
        immutable transportName = transport == TransportKind.inProcess
            ? "in-process" : "socket";
        try {
            fixture.server.setTestMode(false);
            immutable denied = fixture.request(
                transport, gate.method, gate.path, gate.body);
            assert(denied.status == 403,
                format("6790 %s/%s false-mode gate: expected 403, found %d; %s",
                       gate.name, transportName, denied.status, denied.body));
        } catch (Throwable error) {
            failures ~= error.msg;
        }
        try {
            fixture.server.setTestMode(true);
            immutable admitted = fixture.request(
                transport, gate.method, gate.path, gate.body);
            assert(admitted.status == gate.admittedStatus
                && admitted.body.canFind(gate.admittedBodyNeedle),
                format("6790 %s/%s true-mode control: expected downstream "
                     ~ "status %d with `%s`, found %d; %s",
                       gate.name, transportName,
                       gate.admittedStatus, gate.admittedBodyNeedle,
                       admitted.status, admitted.body));
        } catch (Throwable error) {
            failures ~= error.msg;
        }
    }
    return failures;
}

unittest // nine independently reachable gates, two transports each
{
    auto fixture = new GateFixture(true);
    scope(exit) fixture.close();
    string[] failures;
    foreach (gate; kGateCases)
        failures ~= checkGateCase(fixture, gate);
    assert(failures.length == 0,
        "6790 request test-mode gate matrix failed:\n" ~ failures.join("\n"));
}

unittest // dispatch always replaces a carried context with server state
{
    auto fixture = new GateFixture(false);

    fixture.server.setTestMode(false);
    auto carriedTrue = fixture.server.handleRequestWithContextForTest(
        "GET", "/api/changes", HttpRequestContext(true));
    assert(carriedTrue.statusCode == 403,
        "6790 dispatch snapshot must replace carried testMode=true with "
        ~ "server testMode=false (got "
        ~ carriedTrue.statusCode.to!string ~ ")");

    fixture.server.setTestMode(true);
    auto carriedFalse = fixture.server.handleRequestWithContextForTest(
        "GET", "/api/changes", HttpRequestContext(false));
    assert(carriedFalse.statusCode == 200,
        "6790 dispatch snapshot must replace carried testMode=false with "
        ~ "server testMode=true (got "
        ~ carriedFalse.statusCode.to!string ~ ")");
}

unittest // the non-test arms of both conjunctions remain reachable
{
    auto fixture = new GateFixture(false);

    auto ordinaryProbe = fixture.inProcess.request(
        "GET", "/api/viewport/probe", "");
    assert(ordinaryProbe.statusCode == 500
        && ordinaryProbe.body.canFind("viewport-probe provider not set"),
        "6790 target!=frame outside test mode must bypass only the frame "
        ~ "gate (got " ~ ordinaryProbe.statusCode.to!string ~ "; "
        ~ ordinaryProbe.body ~ ")");

    auto ordinaryCommand = fixture.inProcess.request(
        "POST", "/api/command", `{"id":"task6790.probe","params":{}}`);
    assert(ordinaryCommand.statusCode == 200
        && ordinaryCommand.body == `{"status":"ok"}`,
        "6790 wantUi=false outside test mode must bypass only the UI-origin "
        ~ "gate (got " ~ ordinaryCommand.statusCode.to!string ~ "; "
        ~ ordinaryCommand.body ~ ")");
}

unittest // route null gate has its own observable verdict
{
    auto fixture = new GateFixture(false);
    fixture.server.setTestMode(true);
    auto response = fixture.inProcess.request(
        "POST", "/api/subpatch/hold", `{}`);
    assert(response.statusCode == 500
        && response.body == `{"error":"subpatch-hold action not installed"}`,
        "6790 subpatch-hold route null gate changed: " ~ response.body);
}

unittest // named action completes in the current web dispatch, without a pump
{
    auto fixture = new GateFixture(false);
    int calls;
    fixture.server.setSubpatchHoldAction((long ms, long ceilingMs) {
        ++calls;
        return format(`{"status":"ok","ms":%d,"ceilingMs":%d}`,
                      ms, ceilingMs);
    });
    fixture.server.setTestMode(true);
    // No tickAll occurs between this request and the assertions. If the web
    // channel queued the action for a later frame, it could not return these
    // bytes and the call count would remain zero.
    auto response = fixture.inProcess.request(
        "POST", "/api/subpatch/hold", `{"ms":7,"ceilingMs":11}`);
    assert(response.statusCode == 200 && calls == 1
        && response.body == `{"status":"ok","ms":7,"ceilingMs":11}`,
        "6790 subpatch-hold web action waited for a later host frame or "
        ~ "lost its response: " ~ response.body);
}

unittest // service null gate is distinct from the route's earlier null gate
{
    auto fixture = new GateFixture(false);
    fixture.server.setSubpatchHoldAction((long, long) {
        return `{"status":"unexpected-action"}`;
    });
    fixture.server.setTestMode(true);

    auto reply = new AsyncResponse();
    auto client = new Thread({
        try reply.response = fixture.inProcess.request(
            "POST", "/api/subpatch/hold", `{}`);
        catch (Throwable error) reply.failure = error.msg;
        atomicStore(reply.done, true);
    });
    client.isDaemon = true;
    client.start();
    scope(exit) {
        if (client.isRunning) {
            fixture.server.tickAll();
            client.join();
        }
    }

    assert(waitUntil(() => fixture.server.subpatchHoldPendingForTest()
                           || atomicLoad(reply.done)),
        "6790 subpatch-hold service gate setup never reached the bridge queue");
    assert(fixture.server.subpatchHoldPendingForTest()
        && !atomicLoad(reply.done),
        "6790 subpatch-hold service gate setup did not stop between route "
        ~ "and service");
    fixture.server.setSubpatchHoldAction(null);
    fixture.server.tickAll();
    assert(waitUntil(() => atomicLoad(reply.done)),
        "6790 subpatch-hold service null gate did not answer");
    client.join();
    assert(reply.failure.length == 0 && reply.response.statusCode == 500
        && reply.response.body
            == `{"error":"subpatch-hold action unavailable during service"}`,
        "6790 subpatch-hold service null gate changed: "
        ~ reply.failure ~ (reply.response is null ? "<null>" : reply.response.body));
}
