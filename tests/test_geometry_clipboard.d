// Tests for mesh.copy / mesh.paste / mesh.cut (geometry clipboard bundle).
// The clipboard fills on copy (Polygons or Vertices mode) and on cut (Polygons
// only) and is consumed (non-destructively) by paste (mode-agnostic).
//
// TASK 1200 (ledger row 19): copy in VERTICES mode used to refuse; the
// reference takes the points and its paste puts them back as free vertices.
// EDGES mode still refuses — nobody measured it there. Paste lands at the same
// position as the copied faces (v1 = overlapping, no offset).
//
// Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)
// Faces (addFace insertion order):
//   f0=back  [0,3,2,1]   f1=front [4,5,6,7]
//   f2=left  [0,4,7,3]   f3=right [1,2,6,5]
//   f4=top   [3,7,6,2]   f5=bottom [0,1,5,4]

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs;

void main() {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

JSONValue postCommandRaw(string body) {
    return parseJSON(post("http://localhost:8080/api/command", body));
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/select failed: " ~ resp);
}

JSONValue getModel()     { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue getSelection() { return parseJSON(get("http://localhost:8080/api/selection")); }
JSONValue postUndo()     { return parseJSON(post("http://localhost:8080/api/undo", "")); }
JSONValue getHistory()   { return parseJSON(get("http://localhost:8080/api/history")); }

long undoCount() { return getHistory()["undo"].array.length; }

bool approxEq(double a, double b, double eps = 1e-5) {
    return abs(a - b) < eps;
}

double[3] vToArr(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// ---------------------------------------------------------------------------
// Success cases — copy then paste
// ---------------------------------------------------------------------------

unittest { // copy 1 face then paste: 4 new verts, 1 new face, 4 new edges
    resetCube();
    postSelect("polygons", [0]);   // back face: verts 0,3,2,1

    postCommand(`{"id":"mesh.copy"}`);
    postCommand(`{"id":"mesh.paste"}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "faces: expected 7, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 16,
        "edges: expected 16, got " ~ m["edgeCount"].integer.to!string);
}

unittest { // pasted face (index 6) is the only selection; verts+edges clear
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.copy"}`);
    postCommand(`{"id":"mesh.paste"}`);

    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 1, "expected 1 selected face after paste");
    assert(selFaces[0].integer == 6,
        "expected new face index 6, got " ~ selFaces[0].integer.to!string);
    assert(sel["selectedVertices"].array.length == 0,
        "vertex selection should be empty after paste");
    assert(sel["selectedEdges"].array.length == 0,
        "edge selection should be empty after paste");
}

unittest { // pasted verts coincide with the copied face's original positions
    resetCube();
    postSelect("polygons", [0]);  // back face: verts 0,3,2,1
    postCommand(`{"id":"mesh.copy"}`);
    postCommand(`{"id":"mesh.paste"}`);

    auto m = getModel();
    auto verts = m["vertices"].array;
    // The back-face original positions (verts 0,3,2,1).
    double[3][] backPositions = [
        vToArr(verts[0]), vToArr(verts[3]),
        vToArr(verts[2]), vToArr(verts[1]),
    ];
    // Pasted verts start at index 8 (4 originals per selected face).
    double[3][] pastedPositions = [
        vToArr(verts[8]),  vToArr(verts[9]),
        vToArr(verts[10]), vToArr(verts[11]),
    ];
    // Each pasted vert must coincide with some back-face original.
    foreach (pv; pastedPositions) {
        bool found = false;
        foreach (bv; backPositions) {
            if (approxEq(pv[0], bv[0]) && approxEq(pv[1], bv[1])
                                        && approxEq(pv[2], bv[2])) {
                found = true; break;
            }
        }
        assert(found, "pasted vert position does not coincide with any back-face vert");
    }
}

unittest { // clipboard is reusable: paste twice yields independent copies
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.copy"}`);
    postCommand(`{"id":"mesh.paste"}`);
    postCommand(`{"id":"mesh.paste"}`);  // second paste from same clipboard

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "2× paste verts: expected 16, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 8,
        "2× paste faces: expected 8, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 20,
        "2× paste edges: expected 20, got " ~ m["edgeCount"].integer.to!string);
}

unittest { // copy 2 adjacent faces: shared verts deduped in clip
    resetCube();
    // f0=back [0,3,2,1] and f4=top [3,7,6,2] share verts {2,3}.
    // 4+4-2 = 6 unique verts → 6 new verts, 2 new faces, 7 new edges.
    postSelect("polygons", [0, 4]);
    postCommand(`{"id":"mesh.copy"}`);
    postCommand(`{"id":"mesh.paste"}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 14,
        "2-face paste verts: expected 14, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 8,
        "2-face paste faces: expected 8, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 19,
        "2-face paste edges: expected 19, got " ~ m["edgeCount"].integer.to!string);

    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 2, "expected 2 selected faces after paste");
    assert(selFaces[0].integer == 6 && selFaces[1].integer == 7,
        "expected new faces [6,7], got " ~ sel["selectedFaces"].toString);
}

// ---------------------------------------------------------------------------
// Success cases — undo
// ---------------------------------------------------------------------------

unittest { // undo paste restores original cage
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.copy"}`);
    postCommand(`{"id":"mesh.paste"}`);

    assert(getModel()["faceCount"].integer == 7);

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "undo paste verts: expected 8, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "undo paste faces: expected 6, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "undo paste edges: expected 12, got " ~ m["edgeCount"].integer.to!string);
}

