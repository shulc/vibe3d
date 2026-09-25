/// tests/http_client.d — the ONE HTTP client seam every suite driver uses.
/// The default backend talks to its worker's `vibe3d --test` over a socket;
/// an in-process host can install the second backend below.
///
/// WHY IT IS THE ONLY ONE. Before task 4055 the runner rewrote the literal
/// `localhost:8080` inside a scratch COPY of every test source, so a driver
/// that spelled its base any other way silently drove the NEIGHBOURING
/// worker's instance under `-j`. That rewrite is gone; the port now arrives
/// in the environment (`run_test.d` → `childEnv["VIBE3D_TEST_PORT"]`) and is
/// resolved here. Two standing censuses keep the seam closed:
/// `tests/unit/http_endpoint_census_test.d` refuses a host-and-port literal
/// anywhere in `tests/*.d` and a second local copy of these functions.
module http_client;

import std.conv      : ConvException, to;
import std.json      : JSONValue, parseJSON;
import std.net.curl  : get, post, HTTP;
import std.process   : environment;
import std.stdio     : stderr;
import core.thread   : Thread;
import core.time     : Duration, MonoTime, msecs, seconds;

struct ClientResponse
{
    int statusCode;
    string body;
}

alias InProcessClientTransport = ClientResponse delegate(
    string method, string path, string body_);

/// Intentionally thread-local: a suite driver installs and consumes this
/// backend on its own test thread. Other threads retain the socket fallback.
private InProcessClientTransport g_inProcessTransport;

void setInProcessTransport(InProcessClientTransport transport)
{
    g_inProcessTransport = transport;
}

void clearInProcessTransport()
{
    g_inProcessTransport = null;
}

@property bool inProcessTransportInstalled()
{
    return g_inProcessTransport !is null;
}

private bool tryInProcess(string method, string path, string body_,
                          bool allowErrorStatus, out string responseBody)
{
    if (g_inProcessTransport is null)
        return false;

    const response = g_inProcessTransport(method, path, body_);
    if (!allowErrorStatus && response.statusCode >= 400)
        throw new Exception("HTTP request failed with status "
            ~ response.statusCode.to!string);
    responseBody = response.body;
    return true;
}

/// The variable `run_test.d` writes into every test process.
enum string kPortEnv = "VIBE3D_TEST_PORT";

/// Port a hand-run test binary uses when NOTHING set the variable at all.
enum ushort kDefaultPort = 8080;

private __gshared bool g_announcedUnset;

/// The port this test process must drive, read LIVE on every call.
///
/// NOT CACHED, ON PURPOSE: `test_tool_sticky.d`, `test_tool_sticky_cluster_0393.d`
/// and `test_loop_slice_sticky.d` launch their OWN instance and rewrite this
/// variable from `static this()`, so a value memoised at first touch would
/// point at the worker's shared app for the rest of the file.
///
/// STRICT, ALSO ON PURPOSE. Falling back to 8080 for a variable that IS set
/// — to `""`, say, from a spawner that built the environment wrong — re-opens
/// exactly the hole this task closed: worker 3's test would connect to worker
/// 0's app and pass GREEN against another test's state. So a present-but-
/// unusable value is a REFUSAL. Only a variable nobody set at all falls back,
/// and it says so once on stderr, because that case is legitimate (a developer
/// running `scratch/worker_0/test_foo` by hand) and must still be visible if a
/// future spawner forgets.
@property ushort testPort() {
    string raw;
    bool present = true;
    try
        raw = environment[kPortEnv];
    catch (Exception)
        present = false;

    if (!present) {
        if (!g_announcedUnset) {
            g_announcedUnset = true;
            stderr.writefln("http_client: %s is not set — driving the default "
                ~ "port %d. Under `run_test.d` the runner sets it per worker; "
                ~ "if you are seeing this inside a suite run, the spawner "
                ~ "dropped it and this process is about to talk to whichever "
                ~ "instance happens to own %d.",
                kPortEnv, kDefaultPort, kDefaultPort);
            stderr.flush();
        }
        return kDefaultPort;
    }

    if (raw.length == 0)
        throw new Exception(kPortEnv ~ " is SET BUT EMPTY. That is a spawner "
            ~ "bug, not a request for the default: silently using "
            ~ kDefaultPort.to!string ~ " here would let this test drive another "
            ~ "worker's instance and pass. Set it to this worker's port, or "
            ~ "unset it entirely to mean the default.");

    ushort port;
    try
        port = raw.to!ushort;
    catch (ConvException)
        throw new Exception(kPortEnv ~ "=\"" ~ raw ~ "\" is not a port number.");

    if (port == 0)
        throw new Exception(kPortEnv ~ "=\"" ~ raw ~ "\" is not a usable port.");

    return port;
}

/// Base URL for the vibe3d instance assigned to this test process.
@property string testBaseUrl() {
    return "http://localhost:" ~ testPort.to!string;
}

JSONValue getJson(string path, string baseUrl = null) {
    string response;
    if (tryInProcess("GET", path, null, false, response))
        return parseJSON(response);
    const base = baseUrl.length ? baseUrl : testBaseUrl;
    return parseJSON(cast(string)get(base ~ path));
}

