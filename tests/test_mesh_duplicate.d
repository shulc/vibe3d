// Tests for mesh.duplicate (Tier 1 of doc/duplicate_plan.md). The
// command clones the selected polygons in place: verts shared by
// multiple selected faces are cloned once; selection switches to the
// new copies. Polygons-mode-only — vert/edge selections produce no
// useful standalone topology in vibe3d's face-derived edge model.
//
// Cube layout (centered at origin, size 1):
//   v0=(-,-,-)  v1=(+,-,-)  v2=(+,+,-)  v3=(-,+,-)
//   v4=(-,-,+)  v5=(+,-,+)  v6=(+,+,+)  v7=(-,+,+)
// Faces (in addFace insertion order):
//   f0=back [0,3,2,1]   f1=front [4,5,6,7]
//   f2=left [0,4,7,3]   f3=right [1,2,6,5]
//   f4=top  [3,7,6,2]   f5=bottom [0,1,5,4]

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : abs;

void main() {}

// Helpers ------------------------------------------------------------------

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

bool approxEq(double a, double b, double eps = 1e-5) {
    return abs(a - b) < eps;
}

double[3] vToArr(JSONValue v) {
    auto a = v.array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// ---------------------------------------------------------------------------
// Polygons mode — primary path
// ---------------------------------------------------------------------------

unittest { // duplicate one face: 4 new verts, 1 new face, 4 new edges
    resetCube();
    postSelect("polygons", [0]);   // back face: verts 0,3,2,1

    postCommand(`{"id":"mesh.duplicate"}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "faces: expected 7, got "  ~ m["faceCount"].integer.to!string);
    assert(m["edgeCount"].integer == 16,
        "edges: expected 16, got " ~ m["edgeCount"].integer.to!string);

    // The cloned verts (indices 8..11) must coincide with the originals
    // 0,3,2,1 of the back face (positions, not order — order follows the
    // face's insertion of unique verts).
    auto verts = m["vertices"].array;
    double[3][] backVerts = [
        vToArr(verts[0]), vToArr(verts[3]),
        vToArr(verts[2]), vToArr(verts[1]),
    ];
    double[3][] clonedVerts = [
        vToArr(verts[8]),  vToArr(verts[9]),
        vToArr(verts[10]), vToArr(verts[11]),
    ];
    // Each cloned vert must match some back-face vert (same position).
    foreach (cv; clonedVerts) {
        bool found = false;
        foreach (bv; backVerts) {
            if (approxEq(cv[0], bv[0]) && approxEq(cv[1], bv[1])
                                       && approxEq(cv[2], bv[2])) {
                found = true; break;
            }
        }
        assert(found, "cloned vert position does not match any back-face vert");
    }
}

unittest { // selection after duplicate: only the new face (index 6) is selected
    resetCube();
    postSelect("polygons", [0]);
    postCommand(`{"id":"mesh.duplicate"}`);

    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 1, "expected 1 selected face after duplicate");
    assert(selFaces[0].integer == 6,
        "expected new face index 6, got " ~ selFaces[0].integer.to!string);
    // Vert / edge selections cleared.
    assert(sel["selectedVertices"].array.length == 0,
        "vertex selection should be empty after duplicate");
    assert(sel["selectedEdges"].array.length == 0,
        "edge selection should be empty after duplicate");
}

unittest { // duplicate two adjacent faces (share edge 2-3 → 2 shared verts):
           // 4+4-2 = 6 new verts, 2 new faces.
    resetCube();
    // f0=back [0,3,2,1] and f4=top [3,7,6,2] share verts {2,3}.
    postSelect("polygons", [0, 4]);
    postCommand(`{"id":"mesh.duplicate"}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 14,
        "verts: expected 14, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 8,
        "faces: expected 8, got "  ~ m["faceCount"].integer.to!string);

    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 2);
    assert(selFaces[0].integer == 6 && selFaces[1].integer == 7,
        "expected new faces [6,7], got " ~ sel["selectedFaces"].toString);

    // Verify the shared-edge optimization: the two cloned faces still
    // share an edge in the new topology. Edge count grows by exactly 7
    // (4 per face minus 1 shared edge = 7 new undirected edges).
    assert(m["edgeCount"].integer == 12 + 7,
        "edges: expected 19, got " ~ m["edgeCount"].integer.to!string);
}

