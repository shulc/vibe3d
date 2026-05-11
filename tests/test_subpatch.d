// Tests for the subpatch flag (LightWave-style PTCH faces).
// Drives `mesh.subpatch_toggle` via /api/command — the same logic the Tab key
// handler in app.d uses, mirroring the editor UX:
//   • If any faces are selected, toggle isSubpatch on those faces.
//   • If no face is selected, invert isSubpatch on every face.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
    // mesh.subpatch_toggle requires Polygons edit mode (face-level op).
    post("http://localhost:8080/api/command", "select.typeFrom polygon");
}

void runCmd(string id) {
    auto resp = post("http://localhost:8080/api/command",
        `{"id":"` ~ id ~ `"}`);
    assert(parseJSON(resp)["status"].str == "ok",
        id ~ " failed: " ~ resp);
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

bool[] subpatchFlags() {
    auto m = parseJSON(get("http://localhost:8080/api/model"));
    auto a = m["isSubpatch"].array;
    bool[] r;
    foreach (n; a) r ~= n.type == JSONType.true_;
    return r;
}

unittest { // fresh cube has no subpatch faces
    resetCube();
    auto sub = subpatchFlags();
    assert(sub.length == 6, "expected 6 entries, got " ~ sub.length.to!string);
    foreach (i, b; sub)
        assert(!b, "face " ~ i.to!string ~ " should be cage on reset");
}

unittest { // toggle with no selection → all 6 faces flip on, second toggle → off
    resetCube();
    runCmd("mesh.subpatch_toggle");
    auto sub = subpatchFlags();
    foreach (i, b; sub)
        assert(b, "face " ~ i.to!string ~ " should be subpatch after global toggle");

    runCmd("mesh.subpatch_toggle");
    sub = subpatchFlags();
    foreach (i, b; sub)
        assert(!b, "face " ~ i.to!string ~ " should be cage after second toggle");
}

unittest { // toggle with selection only flips selected faces
    resetCube();
    setSelection("polygons", [0, 2, 4]);  // back, left, top
    runCmd("mesh.subpatch_toggle");
    auto sub = subpatchFlags();
    assert(sub[0],  "face 0 (selected) should flip on");
    assert(!sub[1], "face 1 (unselected) should stay off");
    assert(sub[2],  "face 2 (selected) should flip on");
    assert(!sub[3], "face 3 (unselected) should stay off");
    assert(sub[4],  "face 4 (selected) should flip on");
    assert(!sub[5], "face 5 (unselected) should stay off");
}

unittest { // toggle is per-face: a second toggle on a different selection
           // doesn't disturb earlier ones
    resetCube();
    setSelection("polygons", [0]);
    runCmd("mesh.subpatch_toggle");      // → face 0 on
    setSelection("polygons", [3]);
    runCmd("mesh.subpatch_toggle");      // → face 3 on; face 0 unchanged
    auto sub = subpatchFlags();
    assert(sub[0],  "face 0 should still be subpatch");
    assert(sub[3],  "face 3 should now be subpatch");
    assert(!sub[1], "face 1 untouched");
    assert(!sub[2], "face 2 untouched");
    assert(!sub[4], "face 4 untouched");
    assert(!sub[5], "face 5 untouched");
}