string postRaw(string path, string body_, string baseUrl = null) {
    string response;
    if (tryInProcess("POST", path, body_, false, response))
        return response;
    const base = baseUrl.length ? baseUrl : testBaseUrl;
    return cast(string)post(base ~ path, body_);
}

JSONValue postJson(string path, string body_, string baseUrl = null) {
    return parseJSON(postRaw(path, body_, baseUrl));
}

/// POST that tolerates a non-2xx status. `std.net.curl.post` throws on 500,
/// which HIDES the error body — and for a test whose subject IS that body
/// (tests/test_http_error_json.d) the body is the measurement. Lives here
/// rather than in that one file so the endpoint is resolved in exactly one
/// place, like the other three.
string postRawAllowingErrorStatus(string path, string body_, string baseUrl = null) {
    string response;
    if (tryInProcess("POST", path, body_, true, response))
        return response;
    const base = baseUrl.length ? baseUrl : testBaseUrl;
    auto http = HTTP();
    http.method = HTTP.Method.post;
    http.url = base ~ path;
    http.addRequestHeader("Content-Type", "application/json");
    http.setPostData(body_, "application/json");
    string resp;
    http.onReceive = (ubyte[] data) { resp ~= cast(string)data; return data.length; };
    http.onReceiveStatusLine = (HTTP.StatusLine) {};   // never throw on 4xx/5xx
    http.perform();
    return resp;
}

// ---------------------------------------------------------------------------
// Frame barriers (card test-sleep-removal). Both read /api/play-events/status,
// which is served on the main thread inside a tickAll pass and reports that
// pass as `frame`. They replace fixed sleeps with an observation of the frame
// loop, so they cost a few frames rather than a guessed wall-clock margin.
// ---------------------------------------------------------------------------

/// Wait until the HTTP replay reads `processed`: every event of the posted log
/// has been dispatched AND the frame that dispatched the last one has run to
/// completion (tool update, change flush, draw). `finished` alone flips before
/// that frame's tail, which is what the old post-replay sleeps covered.
void waitPlaybackProcessed(string baseUrl = null,
                           Duration budget = 60.seconds) {
    immutable deadline = MonoTime.currTime + budget;
    for (;;) {
        auto s = getJson("/api/play-events/status", baseUrl);
        if (auto p = "processed" in s)
            if (p.boolean) return;
        assert(MonoTime.currTime < deadline,
            "play-events did not reach processed within budget: " ~ s.toString());
        Thread.sleep(2.msecs);
    }
}

/// Frame fence: return once `frames` whole frames have completed after the
/// fence's first read. Every effect of a request ANSWERED before the call —
/// its synchronous edit and the per-frame flush and draw of the frame that
/// served it — has then run, so a counter read afterwards is final for that
/// request. It says nothing about work on another thread (an asynchronous
/// preview build): wait for that on its own route.
void frameFence(string baseUrl = null, uint frames = 1) {
    immutable start = getJson("/api/play-events/status", baseUrl)["frame"].integer;
    immutable deadline = MonoTime.currTime + 30.seconds;
    for (;;) {
        auto s = getJson("/api/play-events/status", baseUrl);
        if (s["frame"].integer >= start + frames) return;
        assert(MonoTime.currTime < deadline,
            "frame fence: the main loop did not advance: " ~ s.toString());
        Thread.sleep(1.msecs);
    }
}

/// The PACE meta line (card test-sleep-removal): the player delivers one
/// distinct `t` per frame, in order, instead of waiting the log's wall-clock
/// schedule. For a synthetic test log whose gaps mean "a frame between these".
enum string kPaceFramesLine = `{"t":0,"type":"PACE","mode":"frames"}` ~ "\n";

/// POST `log` frame-paced and wait until it is `processed`.
void playPacedAndWait(string log, string baseUrl = null) {
    auto r = postJson("/api/play-events", kPaceFramesLine ~ log, baseUrl);
    assert(r["status"].str == "success", "play-events failed: " ~ r.toString());
    waitPlaybackProcessed(baseUrl);
}

/// A frame fence that also outlasts the one asynchronous producer the frame
/// loop does not own: an in-flight subpatch preview build. After it returns,
/// no build is pending and a frame has completed since the last one landed.
/// Never use it while a test HOLDS a build (`/api/subpatch/hold`): the build
/// cannot land and this times out. Card test-sleep-removal.
void quiesce(string baseUrl = null) {
    frameFence(baseUrl);
    immutable deadline = MonoTime.currTime + 30.seconds;
    bool waited = false;
    for (;;) {
        auto s = getJson("/api/subpatch/preview", baseUrl);
        auto p = "pending" in s;
        if (p is null || !p.boolean) break;
        waited = true;
        assert(MonoTime.currTime < deadline,
            "quiesce: a subpatch preview build stayed pending: " ~ s.toString());
        Thread.sleep(2.msecs);
    }
    if (waited) frameFence(baseUrl);
}
