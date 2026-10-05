// test_gizmo_plane_handle.d — the plane handle is TWO circles, not one, and a
// grab makes its inner disc opaque. Plus the one bank that could not reach the
// grabbed state at all.
//
// WHAT IS PINNED HERE, AND WHY IT NEEDED A NEW FILE.
// tests/test_gizmo_handle_colours.d pins the colour LAW; test_gizmo_hover_
// highlight.d pins that hover reaches the framebuffer and that the ring keeps
// its axis colour under a grab. Neither can see SIZE. Our plane handle drew
// its filled disc at the outline ring's own radius, so the two elements were
// one blob distinguishable only by alpha, and every colour assertion in the
// suite passed throughout. This file measures the two radii against each
// other.
//
//   * the outer RING is the handle's stated size (8 window px);
//   * the inner FILL is 0.8 of it (6.4 px), and the gap between them is what
//     makes the handle read as a ring around a hole rather than as a dot;
//   * a GRAB takes the fill to alpha 1.0 — the only opaque thing the plane
//     handle ever draws — while the ring keeps its axis colour. Hover does
//     neither: it only recolours.
//
// HOW THE RADII ARE MEASURED WITHOUT KNOWING WHERE THE HANDLE IS.
// Purely differentially, from three probes of ONE point list:
//
//   idle -> hover     changes the ring AND the disc  (both recolour)
//   idle -> grabbed   changes the disc only          (the ring is unchanged)
//
// so the grab-changed set is the DISC and the hover-only remainder is the
// RING. Comparing their radial extents needs no screen radius, no projection
// maths and no assumption about which way the ellipse leans: both elements are
// concentric circles in the same plane, so they foreshorten by the same factor
// along any given screen direction and their RATIO survives the projection.
// That ratio is the assertion. A fill drawn at the ring's radius gives ~1.0
// and fails; 0.8 does not.
//
// THE ALPHA IS BRACKETED FROM BOTH SIDES, per this suite's standing rule that
// a composite match alone does not pin an alpha. At 1.0 a stroke leaves the
// blending path entirely and every covered pixel reads the RAW colour; at 0.2
// no pixel can. So "grabbed has raw-colour pixels" and "idle and hovered have
// none" together fail a move in either direction.
//
// FLOW C is a different defect on the same theme: the scale bank called
// `suppress()` where move and rotate name their hauled part, so its handle lit
// under the pointer and went dark at the moment you grabbed it. The colour law
// was reached; it was fed the wrong input. Measured for that bank, its grabbed
// state is the active colour — the same as hover — so the assertion is that
// press paints exactly what hover paints.
//
// VERIFIED BY MUTATION. Each was applied to a green tree, built and run; the
// assertion named is the one that actually fired.
//   * `GIZMO_PLANE_FILL_RATIO` 0.8 -> 1.0, i.e. the disc as it used to be drawn
//        -> Flow A, "the fill must sit INSIDE the ring: fill reaches 9.0 px,
//           ring reaches 9.0 px, ratio 1.000".
//   * `GIZMO_ALPHA_PLANE_FILL_GRABBED` 1.0 -> 0.2, i.e. the grab raises nothing
//        -> Flow B, "a grabbed fill must read the RAW active colour — only 0
//           pixels did".
//   * the grabbed alpha applied on HOVER as well (`paint != idle`)
//        -> Flow B, "a hovered fill recolours but does NOT change alpha, so it
//           cannot read the raw active colour either (154 pixels did)". This is
//           the half that keeps the two mechanisms apart.
//   * `setHaul(SCALE_BASE + dragAxis)` reverted to `suppress()`
//        -> Flow C, "the scale bank must publish its hauled part like every
//           other bank".

import http_client : getJson, postRaw, testBaseUrl;
import std.format : format;
import std.json;
import std.math : abs, sqrt;
import std.net.curl : get, post;

import drag_helpers : playAndWait;

void main() {}

alias baseUrl = testBaseUrl;

private enum int MOVE_BASE = 0, SCALE_BASE = 20;
// The XY plane handle (normal Z) — at the default camera it is the most
// nearly face-on of the three, which is what leaves its ring and disc room to
// be told apart on a pixel grid.
private enum int P_PLANE_XY = MOVE_BASE + 4;
private enum int P_SCALE_X  = SCALE_BASE + 0;

// The scheme restated as 8-bit literals, on this suite's convention (a drift
// in the table has to be acknowledged here too). round(255 * c).
private enum int[3] RGB_ACTIVE = [255, 230, 102];   // 1.0, 0.9, 0.4

// Software GL rounds the last bit differently across drivers; 3/255 is byte
// slop, not a shading tolerance.
private enum int SLOP = 3;

