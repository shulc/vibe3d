// The shared suite client has two backends. These cells select by API shape:
// one for each of its four public request functions, plus the exact 400 edge
// that distinguishes the ordinary throwing surface from the error-body one.
module test_http_inprocess_transport;

import http_client : ClientResponse, clearInProcessTransport, getJson,
    inProcessTransportInstalled, postJson, postRaw,
    postRawAllowingErrorStatus, setInProcessTransport;
import http_inprocess_transport : InProcessHttpTransport;
import http_server : HttpServer;
import std.algorithm : canFind;
import std.json : JSONValue;

void main() {}

private final class Rig
{
    HttpServer server;
    InProcessHttpTransport transport;
    size_t calls;
    string method;
    string path;
    string body;

    this()
    {
        server = new HttpServer();
        server.setTestMode(true);
        server.setRefireHandler((string action) {});
        server.markProvidersWired();
        server.tickAll();
        transport = new InProcessHttpTransport(server);
    }

    ClientResponse dispatch(string method, string path, string body_)
    {
        ++calls;
        this.method = method;
        this.path = path;
        this.body = body_;
        auto response = transport.request(method, path, body_);
        return ClientResponse(response.statusCode, response.body);
    }

    void install()
    {
        setInProcessTransport(&dispatch);
    }
}

unittest
{
    bool nullRejected;
    try
        cast(void) new InProcessHttpTransport(null);
    catch (Exception)
        nullRejected = true;
    assert(nullRejected,
        "6720 C0: constructing the in-process transport without a server succeeded");

    assert(!inProcessTransportInstalled,
        "6720 setup: a prior cell leaked the process-wide transport");
    auto rig = new Rig();
    rig.install();
    assert(inProcessTransportInstalled,
        "6720 setup: installing the in-process backend had no effect");
    scope (exit) clearInProcessTransport();

    // C1: JSON GET.
    JSONValue ping = getJson("/api/ping");
    assert(ping["status"].str == "ok" && rig.calls == 1
        && rig.method == "GET" && rig.path == "/api/ping",
        "6720 C1: getJson did not traverse the in-process dispatcher");

    // C2: raw POST. The deliberately incomplete object makes the route read
    // the transported body and answer synchronously before its main-thread bridge.
    immutable rawBody = `{"cell":"C2"}`;
    auto raw = postRaw("/api/refire", rawBody);
    assert(raw == `{"status":"error","message":"missing 'action' string field"}`
        && rig.calls == 2
        && rig.method == "POST" && rig.path == "/api/refire"
        && rig.body == rawBody,
        "6720 C2: postRaw did not carry method, path, and body in-process");

    // C3: parsed JSON POST.
    immutable jsonBody = `{"cell":"C3"}`;
    JSONValue parsed = postJson("/api/trace/disarm", jsonBody);
    assert(parsed["status"].str == "ok" && rig.calls == 3
        && rig.method == "POST" && rig.path == "/api/trace/disarm"
        && rig.body == jsonBody,
        "6720 C3: postJson did not traverse the in-process dispatcher");

    // C4: the error-body surface must return a non-2xx body unchanged.
    auto missing = postRawAllowingErrorStatus("/missing", "C4");
    assert(missing.canFind("404 Not Found") && rig.calls == 4,
        "6720 C4: allowing-error POST did not return the dispatcher body");

    // C5: the ordinary surface rejects the exact lower edge, 400.
    bool rejected400;
    try
        cast(void) getJson("/api/viewport/probe?target=not-a-target");
    catch (Exception e)
        rejected400 = e.msg.canFind("status 400");
    assert(rejected400 && rig.calls == 5,
        "6720 C5: ordinary client surface accepted an in-process HTTP 400");

    clearInProcessTransport();
    assert(!inProcessTransportInstalled,
        "6720 teardown: clearing the in-process backend left it installed");
}
