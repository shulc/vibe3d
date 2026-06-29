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

unittest { // smooth subdivide: undo restores 8/12/6 cube; redo re-applies
    postJson("/api/reset", "");
    // switch to polygon mode (required by subdivide guard)
    postJson("/api/command", "select.typeFrom polygon");
    postJson("/api/command", "history.clear");
    auto r = postJson("/api/command",
        `{"id":"mesh.subdivide","params":{"mode":"smooth"}}`);
    assert(r["status"].str == "ok", "smooth subdivide failed: " ~ r.toString);

    // After smooth: 26/48/24.
    auto mAfter = parseJSON(cast(string) get(baseUrl ~ "/api/model"));
    assert(mAfter["vertexCount"].integer == 26,
        "smooth: expected 26 verts after apply, got "
        ~ mAfter["vertexCount"].integer.to!string);
    assert(mAfter["faceCount"].integer == 24);

    // Undo → back to cube 8/12/6.
    postJson("/api/undo", "");
    auto mUndo = parseJSON(cast(string) get(baseUrl ~ "/api/model"));
    assert(mUndo["vertexCount"].integer == 8,
        "smooth undo: expected 8 verts (cube), got "
        ~ mUndo["vertexCount"].integer.to!string);
    assert(mUndo["faceCount"].integer == 6,
        "smooth undo: expected 6 faces (cube), got "
        ~ mUndo["faceCount"].integer.to!string);

    // Redo entry exists.
    auto h = getJson("/api/history");
    assert(h["redo"].array.length >= 1,
        "smooth undo: redo should have an entry; got " ~ h.toString);

    // Redo → back to 26/48/24.
    postJson("/api/command", "history.redo");
    auto mRedo = parseJSON(cast(string) get(baseUrl ~ "/api/model"));
    assert(mRedo["vertexCount"].integer == 26,
        "smooth redo: expected 26 verts, got "
        ~ mRedo["vertexCount"].integer.to!string);
    assert(mRedo["faceCount"].integer == 24,
        "smooth redo: expected 24 faces, got "
        ~ mRedo["faceCount"].integer.to!string);
}
