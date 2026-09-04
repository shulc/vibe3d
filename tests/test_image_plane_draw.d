// Task 0612 Stage 5 — the draw pass reaches the framebuffer, and residency
// follows the DOCUMENT rather than the draw.
//
// WHAT THIS FILE ASSERTS THAT NO OTHER ONE CAN.
//
// `image_plane.d`'s unittests pin the placement law as numbers and
// `test_image_plane_view.d` pins which cell resolves which plane — neither
// touches GL. What is left over is the half that only a real frame can answer:
// that the pass is wired into the render at all, that the texture is bound and
// sampled, and that the quad's texture coordinates are not transposed or
// mirrored. That is asserted here BY VALUE — three probed pixels whose colours
// are three different bands of a hand-built image — never by looking at a
// screenshot. A picture proves nothing (two errors that cancel produce the
// identical image) and localises nothing.
//
// THE BANDED FIXTURE IS THE INSTRUMENT. A flat-colour image would prove the
// pass runs and nothing else: a transposed quad, a mirrored U, or a flipped V
// all draw the identical flat rectangle. This image is
//
//     x < w/4                 -> YELLOW   (the left band)
//     else, y < h/4 from top  -> CYAN     (the top band)
//     else                    -> MAGENTA  (the field)
//
// so "yellow is on the left" and "cyan is on top" are two independent
// assertions about orientation, and a transpose swaps which one a given probe
// reads.
//
// HOW A KNOWN BAND IS PUT UNDER A KNOWN PIXEL. The probe point is fixed; the
// PLANE is moved. The plane carries `pos` rigidly (measured), so translating
// it by a known number of metres slides a chosen band under the probe without
// touching the camera, the projection, or any of the numbers this test would
// otherwise have to derive from the view matrix.

import http_client : testBaseUrl, getJson;
import http_command_helpers : commandBody;
import std.net.curl;
import std.json;
import std.conv   : to;
import std.file   : write, mkdirRecurse;
import std.path   : buildPath;
import std.format : format;
import core.thread : Thread;
import core.time   : msecs;

void main() {}

alias baseUrl = testBaseUrl;


