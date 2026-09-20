// W14-C closes exactly nine HTTP-owned dependency edges.  Keep the evidence
// in the same order as the claim: population floor, old-edge needles,
// production structure, then a real queued-service pin for every surface.
module tests.unit.portless_route_ports_test;

import core.atomic : atomicLoad, atomicOp, atomicStore;
import core.thread : Thread;
import core.time : Duration, MonoTime, msecs, seconds;

import http_server : HttpResponse, HttpServer, InProcessHttpTransport;
import std.algorithm : canFind;
import std.array : join;
import std.file : readText;
import std.format : format;
import std.path : buildPath, dirName;
import std.string : count, indexOf;

import tests.unit.census_symbols : blankNonCode;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));
private enum serverPath = buildPath(repoRoot, "source", "http_server.d");
private enum providersPath = buildPath(repoRoot, "source", "http_providers.d");

private struct Surface {
    string path;
    string requestPath;
    string method;
    string handler;
    string bridge;
    string setter;
    string provider;
    string dependencyA;
    string dependencyB;
    string contentType;
    string expectedBody;
    string missingProviderError;
}

static assert([__traits(allMembers, Surface)] == [
    "path", "requestPath", "method", "handler", "bridge", "setter",
    "provider", "dependencyA", "dependencyB", "contentType", "expectedBody",
    "missingProviderError"],
    "6780 evidence-surface member set changed");

private enum Surface[] surfaces = [
    Surface("/api/ui/policy", "/api/ui/policy", "GET",
        "route_apiUiPolicy", "uiPolicyBridge", "setUiPolicyProvider",
        "uiPolicyProvider", "uiPolicyJson", "ui.discard_guard",
        "application/json", `{"surface":"ui-policy"}`,
        "UI-policy provider not set"),
    Surface("/api/toolprops/ids", "/api/toolprops/ids", "GET",
        "route_apiToolpropsIds", "toolpropsIdsBridge", "setToolpropsIdsProvider",
        "toolpropsIdsProvider", "toolPropsIdsJson", "property_panel",
        "application/json", `{"surface":"toolprops-ids"}`,
        "tool-props ids provider not set"),
    Surface("/api/buttons/availability", "/api/buttons/availability", "GET",
        "route_apiButtonsAvailability", "buttonAvailabilityBridge",
        "setButtonAvailabilityProvider", "buttonAvailabilityProvider",
        "buttonAvailabilityJson", "ui.availability",
        "application/json", `{"surface":"button-availability"}`,
        "button-availability provider not set"),
    Surface("/api/input/context", "/api/input/context?x=17&y=23&key=probe", "GET",
        "route_apiInputContext", "inputContextBridge", "setInputContextProvider",
        "inputContextProvider", "inputContextJson", "input_context",
        "application/json", `{"surface":"input-context"}`,
        "input-context provider not set"),
    Surface("/api/stats", "/api/stats", "GET",
        "route_apiStats", "statsBridge", "setStatsProvider", "statsProvider",
        "statRowsJson", "ui.stat_record", "application/json; charset=utf-8",
        `{"surface":"stats"}`, "stats provider not set"),
    Surface("/api/pie", "/api/pie", "GET",
        "route_apiPie", "pieBridge", "setPieProvider", "pieProvider",
        "pieFrameJson", "ui.pie_record", "application/json",
        `{"surface":"pie"}`, "pie provider not set"),
    Surface("/api/tool/disarm", "/api/tool/disarm", "GET",
        "route_apiToolDisarm", "toolDisarmBridge", "setToolDisarmProvider",
        "toolDisarmProvider", "g_disarmCrossings", "g_lastDisarm",
        "application/json", `{"surface":"tool-disarm"}`,
        "tool-disarm provider not set"),
    Surface("/api/perf/reset", "/api/perf/reset", "POST",
        "route_apiPerfReset", "perfResetBridge", "setPerfResetHandler",
        "perfResetHandler", "g_perf.reset", "perf_probe",
        "application/json", `{"status":"ok"}`,
        "perf-reset handler not set"),
    Surface("/api/perf", "/api/perf", "GET",
        "route_apiPerf", "perfBridge", "setPerfProvider", "perfProvider",
        "g_perf.toJson", "perf_probe", "application/json",
        `{"surface":"perf"}`, "perf provider not set"),
];

