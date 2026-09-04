module http_client;

import std.json : JSONValue, parseJSON;
import std.net.curl : get, post;
import std.process : environment;

/// Base URL for the vibe3d instance assigned to this test process.
/// Direct/manual invocations retain the historical port 8080 default.
@property string testBaseUrl() {
    auto port = environment.get("VIBE3D_TEST_PORT", "8080");
    if (port.length == 0) port = "8080";
    return "http://localhost:" ~ port;
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
