/// tests/http_client.d — the ONE HTTP transport every suite driver talks to
/// its worker's `vibe3d --test` through.
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
    const base = baseUrl.length ? baseUrl : testBaseUrl;
    return parseJSON(cast(string)get(base ~ path));
}

string postRaw(string path, string body_, string baseUrl = null) {
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
