// Tests for the subpatch flag (.lwo PTCH faces).
// Drives `mesh.subpatch_toggle` via /api/command — the same logic the Tab key
// handler in app.d uses, mirroring the editor UX (MODE-AWARE — parity 0464):
//   • Polygons mode + selection ⇒ toggle isSubpatch on the selected faces.
//   • Polygons mode + nothing   ⇒ invert isSubpatch on every face.
//   • edge/vertex/item mode     ⇒ face selection ignored ⇒ whole model.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
    // Put us in Polygons mode so the tests below exercise the
    // selection-scoped path (subpatch scope is mode-aware: a face selection
    // only counts while the current selection type is Polygons).
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

unittest { // MODE-AWARE scope (parity task 0464): a face selection made in
           // polygon mode is IGNORED once the current selection type is edge.
           // The command whole-models instead of scoping to the 2 selected
           // faces — and no longer throws in non-polygon mode. Matches the
           // reference editor (re-confirmed headless: select 2 → edge → 6).
    resetCube();                                 // leaves us in Polygons mode
    setSelection("polygons", [0, 1]);            // 2 of 6 faces selected
    post("http://localhost:8080/api/command", "select.typeFrom edge");
    runCmd("mesh.subpatch_toggle");              // was: throw / 2 scoped
    auto sub = subpatchFlags();
    foreach (i, b; sub)
        assert(b,
            "edge-mode toggle must whole-model (parity): face " ~ i.to!string ~
            " should be subpatch, not just the 2 polygon-selected");
}
