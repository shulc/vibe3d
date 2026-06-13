// Tests for the layered (formatVersion 3) `.v3d` document schema.
//
// Selection-types Stage 3: the Document round-trips through `.v3d` with the
// item-selection SET persisted. Files are written as v3 — a `layers` array
// (each entry carrying a `selected` flag) wrapping the shared mesh sub-object,
// plus a `primaryLayer` index naming the edit target. There is NO `background`
// key (background derives: visible && !selected) and NO `activeLayer` key
// (primaryLayer replaces it). The legacy v1 (top-level `mesh`) and v2
// (`activeLayer` + per-layer `background`) shapes are REJECTED — a deliberate
// clean break (no external clients).
//
// Coverage:
//   1. a save emits the v3 shape (formatVersion 3, primaryLayer, layers[0] with
//      name/visible/selected — and NO background/activeLayer keys);
//   2. save -> load round-trip preserves geometry;
//   3. a multi-layer v3 file round-trips the SELECTED SET + primary identity;
//   4. a v2 fixture (and a v1 fixture) is rejected cleanly and leaves the
//      document untouched.
//
// These drive the public HTTP surface only — geometry is asserted through
// /api/model; raw v3 file content is read straight off disk (the writer is the
// thing under test).

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

unittest { // a save emits the v3 layered shape (formatVersion + primaryLayer + layers[0] flags)
    enum string path = "/tmp/vibe3d-test-v3-shape.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");
    assert(getSize(path) > 0, "saved file is empty");

    // Read the raw file: this is the writer under test, so we inspect bytes.
    auto doc = parseJSON(readText(path));

    assert(doc["formatVersion"].integer == 3,
        "writer must emit formatVersion 3, got "
        ~ doc["formatVersion"].integer.to!string);

    // v3 names the edit target via primaryLayer (NOT activeLayer).
    assert("primaryLayer" in doc, "v3 doc must carry primaryLayer");
    assert(doc["primaryLayer"].integer == 0, "single-layer doc is primary=0");
    assert("activeLayer" !in doc, "v3 doc must NOT carry the retired activeLayer key");

    assert("layers" in doc, "v3 doc must carry a layers array");
    assert(doc["layers"].type == JSONType.array, "layers must be an array");
    assert(doc["layers"].array.length == 1,
        "single-layer runtime writes exactly one layer, got "
        ~ doc["layers"].array.length.to!string);

    auto l0 = doc["layers"].array[0];
    assert("name" in l0 && l0["name"].str == "Layer 1",
        "first layer is named 'Layer 1'");
    assert("visible" in l0 && l0["visible"].type == JSONType.true_,
        "first layer is visible");
    // v3 persists `selected` (the item-selection SET); the lone layer is the
    // primary, hence selected. The retired `background` key must be gone.
    assert("selected" in l0 && l0["selected"].type == JSONType.true_,
        "first layer is selected (foreground / primary)");
    assert("background" !in l0,
        "v3 layer must NOT carry the retired background key");

    // The per-layer mesh sub-object is the shared shape (vertices + faces present).
    assert("mesh" in l0 && l0["mesh"].type == JSONType.object,
        "layer carries a mesh object");
    auto sub = l0["mesh"];
    assert("vertices" in sub && sub["vertices"].array.length == 8,
        "cube mesh sub-object carries 8 vertices");
    assert("faces" in sub && sub["faces"].array.length == 6,
        "cube mesh sub-object carries 6 faces");
}

unittest { // save -> load round-trip preserves geometry through the v3 path
    enum string path = "/tmp/vibe3d-test-v3-roundtrip.v3d";
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
                ~ " mismatch after v3 round-trip");
    }
}

