// Task 0647 — hover feedback while the current selection type is Item.
//
// WHAT IS BEING ASSERTED, AND WHY "SOMETHING HIGHLIGHTED" WOULD ASSERT NOTHING.
//
// The capture behind `tests/fixtures/item_hover_highlight.json` existed to rule
// between four hypotheses about what an item-mode hover paints:
//
//   H1  a tint over the item's SURFACE
//   H2  the item's EDGES, one pixel wide
//   H3  only the item's SILHOUETTE
//   H4  whatever the SELECTED item is drawn with
//
// Every one of those satisfies "something highlighted". So every assertion here
// is about WHICH pixels carry the paint and WHAT COLOUR they are, never about
// whether the frame changed:
//
//   * H1 dies on a SCANLINE. A row crossing the item is probed pixel by pixel;
//     a wireframe paints a handful of pixels with unpainted gaps between them,
//     a surface tint paints the whole span. The fixture's own instrument was
//     the same one (`paint.evidence.scanline_hits_across_the_top_row_x` records
//     three hits on a row, i.e. two gaps).
//   * H3 dies on the same scanline by COUNTING. A convex outline gives a row
//     exactly two hits; an edge draw gives more, because the interior edges are
//     crossed too. This rig's cube in a three-quarter view gives four.
//   * H4 dies on the COLOUR. Hover and selection are different colours — that
//     was the single most informative thing the capture measured — so a hover
//     implemented as "draw it as selected" reads the selection orange where
//     this file demands the pre-highlight blue.
//
// THE ONE-ITEM TRAP, WHICH THE CAPTURE FELL INTO AND HAD TO REBUILD FOR. With a
// single item in the scene, "the item under the cursor is lit" and "every item
// is lit" render identically. This rig therefore has THREE items, far enough
// apart that their projections are disjoint, and asserts a zero on the two the
// cursor is not over. The three are also in three different states — one
// unselected and unhovered, one hovered, one selected — so a single frame
// carries a positive, a negative and a control.
//
// WHY THE PIXELS AND NOT A MODEL. `viewport_scheme.d`'s unittests already pin
// the colour law as numbers, and they passed for the entire period in which no
// item highlight existed at all: a law test cannot fail for a missing caller.
// This file drives a real pointer over a real frame and reads the framebuffer
// back through /api/viewport/probe, so it fails when the pass is not wired,
// when the pass draws the wrong geometry, and when it draws the right geometry
// in the wrong colour.
//
// VERIFIED BY MUTATION. Each was applied to a green tree, built and run; the
// assertion named is the one that fired, with the value it observed. They land
// on SIX different assertions, which is the point — the flows are not six
// spellings of one check.
//
//   * `itemHighlightColor(hovered)` returns the SELECTION colour (H4 — "just
//     draw it as selected")
//       -> U1(a) "hovering item 1 must paint it in the pre-highlight colour
//          (140,181,199); row 273 carries none" — 0 where >0 is required.
//   * the highlight pass lights every visible item, not the one under the
//     cursor (`itemHighlight(lyr.selected, true)`)
//       -> U1(e) "item 0 is not under the cursor and must carry no
//          pre-highlight pixels — row 237 carries 4 at [122,156,158,192]".
//   * `drawItemHighlight` submits the FACE buffer instead of the edge buffer
//     (H1, a surface tint)
//       -> U1(b) "a scanline across the item must have unpainted gaps — row
//          273 carries 74 painted pixels across a 76-pixel span".
//   * the pass draws only edges with exactly one camera-facing adjacent face
//     (H3, a real silhouette extraction)
//       -> U1(c) "row 273 carries 2 painted pixels. Exactly two is a
//          SILHOUETTE" — 2 where >=3 is required.
//   * the item ray keeps the LAST hit rather than the nearest
//       -> U4 arm 2 "near at index 0, far at index 1 … the app reports item 1".
//   * the item ray keeps the FIRST hit rather than the nearest
//       -> U4 arm 1 "near at index 1, far at index 0 … the app reports item 0".
//     Both arms are needed and neither is padding: with only the first arm,
//     the LAST-hit mutation measured GREEN, because the layer array is walked
//     in index order and that order happened to agree with the depth order.
//   * `itemHighlightColor(selectedHovered)` returns the selection colour
//     unchanged (the third state collapsed into the second)
//       -> U2 "selected+hovered must paint the same pixels again —
//          [287,314,336,361] vs []".
//   * the `currentSelType == Item` gate removed from the highlight pass
//       -> U5 "the selected-item paint is gated on the Item selection type
//          too" — the items stayed lit under a geometry type.
//   * the picker's unconditional `g_hoveredItem = -1` removed, so the hover
//     latches at the last item it found
//       -> U2 "the parking pixel must be over empty space" — the app still
//          reported item 1 with the pointer in the gap.

