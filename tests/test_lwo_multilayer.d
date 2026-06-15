// Multi-layer LWO import regression guard (layered, layers Stage 3).
//
// LWO POLS indices are relative to the CURRENT layer's PNTS — each LAYR chunk
// resets the point base. The old importLWO concatenated all PNTS / all POLS
// into one array, so a second layer's faces pointed at the WRONG vertices
// (off by the first layer's point count). io.lwo_import now starts a fresh
// ImportedPart per LAYR.
//
// Since layers Stage 3 a multi-part interchange import NO LONGER flattens: each
// LWO LAYR becomes its own document Layer (first active/foreground, the rest
// visible background). The per-part face re-offset that used to run at import
// now runs only on EXPORT (flattenDocument). This test pins both:
//   * import keeps the two layers separate — each layer's faces stay
//     LAYER-LOCAL (the quad is [0,1,2,3], the triangle is [0,1,2], NOT
//     re-offset), and each layer's geometry matches its raw LWO coords;
//   * OBJ EXPORT is layer-aware (Stage 4): a 2-layer document exports as one
//     aiMesh per layer (child-node-per-layer), so re-importing the .obj yields
//     TWO parts with layer-local geometry — NOT the old flat 7-vert / 2-face
//     merge. (The flatten path now only runs for FBX export.)
//
// Fixture (LWO2):
//   FORM <size> LWO2
//     LAYR 0 "quad"
//     PNTS  4 verts  (a unit quad at z=0)
//     POLS  FACE  1 quad  [0,1,2,3]          (layer-local indices)
//     LAYR 1 "tri"
//     PNTS  3 verts  (a triangle at z=+5, well away from layer 0)
//     POLS  FACE  1 tri   [0,1,2]            (layer-local indices)

import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write, remove, exists;
import std.format : format;
import std.math   : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// LWO2 byte writers (inline; lwo helpers are private).
// ---------------------------------------------------------------------------

void writeU16BE(ref ubyte[] buf, ushort v) {
    buf ~= cast(ubyte)(v >> 8);
    buf ~= cast(ubyte)(v);
}

void writeU32BE(ref ubyte[] buf, uint v) {
    buf ~= cast(ubyte)(v >> 24);
    buf ~= cast(ubyte)(v >> 16);
    buf ~= cast(ubyte)(v >>  8);
    buf ~= cast(ubyte)(v);
}

void writeF32BE(ref ubyte[] buf, float v) {
    writeU32BE(buf, *cast(uint*)&v);
}

void writeTag(ref ubyte[] buf, string tag) {
    assert(tag.length == 4);
    foreach (c; tag) buf ~= cast(ubyte) c;
}

void writeVX(ref ubyte[] buf, uint idx) {
    if (idx < 0xFF00) {
        writeU16BE(buf, cast(ushort) idx);
    } else {
        buf ~= 0xFF;
        buf ~= cast(ubyte)(idx >> 16);
        buf ~= cast(ubyte)(idx >>  8);
        buf ~= cast(ubyte)(idx);
    }
}

void writeName(ref ubyte[] buf, string name) {
    foreach (c; name) buf ~= cast(ubyte) c;
    buf ~= 0;                               // null terminator
    if (buf.length & 1) buf ~= 0;           // pad to even
}

void appendChunk4(ref ubyte[] out_, string tag, const ubyte[] data) {
    writeTag(out_, tag);
    writeU32BE(out_, cast(uint) data.length);
    out_ ~= data;
    if (data.length & 1) out_ ~= 0;
}

// LAYR body: U2 number, U2 flags, VEC12 pivot, null-terminated name.
ubyte[] layrBody(ushort number, string name) {
    ubyte[] b;
    writeU16BE(b, number);     // layer number
    writeU16BE(b, 0);          // flags
    writeF32BE(b, 0.0f);       // pivot x
    writeF32BE(b, 0.0f);       // pivot y
    writeF32BE(b, 0.0f);       // pivot z
    writeName(b, name);
    return b;
}

