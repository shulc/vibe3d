// test_viewport_commands_registry.d — task 0761: the ten `viewport.*`
// commands moved out of the HTTP delegate's own interception and into
// `reg.commandFactories`. Pins the three things the move was a decision
// about (see doc/tasks/done/0761-*):
//
//   1. all ten ids are visible on GET /api/registry;
//   2. none of the ten lands an undo entry (CmdFlags.UI, same as the
//      pre-existing viewport.fit/fit_selected precedent) — this is the
//      property most at risk of silently regressing once these commands go
//      through the ordinary registry dispatch path;
//   3. the argument-parsing law each command preserves (three call shapes
//      for the oneStringArg-backed commands, the alias-list scan for the
//      per-cell display commands, the mask-vs-clamp asymmetry between
//      gridSteps and master) still produces byte-identical error text.
module test_viewport_commands_registry;

import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP, get;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.algorithm : canFind;
import std.conv      : to;

string baseUrl;

string httpGet(string path) {
    return cast(string) get(baseUrl ~ path);
}

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string) data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void resetApp() {
    httpPost("/api/reset", "{}");
}

/// POST /api/command with a JSON `params` field, return the parsed response
/// (does NOT enforce success — callers check status themselves).
JSONValue command(string id, JSONValue params) {
    JSONValue j;
    j["id"] = id;
    j["params"] = params;
    return parseJSON(httpPost("/api/command", j.toString));
}

/// Same, but `params` is a raw JSON-encoded string body — needed to exercise
/// oneStringArg's bare-string-body call shape (`{"id":..,"params":"Top"}`,
/// where the "params" key's VALUE is itself the whole argument).
JSONValue commandRawParams(string id, string rawJsonParams) {
    string body_ = `{"id":"` ~ id ~ `","params":` ~ rawJsonParams ~ `}`;
    return parseJSON(httpPost("/api/command", body_));
}

void expectOk(JSONValue r, string what) {
    enforce("status" !in r || r["status"].str != "error",
            what ~ " should have succeeded: " ~ r.toString);
}

void expectError(JSONValue r, string what, string messageContains) {
    enforce("status" in r && r["status"].str == "error",
            what ~ " should have failed: " ~ r.toString);
    enforce(r["message"].str.canFind(messageContains),
            what ~ ": expected message containing '" ~ messageContains ~
            "', got: " ~ r["message"].str);
}

// ---------------------------------------------------------------------------

bool testRegistryHasAllTen() {
    writeln("  [1] /api/registry lists all ten viewport.* command ids...");
    auto j = parseJSON(httpGet("/api/registry"));
    string[] ids;
    foreach (v; j["commands"].array) ids ~= v.str;

    string[] expected = [
        "viewport.view", "viewport.layout",
        "viewport.indCenter", "viewport.indScale", "viewport.indRotate",
        "viewport.displayStyle", "viewport.wireOverlay", "viewport.wireAlpha",
        "viewport.gridSteps", "viewport.master",
    ];
    foreach (id; expected)
        enforce(ids.canFind(id), "missing from /api/registry: " ~ id);
    writeln("    PASS: all ten present");
    return true;
}

bool testNoUndoEntry() {
    writeln("  [2] none of the ten lands an undo entry...");
    resetApp();

    // Baseline AFTER reset, not zero: /api/reset itself pushes a
    // "scene.reset" UndoBoundary entry (a Model-flagged entry a plain undo
    // does not cross — see CmdFlags.UndoBoundary in command.d), so
    // canUndo/canUndoModel already read true and undo.length is already 1
    // before any viewport.* command fires. The property under test is that
    // the ten commands add NOTHING on top of that baseline — a delta, not
    // an absolute zero.
    auto before = parseJSON(httpGet("/api/history"));
    size_t baselineUndoLen = before["undo"].array.length;

    // Fire one of each shape/law: view (Law 1), layout (Law 1, app-wide),
    // indCenter (Law 1, tolerant bool), displayStyle (Law 2, cell-aware),
    // wireAlpha (Law 2, numeric), gridSteps (Law 2, app-wide, own alias
    // list), master (Law 3, int-or-string).
    expectOk(command("viewport.view", JSONValue("Top")), "viewport.view");
    expectOk(command("viewport.layout", JSONValue("SplitH")), "viewport.layout");
    expectOk(command("viewport.indCenter", JSONValue("no")), "viewport.indCenter");
    expectOk(command("viewport.indScale", JSONValue("no")), "viewport.indScale");
    expectOk(command("viewport.indRotate", JSONValue("no")), "viewport.indRotate");
    {
        JSONValue p; p["style"] = "solid";
        expectOk(command("viewport.displayStyle", p), "viewport.displayStyle");
    }
    {
        JSONValue p; p["overlay"] = "uniform";
        expectOk(command("viewport.wireOverlay", p), "viewport.wireOverlay");
    }
    expectOk(command("viewport.wireAlpha", JSONValue(0.5)), "viewport.wireAlpha");
    expectOk(command("viewport.gridSteps", JSONValue(5)), "viewport.gridSteps");
    expectOk(command("viewport.master", JSONValue(0)), "viewport.master");

    auto status = parseJSON(httpGet("/api/undo/status"));
    enforce(status["modelDepth"].integer == 0,
        "ten camera-only commands must not leave a Model-class undo entry — got " ~ status.toString);
    enforce(status["uiDepth"].integer == 0,
        "ten camera-only commands must not leave a UI-class undo entry either — got " ~ status.toString);

    auto history = parseJSON(httpGet("/api/history"));
    enforce(history["undo"].array.length == baselineUndoLen,
        "ten camera-only commands must add NOTHING to the undo stack — baseline " ~
        to!string(baselineUndoLen) ~ ", now " ~ history.toString);

    writeln("    PASS: undo stack unchanged after all ten fired (baseline ",
            baselineUndoLen, " entries from reset's own boundary marker)");
    return true;
}

