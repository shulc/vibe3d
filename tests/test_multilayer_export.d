// Multi-layer interchange EXPORT round-trip (assimp OBJ / glTF) — Stage 4.
//
// Stage 4 makes OBJ/glTF export PRESERVE layers: one aiMesh per Document layer
// hung on its own child node (N>=2), or today's root-mesh shape (N==1). This
// test drives the export through the HTTP /api/command file.save path and the
// production importViaAssimp re-read, asserting:
//
//   1. OBJ : a 2-layer doc exports + re-imports as 2 parts with layer-local
//            geometry (the quad at z=0, the tri at z=+5).
//   2. glTF: same — 2 parts, geometry preserved.
//   3. Per-layer xform: setting layer 1 pos.z=+10 then exporting (OBJ + glTF)
//            re-imports that layer at its post-bake WORLD position
//            (original z + 10) — the node transform round-trips as BAKED
//            geometry (no reappearing node matrix; see the plan's Q9). The
//            expected positions are hand-computed, not via composedMatrix, to
//            avoid a tautology.
//   4. Hidden flag: a hidden layer exported to .gltf writes the ml_visible
//            metadata into the file's node `extras`. The IMPORT-side read is
//            Stage 5, so here we only grep the raw .gltf TEXT for "ml_visible"
//            (the full visible=false round-trip lands in Stage 5).
//
// The 2-layer document is built by loading the same multi-layer LWO fixture the
// import tests use (a z=0 quad layer + a z=+5 triangle layer), which gives two
// layers with distinct, non-trivial geometry to track across the round-trip.

import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write, remove, exists, readText;
import std.format : format;
import std.math   : fabs;
import std.algorithm : canFind;

void main() {}

bool approxEqual(double a, double b, double eps = 1e-4) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// LWO2 byte writers (inline) to build the 2-layer source fixture.
// ---------------------------------------------------------------------------

void writeU16BE(ref ubyte[] buf, ushort v) {
    buf ~= cast(ubyte)(v >> 8); buf ~= cast(ubyte)(v);
}
void writeU32BE(ref ubyte[] buf, uint v) {
    buf ~= cast(ubyte)(v >> 24); buf ~= cast(ubyte)(v >> 16);
    buf ~= cast(ubyte)(v >> 8);  buf ~= cast(ubyte)(v);
}
void writeF32BE(ref ubyte[] buf, float v) { writeU32BE(buf, *cast(uint*)&v); }
void writeTag(ref ubyte[] buf, string tag) { foreach (c; tag) buf ~= cast(ubyte) c; }
void writeVX(ref ubyte[] buf, uint idx) {
    if (idx < 0xFF00) writeU16BE(buf, cast(ushort) idx);
    else { buf ~= 0xFF; buf ~= cast(ubyte)(idx >> 16);
           buf ~= cast(ubyte)(idx >> 8); buf ~= cast(ubyte)(idx); }
}
void writeName(ref ubyte[] buf, string name) {
    foreach (c; name) buf ~= cast(ubyte) c;
    buf ~= 0;
    if (buf.length & 1) buf ~= 0;
}
void appendChunk4(ref ubyte[] out_, string tag, const ubyte[] data) {
    writeTag(out_, tag); writeU32BE(out_, cast(uint) data.length);
    out_ ~= data; if (data.length & 1) out_ ~= 0;
}
ubyte[] layrBody(ushort number, string name) {
    ubyte[] b;
    writeU16BE(b, number); writeU16BE(b, 0);
    writeF32BE(b, 0.0f); writeF32BE(b, 0.0f); writeF32BE(b, 0.0f);
    writeName(b, name);
    return b;
}

static immutable float[4 * 3] quadVerts = [
    0.0f, 0.0f, 0.0f,  1.0f, 0.0f, 0.0f,
    1.0f, 1.0f, 0.0f,  0.0f, 1.0f, 0.0f,
];
static immutable float[3 * 3] triVerts = [
    0.0f, 0.0f, 5.0f,  2.0f, 0.0f, 5.0f,  1.0f, 3.0f, 5.0f,
];

