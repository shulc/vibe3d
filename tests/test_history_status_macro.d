// Phase 7 of the history-panel design doc — verifies
// (a) per-entry `flags` propagates through /api/history, and
// (b) macro.record + macro.saveRecorded capture-and-write cycle
// produces a #LXMacro# file with the executed argstrings.

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
    assert(resp["status"].str == "ok", "translate failed: " ~ resp.toString);
}

unittest { // /api/history surfaces a non-zero flags field; the bit
           // pattern includes Succeeded (1) + Undoable (16) = 17.
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);

    translate(0.1);

    auto undo = getJson("/api/history")["undo"].array;
    assert(undo.length >= 1, "expected at least 1 undo entry");
    auto last = undo[$ - 1];
    assert("flags" in last,
        "history entries should expose flags; got: " ~ last.toString);
    long flags = last["flags"].integer;
    // HistoryFlags.Succeeded (1) | HistoryFlags.Undoable (16) = 17.
    long SUCCEEDED = 1, UNDOABLE = 16;
    assert((flags & SUCCEEDED) != 0,
        "Succeeded bit not set; flags=" ~ flags.to!string);
    assert((flags & UNDOABLE) != 0,
        "Undoable bit not set; flags=" ~ flags.to!string);
}

unittest { // macro.record state:1 starts capture; subsequent
           // commands land in the buffer; macro.saveRecorded writes
           // a #LXMacro# file with one line per captured argstring.
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);

    auto r = postJson("/api/command", "macro.record state:1");
    assert(r["status"].str == "ok",
        "macro.record start failed: " ~ r.toString);

    translate(0.1);
    translate(0.2);

    string path = "/tmp/test_macro_recorded.lxm";
    if (exists(path)) remove(path);
    r = postJson("/api/command",
        "macro.saveRecorded path:\"" ~ path ~ "\"");
    assert(r["status"].str == "ok",
        "macro.saveRecorded failed: " ~ r.toString);
    assert(exists(path), "output file not created");

    auto content = readText(path);
    import std.algorithm : startsWith, canFind, count;
    assert(content.startsWith("#LXMacro#"),
        "missing LXMacro header; got: " ~ content[0 .. 30]);
    // Both translates captured as mesh.transform argstrings — two
    // body lines + header line ≥ 3 newlines.
    assert(content.canFind("mesh.transform"),
        "expected mesh.transform in macro; got: " ~ content);
    size_t lines = content.count('\n');
    assert(lines >= 3,
        "expected >=3 newlines (header + 2 entries); got " ~ lines.to!string
        ~ " in:\n" ~ content);

    remove(path);
}

unittest { // macro.record state:0 stops capture; commands after
           // stop are NOT in the saved file.
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    postJson("/api/select", `{"mode":"vertices","indices":[6]}`);

    postJson("/api/command", "macro.record state:1");
    translate(0.1);
    postJson("/api/command", "macro.record state:0");
    translate(0.2);   // post-stop — should NOT be captured

    string path = "/tmp/test_macro_stop.lxm";
    if (exists(path)) remove(path);
    auto r = postJson("/api/command",
        "macro.saveRecorded path:\"" ~ path ~ "\"");
    assert(r["status"].str == "ok",
        "macro.saveRecorded failed: " ~ r.toString);

    auto content = readText(path);
    import std.algorithm : count;
    // Only the FIRST translate should appear → exactly 1 mesh.transform.
    import std.algorithm : countUntil;
    size_t occurrences = 0;
    size_t idx = 0;
    while (true) {
        auto found = content[idx .. $].countUntil("mesh.transform");
        if (found < 0) break;
        occurrences++;
        idx += found + "mesh.transform".length;
    }
    assert(occurrences == 1,
        "expected 1 mesh.transform after stop; got "
        ~ occurrences.to!string ~ " in:\n" ~ content);

    remove(path);
}

unittest { // macro.saveRecorded without `path` arg fails apply().
    postJson("/api/reset", "");
    auto r = postJson("/api/command", "macro.saveRecorded");
    assert(r["status"].str != "ok",
        "saveRecorded without path should fail; got " ~ r.toString);
}
