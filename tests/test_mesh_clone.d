// Tests for mesh.clone (task 0123).
//
// mesh.clone duplicates the selected faces (or whole mesh when empty) and
// offsets the single copy by `offset`.  It is distinct from mesh.array in
// two ways:
//   - count is fixed at 2 (one original + exactly one copy).
//   - weld is PINNED to 0, so a zero-offset clone keeps the coincident copy
//     rather than welding it back into the original.
//
// Cube layout (centered at origin, half-size 0.5):
//   v0=(-0.5,-0.5,-0.5)  v1=(+0.5,-0.5,-0.5)  v2=(+0.5,+0.5,-0.5)  v3=(-0.5,+0.5,-0.5)
//   v4=(-0.5,-0.5,+0.5)  v5=(+0.5,-0.5,+0.5)  v6=(+0.5,+0.5,+0.5)  v7=(-0.5,+0.5,+0.5)
// Face 4 = top face (y = +0.5): verts v3, v2, v6, v7.

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

void postCommand(string body_) {
    auto resp = post("http://localhost:8080/api/command", body_);
    assert(parseJSON(resp)["status"].str == "ok",
        "/api/command failed: " ~ resp);
}

JSONValue postCommandRaw(string body_) {
    return parseJSON(post("http://localhost:8080/api/command", body_));
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

// ---------------------------------------------------------------------------
// Selected-face clone — top face → offset [0,2,0]
// ---------------------------------------------------------------------------

unittest { // Select top face (index 4) and clone it upward.
           // Original 8 verts + 4 copy verts = 12 verts.
           // Original 6 faces + 1 copy face  = 7 faces.
           // Copy is selected; original faces deselected.
    resetCube();
    postSelect("polygons", [4]);   // top face

    postCommand(`{"id":"mesh.clone","params":{"offset":[0,2,0]}}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 12,
        "verts: expected 12, got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 7,
        "faces: expected 7, got " ~ m["faceCount"].integer.to!string);

    // Copy should be selected (face index 6).
    auto sel = getSelection();
    auto selFaces = sel["selectedFaces"].array;
    assert(selFaces.length == 1,
        "expected 1 selected face (copy), got " ~ selFaces.length.to!string);
    assert(selFaces[0].integer == 6,
        "expected selected face index 6, got " ~ selFaces[0].integer.to!string);

    // Copy verts should be at y = +0.5 + 2.0 = +2.5.
    // Top-face verts of a unit cube at y=+0.5: v2,v3,v6,v7.
    auto verts = m["vertices"].array;
    int seen25 = 0;
    foreach (v; verts) {
        double y = v.array[1].floating;
        if (approxEq(y, 2.5)) ++seen25;
    }
    assert(seen25 == 4,
        "expected 4 copy verts at y=2.5, got " ~ seen25.to!string);
}

// ---------------------------------------------------------------------------
// Original-vert-unchanged invariant
// ---------------------------------------------------------------------------

unittest { // arrayFaces appends; the first 8 verts must be byte-stable.
    resetCube();

    // Read original vert coords.
    auto pre = getModel();
    auto preVerts = pre["vertices"].array;
    assert(preVerts.length == 8);

    postSelect("polygons", [4]);
    postCommand(`{"id":"mesh.clone","params":{"offset":[0,2,0]}}`);

    auto post = getModel();
    auto postVerts = post["vertices"].array;
    assert(postVerts.length == 12,
        "expected 12 verts after clone, got " ~ postVerts.length.to!string);

    // First 8 entries must be identical to the originals.
    foreach (i; 0 .. 8) {
        foreach (k; 0 .. 3) {
            double before_ = preVerts[i].array[k].floating;
            double after_  = postVerts[i].array[k].floating;
            assert(approxEq(before_, after_, 1e-7),
                "vert " ~ i.to!string ~ " coord " ~ k.to!string
                ~ " changed: " ~ before_.to!string ~ " → " ~ after_.to!string);
        }
    }
}

// ---------------------------------------------------------------------------
// Whole-mesh fallback — empty selection → clone all faces
// ---------------------------------------------------------------------------

unittest { // No face selection ⇒ act on all faces (same as mesh.array).
           // 8 original + 8 copy = 16 verts; 6 + 6 = 12 faces.
    resetCube();
    // No postSelect — leave selection empty.

    postCommand(`{"id":"mesh.clone","params":{"offset":[3,0,0]}}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "verts: expected 16 (whole-mesh clone), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "faces: expected 12, got " ~ m["faceCount"].integer.to!string);

    // Copy verts should be at x ∈ {2.5, 3.5}.
    auto verts = m["vertices"].array;
    int seen25 = 0, seen35 = 0;
    foreach (v; verts) {
        double x = v.array[0].floating;
        if (approxEq(x, 2.5)) ++seen25;
        if (approxEq(x, 3.5)) ++seen35;
    }
    assert(seen25 == 4 && seen35 == 4,
        "copy positions wrong; got " ~ seen25.to!string
        ~ "@2.5, " ~ seen35.to!string ~ "@3.5");
}

// ---------------------------------------------------------------------------
// Zero-offset — weld=0 keeps the coincident copy (NOT welded away)
// ---------------------------------------------------------------------------

unittest { // offset=[0,0,0] with weld PINNED to 0: the coincident copy is
           // kept.  mesh.array with its default weld=0.001 would collapse
           // the zero-offset copy back to 8 verts — this test guards the pin.
    resetCube();

    postCommand(`{"id":"mesh.clone","params":{"offset":[0,0,0]}}`);

    auto m = getModel();
    assert(m["vertexCount"].integer == 16,
        "zero-offset weld=0: expected 16 verts (copy kept), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 12,
        "zero-offset: expected 12 faces, got " ~ m["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Undo restores original geometry
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    postSelect("polygons", [4]);
    postCommand(`{"id":"mesh.clone","params":{"offset":[0,1,0]}}`);

    // Confirm the clone happened.
    auto post = getModel();
    assert(post["vertexCount"].integer == 12,
        "post-clone: expected 12 verts");

    // Undo.
    auto undoResp = postUndo();
    assert(undoResp["status"].str == "ok", "undo failed: " ~ undoResp.toString);

    auto restored = getModel();
    assert(restored["vertexCount"].integer == 8,
        "post-undo: expected 8 verts, got "
        ~ restored["vertexCount"].integer.to!string);
    assert(restored["faceCount"].integer == 6,
        "post-undo: expected 6 faces, got "
        ~ restored["faceCount"].integer.to!string);
}

// ---------------------------------------------------------------------------
// Empty mesh — mesh.clone returns error (faces.length == 0 guard)
// ---------------------------------------------------------------------------

unittest {
    resetCube();
    // Delete all faces.
    postSelect("polygons", [0, 1, 2, 3, 4, 5]);
    postCommand(`{"id":"mesh.delete"}`);

    auto preEmpty = getModel();
    assert(preEmpty["faceCount"].integer == 0, "setup: mesh should be empty");

    // mesh.clone on an empty mesh must return status:error, not crash.
    auto resp = postCommandRaw(`{"id":"mesh.clone","params":{"offset":[1,0,0]}}`);
    assert(resp["status"].str == "error",
        "expected status:error on empty mesh, got " ~ resp["status"].str);

    // Mesh stays empty.
    auto m = getModel();
    assert(m["faceCount"].integer == 0, "empty mesh mutated by failed clone");
}
