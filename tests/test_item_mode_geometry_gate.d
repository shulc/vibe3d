// Task 0655 — the selection-type ORDERING is the gate for a viewport pick, and
// `editMode` is not.
//
// ---------------------------------------------------------------------------
// Why the obvious assertion here is worth nothing
// ---------------------------------------------------------------------------
// "In Items mode a vertex was not selected" is satisfied in full by an
// implementation that switched geometry picking off entirely, in every mode,
// and by one that clears the geometry selection on the way into Items. Both are
// worse than the bug. So EVERY flow below asserts both sides of the same
// gesture:
//
//   * under the item type the gesture must not change the geometry selection,
//     AND the geometry selection that was already there must still be there
//     (read back as a VALUE from /api/selection, not as "nothing happened");
//   * the SAME gesture in a geometry type must change it — the control arm. An
//     implementation that turned picking off reddens the control, not the item
//     arm, which is the only way to tell the fix from the amputation.
//
// The drawing half gets the same treatment. "Not drawn" is asserted as a pixel
// census that is ZERO for the selection colour while the item-highlight colour
// at the very same pixels is NON-zero — so a frame that simply failed to render
// cannot pass — and then the type is switched back and the census must return
// to its full value.
//
// THREE ITEMS, not one. With one item "the item under the cursor" and "all of
// them" are the same set, and this area has sprung that trap twice (0647 had to
// rebuild its capture for it). Here the three earn their keep concretely: the
// standing geometry selection lives on the MIDDLE item, and U4 clicks the two
// OTHER items to move the primary away and back, so "the selection is still
// there" is a claim about a selection that survived a primary round trip rather
// than about a document that never moved.
//
// ---------------------------------------------------------------------------
// What is deliberately NOT asserted here
// ---------------------------------------------------------------------------
// The per-frame HOVER pickers share the same one-line gate as the click and the
// band, but under the item type their result is not observable from outside the
// process: `/api/tool/state` publishes `hover.{vertex,edge,face}` only while a
// tool is active (with no tool it serves `{}`), and with a tool active the gate
// under test is bypassed for `wantsHoverForType`. Their only other surface is
// the drawn frame, which the same task also stops drawing — so a pixel reading
// there could not tell the pick gate from the draw gate. Named rather than
// faked with a reading that cannot separate the two.
//
// ---------------------------------------------------------------------------
// VERIFIED BY MUTATION — each applied to a green tree, built, run; the
// assertion named is the one that fired, with the value it OBSERVED.
// ---------------------------------------------------------------------------
//   * the rubber band goes back to `editMode` (the item-inclusive gate on the
//     lasso block removed)
//       -> U2 "under the item type the band must leave the geometry selection
//          alone — [0, 2, 4] became [1, 2, 3, 4, 5, 6, 7]".
//   * the double-click loop/connect goes back to `editMode`
//       -> U3 "under the item type a double-click must leave the geometry
//          selection alone — [0, 2, 4] became [0, 1, 2, 3, 4, 5, 6, 7]".
//   * the vertex-dot pass goes back to `editMode`
//       -> U1(b) "under the item type the selected vertices must not be drawn —
//          vertex 0's 5x5 patch still carries 25 selection-coloured pixels".
//   * geometry picking switched off in EVERY type (the amputation that the
//     one-sided assertion would have let through)
//       -> U2's control "the same band in the vertex type must select — the
//          selection is still [0, 2, 4]" and U3's control likewise.
//   * the selection-feedback gate applied to drawing but the standing selection
//     also cleared on the way into Items
//       -> U1(b) "the geometry selection must SURVIVE the switch — [] ".
//
// TASK 0674 re-verified both drawing rows after the colour compare was changed
// from a frozen byte triple to the quantisation bracket of the source float
// (see `DrawnColour` below), because a widened predicate is exactly the kind of
// repair that quietly stops catching what it was written for:
//   * the vertex-dot pass goes back to `editMode` (the same mutation as above,
//     re-run against the new predicate)
//       -> U1(b) "under the item type the selected vertices must not be drawn —
//          vertex 0's 5x5 patch still carries 25 selection-coloured pixels".
//   * the dot pass paints in the ITEM HIGHLIGHT colour instead of the selection
//     colour — the "both are orange" confusion the exact compare existed to
//     prevent, aimed straight at the widened predicate
//       -> U1(a) "baseline: … carries 0 of 25 selection-coloured pixels.
//          Looking for the selection dot = (255..255, 127..128, 25..26); the
//          patch is mostly (255, 168, 41) (25 of 25)".
import std.net.curl;
import std.json;
import std.format  : format;
import std.math    : round;
import std.algorithm : min, max, map;
import std.array   : array;
import core.thread : Thread;
import core.time   : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, DHVec3 = Vec3;

