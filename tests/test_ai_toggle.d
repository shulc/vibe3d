// AI master toggle and no-op advisor shell tests.
//
// Phase A keeps AI behavior inert: commands only flip editor UI state,
// /api/toolpipe/eval exposes the status payload, and no undo entries are
// recorded.

import std.net.curl;
import std.json;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}

JSONValue aiStatus() {
    auto j = getJson("/api/toolpipe/eval");
    assert("ai" in j, "/api/toolpipe/eval must include ai block: " ~ j.toString);
    return j["ai"];
}

bool aiEnabled() {
    return aiStatus()["enabled"].boolean;
}

void runCmd(string argstring) {
    auto r = postJson("/api/command", argstring);
    assert(r["status"].str == "ok",
        "/api/command \"" ~ argstring ~ "\" failed: " ~ r.toString);
}

size_t historyLen(string side) {
    return getJson("/api/history")[side].array.length;
}

unittest { // default-off and advisor shell payload
    postJson("/api/reset", "");
    auto ai = aiStatus();
    assert(ai["enabled"].boolean == false,
        "AI must default off; got " ~ ai.toString);
    assert(ai["advisor"]["intent"].str == "keepDefault",
        "Phase-A advisor must keep default; got " ~ ai.toString);
    assert(ai["advisor"]["confidence"].floating == 0.0,
        "Phase-A advisor confidence must be 0; got " ~ ai.toString);
}

unittest { // enable / disable / toggle
    runCmd("ai.disable");
    assert(!aiEnabled(), "ai.disable must leave AI disabled");

    runCmd("ai.enable");
    assert(aiEnabled(), "ai.enable must enable AI");

    runCmd("ai.disable");
    assert(!aiEnabled(), "ai.disable must disable AI");

    runCmd("ai.toggle");
    assert(aiEnabled(), "ai.toggle must flip off -> on");

    runCmd("ai.toggle");
    assert(!aiEnabled(), "ai.toggle must flip on -> off");
}

unittest { // undo-neutrality
    runCmd("ai.disable");
    runCmd("history.clear");
    size_t undo0 = historyLen("undo");
    size_t redo0 = historyLen("redo");

    runCmd("ai.enable");
    runCmd("ai.toggle");
    runCmd("ai.disable");

    assert(historyLen("undo") == undo0,
        "AI commands must not record undo entries");
    assert(historyLen("redo") == redo0,
        "AI commands must not touch redo entries");
}
