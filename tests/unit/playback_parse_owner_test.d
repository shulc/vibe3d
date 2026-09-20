module tests.unit.playback_parse_owner_test;

import core.atomic : atomicLoad, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;
import eventlog : clearEventPlayerControlsForTest,
    setEventPlayerClockForTest;
import http_server : HttpResponse, HttpServer, InProcessHttpTransport;
import playback_controller : PlaybackAcceptOutcome, PlaybackController;
import std.array : join;
import std.file : readText;
import std.path : buildPath, dirName;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode, blankUnittestBodies;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private bool isIdent(char c) pure nothrow @safe @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_';
}

private size_t countIdentifier(string code, string ident)
{
    size_t result;
    size_t from;
    while (from < code.length) {
        const rel = code[from .. $].indexOf(ident);
        if (rel < 0) break;
        const at = from + cast(size_t) rel;
        const before = at == 0 || !isIdent(code[at - 1]);
        const after = at + ident.length == code.length
            || !isIdent(code[at + ident.length]);
        if (before && after) ++result;
        from = at + ident.length;
    }
    return result;
}

private string bodyAt(string code, string marker)
{
    const markerAt = code.indexOf(marker);
    assert(markerAt >= 0, "6810 missing source area: " ~ marker);
    size_t open = cast(size_t) markerAt;
    while (open < code.length && code[open] != '{') ++open;
    assert(open < code.length, "6810 source area has no body: " ~ marker);
    size_t depth;
    foreach (i; open .. code.length) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[open .. i + 1];
    }
    assert(false, "6810 unterminated source area: " ~ marker);
    return null;
}

private void requireText(ref string[] offenders, string area, string needle,
                         string label)
{
    if (area.indexOf(needle) < 0) offenders ~= label;
}

unittest // identifier needle controls every callable spelling used by this gate
{
    const raw = q{
        auto direct = parseEventLog(data);
        auto address = &parseEventLog;
        auto inferred = () => parseEventLog(data);
        auto explicitDelegate = delegate() => parseEventLog(data);
        auto blockDelegate = delegate() { return parseEventLog(data); };
        auto decoy = parseEventLogger;
        auto text = "parseEventLog";
        // parseEventLog(commentDecoy);
    };
    const code = blankNonCode(raw);
    assert(countIdentifier(code, "parseEventLog") == 5,
        "6810 identifier scanner control changed: direct call, address, and "
        ~ "all three lambda spellings must count; substring/comment/string must not");
}