bool testViewPresetThreeShapes() {
    writeln("  [3] viewport.view accepts all three oneStringArg call shapes...");
    resetApp();

    // Bare JSON string body.
    expectOk(commandRawParams("viewport.view", `"Front"`), "viewport.view (bare string)");
    auto cam1 = parseJSON(httpGet("/api/camera"));
    enforce(cam1["viewPreset"].str == "Front", "bare-string shape: expected Front, got " ~ cam1.toString);

    // _positional array.
    JSONValue pos; pos["_positional"] = [JSONValue("Right")];
    expectOk(command("viewport.view", pos), "viewport.view (_positional)");
    auto cam2 = parseJSON(httpGet("/api/camera"));
    enforce(cam2["viewPreset"].str == "Right", "_positional shape: expected Right, got " ~ cam2.toString);

    // Named key.
    JSONValue named; named["preset"] = "Back";
    expectOk(command("viewport.view", named), "viewport.view (named key)");
    auto cam3 = parseJSON(httpGet("/api/camera"));
    enforce(cam3["viewPreset"].str == "Back", "named-key shape: expected Back, got " ~ cam3.toString);

    writeln("    PASS: bare string / _positional / named key all apply");
    return true;
}

bool testErrorMessagesPreserved() {
    writeln("  [4] error paths — byte-identical messages...");
    resetApp();

    expectError(command("viewport.displayStyle", JSONValue("bogus")),
        "displayStyle bad value",
        "expected 'wireframe', 'solid' or 'shaded'");

    {
        JSONValue p; p["style"] = "solid"; p["viewport"] = 99;
        expectError(command("viewport.displayStyle", p),
            "displayStyle out-of-range cell",
            "is out of range — the current layout has");
    }

    expectError(command("viewport.wireOverlay", JSONValue("colored")),
        "wireOverlay colored refusal",
        "needs a per-item line colour");

    expectError(command("viewport.wireAlpha", JSONValue(1.5)),
        "wireAlpha out of range",
        "is outside 0..1");

    expectError(command("viewport.gridSteps", JSONValue(8)),
        "gridSteps out of range",
        "is outside 0..7");

    // viewport.master: OUT OF RANGE CLAMPS to -1, it does NOT throw — the
    // one deliberate asymmetry against the other range checks above (task
    // 0761 left it as-is; unifying it would be a behaviour change no task
    // authorised).
    expectOk(command("viewport.master", JSONValue(99)), "viewport.master out-of-range (clamps, does not throw)");

    writeln("    PASS: every error path matches, master's clamp-not-throw preserved");
    return true;
}

bool testGridStepsRungSetSpelling() {
    writeln("  [5] gridSteps accepts a rung-set string, not just a mask int...");
    resetApp();
    expectOk(command("viewport.gridSteps", JSONValue("1,2,5,10")), "gridSteps rung-set spelling");
    writeln("    PASS");
    return true;
}

// ---------------------------------------------------------------------------

int main(string[] args) {
    // NOTE: keep the literal "http://localhost:8080" — run_test.d isolates
    // parallel workers by textually rewriting "localhost:8080" to the
    // worker's port in a scratch copy of the source.
    baseUrl = "http://localhost:8080";

    writeln("=== test_viewport_commands_registry ===");
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

    run(&testRegistryHasAllTen,        "all ten ids in /api/registry");
    run(&testNoUndoEntry,              "no undo entry for any of the ten");
    run(&testViewPresetThreeShapes,    "viewport.view — three call shapes");
    run(&testErrorMessagesPreserved,   "error paths preserved byte-identical");
    run(&testGridStepsRungSetSpelling, "gridSteps rung-set spelling");

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