private void script(string line) {
    auto r = parseJSON(cast(string)post(baseUrl ~ "/api/script", line));
    assert(r["status"].str == "ok", "script failed: " ~ line ~ " -> " ~ r.toString);
}

private double num(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    switch (cur.type) {
        case JSONType.float_:   return cur.floating;
        case JSONType.integer:  return cast(double)cur.integer;
        case JSONType.uinteger: return cast(double)cur.uinteger;
        default: throw new Exception("not a number at ." ~ path[$ - 1]);
    }
}

private struct Cell { int vx, vy, vw, vh; }
private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int)num(c, "vpX"),   cast(int)num(c, "vpY"),
                cast(int)num(c, "width"), cast(int)num(c, "height"));
}

private string logHeader(Cell c) {
    return format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n", c.vx, c.vy, c.vw, c.vh);
}

// The player's mouse override is never cleared, so a log that ends on a motion
// leaves the pointer parked and every later frame hovered; one that ends on a
// button-down leaves the capture live across the probe that follows.
private void hoverAt(int x, int y) {
    auto c = cell();
    string log = logHeader(c);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
            ~ "\n", 50.0 + i * 20.0, x, y);
    playAndWait(log);
}
private void pressAt(int x, int y) {
    auto c = cell();
    playAndWait(logHeader(c) ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
        ~ "\n", x, y));
}
private void releaseAt(int x, int y) {
    auto c = cell();
    playAndWait(logHeader(c) ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
        ~ "\n", x, y));
}

private struct Anchor { int x, y; bool visible; }
private Anchor anchor(int part) {
    auto h = getJson("/api/tool/handles")["handles"];
    foreach (p; h["parts"].array) {
        if (cast(int)num(p, "part") != part) continue;
        Anchor a;
        a.visible = p["visible"].type == JSONType.TRUE;
        a.x = cast(int)(p["screen"].array[0].floating + 0.5);
        a.y = cast(int)(p["screen"].array[1].floating + 0.5);
        return a;
    }
    assert(false, format("part %d is not registered", part));
}
private int capturedPart() {
    return cast(int)num(getJson("/api/tool/handles")["handles"], "captured");
}

private struct Px { int x, y, r, g, b; bool valid; }

private Px[] probe(const int[2][] winPts) {
    auto c = cell();
    Px[] outp;
    for (size_t i = 0; i < winPts.length; i += 60) {
        auto slice = winPts[i .. (i + 60 > winPts.length ? winPts.length : i + 60)];
        string q = "/api/viewport/probe?points=";
        foreach (k, p; slice) {
            if (k) q ~= ";";
            q ~= format("%d,%d", p[0] - c.vx, p[1] - c.vy);
        }
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        // The --test single-rendered-cell trap: an unfilled FBO reads zeros and
        // every assertion below would fail for the WRONG reason.
        assert(j["renders"].type == JSONType.TRUE,
               "the probed cell is not rendered under --test; the reading is void");
        foreach (k, e; j["points"].array) {
            Px p;
            p.x = slice[k][0];
            p.y = slice[k][1];
            if ("error" in e) { outp ~= p; continue; }
            p.r = cast(int)num(e, "r");
            p.g = cast(int)num(e, "g");
            p.b = cast(int)num(e, "b");
            p.valid = true;
            outp ~= p;
        }
    }
    return outp;
}

// Indices into a shared point list whose colour differs between two readings.
private bool[size_t] changed(const Px[] a, const Px[] b) {
    bool[size_t] s;
    foreach (i; 0 .. a.length)
        if (a[i].valid && b[i].valid
            && (a[i].r != b[i].r || a[i].g != b[i].g || a[i].b != b[i].b))
            s[i] = true;
    return s;
}

private bool isColor(Px p, const int[3] want) {
    return p.valid && abs(p.r - want[0]) <= SLOP
                   && abs(p.g - want[1]) <= SLOP
                   && abs(p.b - want[2]) <= SLOP;
}

private void armMove() {
    script("tool.set move on");
    postRaw("/api/camera", `{"azimuth":0.5,"elevation":0.4,"distance":3.0}`);
}

// Somewhere the gizmo certainly is not, for the idle reading.
private enum int PARK_X = 200, PARK_Y = 60;

// ---------------------------------------------------------------------------
// Flow A — two concentric circles, and the fill is the smaller one
// ---------------------------------------------------------------------------