// Layer 0: a unit quad in the z=0 plane.
static immutable float[4 * 3] quadVerts = [
    0.0f, 0.0f, 0.0f,
    1.0f, 0.0f, 0.0f,
    1.0f, 1.0f, 0.0f,
    0.0f, 1.0f, 0.0f,
];
// Layer 1: a triangle at z=+5 (far from layer 0 so a wrong-offset bug shows).
static immutable float[3 * 3] triVerts = [
    0.0f, 0.0f, 5.0f,
    2.0f, 0.0f, 5.0f,
    1.0f, 3.0f, 5.0f,
];

ubyte[] buildMultiLayerLwo() {
    ubyte[] body;

    // --- Layer 0 ---
    appendChunk4(body, "LAYR", layrBody(0, "quad"));

    ubyte[] pnts0;
    foreach (f; quadVerts) writeF32BE(pnts0, f);
    appendChunk4(body, "PNTS", pnts0);

    ubyte[] pols0;
    writeTag(pols0, "FACE");
    writeU16BE(pols0, 4);                       // 4-vert face
    foreach (idx; [0u, 1u, 2u, 3u]) writeVX(pols0, idx);   // layer-LOCAL
    appendChunk4(body, "POLS", pols0);

    // --- Layer 1 ---
    appendChunk4(body, "LAYR", layrBody(1, "tri"));

    ubyte[] pnts1;
    foreach (f; triVerts) writeF32BE(pnts1, f);
    appendChunk4(body, "PNTS", pnts1);

    ubyte[] pols1;
    writeTag(pols1, "FACE");
    writeU16BE(pols1, 3);                        // 3-vert face
    foreach (idx; [0u, 1u, 2u]) writeVX(pols1, idx);        // layer-LOCAL
    appendChunk4(body, "POLS", pols1);

    // FORM <size> LWO2 <body>
    ubyte[] out_;
    writeTag(out_, "FORM");
    writeU32BE(out_, cast(uint)(4 + body.length));
    writeTag(out_, "LWO2");
    out_ ~= body;
    return out_;
}

// ---------------------------------------------------------------------------
// Test plumbing
// ---------------------------------------------------------------------------

string fixturePath() {
    return "/tmp/vibe3d_test_lwo_multilayer.lwo";
}

void writeFixture() {
    write(fixturePath(), buildMultiLayerLwo());
}