void main() {}

immutable baseUrl = "http://localhost:8080";

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

private void cmd(string body_) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/command", body_));
    assert(j["status"].str == "ok", "cmd `" ~ body_ ~ "` failed: " ~ j.toString);
}

/// Picks run on the event-playback thread and reads on the HTTP one; a frame
/// between them is what makes the second see the first. The pixel probes need
/// it twice over — a probe reads the last COMPLETED frame.
private void settle() { Thread.sleep(450.msecs); }

// ---------------------------------------------------------------------------
// Reading the app's answer
// ---------------------------------------------------------------------------

/// The PRIMARY layer's selected vertices. `/api/selection` reads the primary's
/// mesh, so this is a question about whichever layer is primary NOW — which is
/// exactly why U4 makes the primary move and come back before reading it.
private int[] selectedVertices() {
    int[] outp;
    foreach (v; getJson("/api/selection")["selectedVertices"].array)
        outp ~= cast(int)v.integer;
    return outp;
}

private string selType()  { return getJson("/api/selection")["selType"].str; }
/// The derived geometry view. It must keep reading a geometry type under Items
/// — that persistence is what makes 1/2/3 restore the previous mode, and it is
/// also precisely why it is the wrong thing for a pick site to read.
private string editModeName() { return getJson("/api/selection")["mode"].str; }
private int primaryIndex() { return cast(int)getJson("/api/layers")["active"].integer; }

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
        // reads zeros, and "the selection colour is absent" would then pass for
        // the wrong reason. Assert the flag rather than trusting the default.
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

/// The two colours this file reads back — declared as the FLOATS the draw
/// passes hand to GL, NOT as the bytes one machine's GL happened to store.
///
/// Both are written by a `glUniform3f` with no lighting, no blending and no
/// anti-aliasing on the pass that carries them, and the FBO applies no gamma.
/// What that buys is an exact statement about the FLOAT; it does not buy an
/// exact statement about the byte. The framebuffer stores `round(f * 255)`,
/// and where `f * 255` lands exactly halfway between two integers the
/// direction of that rounding is the implementation's to choose. Two of the
/// selection dot's three channels are exactly that: `0.5 * 255 = 127.5` and
/// `0.1 * 255 = 25.5`.
///
/// MEASURED, same binary, same rig, same frame, two GLs: a discrete GPU stores
/// (255, 127, 25) and a software rasteriser stores (255, 128, 26). This file
/// used to freeze the first pair, which made it a claim about the machine that
/// wrote it. Everywhere else the census then counted ZERO selection-coloured
/// pixels at a vertex that had been drawn, correctly and in full — reporting a
/// live defect in the words of the defect it exists to catch, which is the
/// worst failure a test can have.
///
/// So a channel is matched against the two integers that BRACKET `f * 255`,
/// and nothing wider. Where the product is exact (red: `1.0 * 255 = 255`) that
/// is one value and the compare stays as tight as it ever was; where it is a
/// tie it admits the single count that is genuinely undecided, and no more.
/// The point of the old exactness is kept by `static assert` below rather than
/// by luck: the two are both orange, and a predicate that could not tell them
/// apart would pass the very bug under test.
private struct DrawnColour {
    string   name;
    float[3] rgb;

    /// The lowest / highest byte a conformant GL may store for channel `c`.
    /// Equal when `rgb[c] * 255` is an integer — then this is an exact compare.
    int lo(size_t c) const { return cast(int)(rgb[c] * 255.0f); }
    int hi(size_t c) const {
        immutable float exact = rgb[c] * 255.0f;
        immutable int   t     = cast(int)exact;
        return (cast(float)t == exact) ? t : t + 1;
    }

    bool matches(Px p) const {
        if (!p.valid) return false;
        immutable int[3] v = [p.r, p.g, p.b];
        foreach (c; 0 .. 3) if (v[c] < lo(c) || v[c] > hi(c)) return false;
        return true;
    }

    /// For failure messages: what this predicate would have accepted.
    string spell() const {
        return format("%s = (%d..%d, %d..%d, %d..%d)", name,
                      lo(0), hi(0), lo(1), hi(1), lo(2), hi(2));
    }
}

