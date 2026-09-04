// Task 0612 Stage 4/5 — WHICH CELL DRAWS WHICH PLANE, and where the plane's
// size comes from, through `GET /api/imageplane?index=N&cell=K`.
//
// WHY THE ENDPOINT IS KEYED ON A CELL. An earlier draft of this endpoint took
// `&view=front` — the preset as an INPUT. You cannot detect which preset a
// cell resolves to through an endpoint you hand the preset to, so every
// viewport-match assertion below would have been unfailable. `cell=K` names a
// cell and the endpoint resolves `(viewPreset, projKind)` itself, which is
// what makes "the wrong cell drew it" an answer the response can give.
//
// The response ECHOES `cellPreset` / `cellOrtho`, and every test here asserts
// them before it asserts anything about the plane. A viewport-match assertion
// against a cell that is not configured the way the test believes is inert,
// and this is how it finds out.
//
// `/api/imageplane` resolves placement for any LIVE cell without that cell
// having rendered — deliberately, because `--test` renders only the active
// cell (`app.d`'s `needRender = (k == vpm.activeId)`). The Quad layout is
// still required, because it is what makes cells 1..3 live at all.
//
// FIXTURE. Three clips, two of which name ONE file, plus two planes:
//
//   0 cube    1 tall.bmp(20x48)   2 wide.bmp(64x32)   3 tall.bmp(20x48)
//   4 plane "front"  -> clip 2 (the MIDDLE clip, the wide one)
//   5 plane "right"  -> clip 3 (the tall one, whose path clip 1 also names)
//
// The two clips bound to planes have DIFFERENT dimensions, which is what makes
// "the extent was read off the wrong clip" produce a different number rather
// than the same one; and the decoy on a shared path is what makes a
// path-keyed lookup land on the WRONG clip instead of on nothing.

import http_client : testBaseUrl, getJson;
import std.net.curl;
import std.json;
import std.conv  : to;
import std.math  : abs;
import std.file  : write, mkdirRecurse;
import std.path  : buildPath;
import std.format : format;

void main() {}

alias baseUrl = testBaseUrl;


JSONValue cmd(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
    return j;
}

double num(JSONValue v) {
    if (v.type == JSONType.float_)   return v.floating;
    if (v.type == JSONType.integer)  return cast(double)v.integer;
    if (v.type == JSONType.uinteger) return cast(double)v.uinteger;
    assert(false, "expected a number, got " ~ v.toString);
}

double[] vec3(JSONValue a) {
    double[] r;
    foreach (e; a.array) r ~= num(e);
    return r;
}

double vlen(double[] v) {
    import std.math : sqrt;
    return sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
}

bool near(double a, double b, double tol = 1e-4) { return abs(a - b) <= tol; }

string vstr(double[] v) { return format("(%.6f, %.6f, %.6f)", v[0], v[1], v[2]); }

immutable scratch = "/tmp/vibe3d_planeview";

/// A minimal 24-bit BMP of the requested size. Written by hand rather than
/// copied, so the DIMENSIONS are what this test says they are — the whole
/// point of T-P6 is that two clips carry different ones.
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

enum int kFrontPlane = 4;
enum int kRightPlane = 5;

/// Cell ids under the Quad layout, as `viewport.d` seeds them.
enum int kCellA = 0;   // seeded Top; this test re-aims it, it is the only cell
                       //   `viewport.view` can reach (it targets the ACTIVE cell,
                       //   and --test keeps cell 0 active)
enum int kCellFront = 1;
enum int kCellLeft  = 2;
enum int kCellPersp = 3;

