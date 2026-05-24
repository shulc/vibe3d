// history.clear + history.saveAsScript command tests (Phase 3 of
// the history-panel design doc). The right-click panel
// menu items dispatch these commands; the test drives them through
// /api/command so we don't depend on ImGui rendering.

import std.net.curl;
import std.json;
import std.conv : to;
import std.file : exists, readText, remove;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

size_t historyLen(string side) {
    return getJson("/api/history")[side].array.length;
}

void translate(double dx) {
    auto resp = postJson("/api/transform",
        `{"kind":"translate","delta":[` ~ dx.to!string ~ `,0,0]}`);
    assert(resp["status"].str == "ok");
}

unittest { // history.clear wipes both undo + redo stacks.
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);

    translate(0.1);
    translate(0.1);
    postJson("/api/undo", "");
    // Now: undo >= 1, redo == 1.
    size_t undoBefore = historyLen("undo");
    size_t redoBefore = historyLen("redo");
    assert(undoBefore >= 1 && redoBefore == 1,
        "expected undo>=1 redo==1; got "
        ~ undoBefore.to!string ~ "/" ~ redoBefore.to!string);

    auto r = postJson("/api/command", "history.clear");
    assert(r["status"].str == "ok",
        "history.clear failed: " ~ r.toString);
    assert(historyLen("undo") == 0 && historyLen("redo") == 0,
        "after history.clear both stacks must be empty; got "
        ~ historyLen("undo").to!string ~ "/"
        ~ historyLen("redo").to!string);
}

unittest { // history.saveAsScript writes #LXMacro# header + one
           // argstring per undo entry.
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");   // pristine
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);

    translate(0.1);
    translate(0.2);

    string path = "/tmp/test_history_save.lxm";
    if (exists(path)) remove(path);
    auto r = postJson("/api/command",
        "history.saveAsScript path:\"" ~ path ~ "\"");
    assert(r["status"].str == "ok",
        "saveAsScript failed: " ~ r.toString);
    assert(exists(path), "output file not created");

    auto content = readText(path);
    assert(content.length > 0, "output file empty");
    import std.algorithm : startsWith, canFind;
    assert(content.startsWith("#LXMacro#"),
        "missing LXMacro header; got: " ~ content[0 .. 30]);
    // Each translate appears as a mesh.transform argstring.
    assert(content.canFind("mesh.transform"),
        "expected mesh.transform argstrings; got: " ~ content);

    remove(path);
}

unittest { // saveAsScript without `path` arg fails apply() — no
           // file is written.
    postJson("/api/reset", "");
    auto r = postJson("/api/command", "history.saveAsScript");
    // The argstring parser may either error (missing required
    // positional) or the command's apply() returns false (path
    // empty). Either way it's NOT "ok".
    assert(r["status"].str != "ok",
        "saveAsScript without path should not succeed; got "
        ~ r.toString);
}