private enum DrawnColour kSelectedVertexDot =
    DrawnColour("the selection dot",  [1.0f, 0.5f,  0.1f ]);  // mesh_gpu.d
private enum DrawnColour kItemHighlight =
    DrawnColour("the item highlight", [1.0f, 0.66f, 0.16f]);  // viewport_scheme.d

/// The census means nothing unless the two colours stay TELLABLE APART under
/// the widened predicate. They part company on green — and they must part by
/// more than the quantisation slack, or "0 selection-coloured pixels while the
/// item highlight is present" degenerates into a statement about one colour
/// counted twice. Checked at compile time so a re-theme that brought the two
/// within a count of each other fails here, loudly, instead of quietly turning
/// every drawing row below into a tautology.
static assert(kSelectedVertexDot.hi(1) < kItemHighlight.lo(1) - 1,
    "the selection dot and the item highlight are no longer separable on the "
    ~ "green channel; the pixel census below can no longer tell them apart");

/// How many pixels of a 5x5 patch centred on `p` carry `want`.
///
/// A patch, not a pixel: the dot is a 10-px GL point, so a 5x5 window centred
/// on the projected vertex is entirely inside it — the count is 25 or it is 0,
/// with no third answer for a rounding disagreement to hide in.
private int patchCount(int[2] p, DrawnColour want) {
    int[2][] pts;
    foreach (dy; -2 .. 3) foreach (dx; -2 .. 3) pts ~= [p[0] + dx, p[1] + dy];
    int n = 0;
    foreach (v; probe(pts))
        if (want.matches(v)) ++n;
    return n;
}

/// What the patch actually carries, for a failure message.
///
/// A census that reads zero is otherwise mute about WHY, and the candidates are
/// three different bugs: the pixels are background (nothing was drawn there),
/// they are some other pass's colour (the wrong thing was drawn), or they are
/// the right colour a count away (the predicate, not the frame, is wrong). The
/// last of those is what sent this file to CI red for a day and read exactly
/// like the first. Naming the majority colour separates them in the message.
private string patchSpell(int[2] p) {
    int[2][] pts;
    foreach (dy; -2 .. 3) foreach (dx; -2 .. 3) pts ~= [p[0] + dx, p[1] + dy];
    int[string] tally;
    int invalid = 0;
    foreach (v; probe(pts)) {
        if (!v.valid) { ++invalid; continue; }
        ++tally[format("(%d, %d, %d)", v.r, v.g, v.b)];
    }
    string best; int bestN = 0;
    foreach (k, n; tally) if (n > bestN) { best = k; bestN = n; }
    if (bestN == 0) return format("%d of 25 pixels could not be read at all", invalid);
    return format("the patch is mostly %s (%d of 25)%s", best, bestN,
                  invalid ? format(", %d unreadable", invalid) : "");
}

// ---------------------------------------------------------------------------
// Gestures
// ---------------------------------------------------------------------------

private enum string kViewportLine =
    `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,` ~
    `"fovY":0.785398}`;

private struct Cell { int vx, vy, vw, vh; }

private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int)c["vpX"].integer,  cast(int)c["vpY"].integer,
                cast(int)c["width"].integer, cast(int)c["height"].integer);
}

private string header(Cell c) {
    return format(kViewportLine, c.vx, c.vy, c.vw, c.vh) ~ "\n";
}

/// Park the pointer well clear of every item, so no vertex is HOVERED while
/// the pixels are read. The hover colour is a third value and would otherwise
/// turn one probed vertex into a silent exception to the census.
private void parkPointer(Cell c) {
    string log = header(c);
    foreach (i; 0 .. 2)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,`
                      ~ `"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                      30.0 + i * 30.0, c.vx + 12, c.vy + c.vh - 12);
    playAndWait(log);
    settle();
}

/// A full LMB click at a WINDOW pixel; `clicks` carries SDL's click counter, so
/// `clicks = 2` is the double-click the loop/connect path keys on.
private void clickAt(Cell c, int wx, int wy, int clicks = 1) {
    string log = header(c);
    foreach (i; 0 .. 3)
        log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,`
                      ~ `"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                      30.0 + i * 10.0, wx, wy);
    log ~= format(`{"t":80.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,`
                  ~ `"y":%d,"clicks":%d,"mod":0}` ~ "\n", wx, wy, clicks);
    log ~= format(`{"t":120.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,`
                  ~ `"y":%d,"clicks":%d,"mod":0}` ~ "\n", wx, wy, clicks);
    playAndWait(log);
    settle();
}

