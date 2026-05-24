// Repro: subdivide → undo should leave a redo entry. The user
// reports the History panel shows only the cursor row with no
// dimmed redo line below it. This test pins down whether the
// bug is in the panel render or in the actual undo/redo stack.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string baseUrl = "http://localhost:8080";

JSONValue getJson(string path) {
    return parseJSON(cast(string) get(baseUrl ~ path));
}
JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string) post(baseUrl ~ path, body_));
}

unittest { // baseline: /api/undo path
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    postJson("/api/command", "mesh.subdivide");
    postJson("/api/undo", "");

    auto h = getJson("/api/history");
    import std.stdio : writeln;
    writeln("[/api/undo] after undo: ", h.toString);
    assert(h["redo"].array.length >= 1,
        "/api/undo: redo should have entry; got " ~ h.toString);
}

unittest { // through the command dispatcher (same path Ctrl-Z takes)
    postJson("/api/reset", "");
    postJson("/api/command", "history.clear");
    postJson("/api/command", "mesh.subdivide");
    auto r = postJson("/api/command", "history.undo");
    assert(r["status"].str == "ok",
        "history.undo command failed: " ~ r.toString);

    auto h = getJson("/api/history");
    import std.stdio : writeln;
    writeln("[history.undo cmd] after undo: ", h.toString);
    assert(h["redo"].array.length >= 1,
        "history.undo cmd: redo should have entry; got " ~ h.toString);
}
