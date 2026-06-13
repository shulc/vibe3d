// Layered interchange import (layers Stage 3) — a multi-part import yields
// MULTIPLE layers instead of one flattened mesh; export flattens the visible
// layers back to a single mesh; the layered document round-trips through .v3d.
//
// Spec cases (doc/layers_document_plan.md Stage 3):
//   * A 2-object OBJ → /api/layers shows 2 layers (first active/foreground,
//     second visible + background). Single-part imports stay one layer.
//   * Geometry per ?layer=N: layer 0 is the first object, layer 1 the second.
//   * Export (OBJ) flattens visible layers → flattened vertex count == sum of
//     the visible layers' vertex counts.
//   * Round-trip via .v3d keeps BOTH layers (native is the layered source of
//     truth; the v2 schema carries every layer).
//
// The OBJ import path is available in the modeling build (assimp is statically
// linked), so this drives the same file.load / file.save / /api/model HTTP path
// the other interchange guards use. OBJ objects are IDENTITY-transform, so no
// node-transform bake is exercised here (that lives in test_gltf_transform.d).

import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write, remove, exists;
import std.format : format;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// Fixtures (OBJ is plain text). Two disjoint quads as separate `o` objects:
// one at the origin, one far away at x=+10. Each is a single quad (4 verts).
// ---------------------------------------------------------------------------

enum string twoObjObj =
    "o quadA\n"
    ~ "v 0 0 0\n"   // 1
    ~ "v 1 0 0\n"   // 2
    ~ "v 1 1 0\n"   // 3
    ~ "v 0 1 0\n"   // 4
    ~ "f 1 2 3 4\n"
    ~ "o quadB\n"
    ~ "v 10 0 0\n"  // 5
    ~ "v 11 0 0\n"  // 6
    ~ "v 11 1 0\n"  // 7
    ~ "v 10 1 0\n"  // 8
    ~ "f 5 6 7 8\n";

// Single-object OBJ: one unit cube (8 verts, 6 quad faces). Must stay ONE layer.
enum string cubeObj =
    "o cube\n"
    ~ "v 0 0 0\n" ~ "v 1 0 0\n" ~ "v 1 1 0\n" ~ "v 0 1 0\n"
    ~ "v 0 0 1\n" ~ "v 1 0 1\n" ~ "v 1 1 1\n" ~ "v 0 1 1\n"
    ~ "f 1 4 3 2\n" ~ "f 5 6 7 8\n" ~ "f 1 5 8 4\n"
    ~ "f 2 3 7 6\n" ~ "f 4 8 7 3\n" ~ "f 1 2 6 5\n";

string twoPath()  { return "/tmp/vibe3d_test_layer_import_two.obj"; }
string cubePath() { return "/tmp/vibe3d_test_layer_import_cube.obj"; }
string objOut()   { return "/tmp/vibe3d_test_layer_import_flat.obj"; }
string v3dOut()   { return "/tmp/vibe3d_test_layer_import_rt.v3d"; }

// ---------------------------------------------------------------------------
// HTTP plumbing
// ---------------------------------------------------------------------------

void resetApp() { post(baseUrl ~ "/api/reset", ""); }

JSONValue cmd(string argstring) {
    auto resp = cast(string) post(baseUrl ~ "/api/command", argstring);
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", "cmd `" ~ argstring ~ "` failed: " ~ resp);
    return j;
}

void loadOk(string path) { cmd("file.load path:\"" ~ path ~ "\""); }
void saveOk(string path) { cmd("file.save path:\"" ~ path ~ "\""); }