import std.net.curl;
import std.json;
import std.conv    : to;
import std.format  : format;
import std.math    : sqrt, abs, round;
import std.algorithm : sort, min, max, canFind;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, CameraState, DHVec3 = Vec3, DHViewport = Viewport;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// The fixture
// ---------------------------------------------------------------------------

/// Embedded at compile time so the test carries its own reference and cannot be
/// run against a fixture that is not on disk. Everything this file expects is
/// READ FROM HERE rather than retyped — a retyped constant is a second copy of
/// the measurement that can silently disagree with the first.
enum string kFixtureJson = import("fixtures/item_hover_highlight.json");

private JSONValue fixture() { return parseJSON(kFixtureJson); }

private int[3] rgbOf(JSONValue v) {
    auto a = v["rgb"].array;
    return [cast(int)a[0].integer, cast(int)a[1].integer, cast(int)a[2].integer];
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

/// POST /api/command. Takes the raw body so both spellings work — a JSON object
/// and the bare argstring form (`layer.attr 0 pos.x -4`).
private void cmd(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
}

/// The probe reads the last COMPLETED frame and the HTTP bridge is serviced
/// before the render, so a change needs a frame to become visible.
private void settle() { Thread.sleep(400.msecs); }

private struct Cell { int vx, vy, vw, vh; }

private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int)c["vpX"].integer,  cast(int)c["vpY"].integer,
                cast(int)c["width"].integer, cast(int)c["height"].integer);
}

/// Park the pointer at a WINDOW pixel with no button pressed and leave it
/// there. The player's mouse override is never cleared, so the position — and
/// therefore the hover — persists into every frame drawn after playback ends,
/// which is what makes a post-playback probe meaningful.
private void hoverAt(Cell c, int wx, int wy) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n", c.vx, c.vy, c.vw, c.vh);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
            ~ "\n", 50.0 + i * 20.0, wx, wy);
    playAndWait(log);
    settle();
}

/// Which item the app says is under the cursor, as a `layers` index (-1 = none).
private int hoveredItem() {
    return cast(int)getJson("/api/layers")["hoveredItem"].integer;
}

private struct Px { int r, g, b; bool valid; }

/// Probe a run of FBO pixels, chunked so the request line stays short.
private Px[] probe(const int[2][] fboPts) {
    Px[] outp;
    for (size_t i = 0; i < fboPts.length; i += 60) {
        auto slice = fboPts[i .. (i + 60 > fboPts.length ? fboPts.length : i + 60)];
        string q = "/api/viewport/probe?cell=0&points=";
        foreach (k, p; slice) {
            if (k) q ~= ";";
            q ~= format("%d,%d", p[0], p[1]);
        }
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        // The --test single-rendered-cell trap: a probe at a never-filled FBO
        // reads zeros, and every assertion below would then fail for the wrong
        // reason. Assert the flag rather than trusting the default.
        assert(j["renders"].type == JSONType.true_,
            "the probed cell is not rendered under --test; the reading is void");
        foreach (e; j["points"].array) {
            Px p;
            if ("error" in e) { outp ~= p; continue; }
            p.r = cast(int)e["r"].integer;
            p.g = cast(int)e["g"].integer;
            p.b = cast(int)e["b"].integer;
            p.valid = true;
            outp ~= p;
        }
    }
    return outp;
}

/// The x positions on FBO row `row`, within [x0, x1), whose pixel is EXACTLY
/// `want`. Exact, not a window: the highlight is drawn opaque with no
/// anti-aliasing, so its pixels carry the uniform's value and nothing else —
/// which is what lets a four-count difference between two colours be an
/// assertion rather than a tolerance question.
private int[] hitsOn(int row, int x0, int x1, int[3] want) {
    int[2][] pts;
    foreach (x; x0 .. x1) pts ~= [x, row];
    auto vals = probe(pts);
    int[] hits;
    foreach (i, v; vals)
        if (v.valid && v.r == want[0] && v.g == want[1] && v.b == want[2])
            hits ~= x0 + cast(int)i;
    return hits;
}

// ---------------------------------------------------------------------------
// The rig
// ---------------------------------------------------------------------------

/// One item's projected extent, in FBO pixels.
private struct Box {
    int x0, y0, x1, y1;
    int[] vertRows;             ///< FBO rows the item's own vertices land on
    int cx() const { return (x0 + x1) / 2; }
    int cy() const { return (y0 + y1) / 2; }
    bool disjointFrom(const Box o) const {
        return x1 < o.x0 || o.x1 < x0 || y1 < o.y0 || o.y1 < y0;
    }
}

