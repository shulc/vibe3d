// Task 0612 Stage 1 — `GET /api/images`, the observability half of the pixel
// cache.
//
// The cache's BEHAVIOUR is proved in-module (`source/image_cache.d`'s
// unittests, over literal string arrays with no document at all). What only
// this file can prove is the half that lives outside that module:
//
//   * the endpoint is routed, the provider is installed, and the response is
//     gathered on the main thread rather than 500-ing or timing out;
//   * a row is emitted for image items ONLY, and its `index` is the LAYER
//     index — the number every other endpoint and every command argument
//     uses — not the row's ordinal within this array;
//   * two clips on ONE file are TWO rows (the document's model: every item
//     owns its own payload; sharing happens one level down, in the cache);
//   * nothing has been decoded. Stage 1 ships the cache with no caller, and
//     the design is explicitly lazy: a document full of clips that nothing
//     links to decodes NOTHING. An implementation that decoded at load time
//     — the obvious alternative — reads three here.
//
// Fixture rules earned on this chain and followed here: three clips, the
// assertions aimed at the MIDDLE one, and two of them sharing one file path
// so a path-identity bug lands on the WRONG row rather than on nothing. The
// two files have different dimensions so a row that reads its neighbour's
// metadata is visible.

import std.net.curl;
import std.json;
import std.conv : to;
import std.file : write, mkdirRecurse;
import std.path : buildPath;

void main() {}

immutable baseUrl = "http://localhost:8080";

JSONValue getJson(string path) { return parseJSON(cast(string)get(baseUrl ~ path)); }