void buildFixture() {
    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"viewport.layout","params":"Quad"}`);

    auto tall = bmpAt("tall.bmp", 20, 48);
    auto wide = bmpAt("wide.bmp", 64, 32);
    cmd(`{"id":"image.load","path":` ~ jsonStr(tall) ~ `}`);   // 1 — decoy, shared path
    cmd(`{"id":"image.load","path":` ~ jsonStr(wide) ~ `}`);   // 2 — the middle clip
    cmd(`{"id":"image.load","path":` ~ jsonStr(tall) ~ `}`);   // 3 — same path as 1

    foreach (name; ["front sheet", "right sheet"]) {
        auto r = parseJSON(cast(string)post(baseUrl ~ "/api/test/layer",
            `{"kind":"imagePlane","name":` ~ jsonStr(name) ~ `}`));
        assert(r["status"].str == "ok", "plane injection failed: " ~ r.toString);
    }
    auto ls = getJson("/api/layers")["layers"].array;
    assert(ls.length == 6, "cube + three clips + two planes, got " ~ ls.length.to!string);
    assert(ls[kFrontPlane]["type"].str == "imagePlane"
        && ls[kRightPlane]["type"].str == "imagePlane", "both injected rows are planes");

    cmd(`{"id":"imagePlane.setImage","index":4,"image":2}`);
    cmd(`{"id":"imagePlane.setImage","index":5,"image":3}`);
    cmd("layer.attr 5 projection right");
}

/// The placement of plane `idx` in cell `cell`, with the cell's OWN preset
/// asserted first so a mis-set fixture cannot masquerade as a match result.
JSONValue placement(int idx, int cell, string expectPreset, bool expectOrtho) {
    auto j = getJson(format("/api/imageplane?index=%d&cell=%d", idx, cell));
    assert("error" !in j, format("/api/imageplane?index=%d&cell=%d: %s",
                                 idx, cell, j.toString));
    assert(j["cellPreset"].str == expectPreset,
        format("FIXTURE: cell %d should be on preset %s, is %s — every assertion "
               ~ "below it would have been about a different cell",
               cell, expectPreset, j["cellPreset"].str));
    assert(j["cellOrtho"].boolean == expectOrtho,
        format("FIXTURE: cell %d ortho should be %s, is %s",
               cell, expectOrtho, j["cellOrtho"].boolean));
    return j;
}

/// Point cell 0 at `preset`. `viewport.view` targets the ACTIVE cell, and
/// --test keeps cell 0 active, so cell 0 is the only re-aimable one.
void aimCellA(string preset) { cmd(`{"id":"viewport.view","params":"` ~ preset ~ `"}`); }

// ---------------------------------------------------------------------------
// T-P6 — the extent comes from THE CLIP THIS PLANE IS BOUND TO.
//
// This is the assertion `image_plane.d`'s own unittests structurally cannot
// make: `resolvePlacement` takes `clipW`/`clipH` as arguments, so "read off
// the wrong clip" is unrepresentable there. It only exists at the caller, and
// this is the caller.
//
// Wrong implementations and what they read: dimensions taken from the FIRST
// image row (both planes report 20x48); from the only-one fallback (same);
// from the plane's own payload (0x0, an empty extent); a path-keyed lookup
// (the right plane lands on clip 1, which shares clip 3's file — same numbers,
// which is exactly why the LINK identity is pinned separately in
// test_image_plane_link.d and why this test pins the DIMENSIONS instead).
// ---------------------------------------------------------------------------
unittest {
    buildFixture();

    auto f = placement(kFrontPlane, kCellFront, "Front", true);
    assert(f["clipWidth"].integer == 64 && f["clipHeight"].integer == 32,
        format("T-P6: the front plane is bound to the 64x32 clip, endpoint says %dx%d",
               f["clipWidth"].integer, f["clipHeight"].integer));
    auto fu = vec3(f["halfU"]), fv = vec3(f["halfV"]);
    // 64 px * 0.01 m/px = 0.64 m full, 0.32 m half; 32 px -> 0.32 / 0.16.
    assert(near(fu[0], 0.32) && near(fv[1], 0.16),
        format("T-P6 front plane: expected halfU (0.320000,0,0) halfV (0,0.160000,0), "
               ~ "got %s / %s", vstr(fu), vstr(fv)));

    aimCellA("Right");
    auto r = placement(kRightPlane, kCellA, "Right", true);
    assert(r["clipWidth"].integer == 20 && r["clipHeight"].integer == 48,
        format("T-P6: the right plane is bound to the 20x48 clip, endpoint says %dx%d",
               r["clipWidth"].integer, r["clipHeight"].integer));
    auto ru = vec3(r["halfU"]), rv = vec3(r["halfV"]);
    // A `right` plane spans world Z (u, along -Z) and Y (v).
    assert(near(ru[2], -0.10) && near(rv[1], 0.24),
        format("T-P6 right plane: expected halfU (0,0,-0.100000) halfV (0,0.240000,0), "
               ~ "got %s / %s", vstr(ru), vstr(rv)));
    assert(!near(vlen(ru), vlen(fu)),
        "T-P6: the two planes must NOT report the same extent — if they do, both "
        ~ "read the same clip");
}

// ---------------------------------------------------------------------------
// T-V1 — each cell draws exactly ONE of the two planes, and they are
// DIFFERENT ones. Asserted by plane INDEX, not by count: "draw the first plane
// in every cell" produces the right count in both cells and the wrong plane in
// one of them.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();
    aimCellA("Right");

    int[] drawnIn(int cell, string preset) {
        int[] hits;
        foreach (idx; [kFrontPlane, kRightPlane]) {
            auto j = placement(idx, cell, preset, true);
            if (j["drawn"].boolean) hits ~= idx;
        }
        return hits;
    }
    auto inRight = drawnIn(kCellA, "Right");
    auto inFront = drawnIn(kCellFront, "Front");
    assert(inRight == [kRightPlane],
        format("T-V1: the Right cell must draw the right plane and ONLY it — "
               ~ "drawn planes were %s", inRight));
    assert(inFront == [kFrontPlane],
        format("T-V1: the Front cell must draw the front plane and ONLY it — "
               ~ "drawn planes were %s", inFront));
    assert(inRight != inFront,
        "T-V1: two cells drawing the same plane means the projection channel "
        ~ "is not reaching the match");
}

// ---------------------------------------------------------------------------
// T-V2 — a FOLLOWING ortho cell resolves its plane from its OWN preset.
//
// Cell 0 is put on the Front preset and made a follower, twice. `resolveFollow`
// resolves focus / distance / ORIENTATION and never `projKind` / `viewPreset`,
// and under Ortho `effectiveOrientation` discards the followed orientation
// anyway — so the plane must still be drawn, at byte-identical half-extents.
//
// Wrong implementation: take the match input from the FOLLOW-RESOLVED camera
// instead of the cell's own — the obvious alternative to enum equality, and
// the one an implementation reaches for the moment it thinks in terms of "the
// camera this cell renders with".
//
// TWO MASTERS, AND THE SECOND ONE IS NOT DECORATION. With ONLY the perspective
// master (the shape this test was first written in) it does not discriminate
// at all: a resolved-camera implementation reads the master's `projKind` as
// Perspective, falls through to `showInPerspective` — which DEFAULTS TRUE —
// and reports `drawn == true`, the same answer as the correct code. Measured:
// that break ran GREEN through this test before the second master was added.
// So:
//   * master = cell 2, an ORTHO cell on a DIFFERENT preset (Left). A
//     resolved-camera implementation compares Left against the plane's Front
//     and reads `drawn == false`.
//   * master = cell 3, the perspective one, with `showInPerspective` turned
//     OFF for the duration — which is what closes the fall-through above and
//     makes this master discriminate too.
//
// THE RIG IS ASSERTED, NOT ASSUMED, for each master: a follow is only a real
// separation if cell 0's RESOLVED orientation actually moves to the master's.
// `indRotate` defaults TRUE (and the Quad layout re-asserts it), so a bare
// `viewport.master` follows focus and distance and keeps the cell's own
// rotation — the orientation half has to be switched on explicitly, and this
// test would otherwise be claiming a separation it never provided.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();
    aimCellA("Front");

    // Aim both candidate masters well off any axis, so "the orientation
    // followed" is an observable difference rather than a coincidence.
    post(baseUrl ~ "/api/camera?viewport=2", `{"azimuth":-52.0,"elevation":11.0}`);
    post(baseUrl ~ "/api/camera?viewport=3", `{"azimuth":37.0,"elevation":24.0}`);

    string orient(int cell) {
        return getJson(format("/api/camera?viewport=%d", cell))["orientation"].toString;
    }
    immutable soloOrient = orient(kCellA);
    auto solo = placement(kFrontPlane, kCellA, "Front", true);
    assert(solo["drawn"].boolean, "T-V2 precondition: drawn before any follow");

    void followedBy(int master, string what) {
        cmd(format(`{"id":"viewport.master","params":"%d"}`, master));
        cmd(`{"id":"viewport.indRotate","params":"no"}`);
        scope(exit) {
            cmd(`{"id":"viewport.indRotate","params":"yes"}`);
            cmd(`{"id":"viewport.master","params":"-1"}`);
        }
        immutable followed = orient(kCellA);
        assert(followed != soloOrient,
            format("T-V2 RIG (%s): cell 0's resolved orientation did not change when "
                   ~ "it started following — the test would then prove nothing about "
                   ~ "following at all", what));
        assert(followed == orient(master),
            format("T-V2 RIG (%s): a follower's resolved orientation must be the "
                   ~ "master's — cell 0 %s vs cell %d %s",
                   what, followed, master, orient(master)));

        auto led = placement(kFrontPlane, kCellA, "Front", true);
        assert(led["drawn"].boolean,
            format("T-V2 (%s): a Front ortho cell following %s still draws its front "
                   ~ "plane — the preset is the cell's OWN and is never "
                   ~ "follow-resolved", what, what));
        assert(led["halfU"].toString == solo["halfU"].toString
            && led["halfV"].toString == solo["halfV"].toString,
            format("T-V2 (%s): the half-extents must be identical under a follow — "
                   ~ "%s / %s became %s / %s", what,
                   solo["halfU"].toString, solo["halfV"].toString,
                   led["halfU"].toString,  led["halfV"].toString));
    }

    followedBy(kCellLeft, "an ORTHO Left master");

    // The perspective master only discriminates once the perspective
    // fall-through is closed — see the header.
    cmd("layer.attr 4 showInPerspective false");
    scope(exit) cmd("layer.attr 4 showInPerspective true");
    followedBy(kCellPersp, "an off-axis PERSPECTIVE master");
}

// ---------------------------------------------------------------------------
// T-V3 — `showInPerspective` is the plane's opt-out for the FREE-ORBIT cell
// only. An implementation that hides everywhere fails on the Front cell.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();
    auto onP = placement(kFrontPlane, kCellPersp, "Perspective", false);
    assert(onP["drawn"].boolean,
        "T-V3 precondition: a plane is shown in perspective by default");

    cmd("layer.attr 4 showInPerspective false");
    auto offP = placement(kFrontPlane, kCellPersp, "Perspective", false);
    auto offF = placement(kFrontPlane, kCellFront, "Front", true);
    assert(!offP["drawn"].boolean,
        "T-V3: showInPerspective=false hides it in the perspective cell");
    assert(offF["drawn"].boolean,
        "T-V3: …and ONLY there — the Front cell still draws it. A 'hide "
        ~ "everywhere' implementation reads drawn=false here.");
}

// ---------------------------------------------------------------------------
// T-V4 is NOT written here, and this is the reason.
//
// Its subject is an ORTHOGRAPHIC cell whose preset is `Perspective` (the
// free-orbit ortho of `view.d`'s own comment), which must draw nothing. No
// route in the tree can produce that state: `applyCellViewPreset` — the single
// writer, and what `viewport.view` dispatches to — DERIVES `projKind` from the
// preset, so `Perspective` always arrives with `ProjKind.Perspective`. A test
// that set the preset and then asserted "not drawn" would be asserting the
// perspective branch under a misleading name.
//
// The predicate is pinned in `image_plane.d`'s own unittests instead, where
// the cell is an argument and the state is expressible.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// T-V5 — HIDDEN is not BROKEN, and hiding does not cost a decode.
//
// Three wrong implementations, three different readings:
//   * visibility ignored           -> drawn == true while hidden;
//   * visibility folded into
//     `source`                     -> source reads "unbound", collapsing a
//                                     perfectly good image with a missing one;
//   * residency keyed on drawn-ness
//     rather than on the link      -> the decode count moves across the
//                                     hide/show, i.e. the workflow re-reads
//                                     the file from disk.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();
    ulong decodes() { return cast(ulong) getJson("/api/images")["cache"]["decodes"].integer; }

    auto shown = placement(kFrontPlane, kCellFront, "Front", true);
    assert(shown["drawn"].boolean && shown["source"].str == "ready",
        "T-V5 precondition: visible + Ready draws");
    immutable before = decodes();

    cmd(`{"id":"layer.setVisible","index":4,"value":false}`);
    auto hidden = placement(kFrontPlane, kCellFront, "Front", true);
    assert(!hidden["drawn"].boolean, "T-V5: a hidden plane is not drawn");
    assert(hidden["source"].str == "ready",
        format("T-V5: a hidden plane's SOURCE is still 'ready' — hiding is not a "
               ~ "source problem, and this field is the only observable of the rule "
               ~ "that its texture stays resident. Got '%s'.", hidden["source"].str));

    cmd(`{"id":"layer.setVisible","index":4,"value":true}`);
    auto reshown = placement(kFrontPlane, kCellFront, "Front", true);
    assert(reshown["drawn"].boolean, "T-V5: un-hiding draws it again");
    immutable after = decodes();
    assert(after == before,
        format("T-V5: a hide/show round trip must cost NO decode — %d became %d",
               before, after));
}

// ---------------------------------------------------------------------------
// T-V6 — THE FROZEN VIEWPORT MATCH, asserted against the measured rows
// (`doc/tasks/0612-evidence/phase0_size_law.txt`, "VIEWPORT MATCH").
//
// This overlaps T-V1..T-V3 by design; the difference is provenance. Those
// assert our DESIGN, this asserts the measured reference rows, so if the
// design is ever revisited it is the parity claim that goes red.
//
// Only two of the four rows can fail, and they fail TOGETHER:
//   * front x back  = false  — "mirror the plane into the opposite view" is
//                              the single most tempting implementation (a
//                              front reference DOES describe the geometry a
//                              back view shows). Measured: not drawn.
//   * front x persp = true   — the same mistake from the other side: an
//                              implementation that mirrors into the opposite
//                              view typically also treats perspective as "no
//                              matching preset" and hides there.
//   * front x top   = false  — weakly; subsumed by the back row for the mirror
//                              hypothesis, but it independently catches "draw
//                              in every ortho cell". One line, so kept.
//   * front x front = true   — the IDENTITY row. No implementation that draws
//                              anything at all fails it; it is not a proof.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();

    struct Row { string preset; int cell; bool ortho; bool drawn; string role; }
    immutable Row[] rows = [
        Row("Front",       kCellFront, true,  true,  "identity — cannot fail"),
        Row("Back",        kCellA,     true,  false, "LOAD-BEARING: not mirrored into the opposite view"),
        Row("Top",         kCellA,     true,  false, "weak: not every ortho cell"),
        Row("Perspective", kCellPersp, false, true,  "LOAD-BEARING: shown in perspective"),
    ];
    foreach (row; rows) {
        if (row.cell == kCellA) aimCellA(row.preset);
        auto j = placement(kFrontPlane, row.cell, row.preset, row.ortho);
        assert(j["drawn"].boolean == row.drawn,
            format("T-V6 measured row `front` x %s: expected drawn=%s (%s), got %s",
                   row.preset, row.drawn, row.role, j["drawn"].boolean));
    }
}

// ---------------------------------------------------------------------------
// The endpoint refuses what it cannot answer, with a TYPED error rather than
// an empty placement — "layer 0 is a mesh" and "layer 4 is a plane showing
// nothing" are different answers, and a caller holding only zeros could not
// tell them apart.
// ---------------------------------------------------------------------------
unittest {
    buildFixture();
    auto notAPlane = getJson("/api/imageplane?index=0&cell=1");
    assert("error" in notAPlane && notAPlane["error"].str.length > 0,
        "asking a mesh layer for a placement is an error, not zeros: "
        ~ notAPlane.toString);
    auto noCell = getJson("/api/imageplane?index=4&cell=9");
    assert("error" in noCell, "a dead cell is an error: " ~ noCell.toString);
    auto noLayer = getJson("/api/imageplane?index=99&cell=1");
    assert("error" in noLayer, "a missing layer is an error: " ~ noLayer.toString);
}
