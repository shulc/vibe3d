// Tests for mesh.setPart — assigns a per-face numeric part id to selected
// faces via /api/command. Verifies assignment, undo, empty-selection no-op,
// wrong-mode rejection, and .v3d round-trip persistence.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;
import std.file : tempDir, remove, exists;
import std.path : buildPath;

void main() {}

// ── helpers ──────────────────────────────────────────────────────────────────

void resetCube() {
    post("http://localhost:8080/api/reset", "");
    // mesh.setPart is a Polygons-mode command.
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
}

string postCommandRaw(string body) {
    return cast(string) post("http://localhost:8080/api/command", body);
}

void postCommand(string body) {
    auto resp = postCommandRaw(body);
    assert(parseJSON(resp)["status"].str == "ok",
        "command failed: " ~ resp);
}

void setSelection(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) {
        if (i > 0) idxJson ~= ",";
        idxJson ~= v.to!string;
    }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

void postUndo() {
    auto resp = post("http://localhost:8080/api/undo", "");
    assert(parseJSON(resp)["status"].str == "ok", "undo failed: " ~ resp);
}

long[] faceParts() {
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto a = m["facePart"].array;
    long[] r;
    foreach (n; a) r ~= n.integer;
    return r;
}

// ── tests ────────────────────────────────────────────────────────────────────

unittest { // assign partId 7 to selected faces; others stay 0
    resetCube();
    setSelection("polygons", [1, 3]);
    postCommand(`{"id":"mesh.setPart","params":{"partId":7}}`);

    auto fp = faceParts();
    assert(fp.length == 6,
        format("expected 6 facePart entries, got %d", fp.length));
    foreach (i, v; fp) {
        if (i == 1 || i == 3)
            assert(v == 7,
                format("face %d should be part 7, got %d", i, v));
        else
            assert(v == 0,
                format("face %d should be 0, got %d", i, v));
    }
}

unittest { // undo restores all facePart entries to 0
    resetCube();
    setSelection("polygons", [1, 3]);
    postCommand(`{"id":"mesh.setPart","params":{"partId":7}}`);
    postUndo();

    auto fp = faceParts();
    foreach (i, v; fp)
        assert(v == 0,
            format("after undo face %d should be 0, got %d", i, v));
}

unittest { // empty selection is a no-op: status != ok, facePart unchanged
    resetCube();
    // No setSelection — cube starts with empty face selection after reset.
    auto resp = postCommandRaw(
        `{"id":"mesh.setPart","params":{"partId":7}}`);
    auto j = parseJSON(resp);
    assert(j["status"].str != "ok",
        "expected error/noop status on empty selection, got: " ~ resp);

    auto fp = faceParts();
    foreach (i, v; fp)
        assert(v == 0,
            format("face %d should be unchanged (0) after no-op, got %d", i, v));
}

unittest { // wrong edit mode (Vertices) is rejected with status error
    post("http://localhost:8080/api/reset", "");
    post("http://localhost:8080/api/command", "select.typeFrom vertex");

    auto resp = postCommandRaw(
        `{"id":"mesh.setPart","params":{"partId":5}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error when not in Polygons mode, got: " ~ resp);

    // Switch to polygon mode and verify facePart is still all zeros.
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    auto fp = faceParts();
    foreach (i, v; fp)
        assert(v == 0,
            format("face %d should be 0 after rejected wrong-mode cmd, got %d", i, v));
}

unittest { // delta-undo restores non-zero facePart (exercises removeFacesReverse prt branch)
    // Assign partId=5 to face 0, then delete face 0 via mesh.delete (delta-tracked
    // by default). On undo the MeshEditDelta inverts removeFacesReverse and must
    // re-insert the face with its recorded facePart (5), not the else-branch 0u.
    resetCube();
    setSelection("polygons", [0]);
    postCommand(`{"id":"mesh.setPart","params":{"partId":5}}`);
    assert(faceParts()[0] == 5, "setup: face 0 should be part 5 after setPart");

    // Delete face 0 (still selected). mesh.delete dispatches through the
    // delta tracker (undoTrackerEnabled default ON) → recordRemoveFaces captures
    // droppedFacePart = [5].
    postCommand(`{"id":"mesh.delete"}`);
    assert(faceParts().length == 5,
        format("after delete expected 5 faces, got %d", faceParts().length));

    // Undo the delete. removeFacesReverse must restore face 0 with prt[0]=5.
    postUndo();
    auto fp = faceParts();
    assert(fp.length == 6,
        format("after delta-undo expected 6 faces, got %d", fp.length));
    assert(fp[0] == 5,
        format("after delta-undo face 0 should be part 5, got %d; " ~
               "removeFacesReverse is not restoring the recorded facePart", fp[0]));
}

unittest { // .v3d round-trip: facePart survives save + load
    resetCube();
    setSelection("polygons", [0, 5]);
    postCommand(`{"id":"mesh.setPart","params":{"partId":42}}`);

    string path = buildPath(tempDir(), "test_set_part_roundtrip.v3d");
    scope(exit) if (exists(path)) remove(path);

    postCommand(`{"id":"file.save","params":{"path":"` ~ path ~ `"}}`);
    post("http://localhost:8080/api/reset", "");
    postCommand(`{"id":"file.load","params":{"path":"` ~ path ~ `"}}`);
    post("http://localhost:8080/api/command", "select.typeFrom polygon");

    auto fp = faceParts();
    assert(fp.length == 6,
        format("after reload expected 6 facePart entries, got %d", fp.length));
    foreach (i, v; fp) {
        if (i == 0 || i == 5)
            assert(v == 42,
                format("after reload face %d should be part 42, got %d", i, v));
        else
            assert(v == 0,
                format("after reload face %d should be 0, got %d", i, v));
    }
}