ubyte[] buildMultiLayerLwo() {
    ubyte[] body;
    appendChunk4(body, "LAYR", layrBody(0, "quad"));
    ubyte[] pnts0; foreach (f; quadVerts) writeF32BE(pnts0, f);
    appendChunk4(body, "PNTS", pnts0);
    ubyte[] pols0; writeTag(pols0, "FACE"); writeU16BE(pols0, 4);
    foreach (idx; [0u, 1u, 2u, 3u]) writeVX(pols0, idx);
    appendChunk4(body, "POLS", pols0);

    appendChunk4(body, "LAYR", layrBody(1, "tri"));
    ubyte[] pnts1; foreach (f; triVerts) writeF32BE(pnts1, f);
    appendChunk4(body, "PNTS", pnts1);
    ubyte[] pols1; writeTag(pols1, "FACE"); writeU16BE(pols1, 3);
    foreach (idx; [0u, 1u, 2u]) writeVX(pols1, idx);
    appendChunk4(body, "POLS", pols1);

    ubyte[] out_;
    writeTag(out_, "FORM"); writeU32BE(out_, cast(uint)(4 + body.length));
    writeTag(out_, "LWO2"); out_ ~= body;
    return out_;
}

// ---------------------------------------------------------------------------
// HTTP plumbing
// ---------------------------------------------------------------------------

enum string FIXTURE = "/tmp/vibe3d_test_mlexport_src.lwo";

void writeFixture() { write(FIXTURE, buildMultiLayerLwo()); }

void loadOk(string path) {
    auto resp = post("http://localhost:8080/api/command",
        "file.load path:\"" ~ path ~ "\"");
    assert(parseJSON(resp)["status"].str == "ok", "file.load failed: " ~ resp);
}
void saveOk(string path) {
    auto resp = post("http://localhost:8080/api/command",
        "file.save path:\"" ~ path ~ "\"");
    assert(parseJSON(resp)["status"].str == "ok", "file.save failed: " ~ resp);
}
void cmdOk(string line) {
    auto resp = post("http://localhost:8080/api/command", line);
    assert(parseJSON(resp)["status"].str == "ok", "command failed: " ~ resp);
}
void resetApp() { post("http://localhost:8080/api/reset", ""); }

JSONValue layers() {
    return parseJSON(get("http://localhost:8080/api/layers"));
}
JSONValue modelLayer(int n) {
    return parseJSON(get("http://localhost:8080/api/model?layer=" ~ n.to!string));
}
double[] vat(JSONValue m, long i) {
    auto a = m["vertices"].array[i].array;
    return [a[0].floating, a[1].floating, a[2].floating];
}

// True iff SOME re-imported layer is a `vc`-vert mesh with vertex 0 at z≈`z`.
bool sawLayer(long vc, double z) {
    auto ls = layers()["layers"].array;
    foreach (li; 0 .. ls.length) {
        auto m = modelLayer(cast(int) li);
        if (m["vertexCount"].integer == vc && approxEqual(vat(m, 0)[2], z))
            return true;
    }
    return false;
}

// The /api/layers index of the FIRST layer that is a `vc`-vert mesh with
// vertex 0 at z≈`z` (the per-layer `visible` flag lives on /api/layers, not on
// /api/model, so callers that need visibility resolve the index this way).
// Returns -1 if none match.
int layerIndexByGeom(long vc, double z) {
    auto ls = layers()["layers"].array;
    foreach (li; 0 .. ls.length) {
        auto m = modelLayer(cast(int) li);
        if (m["vertexCount"].integer == vc && approxEqual(vat(m, 0)[2], z))
            return cast(int) li;
    }
    return -1;
}

// The `visible` flag from /api/layers for the layer at `idx`.
bool layerVisible(int idx) {
    return layers()["layers"].array[idx]["visible"].boolean;
}

// ---------------------------------------------------------------------------
// Case 1 + 2: OBJ / glTF 2-layer round-trip → 2 parts, geometry preserved.
// ---------------------------------------------------------------------------

void roundTripTwoParts(string ext) {
    resetApp();
    writeFixture();
    loadOk(FIXTURE);
    assert(layers()["layers"].array.length == 2, "source doc must have 2 layers");

    const outPath = "/tmp/vibe3d_test_mlexport_rt" ~ ext;
    if (exists(outPath)) remove(outPath);
    saveOk(outPath);
    assert(exists(outPath), ext ~ " export should write a file");

    resetApp();
    loadOk(outPath);
    auto ls = layers()["layers"].array;
    assert(ls.length == 2,
        format("%s 2-layer export must re-import as 2 parts, got %d",
               ext, ls.length));
    assert(sawLayer(4, 0.0), ext ~ ": expected a 4-vert quad layer at z=0");
    assert(sawLayer(3, 5.0), ext ~ ": expected a 3-vert tri layer at z=+5");
    remove(outPath);
}

