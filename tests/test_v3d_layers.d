// Tests for the layered (formatVersion 2) `.v3d` document schema.
//
// Stage 1 of the layered-document work: the Document round-trips through
// `.v3d`. Files are written as v2 (a `layers` array wrapping the v1 mesh
// sub-object); a legacy v1 file (top-level `mesh`) still loads as one
// default-flag layer. Runtime stays single-layer.
//
// Coverage:
//   1. a hand-built v1 JSON file loads (geometry via /api/model);
//   2. a save emits v2 shape (formatVersion 2, layers[0] with flags);
//   3. save -> load round-trip preserves geometry;
//   4. malformed/edge cases: empty `layers` array rejected, out-of-range
//      activeLayer clamped, v1 default-flag wrapping.
//
// These drive the public HTTP surface only — geometry is asserted through
// /api/model; raw v2 file content is read straight off disk (the writer is
// the thing under test).

import std.net.curl;
import std.json;
import std.file : remove, exists, getSize, write, readText;
import std.conv : to;

void main() {}

void resetCube() {
    post("http://localhost:8080/api/reset", "");
}

void runCmd(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto resp = post("http://localhost:8080/api/command", body);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", id ~ " failed: " ~ resp);
}

string runCmdAllowError(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    return cast(string) post("http://localhost:8080/api/command", body);
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

unittest { // a hand-built v1 (legacy top-level "mesh") file still loads
    // The v1 schema must load forever — pinned with a hand-written file, not
    // one this build generated (the build now writes v2 only).
    enum string path = "/tmp/vibe3d-test-v1-legacy.v3d";
    // A single triangle in the old top-level-mesh shape.
    write(path,
        `{"formatVersion":1,"mesh":{`
        ~ `"vertices":[[0,0,0],[1,0,0],[0,1,0]],`
        ~ `"faces":[[0,1,2]]}}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    auto m = model();
    assert(m["vertexCount"].integer == 3,
        "v1 file should load 3 verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1,
        "v1 file should load 1 face, got "
        ~ m["faceCount"].integer.to!string);
}

unittest { // a save emits the v2 layered shape (formatVersion + layers[0] flags)
    enum string path = "/tmp/vibe3d-test-v2-shape.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");
    assert(getSize(path) > 0, "saved file is empty");

    // Read the raw file: this is the writer under test, so we inspect bytes.
    auto doc = parseJSON(readText(path));

    assert(doc["formatVersion"].integer == 2,
        "writer must emit formatVersion 2, got "
        ~ doc["formatVersion"].integer.to!string);

    assert("activeLayer" in doc, "v2 doc must carry activeLayer");
    assert(doc["activeLayer"].integer == 0, "single-layer doc is active=0");

    assert("layers" in doc, "v2 doc must carry a layers array");
    assert(doc["layers"].type == JSONType.array, "layers must be an array");
    assert(doc["layers"].array.length == 1,
        "single-layer runtime writes exactly one layer, got "
        ~ doc["layers"].array.length.to!string);

    auto l0 = doc["layers"].array[0];
    assert("name" in l0 && l0["name"].str == "Layer 1",
        "first layer is named 'Layer 1'");
    assert("visible" in l0 && l0["visible"].type == JSONType.true_,
        "first layer is visible");
    assert("background" in l0 && l0["background"].type == JSONType.false_,
        "first layer is foreground (background == false)");

    // The per-layer mesh sub-object is the v1 shape (vertices + faces present).
    assert("mesh" in l0 && l0["mesh"].type == JSONType.object,
        "layer carries a mesh object");
    auto sub = l0["mesh"];
    assert("vertices" in sub && sub["vertices"].array.length == 8,
        "cube mesh sub-object carries 8 vertices");
    assert("faces" in sub && sub["faces"].array.length == 6,
        "cube mesh sub-object carries 6 faces");
}

unittest { // save -> load round-trip preserves geometry through the v2 path
    enum string path = "/tmp/vibe3d-test-v2-roundtrip.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto orig = model();
    long origV = orig["vertexCount"].integer;
    long origE = orig["edgeCount"].integer;
    long origF = orig["faceCount"].integer;
    assert(origV == 8 && origE == 12 && origF == 6, "cube prerequisite");

    runCmd("file.save", `{"path":"` ~ path ~ `"}`);

    // Mutate so a stale state can't masquerade as a successful load.
    runCmd("mesh.subdivide");
    assert(model()["vertexCount"].integer == 26,
        "subdivide should leave 26 verts before reload");

    runCmd("file.load", `{"path":"` ~ path ~ `"}`);
    auto reloaded = model();

    assert(reloaded["vertexCount"].integer == origV, "round-trip vertexCount");
    assert(reloaded["edgeCount"].integer  == origE, "round-trip edgeCount");
    assert(reloaded["faceCount"].integer  == origF, "round-trip faceCount");

    // Exact vertex positions survive (same %f formatter on both ends).
    auto origVerts = orig["vertices"].array;
    auto reVerts   = reloaded["vertices"].array;
    assert(reVerts.length == origVerts.length, "round-trip vertex array length");
    foreach (i, v; reVerts) {
        auto o = origVerts[i].array;
        auto r = v.array;
        foreach (k; 0 .. 3)
            assert(r[k].floating == o[k].floating,
                "vertex " ~ i.to!string ~ " comp " ~ k.to!string
                ~ " mismatch after v2 round-trip");
    }
}

unittest { // a v2 file with an empty "layers" array is rejected cleanly
    enum string path = "/tmp/vibe3d-test-v2-emptylayers.v3d";
    write(path, `{"formatVersion":2,"activeLayer":0,"layers":[]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for empty layers array, got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "mesh should be intact after empty-layers load");
}

unittest { // an out-of-range activeLayer is clamped, not rejected
    // activeLayer 5 with a single layer must clamp to index 0 and load fine.
    enum string path = "/tmp/vibe3d-test-v2-badactive.v3d";
    write(path,
        `{"formatVersion":2,"activeLayer":5,"layers":[`
        ~ `{"name":"Only","visible":true,"background":false,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    auto m = model();
    assert(m["vertexCount"].integer == 3,
        "clamped active layer should load its 3-vert mesh, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1, "clamped active layer face count");
}

unittest { // a v2 multi-layer file loads; the active layer is what /api/model shows
    // Two layers with different geometry: layer 0 a triangle (active), layer 1
    // a quad marked background. /api/model is active-only, so it must report
    // the triangle. Stage 1 keeps runtime single-layer, but the reader builds
    // every layer; this pins that the active layer is selected correctly and a
    // freshly built background layer does not corrupt the load.
    enum string path = "/tmp/vibe3d-test-v2-multilayer.v3d";
    write(path,
        `{"formatVersion":2,"activeLayer":0,"layers":[`
        ~ `{"name":"Tri","visible":true,"background":false,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}},`
        ~ `{"name":"Quad","visible":true,"background":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],`
        ~ `"faces":[[0,1,2,3]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    auto m = model();
    assert(m["vertexCount"].integer == 3,
        "active layer 0 (triangle) should show 3 verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1, "active layer 0 face count");

    // Re-save: the document now holds two layers, so the v2 writer must emit
    // both (round-trip of a multi-layer document through the active load path).
    enum string outp = "/tmp/vibe3d-test-v2-multilayer-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));
    assert(saved["formatVersion"].integer == 2, "re-save is v2");
    assert(saved["layers"].array.length == 2,
        "re-save must preserve both layers, got "
        ~ saved["layers"].array.length.to!string);
    assert(saved["layers"].array[1]["background"].type == JSONType.true_,
        "second layer keeps its background flag through the round-trip");
}
