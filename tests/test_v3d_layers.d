// Tests for the layered (formatVersion 8) `.v3d` document schema.
//
// The Document round-trips through `.v3d` with the item-selection SET
// persisted. A v8 file is a `layers` array — each entry carrying a `"type"`
// wire token, a `selected` flag, its whole authored `channels` object and a
// payload block per capability — plus `primaryLayer` and `focusedItem` indices.
// There is NO `background` key (background derives: visible && !selected) and
// NO `activeLayer` key (primaryLayer replaces it).
//
// v8 (task 0616 Ph6) moved `name`, `visible` and the twelve item-transform
// components OUT of the layer envelope and INTO `channels`, and deleted the
// grouped `xform` block. Every earlier shape is REJECTED — a deliberate clean
// break, no migration. The transform round-trip itself is covered in
// test_layer_xform_io.d; here the bare envelope is asserted.
//
// Coverage:
//   1. a save emits the v8 shape (formatVersion 8, primaryLayer, layers[0] with
//      type/selected/channels — and NO background/activeLayer/name/visible
//      top-level keys);
//   2. save -> load round-trip preserves geometry;
//   3. a multi-layer v8 file round-trips the SELECTED SET + primary identity;
//   4. legacy fixtures (v7 / v3 / v2 / v1) are rejected cleanly and leave the
//      document untouched.
//
// These drive the public HTTP surface only — geometry is asserted through
// /api/model; raw file content is read straight off disk (the writer is the
// thing under test).

import http_client : testBaseUrl;
import std.net.curl;
import std.json;
import std.file : remove, exists, getSize, write, readText;
import std.conv : to;

void main() {}

void resetCube() {
    post(testBaseUrl() ~ "/api/reset", "");
}

void runCmd(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    auto resp = post(testBaseUrl() ~ "/api/command", body);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", id ~ " failed: " ~ resp);
}

string runCmdAllowError(string id, string params = "") {
    string body = params.length > 0
        ? `{"id":"` ~ id ~ `","params":` ~ params ~ `}`
        : `{"id":"` ~ id ~ `"}`;
    return cast(string) post(testBaseUrl() ~ "/api/command", body);
}

JSONValue model() {
    return parseJSON(get(testBaseUrl() ~ "/api/model"));
}

unittest { // a save emits the v8 layered shape (formatVersion + primaryLayer + layers[0] envelope)
    enum string path = "/tmp/vibe3d-test-v3-shape.v3d";
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    runCmd("file.save", `{"path":"` ~ path ~ `"}`);
    assert(exists(path), "expected " ~ path ~ " after save");
    assert(getSize(path) > 0, "saved file is empty");

    // Read the raw file: this is the writer under test, so we inspect bytes.
    auto doc = parseJSON(readText(path));

    assert(doc["formatVersion"].integer == 8,
        "writer must emit formatVersion 8, got "
        ~ doc["formatVersion"].integer.to!string);

    // v8 names the edit target via primaryLayer (NOT activeLayer), and the
    // item-selection FOCUS separately.
    assert("primaryLayer" in doc, "v8 doc must carry primaryLayer");
    assert(doc["primaryLayer"].integer == 0, "single-layer doc is primary=0");
    assert("focusedItem" in doc, "v8 doc must carry focusedItem");
    assert(doc["focusedItem"].integer == 0,
        "on an all-mesh document the focus coincides with the primary");
    assert("activeLayer" !in doc, "v8 doc must NOT carry the retired activeLayer key");

    assert("layers" in doc, "v8 doc must carry a layers array");
    assert(doc["layers"].type == JSONType.array, "layers must be an array");
    assert(doc["layers"].array.length == 1,
        "single-layer runtime writes exactly one layer, got "
        ~ doc["layers"].array.length.to!string);

    auto l0 = doc["layers"].array[0];
    assert("type" in l0 && l0["type"].str == "mesh",
        "every v8 item declares its kind by wire token");
    // `name` and `visible` are CHANNELS in v8, not envelope keys. Asserting
    // both halves (present in channels, absent at top level) is the point: one
    // half alone would pass an implementation that wrote the value twice.
    assert("channels" in l0, "v8 layer must carry a channels object");
    auto ch = l0["channels"];
    assert("name" in ch && ch["name"].str == "Layer 1",
        "first layer is named 'Layer 1', through its channel");
    assert("visible" in ch && ch["visible"].type == JSONType.true_,
        "first layer is visible, through its channel");
    assert("name" !in l0 && "visible" !in l0,
        "…and NOT also at the top level — two representations of one value is "
        ~ "what v8 removed");
    // v8 persists `selected` (the item-selection SET) in the envelope, because
    // it is governed by the selection invariants and is deliberately NOT a
    // param. The lone layer is the primary, hence selected.
    assert("selected" in l0 && l0["selected"].type == JSONType.true_,
        "first layer is selected (foreground / primary)");
    assert("background" !in l0,
        "v8 layer must NOT carry the retired background key");
    assert("xform" !in l0,
        "the grouped xform block is retired — the transform is twelve flat "
        ~ "channel keys now");
    assert("pos.x" in ch && "pivot.z" in ch,
        "…and those keys really are there");

    // The per-layer mesh sub-object is the shared shape (vertices + faces present).
    assert("mesh" in l0 && l0["mesh"].type == JSONType.object,
        "layer carries a mesh object");
    auto sub = l0["mesh"];
    assert("vertices" in sub && sub["vertices"].array.length == 8,
        "cube mesh sub-object carries 8 vertices");
    assert("faces" in sub && sub["faces"].array.length == 6,
        "cube mesh sub-object carries 6 faces");
}