unittest { // copy adds no undo entry (CmdFlags.None)
    resetCube();
    postSelect("polygons", [0]);

    long before = undoCount();
    postCommand(`{"id":"mesh.copy"}`);
    long after  = undoCount();

    assert(before == after,
        "copy should add no undo entry; count went "
        ~ before.to!string ~ " → " ~ after.to!string);
}

// ---------------------------------------------------------------------------
// Success cases — cut
// ---------------------------------------------------------------------------

unittest { // cut removes selected face; mesh shrinks
    resetCube();
    postSelect("polygons", [0]);

    postCommand(`{"id":"mesh.cut"}`);

    auto m = getModel();
    // All 8 cube verts remain referenced by the surviving 5 faces.
    assert(m["vertexCount"].integer == 8,
        "cut verts: expected 8, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 5,
        "cut faces: expected 5, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "cut edges: expected 12, got " ~ m["edgeCount"].integer.to!string);
}

unittest { // paste after cut restores face count; pasted face is selected
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.cut"}`);

    postCommand(`{"id":"mesh.paste"}`);

    auto m = getModel();
    // 8 original verts + 4 pasted clones = 12; 5 remaining + 1 pasted = 6;
    // 12 surviving edges + 4 new from isolated pasted face = 16.
    assert(m["vertexCount"].integer == 12,
        "cut+paste verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "cut+paste faces: expected 6, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 16,
        "cut+paste edges: expected 16, got " ~ m["edgeCount"].integer.to!string);

    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 1, "expected 1 selected face after cut+paste");
    assert(selFaces[0].integer == 5,
        "expected pasted face index 5, got " ~ selFaces[0].integer.to!string);
}

unittest { // pasted face after cut coincides with the original back face
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.cut"}`);
    postCommand(`{"id":"mesh.paste"}`);

    auto m = getModel();
    auto verts = m["vertices"].array;
    // Original verts 0..7 are unchanged after cut (no compact — all referenced).
    // Pasted verts start at index 8.
    double[3][] backPositions = [
        vToArr(verts[0]), vToArr(verts[3]),
        vToArr(verts[2]), vToArr(verts[1]),
    ];
    double[3][] pastedPositions = [
        vToArr(verts[8]),  vToArr(verts[9]),
        vToArr(verts[10]), vToArr(verts[11]),
    ];
    foreach (pv; pastedPositions) {
        bool found = false;
        foreach (bv; backPositions) {
            if (approxEq(pv[0], bv[0]) && approxEq(pv[1], bv[1])
                                        && approxEq(pv[2], bv[2])) {
                found = true; break;
            }
        }
        assert(found, "cut+paste vert does not coincide with original back-face vert");
    }
}