unittest { // a multi-layer v3 file round-trips the SELECTED SET + primary identity
    // Three layers. The file marks layers 0 and 2 selected (a multi-foreground
    // SET) and names layer 2 as primary. /api/model is primary-only, so it must
    // report the primary (layer 2) geometry. Re-saving must preserve the SAME
    // selected set + primary in the v3 shape.
    enum string path = "/tmp/vibe3d-test-v3-multilayer.v3d";
    write(path,
        `{"formatVersion":3,"primaryLayer":2,"layers":[`
        ~ `{"name":"Tri","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}},`
        ~ `{"name":"Quad","visible":true,"selected":false,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],`
        ~ `"faces":[[0,1,2,3]]}},`
        ~ `{"name":"Pent","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0],[-1,0,0]],`
        ~ `"faces":[[0,1,2,3,4]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    auto m = model();
    assert(m["vertexCount"].integer == 5,
        "primary layer 2 (pentagon) should show 5 verts, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1, "primary layer 2 face count");

    // Re-save: the document now holds three layers with the same selected set
    // (0 and 2) + primary (2); the v3 writer must reproduce both.
    enum string outp = "/tmp/vibe3d-test-v3-multilayer-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));

    assert(saved["formatVersion"].integer == 3, "re-save is v3");
    assert(saved["primaryLayer"].integer == 2,
        "re-save preserves primary index 2, got "
        ~ saved["primaryLayer"].integer.to!string);
    assert(saved["layers"].array.length == 3,
        "re-save must preserve all three layers, got "
        ~ saved["layers"].array.length.to!string);

    // The selected SET survives by identity: layers 0 and 2 selected, 1 not.
    auto sl = saved["layers"].array;
    assert(sl[0]["selected"].type == JSONType.true_, "layer 0 stays selected");
    assert(sl[1]["selected"].type == JSONType.false_, "layer 1 stays deselected");
    assert(sl[2]["selected"].type == JSONType.true_, "layer 2 (primary) stays selected");
    // No retired keys leak back out.
    assert("background" !in sl[0], "no background key on re-saved layer");
    assert("activeLayer" !in saved, "no activeLayer key on re-saved doc");
}

unittest { // a v3 file with an empty "layers" array is rejected cleanly
    enum string path = "/tmp/vibe3d-test-v3-emptylayers.v3d";
    write(path, `{"formatVersion":3,"primaryLayer":0,"layers":[]}`);
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

unittest { // an out-of-range primaryLayer is clamped, not rejected
    // primaryLayer 5 with a single layer must clamp to index 0 and load fine.
    enum string path = "/tmp/vibe3d-test-v3-badprimary.v3d";
    write(path,
        `{"formatVersion":3,"primaryLayer":5,"layers":[`
        ~ `{"name":"Only","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    auto m = model();
    assert(m["vertexCount"].integer == 3,
        "clamped primary layer should load its 3-vert mesh, got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 1, "clamped primary layer face count");
}

unittest { // an inconsistent v3 file (primary marked deselected) is forced selected
    // The file names layer 0 primary but marks it `selected:false`. The reader
    // must FORCE the primary selected (the edit target can't be deselected), so
    // the re-saved file shows it selected.
    enum string path = "/tmp/vibe3d-test-v3-inconsistent.v3d";
    write(path,
        `{"formatVersion":3,"primaryLayer":0,"layers":[`
        ~ `{"name":"Only","visible":true,"selected":false,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    enum string outp = "/tmp/vibe3d-test-v3-inconsistent-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));
    assert(saved["layers"].array[0]["selected"].type == JSONType.true_,
        "the primary must be forced selected even if the file marked it deselected");
}

unittest { // a legacy v2 file is now REJECTED cleanly (the deliberate Stage 3 break)
    // v2 shape: activeLayer + per-layer background, no per-layer selected. The
    // reader must reject at the version gate and leave the cube untouched.
    enum string path = "/tmp/vibe3d-test-v2-reject.v3d";
    write(path,
        `{"formatVersion":2,"activeLayer":0,"layers":[`
        ~ `{"name":"Layer 1","visible":true,"background":false,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for legacy v2 file (Stage 3 clean break), got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "cube must be intact after a rejected v2 load");
}

unittest { // a legacy v1 file (top-level mesh) is now REJECTED cleanly
    // v1 shape: top-level `mesh`, no `layers`. Rejected at the version gate.
    enum string path = "/tmp/vibe3d-test-v1-reject.v3d";
    write(path,
        `{"formatVersion":1,"mesh":{`
        ~ `"vertices":[[0,0,0],[1,0,0],[0,1,0]],`
        ~ `"faces":[[0,1,2]]}}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for legacy v1 file (Stage 3 clean break), got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "cube must be intact after a rejected v1 load");
}