JSONValue cmd(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

/// The probe reads the last COMPLETED frame, and the HTTP bridge is serviced
/// before the render, so a change needs one full frame to become visible.
void settle() { Thread.sleep(400.msecs); }

immutable scratch = "/tmp/vibe3d_planedraw";

/// A 24-bit BMP with a yellow LEFT band, a cyan TOP band and a magenta field.
///
/// BMP rows are stored BOTTOM-UP, so the row written first is the image's
/// BOTTOM row — the top band is therefore the LAST quarter written. Getting
/// this backwards would put cyan at the bottom and make the V-orientation
/// assertion below assert the opposite of what it says.
string bandedBmp(string name, int w, int h) {
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
    foreach (r; 0 .. h) {
        immutable int yTop = h - 1 - r;          // BMP rows run bottom-up
        foreach (x; 0 .. w) {
            ubyte rr, gg, bb;
            if (x < w / 4)            { rr = 255; gg = 255; bb = 0;   }  // yellow
            else if (yTop < h / 4)    { rr = 0;   gg = 255; bb = 255; }  // cyan
            else                      { rr = 255; gg = 0;   bb = 255; }  // magenta
            b ~= bb; b ~= gg; b ~= rr;           // BMP stores BGR
        }
        foreach (_; 0 .. rowBytes - cast(size_t)(w * 3)) b ~= cast(ubyte) 0;
    }
    write(path, b);
    return path;
}

string jsonStr(string s) { return JSONValue(s).toString(); }

struct Px { int r, g, b, a; }

/// One probed FBO pixel of the ACTIVE cell (top-left origin). `renders` is
/// asserted: under --test only the active cell is rendered, and a probe at a
/// never-filled FBO reads zeros that any assertion would pass or fail for the
/// wrong reason.
Px probeAt(int x, int y) {
    auto j = getJson(format("/api/viewport/probe?cell=0&x=%d&y=%d", x, y));
    assert("error" !in j, "probe failed: " ~ j.toString);
    assert(j["renders"].type == JSONType.true_,
        "the probed cell is not rendered under --test; the reading is void");
    auto p = j["points"].array[0];
    return Px(cast(int) p["r"].integer, cast(int) p["g"].integer,
              cast(int) p["b"].integer, cast(int) p["a"].integer);
}

int[2] fboSize() {
    auto j = getJson("/api/viewport/probe?cell=0&x=0&y=0");
    return [cast(int) j["w"].integer, cast(int) j["h"].integer];
}

ulong decodes() { return cast(ulong) getJson("/api/images")["cache"]["decodes"].integer; }
ulong residentEntries() {
    return cast(ulong) getJson("/api/images")["cache"]["residentEntries"].integer;
}
ulong residentBytes() {
    return cast(ulong) getJson("/api/images")["cache"]["residentBytes"].integer;
}

// Layer layout built by `buildFixture`: [0] cube, [1] clip, [2] plane. The
// indices are written as literals in the commands below rather than hoisted
// into constants, because they are ARGUMENTS to those commands and a constant
// that drifted from the fixture would be silently wrong at every call site.

/// Reset, aim cell 0 at an ortho Front view, park the cube far away so it
/// cannot cover the probe, and stand a 16 x 8 m reference plane at the origin.
void buildFixture() {
    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("scene.reset")));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    cmd(`{"id":"history.clear"}`);
    // Ortho Front: the plane's own axis, and the view in which the ground grid
    // is edge-on (a single horizontal line through the middle) rather than a
    // lattice covering everything the probe might land on.
    cmd(`{"id":"viewport.view","params":"Front"}`);
    // The cube draws AFTER the plane and would simply cover the probe point.
    cmd("layer.attr 0 pos.x 40");

    auto file = bandedBmp("bands.bmp", 64, 32);
    cmd(`{"id":"image.load","path":` ~ jsonStr(file) ~ `}`);
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/test/layer",
        `{"kind":"imagePlane","name":"reference"}`));
    assert(r["status"].str == "ok", "plane injection failed: " ~ r.toString);
    cmd(`{"id":"imagePlane.setImage","index":2,"image":1}`);
    // 64 x 32 px at 0.25 m/px = 16 x 8 m, i.e. u in [-8,8], v in [-4,4].
    // Bands: yellow u in [-8,-4]; cyan v in [2,4]; magenta elsewhere.
    cmd("layer.attr 2 pixelSize 0.25");

    auto pl = getJson("/api/imageplane?index=2&cell=0");
    assert("error" !in pl, "placement: " ~ pl.toString);
    assert(pl["cellPreset"].str == "Front" && pl["cellOrtho"].boolean,
        "FIXTURE: cell 0 must be an ortho Front cell, got "
        ~ pl["cellPreset"].str);
    assert(pl["drawn"].boolean, "FIXTURE: the plane must be drawn: " ~ pl.toString);
    settle();
}