/// An RMB rubber band around the rectangle `[x0,x1] x [y0,y1]`, traced corner
/// to corner with intermediate motions so `rmbPath` is a real polygon and not
/// four points the app could reject for being too short.
private void bandAround(Cell c, int x0, int y0, int x1, int y1) {
    immutable int[2][5] corners =
        [[x0, y0], [x1, y0], [x1, y1], [x0, y1], [x0, y0 + 2]];
    string log = header(c);
    double t = 30.0;
    log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,`
                  ~ `"yrel":0,"state":0,"mod":0}` ~ "\n",
                  t, corners[0][0], corners[0][1]);
    t += 30.0;
    log ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONDOWN","btn":3,"x":%d,`
                  ~ `"y":%d,"clicks":1,"mod":0}` ~ "\n",
                  t, corners[0][0], corners[0][1]);
    t += 30.0;
    int[2] prev = corners[0];
    foreach (ci; 1 .. corners.length) {
        immutable int[2] p = corners[ci];
        foreach (k; 1 .. 7) {
            immutable int x = prev[0] + cast(int)((p[0] - prev[0]) * k / 6.0);
            immutable int y = prev[1] + cast(int)((p[1] - prev[1]) * k / 6.0);
            log ~= format(`{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,`
                          ~ `"xrel":0,"yrel":0,"state":4,"mod":0}` ~ "\n", t, x, y);
            t += 20.0;
        }
        prev = p;
    }
    log ~= format(`{"t":%.3f,"type":"SDL_MOUSEBUTTONUP","btn":3,"x":%d,"y":%d,`
                  ~ `"clicks":1,"mod":0}` ~ "\n", t, prev[0], prev[1]);
    playAndWait(log);
    settle();
}

// ---------------------------------------------------------------------------
// The rig
// ---------------------------------------------------------------------------

private struct Box {
    int x0, y0, x1, y1;                 ///< WINDOW pixels
    int cx() const { return (x0 + x1) / 2; }
    int cy() const { return (y0 + y1) / 2; }
    bool disjointFrom(const Box o) const {
        return x1 < o.x0 || o.x1 < x0 || y1 < o.y0 || o.y1 < y0;
    }
}

/// Three unit cubes spread along X, seen three-quarter on, with the MIDDLE one
/// primary and a standing three-vertex selection on it.
///
/// The middle one is deliberate: `layer.duplicate` leaves the LAST layer
/// primary, so index 1 is neither an end of the array nor the layer the
/// document handed us — "the first", "the last" and "the one that was already
/// primary" are three distinct wrong answers with three distinct readings.
///
/// The middle layer is left at the origin, so its local mesh coordinates are
/// its world coordinates and the vertex projections below need no item
/// transform composed into them.
private enum int[] kStanding = [0, 2, 4];

private void buildRig() {
    auto r0 = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(r0["status"].str == "ok", "/api/reset failed: " ~ r0.toString);
    cmd(`{"id":"history.clear"}`);
    cmd(`{"id":"layer.duplicate"}`);
    cmd(`{"id":"layer.duplicate"}`);
    cmd("layer.attr 0 pos.x -4");
    cmd("layer.attr 2 pos.x 4");
    post(baseUrl ~ "/api/camera?viewport=0", `{"distance":12.0}`);
    cmd(`{"id":"layer.select","index":1,"mode":"set"}`);
    // The standing geometry selection, made through a COMMAND rather than a
    // click: the click path is one of the things under test, and a rig that
    // built its own precondition with it could not then say anything about it.
    cmd("select.typeFrom vertex");
    cmd(format("select.element vertex set %(%d %)", kStanding));
    settle();
    assert(primaryIndex() == 1,
        format("rig: the middle item must be primary — the app reports %d",
               primaryIndex()));
    assert(selectedVertices() == kStanding,
        format("rig: the standing vertex selection must be %s — got %s",
               kStanding, selectedVertices()));
}

/// Where each item's cube lands on screen, and where the primary's individual
/// vertices land, computed from the live camera through the projection every
/// drag test uses — so a different window size moves the probes with it and no
/// pixel below is a magic number.
private struct Rig {
    Box[]    boxes;         ///< one per layer, WINDOW pixels
    int[2][] vertFbo;       ///< the primary's 8 vertices, FBO pixels
}

