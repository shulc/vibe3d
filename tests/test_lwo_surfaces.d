// Tests for MG2 — vibe3d's LWO loader parses TAGS / SURF / PTAG into
// mesh.surfaces and mesh.faceMaterial. The fixture is built on the fly
// (no large binary blobs in the repo) and dropped into /tmp.
//
// LWO2 layout assembled below:
//   FORM <size> LWO2
//     TAGS  "Red" "Green" "Blue"
//     PNTS  8 cube verts
//     POLS  FACE  6 quad faces
//     PTAG  SURF  faces 0-1 → tag 0, 2-3 → tag 1, 4-5 → tag 2
//     SURF  "Red"   { COLR 0.85 0.10 0.10 }
//     SURF  "Green" { COLR 0.15 0.75 0.20  DIFF 0.9  GLOS 0.6 }
//     SURF  "Blue"  { COLR 0.10 0.20 0.85  TRAN 0.25 }       // → opacity 0.75

import std.net.curl;
import std.json;
import std.algorithm : sort;
import std.array     : array, appender;
import std.conv      : to;
import std.file      : write;
import std.format    : format;
import std.math      : fabs;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// LWO2 byte writers — inline copies of lwo.d's helpers (which are `private`).
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

void appendSubChunk2(ref ubyte[] out_, string tag, const ubyte[] data) {
    writeTag(out_, tag);
    writeU16BE(out_, cast(ushort) data.length);
    out_ ~= data;
    if (data.length & 1) out_ ~= 0;
}

ubyte[] colrBody(float r, float g, float b) {
    ubyte[] body;
    writeF32BE(body, r);
    writeF32BE(body, g);
    writeF32BE(body, b);
    writeVX(body, 0);    // envelope = 0 (no animation)
    return body;
}

ubyte[] f32WithEnv(float v) {
    ubyte[] body;
    writeF32BE(body, v);
    writeVX(body, 0);
    return body;
}

ubyte[] buildSurfChunk(string name, float r, float g, float b,
                       float diff = float.nan,
                       float spec = float.nan,
                       float glos = float.nan,
                       float tran = float.nan) {
    ubyte[] surf;
    writeName(surf, name);            // surface name
    writeName(surf, "");              // source (empty)
    appendSubChunk2(surf, "COLR", colrBody(r, g, b));
    if (diff == diff) appendSubChunk2(surf, "DIFF", f32WithEnv(diff));
    if (spec == spec) appendSubChunk2(surf, "SPEC", f32WithEnv(spec));
    if (glos == glos) appendSubChunk2(surf, "GLOS", f32WithEnv(glos));
    if (tran == tran) appendSubChunk2(surf, "TRAN", f32WithEnv(tran));
    return surf;
}

