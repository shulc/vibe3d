// Tests for mesh.setMaterial — assigns a per-face material index to selected
// faces via /api/command. Verifies assignment, undo, empty-selection no-op,
// and wrong-mode rejection.

import std.net.curl;
import std.json;
import std.conv : to;
import std.format : format;

void main() {}

// ── helpers ──────────────────────────────────────────────────────────────────

void resetCube() {
    post("http://localhost:8080/api/reset", "");
    // mesh.setMaterial is a Polygons-mode command.
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

long[] faceMaterials() {
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto a = m["faceMaterial"].array;
    long[] r;
    foreach (n; a) r ~= n.integer;
    return r;
}

// ── tests ────────────────────────────────────────────────────────────────────

unittest { // assign materialId 3 to selected faces; others stay 0
    resetCube();
    setSelection("polygons", [2, 4]);
    postCommand(`{"id":"mesh.setMaterial","params":{"materialId":3}}`);

    auto fm = faceMaterials();
    assert(fm.length == 6,
        format("expected 6 faceMaterial entries, got %d", fm.length));
    foreach (i, v; fm) {
        if (i == 2 || i == 4)
            assert(v == 3,
                format("face %d should be material 3, got %d", i, v));
        else
            assert(v == 0,
                format("face %d should be 0, got %d", i, v));
    }
}

unittest { // undo restores all faceMaterial entries to 0
    resetCube();
    setSelection("polygons", [2, 4]);
    postCommand(`{"id":"mesh.setMaterial","params":{"materialId":3}}`);
    postUndo();

    auto fm = faceMaterials();
    foreach (i, v; fm)
        assert(v == 0,
            format("after undo face %d should be 0, got %d", i, v));
}

unittest { // empty selection is a no-op: status != ok, faceMaterial unchanged
    resetCube();
    // No setSelection — cube starts with empty face selection after reset.
    auto resp = postCommandRaw(
        `{"id":"mesh.setMaterial","params":{"materialId":3}}`);
    auto j = parseJSON(resp);
    assert(j["status"].str != "ok",
        "expected error/noop status on empty selection, got: " ~ resp);

    auto fm = faceMaterials();
    foreach (i, v; fm)
        assert(v == 0,
            format("face %d should be unchanged (0) after no-op, got %d", i, v));
}

unittest { // wrong edit mode (Vertices) is rejected with status error
    post("http://localhost:8080/api/reset", "");
    post("http://localhost:8080/api/command", "select.typeFrom vertex");

    auto resp = postCommandRaw(
        `{"id":"mesh.setMaterial","params":{"materialId":5}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error when not in Polygons mode, got: " ~ resp);

    // Switch to polygon mode and verify faceMaterial is still all zeros.
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
    auto fm = faceMaterials();
    foreach (i, v; fm)
        assert(v == 0,
            format("face %d should be 0 after rejected wrong-mode cmd, got %d", i, v));
}
