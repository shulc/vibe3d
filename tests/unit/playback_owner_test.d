module tests.unit.playback_owner_test;

import bindbc.sdl : KMOD_NONE, SDL_Event, SDL_Keymod, SDL_KEYDOWN,
    SDL_MOUSEBUTTONDOWN, SDL_MOUSEBUTTONUP, SDL_MOUSEMOTION;
import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import eventlog : clearEventPlayerControlsForTest,
    eventPlayerModifierForTest, setEventPlayerClockForTest,
    setEventPlayerCounterForTest, setEventPlayerModifierForTest;
import http_server : HttpServer;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.socket : InternetAddress, Socket, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.string : count, indexOf, startsWith;

private final class Reply {
    shared bool done;
    string wire;
    string failure;
}

private ushort freePort() {
    auto probe = new TcpSocket();
    scope(exit) probe.close();
    probe.bind(new InternetAddress("127.0.0.1", cast(ushort) 0));
    return (cast(InternetAddress) probe.localAddress).port;
}

private size_t threadIdentity() nothrow {
    try return cast(size_t) cast(void*) Thread.getThis();
    catch (Throwable) return 0;
}

private void performRequest(ushort port, string method, string path,
                            string requestBody, Reply reply) {
    try {
        Socket socket;
        foreach (_; 0 .. 400) {
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
        if (socket is null) throw new Exception("5960 server unavailable");
        scope(exit) socket.close();
        socket.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO,
                         10.seconds);
        auto request = method ~ " " ~ path ~ " HTTP/1.1\r\n"
                     ~ "Host: 127.0.0.1\r\nConnection: close\r\n"
                     ~ "Content-Type: text/plain\r\nContent-Length: "
                     ~ requestBody.length.to!string ~ "\r\n\r\n"
                     ~ requestBody;
        socket.send(request);
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
}

private Thread startRequest(ushort port, string method, string path,
                            string requestBody, Reply reply) {
    auto client = new Thread({
        performRequest(port, method, path, requestBody, reply);
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
    server.setTestMode(true);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    assert(waitUntil(() => server.running),
        "5960 server did not start");
}

private string body(Reply reply) {
    assert(reply.failure.length == 0,
        "5960 HTTP client failure: " ~ reply.failure);
    immutable split = reply.wire.indexOf("\r\n\r\n");
    assert(split >= 0, "5960 response has no body: " ~ reply.wire);
    return reply.wire[split + 4 .. $];
}

private JSONValue jsonReply(Reply reply, string status, string cell) {
    assert(reply.wire.startsWith(status ~ "\r\n"),
        cell ~ " status changed: " ~ reply.wire);
    return parseJSON(body(reply));
}

private Reply requestAndTick(HttpServer server, ushort port, string method,
                             string path, string requestBody) {
    auto reply = new Reply();
    auto client = startRequest(port, method, path, requestBody, reply);
    scope(exit) if (client.isRunning) client.join();
    assert(waitUntil(() => path == "/api/play-events/status"
        ? server.playEventsStatusOwnedPendingForTest() == 1
        : server.playEventsOwnedPendingForTest() == 1),
        "5960 request did not reach its owned bridge: " ~ path);
    server.tickAll();
    assert(waitUntil(() => atomicLoad(reply.done)),
        "5960 request did not finish after tickAll: " ~ path);
    client.join();
    return reply;
}

private string aLog() {
    return
        `{"t":0,"type":"VIEWPORT","vpX":0,"vpY":0,"vpW":800,"vpH":600,"fovY":0.785398}` ~ "\n" ~
        `{"t":0,"type":"SDL_MOUSEMOTION","x":10,"y":10,"xrel":1,"yrel":1,"state":0,"mod":64}` ~ "\n" ~
        `{"t":10,"type":"SDL_MOUSEMOTION","x":20,"y":20,"xrel":1,"yrel":1,"state":0,"mod":64}` ~ "\n" ~
        `{"t":100,"type":"SDL_MOUSEMOTION","x":30,"y":30,"xrel":1,"yrel":1,"state":0,"mod":64}` ~ "\n" ~
        `{"t":200,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":30,"y":30,"clicks":1,"mod":64}` ~ "\n" ~
        `{"t":210,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":30,"y":30,"clicks":1,"mod":64}` ~ "\n" ~
        `{"t":220,"type":"SDL_KEYDOWN","sym":97,"scan":4,"mod":0,"repeat":0}`;
}

private string bLog() {
    return
        `{"t":0,"type":"SDL_MOUSEMOTION","x":101,"y":101,"xrel":1,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":0,"type":"SDL_MOUSEMOTION","x":102,"y":102,"xrel":1,"yrel":0,"state":0,"mod":0}` ~ "\n" ~
        `{"t":0,"type":"SDL_KEYDOWN","sym":98,"scan":5,"mod":0,"repeat":0}`;
}

unittest { // U1: POST blocks until acceptance on the tickAll thread
    setEventPlayerClockForTest(0, 1000);
    setEventPlayerModifierForTest(KMOD_NONE);
    scope(exit) clearEventPlayerControlsForTest();
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setEventPlayerSink((SDL_Event*, bool) {});
    startReady(server);
    auto reply = new Reply();
    auto client = startRequest(port, "POST", "/api/play-events", bLog(), reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.playEventsOwnedPendingForTest() == 1
        || atomicLoad(reply.done)),
        "U1 population floor: valid POST never queued");
    Thread.sleep(30.msecs);
    assert(!atomicLoad(reply.done), "U1 POST answered without a main tick");
    assert(server.playbackAcceptCallsForTest() == 0,
        "U1 acceptance ran before the owned service");
    immutable tickThread = threadIdentity();
    assert(tickThread != 0, "U1 tick thread identity is empty");
    server.tickAll();
    assert(waitUntil(() => atomicLoad(reply.done)),
        "U1 POST did not answer after a main tick");
    client.join();
    auto payload = jsonReply(reply, "HTTP/1.1 200 OK", "U1");
    assert(payload["generation"].integer == 1
        && payload["replaced"].integer == 0,
        "U1 first accepted generation must be one and replace nothing");
    assert(server.playbackAcceptCallsForTest() == 1
        && server.playbackAcceptThreadForTest() == tickThread,
        "U1 acceptance did not run exactly once on the tickAll thread");
    server.tickEventPlayer();
    assert(server.playbackStatusForTest().finished,
        "U1 idle-replacement setup did not finish generation one");
    auto idle = requestAndTick(server, port, "POST", "/api/play-events", bLog());
    auto idlePayload = jsonReply(idle, "HTTP/1.1 200 OK", "U1 idle load");
    assert(idlePayload["generation"].integer == 2
        && idlePayload["replaced"].integer == 0,
        "U1 idle acceptance reported a replaced generation");
}

unittest { // U2: status waits behind a sink and then observes one state
    setEventPlayerClockForTest(0, 1000);
    setEventPlayerModifierForTest(KMOD_NONE);
    scope(exit) clearEventPlayerControlsForTest();
    shared size_t delivered;
    shared bool sinkEntered;
    shared bool releaseSink;
    shared bool blockedObserved;
    shared bool statusQueued;
    immutable port = freePort();
    auto server = new HttpServer(port);
    startReady(server);
    immutable log =
        `{"t":50,"type":"SDL_MOUSEMOTION","x":10,"y":10,"xrel":1,"yrel":1,"state":0,"mod":0}` ~ "\n" ~
        `{"t":100,"type":"SDL_MOUSEMOTION","x":20,"y":20,"xrel":1,"yrel":1,"state":0,"mod":0}` ~ "\n" ~
        `{"t":110,"type":"SDL_MOUSEMOTION","x":30,"y":30,"xrel":1,"yrel":1,"state":0,"mod":0}` ~ "\n" ~
        `{"t":120,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":30,"y":30,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":130,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":30,"y":30,"clicks":1,"mod":0}` ~ "\n" ~
        `{"t":140,"type":"SDL_KEYDOWN","sym":97,"scan":4,"mod":0,"repeat":0}`;
    auto accepted = requestAndTick(server, port, "POST", "/api/play-events", log);
    assert(jsonReply(accepted, "HTTP/1.1 200 OK", "U2 load")["generation"].integer == 1,
        "U2 populated load generation changed");
    server.setEventPlayerSink((SDL_Event* event, bool) {
        atomicOp!"+="(delivered, 1);
        if (event.type == SDL_MOUSEMOTION && atomicLoad(delivered) == 1) {
            atomicStore(sinkEntered, true);
            while (!atomicLoad(releaseSink)) Thread.sleep(1.msecs);
        }
    });
    setEventPlayerCounterForTest(50);

    auto status = new Reply();
    auto requester = new Thread({
        while (!atomicLoad(sinkEntered)) Thread.sleep(1.msecs);
        performRequest(port, "GET", "/api/play-events/status", "", status);
    });
    auto releaser = new Thread({
        immutable queued = waitUntil(
            () => server.playEventsStatusOwnedPendingForTest() == 1
                || atomicLoad(status.done))
            && server.playEventsStatusOwnedPendingForTest() == 1;
        atomicStore(statusQueued, queued);
        if (queued) {
            Thread.sleep(30.msecs);
            atomicStore(blockedObserved, !atomicLoad(status.done));
        }
        atomicStore(releaseSink, true);
    });
    requester.start();
    releaser.start();
    scope(exit) {
        atomicStore(releaseSink, true);
        if (releaser.isRunning) releaser.join();
        if (requester.isRunning) requester.join();
        if (server.running) server.stop();
    }
    server.tickEventPlayer();
    releaser.join();
    assert(atomicLoad(statusQueued),
        "U2 status did not queue while sink was blocked");
    assert(atomicLoad(blockedObserved),
        "U2 status answered while main blocked in sink");
    server.tickAll();
    assert(waitUntil(() => atomicLoad(status.done)),
        "U2 status did not answer after the sink returned");
    requester.join();
    auto payload = jsonReply(status, "HTTP/1.1 200 OK", "U2 status");
    assert(atomicLoad(delivered) == 1,
        "U2 population floor: exactly one due event must reach the sink");
    assert(payload["total"].integer == 6
        && payload["remaining"].integer == 5
        && payload["immediateMotions"].integer == 1
        && payload["generation"].integer == 1,
        "U2 status fields did not describe one player state: " ~ payload.toString());
}

unittest { // U3: acceptance frame cannot deliver a t=0 event
    setEventPlayerClockForTest(0, 1000);
    setEventPlayerModifierForTest(KMOD_NONE);
    scope(exit) clearEventPlayerControlsForTest();
    shared size_t delivered;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setEventPlayerSink((SDL_Event*, bool) { atomicOp!"+="(delivered, 1); });
    startReady(server);
    scope(exit) if (server.running) server.stop();
    auto accepted = requestAndTick(server, port, "POST", "/api/play-events", bLog());
    jsonReply(accepted, "HTTP/1.1 200 OK", "U3 load");
    assert(atomicLoad(delivered) == 0, "U3 acceptance tick delivered");
    server.tickEventPlayer();
    assert(atomicLoad(delivered) == 3,
        "U3 next player tick did not deliver the three-event population");
}

unittest { // U4: the playback clock starts at main-thread acceptance
    setEventPlayerClockForTest(0, 1000);
    setEventPlayerModifierForTest(KMOD_NONE);
    scope(exit) clearEventPlayerControlsForTest();
    shared size_t delivered;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setEventPlayerSink((SDL_Event*, bool) { atomicOp!"+="(delivered, 1); });
    startReady(server);
    scope(exit) if (server.running) server.stop();
    auto reply = new Reply();
    auto client = startRequest(port, "POST", "/api/play-events",
        `{"t":50,"type":"SDL_KEYDOWN","sym":97,"scan":4,"mod":0,"repeat":0}`,
        reply);
    scope(exit) if (client.isRunning) client.join();
    assert(waitUntil(() => server.playEventsOwnedPendingForTest() == 1),
        "U4 valid request did not queue at submit counter zero");
    setEventPlayerCounterForTest(100);
    server.tickAll();
    assert(waitUntil(() => atomicLoad(reply.done)), "U4 POST did not answer");
    client.join();
    jsonReply(reply, "HTTP/1.1 200 OK", "U4 load");
    setEventPlayerCounterForTest(120);
    server.tickEventPlayer();
    assert(atomicLoad(delivered) == 0,
        "U4 submit-time clock delivered a 50ms event at accept+20ms");
    setEventPlayerCounterForTest(160);
    server.tickEventPlayer();
    assert(atomicLoad(delivered) == 1,
        "U4 accept-time clock did not deliver at accept+60ms");
}

unittest { // U5: a new accepted generation replaces A without duplicates
    setEventPlayerClockForTest(0, 1000);
    setEventPlayerModifierForTest(KMOD_NONE);
    scope(exit) clearEventPlayerControlsForTest();
    int[] deliveredTypes;
    int[] deliveredX;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setEventPlayerSink((SDL_Event* event, bool) {
        deliveredTypes ~= cast(int)event.type;
        if (event.type == SDL_MOUSEMOTION) deliveredX ~= event.motion.x;
    });
    startReady(server);
    scope(exit) if (server.running) server.stop();
    auto a = requestAndTick(server, port, "POST", "/api/play-events", aLog());
    assert(jsonReply(a, "HTTP/1.1 200 OK", "U5 A")["generation"].integer == 1,
        "U5 A generation changed");
    setEventPlayerCounterForTest(10);
    server.tickEventPlayer();
    assert(deliveredTypes.length == 2 && deliveredX == [10, 20],
        "U5 population floor: A must deliver its first two motions before B");
    setEventPlayerCounterForTest(100);
    auto b = requestAndTick(server, port, "POST", "/api/play-events", bLog());
    auto accepted = jsonReply(b, "HTTP/1.1 200 OK", "U5 B");
    assert(deliveredTypes.length == 2,
        "U5 B acceptance delivered or re-ticked A");
    assert(accepted["generation"].integer == 2
        && accepted["replaced"].integer == 1,
        "U5 replacement identity changed: " ~ accepted.toString());
    server.tickEventPlayer();
    assert(deliveredTypes.length == 5
        && deliveredX == [10, 20, 101, 102]
        && deliveredTypes[$ - 1] == SDL_KEYDOWN,
        "U5 replacement sink sequence was duplicated or out of order");
    auto state = server.playbackStatusForTest();
    assert(state.finished && state.total == 3 && state.remaining == 0
        && state.immediateMotions == 2 && state.generation == 2,
        "U5 status did not count only generation B");
}

unittest { // U6: invalid and empty bodies leave active A untouched
    setEventPlayerClockForTest(0, 1000);
    setEventPlayerModifierForTest(KMOD_NONE);
    scope(exit) clearEventPlayerControlsForTest();
    shared size_t delivered;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setEventPlayerSink((SDL_Event*, bool) { atomicOp!"+="(delivered, 1); });
    startReady(server);
    scope(exit) if (server.running) server.stop();
    auto a = requestAndTick(server, port, "POST", "/api/play-events", aLog());
    jsonReply(a, "HTTP/1.1 200 OK", "U6 A");
    server.tickEventPlayer();
    assert(atomicLoad(delivered) == 1
        && eventPlayerModifierForTest() == cast(SDL_Keymod)64,
        "U6 population floor: A must deliver one Ctrl motion before rejection");
    auto before = server.playbackStatusForTest();
    auto viewport = server.playbackViewportForTest();

    foreach (rejected; ["not json\n", "",
            `{"t":0,"type":"VIEWPORT","vpX":0,"vpY":0,"vpW":1,"vpH":1}`]) {
        auto reply = requestAndTick(
            server, port, "POST", "/api/play-events", rejected);
        jsonReply(reply, "HTTP/1.1 400 Bad Request", "U6 rejected");
    }
    auto after = server.playbackStatusForTest();
    auto afterViewport = server.playbackViewportForTest();
    assert(after.generation == before.generation && after.total == before.total
        && after.remaining == before.remaining
        && afterViewport.valid && afterViewport.vpW == viewport.vpW
        && afterViewport.vpH == viewport.vpH,
        "U6 rejected body changed generation, playback, or inherited viewport");
    setEventPlayerCounterForTest(1000);
    server.tickEventPlayer();
    assert(atomicLoad(delivered) == 6,
        "U6 A remainder not delivered");
    assert(eventPlayerModifierForTest() == KMOD_NONE,
        "U6 A completion did not return its modifier loan");
}

unittest { // U7: a timed-out load is refused when serviced later
    setEventPlayerClockForTest(0, 1000);
    setEventPlayerModifierForTest(KMOD_NONE);
    scope(exit) clearEventPlayerControlsForTest();
    shared size_t delivered;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setPlayEventsBudgetForTest(100.msecs);
    server.setEventPlayerSink((SDL_Event*, bool) { atomicOp!"+="(delivered, 1); });
    startReady(server);
    auto reply = new Reply();
    auto client = startRequest(port, "POST", "/api/play-events", bLog(), reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.playEventsOwnedPendingForTest() == 1),
        "U7 population floor: expiring request did not queue");
    assert(waitUntil(() => atomicLoad(reply.done), 2.seconds),
        "U7 request did not return its timeout body");
    client.join();
    auto payload = jsonReply(reply, "HTTP/1.1 500 Internal Server Error", "U7 timeout");
    assert(payload["message"].str == "timeout waiting for main thread",
        "U7 timeout message changed");
    server.tickAll();
    server.tickEventPlayer();
    auto state = server.playbackStatusForTest();
    assert(state.generation == 0 && state.total == 0
        && atomicLoad(delivered) == 0,
        "U7 timed-out request accepted later");
}

unittest { // U7b: the 50 ms accept guard refuses service before wait timeout
    setEventPlayerClockForTest(0, 1000);
    setEventPlayerModifierForTest(KMOD_NONE);
    scope(exit) clearEventPlayerControlsForTest();
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setPlayEventsBudgetForTest(250.msecs);
    server.holdPlayEventsOwnedWaitForTest(true);
    startReady(server);
    auto reply = new Reply();
    auto client = startRequest(port, "POST", "/api/play-events", bLog(), reply);
    scope(exit) {
        server.holdPlayEventsOwnedWaitForTest(false);
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.playEventsOwnedPendingForTest() == 1),
        "U7b population floor: guarded request did not queue");
    assert(waitUntil(() => server.playEventsOwnedWaitReachedForTest()),
        "U7b held-waiter floor: HTTP waiter did not reach its test barrier");
    immutable deadline = server.playEventsOwnedDeadlineForTest();
    immutable serviceTarget = deadline - 40.msecs;
    while (MonoTime.currTime < serviceTarget) Thread.sleep(1.msecs);
    immutable servicedAt = MonoTime.currTime;
    assert(servicedAt < deadline,
        "U7b setup missed the owned wait deadline");
    server.tickAll();
    server.holdPlayEventsOwnedWaitForTest(false);
    assert(waitUntil(() => atomicLoad(reply.done)),
        "U7b guarded refusal did not release the HTTP waiter");
    client.join();
    auto payload = jsonReply(reply, "HTTP/1.1 500 Internal Server Error",
                             "U7b accept-window guard");
    assert(payload["message"].str == "timeout waiting for main thread",
        "U7b accept-window refusal message changed");
    auto state = server.playbackStatusForTest();
    assert(state.generation == 0 && state.total == 0,
        "U7b request serviced after notAfter changed the player");
}

unittest { // U8: stopping detaches a queued load before acceptance
    setEventPlayerClockForTest(0, 1000);
    scope(exit) clearEventPlayerControlsForTest();
    immutable port = freePort();
    auto server = new HttpServer(port);
    startReady(server);
    auto reply = new Reply();
    auto client = startRequest(port, "POST", "/api/play-events", bLog(), reply);
    scope(exit) if (client.isRunning) client.join();
    assert(waitUntil(() => server.playEventsOwnedPendingForTest() == 1),
        "U8 population floor: stopping request did not queue");
    server.stop();
    assert(waitUntil(() => atomicLoad(reply.done)),
        "U8 stopping did not release the waiting POST");
    client.join();
    auto payload = jsonReply(reply, "HTTP/1.1 500 Internal Server Error", "U8 stopping");
    assert(payload["message"].str == "HTTP server stopping",
        "U8 stopping message changed");
    server.tickAll();
    auto state = server.playbackStatusForTest();
    assert(state.generation == 0 && state.total == 0,
        "U8 stopped request was accepted after shutdown");
}