ubyte[] buildTestLwo() {
    // Cube with 8 verts, 6 quad faces. Vertex layout matches mesh.makeCube
    // — the loader doesn't depend on a specific ordering, but matching the
    // procedural cube keeps subsequent geometry assertions easy.
    static immutable float[8 * 3] cubeVerts = [
        -0.5f, -0.5f, -0.5f,    0.5f, -0.5f, -0.5f,
         0.5f,  0.5f, -0.5f,   -0.5f,  0.5f, -0.5f,
        -0.5f, -0.5f,  0.5f,    0.5f, -0.5f,  0.5f,
         0.5f,  0.5f,  0.5f,   -0.5f,  0.5f,  0.5f,
    ];
    static immutable uint[4][6] cubeFaces = [
        [0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3],
        [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4],
    ];

    // TAGS
    ubyte[] tags;
    writeName(tags, "Red");
    writeName(tags, "Green");
    writeName(tags, "Blue");

    // PNTS
    ubyte[] pnts;
    foreach (f; cubeVerts) writeF32BE(pnts, f);

    // POLS FACE
    ubyte[] pols;
    writeTag(pols, "FACE");
    foreach (face; cubeFaces) {
        writeU16BE(pols, 4);
        foreach (idx; face) writeVX(pols, idx);
    }

    // PTAG SURF: faces 0-1 → 0 (Red), 2-3 → 1 (Green), 4-5 → 2 (Blue).
    ubyte[] ptag;
    writeTag(ptag, "SURF");
    foreach (faceIdx; 0 .. 6) {
        writeVX(ptag, cast(uint)faceIdx);
        const ushort tagIdx = cast(ushort)(faceIdx / 2);
        writeU16BE(ptag, tagIdx);
    }

    // SURF chunks.
    ubyte[] surfRed   = buildSurfChunk("Red",   0.85f, 0.10f, 0.10f);
    ubyte[] surfGreen = buildSurfChunk("Green", 0.15f, 0.75f, 0.20f,
                                        /*diff*/ 0.9f, float.nan, /*glos*/ 0.6f);
    ubyte[] surfBlue  = buildSurfChunk("Blue",  0.10f, 0.20f, 0.85f,
                                        float.nan, float.nan, float.nan,
                                        /*tran*/ 0.25f);

    // Body assembly.
    ubyte[] body;
    appendChunk4(body, "TAGS", tags);
    appendChunk4(body, "PNTS", pnts);
    appendChunk4(body, "POLS", pols);
    appendChunk4(body, "PTAG", ptag);
    appendChunk4(body, "SURF", surfRed);
    appendChunk4(body, "SURF", surfGreen);
    appendChunk4(body, "SURF", surfBlue);

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
    return "/tmp/vibe3d_test_lwo_3surfaces.lwo";
}

void writeFixture() {
    write(fixturePath(), buildTestLwo());
}

void loadFixture() {
    auto resp = post("http://localhost:8080/api/command",
        "file.load path:\"" ~ fixturePath() ~ "\"");
    auto j = parseJSON(resp);
    assert(j["status"].str == "ok",
        "file.load failed: " ~ resp);
}