private Rig readRig() {
    auto layers = getJson("/api/layers")["layers"].array;
    auto camS   = fetchCamera(baseUrl);
    auto vp     = viewportFromCamera(camS);
    auto verts  = getJson("/api/model")["vertices"].array;

    Rig rig;
    foreach (li, l; layers) {
        auto pos = l["xform"]["pos"].array;
        Box b;
        b.x0 = int.max; b.y0 = int.max; b.x1 = int.min; b.y1 = int.min;
        foreach (v; verts) {
            auto world = DHVec3(
                cast(float)(v.array[0].floating + pos[0].floating),
                cast(float)(v.array[1].floating + pos[1].floating),
                cast(float)(v.array[2].floating + pos[2].floating));
            float px, py;
            assert(projectToWindow(world, vp, px, py),
                format("rig: item %d has a corner behind the camera", li));
            immutable int fx = cast(int)round(px);
            immutable int fy = cast(int)round(py);
            b.x0 = min(b.x0, fx); b.x1 = max(b.x1, fx);
            b.y0 = min(b.y0, fy); b.y1 = max(b.y1, fy);
            if (li == 1) rig.vertFbo ~= [fx - camS.vpX, fy - camS.vpY];
        }
        rig.boxes ~= b;
    }
    return rig;
}

/// The rig decides something only if the three items are separable on screen
/// and the primary's vertices sit far enough inside the cell for a 5x5 patch.
private void assertRigSane(const ref Rig rig, Cell c) {
    foreach (i; 0 .. rig.boxes.length)
        foreach (j; i + 1 .. rig.boxes.length)
            assert(rig.boxes[i].disjointFrom(rig.boxes[j]),
                format("rig: items %d and %d overlap on screen — with "
                       ~ "overlapping footprints 'the cursor is over that one "
                       ~ "and not these two' is not a claim this rig can make",
                       i, j));
    foreach (vi, p; rig.vertFbo)
        assert(p[0] >= 3 && p[1] >= 3 && p[0] < c.vw - 3 && p[1] < c.vh - 3,
            format("rig: the primary's vertex %d projects to FBO (%d, %d), "
                   ~ "too close to the %dx%d cell edge for a 5x5 patch",
                   vi, p[0], p[1], c.vw, c.vh));
}

// ---------------------------------------------------------------------------
// U1 — the standing geometry selection is KEPT under the item type and NOT
//      DRAWN, and switching back shows the same selection, drawn again.
//
// The two halves are the whole point. "Not drawn" alone is satisfied by
// clearing the selection on entry; "kept" alone is satisfied by drawing it
// anyway. The census is taken three times over the SAME pixels so the third
// reading is a return to the first, not a fresh claim.
// ---------------------------------------------------------------------------
unittest {
    buildRig();
    auto c   = cell();
    auto rig = readRig();
    assertRigSane(rig, c);
    parkPointer(c);

    // ---- (a) the baseline: in the vertex type the selected dots are there and
    //      the unselected ones are not, so the census can tell them apart at
    //      all. Vertex 1 is the control — an unselected corner of the same cube.
    foreach (vi; kStanding)
        assert(patchCount(rig.vertFbo[vi], kSelectedVertexDot) == 25,
            format("baseline: in the vertex type the selected vertex %d must be "
                   ~ "drawn as a selection dot — its 5x5 patch carries %d of 25 "
                   ~ "selection-coloured pixels. Looking for %s; %s",
                   vi, patchCount(rig.vertFbo[vi], kSelectedVertexDot),
                   kSelectedVertexDot.spell(), patchSpell(rig.vertFbo[vi])));
    assert(patchCount(rig.vertFbo[1], kSelectedVertexDot) == 0,
        format("baseline: vertex 1 is NOT selected, so its patch must carry no "
               ~ "selection colour — it carries %d, which would make the census "
               ~ "unable to distinguish selected from not",
               patchCount(rig.vertFbo[1], kSelectedVertexDot)));

    // ---- (b) under the item type: kept, and not drawn.
    cmd("select.typeFrom item");
    settle();
    assert(selType() == "item", "the item door must make the item type current");
    assert(editModeName() == "vertices",
        format("the derived geometry view must still read the last geometry "
               ~ "type — it reads %s. If it did not, the gate under test would "
               ~ "be indistinguishable from reading it", editModeName()));
    assert(selectedVertices() == kStanding,
        format("the geometry selection must SURVIVE the switch into the item "
               ~ "type — %s became %s", kStanding, selectedVertices()));
    foreach (vi; kStanding) {
        immutable int sel  = patchCount(rig.vertFbo[vi], kSelectedVertexDot);
        immutable int item = patchCount(rig.vertFbo[vi], kItemHighlight);
        assert(sel == 0,
            format("under the item type the selected vertices must not be "
                   ~ "drawn — vertex %d's 5x5 patch still carries %d "
                   ~ "selection-coloured pixels", vi, sel));
        // The same pixels must carry the ITEM highlight, which is what makes
        // the zero above a statement about this pass rather than about a frame
        // that never rendered.
        assert(item > 0,
            format("the frame must still be drawing the item at vertex %d's "
                   ~ "pixels — its patch carries %d item-highlight pixels, so "
                   ~ "the zero above says nothing. Looking for %s; %s",
                   vi, item, kItemHighlight.spell(), patchSpell(rig.vertFbo[vi])));
    }

    // ---- (c) back to the vertex type: the same selection, drawn again.
    cmd("select.typeFrom vertex");
    settle();
    assert(selectedVertices() == kStanding,
        format("coming back to the vertex type must show the SAME selection — "
               ~ "%s became %s", kStanding, selectedVertices()));
    foreach (vi; kStanding)
        assert(patchCount(rig.vertFbo[vi], kSelectedVertexDot) == 25,
            format("coming back must draw it again — vertex %d's patch carries "
                   ~ "%d of 25 selection-coloured pixels. Looking for %s; %s",
                   vi, patchCount(rig.vertFbo[vi], kSelectedVertexDot),
                   kSelectedVertexDot.spell(), patchSpell(rig.vertFbo[vi])));
}

