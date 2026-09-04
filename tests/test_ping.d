import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

alias baseUrl = testBaseUrl;

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

unittest { // GET /api/ping → 200 with status="ok"
    post(baseUrl ~ "/api/reset", "");
    HTTP.StatusLine sl;
    auto body = fetchCheck("/api/ping", sl);
    assert(sl.code == 200,
        "GET /api/ping should return 200, got " ~ sl.code.to!string);
    assert(parseJSON(body)["status"].str == "ok",
        "GET /api/ping body should have status=ok, got: " ~ body);
}

unittest { // POST /api/ping → 404 (GET-only branch falls through)
    HTTP.StatusLine sl;
    postCheck("/api/ping", "", sl);
    assert(sl.code == 404,
        "POST /api/ping should return 404, got " ~ sl.code.to!string);
}
