// Tests for the layered (formatVersion 6) `.v3d` document schema.
//
// Selection-types Stage 3: the Document round-trips through `.v3d` with the
// item-selection SET persisted. Files are written as v5 — a `layers` array
// (each entry carrying a `selected` flag, plus an optional per-layer `xform`
// item-transform block — per-item channels Phase 1) wrapping the shared mesh
// sub-object, plus a `primaryLayer` index naming the edit target. There is NO
// `background` key (background derives: visible && !selected) and NO
// `activeLayer` key (primaryLayer replaces it). The legacy v1 (top-level
// `mesh`), v2 (`activeLayer` + per-layer `background`), v3 (no `uvMaps`) and v4
// (no per-layer `xform`) shapes are REJECTED — a deliberate clean break (no
// external clients, no migration). The per-layer `xform` round-trip itself is
// covered in test_layer_xform_io.d; here the bare envelope is asserted at v5.
//
// Coverage:
//   1. a save emits the v5 shape (formatVersion 5, primaryLayer, layers[0] with
//      name/visible/selected — and NO background/activeLayer keys);
//   2. save -> load round-trip preserves geometry;
//   3. a multi-layer v5 file round-trips the SELECTED SET + primary identity;
//   4. a v4 fixture (and v3 / v2 / v1) is rejected cleanly and leaves the
//      document untouched.
//
// These drive the public HTTP surface only — geometry is asserted through
// /api/model; raw v5 file content is read straight off disk (the writer is the
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

unittest { // a save emits the v5 layered shape (formatVersion + primaryLayer + layers[0] flags)
    enum string path = "/tmp/vibe3d-test-v3-shape.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");
    assert(getSize(path) > 0, "saved file is empty");

    // Read the raw file: this is the writer under test, so we inspect bytes.
    auto doc = parseJSON(readText(path));

    assert(doc["formatVersion"].integer == 6,
        "writer must emit formatVersion 6, got "
        ~ doc["formatVersion"].integer.to!string);

    // v5 names the edit target via primaryLayer (NOT activeLayer).
    assert("primaryLayer" in doc, "v5 doc must carry primaryLayer");
    assert(doc["primaryLayer"].integer == 0, "single-layer doc is primary=0");
    assert("activeLayer" !in doc, "v5 doc must NOT carry the retired activeLayer key");

    assert("layers" in doc, "v5 doc must carry a layers array");
    assert(doc["layers"].type == JSONType.array, "layers must be an array");
    assert(doc["layers"].array.length == 1,
        "single-layer runtime writes exactly one layer, got "
        ~ doc["layers"].array.length.to!string);

    auto l0 = doc["layers"].array[0];
    assert("name" in l0 && l0["name"].str == "Layer 1",
        "first layer is named 'Layer 1'");
    assert("visible" in l0 && l0["visible"].type == JSONType.true_,
        "first layer is visible");
    // v5 persists `selected` (the item-selection SET); the lone layer is the
    // primary, hence selected. The retired `background` key must be gone.
    assert("selected" in l0 && l0["selected"].type == JSONType.true_,
        "first layer is selected (foreground / primary)");
    assert("background" !in l0,
        "v5 layer must NOT carry the retired background key");
    // A fresh cube has an identity transform, so the optional xform key is
    // omitted (omit-when-default). The xform round-trip is in test_layer_xform_io.
    assert("xform" !in l0,
        "a default (identity) layer must omit the optional xform key");

    // The per-layer mesh sub-object is the shared shape (vertices + faces present).
    assert("mesh" in l0 && l0["mesh"].type == JSONType.object,
        "layer carries a mesh object");
    auto sub = l0["mesh"];
    assert("vertices" in sub && sub["vertices"].array.length == 8,
        "cube mesh sub-object carries 8 vertices");
    assert("faces" in sub && sub["faces"].array.length == 6,
        "cube mesh sub-object carries 6 faces");
}

unittest { // save -> load round-trip preserves geometry through the v5 path
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
                ~ " mismatch after v5 round-trip");
    }
}

