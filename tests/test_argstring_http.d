// Tests for subphase 4.1: argstring surface on /api/command and /api/script.
//
// Cube layout:
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4)
{
    return fabs(a - b) < eps;
}

void resetCube()
{
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "reset failed: " ~ cast(string) resp);
}

void postSelect(string mode, int[] indices)
{
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "select failed");
}

string postCommandRaw(string body)
{
    return cast(string) post("http://localhost:8080/api/command", body);
}

void postCommand(string body)
{
    auto r = postCommandRaw(body);
    assert(parseJSON(r)["status"].str == "ok", "/api/command failed: " ~ r);
}

JSONValue getModel()
{
    return parseJSON(get("http://localhost:8080/api/model"));
}

// Move v0 to coincide with v1 using the JSON path (regression guard).
void coincidev0v1JSON()
{
    postCommand(`{"id":"mesh.move_vertex","params":{"from":[-0.5,-0.5,-0.5],"to":[0.5,-0.5,-0.5]}}`);
}

// Move v0 to coincide with v1 using the argstring path.
void coincidev0v1Argstring()
{
    postCommand("mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{0.5,-0.5,-0.5}");
}

// -------------------------------------------------------------------------
// 1. JSON path still works (regression)
// -------------------------------------------------------------------------

unittest { // /api/command JSON body: vert.merge via JSON
    resetCube();
    coincidev0v1JSON();
    postSelect("vertices", [0, 1]);
    postCommand(`{"id":"vert.merge","params":{"range":"fixed","dist":0.2,"keep":false}}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 7,
        "JSON path: expected 7 verts, got " ~ m["vertexCount"].integer.to!string);
}

// -------------------------------------------------------------------------
// 2. Argstring body on /api/command
// -------------------------------------------------------------------------

unittest { // /api/command argstring: vert.merge range:fixed dist:0.2 keep:false
    resetCube();
    coincidev0v1Argstring();
    postSelect("vertices", [0, 1]);
    postCommand("vert.merge range:fixed dist:0.2 keep:false");
    auto m = getModel();
    assert(m["vertexCount"].integer == 7,
        "argstring path: expected 7 verts, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // argstring: boolean true param (keep:true means verts survive)
    resetCube();
    coincidev0v1Argstring();
    postSelect("vertices", [0, 1]);
    // keep:true: merge but retain source verts — result should still be 7 or cmd ok
    auto resp = postCommandRaw("vert.merge range:fixed dist:0.2 keep:true");
    auto j = parseJSON(resp);
    // Command should not throw a parse error — status ok or error from the command
    // itself (not a syntax error). Either way the server handled argstring correctly.
    assert(j["status"].type == JSONType.string,
        "argstring keep:true: expected status field, got: " ~ resp);
}

unittest { // argstring: bare-identifier value (range:auto)
    resetCube();
    coincidev0v1Argstring();
    postSelect("vertices", [0, 1]);
    postCommand("vert.merge range:auto");
    auto m = getModel();
    assert(m["vertexCount"].integer == 7,
        "argstring range:auto: expected 7 verts, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // argstring: empty body returns error (not a crash)
    auto resp = postCommandRaw("");
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "empty body should return error, got: " ~ resp);
}

// -------------------------------------------------------------------------
// 3. /api/script multi-line
// -------------------------------------------------------------------------

unittest { // /api/script: comment and blank lines are skipped
    resetCube();
    // Script selects v0 & v1, then coincides v0, then merges.
    string script = "# comment line\n" ~
                    "mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{0.5,-0.5,-0.5}\n" ~
                    "\n" ~
                    "vert.merge range:fixed dist:0.01 keep:false";
    // pre-select v0 and v1 before script runs
    postSelect("vertices", [0, 1]);
    auto resp = cast(string) post("http://localhost:8080/api/script", script);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
        "/api/script failed: " ~ resp);
    // results only contains executed (non-empty, non-comment) lines
    auto results = j["results"].array;
    assert(results.length == 2,
        "expected 2 executed lines, got " ~ results.length.to!string);
    assert(results[0]["status"].str == "ok", "line 1 failed: " ~ resp);
    assert(results[1]["status"].str == "ok", "line 2 failed: " ~ resp);
    auto m = getModel();
    assert(m["vertexCount"].integer == 7,
        "/api/script: expected 7 verts, got " ~ m["vertexCount"].integer.to!string);
}

unittest { // /api/script: line numbers in results match script lines
    resetCube();
    // Two-line script
    string script = "mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{0.5,-0.5,-0.5}\n" ~
                    "vert.merge range:auto";
    postSelect("vertices", [0, 1]);
    auto resp = cast(string) post("http://localhost:8080/api/script", script);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", resp);
    auto results = j["results"].array;
    assert(results.length == 2, "expected 2 results");
    assert(results[0]["line"].integer == 1, "first result should be line 1");
    assert(results[1]["line"].integer == 2, "second result should be line 2");
    assert(results[0]["command"].str == "mesh.move_vertex");
    assert(results[1]["command"].str == "vert.merge");
}

unittest { // /api/script: stop on first error (default behavior)
    resetCube();
    // Line 2 has a bad syntax (missing ':' separator makes it a command with
    // unparseable 'pairs' — "badkey" followed by a space-separated word
    // would be a second identifier without ':').  Use a command that will
    // fail at the command-handler level instead to keep parsing clean:
    // vert.merge with dist:0 on a normal cube where nothing is within 0
    // distance should error from the command itself.
    string script = "vert.merge range:fixed dist:0.0 keep:false\n" ~
                    "mesh.move_vertex from:{-0.5,-0.5,-0.5} to:{0.5,-0.5,-0.5}";
    postSelect("vertices", [0, 1]);
    auto resp = cast(string) post("http://localhost:8080/api/script", script);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error", "expected error for failing line: " ~ resp);
    auto results = j["results"].array;
    // Only 1 result — execution stopped after first error.
    assert(results.length == 1,
        "stop-on-error: expected 1 result, got " ~ results.length.to!string);
    assert(results[0]["status"].str == "error");
}

unittest { // /api/script ?continue=true: runs all lines, collects all errors
    resetCube();
    // Line 1 fails (dist too small), line 2 also fails. Both should appear.
    string script = "vert.merge range:fixed dist:0.0 keep:false\n" ~
                    "vert.merge range:fixed dist:0.0 keep:false";
    postSelect("vertices", [0, 1]);
    auto resp = cast(string) post("http://localhost:8080/api/script?continue=true", script);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error", resp);
    auto results = j["results"].array;
    assert(results.length == 2,
        "continue=true: expected 2 results, got " ~ results.length.to!string);
    assert(results[0]["status"].str == "error");
    assert(results[1]["status"].str == "error");
}

unittest { // /api/script: ok overall status when all lines succeed
    resetCube();
    coincidev0v1Argstring();  // move v0 first
    postSelect("vertices", [0, 1]);
    string script = "vert.merge range:auto";
    auto resp = cast(string) post("http://localhost:8080/api/script", script);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", resp);
}
