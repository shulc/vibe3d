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
// Case 4: hidden flag → ml_visible metadata is written into the .gltf file
// text. The IMPORT-side read is Stage 5; here we grep the raw file only.
// ---------------------------------------------------------------------------

unittest {
    resetApp();
    writeFixture();
    loadOk(FIXTURE);

    // Hide the tri layer (index 1 in the imported doc — order is import-defined,
    // but the LWO importer keeps LAYR order so tri = index 1).
    auto ls = layers()["layers"].array;
    int triIdx = -1;
    foreach (li; 0 .. ls.length) {
        auto m = modelLayer(cast(int) li);
        if (m["vertexCount"].integer == 3) triIdx = cast(int) li;
    }
    assert(triIdx >= 0, "could not find the tri layer to hide");
    // Hiding goes through layer.setVisible (owns the hide-primary promotion);
    // the tri layer is non-primary so hiding it leaves the quad primary/visible.
    cmdOk(format("layer.setVisible index:%d value:false", triIdx));

    const outPath = "/tmp/vibe3d_test_mlexport_hidden.gltf";
    if (exists(outPath)) remove(outPath);
    saveOk(outPath);
    assert(exists(outPath), "glTF hidden export should write a file");

    // The glTF exporter writes node BOOL metadata into the node's `extras`.
    const text = readText(outPath);
    assert(text.canFind("ml_visible"),
        "hidden layer must write ml_visible into the .gltf node extras "
        ~ "(import-side read is Stage 5)");
    remove(outPath);
}
