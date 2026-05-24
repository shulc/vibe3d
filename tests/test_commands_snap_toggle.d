// snap.toggle + snap.toggleType command tests (Stage C3 of
// doc/test_coverage_plan.md).
//
// snap.toggle: flips SnapStage.enabled.
// snap.toggleType <name>: flips one SnapType bit in enabledTypes.
//
// Both read back from /api/toolpipe SNAP stage's listAttrs.

import std.net.curl;
import std.json;
import std.conv : to;
import std.algorithm : canFind, splitter;
import std.array : array;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

void runCmd(string argstring) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/command", argstring));
    assert(r["status"].str == "ok",
        "/api/command \"" ~ argstring ~ "\" failed: " ~ r.toString);
}

string[string] snapAttrs() {
    auto j = getJson("/api/toolpipe");
    foreach (st; j["stages"].array) {
        if (st["task"].str == "SNAP") {
            string[string] m;
            foreach (k, v; st["attrs"].object) m[k] = v.str;
            return m;
        }
    }
    assert(false, "SNAP stage not found");
}

bool typeOn(string types, string name) {
    return types.splitter(',').array.canFind(name);
}

unittest { // snap.toggle: false → true → false
    post(baseUrl ~ "/api/reset", "");
    auto a0 = snapAttrs();
    bool start = a0["enabled"] == "true";

    runCmd("snap.toggle");
    auto a1 = snapAttrs();
    assert((a1["enabled"] == "true") != start,
        "first toggle should flip enabled; was " ~ a0["enabled"] ~
        " now " ~ a1["enabled"]);

    runCmd("snap.toggle");
    auto a2 = snapAttrs();
    assert((a2["enabled"] == "true") == start,
        "second toggle should restore initial state; was " ~ a0["enabled"] ~
        " after two toggles " ~ a2["enabled"]);
}

unittest { // snap.toggleType: flips a single SnapType bit on/off
    post(baseUrl ~ "/api/reset", "");
    // Pin to a known starting set so the test isn't sensitive to
    // whichever defaults the engine ships with today.
    runCmd("tool.pipe.attr snap types vertex");
    auto a0 = snapAttrs();
    assert( typeOn(a0["types"], "vertex"),    "setup: vertex should be on, got " ~ a0["types"]);
    assert(!typeOn(a0["types"], "edge"),       "setup: edge should be off");
    assert(!typeOn(a0["types"], "polyCenter"), "setup: polyCenter should be off");

    runCmd("snap.toggleType edge");
    auto a1 = snapAttrs();
    assert(typeOn(a1["types"], "edge"),
        "toggleType edge should add edge to the mask: " ~ a1["types"]);
    assert(typeOn(a1["types"], "vertex"),
        "toggleType edge shouldn't drop vertex: " ~ a1["types"]);

    runCmd("snap.toggleType edge");
    auto a2 = snapAttrs();
    assert(!typeOn(a2["types"], "edge"),
        "second toggleType edge should remove edge: " ~ a2["types"]);

    // Multiple distinct types stack independently.
    runCmd("snap.toggleType grid");
    runCmd("snap.toggleType polyCenter");
    auto a3 = snapAttrs();
    assert(typeOn(a3["types"], "grid"),       "grid should be on: " ~ a3["types"]);
    assert(typeOn(a3["types"], "polyCenter"), "polyCenter should be on: " ~ a3["types"]);
    assert(typeOn(a3["types"], "vertex"),     "vertex should still be on: " ~ a3["types"]);
}
