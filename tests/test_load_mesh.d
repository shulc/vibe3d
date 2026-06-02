// Tests for the test-only raw-mesh injection endpoint POST /api/load-mesh.
//
// The endpoint replaces the live mesh with caller-supplied vertices + faces
// (faces are vertex-index lists, any degree >= 3), rebuilds all derived data
// (deduplicated edges, half-edge loops, selection/mark/material arrays),
// clears the selection, and refreshes the GPU + screen-space caches — the
// same consistent post-load state /api/reset leaves behind, just with a
// caller-supplied mesh instead of a primitive.
//
// "localhost:8080" is rewritten to the per-worker port by run_test.d when
// running in parallel; keep the literal so that rewrite still matches.

import std.net.curl;
import std.json;
import std.conv : to;

void main() {}

string postLoadMesh(string body) {
    return cast(string)post("http://localhost:8080/api/load-mesh", body);
}

void resetCube() {
    auto resp = post("http://localhost:8080/api/reset", "");
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/reset failed: " ~ resp);
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

string postCommandRaw(string body) {
    return cast(string)post("http://localhost:8080/api/command", body);
}

JSONValue getModel() { return parseJSON(get("http://localhost:8080/api/model")); }

// A unit tetrahedron: 4 verts, 4 triangular faces, 6 edges.
enum string kTetra =
    `{"vertices":[[0,0,0],[1,0,0],[0,1,0],[0,0,1]],` ~
    `"faces":[[0,2,1],[0,1,3],[0,3,2],[1,2,3]]}`;

// ---------------------------------------------------------------------------
// Happy path
// ---------------------------------------------------------------------------

unittest { // load a tetra → response reports the supplied counts
    resetCube();
    auto resp = parseJSON(postLoadMesh(kTetra));
    assert(resp["status"].str == "ok",
        "load-mesh failed: " ~ resp.toString);
    assert(resp["vertexCount"].integer == 4,
        "expected vertexCount 4, got " ~ resp["vertexCount"].integer.to!string);
    assert(resp["faceCount"].integer == 4,
        "expected faceCount 4, got " ~ resp["faceCount"].integer.to!string);
}

unittest { // /api/model round-trips the loaded geometry with rebuilt edges
    resetCube();
    postLoadMesh(kTetra);
    auto m = getModel();
    assert(m["vertexCount"].integer == 4,
        "expected 4 verts, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 4,
        "expected 4 faces, got " ~ m["faceCount"].integer.to!string);
    // A closed tetra has 6 unique (deduplicated) edges — proves rebuildEdges
    // ran on the injected faces.
    assert(m["edgeCount"].integer == 6,
        "expected 6 edges, got " ~ m["edgeCount"].integer.to!string);
}

unittest { // a follow-up op runs on the loaded mesh (proves loops/edges rebuilt)
    resetCube();
    postLoadMesh(kTetra);
    postSelect("edges", [0]);
    auto resp = parseJSON(postCommandRaw(`{"id":"mesh.edge_extrude"}`));
    assert(resp["status"].str == "ok",
        "mesh.edge_extrude on loaded mesh failed: " ~ resp.toString);
    auto m = getModel();
    // Extrude adds geometry — the exact tally isn't the point, only that the
    // op succeeded and the mesh grew (half-edge structure was valid).
    assert(m["vertexCount"].integer > 4,
        "expected the extrude to add verts, got " ~
        m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer > 4,
        "expected the extrude to add faces, got " ~
        m["faceCount"].integer.to!string);
}

unittest { // load replaces (not merges with) the previous mesh
    resetCube();                                  // 8 verts / 6 faces
    postLoadMesh(kTetra);                         // → 4 verts / 4 faces
    auto m = getModel();
    assert(m["vertexCount"].integer == 4,
        "load should REPLACE the cube, got " ~
        m["vertexCount"].integer.to!string ~ " verts");
}

unittest { // a quad face (degree 4) is accepted
    resetCube();
    auto resp = parseJSON(postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],"faces":[[0,1,2,3]]}`));
    assert(resp["status"].str == "ok",
        "single-quad load failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertexCount"].integer == 4 && m["faceCount"].integer == 1,
        "expected 4 verts / 1 face, got " ~ m.toString);
    assert(m["edgeCount"].integer == 4,
        "expected 4 edges for a single quad, got " ~
        m["edgeCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Error paths — bad input returns an error and leaves the mesh untouched
// ---------------------------------------------------------------------------

unittest { // face index out of range → error, mesh unchanged
    resetCube();
    auto before = getModel()["vertexCount"].integer;
    auto resp = parseJSON(postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,5]]}`));
    assert(resp["status"].str == "error",
        "expected error for out-of-range index, got " ~ resp.toString);
    assert(getModel()["vertexCount"].integer == before,
        "mesh must be untouched after a bad load");
}

unittest { // degenerate face (< 3 verts) → error
    resetCube();
    auto resp = parseJSON(postLoadMesh(
        `{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1]]}`));
    assert(resp["status"].str == "error",
        "expected error for degenerate face, got " ~ resp.toString);
}

unittest { // missing 'vertices' field → error
    resetCube();
    auto resp = parseJSON(postLoadMesh(`{"faces":[[0,1,2]]}`));
    assert(resp["status"].str == "error",
        "expected error for missing vertices, got " ~ resp.toString);
}

unittest { // non-array vertices → error
    resetCube();
    auto resp = parseJSON(postLoadMesh(`{"vertices":42,"faces":[]}`));
    assert(resp["status"].str == "error",
        "expected error for non-array vertices, got " ~ resp.toString);
}