private size_t matchingClose(string code, size_t open,
                             char opening = '{', char closing = '}') {
    assert(open < code.length && code[open] == opening,
        "6780 scanner opening delimiter is absent");
    size_t depth;
    foreach (i; open .. code.length) {
        if (code[i] == opening) ++depth;
        else if (code[i] == closing && --depth == 0) return i;
    }
    assert(false, "6780 scanner region is unterminated");
}

private string functionBody(string raw, string declaration) {
    const code = blankNonCode(raw);
    assert(code.count(declaration) == 1, format(
        "6780 expected one declaration %s; found %d",
        declaration, code.count(declaration)));
    const at = code.indexOf(declaration);
    const open = code.indexOf('{', cast(size_t) at + declaration.length);
    assert(open >= 0, "6780 declaration has no body: " ~ declaration);
    const close = matchingClose(code, cast(size_t) open);
    const result = code[cast(size_t) open .. close + 1];
    assert(result.length >= 40, format(
        "6780 scanned body is too short: %s has %d bytes",
        declaration, result.length));
    return result;
}

private string routeRow(string server, string handler) {
    const needle = `"` ~ handler ~ `")`;
    if (server.count(needle) != 1) return null;
    const at = server.indexOf(needle);
    auto begin = cast(size_t) at;
    while (begin != 0 && server[begin - 1] != '\n') --begin;
    auto end = cast(size_t) at + needle.length;
    while (end < server.length && server[end] != '\n') ++end;
    const row = server[begin .. end];
    return row.length >= 80 ? row : null;
}

private string bridgeConstruction(string ctor, ref const Surface surface) {
    const startNeedle = surface.bridge ~ " = new MainThreadBridge";
    assert(ctor.count(startNeedle) == 1, format(
        "6780 expected one construction for %s; found %d",
        surface.bridge, ctor.count(startNeedle)));
    const begin = ctor.indexOf(startNeedle);
    const open = ctor.indexOf("(this,", cast(size_t) begin);
    assert(open >= 0,
        "6780 bridge construction has no service argument list: " ~ surface.bridge);
    const end = matchingClose(ctor, cast(size_t) open, '(', ')') + 1;
    const result = ctor[cast(size_t) begin .. end];
    assert(result.length >= 180,
        "6780 bridge construction scan is too short for " ~ surface.bridge);
    return result;
}

private string rawBridgeConstruction(string server, ref const Surface surface) {
    const startNeedle = surface.bridge ~ " = new MainThreadBridge";
    if (server.count(startNeedle) != 1) return null;
    const begin = server.indexOf(startNeedle);
    const open = server.indexOf("(this,", cast(size_t) begin);
    if (open < 0) return null;
    const end = matchingClose(server, cast(size_t) open, '(', ')') + 1;
    return server[cast(size_t) begin .. end];
}

private string setterCall(string wiring, ref const Surface surface) {
    const startNeedle = "httpServer." ~ surface.setter ~ "(";
    if (wiring.count(startNeedle) != 1) return null;
    const begin = wiring.indexOf(startNeedle);
    const open = wiring.indexOf('(', cast(size_t) begin);
    if (open < 0) return null;
    const end = matchingClose(wiring, cast(size_t) open, '(', ')') + 1;
    return wiring[cast(size_t) begin .. end];
}

unittest { // floor: the nine-row population and both scanned regions exist
    const server = readText(serverPath);
    const providers = readText(providersPath);
    assert(server.length > 100_000 && providers.length > 100_000,
        "6780 source floor: server/provider source region is unexpectedly small");
    assert(surfaces.length == 9,
        "6780 population floor: expected nine route cells");

    foreach (ref const surface; surfaces) {
        const row = routeRow(server, surface.handler);
        assert(row.length != 0
            && row.canFind(`RouteSpec("` ~ surface.path ~ `"`),
            "6780 named-route floor changed: " ~ surface.handler ~ " => " ~ row);
    }
}

unittest { // needles: each old dependency is absent from its former handler
    const server = readText(serverPath);
    const providerCode = blankNonCode(readText(providersPath));
    foreach (ref const surface; surfaces) {
        const body = functionBody(server, "private void " ~ surface.handler ~ "(");
        const positive = providerCode.canFind(surface.dependencyA)
            && providerCode.canFind(surface.dependencyB);
        const absent = !body.canFind(surface.dependencyA)
            && !body.canFind(surface.dependencyB);
        assert(positive && absent, format(
            "6780 dependency needle failed for %s: provider-positive=%s, "
          ~ "handler has %s=%s / %s=%s",
            surface.handler, positive, surface.dependencyA,
            body.canFind(surface.dependencyA), surface.dependencyB,
            body.canFind(surface.dependencyB)));
    }
}

