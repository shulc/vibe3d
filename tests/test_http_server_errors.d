// HTTP server error-path tests (Stage C6 of doc/test_coverage_plan.md).
//
// Pins how the server reacts to:
//   • unknown paths → HTTP 404
//   • malformed JSON in /api/command → status 200, status="error"
//     (the route returns 200 even on input errors so the client always
//      gets a parseable JSON body; the error lives in the body)
//   • empty body in /api/command
//   • unknown command id
//   • repeated concurrent commands serialize correctly (no lost replies)

import std.net.curl;
import std.json;
import std.conv : to;
import std.parallelism : parallel;
import std.range : iota;

void main() {}

string baseUrl = "http://localhost:8080";

// Plain HTTP helper that surfaces the status code AND body — std.net.curl's
// `get` / `post` throw on non-2xx by default, hiding the 404 path.
string fetchCheck(string path, out HTTP.StatusLine sl) {
    auto http = HTTP(baseUrl ~ path);
    http.method = HTTP.Method.get;
    string body;
    http.onReceive = (ubyte[] data) {
        body ~= cast(string)data;
        return data.length;
    };
    http.onReceiveStatusLine = (HTTP.StatusLine line) { sl = line; };
    http.perform();
    return body;
}

string postCheck(string path, string body_, out HTTP.StatusLine sl) {
    auto http = HTTP(baseUrl ~ path);
    http.method = HTTP.Method.post;
    http.postData = body_;
    string respBody;
    http.onReceive = (ubyte[] data) {
        respBody ~= cast(string)data;
        return data.length;
    };
    http.onReceiveStatusLine = (HTTP.StatusLine line) { sl = line; };
    http.perform();
    return respBody;
}

unittest { // unknown GET path → 404
    HTTP.StatusLine sl;
    fetchCheck("/api/does-not-exist", sl);
    assert(sl.code == 404,
        "unknown GET path should return 404, got " ~ sl.code.to!string);
}

unittest { // unknown POST path → 404 too
    HTTP.StatusLine sl;
    postCheck("/api/foo-bar-baz", `{"id":"file.new"}`, sl);
    assert(sl.code == 404,
        "unknown POST path should return 404, got " ~ sl.code.to!string);
}

unittest { // malformed JSON in /api/command → 200 with status="error"
    HTTP.StatusLine sl;
    auto body = postCheck("/api/command",
        `{"id": "file.new", "params": INVALID_JSON_HERE}`, sl);
    assert(sl.code == 200,
        "malformed JSON returns body-level error at HTTP 200, got " ~
        sl.code.to!string);
    auto j = parseJSON(body);
    assert(j["status"].str == "error",
        "malformed JSON body should yield status=error, got: " ~ body);
}

unittest { // empty body in /api/command → status="error"
    HTTP.StatusLine sl;
    auto body = postCheck("/api/command", "", sl);
    auto j = parseJSON(body);
    assert(j["status"].str == "error",
        "empty /api/command body should yield status=error, got: " ~ body);
}

unittest { // JSON with no "id" field → status="error"
    HTTP.StatusLine sl;
    auto body = postCheck("/api/command",
        `{"params": {"foo":1}}`, sl);
    auto j = parseJSON(body);
    assert(j["status"].str == "error",
        "missing 'id' field should yield status=error, got: " ~ body);
}

unittest { // unknown command id → status="error"
    HTTP.StatusLine sl;
    auto body = postCheck("/api/command",
        `{"id":"this.command.does.not.exist"}`, sl);
    auto j = parseJSON(body);
    assert(j["status"].str == "error",
        "unknown command id should yield status=error, got: " ~ body);
}

unittest { // concurrent /api/command calls all complete with consistent state
    // Reset to a known starting point.
    post(baseUrl ~ "/api/reset", "");

    // Fire eight concurrent file.new commands in parallel. Each one
    // wipes the scene to empty; running them concurrently shouldn't
    // produce timeouts or lost responses (the main-thread bridge
    // serializes them through pendingCmdId / submittedEpoch).
    bool[8] okFlags;
    foreach (i; iota(8).parallel(1)) {
        auto resp = post(baseUrl ~ "/api/command", `{"id":"file.new"}`);
        auto j = parseJSON(cast(string)resp);
        okFlags[i] = (j["status"].str == "ok");
    }
    foreach (i, ok; okFlags)
        assert(ok, "concurrent file.new #" ~ i.to!string ~ " did not return ok");

    // Final mesh state should be the result of the LAST processed
    // file.new (an empty mesh). The exact intermediate ordering doesn't
    // matter — what matters is that no command silently dropped.
    auto m = parseJSON(cast(string)get(baseUrl ~ "/api/model"));
    assert(m["vertices"].array.length == 0,
        "after 8 concurrent file.new, mesh should be empty; got " ~
        m["vertices"].array.length.to!string ~ " verts");
}
