// Tests for phase 7.0: Tool Pipe skeleton.
//
// Verifies the pipeline data structures are exposed via /api/toolpipe and
// that the empty-pipeline default returns a sane "no stages registered"
// response. Phase 7.0 ships only the type system + global singleton; the
// pipe has zero non-actor stages registered, so the snapshot should
// always be `{"stages":[]}`.
//
// Later subphases (7.1 Workplane, 7.2 ACEN/AXIS, etc.) extend the API
// with stage-mutation commands and replace this minimum-viable test
// with richer assertions.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}

// -------------------------------------------------------------------------
// 1. /api/toolpipe responds with a JSON envelope containing a "stages"
//    array. Phase 7.0 has no stages registered → the array is empty.
// -------------------------------------------------------------------------

unittest { // empty pipeline by default
    auto j = getJson("/api/toolpipe");
    assert("stages" in j.object,
        "/api/toolpipe must expose a 'stages' field, got: " ~ j.toString);
    assert(j["stages"].type == JSONType.array,
        "'stages' must be an array, got " ~ j["stages"].type.to!string);
    assert(j["stages"].array.length == 0,
        "phase 7.0 ships zero non-actor stages; got "
        ~ j["stages"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. Endpoint is idempotent — repeated GETs return identical payloads.
// -------------------------------------------------------------------------

unittest { // idempotent
    auto a = getJson("/api/toolpipe");
    auto b = getJson("/api/toolpipe");
    assert(a.toString == b.toString,
        "/api/toolpipe should be idempotent, got differing payloads");
}
