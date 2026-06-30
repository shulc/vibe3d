// Tests for mesh.splitFace (Split Face command).
//
// Fixture: a single quad face loaded via /api/load-mesh.
// All reject cases use postCommandRaw (not postCommand) — the no-op evaluate
// returns false, which propagates as status:ERROR from /api/command.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

// ---------------------------------------------------------------------------
// HTTP helpers (mirrors test_make_polygon.d)
// ---------------------------------------------------------------------------

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok", "/api/reset failed: " ~ resp);
}

void postLoadMesh(string body) {
    auto resp = post("http://localhost:8080/api/load-mesh", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/load-mesh failed: " ~ resp);
}

void postSelect(string mode, int[] indices) {
    string idxJson = "[";
    foreach (i, v; indices) { if (i > 0) idxJson ~= ","; idxJson ~= v.to!string; }
    idxJson ~= "]";
    auto resp = post("http://localhost:8080/api/select",
        `{"mode":"` ~ mode ~ `","indices":` ~ idxJson ~ `}`);
    assert(parseJSON(resp)["status"].str == "ok", "/api/select failed: " ~ resp);
}

void postCommand(string body) {
    auto resp = post("http://localhost:8080/api/command", body);
    assert(parseJSON(resp)["status"].str == "ok", "/api/command failed: " ~ resp);
}

string postCommandRaw(string body) {
    return cast(string)post("http://localhost:8080/api/command", body);
}

JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }
JSONValue postUndo()  { return parseJSON(post("http://localhost:8080/api/undo", "")); }

// Standard fixture: quad [0,1,2,3] on the XY plane.
void loadQuad() {
    postLoadMesh(`{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],"faces":[[0,1,2,3]]}`);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest { // params mode: split quad {a:0,b:2} → two tris [0,1,2] + [2,3,0], edgeCount 4→5
    loadQuad();
    postCommand(`{"id":"mesh.splitFace","params":{"a":0,"b":2}}`);
    auto m = getModel();

    assert(m["faceCount"].integer  == 2, "expected 2 faces after split, got " ~ m["faceCount"].integer.to!string);
    assert(m["vertexCount"].integer == 4, "vertex count must stay 4");
    assert(m["edgeCount"].integer   == 5, "expected 5 edges (4 boundary + 1 chord), got " ~ m["edgeCount"].integer.to!string);

    // Both triangles must appear in the face list.
    auto faces = m["faces"].array;
    bool hasF1 = false, hasF2 = false;
    foreach (f; faces) {
        auto c = f.array;
        if (c.length == 3 && c[0].integer == 0 && c[1].integer == 1 && c[2].integer == 2) hasF1 = true;
        if (c.length == 3 && c[0].integer == 2 && c[1].integer == 3 && c[2].integer == 0) hasF2 = true;
    }
    assert(hasF1, "expected face [0,1,2]");
    assert(hasF2, "expected face [2,3,0]");
}

unittest { // selection mode: select verts [1,3] → two tris [1,2,3] + [3,0,1], edgeCount 5
    loadQuad();
    postSelect("vertices", [1, 3]);
    postCommand(`{"id":"mesh.splitFace"}`);
    auto m = getModel();

    assert(m["faceCount"].integer   == 2, "expected 2 faces");
    assert(m["vertexCount"].integer  == 4, "vertex count must stay 4");
    assert(m["edgeCount"].integer    == 5, "expected 5 edges");

    auto faces = m["faces"].array;
    bool hasF1 = false, hasF2 = false;
    foreach (f; faces) {
        auto c = f.array;
        if (c.length == 3 && c[0].integer == 1 && c[1].integer == 2 && c[2].integer == 3) hasF1 = true;
        if (c.length == 3 && c[0].integer == 3 && c[1].integer == 0 && c[2].integer == 1) hasF2 = true;
    }
    assert(hasF1, "expected face [1,2,3]");
    assert(hasF2, "expected face [3,0,1]");
}

unittest { // undo restores original single quad
    loadQuad();
    postCommand(`{"id":"mesh.splitFace","params":{"a":0,"b":2}}`);
    assert(getModel()["faceCount"].integer == 2, "sanity: 2 faces after split");

    postUndo();
    auto m = getModel();
    assert(m["faceCount"].integer  == 1, "undo: expected 1 face");
    assert(m["edgeCount"].integer  == 4, "undo: expected 4 edges");
    assert(m["vertexCount"].integer == 4, "undo: vertex count unchanged");

    auto corners = m["faces"].array[0].array;
    assert(corners.length == 4, "undo: restored face must be a quad");
    assert(corners[0].integer == 0 && corners[1].integer == 1 &&
           corners[2].integer == 2 && corners[3].integer == 3,
        "undo: restored winding must be [0,1,2,3]");
}

unittest { // reject adjacent verts → non-ok status, mesh unchanged
    loadQuad();
    auto before = getModel();
    long fc0 = before["faceCount"].integer;

    auto raw = postCommandRaw(`{"id":"mesh.splitFace","params":{"a":0,"b":1}}`);
    assert(parseJSON(raw)["status"].str != "ok",
        "adjacent verts must yield non-ok status");
    assert(getModel()["faceCount"].integer == fc0,
        "adjacent verts: faceCount must not change");
}

unittest { // reject wrap-adjacent verts → non-ok status
    loadQuad();
    auto raw = postCommandRaw(`{"id":"mesh.splitFace","params":{"a":3,"b":0}}`);
    assert(parseJSON(raw)["status"].str != "ok",
        "wrap-adjacent verts must yield non-ok status");
    assert(getModel()["faceCount"].integer == 1,
        "wrap-adjacent: faceCount must not change");
}

unittest { // reject same vertex → non-ok status
    loadQuad();
    auto raw = postCommandRaw(`{"id":"mesh.splitFace","params":{"a":0,"b":0}}`);
    assert(parseJSON(raw)["status"].str != "ok",
        "same-vert must yield non-ok status");
    assert(getModel()["faceCount"].integer == 1,
        "same-vert: faceCount must not change");
}

unittest { // reject not-a-member: 2-face mesh, vert from the other face → non-ok
    // Build a two-face mesh: face0=[0,1,2,3], face1=[4,5,6,7].
    // Vert 4 belongs only to face1; requesting {a:0,b:4} via face:0 → not a member.
    postLoadMesh(`{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],
                               [2,0,0],[3,0,0],[3,1,0],[2,1,0]],
                  "faces":[[0,1,2,3],[4,5,6,7]]}`);
    auto raw = postCommandRaw(`{"id":"mesh.splitFace","params":{"face":0,"a":0,"b":4}}`);
    assert(parseJSON(raw)["status"].str != "ok",
        "not-a-member vert must yield non-ok status");
    assert(getModel()["faceCount"].integer == 2,
        "not-a-member: faceCount must not change");
}

unittest { // explicit face param picks the right face in a 2-face mesh
    // face0=[0,1,2,3], face1=[0,2,4,5] — vert 0 and 2 are shared, but we
    // explicitly target face:0 only.
    postLoadMesh(`{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],[2,0,0],[2,1,0]],
                  "faces":[[0,1,2,3],[0,2,4,5]]}`);
    postCommand(`{"id":"mesh.splitFace","params":{"face":0,"a":0,"b":2}}`);
    auto m = getModel();
    // face0 is split into 2, face1 unchanged → total 3 faces
    assert(m["faceCount"].integer == 3,
        "explicit face:0 split must yield 3 total faces, got " ~ m["faceCount"].integer.to!string);
}
