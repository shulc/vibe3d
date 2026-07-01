// test_viewport_independence.d — Phase-5 per-cell independence follow + commands.
//
// Flow A: Quad linked defaults — follower center+scale follow master.
// Flow B: Explicit viewport.master + viewport.indCenter commands.
// Regression: default GET/POST /api/camera (no query) unchanged.
module test_viewport_independence;

import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.math      : isClose;
import std.conv      : to;

// --------------------------------------------------------------------------
// Helpers
// --------------------------------------------------------------------------

string baseUrl;

string httpGet(string path) {
    import std.net.curl : get;
    return cast(string)get(baseUrl ~ path);
}

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void postCommand(string cmd, string params = "") {
    JSONValue j;
    j["id"] = cmd;
    if (params.length) j["params"] = params;
    string resp = httpPost("/api/command", j.toString);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " failed: " ~ resp);
}

void resetApp() {
    httpPost("/api/reset", "{}");
}

double getField(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    switch (cur.type) {
        case JSONType.float_:   return cur.floating;
        case JSONType.integer:  return cast(double)cur.integer;
        case JSONType.uinteger: return cast(double)cur.uinteger;
        default: throw new Exception("not a number at " ~ path[$-1]);
    }
}

// --------------------------------------------------------------------------
// Flow A — Quad linked defaults
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] Quad linked defaults...");
    resetApp();

    // Switch to Quad layout: cells 0-2 get indCenter=false, indScale=false;
    // cell 3 = persp master (masterId=3).
    postCommand("viewport.layout", "Quad");

    // Record cell 0's own distance before touching the master.
    auto cam0before = parseJSON(httpGet("/api/camera?viewport=0"));
    double ownDist = getField(cam0before, "distance");

    // POST-pan the master (cell 3) to focus.x = 5.
    string resp3 = httpPost("/api/camera?viewport=3", `{"focus":{"x":5,"y":0,"z":0}}`);
    auto r3 = parseJSON(resp3);
    enforce(r3["status"].str == "ok", "POST camera?viewport=3 failed: " ~ resp3);

    // GET follower (cell 0) resolved camera — focus.x must track master.
    auto cam0 = parseJSON(httpGet("/api/camera?viewport=0"));
    double fx = getField(cam0, "focus", "x");
    enforce(isClose(fx, 5.0, 1e-3), "Flow A: follower focus.x must track master (got " ~ to!string(fx) ~ ")");
    writeln("    A1 PASS: follower focus.x tracks master (", fx, ")");

    // Flip cell 0 indScale to yes (own) via viewport.indScale command.
    // Cell 0 is the active cell after Quad (activeId defaults to 0).
    postCommand("viewport.indScale", "yes");

    // POST-zoom the master distance.
    string respb = httpPost("/api/camera?viewport=3", `{"distance":10}`);
    enforce(parseJSON(respb)["status"].str == "ok", "POST camera distance failed");

    // GET cell 0 resolved — distance must be OWN (not 10); focus.x still follows.
    auto cam0b = parseJSON(httpGet("/api/camera?viewport=0"));
    double dist0 = getField(cam0b, "distance");
    enforce(isClose(dist0, ownDist, 1e-3),
        "Flow A: indScale=yes must keep own distance (expected " ~
        to!string(ownDist) ~ ", got " ~ to!string(dist0) ~ ")");
    double fx2 = getField(cam0b, "focus", "x");
    enforce(isClose(fx2, 5.0, 1e-3), "Flow A: focus.x must still track master after indScale flip");
    writeln("    A2 PASS: own distance preserved (", dist0, "), center still follows (", fx2, ")");

    return true;
}

// --------------------------------------------------------------------------
// Flow B — explicit viewport.master + viewport.indCenter
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] Explicit viewport.master + indCenter...");
    resetApp();

    // SplitH: 2 cells, fully-independent, group master=0; active=0.
    postCommand("viewport.layout", "SplitH");

    // Give cell 1 a distinct focus.
    string respSet1 = httpPost("/api/camera?viewport=1", `{"focus":{"x":7,"y":0,"z":0}}`);
    enforce(parseJSON(respSet1)["status"].str == "ok", "POST camera cell 1 failed");

    // Record cell 0's own distance.
    auto cam0base = parseJSON(httpGet("/api/camera?viewport=0"));
    double ownDist = getField(cam0base, "distance");

    // Cell 0 is active: set masterId=1 (follow cell 1's center).
    postCommand("viewport.master", "1");
    postCommand("viewport.indCenter", "no");

    // GET resolved cell 0 — focus.x must be 7.
    auto cam0res = parseJSON(httpGet("/api/camera?viewport=0"));
    double fx = getField(cam0res, "focus", "x");
    enforce(isClose(fx, 7.0, 1e-3),
        "Flow B: cell 0 focus.x must follow cell 1 (got " ~ to!string(fx) ~ ")");
    writeln("    B1 PASS: indCenter=no follows master focus.x (", fx, ")");

    // Scale still own (indScale=true by default after SplitH).
    double dist0 = getField(cam0res, "distance");
    enforce(isClose(dist0, ownDist, 1e-3),
        "Flow B: distance must remain own (expected " ~
        to!string(ownDist) ~ ", got " ~ to!string(dist0) ~ ")");
    writeln("    B2 PASS: distance still own (", dist0, ")");

    return true;
}

// --------------------------------------------------------------------------
// Regression — default GET/POST /api/camera (no query) unchanged
// --------------------------------------------------------------------------

bool testRegression() {
    writeln("  [R] Default GET/POST /api/camera regression...");
    resetApp();

    // GET without ?viewport param (Single layout, cell 0, self-master).
    auto cam = parseJSON(httpGet("/api/camera"));
    enforce("azimuth" in cam, "Regression: GET /api/camera must return azimuth");
    enforce("focus"   in cam, "Regression: GET /api/camera must return focus");
    enforce("eye"     in cam, "Regression: GET /api/camera must return eye");
    writeln("    R1 PASS: GET /api/camera fields present");

    // POST without ?viewport param — moves active camera.
    string resp = httpPost("/api/camera", `{"azimuth":1.23}`);
    enforce(parseJSON(resp)["status"].str == "ok", "Regression: POST /api/camera failed");
    auto cam2 = parseJSON(httpGet("/api/camera"));
    enforce(isClose(getField(cam2, "azimuth"), 1.23, 1e-3),
        "Regression: POST /api/camera must update active camera azimuth");
    writeln("    R2 PASS: POST /api/camera updates active camera");

    return true;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------

int main(string[] args) {
    // NOTE: keep the literal "http://localhost:8080" — run_test.d isolates
    // parallel workers by textually rewriting "localhost:8080" to the worker's
    // port in a scratch copy of the source.  Building the URL from an env var
    // (VIBE3D_TEST_PORT is never set by the runner) would defeat that rewrite
    // and make every worker hit port 8080 → cross-worker state corruption.
    baseUrl = "http://localhost:8080";

    writeln("=== test_viewport_independence ===");
    int passed = 0, failed = 0;

    void run(bool function() fn, string name) {
        try {
            if (fn()) { writeln("  PASS: ", name); passed++; }
            else       { writeln("  FAIL: ", name); failed++; }
        } catch (Exception e) {
            writefln("  FAIL: %s — %s", name, e.msg);
            failed++;
        }
    }

    run(&testFlowA,      "Flow A — Quad linked-center+scale follow");
    run(&testFlowB,      "Flow B — explicit master + indCenter");
    run(&testRegression, "Regression — default GET/POST /api/camera");

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
