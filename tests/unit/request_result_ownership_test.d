module tests.unit.request_result_ownership_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import http_server : BridgeResultKind, HttpServer;
import std.algorithm : canFind, count, min;
import std.conv : to;
import std.file : readText;
import std.path : buildPath, dirName;
import std.socket : InternetAddress, Socket, SocketOption,
    SocketOptionLevel, TcpSocket;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode;

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

private string bodyAt(string code, string marker) {
    immutable at = code.indexOf(marker);
    assert(at >= 0, "5940 census missing marker " ~ marker);
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "5940 census marker has no body " ~ marker);
    immutable begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "5940 census body is unterminated " ~ marker);
    return null;
}

private final class ShortWriteSocket {
    const(ubyte)[] expected;
    size_t maxWrite;
    size_t accepted;
    size_t calls;

    this(const(ubyte)[] expected, size_t maxWrite) {
        this.expected = expected;
        this.maxWrite = maxWrite;
    }

    ptrdiff_t send(const(void)[] raw) {
        auto bytes = cast(const(ubyte)[]) raw;
        immutable take = min(maxWrite, bytes.length);
        assert(bytes[0 .. take] == expected[accepted .. accepted + take],
            "6310 short-write socket saw a skipped or duplicated response slice");
        accepted += take;
        ++calls;
        return cast(ptrdiff_t) take;
    }
}

private final class ZeroWriteSocket {
    size_t calls;

    ptrdiff_t send(const(void)[]) {
        ++calls;
        return 0;
    }
}

version (Posix)
private final class InterruptOnceSocket {
    const(ubyte)[] expected;
    size_t accepted;
    size_t calls;

    this(const(ubyte)[] expected) {
        this.expected = expected;
    }

    ptrdiff_t send(const(void)[] raw) {
        import core.stdc.errno : errno, EINTR;
        ++calls;
        if (calls == 1) {
            errno = EINTR;
            return -1;
        }
        auto bytes = cast(const(ubyte)[]) raw;
        assert(bytes == expected,
            "6310 EINTR retry did not resume from the unsent response slice");
        accepted += bytes.length;
        return cast(ptrdiff_t) bytes.length;
    }
}

version (Posix)
private final class AlwaysInterruptedSocket {
    ptrdiff_t send(const(void)[]) {
        import core.stdc.errno : errno, EINTR;
        errno = EINTR;
        return -1;
    }
}

version (Posix)
private final class HardFailSocket {
    ptrdiff_t send(const(void)[]) {
        import core.stdc.errno : errno, EPIPE;
        errno = EPIPE;
        return -1;
    }
}

private struct TimeoutCadenceSample {
    bool completed;
    Duration elapsed;
    long waits;
    long returns;
    int providerCalls;
    string wire;
    string failure;
}

