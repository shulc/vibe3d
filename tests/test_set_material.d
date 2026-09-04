// Tests for mesh.setMaterial — assigns a per-face material index to the
// OPERAND faces via /api/command. Verifies assignment, undo, the
// empty-selection = WHOLE MESH law, and wrong-mode rejection.
//
// The empty-selection block below used to assert the opposite. It pinned "no
// selection ⇒ no-op" as correct, and it was wrong: the reference paints every
// face, and a second, unrelated command (copy+paste, which duplicates the
// whole mesh from the same empty selection) says the same thing. Ledger rows
// 13 + 18, frozen in tests/fixtures/empty_selection_whole_mesh.json, ported in
// task 1210. Left as a comment because a test that changed its mind is worth
// more with the reason attached than without.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.json : JSONType;
import std.conv : to;
import std.format : format;

void main() {}

// ── helpers ──────────────────────────────────────────────────────────────────

void resetCube() {
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
    // mesh.setMaterial is a Polygons-mode command.
    post(testBaseUrl() ~ "/api/command", "select.typeFrom polygon");
}

string postCommandRaw(string body) {
    return cast(string) post(testBaseUrl() ~ "/api/command", body);
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
    auto resp = post(testBaseUrl() ~ "/api/command", commandBody("mesh.select", `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`));
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

string[] undoLabels() {
    auto h = parseJSON(get(testBaseUrl() ~ "/api/history"));
    string[] r;
    foreach (e; h["undo"].array)
        r ~= (e.type == JSONType.object && "label" in e) ? e["label"].str
                                                         : e.toString;
    return r;
}

void postUndo() {
    auto resp = post(testBaseUrl() ~ "/api/command", commandBody("history.undo"));
    assert(parseJSON(resp)["status"].str == "ok", "undo failed: " ~ resp);
}

long[] faceMaterials() {
    auto m = parseJSON(get(testBaseUrl() ~ "/api/model"));
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

unittest { // empty selection means THE WHOLE MESH: every face is painted
    resetCube();
    // No setSelection — the cube starts with an empty face selection after
    // reset, and that is exactly the operand this asserts.
    auto resp = postCommandRaw(
        `{"id":"mesh.setMaterial","params":{"materialId":3}}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
        "empty selection must paint the whole mesh, not no-op: " ~ resp);

    auto fm = faceMaterials();
    assert(fm.length == 6,
        format("expected 6 faceMaterial entries, got %d", fm.length));
    foreach (i, v; fm)
        assert(v == 3,
            format("face %d should be material 3 (empty selection = whole "
                   ~ "mesh), got %d", i, v));
}

unittest { // ... and it is ONE undo entry, not six
    // Depth is the wrong instrument here: the undo stack saturates, so
    // "before + 1" reads as unchanged on a full stack. The stack's LABELS say
    // it directly — exactly one "Set Material" on top, and something else
    // underneath it.
    resetCube();
    postCommand(`{"id":"mesh.setMaterial","params":{"materialId":7}}`);
    auto labels = undoLabels();
    assert(labels.length >= 2, "expected a non-trivial undo stack");
    assert(labels[$ - 1] == "Set Material",
        "the whole-mesh paint must be on top of the undo stack, got: "
        ~ labels[$ - 1]);
    assert(labels[$ - 2] != "Set Material",
        "…and it must be ONE entry, not one per face — the entry below it is "
        ~ "also a Set Material: " ~ labels[$ - 2]);

    postUndo();
    auto fm = faceMaterials();
    foreach (i, v; fm)
        assert(v == 0,
            format("one undo must restore every face; face %d is %d", i, v));
}

unittest { // a NON-empty selection is still exactly that selection
    resetCube();
    setSelection("polygons", [1]);
    postCommand(`{"id":"mesh.setMaterial","params":{"materialId":4}}`);
    auto fm = faceMaterials();
    foreach (i, v; fm)
        assert(v == (i == 1 ? 4 : 0),
            format("face %d should be %d, got %d", i, i == 1 ? 4 : 0, v));
}

unittest { // wrong edit mode (Vertices) is rejected with status error
    post(testBaseUrl() ~ "/api/command", commandBody("scene.reset"));
    post(testBaseUrl() ~ "/api/command", "select.typeFrom vertex");

    auto resp = postCommandRaw(
        `{"id":"mesh.setMaterial","params":{"materialId":5}}`);
    assert(parseJSON(resp)["status"].str == "error",
        "expected error when not in Polygons mode, got: " ~ resp);

    // Switch to polygon mode and verify faceMaterial is still all zeros.
    post(testBaseUrl() ~ "/api/command", "select.typeFrom polygon");
    auto fm = faceMaterials();
    foreach (i, v; fm)
        assert(v == 0,
            format("face %d should be 0 after rejected wrong-mode cmd, got %d", i, v));
}