unittest // source ownership: floor -> identifier needle -> structure -> pin
{
    const serverRaw = readText(buildPath(repoRoot, "source", "http_server.d"));
    const ownerRaw = readText(
        buildPath(repoRoot, "source", "playback_controller.d"));
    const eventlogRaw = readText(buildPath(repoRoot, "source", "eventlog.d"));
    const server = blankUnittestBodies(blankNonCode(serverRaw));
    const owner = blankUnittestBodies(blankNonCode(ownerRaw));
    const eventlog = blankUnittestBodies(blankNonCode(eventlogRaw));
    const route = bodyAt(server, "private void route_apiPlayEvents(");
    const serve = bodyAt(server, "private void servePlayEvents(");
    const constructor = bodyAt(server, "public this(ushort port = 8080)");
    const accept = bodyAt(owner,
        "PlaybackAcceptOutcome accept(string data, MonoTime notAfter)");
    const acceptParsed = bodyAt(owner,
        "private PlaybackAcceptOutcome acceptParsed(");

    assert(server.length > 150_000 && owner.length > 2_000
        && eventlog.length > 20_000 && route.length > 100
        && serve.length > 500 && constructor.length > 10_000
        && accept.length > 300 && acceptParsed.length > 300,
        "6810 ownership census area changed: server, owner, eventlog, wrapper, "
        ~ "body, constructor, or accept surface is empty/truncated");

    assert(countIdentifier(server, "parseEventLog") == 0
        && countIdentifier(server, "eventPlayer_") == 0
        && countIdentifier(owner, "parseEventLog") == 2
        && countIdentifier(accept, "parseEventLog") == 1
        && countIdentifier(eventlog, "parseEventLog") == 3,
        "6810 parser/storage identifier census changed: expected http_server "
        ~ "parseEventLog=0 and eventPlayer_=0, playback_controller parseEventLog=2 "
        ~ "(import+owner call), eventlog parseEventLog=3");

    assert(countIdentifier(route, "testMode") == 1
        && countIdentifier(serve, "testMode") == 0
        && countIdentifier(constructor, "accept") == 1,
        "6810 play-events structural path changed: authorization must stay in "
        ~ "the wrapper, the body must forward raw body once, and the bridge "
        ~ "service must call the owner once");
    assert(serve.indexOf("bridgeRequest.body = request.body") >= 0
        && serve.indexOf("playEventsBridge.submitOwned")
            > serve.indexOf("bridgeRequest.body = request.body")
        && constructor.indexOf(
            "playbackController.accept(req.body, req.notAfter)") >= 0
        && accept.indexOf("parseEventLog(data)") >= 0
        && accept.indexOf("acceptParsed(parsed.log, notAfter)")
            > accept.indexOf("parseEventLog(data)"),
        "6810 raw play-events body did not travel transport -> bridge -> "
        ~ "PlaybackController parser -> validated accept in order");

    string[] offenders;
    requireText(offenders, constructor,
        "playbackController.accept(req.body, req.notAfter)", "bridge.accept-raw");
    requireText(offenders, constructor,
        "if (outcome.invalidLog)", "bridge.invalid-guard");
    requireText(offenders, constructor,
        "resp.invalidLog = true", "bridge.invalid-result");
    requireText(offenders, serve,
        "bridgeRequest.body = request.body", "transport.raw-body");
    requireText(offenders, serve,
        "if (owned.result.invalidLog)", "transport.invalid-guard");
    requireText(offenders, serve,
        "response.statusCode = 400", "transport.invalid-status");
    requireText(offenders, accept,
        "if (MonoTime.currTime >= notAfter)", "owner.pre-parse-deadline");
    requireText(offenders, accept,
        "auto parsed = parseEventLog(data)", "owner.parse");
    requireText(offenders, accept,
        "if (!parsed.accepted)", "owner.invalid-guard");
    requireText(offenders, accept,
        "outcome.invalidLog = true", "owner.invalid-result");
    requireText(offenders, accept,
        "return acceptParsed(parsed.log, notAfter)", "owner.accept-parsed");
    requireText(offenders, acceptParsed,
        "if (MonoTime.currTime >= notAfter)", "owner.post-parse-deadline");
    requireText(offenders, acceptParsed,
        "eventPlayer_.begin(log)", "owner.begin");
    requireText(offenders, bodyAt(owner, "bool tick()"),
        "return eventPlayer_.tick()", "owner.tick");
    requireText(offenders, bodyAt(owner, "void setFastForward("),
        "eventPlayer_.fastForward = enabled", "owner.fast-forward");
    requireText(offenders, bodyAt(owner, "void setImmediateSink("),
        "eventPlayer_.setImmediateSink(sink)", "owner.sink");
    requireText(offenders, bodyAt(owner, "int mouseX()"),
        "return eventPlayer_.mouseX", "owner.mouse-x");
    requireText(offenders, bodyAt(owner, "int mouseY()"),
        "return eventPlayer_.mouseY", "owner.mouse-y");
    requireText(offenders, bodyAt(owner, "bool mouseDown()"),
        "return eventPlayer_.mouseDown", "owner.mouse-down");
    requireText(offenders, bodyAt(owner, "auto recordedViewport()"),
        "return eventPlayer_.recordedViewport", "owner.viewport");
    const statusBody = bodyAt(owner, "PlaybackStatus status()");
    requireText(offenders, statusBody,
        "result.finished = !eventPlayer_.active", "owner.status-finished");
    requireText(offenders, statusBody,
        "result.total = eventPlayer_.entries.length", "owner.status-total");
    requireText(offenders, statusBody,
        "result.total - eventPlayer_.idx", "owner.status-remaining");
    requireText(offenders, statusBody,
        "eventPlayer_.immediateMotionDeliveries()", "owner.status-motions");
    requireText(offenders, statusBody,
        "result.generation = generation_", "owner.status-generation");
    assert(offenders.length == 0,
        "6810 playback surface wiring changed; offenders: " ~ offenders.join(", "));

    const requestDeclAt = serverRaw.indexOf("struct PlayEventsReq {");
    const requestBridgeAt = serverRaw.indexOf(
        "private MainThreadBridge!(PlayEventsReq, PlayEventsResp)");
    assert(requestDeclAt >= 0 && requestBridgeAt > requestDeclAt,
        "6810 PlayEventsReq raw reflection area was not found");
    const requestArea = serverRaw[cast(size_t) requestDeclAt
        .. cast(size_t) requestBridgeAt];
    const reflectionControl = q{ value.tupleof;
        __traits(getMember, value, "field"); mixin("field"); };
    assert(reflectionControl.indexOf(".tupleof") >= 0
        && reflectionControl.indexOf("__traits(getMember") >= 0
        && reflectionControl.indexOf("mixin") >= 0,
        "6810 raw reflection local positive control no longer sees all three spellings");
    assert(requestArea.indexOf(".tupleof") < 0
        && requestArea.indexOf("__traits(getMember") < 0
        && requestArea.indexOf("mixin") < 0,
        "6810 PlayEventsReq raw reflection pin changed; tupleof, getMember, "
        ~ "and mixin can bypass a private transport carrier");
    assert(serverRaw.indexOf("playbackController.tupleof") < 0
        && serverRaw.indexOf("__traits(getMember, playbackController") < 0
        && serverRaw.indexOf("mixin(\"playbackController") < 0,
        "6810 playback owner raw reflection pin changed; HttpServer must not "
        ~ "reach controller storage through tupleof, getMember, or string mixin");
}