unittest {
    armMove();
    scope(exit) { script("tool.set move off"); hoverAt(PARK_X, PARK_Y); }

    auto a = anchor(P_PLANE_XY);
    assert(a.visible, "fixture premise: the XY plane handle must be drawn here");

    // A cross through the handle's published centre, 14 px each way. Wide
    // enough to contain an 8 px ring and its antialiasing, narrow enough that
    // nothing else on the gizmo reaches it (the nearest arm tip is ~90 px off).
    enum int REACH = 14;
    int[2][] pts;
    foreach (d; -REACH .. REACH + 1) pts ~= [a.x + d, a.y];
    foreach (d; -REACH .. REACH + 1) pts ~= [a.x, a.y + d];

    hoverAt(PARK_X, PARK_Y);        auto idle = probe(pts);
    hoverAt(a.x, a.y);              auto hov  = probe(pts);
    assert(anchor(P_PLANE_XY).visible, "the handle must survive being hovered");
    pressAt(a.x, a.y);
    assert(capturedPart() == P_PLANE_XY,
           "premise: the press must capture the plane handle, not something under it");
    auto grab = probe(pts);
    releaseAt(a.x, a.y);

    auto dHover = changed(idle, hov);
    auto dGrab  = changed(idle, grab);

    assert(dHover.length > 8,
           format("premise: hovering the handle must repaint it (%d pixels changed)",
                  dHover.length));
    assert(dGrab.length > 4,
           format("premise: grabbing the handle must repaint its disc (%d pixels changed)",
                  dGrab.length));

    // The ring keeps its axis colour under a grab, so every grab-changed pixel
    // is a disc pixel and the hover-only remainder is the ring. (The strict
    // superset itself is test_gizmo_hover_highlight.d's Flow B; here it is the
    // premise that makes the radii below mean what they say.)
    foreach (i; dGrab.byKey)
        assert(i in dHover,
               "premise: a grab may not change a pixel a hover leaves alone");

    double radius(size_t i) {
        immutable double dx = pts[i][0] - a.x, dy = pts[i][1] - a.y;
        return sqrt(dx * dx + dy * dy);
    }
    double maxRadius(bool[size_t] s) {
        double m = 0;
        foreach (i; s.byKey) if (radius(i) > m) m = radius(i);
        return m;
    }

    immutable double rFill = maxRadius(dGrab);
    immutable double rRing = maxRadius(dHover);

    // THE ASSERTION. Both circles lie in one plane and share a centre, so
    // whatever the projection does to one it does to the other and the ratio
    // is the shipped 0.8 plus a pixel of antialiasing at each end. Bracketed
    // both ways: a fill at the ring's own radius lands at ~1.0 and fails the
    // upper bound; a fill much smaller than 0.8 fails the lower one.
    immutable double ratio = rFill / rRing;
    assert(ratio <= 0.88,
           format("the fill must sit INSIDE the ring: fill reaches %.1f px, ring "
                  ~ "reaches %.1f px, ratio %.3f — a fill drawn at the ring's own "
                  ~ "radius gives ~1.0", rFill, rRing, ratio));
    assert(ratio >= 0.62,
           format("the fill must still be most of the ring: fill %.1f px, ring "
                  ~ "%.1f px, ratio %.3f", rFill, rRing, ratio));

    // ...and the difference really is a ring: the pixels hover changes and
    // grab does not must all be OUTSIDE the fill's extent.
    foreach (i; dHover.byKey) {
        if (i in dGrab) continue;
        assert(radius(i) > rFill - 1.5,
               format("a hover-only pixel at radius %.1f sits inside the fill "
                      ~ "(which reaches %.1f) — the two elements are not "
                      ~ "concentric circles", radius(i), rFill));
    }
}

// ---------------------------------------------------------------------------
// Flow B — the grabbed disc is OPAQUE, and only the grabbed one
// ---------------------------------------------------------------------------