/// Reset to three unit cubes, spread along X, seen three-quarter on, with the
/// current selection type switched to Item.
///
/// Three items is the minimum that decides anything (see the header), and they
/// are spread far enough for `assertRigSane` below to prove their projections
/// are disjoint rather than assume it.
///
/// The LAST layer is left selected and primary, which is what `layer.duplicate`
/// does; the test asserts that rather than arranging it, so the rig describes
/// the app's real behaviour. That gives the frame a selected item the cursor is
/// not over — the second colour, for free, in the same frame as the first.
private void buildRig() {
    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"layer.duplicate"}`);
    cmd(`{"id":"layer.duplicate"}`);
    cmd("layer.attr 0 pos.x -4");
    cmd("layer.attr 2 pos.x 4");
    // The door into the Item selection type (task 0642). Without it the app is
    // in a geometry type and the highlight pass must not run at all — which is
    // itself asserted, in U5.
    cmd(`{"id":"select.item"}`);
    // Far enough back that all three fit, close enough that a cube is ~75 px
    // across and its interior edges are separable at one-pixel resolution.
    post(baseUrl ~ "/api/camera?viewport=0", `{"distance":12.0}`);
    settle();
}

/// Where each item lands on screen, computed from the camera rather than
/// hard-coded.
///
/// The eight corners are projected through the SAME formula the app projects
/// with (`drag_helpers`, which carries the copy every drag test already relies
/// on), so a camera change moves the probes with it and nothing here is a
/// magic number.
private Box[] itemBoxes() {
    auto layers = getJson("/api/layers")["layers"].array;
    auto camS   = fetchCamera(baseUrl);
    auto vp     = viewportFromCamera(camS);
    auto c      = cell();

    Box[] boxes;
    foreach (li, l; layers) {
        auto pos = l["xform"]["pos"].array;
        auto rot = l["xform"]["rot"].array;
        auto scl = l["xform"]["scl"].array;
        foreach (k; 0 .. 3)
            assert(abs(rot[k].floating) < 1e-6,
                "rig: an unrotated item keeps the projection below a pure offset");
        Box b;
        b.x0 = int.max; b.y0 = int.max; b.x1 = int.min; b.y1 = int.min;
        foreach (sx; [-0.5f, 0.5f])
        foreach (sy; [-0.5f, 0.5f])
        foreach (sz; [-0.5f, 0.5f]) {
            auto world = DHVec3(
                cast(float)(pos[0].floating + sx * scl[0].floating),
                cast(float)(pos[1].floating + sy * scl[1].floating),
                cast(float)(pos[2].floating + sz * scl[2].floating));
            float px, py;
            assert(projectToWindow(world, vp, px, py),
                format("rig: item %d has a corner behind the camera", li));
            immutable int fx = cast(int)round(px) - c.vx;
            immutable int fy = cast(int)round(py) - c.vy;
            b.x0 = min(b.x0, fx); b.x1 = max(b.x1, fx);
            b.y0 = min(b.y0, fy); b.y1 = max(b.y1, fy);
            if (!b.vertRows.canFind(fy)) b.vertRows ~= fy;
        }
        boxes ~= b;
    }
    return boxes;
}

/// `itemBoxes` plus the preconditions the three-item rig's conclusions rest on.
private Box[] rigBoxes() {
    auto layers = getJson("/api/layers")["layers"].array;
    assert(layers.length == 3,
        format("rig: three items, got %d", layers.length));

    // The mesh is the unit cube, and it is the SAME mesh in all three (a
    // duplicate). Read rather than assumed: a different primitive would move
    // every screen coordinate below.
    auto verts = getJson("/api/model")["vertices"].array;
    assert(verts.length == 8, format("rig: a cube has 8 vertices, got %d", verts.length));
    foreach (v; verts)
        foreach (k; 0 .. 3)
            assert(abs(abs(v.array[k].floating) - 0.5) < 1e-4,
                "rig: the item mesh must be the unit cube centred on its own origin");

    return itemBoxes();
}

/// The rig decides something only if the three items are separable on screen.
/// Asserted, not eyeballed: the whole "the cursor is over B and not over A or
/// C" argument rests on it.
private void assertRigSane(const Box[] b) {
    foreach (i; 0 .. b.length)
        foreach (j; i + 1 .. b.length)
            assert(b[i].disjointFrom(b[j]),
                format("rig: items %d and %d overlap on screen "
                       ~ "([%d,%d]x[%d,%d] vs [%d,%d]x[%d,%d]) — with overlapping "
                       ~ "footprints 'the cursor is not over that one' is not a "
                       ~ "claim this rig can make",
                       i, j, b[i].x0, b[i].x1, b[i].y0, b[i].y1,
                       b[j].x0, b[j].x1, b[j].y0, b[j].y1));
}

/// A scan row through `b` that no vertex DOT can reach.
///
/// The primary layer draws a dot at every one of its vertices, AFTER the
/// highlight pass, so a row passing within a couple of pixels of a projected
/// vertex has some of its highlight pixels overwritten — and, because only the
/// PRIMARY gets dots, by a different amount depending on which item is primary.
/// That is a property of the vertex overlay, not of the highlight, and a row
/// chosen without regard for it would make the "same pixels, different colour"
/// assertion in U2 fail for a reason U2 is not about.
///
/// Found by walking outward from the box centre, so the answer is deterministic
/// and stays near the widest part of the item.
private int scanRow(const Box[] boxes, size_t which) {
    // The unselected dot is 3 px since task 1860 (it was 5). The clearance is
    // deliberately left at 6 rather than tightened with it: the number's job is
    // to be comfortably larger than the dot, and a margin that tracked the size
    // exactly would put this rig back on the edge every time the size moves.
    // The SELECTED dot is 6 px, and nothing in this file selects a vertex.
    enum int kDotClear = 6;      // a 3 px dot, plus generous margin
    enum int kInset    = 2;      // stay off the box's own top/bottom edge
    const b = boxes[which];
    // Only the SCANNED item's own vertices matter. A row is a horizontal line
    // across the whole cell, so it passes close to some other item's vertices
    // no matter where it is put; what it must not do is pass close to a vertex
    // of the item whose pixels are being counted.
    foreach (d; 0 .. (b.y1 - b.y0)) {
        foreach (row; [b.cy - d, b.cy + d]) {
            if (row < b.y0 + kInset || row > b.y1 - kInset) continue;
            bool clear = true;
            foreach (vr; b.vertRows)
                if (abs(row - vr) < kDotClear) { clear = false; break; }
            if (clear) return row;
        }
    }
    assert(false, "rig: no scan row far enough from the item's own projected "
                  ~ "vertices — the item is too small on screen for this rig");
}

// ---------------------------------------------------------------------------
// U0 — the fixture says what this file claims it says.
//
// Runs before anything is driven, needs no application, and exists because
// every expectation below is READ from the fixture: a fixture edited to say
// "the surface is filled" would otherwise turn this file's assertions into
// assertions about something else without a word of warning. It also re-derives
// the third colour from the law, so the derivation is pinned independently of
// the running code.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();

    assert(fx["unit"]["highlighted_unit"].str == "whole_item",
        "the fixture must say the highlighted unit is the WHOLE item");
    assert(fx["paint"]["target"].str == "edges");
    assert(fx["paint"]["surface_filled"].type      == JSONType.false_);
    assert(fx["paint"]["covers_interior_edges"].type == JSONType.true_);
    assert(fx["paint"]["silhouette_only"].type     == JSONType.false_);
    assert(fx["colors"]["hover_equals_selection"].type == JSONType.false_,
        "the fixture must say hover and selection are DIFFERENT colours — that "
        ~ "is the fact U2 exists to check we implement");
    assert(fx["coverage_shared_with_selection"]["identical_pixel_set"].type
           == JSONType.true_);

    immutable pre  = rgbOf(fx["colors"]["hovered_unselected"]);
    immutable sel  = rgbOf(fx["colors"]["selected_not_hovered"]);
    immutable selH = rgbOf(fx["colors"]["selected_and_hovered"]);
    assert(pre != sel && pre != selH && sel != selH,
        "three states, three distinct colours");

    // The third colour is DERIVED. Re-derived here from the first, through the
    // law the fixture states, so this file never carries (255,194,66) as a
    // constant that a re-themed selection colour would leave behind.
    assert(fx["selected_and_hovered_law"]["rule"].str
           == "clamp(selection_color + 0.1, 0, 1)");
    foreach (k; 0 .. 3) {
        immutable float lit = sel[k] / 255.0f + 0.1f;
        immutable int  want = cast(int)round((lit > 1.0f ? 1.0f : lit) * 255.0f);
        assert(abs(want - selH[k]) <= 1,
            format("the fixture's selected+hovered channel %d (%d) must be its "
                   ~ "selection channel (%d) brightened by 0.1 -> %d",
                   k, selH[k], sel[k], want));
    }
}

// ---------------------------------------------------------------------------
// U1 — WHAT is painted, and on WHICH item.
//
// The hypothesis-killing flow. One scanline across the hovered item settles
// H1 (a filled span versus gaps) and H3 (two hits versus more), and the two
// items the cursor is not over settle "the item under the cursor" versus
// "every item".
// ---------------------------------------------------------------------------
unittest {
    auto fx  = fixture();
    immutable pre = rgbOf(fx["colors"]["hovered_unselected"]);
    immutable sel = rgbOf(fx["colors"]["selected_not_hovered"]);

    buildRig();
    auto boxes = rigBoxes();
    assertRigSane(boxes);
    auto c = cell();

    auto layers = getJson("/api/layers")["layers"].array;
    assert(layers[0]["selected"].type == JSONType.false_
        && layers[1]["selected"].type == JSONType.false_
        && layers[2]["selected"].type == JSONType.true_,
        "rig precondition: exactly the last item is selected");

    immutable int row = scanRow(boxes, 1);
    hoverAt(c, boxes[1].cx + c.vx, row + c.vy);

    // The ray found the middle item — asserted separately from the pixels so a
    // failure says whether the ray or the paint is wrong.
    assert(hoveredItem() == 1,
        format("the cursor was placed inside item 1's footprint; the app "
               ~ "reports item %d under it", hoveredItem()));

    auto hits = hitsOn(row, boxes[1].x0 - 2, boxes[1].x1 + 3, pre);
    immutable int span = boxes[1].x1 - boxes[1].x0 + 1;

    // (a) It is painted at all, in the pre-highlight colour.
    assert(hits.length > 0,
        format("hovering item 1 must paint it in the pre-highlight colour "
               ~ "(%d,%d,%d); row %d carries none", pre[0], pre[1], pre[2], row));

    // (b) NOT a surface tint. A fill paints the whole span between the
    //     silhouette edges; edges paint a handful with gaps between them.
    assert(hits.length * 4 < span,
        format("a scanline across the item must have unpainted gaps — row %d "
               ~ "carries %d painted pixels across a %d-pixel span. A count "
               ~ "near the span is a filled surface, not a wireframe.",
               row, hits.length, span));
    bool gapFound = false;
    foreach (i; 1 .. hits.length)
        if (hits[i] - hits[i - 1] > 1) { gapFound = true; break; }
    assert(gapFound, "a scanline across the item must contain a real gap");

    // (c) NOT silhouette-only. A row across a convex outline meets it exactly
    //     twice; an edge draw also meets the interior edges. This rig's
    //     three-quarter view puts two interior edges on the row.
    assert(hits.length >= 3,
        format("row %d carries %d painted pixels. Exactly two is a SILHOUETTE: "
               ~ "the interior edges of the item must paint too (the reference "
               ~ "painted %s of its %s pixels on interior edges).",
               row, hits.length,
               fx["paint"]["evidence"]["interior_edge_changed_px"].toString,
               fx["paint"]["evidence"]["total_changed_px"].toString));

    // (d) The unit is the ITEM, not the polygon under the cursor. A second
    //     cursor position, on a different face of the same cube, must paint the
    //     identical pixels — the fixture's
    //     `hover_a_different_polygon_paints_the_identical_pixel_set`.
    immutable int row2 = scanRow(boxes, 1);
    immutable int otherX = boxes[1].x0 + (boxes[1].x1 - boxes[1].x0) / 4;
    hoverAt(c, otherX + c.vx, boxes[1].y0 + (boxes[1].y1 - boxes[1].y0) / 4 + c.vy);
    assert(hoveredItem() == 1, "the second cursor position is still over item 1");
    auto hits2 = hitsOn(row2, boxes[1].x0 - 2, boxes[1].x1 + 3, pre);
    assert(hits == hits2,
        format("hovering a DIFFERENT polygon of the same item must paint the "
               ~ "identical pixels — got %s then %s. A per-polygon highlight "
               ~ "moves with the cursor; an item highlight does not.",
               hits, hits2));

    // (e) The two items the cursor is NOT over carry no highlight at all —
    //     item 0 because it is neither hovered nor selected, and it must not
    //     pick up the hovered item's colour.
    foreach (idx; [0UL, 2UL]) {
        immutable int r = scanRow(boxes, idx);
        auto stray = hitsOn(r, boxes[idx].x0 - 2, boxes[idx].x1 + 3, pre);
        assert(stray.length == 0,
            format("item %d is not under the cursor and must carry no "
                   ~ "pre-highlight pixels — row %d carries %d at %s. This is "
                   ~ "the assertion a one-item rig cannot make.",
                   idx, r, stray.length, stray));
    }

    // (f) …and the CONTROL that says the probe is live and the frame really
    //     does paint other items: item 2 is selected, and reads the selection
    //     colour on its own row.
    immutable int rowC = scanRow(boxes, 2);
    auto selHits = hitsOn(rowC, boxes[2].x0 - 2, boxes[2].x1 + 3, sel);
    assert(selHits.length >= 3,
        format("control: the SELECTED item 2 must be painted in (%d,%d,%d) — "
               ~ "row %d carries %d such pixels. Zero here means the probe or "
               ~ "the rig is broken and every zero above is meaningless.",
               sel[0], sel[1], sel[2], rowC, selHits.length));
}

// ---------------------------------------------------------------------------
// U2 — the three colours, over ONE shared coverage.
//
// The fixture's central claim is not that the three states look different; it
// is that they paint the SAME PIXELS in different colours (symmetric difference
// zero). So this flow measures the same scan row three times, in three states,
// and requires the pixel SET to be identical and the colour to differ.
//
// A "hover draws it as selected" implementation passes the set assertion and
// fails the colour ones. A "hovered-selected is just selected" implementation
// fails the third colour alone. A hover implemented as a surface tint fails the
// set assertion. No two of those are the same failure.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    immutable pre  = rgbOf(fx["colors"]["hovered_unselected"]);
    immutable sel  = rgbOf(fx["colors"]["selected_not_hovered"]);
    immutable selH = rgbOf(fx["colors"]["selected_and_hovered"]);

    buildRig();
    auto boxes = rigBoxes();
    assertRigSane(boxes);
    auto c = cell();
    immutable int row = scanRow(boxes, 1);
    immutable int x0  = boxes[1].x0 - 2, x1 = boxes[1].x1 + 3;

    // State 1 — hovered, NOT selected.
    hoverAt(c, boxes[1].cx + c.vx, row + c.vy);
    assert(hoveredItem() == 1);
    auto hHover = hitsOn(row, x0, x1, pre);
    assert(hHover.length >= 3,
        format("a hovered UNSELECTED item must read the pre-highlight colour "
               ~ "(%d,%d,%d) — row %d carries %d such pixels. Reading the "
               ~ "SELECTION colour here instead is the 'draw it as selected' "
               ~ "implementation the capture refuted.",
               pre[0], pre[1], pre[2], row, hHover.length));
    assert(hitsOn(row, x0, x1, sel).length == 0,
        "a hovered UNSELECTED item must not carry the selection colour");

    // State 2 — selected, NOT hovered. The pointer is parked on empty space so
    // the only thing that changed is the selection.
    cmd(`{"id":"layer.select","index":1,"mode":"add"}`);
    hoverAt(c, c.vx + 8, c.vy + 8);
    assert(hoveredItem() == -1, "the parking pixel must be over empty space");
    auto hSel = hitsOn(row, x0, x1, sel);
    assert(hSel == hHover,
        format("selected and hovered must paint the SAME pixels — hovered %s, "
               ~ "selected %s. The reference measured a symmetric difference of "
               ~ "zero, which is a statement about coverage, not about counts.",
               hHover, hSel));
    assert(hitsOn(row, x0, x1, pre).length == 0,
        "an item that is selected and not hovered must not carry the "
        ~ "pre-highlight colour");

    // State 3 — selected AND hovered. Its own colour, over the same pixels.
    hoverAt(c, boxes[1].cx + c.vx, row + c.vy);
    assert(hoveredItem() == 1);
    auto hBoth = hitsOn(row, x0, x1, selH);
    assert(hBoth == hHover,
        format("selected+hovered must paint the same pixels again — %s vs %s. "
               ~ "The reference measured that hovering a selected item adds no "
               ~ "pixels to the selected look.", hHover, hBoth));
    assert(hitsOn(row, x0, x1, sel).length == 0,
        format("selected AND hovered is its own colour (%d,%d,%d), not the "
               ~ "selection colour (%d,%d,%d) — reading the latter means the "
               ~ "third state was collapsed into the second",
               selH[0], selH[1], selH[2], sel[0], sel[1], sel[2]));
    assert(hitsOn(row, x0, x1, pre).length == 0,
        "…nor the pre-highlight colour: the third state is a brightened "
        ~ "SELECTION, not the hover colour");
}

// ---------------------------------------------------------------------------
// U3 — empty space clears the highlight, and the state does not latch.
//
// Measured as a zero three times over, because a single zero cannot tell a
// cleared state from a probe that stopped working. The selected item is left in
// the frame throughout as the live control.
// ---------------------------------------------------------------------------
unittest {
    auto fx  = fixture();
    immutable pre = rgbOf(fx["colors"]["hovered_unselected"]);
    immutable sel = rgbOf(fx["colors"]["selected_not_hovered"]);

    buildRig();
    auto boxes = rigBoxes();
    assertRigSane(boxes);
    auto c = cell();
    immutable int row  = scanRow(boxes, 1);
    immutable int rowC = scanRow(boxes, 2);

    // The gap BETWEEN two items, not the far corner of the view: a cursor off
    // the edge of everything is a weaker statement than a cursor in a hole.
    immutable int gapX = (boxes[0].x1 + boxes[1].x0) / 2;

    foreach (pass; 0 .. 3) {
        hoverAt(c, boxes[1].cx + c.vx, row + c.vy);
        assert(hoveredItem() == 1, format("pass %d: on the item", pass));
        assert(hitsOn(row, boxes[1].x0 - 2, boxes[1].x1 + 3, pre).length >= 3,
            format("pass %d: the item lights while hovered", pass));

        hoverAt(c, gapX + c.vx, row + c.vy);
        assert(hoveredItem() == -1,
            format("pass %d: the gap between two items is empty space, the app "
                   ~ "reports item %d there", pass, hoveredItem()));
        auto after = hitsOn(row, boxes[1].x0 - 2, boxes[1].x1 + 3, pre);
        assert(after.length == 0,
            format("pass %d: moving off the item must clear its highlight — %d "
                   ~ "pixels survive at %s. A highlight that survives is latched "
                   ~ "state, and the reference measured zero, three times.",
                   pass, after.length, after));

        // The control, inside the same frame: the SELECTED item is unaffected
        // by any of this, so a zero above is a cleared hover and not a dead
        // probe.
        assert(hitsOn(rowC, boxes[2].x0 - 2, boxes[2].x1 + 3, sel).length >= 3,
            format("pass %d: the selected item must keep its colour while the "
                   ~ "pointer is elsewhere", pass));
    }
}

// ---------------------------------------------------------------------------
// U4 — along one ray, exactly the FRONT-most item lights.
//
// Two cubes on the eye-to-origin line, the near one scaled down so it sits
// strictly inside the far one's footprint. The far one is SELECTED, which makes
// it visible in the frame and gives the flow its discriminator: if the ray
// resolved to the far item it would read the selected+hovered colour, and if it
// resolved to both, both would light.
//
// TWO ARMS, AND THE REASON IS A MUTATION THAT CAME OUT INERT. With the near
// item at a fixed index, "keep the nearest hit", "keep the first hit" and "keep
// the last hit" can all agree — the layer array is walked in index order, so an
// index order that happens to match the depth order makes the wrong rules
// indistinguishable from the right one. Removing the depth compare from the
// picker was measured GREEN against the single-arm version of this flow. The
// arms therefore run the SAME assertions twice with the near item at index 0
// and then at index 1: index-order-first and index-order-last each fail exactly
// one of them, and only depth passes both.
// ---------------------------------------------------------------------------
private void rayArm(size_t nearIdx, size_t farIdx) {
    auto fx = fixture();
    immutable pre  = rgbOf(fx["colors"]["hovered_unselected"]);
    immutable sel  = rgbOf(fx["colors"]["selected_not_hovered"]);
    immutable selH = rgbOf(fx["colors"]["selected_and_hovered"]);

    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"layer.duplicate"}`);
    cmd(`{"id":"select.item"}`);
    post(baseUrl ~ "/api/camera?viewport=0", `{"distance":12.0}`);
    settle();

    // The FAR item stays at the origin and is the SELECTED one; the NEAR item
    // moves 3 m toward the eye along the same ray and shrinks to 0.4, which
    // puts it strictly inside the far one's footprint.
    cmd(format(`{"id":"layer.select","index":%d,"mode":"set"}`, farIdx));
    auto camS = fetchCamera(baseUrl);
    immutable float len = sqrt(camS.eye.x * camS.eye.x
                             + camS.eye.y * camS.eye.y
                             + camS.eye.z * camS.eye.z);
    assert(len > 1e-3f, "the camera must not sit on the focus point");
    immutable float k = 3.0f / len;
    cmd(format("layer.attr %d pos.x %.5f", nearIdx, camS.eye.x * k));
    cmd(format("layer.attr %d pos.y %.5f", nearIdx, camS.eye.y * k));
    cmd(format("layer.attr %d pos.z %.5f", nearIdx, camS.eye.z * k));
    foreach (ax; ["x", "y", "z"])
        cmd(format("layer.attr %d scl.%s 0.4", nearIdx, ax));
    settle();

    auto boxes = itemBoxes();
    assert(boxes.length == 2, format("rig: two items, got %d", boxes.length));
    auto c = cell();
    const nb = boxes[nearIdx], fb = boxes[farIdx];
    assert(nb.x0 > fb.x0 && nb.x1 < fb.x1 && nb.y0 > fb.y0 && nb.y1 < fb.y1,
        format("rig: the near item ([%d,%d]x[%d,%d]) must sit inside the far "
               ~ "one ([%d,%d]x[%d,%d])",
               nb.x0, nb.x1, nb.y0, nb.y1, fb.x0, fb.x1, fb.y0, fb.y1));

    immutable int row = scanRow(boxes, nearIdx);
    hoverAt(c, nb.cx + c.vx, row + c.vy);

    assert(hoveredItem() == cast(int)nearIdx,
        format("near at index %d, far at index %d: the front-most item along "
               ~ "the ray is the hovered one — the app reports item %d. Reading "
               ~ "%d means the ray resolves by ARRAY ORDER, not by depth.",
               nearIdx, farIdx, hoveredItem(), farIdx));

    // Every pre-highlight pixel on the row belongs to the NEAR item.
    auto preHits = hitsOn(row, fb.x0 - 2, fb.x1 + 3, pre);
    assert(preHits.length >= 2,
        format("the near item must be painted — row %d carries %d pre-highlight "
               ~ "pixels", row, preHits.length));
    foreach (x; preHits)
        assert(x >= nb.x0 - 1 && x <= nb.x1 + 1,
            format("a pre-highlight pixel at x=%d lies outside the NEAR item's "
                   ~ "extent [%d,%d] — the far item is being highlighted too",
                   x, nb.x0, nb.x1));

    // …and the far item is drawn, in the plain SELECTION colour: it is
    // selected, and it is NOT hovered.
    auto farSel = hitsOn(row, fb.x0 - 2, fb.x1 + 3, sel);
    assert(farSel.length >= 2,
        format("control: the far item is selected and must be painted in "
               ~ "(%d,%d,%d) — row %d carries %d such pixels",
               sel[0], sel[1], sel[2], row, farSel.length));
    assert(hitsOn(row, fb.x0 - 2, fb.x1 + 3, selH).length == 0,
        format("the far item must NOT read the selected+hovered colour "
               ~ "(%d,%d,%d) — that colour appearing means the ray resolved to "
               ~ "it as well as to the near one",
               selH[0], selH[1], selH[2]));
}