unittest { roundTripTwoParts(".obj"); }
unittest { roundTripTwoParts(".gltf"); }

// ---------------------------------------------------------------------------
// Case 3: per-layer xform survives as post-bake WORLD geometry.
// Set the tri layer (z=+5) pos.z=+10 → re-import at z = 5 + 10 = 15.
// ---------------------------------------------------------------------------

void xformRoundTrip(string ext) {
    resetApp();
    writeFixture();
    loadOk(FIXTURE);

    // Identify which layer is the triangle (3 verts, z=5) before transforming.
    auto ls = layers()["layers"].array;
    int triIdx = -1;
    foreach (li; 0 .. ls.length) {
        auto m = modelLayer(cast(int) li);
        if (m["vertexCount"].integer == 3 && approxEqual(vat(m, 0)[2], 5.0))
            triIdx = cast(int) li;
    }
    assert(triIdx >= 0, "could not find the tri layer in the source doc");

    // Non-identity item transform: translate the tri layer +10 in Z (render-only,
    // never baked into mesh verts — Stage 4 export is the first time it bakes).
    cmdOk(format("layer.attr %d pos.z 10", triIdx));

    const outPath = "/tmp/vibe3d_test_mlexport_xf" ~ ext;
    if (exists(outPath)) remove(outPath);
    saveOk(outPath);
    assert(exists(outPath), ext ~ " xform export should write a file");

    resetApp();
    loadOk(outPath);
    // The transformed layer must come back at z = 5 + 10 = 15 (post-bake world).
    assert(sawLayer(3, 15.0),
        ext ~ ": transformed tri layer must re-import at world z=15 "
        ~ "(original 5 + pos.z 10, baked on import)");
    // The untouched quad layer stays at z=0.
    assert(sawLayer(4, 0.0), ext ~ ": untouched quad layer must stay at z=0");
    remove(outPath);
}

unittest { xformRoundTrip(".obj"); }
unittest { xformRoundTrip(".gltf"); }

// ---------------------------------------------------------------------------
// Case 4 (UPGRADED — Stage 5 import lands): glTF hidden-layer FULL round-trip.
// A hidden, geometry-carrying layer exported to .gltf rides the `ml_visible`
// node `extras`; now that the assimp import reads node metadata, re-loading the
// file must bring that layer back PRESENT and `visible == false`. We keep the
// raw-text grep as a cheap witness that the metadata reached the file, but the
// load-side `visible == false` assertion is the real proof.
// NOTE: OBJ has NO visibility metadata (documented loss) — hidden round-trips
// are asserted only through glTF (here) and LWO (below), never OBJ.
// ---------------------------------------------------------------------------

unittest {
    resetApp();
    writeFixture();
    loadOk(FIXTURE);

    // Hide the tri layer (3 verts at z=+5). It MUST carry geometry: an empty
    // hidden layer is dropped on re-import, so the round-trip would assert on a
    // vanished layer. The tri layer is non-primary, so hiding it leaves the quad
    // primary/visible (the primary-must-be-visible invariant holds).
    int triIdx = layerIndexByGeom(3, 5.0);
    assert(triIdx >= 0, "could not find the tri layer to hide");
    cmdOk(format("layer.setVisible index:%d value:false", triIdx));

    const outPath = "/tmp/vibe3d_test_mlexport_hidden.gltf";
    if (exists(outPath)) remove(outPath);
    saveOk(outPath);
    assert(exists(outPath), "glTF hidden export should write a file");

    // Cheap witness: the BOOL node metadata reached the file's node `extras`.
    const text = readText(outPath);
    assert(text.canFind("ml_visible"),
        "hidden layer must write ml_visible into the .gltf node extras");

    // The real assertion: re-import and confirm the tri layer is back, present
    // AND visible==false (Stage 5 reads the node metadata into ImportedPart).
    // Assert on `visible`, NOT `background`: a hidden layer is neither
    // foreground nor background (background == visible && !selected).
    resetApp();
    loadOk(outPath);
    assert(layers()["layers"].array.length == 2,
        "glTF hidden export must re-import both layers (hidden one is present)");
    int triBack = layerIndexByGeom(3, 5.0);
    assert(triBack >= 0,
        "the hidden tri layer must come back PRESENT after glTF round-trip");
    assert(!layerVisible(triBack),
        "the hidden tri layer must re-import with visible==false (glTF)");
    // The other (quad) layer stays visible.
    int quadBack = layerIndexByGeom(4, 0.0);
    assert(quadBack >= 0 && layerVisible(quadBack),
        "the un-hidden quad layer must re-import visible==true (glTF)");
    remove(outPath);
}