unittest { // structure: route -> own bridge -> own port -> production dependency
    const server = readText(serverPath);
    const providers = readText(providersPath);
    const ctor = functionBody(server, "public this(ushort port = 8080)");
    const wiring = functionBody(providers, "void wireHttpProviders(");

    foreach (ref const surface; surfaces) {
        const row = routeRow(server, surface.handler);
        const handler = functionBody(server,
            "private void " ~ surface.handler ~ "(");
        const construction = bridgeConstruction(ctor, surface);
        const rawConstruction = rawBridgeConstruction(server, surface);
        const wiringCount = wiring.count(
            "httpServer." ~ surface.setter ~ "(");
        const call = setterCall(wiring, surface);
        const mapped = row.canFind("Answered.mainThread")
            && handler.count(surface.bridge) == 1
            && construction.canFind(surface.provider)
            && rawConstruction.canFind(`"` ~ surface.path ~ `"`)
            && wiringCount == 1
            && call.canFind(surface.dependencyA)
            && providers.canFind(surface.dependencyB)
            && server.count("public void " ~ surface.setter ~ "(") == 1;
        assert(mapped, format(
            "6780 structural map failed for %s: answered=%s bridge-count=%d "
          ~ "service-port=%s owned-route=%s wiring-count=%d dependency=%s "
          ~ "setter-count=%d",
            surface.handler, row.canFind("Answered.mainThread"),
            handler.count(surface.bridge), construction.canFind(surface.provider),
            rawConstruction.canFind(`"` ~ surface.path ~ `"`),
            wiringCount,
            call.canFind(surface.dependencyA)
                && providers.canFind(surface.dependencyB),
            server.count("public void " ~ surface.setter ~ "(")));
    }
}