private TimeoutCadenceSample runTimeoutCadence(Duration wakeCadence) {
    enum int kRigMaxIters = 150;
    shared int providerCalls = 0;
    shared bool keepWaking = true;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setSelectionBridgeMaxItersForTest(kRigMaxIters);
    server.suppressSelectionOwnedCompletionNotifyForTest(true);
    server.setSelectionDataProvider(() {
        atomicOp!"+="(providerCalls, 1);
        return `{"payload":"must-not-run"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    server.start();

    auto reply = new AsyncHttpReply();
    immutable started = MonoTime.currTime;
    auto client = startHttpGet(port, "/api/selection", reply);
    Thread waker = null;
    scope(exit) {
        atomicStore(keepWaking, false);
        if (waker !is null && waker.isRunning) waker.join();
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }

    assert(waitUntil(() => server.selectionOwnedPendingForTest() == 1,
                     2.seconds),
        "5780 deadline setup: request did not reach the owned queue");
    assert(waitUntil(() => server.selectionOwnedConditionWaitsForTest() >= 1,
                     2.seconds),
        "5780 deadline setup: waiter never blocked on the condition");

    waker = new Thread({
        while (atomicLoad(keepWaking) && !atomicLoad(reply.done)) {
            Thread.sleep(wakeCadence);
            server.wakeSelectionOwnedWaiterForTest();
        }
    });
    waker.start();

    TimeoutCadenceSample sample;
    sample.completed = waitUntil(() => atomicLoad(reply.done), 900.msecs);
    sample.elapsed = MonoTime.currTime - started;
    atomicStore(keepWaking, false);
    waker.join();
    if (sample.completed) client.join();
    sample.waits = server.selectionOwnedConditionWaitsForTest();
    sample.returns = server.selectionOwnedConditionReturnsForTest();
    sample.providerCalls = atomicLoad(providerCalls);
    sample.wire = reply.wire;
    sample.failure = reply.failure;
    return sample;
}

unittest {
    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable source = readText(buildPath(root, "source", "http_server.d"));
    assert(occurrences(source, "selectionBridge.submitAndWait") == 0,
        "5730 surface coexistence: selectionBridge must not use submitAndWait");
    assert(occurrences(source, "selectionBridge.submitOwned(") == 1,
        "5730 production wiring: route_apiSelection must contain the one "
        ~ "selectionBridge.submitOwned call; the helper alone is not evidence");
    assert(occurrences(source, "layersBridge.submitAndWait") == 0,
        "5730 surface coexistence: layersBridge must not use submitAndWait");
    assert(occurrences(source, "layersBridge.submitOwned(") == 1,
        "5730 production wiring: route_apiLayers must contain the one "
        ~ "layersBridge.submitOwned call; the helper alone is not evidence");
    assert(occurrences(source, "modelBridge.submitAndWait") == 0,
        "5950 surface coexistence: modelBridge must not use submitAndWait");
    assert(occurrences(source, "modelBridge.submitOwned(") == 1,
        "5950 production wiring: route_apiModel must contain one owned submit");
    assert(occurrences(source, "toolHandlesBridge.submitAndWait") == 0,
        "5950 surface coexistence: toolHandlesBridge must not use submitAndWait");
    assert(occurrences(source, "toolHandlesBridge.submitOwned(") == 1,
        "5950 production wiring: route_apiToolHandles must contain one owned submit");
    assert(occurrences(source, "modelBridge.req") == 0
        && occurrences(source, "modelBridge.resp") == 0,
        "5950 model storage: route_apiModel must not use shared request/result slots");
    assert(occurrences(source, "toolHandlesBridge.resp") == 0,
        "5950 handles storage: route_apiToolHandles must not use its shared result slot");
    assert(source.canFind(
            `RouteSpec("/api/model",                "",     Match.prefix, Answered.mainThread, "route_apiModel")`)
        && source.canFind(
            `RouteSpec("/api/tool/handles",         "GET",  Match.exact,  Answered.mainThread, "route_apiToolHandles")`),
        "5950 routing contract: model and handles must remain main-thread routes");

    immutable submitStart = source.indexOf("OwnedResult submitOwned(");
    immutable submitEnd = source.indexOf("override void notifyStarted()",
                                         submitStart);
    immutable tickStart = source.indexOf("if (owned !is null)", submitEnd);
    immutable tickEnd = source.indexOf("immutable long sub", tickStart);
    assert(submitStart >= 0 && submitEnd > submitStart
        && tickStart > submitEnd && tickEnd > tickStart,
        "5780 source population floor: owned submit/tick markers must exist");
    immutable submitBody = source[submitStart .. submitEnd];
    immutable ownedTickBody = source[tickStart .. tickEnd];
    assert(!submitBody.canFind("Thread.sleep(2.msecs)"),
        "5780 production wiring: submitOwned must not retain the 2 ms poll");
    assert(submitBody.canFind("ownedWaitCondition.wait(call.deadline - now)")
        && submitBody.canFind("for (;;)"),
        "5780 predicate wiring: submitOwned must wait in a deadline predicate loop");
    immutable submitWaitLock = submitBody.indexOf(
        "synchronized (ownedWaitMutex)");
    immutable finishedCheck = submitBody.indexOf(
        "if (atomicLoad(call.finished)");
    assert(submitWaitLock >= 0 && finishedCheck > submitWaitLock,
        "5780 waiter mutex predicate: finished must be checked under the same "
        ~ "ownedWaitMutex used by Condition.wait");
    immutable publish = ownedTickBody.indexOf(
        "atomicStore(owned.finished, 1)");
    immutable notify = ownedTickBody.indexOf(
        "ownedWaitCondition.notifyAll()");
    assert(occurrences(ownedTickBody,
                       "ownedWaitCondition.notifyAll()") == 1,
        "5780 shipped completion notify: unittest and production must share "
        ~ "one notifyAll statement");
    immutable publishLock = ownedTickBody.indexOf(
        "synchronized (ownedWaitMutex)");
    immutable publishLockEnd = ownedTickBody.indexOf(
        "\n            }", publishLock);
    assert(publishLock >= 0 && publishLockEnd > publishLock
        && publish > publishLock && notify > publish
        && notify < publishLockEnd,
        "5780 completion mutex: finished publication and notifyAll must stay "
        ~ "inside the same ownedWaitMutex scope");
    assert(publish >= 0 && notify > publish,
        "5780 publish order: completion must be published before notifyAll");

    immutable httpCode = blankNonCode(source);
    assert(occurrences(httpCode, "toolStateBridge.submitAndWait") == 0,
        "5940 surface coexistence: toolStateBridge must not use submitAndWait");
    assert(occurrences(httpCode, "toolStateBridge.submitOwned(") == 1,
        "5940 production route must contain exactly one toolStateBridge.submitOwned call");
    assert(occurrences(httpCode, "toolStateDataProvider()") == 1,
        "5940 provider ownership: only the main-thread service may invoke toolStateDataProvider");
    immutable routeBody = bodyAt(httpCode,
        "private void route_apiToolState(HttpRequest request, HttpResponse response)");
    assert(!routeBody.canFind("toolStateDataProvider()"),
        "5940 route ownership: the HTTP handler must not invoke the provider directly");
    immutable selectionAt = httpCode.indexOf("selectionBridge = new");
    immutable toolStateAt = httpCode.indexOf("toolStateBridge = new");
    immutable historyAt = httpCode.indexOf("historyBridge = new");
    immutable commandAt = httpCode.indexOf("commandBridge = new");
    assert(selectionAt >= 0 && toolStateAt > selectionAt
        && historyAt > toolStateAt && commandAt > historyAt,
        "5940 bridge construction order must be selection -> tool-state -> history -> command");
    immutable routeRow = source.indexOf(
        `RouteSpec("/api/tool/state",           "GET",  Match.exact,  Answered.mainThread, "route_apiToolState")`);
    assert(routeRow >= 0,
        "5940 route table must classify exact GET /api/tool/state as main-thread answered");

    immutable providers = readText(buildPath(root, "source", "http_providers.d"));
    immutable providerCode = blankNonCode(providers);
    immutable wireBody = bodyAt(providerCode,
        "private void wireSelectionProviders(HttpServer httpServer, ref EditorApp app,");
    assert(occurrences(wireBody, "new ToolStateHttpAdapter(") == 1,
        "5940 production provider wiring must construct exactly one ToolStateHttpAdapter");
    assert(occurrences(providerCode, "toolStateJson(") == 1,
        "5940 provider ownership: ToolStateHttpAdapter.read must be the sole toolStateJson caller");
}

unittest {
    shared int providerCalls = 0;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setSelectionDataProvider(() {
        atomicOp!"+="(providerCalls, 1);
        return `{"payload":"signalled"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    server.start();

    auto reply = new AsyncHttpReply();
    auto client = startHttpGet(port, "/api/selection", reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.selectionOwnedPendingForTest() == 1,
                     2.seconds),
        "5780 completion signal: request did not reach the owned queue");
    assert(waitUntil(() => server.selectionOwnedConditionWaitsForTest() >= 1,
                     2.seconds),
        "5780 completion signal: waiter did not block on the predicate");
    immutable returnsBeforeCompletion =
        server.selectionOwnedConditionReturnsForTest();

    // Complete halfway between the old 0 ms and 2 ms poll boundaries. The
    // condition-return counter identifies the signal path independently of
    // scheduler-sensitive wall latency; the distribution is measured apart.
    Thread.sleep(1.msecs);
    server.tickAll();
    assert(atomicLoad(providerCalls) == 1,
        "5780 completion signal population floor: callback must run exactly once");
    immutable returnedOnSignal = waitUntil(
        () => atomicLoad(reply.done)
           && server.selectionOwnedConditionReturnsForTest()
                > returnsBeforeCompletion,
        250.msecs);
    assert(returnedOnSignal,
        "5780 completion signal: callback ran once but the waiter did not "
        ~ "return on its completion notify");
    client.join();
    assert(reply.failure.length == 0
        && responseBody(reply.wire) == `{"payload":"signalled"}`,
        "5780 completion signal: real request did not return its completed payload");
}

unittest {
    shared int providerCalls = 0;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setSelectionDataProvider(() {
        atomicOp!"+="(providerCalls, 1);
        return `{"payload":"after-spurious"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    server.start();

    auto reply = new AsyncHttpReply();
    auto client = startHttpGet(port, "/api/selection", reply);
    scope(exit) {
        if (server.running) server.stop();
        if (client.isRunning) client.join();
    }
    assert(waitUntil(() => server.selectionOwnedConditionWaitsForTest() >= 1,
                     2.seconds),
        "5780 spurious wake: waiter did not enter its first condition wait");
    immutable waitsBeforeSpurious = server.selectionOwnedConditionWaitsForTest();
    immutable returnsBeforeSpurious =
        server.selectionOwnedConditionReturnsForTest();
    server.wakeSelectionOwnedWaiterForTest();
    assert(waitUntil(
        () => server.selectionOwnedConditionReturnsForTest()
                > returnsBeforeSpurious
           && server.selectionOwnedConditionWaitsForTest()
                > waitsBeforeSpurious,
                     2.seconds),
        "5780 spurious wake population floor: waiter did not consume the wake");
    assert(atomicLoad(providerCalls) == 0,
        "5780 spurious wake control: provider must remain uncalled before tick");
    assert(!atomicLoad(reply.done),
        "5780 spurious wake: an incomplete request must not return");

    server.tickAll();
    assert(waitUntil(() => atomicLoad(reply.done), 250.msecs),
        "5780 spurious wake: real completion did not wake the waiter");
    client.join();
    assert(atomicLoad(providerCalls) == 1
        && responseBody(reply.wire) == `{"payload":"after-spurious"}`,
        "5780 spurious wake completion floor: one real callback/payload required");
}

unittest {
    auto fastWake = runTimeoutCadence(1.msecs);
    auto coarseWake = runTimeoutCadence(17.msecs);
    immutable delta = fastWake.elapsed >= coarseWake.elapsed
        ? fastWake.elapsed - coarseWake.elapsed
        : coarseWake.elapsed - fastWake.elapsed;

    assert(fastWake.providerCalls == 0 && coarseWake.providerCalls == 0,
        "5780 deadline service floor: both expired requests must remain unserviced");
    assert(fastWake.waits >= 2 && coarseWake.waits >= 2
        && fastWake.returns >= 1 && coarseWake.returns >= 1,
        "5780 deadline wake floor: both cadence controls must really wake the waiter");
    assert(fastWake.completed && coarseWake.completed,
        "5780 fixed deadline: repeated wakes must not extend the submit-time deadline");
    assert(fastWake.elapsed >= 250.msecs && coarseWake.elapsed >= 250.msecs
        && fastWake.elapsed < 700.msecs && coarseWake.elapsed < 700.msecs
        && delta < 200.msecs,
        "5780 fixed deadline: 1 ms versus 17 ms wake cadence changed the "
        ~ "same 300 ms timeout");
    assert(fastWake.failure.length == 0 && coarseWake.failure.length == 0
        && responseBody(fastWake.wire).canFind(
            `"message": "timeout waiting for main thread"`)
        && responseBody(coarseWake.wire).canFind(
            `"message": "timeout waiting for main thread"`),
        "5780 expired request floor: both real requests need the timeout envelope");
}

unittest {
    shared int providerCalls = 0;
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.holdSelectionOwnedWaitForTest(true);
    server.setSelectionDataProvider(() {
        atomicOp!"+="(providerCalls, 1);
        return `{"payload":"completed-before-stop"}`;
    });
    server.markProvidersWired();
    server.tickAll();
    server.start();

    Thread stopper = null;
    scope(exit) {
        server.holdSelectionOwnedWaitForTest(false);
        if (stopper !is null && stopper.isRunning) stopper.join();
        if (server.running) server.stop();
    }

    auto reply = new AsyncHttpReply();
    auto client = startHttpGet(port, "/api/selection", reply);
    assert(waitUntil(() => server.selectionOwnedPendingForTest() == 1,
                     2.seconds),
        "5730 completed-before-stop: request never reached the owned queue");
    assert(waitUntil(() => server.selectionOwnedWaitReachedForTest(),
                     2.seconds),
        "5730 completed-before-stop: HTTP waiter did not reach its test barrier");
    server.tickAll();
    assert(atomicLoad(providerCalls) == 1
        && server.selectionOwnedPendingForTest() == 0,
        "5730 completed-before-stop population floor: tick must finish the one request");

    stopper = new Thread({ server.stop(); });
    stopper.start();
    assert(waitUntil(() => !server.running, 2.seconds),
        "5730 completed-before-stop: stop did not publish shutdown");
    server.holdSelectionOwnedWaitForTest(false);
    stopper.join();
    client.join();
    assert(reply.failure.length == 0,
        "5730 completed-before-stop: HTTP client failed: " ~ reply.failure);
    assert(responseBody(reply.wire) == `{"payload":"completed-before-stop"}`,
        "5730 completed-before-stop: a finished request must return its service "
        ~ "payload, not the stopping envelope: " ~ reply.wire);
}

unittest {
    immutable port = freePort();
    auto server = new HttpServer(port);
    server.setLayersDataProvider(() => `{"layers":[{"name":"budget"}]}`);
    server.markProvidersWired();
    server.tickAll();
    server.start();
    scope(exit) if (server.running) server.stop();

    auto reply = new AsyncHttpReply();
    auto client = startHttpGet(port, "/api/layers", reply);
    assert(waitUntil(() => server.layersOwnedPendingForTest() == 1, 2.seconds),
        "5730 layers budget: request did not reach the owned queue");
    Thread.sleep(300.msecs);
    assert(server.layersOwnedPendingForTest() == 1,
        "5730 layers budget: unticked call must remain queued across 300 ms");
    assert(!atomicLoad(reply.done),
        "5730 layers budget: the five-second call completed before its first tick");
    tickUntilDone(server, reply);
    client.join();
    assert(reply.failure.length == 0
        && responseBody(reply.wire) == `{"layers":[{"name":"budget"}]}`,
        "5730 layers budget: tick did not return the real provider payload: "
        ~ reply.wire);
}

unittest {
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
    server.setSelectionBridgeMaxItersForTest(2500);
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
    server.setSelectionBridgeMaxItersForTest(2500);
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
    // These are the bytes from the 2026-09-16 failure: the first send stopped
    // at 7,491,072 of a 13,637,433-byte /api/model response. Keeping the
    // multi-megabyte shape is essential; a small-response cell passes with the
    // old one-shot send and is not evidence for this defect.
    enum size_t responseBytes = 13_637_433;
    enum size_t firstWriteBytes = 7_491_072;
    auto response = new ubyte[responseBytes];
    foreach (i, ref value; response)
        value = cast(ubyte)((i * 31 + 7) & 0xff);

    auto socket = new ShortWriteSocket(response, firstWriteBytes);
    string failure;
    immutable sent = HttpServer.sendHttpResponseForTest(
        socket, cast(const(void)[]) response, 1.seconds, failure);
    assert(sent == response.length,
        "6310 partial-send witness: returned " ~ sent.to!string ~ " of "
        ~ response.length.to!string ~ " bytes");
    assert(socket.accepted == response.length,
        "6310 partial-send witness: socket accepted "
        ~ socket.accepted.to!string ~ " of " ~ response.length.to!string
        ~ " bytes");
    assert(socket.calls == 2,
        "6310 partial-send witness: incident-sized response should need two "
        ~ "short writes, got " ~ socket.calls.to!string);
    assert(failure.length == 0,
        "6310 partial-send witness: complete response reported failure: "
        ~ failure);

    auto deadlineSocket = new ShortWriteSocket(response, firstWriteBytes);
    string deadlineFailure;
    immutable deadlineSent = HttpServer.sendHttpResponseForTest(
        deadlineSocket, cast(const(void)[]) response, Duration.zero,
        deadlineFailure);
    assert(deadlineSent == firstWriteBytes
        && deadlineSocket.accepted == firstWriteBytes
        && deadlineFailure.canFind("send still incomplete after"),
        "6310 send deadline witness: positive short writes escaped the "
        ~ "whole-response deadline");

    auto zeroSocket = new ZeroWriteSocket();
    string zeroFailure;
    immutable zeroSent = HttpServer.sendHttpResponseForTest(
        zeroSocket, cast(const(void)[]) response, 1.seconds, zeroFailure);
    assert(zeroSent == 0 && zeroSocket.calls == 1
        && zeroFailure == "stopped reading",
        "6310 zero-write witness: no-progress send did not fail loudly");
}

version (Posix)
unittest {
    import core.stdc.errno : errno;

    immutable savedErrno = errno;
    scope(exit) errno = savedErrno;

    const response = cast(const(ubyte)[]) "signal-interrupted response";
    auto socket = new InterruptOnceSocket(response);
    string failure;
    immutable sent = HttpServer.sendHttpResponseForTest(
        socket, cast(const(void)[]) response, 1.seconds, failure);
    assert(sent == response.length,
        "6310 EINTR witness: interrupted send was not retried");
    assert(socket.calls == 2 && socket.accepted == response.length,
        "6310 EINTR witness: retry did not deliver the full response");
    assert(failure.length == 0,
        "6310 EINTR witness: successful retry reported failure: " ~ failure);

    string deadlineFailure;
    immutable deadlineSent = HttpServer.sendHttpResponseForTest(
        new AlwaysInterruptedSocket(), cast(const(void)[]) response,
        Duration.zero, deadlineFailure);
    assert(deadlineSent == 0 && deadlineFailure.canFind(
            "send still incomplete after"),
        "6310 send deadline witness: repeated EINTR did not end loudly");

    string hardFailure;
    immutable hardSent = HttpServer.sendHttpResponseForTest(
        new HardFailSocket(), cast(const(void)[]) response,
        1.seconds, hardFailure);
    assert(hardSent == 0 && hardFailure.length != 0
        && hardFailure != "stopped reading",
        "6310 hard send failure witness: socket error reason was lost");
}

unittest {
    immutable root = dirName(dirName(dirName(__FILE_FULL_PATH__)));
    immutable rawSource = readText(
        buildPath(root, "source", "http_server.d"));
    immutable source = blankNonCode(rawSource);
    immutable handle = bodyAt(source,
        "private void handleClient(Socket client)");
    assert(handle.count("sendHttpResponse(") == 1,
        "6310 production wiring: handleClient must route its one response "
        ~ "through the partial-write retry helper");
    assert(handle.canFind(
            "client, responseStr, clientWriteDeadline, sendFailure"),
        "6310 production wiring: handleClient stopped applying its whole-send "
        ~ "deadline to the retry helper");
    assert(handle.canFind("if (sent != responseStr.length)"),
        "6310 failure wiring: incomplete responses must retain the loud warning");
    assert(rawSource.canFind("took only %d of %d response bytes"),
        "6310 failure wiring: incomplete-response diagnostic text vanished");
    assert(!handle.canFind("client.send(responseStr)"),
        "6310 production wiring: the old one-shot response send returned");
    assert(source.canFind("Duration clientWriteDeadline = 15.seconds;"),
        "6310 send deadline: production whole-response budget changed");
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