// ===========================================================================
// LWO cases (Stage 3) — LWO export no longer flattens: one LAYR per layer,
// xform BAKED into PNTS, hidden carried in the LAYR `flags` bit. Re-import
// keeps LAYER-LOCAL indices (unlike assimp, which may re-order verts), so the
// LWO cases assert layer-local face indexing on top of the geometry checks.
// ===========================================================================

// ---------------------------------------------------------------------------
// LWO Case 1: 2-layer round-trip. Mirrors the assimp Case 1/2 (2 parts, quad
// at z=0 + tri at z=+5) but additionally asserts each layer's face indices are
// LAYER-LOCAL (quad [0,1,2,3], tri [0,1,2]) — the LWO writer/reader contract
// the import test (test_lwo_multilayer.d) pins for the import direction; here
// we prove the export→import round-trip preserves it too.
// ---------------------------------------------------------------------------

unittest {
    resetApp();
    writeFixture();
    loadOk(FIXTURE);
    assert(layers()["layers"].array.length == 2, "source doc must have 2 layers");

    const outPath = "/tmp/vibe3d_test_mlexport_rt.lwo";
    if (exists(outPath)) remove(outPath);
    saveOk(outPath);
    assert(exists(outPath), "LWO export should write a file");

    resetApp();
    loadOk(outPath);
    auto ls = layers()["layers"].array;
    assert(ls.length == 2,
        format("LWO 2-layer export must re-import as 2 layers, got %d", ls.length));

    // The quad layer: 4 verts at z=0, ONE quad face with LAYER-LOCAL indices.
    int qIdx = layerIndexByGeom(4, 0.0);
    assert(qIdx >= 0, "LWO: expected a 4-vert quad layer at z=0");
    auto qm = modelLayer(qIdx);
    auto qf = qm["faces"].array;
    assert(qf.length == 1 && qf[0].array.length == 4, "LWO quad layer = one quad");
    foreach (k, idx; qf[0].array)
        assert(idx.integer == k,
            "LWO quad face indices must round-trip LAYER-LOCAL [0,1,2,3]");
    foreach (idx; qf[0].array)
        assert(approxEqual(vat(qm, idx.integer)[2], 0.0),
            "LWO quad verts stay at z=0 after round-trip");

    // The tri layer: 3 verts at z=+5, ONE tri face, LAYER-LOCAL indices, and
    // each vertex matches its original LWO coordinate (not re-offset).
    int tIdx = layerIndexByGeom(3, 5.0);
    assert(tIdx >= 0, "LWO: expected a 3-vert tri layer at z=+5");
    auto tm = modelLayer(tIdx);
    auto tf = tm["faces"].array;
    assert(tf.length == 1 && tf[0].array.length == 3, "LWO tri layer = one tri");
    foreach (k, idx; tf[0].array) {
        assert(idx.integer == k,
            "LWO tri face indices must round-trip LAYER-LOCAL [0,1,2]");
        auto p = vat(tm, idx.integer);
        assert(approxEqual(p[0], triVerts[k * 3 + 0])
            && approxEqual(p[1], triVerts[k * 3 + 1])
            && approxEqual(p[2], triVerts[k * 3 + 2]),
            format("LWO tri vert %d round-tripped to %s", k, p.to!string));
    }
    remove(outPath);
}

// ---------------------------------------------------------------------------
// LWO Case 2: per-layer xform BAKE. LWO has no node transform — the layer's
// composedMatrix() is baked into the written PNTS. Set the tri layer pos.z=+10,
// export .lwo, re-import, and assert the tri verts came back at their ORIGINAL
// local coords + (0,0,10). Expected positions are hand-computed (not via
// composedMatrix) to avoid a tautology.
// ---------------------------------------------------------------------------