// ---------------------------------------------------------------------------
// The draw pass reaches the framebuffer, with the image the right way up.
//
// Wrong implementations, and what each reads at these three probes:
//   * the pass never wired in / the program never built  -> all three read the
//     FBO clear colour (92, 102, 107);
//   * the texture not bound (a flat quad)                -> all three read the
//     same colour as each other;
//   * U mirrored (a flip implemented in the corners)     -> the yellow probe
//     reads MAGENTA and a probe on the far side reads yellow;
//   * V flipped (the fan's v coordinates swapped)        -> the cyan probe
//     reads magenta, and cyan appears at the BOTTOM;
//   * the quad transposed                                -> the cyan probe
//     reads yellow.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();
    immutable sz = fboSize();
    // Off-centre in BOTH axes: the ground grid is a horizontal line through
    // the middle row and the Y axis line is a vertical line through the middle
    // column, and both draw OVER the plane.
    immutable int px = sz[0] / 2 + 30;
    immutable int py = sz[1] / 2 - 30;

    string describe(Px p) { return format("(%d, %d, %d, a=%d)", p.r, p.g, p.b, p.a); }
    bool isMagenta(Px p) { return p.r > 200 && p.g <  60 && p.b > 200; }
    bool isYellow (Px p) { return p.r > 200 && p.g > 200 && p.b <  60; }
    bool isCyan   (Px p) { return p.r <  60 && p.g > 200 && p.b > 200; }

    // 1. The field. This is also the assertion that the pass runs at all.
    auto field = probeAt(px, py);
    assert(isMagenta(field),
        format("the plane's magenta field must reach the framebuffer at (%d,%d) — "
               ~ "got %s. The FBO clear colour is about (92,102,107); reading THAT "
               ~ "means the pass never ran.", px, py, describe(field)));

    // 2. Slide the plane +6 m in X: the probe point now sits over the plane's
    //    LEFT band (local u = -6 + a fraction of a metre, inside [-8,-4]).
    cmd("layer.attr 2 pos.x 6.0");
    settle();
    auto left = probeAt(px, py);
    assert(isYellow(left),
        format("the plane's LEFT band must be yellow at (%d,%d) after sliding the "
               ~ "plane +6 m in X — got %s. Magenta here means U is mirrored; "
               ~ "cyan means the quad is transposed.", px, py, describe(left)));
    cmd("layer.attr 2 pos.x 0.0");

    // 3. Slide it -3 m in Y: the probe point now sits over the TOP band
    //    (local v = +3 and a fraction, inside [2,4]).
    cmd("layer.attr 2 pos.y -3.0");
    settle();
    auto top = probeAt(px, py);
    assert(isCyan(top),
        format("the plane's TOP band must be cyan at (%d,%d) after sliding the "
               ~ "plane -3 m in Y — got %s. Magenta here means V is flipped "
               ~ "(cyan would be at the bottom); yellow means transposed.",
               px, py, describe(top)));
    cmd("layer.attr 2 pos.y 0.0");

    // 4. …and the three readings are three DIFFERENT colours, which is the
    //    assertion a flat-texture bug fails while all three above could pass
    //    on a fixture whose bands happened to agree.
    assert(!(isMagenta(left) || isMagenta(top)) && !isYellow(top),
        format("the three probes must read three different bands — got %s / %s / %s",
               describe(field), describe(left), describe(top)));

    // 5. Hiding the plane returns the pixel to the clear colour. This is the
    //    control: without it, a probe reading "not the clear colour" could be
    //    anything else the frame happens to draw there.
    cmd(`{"id":"layer.setVisible","index":2,"value":false}`);
    settle();
    auto gone = probeAt(px, py);
    assert(gone.r > 80 && gone.r < 105 && gone.g > 90 && gone.g < 115
        && gone.b > 95 && gone.b < 120,
        format("hiding the plane must return (%d,%d) to the FBO clear colour "
               ~ "(about 92,102,107) — got %s", px, py, describe(gone)));
    cmd(`{"id":"layer.setVisible","index":2,"value":true}`);
}

// ---------------------------------------------------------------------------
// T-C7 — THE ORBIT REGRESSION. N frames of camera motion with a resident
// plane must produce exactly ONE decode.
//
// This is the assertion the retracted frame-scoped cache design would have
// failed: residency driven by a `require` from the dirty-gated draw plus an
// unconditional end-of-frame sweep frees the texture on any frame the cell is
// clean, and re-decodes it from disk the moment the camera moves again — an
// image decode per frame for the whole of an orbit, while the residency count
// stays a perfectly healthy 1. Reads: a decode count of about N.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();
    immutable before = decodes();
    assert(residentEntries() == 1,
        format("T-C7 precondition: one live link, one resident entry — got %d",
               residentEntries()));

    enum int kFrames = 12;
    foreach (i; 0 .. kFrames) {
        // Move the camera the way a user's orbit does — a real render input
        // change, so cells go dirty and clean and dirty again.
        post(baseUrl ~ "/api/camera?viewport=0",
             format(`{"distance":%f}`, 6.0 + 0.25 * i));
        Thread.sleep(40.msecs);
    }
    settle();
    immutable after = decodes();
    assert(after == before,
        format("T-C7: %d frames of camera motion must cost NO further decode — "
               ~ "the count went %d -> %d. A count near %d means residency is "
               ~ "driven by the DRAW rather than by the document's live links.",
               kFrames, before, after, kFrames));
    assert(residentEntries() == 1,
        format("T-C7: …and the entry is still resident — got %d",
               residentEntries()));
}