unittest { // empty selection: command is a no-op (rejected by apply()).
    resetCube();
    // No selection set — every selectedFaces[i] is false after reset.
    auto resp = postCommandRaw(`{"id":"mesh.duplicate"}`);
    // apply() returns false ⇒ HTTP status reflects the rejection.
    assert(resp["status"].str != "ok"
           || (resp["status"].str == "ok" && getModel()["faceCount"].integer == 6),
        "duplicate with empty selection should leave the mesh unchanged");
    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    assert(m["edgeCount"].integer == 12);
}

unittest { // undo restores original cage exactly.
    resetCube();
    postSelect("polygons", [0, 4]);
    postCommand(`{"id":"mesh.duplicate"}`);

    auto pre = getModel();
    assert(pre["faceCount"].integer == 8);

    auto undoResp = postUndo();
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);

    auto post = getModel();
    assert(post["vertexCount"].integer == 8,
        "undo verts: expected 8, got " ~ post["vertexCount"].integer.to!string);
    assert(post["faceCount"].integer == 6,
        "undo faces: expected 6, got "  ~ post["faceCount"].integer.to!string);
    assert(post["edgeCount"].integer == 12,
        "undo edges: expected 12, got " ~ post["edgeCount"].integer.to!string);
}

unittest { // duplicated face preserves winding (= same normal direction).
           // We can't read normals directly, so we check that the new face's
           // vertex indices, in order, produce the same cross-product sign
           // as the original — i.e., the face[k] order is preserved.
    resetCube();
    postSelect("polygons", [0]);  // back face: [0,3,2,1]
    postCommand(`{"id":"mesh.duplicate"}`);

    auto m = getModel();
    auto faces = m["faces"].array;
    auto origFace = faces[0].array;
    auto newFace  = faces[6].array;
    assert(origFace.length == newFace.length,
        "new face has different vertex count");

    auto verts = m["vertices"].array;
    // Verify that the i-th vert of the new face is at the same position
    // as the i-th vert of the original face — i.e., the winding is
    // preserved one-for-one through the vertMap.
    foreach (i; 0 .. origFace.length) {
        auto vo = vToArr(verts[origFace[i].integer]);
        auto vn = vToArr(verts[newFace[i].integer]);
        assert(approxEq(vo[0], vn[0]) && approxEq(vo[1], vn[1])
                                      && approxEq(vo[2], vn[2]),
            "winding mismatch at index " ~ i.to!string);
    }
}

// ---------------------------------------------------------------------------
// Non-Polygons modes are rejected
// ---------------------------------------------------------------------------

unittest { // vertices-mode duplicate: command's supportedModes excludes
           // Vertices, so apply() returns false and the mesh is unchanged.
    resetCube();
    postSelect("vertices", [0, 1, 2, 3]);

    postCommandRaw(`{"id":"mesh.duplicate"}`);  // ok/error tolerated
    auto m = getModel();
    assert(m["vertexCount"].integer == 8,
        "verts mode duplicate must not add verts; got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6);
}

unittest { // edges-mode duplicate: rejected (no useful standalone-edge semantics).
    resetCube();
    postSelect("edges", [0, 1, 2, 3]);

    postCommandRaw(`{"id":"mesh.duplicate"}`);
    auto m = getModel();
    assert(m["vertexCount"].integer == 8);
    assert(m["faceCount"].integer == 6);
    assert(m["edgeCount"].integer == 12);
}