// Hand-computed expected tri positions after a pure +Z translation of 10.
// (Independent of composedMatrix — a translation just adds to every vertex.)
static immutable float[3 * 3] triVertsBaked = [
    0.0f, 0.0f, 15.0f,  2.0f, 0.0f, 15.0f,  1.0f, 3.0f, 15.0f,
];

unittest {
    resetApp();
    writeFixture();
    loadOk(FIXTURE);

    int triIdx = layerIndexByGeom(3, 5.0);
    assert(triIdx >= 0, "could not find the tri layer to transform");

    // Non-identity item transform: +10 in Z (render-only; the LWO export is the
    // first place it bakes into coordinates).
    cmdOk(format("layer.attr %d pos.z 10", triIdx));

    const outPath = "/tmp/vibe3d_test_mlexport_xf.lwo";
    if (exists(outPath)) remove(outPath);
    saveOk(outPath);
    assert(exists(outPath), "LWO xform export should write a file");

    resetApp();
    loadOk(outPath);
    assert(layers()["layers"].array.length == 2,
        "LWO xform export must re-import both layers");

    // The tri layer comes back at z=+15 (5 + 10), each vert at the hand-computed
    // baked coordinate (NOT recomputed from composedMatrix).
    int tBack = layerIndexByGeom(3, 15.0);
    assert(tBack >= 0,
        "transformed tri layer must re-import at world z=15 (baked, LWO)");
    auto tm = modelLayer(tBack);
    auto tf = tm["faces"].array;
    assert(tf.length == 1 && tf[0].array.length == 3, "baked tri layer = one tri");
    foreach (k, idx; tf[0].array) {
        auto p = vat(tm, idx.integer);
        assert(approxEqual(p[0], triVertsBaked[k * 3 + 0])
            && approxEqual(p[1], triVertsBaked[k * 3 + 1])
            && approxEqual(p[2], triVertsBaked[k * 3 + 2]),
            format("LWO baked tri vert %d = %s, expected %s", k, p.to!string,
                   [triVertsBaked[k*3], triVertsBaked[k*3+1],
                    triVertsBaked[k*3+2]].to!string));
    }
    // The untouched quad layer stays at its original z=0.
    assert(sawLayer(4, 0.0), "LWO: untouched quad layer must stay at z=0");
    remove(outPath);
}

// ---------------------------------------------------------------------------
// LWO Case 3: hidden-layer FULL round-trip (now that the importer reads the
// LAYR `flags` hidden bit — Stage 5). Hide the tri layer (it carries geometry,
// so it survives import — empty parts are dropped), export .lwo, re-import, and
// assert the layer comes back PRESENT and `visible == false`. Assert on
// `visible`, NOT `background` (a hidden layer is neither fg nor bg).
// ---------------------------------------------------------------------------

unittest {
    resetApp();
    writeFixture();
    loadOk(FIXTURE);

    // Hide the tri layer (3 verts at z=+5, non-primary → quad stays primary).
    int triIdx = layerIndexByGeom(3, 5.0);
    assert(triIdx >= 0, "could not find the tri layer to hide");
    cmdOk(format("layer.setVisible index:%d value:false", triIdx));

    const outPath = "/tmp/vibe3d_test_mlexport_hidden.lwo";
    if (exists(outPath)) remove(outPath);
    saveOk(outPath);
    assert(exists(outPath), "LWO hidden export should write a file");

    resetApp();
    loadOk(outPath);
    assert(layers()["layers"].array.length == 2,
        "LWO hidden export must re-import both layers (hidden one is present)");
    int triBack = layerIndexByGeom(3, 5.0);
    assert(triBack >= 0,
        "the hidden tri layer must come back PRESENT after LWO round-trip");
    assert(!layerVisible(triBack),
        "the hidden tri layer must re-import with visible==false (LWO LAYR flag)");
    // The other (quad) layer stays visible.
    int quadBack = layerIndexByGeom(4, 0.0);
    assert(quadBack >= 0 && layerVisible(quadBack),
        "the un-hidden quad layer must re-import visible==true (LWO)");
    remove(outPath);
}