// ---------------------------------------------------------------------------
// U2 — the RUBBER BAND. A viewport pick that never went through the click
//      branch 0643 added, so it is the site that shows the gate is the
//      ordering rather than a special case bolted in front of one path.
// ---------------------------------------------------------------------------
unittest {
    buildRig();
    auto c   = cell();
    auto rig = readRig();
    assertRigSane(rig, c);
    immutable Box mid = rig.boxes[1];
    // A band comfortably around the middle cube only.
    immutable int bx0 = mid.x0 - 27, bx1 = mid.x1 + 28;
    immutable int by0 = mid.y0 - 22, by1 = mid.y1 + 29;

    // ---- under the item type: the band changes nothing.
    cmd("select.typeFrom item");
    settle();
    bandAround(c, bx0, by0, bx1, by1);
    assert(selectedVertices() == kStanding,
        format("under the item type the band must leave the geometry selection "
               ~ "alone — %s became %s", kStanding, selectedVertices()));
    assert(selType() == "item",
        format("…and must not promote a geometry type either — the current "
               ~ "type is now %s", selType()));

    // ---- the CONTROL: the same band in the vertex type DOES select. Without
    //      this arm, switching geometry picking off entirely passes the flow.
    cmd("select.typeFrom vertex");
    settle();
    bandAround(c, bx0, by0, bx1, by1);
    auto after = selectedVertices();
    assert(after != kStanding && after.length > 0,
        format("the same band in the vertex type must select — the selection is "
               ~ "still %s, so the item-type arm above proves nothing", after));
}

// ---------------------------------------------------------------------------
// U3 — the DOUBLE-CLICK (loop / connect). The third pick site, and the one
//      whose mutation is largest: on a cube it takes a three-vertex selection
//      to all eight.
// ---------------------------------------------------------------------------
unittest {
    buildRig();
    auto c   = cell();
    auto rig = readRig();
    assertRigSane(rig, c);

    cmd("select.typeFrom item");
    settle();
    clickAt(c, rig.boxes[1].cx, rig.boxes[1].cy, /*clicks=*/2);
    assert(selectedVertices() == kStanding,
        format("under the item type a double-click must leave the geometry "
               ~ "selection alone — %s became %s",
               kStanding, selectedVertices()));

    // The control, same gesture, geometry type: connect expands to the whole
    // connected component.
    cmd("select.typeFrom vertex");
    settle();
    clickAt(c, rig.boxes[1].cx, rig.boxes[1].cy, /*clicks=*/2);
    assert(selectedVertices().length == 8,
        format("the same double-click in the vertex type must expand the "
               ~ "selection to the connected component — got %s",
               selectedVertices()));
}