unittest {
    armMove();
    scope(exit) { script("tool.set move off"); hoverAt(PARK_X, PARK_Y); }

    auto a = anchor(P_PLANE_XY);
    assert(a.visible, "fixture premise: the XY plane handle must be drawn here");

    // A filled square over the whole handle — the disc is what is being
    // counted, so the sample has to be two-dimensional.
    enum int HALF = 9;
    int[2][] pts;
    foreach (dy; -HALF .. HALF + 1)
        foreach (dx; -HALF .. HALF + 1)
            pts ~= [a.x + dx, a.y + dy];

    hoverAt(PARK_X, PARK_Y);   auto idle = probe(pts);
    hoverAt(a.x, a.y);         auto hov  = probe(pts);
    pressAt(a.x, a.y);
    assert(capturedPart() == P_PLANE_XY, "premise: the press must capture the handle");
    auto grab = probe(pts);
    releaseAt(a.x, a.y);

    int rawActive(const Px[] rows) {
        int n = 0;
        foreach (p; rows) if (isColor(p, RGB_ACTIVE)) ++n;
        return n;
    }

    immutable int nIdle = rawActive(idle), nHov = rawActive(hov), nGrab = rawActive(grab);

    // POSITIVE HALF: at alpha 1.0 the batch never reaches the blending path, so
    // every covered pixel is the colour itself and not a composite of it.
    assert(nGrab >= 20,
           format("a grabbed fill must read the RAW active colour — only %d pixels "
                  ~ "did, which is what a translucent disc looks like", nGrab));

    // NEGATIVE HALF, which is what turns the above from an existence claim into
    // a measurement of the alpha. At 0.2 no pixel can reach the raw colour,
    // however the disc is coloured, because a 20 % coverage of it over ANY
    // backdrop is 80 % backdrop.
    assert(nIdle == 0,
           format("an idle fill is 20 %% opaque and cannot read the raw active "
                  ~ "colour (%d pixels did)", nIdle));
    assert(nHov == 0,
           format("a hovered fill recolours but does NOT change alpha, so it "
                  ~ "cannot read the raw active colour either (%d pixels did)", nHov));

    // ...and the same fact from the other direction: an opaque disc is
    // backdrop-independent, so its interior collapses to ONE value, where the
    // translucent one carries the backdrop's variation through.
    size_t distinct(const Px[] rows) {
        bool[uint] seen;
        foreach (p; rows) {
            if (!p.valid) continue;
            immutable double dx = p.x - a.x, dy = p.y - a.y;
            if (sqrt(dx * dx + dy * dy) > 4.0) continue;   // well inside the disc
            seen[(cast(uint)p.r << 16) | (cast(uint)p.g << 8) | cast(uint)p.b] = true;
        }
        return seen.length;
    }
    assert(distinct(grab) == 1,
           format("a fully opaque disc shows ONE colour whatever is behind it; "
                  ~ "the grabbed disc showed %d", distinct(grab)));
    assert(distinct(idle) > 1,
           "control: the idle disc is translucent and must show the backdrop's "
           ~ "variation — a single value here would mean the probe is reading a "
           ~ "flat area and Flow B proves nothing");
}

// ---------------------------------------------------------------------------
// Flow C — the scale bank can reach `grabbed` at all
// ---------------------------------------------------------------------------
//
// It could not: the wrapper called `suppress()` for this bank alone, which
// clears `setEngaged(false)` on EVERY registered handle. The handle lit under
// the pointer and reverted on press — a non-monotonic cue the colour law
// allows for exactly one part (the plane ring, where it is measured) and not
// for an axis. Measured for the scale bank, grabbed is the active colour, the
// same as hover. So: press must paint what hover paints.
unittest {
    script("tool.set scale on");
    postRaw("/api/camera", `{"azimuth":0.5,"elevation":0.4,"distance":3.0}`);
    scope(exit) { script("tool.set scale off"); hoverAt(PARK_X, PARK_Y); }

    auto a = anchor(P_SCALE_X);
    assert(a.visible, "fixture premise: the scale X box must be drawn here");

    enum int HALF = 9;
    int[2][] pts;
    foreach (dy; -HALF .. HALF + 1)
        foreach (dx; -HALF .. HALF + 1)
            pts ~= [a.x + dx, a.y + dy];

    hoverAt(PARK_X, PARK_Y);   auto idle = probe(pts);
    hoverAt(a.x, a.y);         auto hov  = probe(pts);
    pressAt(a.x, a.y);
    assert(capturedPart() == P_SCALE_X,
           "the scale bank must publish its hauled part like every other bank — "
           ~ "suppressing the whole registry is what made `grabbed` unreachable");
    auto grab = probe(pts);
    releaseAt(a.x, a.y);

    auto dHover = changed(idle, hov);
    auto dGrab  = changed(idle, grab);

    assert(dHover.length > 8,
           format("premise: hovering the scale box must repaint it (%d pixels)",
                  dHover.length));

    // The assertion. Before the fix this set was EMPTY — the press put the box
    // back to its idle colour, so a differential against idle found nothing.
    assert(dGrab.length > 8,
           format("pressing the scale box must paint what hovering it paints; it "
                  ~ "changed %d pixels against idle where the hover changed %d — "
                  ~ "zero here means the handle went dark at the moment of the grab",
                  dGrab.length, dHover.length));

    // ...and it is the SAME repaint, not merely some repaint: hover and grab
    // are one colour for this bank, so the two readings must agree pixel for
    // pixel over the box.
    foreach (i; dHover.byKey)
        assert(hov[i].r == grab[i].r && hov[i].g == grab[i].g && hov[i].b == grab[i].b,
               format("hover and grab are the same colour for the scale bank, so "
                      ~ "pixel (%d,%d) must read alike: hover (%d,%d,%d) vs grab "
                      ~ "(%d,%d,%d)", hov[i].x, hov[i].y,
                      hov[i].r, hov[i].g, hov[i].b, grab[i].r, grab[i].g, grab[i].b));
}