private final class AsyncReply {
    shared bool done;
    HttpResponse response;
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

private size_t threadIdentity() nothrow {
    return cast(size_t) cast(void*) Thread.getThis();
}

unittest { // pin: each absent application port yields its own 500 diagnosis
    const serverSource = readText(serverPath);
    const regionBegin = serverSource.indexOf(
        "private PortlessJsonResp awaitPortlessJson(");
    assert(regionBegin >= 0,
        "6780 missing-provider source region has no beginning");
    const regionEnd = serverSource.indexOf(
        "private void route_apiFramesCountsReset", cast(size_t) regionBegin);
    assert(regionEnd > regionBegin,
        "6780 missing-provider source region has no end");
    const errorRegion = serverSource[
        cast(size_t) regionBegin .. cast(size_t) regionEnd];

    string[] violations;
    if (serverSource.count(
            "private Duration portlessRouteBudget_ = 5.seconds;") != 1)
        violations ~= "<portless-budget>";
    if (errorRegion.count("portlessRouteBudget_") != 3)
        violations ~= "<budget-consumers>";
    const timeoutPinned = errorRegion.count(
            `PortlessJsonResp("", "timeout waiting for main thread")`) == 1
        && errorRegion.count(
            `InputContextResp("", "timeout waiting for main thread")`) == 1
        && errorRegion.count(
            `PerfResetResp("timeout waiting for main thread")`) == 1;
    if (!timeoutPinned)
        violations ~= "<timeout-synthetic>";
    const stoppingPinned = errorRegion.count(
            `PortlessJsonResp("", "HTTP server stopping")`) == 1
        && errorRegion.count(
            `InputContextResp("", "HTTP server stopping")`) == 1
        && errorRegion.count(`PerfResetResp("HTTP server stopping")`) == 1;
    if (!stoppingPinned)
        violations ~= "<stopping-synthetic>";

    auto server = new HttpServer();
    server.markProvidersWired();
    server.tickAll();
    auto transport = new InProcessHttpTransport(server);

    foreach (ref const surface; surfaces) {
        auto reply = new AsyncReply();
        auto client = new Thread({
            try reply.response = transport.request(
                surface.method, surface.requestPath, "");
            catch (Throwable error) reply.failure = error.msg;
            atomicStore(reply.done, true);
        });
        client.isDaemon = true;
        client.start();
        const observed = waitUntil(
            () => server.portlessOwnedPendingForTest(surface.path) == 1
               || atomicLoad(reply.done));
        const queued = observed
            && server.portlessOwnedPendingForTest(surface.path) == 1
            && !atomicLoad(reply.done);
        server.tickAll();
        const completed = waitUntil(() => atomicLoad(reply.done));
        if (completed) client.join();
        const pinned = queued && completed && reply.failure.length == 0
            && reply.response !is null && reply.response.statusCode == 500
            && reply.response.headers["Content-Type"] == surface.contentType
            && reply.response.body.canFind(surface.missingProviderError);
        if (!pinned) violations ~= format(
            "%s(queued=%s completed=%s failure=%s status=%d type=%s body=%s)",
            surface.path, queued, completed, reply.failure,
            reply.response is null ? -1 : reply.response.statusCode,
            reply.response is null ? "<none>"
                : reply.response.headers.get("Content-Type", "<none>"),
            reply.response is null ? "<none>" : reply.response.body);
    }
    assert(violations.length == 0,
        "6780 missing-provider violations: " ~ violations.join("; "));
}

unittest { // pin: every named route queues and invokes its port on tickAll
    shared size_t[9] callbackThreads;
    shared int resetCalls;
    auto server = new HttpServer();
    server.setUiPolicyProvider(() {
        atomicStore(callbackThreads[0], threadIdentity());
        return surfaces[0].expectedBody;
    });
    server.setToolpropsIdsProvider(() {
        atomicStore(callbackThreads[1], threadIdentity());
        return surfaces[1].expectedBody;
    });
    server.setButtonAvailabilityProvider(() {
        atomicStore(callbackThreads[2], threadIdentity());
        return surfaces[2].expectedBody;
    });
    server.setInputContextProvider((bool havePoint, int x, int y, string key) {
        atomicStore(callbackThreads[3], threadIdentity());
        return havePoint && x == 17 && y == 23 && key == "probe"
            ? surfaces[3].expectedBody : `{"surface":"wrong-input"}`;
    });
    server.setStatsProvider(() {
        atomicStore(callbackThreads[4], threadIdentity());
        return surfaces[4].expectedBody;
    });
    server.setPieProvider(() {
        atomicStore(callbackThreads[5], threadIdentity());
        return surfaces[5].expectedBody;
    });
    server.setToolDisarmProvider(() {
        atomicStore(callbackThreads[6], threadIdentity());
        return surfaces[6].expectedBody;
    });
    server.setPerfResetHandler(() {
        atomicStore(callbackThreads[7], threadIdentity());
        atomicOp!"+="(resetCalls, 1);
    });
    server.setPerfProvider(() {
        atomicStore(callbackThreads[8], threadIdentity());
        return surfaces[8].expectedBody;
    });
    server.markProvidersWired();
    server.tickAll();
    immutable tickThread = threadIdentity();
    auto transport = new InProcessHttpTransport(server);

    foreach (i, ref const surface; surfaces) {
        auto reply = new AsyncReply();
        auto client = new Thread({
            try reply.response = transport.request(
                surface.method, surface.requestPath, "");
            catch (Throwable error) reply.failure = error.msg;
            atomicStore(reply.done, true);
        });
        client.isDaemon = true;
        client.start();
        const observed = waitUntil(
            () => server.portlessOwnedPendingForTest(surface.path) == 1
               || atomicLoad(reply.done));
        const queued = observed
            && server.portlessOwnedPendingForTest(surface.path) == 1
            && !atomicLoad(reply.done);
        server.tickAll();
        const completed = waitUntil(() => atomicLoad(reply.done));
        if (completed) client.join();
        const resetPinned = surface.path == "/api/perf/reset"
            ? atomicLoad(resetCalls) == 1 : true;
        const pinned = queued && completed && reply.failure.length == 0
            && reply.response !is null && reply.response.statusCode == 200
            && reply.response.headers["Content-Type"] == surface.contentType
            && reply.response.body == surface.expectedBody
            && atomicLoad(callbackThreads[i]) == tickThread
            && resetPinned;
        assert(pinned, format(
            "6780 route pin failed for %s: queued=%s completed=%s failure=%s "
          ~ "status=%d type=%s body=%s callback-thread=%d tick-thread=%d reset-pinned=%s",
            surface.path, queued, completed, reply.failure,
            reply.response is null ? -1 : reply.response.statusCode,
            reply.response is null ? "<none>"
                : reply.response.headers.get("Content-Type", "<none>"),
            reply.response is null ? "<none>" : reply.response.body,
            atomicLoad(callbackThreads[i]), tickThread, resetPinned));
    }
}