unittest { // a multi-layer v5 file round-trips the SELECTED SET + primary identity
    // Three layers. The file marks layers 0 and 2 selected (a multi-foreground
    // SET) and names layer 2 as primary. /api/model is primary-only, so it must
    // report the primary (layer 2) geometry. Re-saving must preserve the SAME
    // selected set + primary in the v5 shape.
    enum string path = "/tmp/vibe3d-test-v3-multilayer.v3d";
    write(path,
        `{"formatVersion":6,"primaryLayer":2,"layers":[`
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
    // (0 and 2) + primary (2); the v5 writer must reproduce both.
    enum string outp = "/tmp/vibe3d-test-v3-multilayer-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));

    assert(saved["formatVersion"].integer == 6, "re-save is v6");
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

unittest { // a v4 file with an empty "layers" array is rejected cleanly
    enum string path = "/tmp/vibe3d-test-v3-emptylayers.v3d";
    write(path, `{"formatVersion":6,"primaryLayer":0,"layers":[]}`);
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
        `{"formatVersion":6,"primaryLayer":5,"layers":[`
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

unittest { // an inconsistent v4 file (primary marked deselected) is forced selected
    // The file names layer 0 primary but marks it `selected:false`. The reader
    // must FORCE the primary selected (the edit target can't be deselected), so
    // the re-saved file shows it selected.
    enum string path = "/tmp/vibe3d-test-v3-inconsistent.v3d";
    write(path,
        `{"formatVersion":6,"primaryLayer":0,"layers":[`
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

unittest { // a v3 file (no uvMaps) is now REJECTED cleanly (the UV-maps Stage 3 break)
    // v3 was the previous current shape (layers + selected + primaryLayer, no
    // uvMaps). Bumping past v3 makes it reject at the version gate, leaving the
    // cube untouched — same deliberate clean-break stance as the v2/v1 rejects.
    enum string path = "/tmp/vibe3d-test-v3-reject.v3d";
    write(path,
        `{"formatVersion":3,"primaryLayer":0,"layers":[`
        ~ `{"name":"Layer 1","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for legacy v3 file (UV-maps Stage 3 clean break), got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "cube must be intact after a rejected v3 load");
}

unittest { // per-corner UV round-trips byte-exact through load -> save
    // A single triangle (3 corners) with a DISTINCT u,v per corner — so any
    // corner misalignment in the load (faceCornerLoop fill) or the save (CSR
    // emit) would change the re-saved data. There is no HTTP surface for UV, so
    // the round-trip is verified by re-saving and comparing `uvMaps` bytes: the
    // load fills the PolyVertex map in corner==loop order, the save re-emits it
    // in the same order, so an exact match proves the corner correspondence held.
    enum string path = "/tmp/vibe3d-test-v4-uv-in.v3d";
    write(path,
        `{"formatVersion":6,"primaryLayer":0,"layers":[`
        ~ `{"name":"Tri","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]],`
        ~ `"uvMaps":[{"name":"uv","dim":2,`
        ~ `"data":[0.1,0.2, 0.3,0.4, 0.5,0.6]}]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    // Geometry loaded (the file's triangle, not the reset cube).
    auto m = model();
    assert(m["vertexCount"].integer == 3, "triangle should load (3 verts)");
    assert(m["faceCount"].integer == 1, "triangle should load (1 face)");

    // Re-save and read the uvMaps block straight off disk.
    enum string outp = "/tmp/vibe3d-test-v4-uv-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));

    auto sub = saved["layers"].array[0]["mesh"];
    assert("uvMaps" in sub, "re-saved mesh must carry uvMaps");
    auto uvm = sub["uvMaps"].array;
    assert(uvm.length == 1, "exactly one uv map, got " ~ uvm.length.to!string);
    assert(uvm[0]["name"].str == "uv", "map name is 'uv'");
    assert(uvm[0]["dim"].integer == 2, "map dim is 2");

    // Per-corner data byte-exact (float text deterministic on both ends).
    float[] expect = [0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f];
    auto data = uvm[0]["data"].array;
    assert(data.length == expect.length,
        "uv data length mismatch: expected 6, got " ~ data.length.to!string);
    foreach (i, e; expect) {
        const float got = cast(float) (data[i].type == JSONType.float_
            ? data[i].floating : data[i].integer);
        assert(got == e,
            "uv corner value " ~ i.to!string ~ " mismatch: expected "
            ~ e.to!string ~ ", got " ~ got.to!string);
    }
}

unittest { // a wrong-length uvMaps entry is ignored tolerantly (file still loads)
    // The triangle has 3 corners → 6 floats are required for a dim-2 map. The
    // file supplies only 4, so the reader must SKIP the map with a warning and
    // still load the geometry. Re-saving must then carry NO uvMaps (the map was
    // never registered) — proving the tolerant skip, not a crash.
    enum string path = "/tmp/vibe3d-test-v4-uv-badlen.v3d";
    write(path,
        `{"formatVersion":6,"primaryLayer":0,"layers":[`
        ~ `{"name":"Tri","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]],`
        ~ `"uvMaps":[{"name":"uv","dim":2,"data":[0.1,0.2, 0.3,0.4]}]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    // Geometry loaded fine despite the bad map.
    auto m = model();
    assert(m["vertexCount"].integer == 3,
        "triangle must still load with a wrong-length uvMaps");
    assert(m["faceCount"].integer == 1, "triangle face count after tolerant skip");

    // Re-save: the skipped map was never registered, so no uvMaps key is emitted.
    enum string outp = "/tmp/vibe3d-test-v4-uv-badlen-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));
    auto sub = saved["layers"].array[0]["mesh"];
    assert("uvMaps" !in sub,
        "a tolerantly-skipped map must NOT reappear in the re-saved file");
}

unittest { // a multi-layer doc round-trips UV on ONE layer, none on the other
    // Two layers: layer 0 (a quad, primary) carries a per-corner uv map; layer 1
    // (a triangle) carries none. The round-trip must preserve UV on layer 0 and
    // leave layer 1 UV-less — maps are per-layer (they live inside each layer's
    // own mesh sub-object), so they must not bleed across layers.
    enum string path = "/tmp/vibe3d-test-v4-uv-multilayer.v3d";
    write(path,
        `{"formatVersion":6,"primaryLayer":0,"layers":[`
        ~ `{"name":"Quad","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],`
        ~ `"faces":[[0,1,2,3]],`
        ~ `"uvMaps":[{"name":"uv","dim":2,`
        ~ `"data":[0.0,0.0, 1.0,0.0, 1.0,1.0, 0.0,1.0]}]}},`
        ~ `{"name":"Tri","visible":true,"selected":false,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.load", `{"path":"` ~ path ~ `"}`);

    // Primary (layer 0) is the quad.
    auto m = model();
    assert(m["vertexCount"].integer == 4, "primary quad should load (4 verts)");

    enum string outp = "/tmp/vibe3d-test-v4-uv-multilayer-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));
    auto layers = saved["layers"].array;
    assert(layers.length == 2, "both layers re-saved");

    // Layer 0 keeps its uv map (4 corners * 2 = 8 floats).
    auto sub0 = layers[0]["mesh"];
    assert("uvMaps" in sub0, "layer 0 must keep its uv map");
    auto uvm0 = sub0["uvMaps"].array;
    assert(uvm0.length == 1 && uvm0[0]["name"].str == "uv", "layer 0 'uv' map");
    assert(uvm0[0]["data"].array.length == 8,
        "layer 0 uv data is 4 corners * 2, got "
        ~ uvm0[0]["data"].array.length.to!string);
    float[] expect = [0.0f,0.0f, 1.0f,0.0f, 1.0f,1.0f, 0.0f,1.0f];
    auto d0 = uvm0[0]["data"].array;
    foreach (i, e; expect) {
        const float got = cast(float) (d0[i].type == JSONType.float_
            ? d0[i].floating : d0[i].integer);
        assert(got == e, "layer 0 uv corner " ~ i.to!string ~ " mismatch");
    }

    // Layer 1 has no uv map and must NOT have gained one.
    auto sub1 = layers[1]["mesh"];
    assert("uvMaps" !in sub1,
        "layer 1 had no uv map and must not gain one across the round-trip");
}