unittest { // save -> load round-trip preserves geometry through the v8 path
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
                ~ " mismatch after the round-trip");
    }
}

unittest { // a multi-layer v8 file round-trips the SELECTED SET + primary identity
    // Three layers. The file marks layers 0 and 2 selected (a multi-foreground
    // SET) and names layer 2 as primary. /api/model is primary-only, so it must
    // report the primary (layer 2) geometry. Re-saving must preserve the SAME
    // selected set + primary in the v8 shape.
    enum string path = "/tmp/vibe3d-test-v3-multilayer.v3d";
    write(path,
        `{"formatVersion":8,"primaryLayer":2,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"Tri","visible":true},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}},`
        ~ `{"type":"mesh","selected":false,"channels":{"name":"Quad","visible":true},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],`
        ~ `"faces":[[0,1,2,3]]}},`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"Pent","visible":true},`
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
    // (0 and 2) + primary (2); the writer must reproduce both.
    enum string outp = "/tmp/vibe3d-test-v3-multilayer-out.v3d";
    if (exists(outp)) remove(outp);
    scope(exit) if (exists(outp)) remove(outp);
    runCmd("file.save", `{"path":"` ~ outp ~ `"}`);
    auto saved = parseJSON(readText(outp));

    assert(saved["formatVersion"].integer == 8, "re-save is v8");
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

unittest { // a v8 file with an empty "layers" array is rejected cleanly
    enum string path = "/tmp/vibe3d-test-v3-emptylayers.v3d";
    write(path, `{"formatVersion":8,"primaryLayer":0,"layers":[]}`);
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
        `{"formatVersion":8,"primaryLayer":5,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"Only","visible":true},`
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

unittest { // a file whose edit target is marked deselected round-trips LATCHED
    // ~~an inconsistent file (primary marked deselected) is forced selected…
    // the reader must FORCE the primary selected (the edit target can't be
    // deselected).~~
    //
    // TASK 0671 — that file is not inconsistent any more, it is the ordinary
    // encoding of a latched edit target: drop the item selection, or select a
    // reference plane, and this is what gets written. Forcing it selected would
    // round-trip the document into a different one. The reader now seats the
    // named item at the head of its kind's recently-deselected cache instead —
    // the state that produces exactly this file.
    enum string path = "/tmp/vibe3d-test-v3-inconsistent.v3d";
    write(path,
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":false,"channels":{"name":"Only","visible":true},`
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
    assert(saved["layers"].array[0]["selected"].type == JSONType.false_,
        "the deselected edit target stays deselected across the round trip — "
        ~ "`true` here is a reader that installs the target by SELECTING it");
    assert(saved["primaryLayer"].integer == 0,
        "…and it is still named as the edit target, so what came back is the "
        ~ "state that was read and not merely an emptied selection");
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

unittest { // the IMMEDIATELY PREVIOUS version (v7) is REJECTED cleanly
    // v7 rather than v3: the near miss is the one users actually hit, and it is
    // the shape a reader that tolerated "close enough" would wave through — a
    // v7 layer envelope differs from v8 only by where `name`/`visible`/`xform`
    // live, so it would parse into a plausible-looking document if the version
    // gate ever softened.
    enum string path = "/tmp/vibe3d-test-v7-reject.v3d";
    write(path,
        `{"formatVersion":7,"primaryLayer":0,"layers":[`
        ~ `{"name":"Layer 1","visible":true,"selected":true,`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[0,1,0]],"faces":[[0,1,2]]}}`
        ~ `]}`);
    scope(exit) if (exists(path)) remove(path);

    resetCube();
    auto resp = runCmdAllowError("file.load", `{"path":"` ~ path ~ `"}`);
    auto j = parseJSON(resp);
    assert(j["status"].str == "error",
        "expected error for a v7 file (the task 0616 Ph6 clean break), got: " ~ resp);

    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "cube must be intact after a rejected v7 load");
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
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"Tri","visible":true},`
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
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"Tri","visible":true},`
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
        `{"formatVersion":8,"primaryLayer":0,"layers":[`
        ~ `{"type":"mesh","selected":true,"channels":{"name":"Quad","visible":true},`
        ~ `"mesh":{"vertices":[[0,0,0],[1,0,0],[1,1,0],[0,1,0]],`
        ~ `"faces":[[0,1,2,3]],`
        ~ `"uvMaps":[{"name":"uv","dim":2,`
        ~ `"data":[0.0,0.0, 1.0,0.0, 1.0,1.0, 0.0,1.0]}]}},`
        ~ `{"type":"mesh","selected":false,"channels":{"name":"Tri","visible":true},`
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
