// Tests for subphase 6.1a: prim.cube headless command.
//
// Exercises the HTTP API surface for BoxTool / buildCuboidParametric:
//   - Default 1x1x1 cube       → 8 verts / 6 faces
//   - Segmented 2/2/2 cube     → 26 verts / 24 faces
//   - sizeY=0 plane            → 4 verts / 1 face
//   - Undo after prim.cube     → restores empty scene
//   - JSON path parity         → same result as argstring path

import std.net.curl;
import std.json;
import std.conv : to;
import std.math : fabs;

void main() {}

string baseUrl = "http://localhost:8080";

string apiUrl(string path) { return baseUrl ~ path; }

JSONValue postJson(string path, string body_)
{
    return parseJSON(cast(string) post(apiUrl(path), body_));
}

JSONValue getModel()
{
    return parseJSON(cast(string) get(apiUrl("/api/model")));
}

void resetEmpty()
{
    auto resp = postJson("/api/reset?empty=true", "");
    assert(resp["status"].str == "ok", "reset(empty) failed: " ~ resp.toString);
}

// Post a prim.cube command via the argstring path and return the response.
JSONValue primCubeArgstring(string params)
{
    return postJson("/api/command", "prim.cube " ~ params);
}

// Post a prim.cube command via the JSON path and return the response.
JSONValue primCubeJson(string paramsJson)
{
    return postJson("/api/command",
        `{"id":"prim.cube","params":{` ~ paramsJson ~ `}}`);
}

// -------------------------------------------------------------------------
// 1. Default 1x1x1 cube → 8 verts / 6 faces
// -------------------------------------------------------------------------

unittest { // prim.cube argstring default → 8v/6f
    resetEmpty();
    auto resp = primCubeArgstring("sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", "argstring prim.cube failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 8,
        "default cube: expected 8 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 6,
        "default cube: expected 6 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 2. Segmented 2/2/2 → 26 verts / 24 faces
// -------------------------------------------------------------------------

unittest { // prim.cube segments 2/2/2 → 26v/24f
    resetEmpty();
    auto resp = primCubeArgstring(
        "sizeX:1.0 sizeY:1.0 sizeZ:1.0 segmentsX:2 segmentsY:2 segmentsZ:2");
    assert(resp["status"].str == "ok", "segmented prim.cube failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 26,
        "2/2/2 cube: expected 26 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 24,
        "2/2/2 cube: expected 24 faces, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 3. sizeY=0 → XZ plane: 4 verts / 1 face
// -------------------------------------------------------------------------

unittest { // prim.cube sizeY=0 → 4v/1f XZ plane
    resetEmpty();
    auto resp = primCubeArgstring("sizeX:1.0 sizeY:0.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", "plane prim.cube failed: " ~ resp.toString);
    auto m = getModel();
    assert(m["vertices"].array.length == 4,
        "plane: expected 4 verts, got " ~ m["vertices"].array.length.to!string);
    assert(m["faces"].array.length == 1,
        "plane: expected 1 face, got " ~ m["faces"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 4. Undo restores empty scene
// -------------------------------------------------------------------------

unittest { // undo after prim.cube restores empty mesh
    resetEmpty();
    auto r1 = primCubeArgstring("sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(r1["status"].str == "ok", r1.toString);
    auto m1 = getModel();
    assert(m1["vertices"].array.length == 8, "before undo: expected 8 verts");

    auto u = postJson("/api/undo", "");
    assert(u["status"].str == "ok", "undo failed: " ~ u.toString);
    auto m2 = getModel();
    assert(m2["vertices"].array.length == 0,
        "after undo: expected 0 verts, got " ~ m2["vertices"].array.length.to!string);
}

// -------------------------------------------------------------------------
// 5. JSON path parity: same geometry as argstring path
// -------------------------------------------------------------------------

unittest { // JSON path produces same vertex/face count as argstring
    // Argstring path
    resetEmpty();
    primCubeArgstring("sizeX:2.0 sizeY:3.0 sizeZ:4.0");
    auto ma = getModel();
    size_t vA = ma["vertices"].array.length;
    size_t fA = ma["faces"].array.length;

    // JSON path
    resetEmpty();
    primCubeJson(`"sizeX":2.0,"sizeY":3.0,"sizeZ":4.0`);
    auto mj = getModel();
    size_t vJ = mj["vertices"].array.length;
    size_t fJ = mj["faces"].array.length;

    assert(vA == vJ,
        "JSON vs argstring vert count mismatch: " ~ vA.to!string ~ " vs " ~ vJ.to!string);
    assert(fA == fJ,
        "JSON vs argstring face count mismatch: " ~ fA.to!string ~ " vs " ~ fJ.to!string);
    assert(vA == 8, "cuboid: expected 8 verts, got " ~ vA.to!string);
    assert(fA == 6, "cuboid: expected 6 faces, got " ~ fA.to!string);
}

// -------------------------------------------------------------------------
// 6. Non-default position: cenY=1.5 shifts mesh up
// -------------------------------------------------------------------------

unittest { // cenY=1.5 centers cube at y=1.5
    resetEmpty();
    auto resp = primCubeArgstring("cenY:1.5 sizeX:1.0 sizeY:1.0 sizeZ:1.0");
    assert(resp["status"].str == "ok", resp.toString);
    auto m = getModel();
    // All verts should have y in [1.0, 2.0].
    foreach (v; m["vertices"].array) {
        double y = v.array[1].floating;
        assert(y >= 0.99 && y <= 2.01,
            "cenY=1.5: vert y out of [1,2]: " ~ y.to!string);
    }
}