void loadFixture() {
    auto resp = post("http://localhost:8080/api/command",
        "file.load path:\"" ~ fixturePath() ~ "\"");
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", "file.load failed: " ~ resp);
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

JSONValue modelLayer(int n) {
    return parseJSON(get("http://localhost:8080/api/model?layer=" ~ n.to!string));
}

JSONValue layers() {
    return parseJSON(get("http://localhost:8080/api/layers"));
}

void saveOk(string path) {
    auto resp = post("http://localhost:8080/api/command",
        "file.save path:\"" ~ path ~ "\"");
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok", "file.save failed: " ~ resp);
}

void resetApp() { post("http://localhost:8080/api/reset", ""); }

double[] vat(JSONValue m, long i) {
    auto a = m["vertices"].array[i].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest {  // the two LWO layers import as TWO document layers (no flattening)
    writeFixture();
    loadFixture();

    auto L = layers();
    auto ls = L["layers"].array;
    assert(ls.length == 2,
        "2-layer LWO should import as 2 layers, got " ~ ls.length.to!string);
    assert(L["active"].integer == 0, "first layer must be active");
    assert(ls[0]["background"].type == JSONType.false_,
        "layer 0 (active) is foreground");
    assert(ls[1]["background"].type == JSONType.true_,
        "layer 1 is background reference geometry");

    // Layer 0: the quad (4 verts / 1 face); layer 1: the triangle (3 / 1).
    assert(ls[0]["vertexCount"].integer == 4 && ls[0]["faceCount"].integer == 1,
        "layer 0 should be the 4-vert quad");
    assert(ls[1]["vertexCount"].integer == 3 && ls[1]["faceCount"].integer == 1,
        "layer 1 should be the 3-vert triangle");
}

unittest {  // each layer keeps LAYER-LOCAL face indices + its own raw geometry
    writeFixture();
    loadFixture();

    // --- layer 0: the quad, indices [0,1,2,3], z=0 ---
    auto m0 = modelLayer(0);
    auto f0 = m0["faces"].array;
    assert(f0.length == 1 && f0[0].array.length == 4, "layer 0 = one quad");
    foreach (k, idx; f0[0].array) {
        assert(idx.integer == k,
            "layer 0 quad indices are layer-local (NOT re-offset)");
        assert(approxEqual(vat(m0, idx.integer)[2], 0.0),
            "layer 0 quad verts are at z=0");
    }

    // --- layer 1: the triangle, indices [0,1,2] (layer-LOCAL, not 4,5,6) ---
    auto m1 = modelLayer(1);
    auto f1 = m1["faces"].array;
    assert(f1.length == 1 && f1[0].array.length == 3, "layer 1 = one triangle");
    foreach (k, idx; f1[0].array) {
        assert(idx.integer == k,
            format("layer 1 tri indices must be LAYER-LOCAL [0,1,2], got %d at %d",
                   idx.integer, k));
        auto p = vat(m1, idx.integer);
        assert(approxEqual(p[0], triVerts[k * 3 + 0])
            && approxEqual(p[1], triVerts[k * 3 + 1])
            && approxEqual(p[2], triVerts[k * 3 + 2]),
            format("layer 1 tri vert %d = %s, expected %s", k, p.to!string,
                   [triVerts[k*3], triVerts[k*3+1], triVerts[k*3+2]].to!string));
    }
}

unittest {  // OBJ-witness (Stage 4): export NO LONGER flattens — 2 layers → 2 parts
    writeFixture();
    loadFixture();

    // Stage 4 routes OBJ/glTF export through the LAYER-AWARE exporter: one aiMesh
    // per Document layer on its own child node. assimp's OBJ exporter emits one
    // group per mesh, so re-import yields TWO parts (NOT the old flat 7v/2f merge).
    // This is the OBJ-witness the plan MOVED out of the LWO stage into Stage 4.
    const objPath = "/tmp/vibe3d_test_lwo_multilayer_obj.obj";
    if (exists(objPath)) remove(objPath);
    saveOk(objPath);
    assert(exists(objPath), "OBJ export should write a file");

    resetApp();
    auto resp = post("http://localhost:8080/api/command",
        "file.load path:\"" ~ objPath ~ "\"");
    assert(parseJSON(resp)["status"].str == "ok", "OBJ reload failed: " ~ resp);

    // Two parts, NOT one flat 7-vert mesh.
    auto L = layers();
    auto ls = L["layers"].array;
    assert(ls.length == 2,
        "2-layer OBJ export must re-import as 2 layers (not flattened), got "
        ~ ls.length.to!string);

    // Geometry survives per layer: one layer carries the z=0 quad (4 verts),
    // the other the z=+5 triangle (3 verts). Order is exporter-defined, so check
    // by content, not by index.
    bool sawQuadZ0 = false, sawTriZ5 = false;
    foreach (li; 0 .. 2) {
        auto m = modelLayer(cast(int) li);
        const vc = m["vertexCount"].integer;
        const z  = vat(m, 0)[2];
        if (vc == 4 && approxEqual(z, 0.0)) sawQuadZ0 = true;
        if (vc == 3 && approxEqual(z, 5.0)) sawTriZ5 = true;
    }
    assert(sawQuadZ0,
        "one re-imported layer must be the z=0 quad (4 verts)");
    assert(sawTriZ5,
        "one re-imported layer must be the z=+5 triangle (3 verts)");

    remove(objPath);
}