JSONValue cmd(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

void resetCube() {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(j["status"].str == "ok", "/api/reset failed: " ~ j.toString);
    cmd(`{"id":"history.clear"}`);
}

immutable scratch = "/tmp/vibe3d_imgcache_api";

/// A minimal uncompressed 24-bit BMP (same shape as tests/test_image_commands.d).
string bmpAt(string name, int w, int h) {
    mkdirRecurse(scratch);
    auto path = buildPath(scratch, name);
    ubyte[] b;
    void u16(ushort v) { b ~= cast(ubyte)(v & 0xFF); b ~= cast(ubyte)((v >> 8) & 0xFF); }
    void u32(uint v) {
        b ~= cast(ubyte)(v & 0xFF);         b ~= cast(ubyte)((v >> 8)  & 0xFF);
        b ~= cast(ubyte)((v >> 16) & 0xFF); b ~= cast(ubyte)((v >> 24) & 0xFF);
    }
    immutable size_t rowBytes = cast(size_t)((w * 3 + 3) & ~3);
    immutable size_t pixBytes = rowBytes * h;
    b ~= cast(ubyte)'B'; b ~= cast(ubyte)'M';
    u32(cast(uint)(54 + pixBytes));
    u16(0); u16(0); u32(54); u32(40);
    u32(cast(uint) w); u32(cast(uint) h);
    u16(1); u16(24); u32(0); u32(cast(uint) pixBytes);
    u32(2835); u32(2835); u32(0); u32(0);
    foreach (y; 0 .. h) {
        foreach (x; 0 .. w) {
            b ~= cast(ubyte)(x * 7 + 3); b ~= cast(ubyte)(y * 11 + 5); b ~= cast(ubyte)(x * 3 + y);
        }
        foreach (_; 0 .. rowBytes - cast(size_t)(w * 3)) b ~= cast(ubyte) 0;
    }
    write(path, b);
    return path;
}

string jsonStr(string s) { return JSONValue(s).toString(); }

void loadImage(string path) {
    cmd(`{"id":"image.load","path":` ~ jsonStr(path) ~ `}`);
}

// ---------------------------------------------------------------------------
// The rows: image items only, keyed by LAYER index, one row per item even
// when two items name one file.
// ---------------------------------------------------------------------------
unittest {
    resetCube();
    // The reset leaves exactly one mesh layer; the three clips land after it,
    // so a "row ordinal" implementation and a "layer index" one disagree on
    // every row.
    immutable shared_ = bmpAt("shared.bmp", 3, 2);
    immutable middle  = bmpAt("middle.bmp", 5, 7);
    loadImage(shared_);   // layer 1
    loadImage(middle);    // layer 2  <- the one under test
    loadImage(shared_);   // layer 3, the decoy on the SAME file

    auto layers = getJson("/api/layers")["layers"].array;
    assert(layers.length == 4, "one mesh + three clips: " ~ layers.length.to!string);

    auto j = getJson("/api/images");
    assert("images" in j, "/api/images must return an images array: " ~ j.toString);
    auto rows = j["images"].array;

    assert(rows.length == 3,
        "three image ITEMS are three rows — two of them share a file, and "
        ~ "collapsing them by path reads 2: " ~ rows.length.to!string);

    assert(rows[0]["index"].integer == 1,
        "the first clip is LAYER 1 (the mesh is layer 0) — a row-ordinal "
        ~ "index reads 0");
    assert(rows[1]["index"].integer == 2, "the middle clip is layer 2");
    assert(rows[2]["index"].integer == 3, "the decoy is layer 3");

    // The middle row's own metadata, not its neighbour's. The two files
    // differ in BOTH dimensions, so a transpose and an off-by-one row read
    // give different wrong answers.
    assert(rows[1]["width"].integer  == 5, "middle row width");
    assert(rows[1]["height"].integer == 7, "middle row height");
    assert(rows[1]["storedPath"].str == middle, "middle row path");
    assert(rows[1]["missing"].type == JSONType.false_, "the file is there");

    // The decoy proves the neighbours are the SHARED file, so "the middle row
    // resolved to the only other one" is not what the assertion above saw.
    assert(rows[0]["storedPath"].str == shared_ && rows[2]["storedPath"].str == shared_,
        "rows 0 and 2 name one file");
    assert(rows[0]["width"].integer == 3 && rows[2]["width"].integer == 3,
        "and both report ITS width, not the middle one's");
}

// ---------------------------------------------------------------------------
// Nothing decodes. Three clips exist, none is linked by a consumer, and the
// cache is empty — the plan's laziness claim, and the assertion that goes red
// the day something starts decoding at load time.
// ---------------------------------------------------------------------------
// FIXED (task 0612 Stage 9): the decode half of this case was an ABSOLUTE
// assertion (`decodes == 0`) against a counter the cache deliberately does NOT
// reset — `decodes_` "counts what this PROCESS has decoded" and survives
// `/api/reset` on purpose, so that "N frames of orbit produce one decode" can
// be asserted across a reset at all. `run_test.d` runs many tests against ONE
// app process, so the absolute form was really claiming "no test scheduled
// before this one on this worker ever decoded anything" — which stopped being
// true the moment Stage 5 landed a test that draws a bound plane.
//
// It was latent, not new: `./run_test.d --no-build -j 1 test_image_plane_draw
// test_image_cache_api` reproduces it against the Stage-5 commit with nothing
// from Stage 8 or 9 involved. The green `-j 8` runs in between were the
// shuffle keeping the two apart, not a proof. Adding a third decoding test
// made the collision likely enough to surface.
//
// The DELTA is the claim this case was always making — "loading clips that
// nothing links to decodes nothing" — and it is order-independent. The
// residency halves stay absolute, correctly: `reconcile` against a document
// with no plane frees everything, so those really are zero whatever ran first.
unittest {
    resetCube();
    immutable long decodesBefore = getJson("/api/images")["cache"]["decodes"].integer;

    loadImage(bmpAt("a.bmp", 3, 2));
    loadImage(bmpAt("b.bmp", 5, 7));
    loadImage(bmpAt("c.bmp", 11, 4));

    auto c = getJson("/api/images")["cache"];
    assert(c["residentEntries"].integer == 0,
        "three clips, no consumer: nothing is resident — a decode-at-load "
        ~ "implementation reads 3");
    assert(c["residentBytes"].integer == 0, "and no bytes are held");
    assert(c["decodes"].integer == decodesBefore,
        "and loading three clips called the decoder ZERO more times — a "
        ~ "decode-at-load implementation adds 3. before=" ~ decodesBefore.to!string
        ~ " after=" ~ c["decodes"].integer.to!string);
}