// ---------------------------------------------------------------------------
// T-C5 — residency follows the DOCUMENT, through every path that replaces it.
//
// Fixture: TWO planes on TWO clips on TWO DIFFERENT FILES of DIFFERENT SIZES.
// Both halves matter. With one image, an implementation keyed on something the
// replacement does not change reads `1` after a load that should leave `1`,
// i.e. it PASSES. With two images of the same size, `residentEntries` alone
// cannot tell which survivor is left — the count is right and the wrong
// texture is held. The byte totals are what name the survivor.
//
// Three arms, not the four the plan lists: `scene.reset`, a `.v3d` load that
// names one plane, and a `layer.delete`. An interchange import is the same
// shape as the `.v3d` load from this cache's point of view — it replaces the
// document with one that names no image at all — and would assert nothing the
// reset arm does not.
// ---------------------------------------------------------------------------
unittest {
    // 8x8 and 16x16 -> 256 and 1024 resident bytes: different, and the
    // difference is what identifies the survivor.
    auto small = bandedBmp("small.bmp", 8, 8);
    auto big   = bandedBmp("big.bmp",  16, 16);
    immutable ulong smallBytes = 8 * 8 * 4;
    immutable ulong bigBytes   = 16 * 16 * 4;

    void twoPlanes() {
        auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("scene.reset")));
        assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
        cmd(`{"id":"history.clear"}`);
        cmd(`{"id":"image.load","path":` ~ jsonStr(small) ~ `}`);   // 1
        cmd(`{"id":"image.load","path":` ~ jsonStr(big)   ~ `}`);   // 2
        foreach (n; ["small plane", "big plane"]) {
            auto r = parseJSON(cast(string)post(baseUrl ~ "/api/test/layer",
                `{"kind":"imagePlane","name":` ~ jsonStr(n) ~ `}`));
            assert(r["status"].str == "ok", "plane injection failed: " ~ r.toString);
        }
        cmd(`{"id":"imagePlane.setImage","index":3,"image":1}`);    // small
        cmd(`{"id":"imagePlane.setImage","index":4,"image":2}`);    // big
        assert(residentEntries() == 2,
            format("T-C5 precondition: two files, two entries — got %d",
                   residentEntries()));
        assert(residentBytes() == smallBytes + bigBytes,
            format("T-C5 precondition: %d resident bytes, got %d",
                   smallBytes + bigBytes, residentBytes()));
    }

    // Arm 1 — the document is thrown away entirely.
    twoPlanes();
    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/command", commandBody("scene.reset")));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    assert(residentEntries() == 0 && residentBytes() == 0,
        format("T-C5 (reset): a document with no planes holds nothing — got "
               ~ "%d entries / %d bytes", residentEntries(), residentBytes()));

    // Arm 2 — one plane is deleted. The SURVIVOR is named by its byte count,
    // which is the assertion an entries-only check cannot make.
    twoPlanes();
    cmd(`{"id":"layer.delete","index":4}`);          // the BIG one goes
    assert(residentEntries() == 1,
        format("T-C5 (delete): one plane left, one entry — got %d",
               residentEntries()));
    assert(residentBytes() == smallBytes,
        format("T-C5 (delete): the SMALL image must be the survivor (%d bytes) — "
               ~ "got %d. The right count with the wrong survivor is exactly "
               ~ "what a count-only assertion cannot see.",
               smallBytes, residentBytes()));

    // Arm 3 — the document is REPLACED by one loaded from disk. `file.load`
    // rebuilds the layer array wholesale, so an implementation keyed on
    // anything the load does not touch survives it.
    //
    // The saved document is built here rather than inherited from arm 2, so
    // this arm does not silently depend on what the arm above happened to
    // leave behind. It holds BOTH image clips and only ONE plane — which
    // makes it the arm that also pins residency to the LINKS rather than to
    // the image rows: the big clip is present in the loaded document and must
    // NOT be resident, because nothing points at it.
    immutable savePath = buildPath(scratch, "one_plane.v3d");
    twoPlanes();
    cmd(`{"id":"layer.delete","index":4}`);          // drop the BIG plane
    cmd(`{"id":"file.save","path":` ~ jsonStr(savePath) ~ `}`);
    twoPlanes();                                     // back to two, then load
    cmd(`{"id":"file.load","path":` ~ jsonStr(savePath) ~ `}`);
    assert(residentEntries() == 1,
        format("T-C5 (file.load): the loaded document holds two image clips and "
               ~ "ONE plane, so exactly one file is live — got %d entries. Two "
               ~ "means residency followed the image ROWS instead of the links.",
               residentEntries()));
    assert(residentBytes() == smallBytes,
        format("T-C5 (file.load): and the live one is the small image (%d bytes) "
               ~ "— got %d", smallBytes, residentBytes()));
}