// ---------------------------------------------------------------------------
// U4 — the selection survives a PRIMARY ROUND TRIP under the item type.
//
// This is where three items stop being decoration. Clicking item 0 moves the
// primary off the layer that holds the geometry selection; clicking item 1
// brings it back. `/api/selection` reads the PRIMARY's mesh, so "still there"
// is only a real claim once the primary has actually left and returned — and
// the intermediate reading (item 0's own, empty selection) is asserted too, so
// a document that never moved the primary cannot pass this flow either.
// ---------------------------------------------------------------------------
unittest {
    buildRig();
    auto c   = cell();
    auto rig = readRig();
    assertRigSane(rig, c);

    cmd("select.typeFrom item");
    settle();

    clickAt(c, rig.boxes[0].cx, rig.boxes[0].cy);
    assert(primaryIndex() == 0,
        format("the click on item 0 must make it primary — the app reports %d",
               primaryIndex()));
    assert(selectedVertices().length == 0,
        format("item 0 carries no geometry selection of its own — reading %s "
               ~ "here would mean /api/selection is not following the primary",
               selectedVertices()));

    clickAt(c, rig.boxes[2].cx, rig.boxes[2].cy);
    assert(primaryIndex() == 2,
        format("the click on item 2 must make it primary — the app reports %d",
               primaryIndex()));

    clickAt(c, rig.boxes[1].cx, rig.boxes[1].cy);
    assert(primaryIndex() == 1,
        format("the click back on item 1 must restore it as primary — the app "
               ~ "reports %d", primaryIndex()));
    assert(selectedVertices() == kStanding,
        format("the middle item's geometry selection must have survived the "
               ~ "whole round trip — %s became %s",
               kStanding, selectedVertices()));

    // …and it is drawn again the moment the geometry type comes back.
    cmd("select.typeFrom vertex");
    settle();
    foreach (vi; kStanding)
        assert(patchCount(rig.vertFbo[vi], kSelectedVertexDot) == 25,
            format("after the round trip vertex %d must be drawn selected "
                   ~ "again — its patch carries %d of 25",
                   vi, patchCount(rig.vertFbo[vi], kSelectedVertexDot)));
}

// ---------------------------------------------------------------------------
// U5 — the BETWEEN-TEST BASELINE has to restore the pick type, not just the
//      pick mode, and the very next gesture has to pick again.
//
// This task moved the gate off `editMode`, and in doing so it split one
// observable into two. `/api/selection` reports `mode` (the derived geometry
// view) and `selType` (the ordering front — the gate). Under the item type
// `mode` still reads "vertices"; U1 asserts that persistence, and it is
// deliberate. The consequence is a state that reads completely clean and is
// not: measured on a live instance, `/api/model` gives the pristine 8-vertex
// cube with v6 = (0.5, 0.5, 0.5), `/api/selection` gives mode "vertices" with
// all three selection arrays empty — and `selType` is "item", so every
// viewport pick site declines. That is exactly the tuple `run_test.d`'s
// `resetBetweenTests` verifies before handing a shared `--test` instance to the
// next test binary in a worker's slice, which is how a stale pick type would
// travel between tests without anything being able to see it.
//
// So this flow is an ordered PAIR inside one process, and its second half is a
// real gesture rather than a field read: `selType() == "vertex"` is a claim
// about a string, the click is the claim about the gate. The control arm
// measures the click's answer from a clean start in this same process at this
// same camera, so "picks again" is compared against a value this rig observed
// rather than a constant written down.
//
// Both doors into the item type are driven. `layer.select`'s promote hook and
// the deliberate `select.typeFrom item` door are different code, and a reset
// that cleared one and not the other is representable.
// ---------------------------------------------------------------------------

/// A clean single-cube scene with an empty undo stack — what `/api/reset`
/// yields between test binaries.
private void freshCube() {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
    assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
    cmd(`{"id":"history.clear"}`);
    settle();
}