JSONValue layers() { return parseJSON(cast(string) get(baseUrl ~ "/api/layers")); }
JSONValue model()  { return parseJSON(cast(string) get(baseUrl ~ "/api/model")); }
JSONValue modelLayer(int n) {
    return parseJSON(cast(string) get(baseUrl ~ "/api/model?layer=" ~ n.to!string));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest {  // 2-part OBJ → two layers; first active/foreground, second background
    write(twoPath(), twoObjObj);
    resetApp();
    loadOk(twoPath());

    auto L = layers();
    assert(L["active"].integer == 0, "first layer must be active after import");
    auto ls = L["layers"].array;
    assert(ls.length == 2,
        "2-object OBJ should import as 2 layers, got " ~ ls.length.to!string);

    // Layer 0: active, foreground (not background), visible.
    assert(ls[0]["active"].type == JSONType.true_, "layer 0 should be active");
    assert(ls[0]["background"].type == JSONType.false_,
        "layer 0 (active) must be foreground (background=false)");
    assert(ls[0]["visible"].type == JSONType.true_, "layer 0 must be visible");

    // Layer 1: not active, background, visible.
    assert(ls[1]["active"].type == JSONType.false_, "layer 1 should not be active");
    assert(ls[1]["background"].type == JSONType.true_,
        "layer 1 (non-first) must be background");
    assert(ls[1]["visible"].type == JSONType.true_,
        "layer 1 must be visible (reference geometry)");

    // Each layer holds one quad.
    assert(ls[0]["vertexCount"].integer == 4 && ls[0]["faceCount"].integer == 1,
        "layer 0 should be a single quad");
    assert(ls[1]["vertexCount"].integer == 4 && ls[1]["faceCount"].integer == 1,
        "layer 1 should be a single quad");

    remove(twoPath());
}

unittest {  // geometry per ?layer=N: layer 0 = origin object, layer 1 = far object
    write(twoPath(), twoObjObj);
    resetApp();
    loadOk(twoPath());

    // /api/model (default) and ?layer=0 both = the active (origin) object.
    foreach (m; [model(), modelLayer(0)]) {
        assert(m["vertexCount"].integer == 4, "active/layer 0 = 4 verts");
        foreach (v; m["vertices"].array)
            assert(v.array[0].floating <= 1.5,
                "layer 0 should hold the origin object only");
    }

    // ?layer=1 = the far (background) object.
    auto m1 = modelLayer(1);
    assert(m1["vertexCount"].integer == 4, "layer 1 = 4 verts");
    foreach (v; m1["vertices"].array)
        assert(v.array[0].floating >= 9.5,
            "layer 1 should hold the far object only");

    remove(twoPath());
}

unittest {  // export flattens VISIBLE layers → vertex count == sum of layers
    write(twoPath(), twoObjObj);
    resetApp();
    loadOk(twoPath());

    if (exists(objOut())) remove(objOut());
    saveOk(objOut());
    assert(exists(objOut()), "OBJ export should write a file");

    // Re-import the flattened OBJ. It is now ONE object (a single `o` group
    // assimp synthesizes from the merged mesh), so it lands as ONE layer of 8
    // verts (4 + 4 from the two visible layers).
    resetApp();
    loadOk(objOut());

    auto L = layers();
    assert(L["layers"].array.length == 1,
        "flattened OBJ re-imports as a single layer (one object)");
    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "flattened export must contain BOTH visible layers (4+4=8 verts), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 2,
        "flattened export must contain both quads (2 faces), got "
        ~ m["faceCount"].integer.to!string);

    // Both clusters present (origin + far) → both layers were flattened.
    bool nearOrigin = false, nearFar = false;
    foreach (v; m["vertices"].array) {
        const x = v.array[0].floating;
        if (x <= 1.5) nearOrigin = true;
        if (x >= 9.5) nearFar = true;
    }
    assert(nearOrigin && nearFar,
        "flattened export must contain both the origin and the far object");

    remove(twoPath());
    remove(objOut());
}

unittest {  // round-trip via .v3d keeps BOTH layers (native = layered source)
    write(twoPath(), twoObjObj);
    resetApp();
    loadOk(twoPath());

    if (exists(v3dOut())) remove(v3dOut());
    saveOk(v3dOut());
    assert(exists(v3dOut()), ".v3d save should write a file");

    // Reset to a single-layer cube, then reload the .v3d: it must restore BOTH
    // layers with their flags intact.
    resetApp();
    loadOk(v3dOut());

    auto L = layers();
    auto ls = L["layers"].array;
    assert(ls.length == 2,
        ".v3d round-trip must preserve both layers, got " ~ ls.length.to!string);
    assert(L["active"].integer == 0, "round-trip preserves the active index");
    assert(ls[1]["background"].type == JSONType.true_,
        "round-trip preserves the background flag on layer 1");

    // Geometry per layer survives.
    auto m0 = modelLayer(0);
    auto m1 = modelLayer(1);
    assert(m0["vertexCount"].integer == 4 && m1["vertexCount"].integer == 4,
        "round-trip preserves per-layer geometry");
    foreach (v; m0["vertices"].array)
        assert(v.array[0].floating <= 1.5, "layer 0 origin object preserved");
    foreach (v; m1["vertices"].array)
        assert(v.array[0].floating >= 9.5, "layer 1 far object preserved");

    remove(twoPath());
    remove(v3dOut());
}

unittest {  // single-part import stays ONE layer (guard: only multi-part splits)
    write(cubePath(), cubeObj);
    resetApp();
    loadOk(cubePath());

    auto L = layers();
    assert(L["layers"].array.length == 1,
        "single-object OBJ must import as ONE layer (no spurious split)");
    auto m = model();
    assert(m["vertexCount"].integer == 8,
        "single-part cube must be 8 verts (unchanged), got "
        ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 6,
        "single-part cube must be 6 faces (unchanged), got "
        ~ m["faceCount"].integer.to!string);

    remove(cubePath());
}