static assert([__traits(allMembers, PlaybackAcceptOutcome)]
        == ["accepted", "invalidLog", "generation", "replaced"],
    "6810 PlaybackAcceptOutcome compiler fence changed");
static assert([__traits(allMembers, PlaybackController)] == [
        "eventPlayer_", "generation_", "parseThreadForTest_",
        "parseCallsForTest_", "acceptThreadForTest_", "acceptCallsForTest_",
        "accept", "acceptParsed", "tick", "setFastForward",
        "setImmediateSink", "mouseX", "mouseY", "mouseDown",
        "recordedViewport", "status", "parseThreadForTest",
        "parseCallsForTest", "acceptThreadForTest", "acceptCallsForTest"],
    "6810 PlaybackController compiler fence changed");

private final class AsyncResponse
{
    shared bool done;
    HttpResponse response;
    string failure;
}

private size_t threadIdentity() nothrow
{
    try return cast(size_t) cast(void*) Thread.getThis();
    catch (Throwable) return 0;
}

private bool waitUntil(bool delegate() predicate,
                       Duration budget = 2.seconds)
{
    const deadline = MonoTime.currTime + budget;
    while (!predicate()) {
        if (MonoTime.currTime >= deadline) return false;
        Thread.sleep(1.msecs);
    }
    return true;
}

private Thread requestOnForeignThread(InProcessHttpTransport transport,
                                       string body, AsyncResponse result)
{
    auto thread = new Thread({
        try result.response = transport.request("POST", "/api/play-events", body);
        catch (Throwable error) result.failure = error.msg;
        atomicStore(result.done, true);
    });
    thread.start();
    return thread;
}

private HttpResponse requestAndTick(HttpServer server,
                                    InProcessHttpTransport transport,
                                    string body,
                                    string cell)
{
    auto result = new AsyncResponse();
    auto client = requestOnForeignThread(transport, body, result);
    scope(exit) {
        if (client.isRunning) {
            server.tickAll();
            client.join();
        }
    }
    assert(waitUntil(() => server.playEventsOwnedPendingForTest() == 1),
        cell ~ ": request did not reach the owner queue");
    assert(!atomicLoad(result.done),
        cell ~ ": transport answered before the playback owner tick");
    server.tickAll();
    assert(waitUntil(() => atomicLoad(result.done)),
        cell ~ ": owner tick did not release the request");
    client.join();
    assert(result.failure.length == 0,
        cell ~ ": in-process request failed: " ~ result.failure);
    return result.response;
}

unittest // valid control plus invalid parse both execute on the owner thread
{
    setEventPlayerClockForTest(0, 1000);
    scope(exit) clearEventPlayerControlsForTest();
    auto server = new HttpServer();
    server.setTestMode(true);
    server.markProvidersWired();
    server.tickAll();
    const ownerThread = threadIdentity();
    assert(ownerThread != 0 && server.playbackParseCallsForTest() == 0
        && server.playbackAcceptCallsForTest() == 0,
        "6810 runtime floor: owner identity or fresh parser/accept counters changed");

    auto transport = new InProcessHttpTransport(server);
    const valid = requestAndTick(server, transport,
        `{"t":0,"type":"SDL_KEYDOWN","sym":97,"scan":4,"mod":0,"repeat":0}`,
        "6810 valid control");
    assert(valid.statusCode == 200
        && server.playbackParseCallsForTest() == 1
        && server.playbackAcceptCallsForTest() == 1,
        "6810 local positive control: owner did not parse and accept one valid log");

    const invalid = requestAndTick(
        server, transport, "not json\n", "6810 invalid log");
    assert(invalid.statusCode == 400
        && invalid.body == `{"status": "error", "message": "Failed to parse events"}`,
        "6810 owner-parsed invalid log changed its 400 response");
    assert(server.playbackParseCallsForTest() == 2
        && server.playbackParseThreadForTest() == ownerThread,
        "6810 invalid log was not parsed exactly once on the playback owner thread");
    const status = server.playbackStatusForTest();
    assert(server.playbackAcceptCallsForTest() == 1
        && status.generation == 1 && status.total == 1,
        "6810 invalid owner parse changed accepted playback state");
}