/// The cube corner NEAREST the eye, and where it lands in WINDOW pixels.
///
/// Nearest, not arbitrary: the pick runs against a depth-tested ID buffer, so a
/// far corner sits behind the cube's own faces and a click there would answer
/// "nothing" for a reason that has nothing to do with this flow.
private void nearestVertexPx(out int vi, out int wx, out int wy) {
    auto eye   = getJson("/api/camera")["eye"];
    immutable double ex = eye["x"].floating;
    immutable double ey = eye["y"].floating;
    immutable double ez = eye["z"].floating;
    auto vp    = viewportFromCamera(fetchCamera(baseUrl));
    auto verts = getJson("/api/model")["vertices"].array;
    double best = double.max;
    vi = -1;
    foreach (i, v; verts) {
        immutable double dx = v.array[0].floating - ex;
        immutable double dy = v.array[1].floating - ey;
        immutable double dz = v.array[2].floating - ez;
        immutable double d2 = dx * dx + dy * dy + dz * dz;
        if (d2 >= best) continue;
        float px, py;
        if (!projectToWindow(DHVec3(cast(float)v.array[0].floating,
                                    cast(float)v.array[1].floating,
                                    cast(float)v.array[2].floating),
                             vp, px, py)) continue;
        best = d2;
        vi   = cast(int)i;
        wx   = cast(int)round(px);
        wy   = cast(int)round(py);
    }
    assert(vi >= 0, "no cube corner projects on-camera at the reset camera");
}

unittest {
    foreach (route; ["door", "layer"]) {
        // ---- the CONTROL, measured here: from a clean start a click at P
        //      selects exactly one vertex, and this is which one.
        freshCube();
        int vi, px, py;
        nearestVertexPx(vi, px, py);
        auto c = cell();
        assert(px - c.vx >= 4 && py - c.vy >= 4
            && px - c.vx < c.vw - 4 && py - c.vy < c.vh - 4,
            format("rig: the nearest corner projects to window (%d, %d), not "
                   ~ "comfortably inside the %dx%d cell at (%d, %d)",
                   px, py, c.vw, c.vh, c.vx, c.vy));
        clickAt(c, px, py);
        auto control = selectedVertices();
        assert(control == [vi],
            format("control (%s): a click at the nearest corner must select "
                   ~ "vertex %d — it selected %s", route, vi, control));

        // ---- the PAIR: enter the item type, then take exactly the reset the
        //      runner takes between test binaries, then repeat that click.
        freshCube();
        if (route == "door") cmd("select.typeFrom item");
        else                 cmd(`{"id":"layer.select","index":0,"mode":"set"}`);
        settle();
        assert(selType() == "item",
            format("%s: this route must make the item type current — it is %s",
                   route, selType()));
        // THE BLIND SPOT, as a value. This is the exact tuple a baseline check
        // written against `mode` reads, and every field of it says "clean"
        // while the gate says otherwise. Asserted here rather than described,
        // because it is the reason the reset below has a job to do.
        assert(editModeName() == "vertices" && selectedVertices().length == 0,
            format("%s: the item type must leave the derived view reading "
                   ~ `"vertices" with an empty geometry selection — it reads `
                   ~ "%s / %s, and if it did not, a `mode`-only baseline check "
                   ~ "would already be able to see this state",
                   route, editModeName(), selectedVertices()));

        auto r = parseJSON(cast(string)post(baseUrl ~ "/api/reset", ""));
        assert(r["status"].str == "ok", "/api/reset failed: " ~ r.toString);
        settle();

        // (a) the gate's own input.
        assert(selType() == "vertex",
            format("%s: the reset must return the ordering front to a geometry "
                   ~ "type — it is %s, and every pick site in whatever runs "
                   ~ "next would decline", route, selType()));
        // (b) …and why (a) has to be spelled out at all: the field a `mode`-only
        //     baseline check reads is "vertices" in BOTH states.
        assert(editModeName() == "vertices",
            format("%s: the derived geometry view reads %s — it reads "
                   ~ `"vertices" under the item type too, which is exactly why `
                   ~ "the assertion above is about selType and not about it",
                   route, editModeName()));

        // (c) the gate itself. The reset restores the camera, so the same pixel
        //     is the same click — asserted, not assumed.
        int vi2, px2, py2;
        nearestVertexPx(vi2, px2, py2);
        assert(vi2 == vi && px2 == px && py2 == py,
            format("%s: the reset must restore the camera or the two clicks are "
                   ~ "not the same click — corner %d at (%d, %d) became corner "
                   ~ "%d at (%d, %d)", route, vi, px, py, vi2, px2, py2));
        clickAt(cell(), px, py);
        assert(selectedVertices() == control,
            format("%s: after the reset the next click must pick exactly what "
                   ~ "it picks from a clean start — expected %s, got %s",
                   route, control, selectedVertices()));
    }
}
