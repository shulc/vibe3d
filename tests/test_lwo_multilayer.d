// Multi-layer LWO import regression guard.
//
// LWO POLS indices are relative to the CURRENT layer's PNTS — each LAYR chunk
// resets the point base. The old importLWO concatenated all PNTS / all POLS
// into one array, so a second layer's faces pointed at the WRONG vertices
// (off by the first layer's point count). io.lwo_import now starts a fresh
// ImportedPart per LAYR; flattenToMesh re-offsets each part's faces by the
// running vertex count, so the merged mesh is correct.
//
// Fixture (LWO2):
//   FORM <size> LWO2
//     LAYR 0 "quad"
//     PNTS  4 verts  (a unit quad at z=0)
//     POLS  FACE  1 quad  [0,1,2,3]          (layer-local indices)
//     LAYR 1 "tri"
//     PNTS  3 verts  (a triangle at z=+5, well away from layer 0)
//     POLS  FACE  1 tri   [0,1,2]            (layer-local indices)
//
// Assertions: merged mesh has 7 verts (4+3) and 2 faces; the triangle face
// resolves to vertices 4,5,6 (offset applied) whose positions match layer 1's
// raw coords. Under the OLD code the triangle face would be [0,1,2] pointing
// at layer-0 verts (geometry collapsed / wrong) — this test fails on that.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest {  // both layers' vertices merge: 4 + 3 = 7
    writeFixture();
    loadFixture();
    auto m = model();
    assert(m["vertexCount"].integer == 7,
        "expected 7 verts (4+3), got " ~ m["vertexCount"].integer.to!string);
    assert(m["faceCount"].integer == 2,
        "expected 2 faces (quad+tri), got " ~ m["faceCount"].integer.to!string);
}

unittest {  // layer-1's triangle resolves to the OFFSET verts 4,5,6
    writeFixture();
    loadFixture();
    auto m = model();

    auto faces = m["faces"].array;
    assert(faces.length == 2, "expected 2 faces");

    // The quad (4 indices) is face 0; the triangle (3 indices) is face 1.
    auto quad = faces[0].array;
    auto tri  = faces[1].array;
    assert(quad.length == 4, "face 0 should be the 4-vert quad");
    assert(tri.length  == 3, "face 1 should be the 3-vert triangle");

    // Triangle indices must be OFFSET past layer 0's 4 verts → 4,5,6.
    // (The OLD concatenation bug would leave them at 0,1,2.)
    auto t0 = tri[0].integer, t1 = tri[1].integer, t2 = tri[2].integer;
    assert(t0 == 4 && t1 == 5 && t2 == 6,
        format("triangle should resolve to verts 4,5,6, got %d,%d,%d",
               t0, t1, t2));

    // All indices in range — no out-of-range / degenerate faces.
    auto verts = m["vertices"].array;
    assert(verts.length == 7, "expected 7 vertex tuples");
    foreach (f; faces)
        foreach (idx; f.array)
            assert(idx.integer >= 0 && idx.integer < 7,
                "face index out of range: " ~ idx.integer.to!string);

    // The triangle verts must carry layer-1's z=+5 coords (geometry matches
    // the second layer, not a stale copy of the first).
    auto vat(long i) {
        auto a = verts[i].array;
        return [a[0].floating, a[1].floating, a[2].floating];
    }
    foreach (k, idx; [t0, t1, t2]) {
        auto p = vat(idx);
        assert(approxEqual(p[0], triVerts[k * 3 + 0])
            && approxEqual(p[1], triVerts[k * 3 + 1])
            && approxEqual(p[2], triVerts[k * 3 + 2]),
            format("tri vert %d (mesh idx %d) = %s, expected %s",
                   k, idx, p.to!string,
                   [triVerts[k*3], triVerts[k*3+1], triVerts[k*3+2]].to!string));
    }

    // And the quad verts must carry layer-0's z=0 coords.
    foreach (k; 0 .. 4) {
        auto p = vat(quad[k].integer);
        assert(approxEqual(p[2], 0.0),
            format("quad vert %d z = %f, expected 0", k, p[2]));
    }
}