unittest {
    rayArm(/*near=*/1, /*far=*/0);   // depth order agrees with index order
    rayArm(/*near=*/0, /*far=*/1);   // …and now it disagrees
}

// ---------------------------------------------------------------------------
// U5 — the gate is the SELECTION TYPE, not the geometry mode.
//
// `editMode` keeps reading whatever geometry type was last used, even under the
// Item selection type — that is what makes keys 1/2/3 restore it. An
// implementation that gated the highlight on `editMode` would therefore light
// items in Vertices mode and would NOT light them in Item mode, and both halves
// are asserted here: the same cursor, over the same item, before and after the
// door is opened.
// ---------------------------------------------------------------------------
unittest {
    auto fx = fixture();
    immutable pre = rgbOf(fx["colors"]["hovered_unselected"]);
    immutable sel = rgbOf(fx["colors"]["selected_not_hovered"]);

    buildRig();
    auto boxes = rigBoxes();
    assertRigSane(boxes);
    auto c = cell();
    immutable int row = scanRow(boxes, 1);
    immutable int x0  = boxes[1].x0 - 2, x1 = boxes[1].x1 + 3;

    hoverAt(c, boxes[1].cx + c.vx, row + c.vy);
    assert(hitsOn(row, x0, x1, pre).length >= 3, "precondition: lit under Item");

    // Back to a geometry type. The pointer does not move.
    cmd(`{"id":"select.polygon"}`);
    settle();
    assert(getJson("/api/selection")["selType"].str != "item",
        "the geometry door must have changed the current selection type");
    assert(hoveredItem() == -1,
        format("no item is hovered outside the Item selection type — the app "
               ~ "reports item %d", hoveredItem()));
    assert(hitsOn(row, x0, x1, pre).length == 0,
        "an item must not be pre-highlighted while a GEOMETRY type is current");
    // …and neither is the selected one: the whole pass is gated, not just its
    // hover half.
    immutable int rowC = scanRow(boxes, 2);
    assert(hitsOn(rowC, boxes[2].x0 - 2, boxes[2].x1 + 3, sel).length == 0,
        "the selected-item paint is gated on the Item selection type too");

    // Back through the item door, same cursor, and it lights again.
    cmd(`{"id":"select.item"}`);
    settle();
    assert(hoveredItem() == 1, "the item door restores the item hover");
    assert(hitsOn(row, x0, x1, pre).length >= 3,
        "returning to the Item selection type must light the item under the "
        ~ "cursor again, with no pointer movement");
}