unittest { // undo cut restores original cage
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.cut"}`);

    assert(getModel()["faceCount"].integer == 5);

    auto u = postUndo();
    assert(u["status"].str == "ok", "undo cut failed: " ~ u.toString);

    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "undo cut verts: expected 8, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "undo cut faces: expected 6, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "undo cut edges: expected 12, got " ~ m["edgeCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Reject / no-op cases — all use postCommandRaw + tolerate non-ok per plan
// ---------------------------------------------------------------------------

unittest { // empty-selection copy: after reset we're in Vertices mode → rejected
    resetCube();
    // No face selected (and not in Polygons mode after reset).
    auto resp = postCommandRaw(`{"id":"mesh.copy"}`);
    // status may be non-ok (rejection) or ok but mesh must be unchanged.
    auto m = getModel();
    assert(resp["status"].str != "ok"
           || (m["vertexCount"].integer == 8 && m["faceCount"].integer == 6),
        "empty-selection copy should not change the mesh");
    // Clipboard must be empty → paste rejected too.
    auto p = postCommandRaw(`{"id":"mesh.paste"}`);
    assert(p["status"].str != "ok"
           || getModel()["faceCount"].integer == 6,
        "paste after empty copy should be a no-op");
}

unittest { // empty-selection cut: no selected faces → rejected, mesh unchanged
    resetCube();
    auto resp = postCommandRaw(`{"id":"mesh.cut"}`);
    auto m = getModel();
    assert(resp["status"].str != "ok"
           || (m["vertexCount"].integer == 8 && m["faceCount"].integer == 6),
        "empty-selection cut should not change the mesh");
    assert(m["vertexCount"].integer == 8,
        "cut with no selection must not remove verts; got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "cut with no selection must not remove faces; got "
        ~ m["faceCount"].integer.to!string);
}

unittest { // VERTICES-mode copy: task 1200 (ledger row 19) — it takes the
           // points, and the paste puts that many free vertices back.
    resetCube();
    postSelect("vertices", [0, 1, 2, 3]);  // switches to Vertices mode

    postCommand(`{"id":"mesh.copy"}`);
    auto m0 = getModel();
    assert(m0["vertexCount"].integer == 8 && m0["faceCount"].integer == 6,
        "copy is read-only — it must not touch the mesh");

    postCommand(`{"id":"mesh.paste"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "paste must add the four copied points, expected 12 got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "and no face: a loose vertex borders nothing; got "
        ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "and no edge either; got " ~ m["edgeCount"].integer.to!string);

    // The pasted points land on their originals, so position alone cannot see
    // the paste — the count is what sees it — but WHICH four are selected can
    // still be checked: exactly four, and they are the new tail indices.
    auto sel = getSelection()["selectedVertices"].array;
    assert(sel.length == 4,
        "exactly the four pasted points stay selected, got "
        ~ sel.length.to!string);
    foreach (v; sel)
        assert(v.integer >= 8,
            "the selection must name the PASTED points (indices 8..11), not "
            ~ "the originals; got index " ~ v.integer.to!string);

    // Undo restores the cage.
    postUndo();
    assert(getModel()["vertexCount"].integer == 8,
        "undo must remove the pasted points");
}

unittest { // EDGES-mode copy still refuses — an absence of measurement, not a
           // decision: the reference was never driven with an edge selection.
    resetCube();
    postSelect("edges", [0, 1, 2, 3]);

    auto r = postCommandRaw(`{"id":"mesh.copy"}`);
    assert(r["status"].str != "ok",
        "edge-mode copy must still refuse");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 6,
        "and must not change the mesh");
    // Clipboard not filled → paste rejected.
    auto p = postCommandRaw(`{"id":"mesh.paste"}`);
    assert(p["status"].str != "ok"
           || getModel()["faceCount"].integer == 6,
        "paste after a refused edge-mode copy should be a no-op");
}

unittest { // non-Polygons cut: Edges mode with a selection → rejected
    resetCube();
    postSelect("edges", [0, 1, 2, 3]);  // switches to Edges mode

    postCommandRaw(`{"id":"mesh.cut"}`);  // tolerate non-ok
    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "non-Polygons cut must not change verts; got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "non-Polygons cut must not change faces; got "
        ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 12,
        "non-Polygons cut must not change edges; got "
        ~ m["edgeCount"].integer.to!string);
}

unittest { // empty-clipboard paste: after reset the clipboard is cleared
    resetCube();
    // SceneReset.apply calls geometryClipboard.clear(), so paste must reject.
    auto resp = postCommandRaw(`{"id":"mesh.paste"}`);
    auto m = getModel();
    assert(resp["status"].str != "ok"
           || m["faceCount"].integer == 6,
        "paste with empty clipboard should be a no-op");
    assert(m["vertexCount"].integer == 8,
        "paste with empty clipboard must not add verts");
    assert(m["faceCount"].integer == 6,
        "paste with empty clipboard must not add faces");
}

unittest { // reset-cleared clipboard: copy then reset then paste → rejected
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.copy"}`);  // fills clipboard

    resetCube();  // SceneReset.apply clears the clipboard

    auto resp = postCommandRaw(`{"id":"mesh.paste"}`);
    auto m = getModel();
    assert(resp["status"].str != "ok"
           || m["faceCount"].integer == 6,
        "paste after reset should be rejected (clipboard was cleared)");
    assert(m["faceCount"].integer == 6,
        "paste after reset must not add faces; got "
        ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Empty selection = THE WHOLE MESH (task 1210, ledger rows 13 + 18)
//
// The two "empty-selection" cases above reach their refusal through the MODE
// gate — /api/reset leaves us in Vertices mode — so neither of them says
// anything about what an empty POLYGON selection means. These do.
// ---------------------------------------------------------------------------

void toPolygonMode() {
    auto resp = post("http://localhost:8080/api/command", "select.typeFrom polygon");
    assert(parseJSON(resp)["status"].str == "ok",
        "select.typeFrom polygon failed: " ~ resp);
}

unittest { // copy with NOTHING selected takes everything; paste duplicates it
    resetCube();
    toPolygonMode();

    postCommand(`{"id":"mesh.copy"}`);
    postCommand(`{"id":"mesh.paste"}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "empty-selection copy+paste must duplicate all 8 verts; got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "empty-selection copy+paste must duplicate all 6 faces; got "
        ~ m["faceCount"].integer.to!string);

    // The pasted faces are what is left selected — the 6 new ones, not 12.
    auto s = getSelection();
    assert(s["selectedFaces"].array.length == 6,
        "paste must leave exactly the 6 pasted faces selected; got "
        ~ s["selectedFaces"].array.length.to!string);

    // ONE undo entry covers the whole-mesh paste.
    postUndo();
    auto m2 = getModel();
    assert(m2["vertexCount"].integer == 8 && m2["faceCount"].integer == 6,
        "a single undo must take the whole-mesh paste back off");
}

unittest { // mesh.cut is DELIBERATELY not on the law — it still refuses
    // Not an oversight and not a symmetry bug: the frozen capture drives cut
    // with every face SELECTED (and is left with an empty mesh), never with
    // none, so what the reference's cut does with an empty selection has not
    // been measured. Applying the law here would delete the user's whole mesh
    // on a stray keypress on the strength of a guess. Pinned so that a later
    // change to it is a deliberate one with a measurement behind it.
    resetCube();
    toPolygonMode();

    auto resp = postCommandRaw(`{"id":"mesh.cut"}`);
    auto m = getModel();
    assert(resp["status"].str != "ok",
        "empty-selection cut in Polygons mode must still refuse");
    assert(m["vertexCount"].integer == 8 && m["faceCount"].integer == 6,
        "empty-selection cut must not touch the mesh");
}