JSONValue model() {
    return parseJSON(get("http://localhost:8080/api/model"));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest {  // loader recognises TAGS → mesh.surfaces with the expected names
    writeFixture();
    loadFixture();
    auto m = model();
    assert(m["faceCount"].integer == 6,
        "expected 6 faces, got " ~ m["faceCount"].integer.to!string);
    auto surfaces = m["surfaces"].array;
    assert(surfaces.length == 3,
        "expected 3 surfaces, got " ~ surfaces.length.to!string);
    assert(surfaces[0]["name"].str == "Red",   surfaces[0]["name"].str);
    assert(surfaces[1]["name"].str == "Green", surfaces[1]["name"].str);
    assert(surfaces[2]["name"].str == "Blue",  surfaces[2]["name"].str);
}

unittest {  // COLR base colours land in Surface.baseColor
    writeFixture();
    loadFixture();
    auto surfaces = model()["surfaces"].array;
    auto rgbOf(JSONValue s) {
        auto a = s["baseColor"].array;
        return [a[0].floating, a[1].floating, a[2].floating];
    }
    auto red   = rgbOf(surfaces[0]);
    auto green = rgbOf(surfaces[1]);
    auto blue  = rgbOf(surfaces[2]);
    assert(approxEqual(red[0],   0.85) && approxEqual(red[1],   0.10) && approxEqual(red[2],   0.10),
        "red rgb: " ~ red.to!string);
    assert(approxEqual(green[0], 0.15) && approxEqual(green[1], 0.75) && approxEqual(green[2], 0.20),
        "green rgb: " ~ green.to!string);
    assert(approxEqual(blue[0],  0.10) && approxEqual(blue[1],  0.20) && approxEqual(blue[2],  0.85),
        "blue rgb: " ~ blue.to!string);
}

unittest {  // DIFF / GLOS / TRAN sub-chunks land in the right Surface fields
    writeFixture();
    loadFixture();
    auto s = model()["surfaces"].array;
    // Green has DIFF=0.9, GLOS=0.6; opacity should still be 1.0 (no TRAN).
    assert(approxEqual(s[1]["diffuseAmount"].floating, 0.9),
        "green diffuse: " ~ s[1]["diffuseAmount"].floating.to!string);
    assert(approxEqual(s[1]["glossiness"].floating, 0.6),
        "green glossiness: " ~ s[1]["glossiness"].floating.to!string);
    assert(approxEqual(s[1]["opacity"].floating, 1.0),
        "green opacity: " ~ s[1]["opacity"].floating.to!string);
    // Blue has TRAN=0.25 → opacity = 1 - 0.25 = 0.75.
    assert(approxEqual(s[2]["opacity"].floating, 0.75),
        "blue opacity: " ~ s[2]["opacity"].floating.to!string);
}

unittest {  // PTAG SURF assigns the right surface index to each face
    writeFixture();
    loadFixture();
    auto fm = model()["faceMaterial"].array;
    assert(fm.length == 6, "expected 6 faceMaterial entries");
    // faces 0-1 → 0 (Red), 2-3 → 1 (Green), 4-5 → 2 (Blue).
    foreach (i, v; fm) {
        const expected = cast(int)(i / 2);
        assert(v.integer == expected,
            format("face %d → material %d (expected %d)", i, v.integer, expected));
    }
}

// ---------------------------------------------------------------------------
// MG5 — round-trip: load → file.save → load again, surfaces preserved.
// ---------------------------------------------------------------------------

unittest {  // LWO writer emits TAGS + SURF + PTAG that the loader reads back
    writeFixture();
    loadFixture();

    // Snapshot the post-load surfaces + faceMaterial so we can compare.
    auto pre = model();
    auto preSurfaces = pre["surfaces"].array;
    auto preFaceMat  = pre["faceMaterial"].array;

    // Save to a fresh path.
    const roundTripPath = "/tmp/vibe3d_test_lwo_roundtrip.lwo";
    auto saveResp = post("http://localhost:8080/api/command",
        "file.save path:\"" ~ roundTripPath ~ "\"");
    assert(parseJSON(saveResp)["status"].str == "ok",
        "file.save failed: " ~ saveResp);

    // Load it back into a fresh mesh state.
    auto loadResp = post("http://localhost:8080/api/command",
        "file.load path:\"" ~ roundTripPath ~ "\"");
    assert(parseJSON(loadResp)["status"].str == "ok",
        "file.load round-trip failed: " ~ loadResp);

    auto post_ = model();
    auto postSurfaces = post_["surfaces"].array;
    auto postFaceMat  = post_["faceMaterial"].array;

    assert(postSurfaces.length == preSurfaces.length,
        format("surfaces.length: pre=%d post=%d",
               preSurfaces.length, postSurfaces.length));
    foreach (i, ps; preSurfaces) {
        assert(postSurfaces[i]["name"].str == ps["name"].str,
            format("surface[%d].name: pre=%s post=%s",
                   i, ps["name"].str, postSurfaces[i]["name"].str));
        auto preRGB  = ps["baseColor"].array;
        auto postRGB = postSurfaces[i]["baseColor"].array;
        foreach (k; 0 .. 3) {
            assert(approxEqual(preRGB[k].floating, postRGB[k].floating),
                format("surface[%d].baseColor[%d]: pre=%f post=%f",
                       i, k, preRGB[k].floating, postRGB[k].floating));
        }
        // DIFF / GLOS / TRAN-derived opacity round-trip too.
        assert(approxEqual(ps["diffuseAmount"].floating,
                          postSurfaces[i]["diffuseAmount"].floating),
            format("surface[%d].diffuseAmount", i));
        assert(approxEqual(ps["glossiness"].floating,
                          postSurfaces[i]["glossiness"].floating),
            format("surface[%d].glossiness", i));
        assert(approxEqual(ps["opacity"].floating,
                          postSurfaces[i]["opacity"].floating),
            format("surface[%d].opacity", i));
    }
    assert(postFaceMat.length == preFaceMat.length,
        format("faceMaterial.length: pre=%d post=%d",
               preFaceMat.length, postFaceMat.length));
    foreach (i, v; preFaceMat) {
        assert(postFaceMat[i].integer == v.integer,
            format("faceMaterial[%d]: pre=%d post=%d",
                   i, v.integer, postFaceMat[i].integer));
    }
}
