// test_gizmo_hover_highlight.d — the pointer resting on a handle must repaint
// it, and repaint NOTHING else.
//
// WHY THIS FILE EXISTS, AND WHY test_gizmo_handle_colours.d COULD NOT COVER IT.
// That test asserts the LAW: it checks what `handleColor` returns for each
// state. It passed, green, for the entire period in which the application had
// no hover cue at all — because nothing in it ever asks whether the pointer
// resting on a handle reaches that function with the hover state, or reaches
// it at all. A law test cannot fail for a missing caller. This one can: it
// drives a real pointer to a real handle over the event log and reads the
// framebuffer back.
//
// WHAT MAKES THIS NOT A SCREENSHOT TEST. It never looks at an image and never
// compares one against a stored one. It asks the handle registry where the
// handle is, reads channel VALUES at those coordinates through
// /api/viewport/probe, and compares them against the scheme restated as 8-bit
// literals. Every comparison carries a control that must NOT change, so a null
// result is distinguishable from a broken probe.
//
// Flow A — the common law, on a Move arm. Hovering the X arm repaints exactly
//          the X arm's pixels in the active colour; the SAME pixels, not more
//          and not fewer (a size or line-width change would move the set), and
//          the Y arm beside it is untouched. Y is the control: it proves the
//          probe is reading a live frame and that one part lights at a time.
//
// Flow B — the plane handle, which is the ONE part where hover and grab
//          disagree, and the only flow that can tell the two mechanisms apart.
//          Measured: hover recolours the ring AND the disc; a grab recolours
//          the disc and gives the ring its axis colour BACK. This is asserted
//          as a pure differential — the set of pixels a hover changes must be
//          a STRICT SUPERSET of the set a grab changes — so it needs to know
//          nothing about where the ring is, and the pixels in the difference
//          are then identified by value as the ring. A two-state colour law
//          cannot pass this flow in either direction.
//
// Flow C — the hover region IS the click region. The exact pixel that makes a
//          part hot must be a pixel that captures that same part on a press.
//          Asserted for an arm and for a plane handle, at the pixel, rather
//          than argued from the fact that both paths call the same function.
//
// VERIFIED BY MUTATION. Each of these was applied to a green tree, built, and
// run; the named assertion is the one that fired:
//
//   * hover branch removed from `Handler.drawColor` (hover painted as idle)
//       -> Flow A, "the X arm did not change colour under the pointer".
//   * `planeRingColor` collapsed to a bool (active for hover AND grabbed)
//       -> Flow B, "the hover and the grab changed exactly the same 72
//          pixels". Flow A stays green, which is the point: only the plane
//          ring can tell the two mechanisms apart.
//   * GIZMO_ALPHA_ARM 0.95 -> 1.00, and -> 0.90
//       -> Flow A, "no pixel of the X arm found on the centre->tip sweep".
//   * GIZMO_ALPHA_PLANE_RING 0.80 -> 1.00
//       -> Flow B, "lights to gain 0.998, past the ring's own alpha 0.80".
//
// --------------------------------------------------------------------------
// HOW A HANDLE'S COLOUR IS RECOGNISED, AND WHY THAT CHANGED (task 0600)
//
// This file used to find a handle's pixels by matching the scheme colour
// directly, on the stated premise that the handle passes never blend, so a
// pixel's value IS the uniform. That premise was true when it was written and
// is now false: the gizmo's lines are drawn at a measured per-part alpha over
// a live blend (ARM_ALPHA, RING_ALPHA below), so an arm shaft pixel is
// `0.95*axis + 0.05*background` — about 6 counts off the raw colour on the
// saturated channel, which the +-3 byte-slop window rightly rejects. Flow A
// failed exactly there, at "the arm was not drawn". Flow B was hidden behind
// it (a module stops at its first failure) and was measured to be broken the
// same way: 0 of its 7 ring pixels read the raw active colour, and 5 pixels
// where the ring overlaps the disc differ between hovered and grabbed, which
// its old "hover and grab agree about the disc" assertion could not allow.
//
// The fix is NOT to widen the window. A +-7 window would swallow the very
// distinction these flows exist to make, and this is the only test pinning
// that the hover cue reaches the framebuffer at all. Instead — following
// tests/test_gizmo_handle_alpha.d, which met this in the same task and was
// strengthened rather than rebaselined — the destination is MEASURED and the
// expectation is the exact composite of the two:
//
//   * Flow A probes the same sweep points a second time with the tool
//     dropped, and matches `alpha*colour + (1-alpha)*measured background`.
//     That is strictly tighter than what it replaced: the old form could not
//     see the alpha VALUE at all, and this one fails at 1.0 and at 0.90
//     alike (see the two-sided bracket at the "translucent" assertion).
//   * Flow B needs no background at all. Its ring pixels sit over an unknown
//     destination, so they are identified by the DIRECTION they move in: a
//     ring pixel's step from idle to hovered must be exactly
//     `k*(active - the ring's axis colour)` for one scalar k in (0, RING_ALPHA]
//     — one number explaining all three channels. That is a stronger
//     identification than "reads active" ever was, because it pins the idle
//     colour and the hovered colour and the alpha bound together, and it is
//     immune to whatever the ring happens to be drawn over.
//
// Flow C compares no pixels — it reads the handle registry only — so blending
// cannot reach it and it is deliberately untouched.
// --------------------------------------------------------------------------

import std.format : format;
import std.json;
import std.math : abs, round, cos, sin, PI;
import std.net.curl : get, post;

import drag_helpers : playAndWait;

void main() {}

private enum string baseUrl = "http://localhost:8080";

// Registration bases from source/tools/transform/xfrm_transform.d.
private enum int MOVE_BASE = 0;
// Slot order inside the Move bank (source/tools/transform/move.d
// registerHandles): arms 0/1/2, centre box 3, plane circles 4/5/6.
private enum int PART_ARM_X  = MOVE_BASE + 0;
private enum int PART_ARM_Y  = MOVE_BASE + 1;
private enum int[3] PART_PLANES = [MOVE_BASE + 4, MOVE_BASE + 5, MOVE_BASE + 6];

// The scheme, restated as 8-bit literals — the same independent-restatement
// convention tests/test_gizmo_handle_alpha.d uses. `round(255 * c)` of the
// Vec3 rows that tests/test_gizmo_handle_colours.d pins. Restated rather than
// imported so that a drift in the table has to be acknowledged here too.
private enum int[3] RGB_AXIS_X = [229,  51,  51];   // 0.9, 0.2, 0.2
private enum int[3] RGB_AXIS_Y = [ 51, 204,  51];   // 0.2, 0.8, 0.2
private enum int[3] RGB_AXIS_Z = [ 51, 102, 255];   // 0.2, 0.4, 1.0
private enum int[3] RGB_ACTIVE = [255, 230, 102];   // 1.0, 0.9, 0.4

// The per-part alphas the gizmo's LINE batches are drawn at
// (handles/gl_util.d: GIZMO_ALPHA_ARM, GIZMO_ALPHA_PLANE_RING). Restated here
// as literals rather than read back from the app, on the same convention as
// the colours above: changing one in the renderer has to fail here and be
// re-justified. Both are bracketed from BOTH sides below — a value that is
// too low matches no composite, a value that is too high shows through as the
// raw colour (Flow A) or overshoots the recolour gain (Flow B).
private enum double ARM_ALPHA  = 0.95;   // move/scale arms, shaft and head
private enum double RING_ALPHA = 0.80;   // the plane handle's outline ring

private JSONValue postJson(string path, string body_) {
    return parseJSON(cast(string)post(baseUrl ~ path, body_));
}
private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
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

// ---------------------------------------------------------------------------
// Pointer driving
// ---------------------------------------------------------------------------

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

// Park the pointer at (x, y) with no button pressed and leave it there. The
// mouse override the player sets is never cleared, so the position — and
// therefore the hover — persists into every frame drawn after playback ends,
// which is what makes a post-playback probe meaningful.
private void hoverAt(Cell c, int x, int y) {
    string log = logHeader(c);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
            ~ "\n", 50.0 + i * 20.0, x, y);
    playAndWait(log);
}

// Press at (x, y) and DO NOT release — the log ends on the button-down, so the
// capture is still live when the next probe runs. Pair every call with
// `releaseAt`.
private void pressAt(Cell c, int x, int y) {
    playAndWait(logHeader(c) ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONDOWN","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
        ~ "\n", x, y));
}

private void releaseAt(Cell c, int x, int y) {
    playAndWait(logHeader(c) ~ format(
        `{"t":50.000,"type":"SDL_MOUSEBUTTONUP","btn":1,"x":%d,"y":%d,"clicks":1,"mod":0}`
        ~ "\n", x, y));
}

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

private struct Px { int x, y, r, g, b, a; bool valid; }

// Probe a list of window-space points, chunked so the request line stays short
// regardless of how many were asked for. Window -> FBO is the cell origin;
// both are top-left.
private Px[] probe(Cell c, const int[2][] winPts) {
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
        // The --test single-rendered-cell trap: a probe at a never-filled FBO
        // reads zeros and every assertion below would fail for the WRONG
        // reason. Assert the flag rather than trusting the default.
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
            p.a = cast(int)num(e, "a");
            p.valid = true;
            outp ~= p;
        }
    }
    return outp;
}

// Software GL rounds the last bit differently across drivers; 3/255 is byte
// slop, not a shading tolerance. It is the same window everywhere below.
private enum int SLOP = 3;

// The RAW scheme colour, i.e. an UNBLENDED write. Since task 0600 no gizmo
// line is one, so this now serves only as the negative half of the alpha
// bracket: "no pixel of the arm may read the raw axis colour".
private bool isColor(Px p, const int[3] want) {
    return p.valid && abs(p.r - want[0]) <= SLOP
                   && abs(p.g - want[1]) <= SLOP
                   && abs(p.b - want[2]) <= SLOP;
}

private int mix1(int fg, int bg, double alpha) {
    return cast(int)(alpha * fg + (1.0 - alpha) * bg + 0.5);
}

// Is `p` the FULLY covered composite of `want` at `alpha` over the background
// `bg`, measured at the same pixel with the gizmo dropped?
//
// Partial-coverage fringe pixels do NOT satisfy this — their effective alpha
// is lower — which is exactly what makes a match mean "the stroke's
// centreline" and what makes the index sets below stable enough to compare.
private bool isStroke(Px p, Px bg, const int[3] want, double alpha) {
    if (!p.valid || !bg.valid) return false;
    return abs(p.r - mix1(want[0], bg.r, alpha)) <= SLOP
        && abs(p.g - mix1(want[1], bg.g, alpha)) <= SLOP
        && abs(p.b - mix1(want[2], bg.b, alpha)) <= SLOP;
}

// Is the step from `a` to `b` the SAME stroke repainted from `from` to `to`?
//
// A blended stroke over an unknown destination D reads
// `k*colour + (1-k)*D`, with `k = alpha * coverage`. Two readings of one pixel
// that differ only in the stroke's colour therefore differ by exactly
// `k*(to - from)` — D cancels, and one scalar has to explain all three
// channels. That is what identifies a pixel as belonging to a given stroke
// without knowing anything about what it was drawn over.
//
// `k` is the recovered gain; it is the stroke's own alpha where the pixel is
// fully covered and less on its fringe, so `0 < k <= alpha` is a bound on the
// renderer, not a tolerance.
private bool recolourGain(Px a, Px b, const int[3] from, const int[3] to,
                          out double k)
{
    k = 0;                                  // `out` starts at double.init = NaN
    if (!a.valid || !b.valid) return false;
    immutable double dr = to[0] - from[0], dg = to[1] - from[1], db = to[2] - from[2];
    immutable double den = dr*dr + dg*dg + db*db;
    if (den < 1.0) return false;            // the two colours are the same
    immutable double cr = b.r - a.r, cg = b.g - a.g, cb = b.b - a.b;
    k = (cr*dr + cg*dg + cb*db) / den;
    return abs(cr - k*dr) <= SLOP
        && abs(cg - k*dg) <= SLOP
        && abs(cb - k*db) <= SLOP;
}

private bool samePixel(Px a, Px b) {
    return a.valid == b.valid && a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a;
}

// Indices (into a shared point list) whose colour differs between two probes
// of that same list. The point list is the identity of a pixel here, so two
// probes are always compared index-for-index.
private size_t[] changedIdx(const Px[] before, const Px[] after) {
    assert(before.length == after.length, "probe lists differ in length");
    size_t[] outi;
    foreach (i; 0 .. before.length)
        if (!samePixel(before[i], after[i])) outi ~= i;
    return outi;
}

private size_t[] matchingIdx(const Px[] pxs, const int[3] want) {
    size_t[] outi;
    foreach (i, p; pxs) if (isColor(p, want)) outi ~= i;
    return outi;
}

// The same, for a blended stroke: the indices whose value is `want` composited
// at `alpha` over the background measured at that same index.
private size_t[] strokeIdx(const Px[] pxs, const Px[] bg, const int[3] want,
                           double alpha)
{
    assert(pxs.length == bg.length, "reading and background differ in length");
    size_t[] outi;
    foreach (i, p; pxs) if (isStroke(p, bg[i], want, alpha)) outi ~= i;
    return outi;
}

// ---------------------------------------------------------------------------
// The handle registry
// ---------------------------------------------------------------------------

private struct Handles {
    double[2][int] screen;
    int hot, captured;
}

private Handles handles() {
    auto j = getJson("/api/tool/handles")["handles"];
    assert(j.type != JSONType.null_,
           "/api/tool/handles reports no handles — no tool is armed");
    Handles h;
    h.hot      = cast(int)num(j, "hot");
    h.captured = cast(int)num(j, "captured");
    foreach (e; j["parts"].array) {
        if (e["screen"].type == JSONType.null_) continue;
        if (!e["visible"].boolean) continue;
        h.screen[cast(int)num(e, "part")] =
            [e["screen"].array[0].floating, e["screen"].array[1].floating];
    }
    return h;
}

// Arm the Move bank over the whole default cube and park the pointer on empty
// space. Returns the cell. Asserts the parked state really is idle — without
// that check the "before" reading could itself be a hover and every
// comparison below would be against the wrong baseline.
private Cell armMoveAndPark() {
    postJson("/api/reset", "");
    postJson("/api/select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`);
    postJson("/api/script", "tool.set move");

    auto c = cell();
    // A corner of the cell. The gizmo sits on the selection, i.e. near the
    // middle, so a corner is off every handle.
    hoverAt(c, c.vx + 8, c.vy + 8);
    auto h = handles();
    assert(h.hot == -1,
           format("the idle baseline is not idle: parking at the cell corner "
                  ~ "left part %d hot, so every 'before' reading below would "
                  ~ "be of an already-highlighted gizmo", h.hot));
    assert(h.captured == -1, "a capture is live before the test began");
    return c;
}

// Read one or more point lists with the Move bank DROPPED — i.e. what is
// BEHIND the gizmo — then put the tool back and re-park the pointer on empty
// space, so the caller resumes from the same idle state it left.
//
// Dropping the tool changes nothing else in the scene: the selection stays,
// the camera stays, and the gizmo is simply not emitted. The two controls at
// the call site (the arm's anchor did not move, the idle sweep re-reads
// identically) are what turn that from an assumption into a measurement.
private Px[][] backgroundProbe(Cell c, int[2][][] lists...) {
    postJson("/api/script", "tool.set move off");
    hoverAt(c, c.vx + 8, c.vy + 8);          // one played frame with no gizmo
    Px[][] outp;
    foreach (l; lists) outp ~= probe(c, l);
    postJson("/api/script", "tool.set move");
    hoverAt(c, c.vx + 8, c.vy + 8);          // re-armed, and idle again
    return outp;
}

// A perpendicular sweep across the segment centre->tip, sampling well inside
// the shaft (past the inset, short of the cone) at several points along it.
// The drawn line is only a few pixels wide and its exact row depends on the
// camera, hence the sweep rather than a single point.
private int[2][] shaftSweep(double cx, double cy, double tx, double ty) {
    import std.math : sqrt;
    immutable double dx = tx - cx, dy = ty - cy;
    immutable double len = sqrt(dx * dx + dy * dy);
    assert(len > 20, "the arm projects to under 20 px; nothing to sample");
    immutable double ux = dx / len, uy = dy / len;
    immutable double px = -uy, py = ux;
    int[2][] pts;
    foreach (ti; 0 .. 3) {
        immutable double t = 0.40 + 0.10 * ti;
        foreach (d; -6 .. 7)
            pts ~= [cast(int)round(cx + dx * t + px * d),
                    cast(int)round(cy + dy * t + py * d)];
    }
    return pts;
}

// ---------------------------------------------------------------------------
// Flow A — hovering an arm repaints that arm, and only that arm
// ---------------------------------------------------------------------------

unittest {
    auto c = armMoveAndPark();
    auto h = handles();
    assert(PART_ARM_X in h.screen && PART_ARM_Y in h.screen
           && (MOVE_BASE + 3) in h.screen,
           "the Move bank must publish an X arm, a Y arm and a centre");

    immutable double gx = h.screen[MOVE_BASE + 3][0], gy = h.screen[MOVE_BASE + 3][1];
    auto sweepX = shaftSweep(gx, gy, h.screen[PART_ARM_X][0], h.screen[PART_ARM_X][1]);
    auto sweepY = shaftSweep(gx, gy, h.screen[PART_ARM_Y][0], h.screen[PART_ARM_Y][1]);

    auto idleX = probe(c, sweepX);
    auto idleY = probe(c, sweepY);

    // What the arms are drawn OVER, measured at the same points. The shafts
    // are blended now, so every colour claim below is made against this and
    // never against the raw scheme entry.
    auto bg  = backgroundProbe(c, sweepX, sweepY);
    auto bgX = bg[0], bgY = bg[1];

    // Two controls on that round trip. It has to leave the frame exactly as it
    // found it, or the background belongs to some other frame than the
    // readings taken around it: the arm's own anchor must not have moved, and
    // re-reading the idle sweep must give back the same pixels.
    auto hRe = handles();
    assert(PART_ARM_X in hRe.screen
           && abs(hRe.screen[PART_ARM_X][0] - h.screen[PART_ARM_X][0]) < 0.5
           && abs(hRe.screen[PART_ARM_X][1] - h.screen[PART_ARM_X][1]) < 0.5,
           "dropping and re-arming the Move bank moved the gizmo — the "
           ~ "measured background does not line up with the readings");
    assert(changedIdx(idleX, probe(c, sweepX)).length == 0,
           "the idle X sweep did not read back identically across the "
           ~ "drop/re-arm round trip, so the background probe is not a "
           ~ "background OF THIS frame");

    auto onX = strokeIdx(idleX, bgX, RGB_AXIS_X, ARM_ALPHA);
    auto onY = strokeIdx(idleY, bgY, RGB_AXIS_Y, ARM_ALPHA);
    assert(onX.length > 0,
           format("no pixel of the X arm found on the centre->tip sweep: none "
                  ~ "reads its colour rgb(%(%d,%)) composited at alpha %.2f "
                  ~ "over its own measured background. The arm was not drawn, "
                  ~ "the scheme changed without this test, or it is not being "
                  ~ "drawn at that alpha", RGB_AXIS_X[], ARM_ALPHA));
    assert(onY.length > 0,
           format("no pixel of the Y arm's colour rgb(%(%d,%)) found — the "
                  ~ "control arm is not on screen, so its silence below would "
                  ~ "prove nothing", RGB_AXIS_Y[]));

    // The arm is TRANSLUCENT, and this is the other half of the bracket on
    // ARM_ALPHA. Nothing on the sweep may read the RAW axis colour: at 0.95
    // over the measured background the centreline lands ~6 counts short of it
    // and the window is 3, so an opaque arm fails here while a fainter one
    // fails the composite match above. Between them the value is pinned to
    // roughly +-0.025, and 1.00 / 0.90 / 0.80 are all excluded.
    assert(matchingIdx(idleX, RGB_AXIS_X).length == 0,
           format("%d pixel(s) of the X arm read the raw scheme colour "
                  ~ "rgb(%(%d,%)) — the arm is reaching the framebuffer more "
                  ~ "opaque than the measured alpha %.2f it is supposed to be "
                  ~ "drawn at", matchingIdx(idleX, RGB_AXIS_X).length,
                  RGB_AXIS_X[], ARM_ALPHA));
    // Nothing is highlighted yet. Stated explicitly so a build that paints the
    // whole gizmo active could not sail through the comparison.
    assert(strokeIdx(idleX, bgX, RGB_ACTIVE, ARM_ALPHA).length == 0,
           "an unhovered X arm already wears the active colour");

    // --- hover the X arm ---
    immutable int hx = cast(int)round(h.screen[PART_ARM_X][0]);
    immutable int hy = cast(int)round(h.screen[PART_ARM_X][1]);
    hoverAt(c, hx, hy);
    auto hov = handles();
    assert(hov.hot == PART_ARM_X,
           format("hovering the X arm's own anchor (%d, %d) made part %d hot, "
                  ~ "not %d", hx, hy, hov.hot, PART_ARM_X));
    assert(hov.captured == -1,
           "hovering must not capture — the pointer has pressed nothing");

    auto hovX = probe(c, sweepX);
    auto hovY = probe(c, sweepY);

    // 1. The arm changed colour: every pixel that wore the axis colour now
    //    wears the active one — at the same alpha, over the same background.
    auto nowActive = strokeIdx(hovX, bgX, RGB_ACTIVE, ARM_ALPHA);
    assert(nowActive.length > 0,
           format("the X arm did not change colour under the pointer: %d "
                  ~ "pixels still read rgb(%(%d,%)) at alpha %.2f and none "
                  ~ "read the active rgb(%(%d,%)). The hover state is not "
                  ~ "reaching the draw.",
                  strokeIdx(hovX, bgX, RGB_AXIS_X, ARM_ALPHA).length,
                  RGB_AXIS_X[], ARM_ALPHA, RGB_ACTIVE[]));

    // 2. ...and it is the SAME set of pixels, not a larger or smaller one.
    //    This is the half that says "colour, and nothing but colour": a size,
    //    line-width, outline or glow change would move the footprint, and the
    //    two index sets would stop matching.
    assert(onX == nowActive,
           format("the X arm's footprint changed under the pointer: %d pixels "
                  ~ "wore its axis colour, %d now wear the active colour, and "
                  ~ "the sets are not the same pixels. Hover must repaint the "
                  ~ "handle, not resize or re-stroke it.",
                  onX.length, nowActive.length));
    assert(strokeIdx(hovX, bgX, RGB_AXIS_X, ARM_ALPHA).length == 0,
           "part of the X arm kept its axis colour — the highlight covered "
           ~ "only some of the handle");

    // 3. The control: the Y arm beside it is untouched, pixel for pixel. One
    //    part lights at a time, and the probe is not simply reporting a
    //    global recolour.
    assert(changedIdx(idleY, hovY).length == 0,
           format("hovering the X arm changed %d pixels of the Y arm",
                  changedIdx(idleY, hovY).length));
    assert(strokeIdx(hovY, bgY, RGB_AXIS_Y, ARM_ALPHA) == onY,
           "the Y arm's own colour moved while the X arm was hovered");
    assert(strokeIdx(hovY, bgY, RGB_ACTIVE, ARM_ALPHA).length == 0,
           "the Y arm lit up while the pointer was on the X arm");

    // Leave the gizmo unhovered for whatever runs next.
    hoverAt(c, c.vx + 8, c.vy + 8);
}

// ---------------------------------------------------------------------------
// Flow B — the plane handle: hover and grab are DIFFERENT looks
// ---------------------------------------------------------------------------

unittest {
    auto c = armMoveAndPark();
    auto h = handles();

    // Take the first plane circle whose own anchor grabs it. The circles are
    // registered ahead of the box and the arms, so a hover at a circle's
    // centre resolves to that circle — but which of the three is reachable
    // depends on the camera, so this is discovered rather than assumed.
    int planePart = -1;
    int px, py;
    foreach (part; PART_PLANES) {
        if (part !in h.screen) continue;
        int x = cast(int)round(h.screen[part][0]);
        int y = cast(int)round(h.screen[part][1]);
        hoverAt(c, x, y);
        if (handles().hot == part) { planePart = part; px = x; py = y; break; }
    }
    assert(planePart >= 0,
           "no Move plane handle could be hovered at its own published anchor "
           ~ "— the plane exception cannot be measured");

    // The ring's IDLE colour. A plane handle's outline wears the colour of the
    // axis NORMAL to its plane (handles/shapes.d, MoveHandler's ctor), and the
    // Move bank registers circleXY / circleYZ / circleXZ at base+4 / +5 / +6
    // (tools/transform/move.d, registerHandles). Needed because the ring is
    // blended over an unknown destination: what identifies a ring pixel below
    // is the DIRECTION it travels, out of this colour and toward the active
    // one, so the colour it starts from is now part of the claim.
    int[3] RGB_RING;
    if      (planePart == MOVE_BASE + 4) RGB_RING = RGB_AXIS_Z;  // XY plane, Z normal
    else if (planePart == MOVE_BASE + 5) RGB_RING = RGB_AXIS_X;  // YZ plane, X normal
    else                                 RGB_RING = RGB_AXIS_Y;  // XZ plane, Y normal

    // Rays out of the disc centre. Every ray crosses the outline ring exactly
    // once, so the ring is always in the sample without this test needing to
    // know the disc's screen radius. Anything else a ray crosses (an arm, the
    // mesh, the grid) is harmless: the assertions below are differentials and
    // only ever look at pixels that CHANGED.
    int[2][] rays;
    foreach (k; 0 .. 8) {
        immutable double a = 2.0 * PI * k / 8.0;
        foreach (r; 1 .. 100)
            rays ~= [cast(int)round(px + cos(a) * r), cast(int)round(py + sin(a) * r)];
    }
    // A control point on empty canvas, carried through all three readings.
    immutable int[2] ctrl = [c.vx + 8, c.vy + 8];
    rays ~= ctrl;
    immutable size_t ctrlIdx = rays.length - 1;

    // --- three states of the same pixels ---
    hoverAt(c, c.vx + 8, c.vy + 8);
    auto idle = probe(c, rays);
    assert(handles().hot == -1, "the idle reading was taken while something was hot");

    hoverAt(c, px, py);
    assert(handles().hot == planePart, "the plane handle stopped being hot");
    auto hov = probe(c, rays);

    pressAt(c, px, py);
    scope(exit) { releaseAt(c, px, py); hoverAt(c, c.vx + 8, c.vy + 8); }
    auto grabbed = handles();
    assert(grabbed.captured == planePart,
           format("pressing the plane handle at its own anchor captured part "
                  ~ "%d, not %d", grabbed.captured, planePart));
    auto grb = probe(c, rays);

    auto hovChanged = changedIdx(idle, hov);
    auto grbChanged = changedIdx(idle, grb);

    assert(hovChanged.length > 0,
           "hovering the plane handle changed no pixel at all — there is no "
           ~ "hover cue on the plane handle");
    assert(grbChanged.length > 0,
           "grabbing the plane handle changed no pixel at all");

    // The measured shape: a grab lights STRICTLY FEWER pixels than a hover,
    // because the ring reverts to its axis colour while the disc stays lit.
    bool[size_t] inHov;
    foreach (i; hovChanged) inHov[i] = true;
    foreach (i; grbChanged)
        assert(i in inHov,
               format("pixel (%d,%d) changed on the grab but not on the hover. "
                      ~ "The grab is expected to light a SUBSET of what the "
                      ~ "hover lights.", rays[i][0], rays[i][1]));

    bool[size_t] inGrb;
    foreach (i; grbChanged) inGrb[i] = true;
    size_t[] ringOnly;
    foreach (i; hovChanged) if (i !in inGrb) ringOnly ~= i;

    assert(ringOnly.length > 0,
           format("the hover and the grab changed exactly the same %d pixels. "
                  ~ "The plane handle's ring is supposed to light under the "
                  ~ "pointer and go BACK to its axis colour on the grab, so "
                  ~ "these two states must not be identical — this is what a "
                  ~ "two-state colour law cannot express.", hovChanged.length));

    // Identify the difference by VALUE rather than by position: those pixels
    // must be the RING, i.e. one stroke repainted from its axis colour to the
    // active one and back again.
    //
    // The ring is blended (RING_ALPHA) and antialiased, over a destination
    // this test does not know, so "reads the active colour" is not what a ring
    // pixel does any more — it reads some mix of the active colour and
    // whatever is behind it. What it must do is MOVE, from idle to hovered, by
    // exactly `k*(active - axis)`: one scalar explaining all three channels,
    // with the destination cancelling out of the difference. A pixel that
    // moved for any other reason (a different part, a shading change, a frame
    // shift) does not line up with that direction.
    double ringGainMax = 0;
    foreach (i; ringOnly) {
        double k;
        assert(recolourGain(idle[i], hov[i], RGB_RING, RGB_ACTIVE, k) && k > 0,
               format("pixel (%d,%d) is in the hover-only set but its step "
                      ~ "rgb(%d,%d,%d) -> rgb(%d,%d,%d) is not the ring's own "
                      ~ "stroke repainted from rgb(%(%d,%)) to rgb(%(%d,%)) — "
                      ~ "no single coverage explains all three channels, so "
                      ~ "this pixel is not the plane ring",
                      rays[i][0], rays[i][1],
                      idle[i].r, idle[i].g, idle[i].b,
                      hov[i].r, hov[i].g, hov[i].b, RGB_RING[], RGB_ACTIVE[]));
        // The gain is `RING_ALPHA * coverage`, so it may not exceed the alpha
        // the ring is drawn at. This is the upper half of the bracket on
        // RING_ALPHA: draw the ring more opaque and the centreline overshoots.
        assert(k <= RING_ALPHA + 0.05,
               format("pixel (%d,%d) lights to gain %.3f, past the ring's own "
                      ~ "alpha %.2f — the ring is being drawn more opaque than "
                      ~ "measured", rays[i][0], rays[i][1], k, RING_ALPHA));
        assert(samePixel(idle[i], grb[i]),
               format("pixel (%d,%d) is in the hover-only set, so idle and "
                      ~ "grabbed must agree there; they read rgb(%d,%d,%d) and "
                      ~ "rgb(%d,%d,%d)", rays[i][0], rays[i][1],
                      idle[i].r, idle[i].g, idle[i].b,
                      grb[i].r, grb[i].g, grb[i].b));
        if (k > ringGainMax) ringGainMax = k;
    }
    // ...and the lower half: somewhere on the ring the pointer's repaint is at
    // full strength, not a fringe whisper. Half the measured alpha is the
    // floor; the ring's centreline reads ~0.80. Without this, a set of
    // one-count fringe changes would satisfy the direction test vacuously.
    assert(ringGainMax >= 0.4,
           format("the hover-only pixels never light beyond gain %.3f. The "
                  ~ "ring's own alpha is %.2f, so a repaint of it should reach "
                  ~ "about that on the stroke's centreline; this is a fringe "
                  ~ "flicker, not a handle lighting up", ringGainMax, RING_ALPHA));

    // The other half of the exception: hover and grab agree about the DISC and
    // disagree about the ring — so wherever the two states disagree AT ALL, on
    // any of the rays, the disagreement must again be the ring's stroke and
    // nothing else. (This subsumes the ring-only set: those are the ring
    // pixels the disc does not also cover. The pixels where the two overlap
    // change on the grab as well — the disc recolours under them — and are
    // therefore not in `ringOnly`, but the difference between hovered and
    // grabbed there is still purely the ring.)
    auto hovVsGrb = changedIdx(grb, hov);
    foreach (i; hovVsGrb) {
        double k;
        assert(recolourGain(grb[i], hov[i], RGB_RING, RGB_ACTIVE, k) && k > 0,
               format("pixel (%d,%d) differs between hovered and grabbed by "
                      ~ "something that is not the ring: rgb(%d,%d,%d) vs "
                      ~ "rgb(%d,%d,%d). Only the ring may tell those two "
                      ~ "states apart.", rays[i][0], rays[i][1],
                      hov[i].r, hov[i].g, hov[i].b,
                      grb[i].r, grb[i].g, grb[i].b));
    }
    // And the disc really is lit identically in both: most of what the grab
    // changed reads pixel-for-pixel the same as under a bare hover.
    size_t discAgreed = 0;
    foreach (i; grbChanged) if (samePixel(hov[i], grb[i])) ++discAgreed;
    assert(discAgreed > 0,
           format("every one of the %d pixels the grab lit also differs "
                  ~ "between hover and grab, so nothing here is the disc — the "
                  ~ "two states share no lit geometry at all", grbChanged.length));

    // The control never moved, in any of the three readings — so none of the
    // differences above is a whole-frame shift (a camera nudge, a relocate, a
    // re-layout) masquerading as a handle repaint.
    assert(samePixel(idle[ctrlIdx], hov[ctrlIdx])
           && samePixel(idle[ctrlIdx], grb[ctrlIdx]),
           "the empty-canvas control pixel changed between readings — the "
           ~ "frame moved, so no difference measured above is attributable to "
           ~ "the handle");
}

// ---------------------------------------------------------------------------
// Flow C — the hover region IS the click region
// ---------------------------------------------------------------------------

unittest {
    auto c = armMoveAndPark();
    auto h = handles();

    // Every published handle that a hover can reach must be captured by a
    // press at the SAME pixel. One radius, one test — not two that happen to
    // agree near the middle.
    int checked = 0;
    foreach (part; [PART_ARM_X, PART_ARM_Y] ~ PART_PLANES[]) {
        if (part !in h.screen) continue;
        int x = cast(int)round(h.screen[part][0]);
        int y = cast(int)round(h.screen[part][1]);

        hoverAt(c, x, y);
        int hot = handles().hot;
        if (hot != part) continue;   // this pixel belongs to a neighbour here

        pressAt(c, x, y);
        int captured = handles().captured;
        releaseAt(c, x, y);
        assert(captured == part,
               format("pixel (%d, %d) makes part %d hot on hover but captures "
                      ~ "part %d on a press. The hover region and the grab "
                      ~ "region have drifted apart — they must resolve through "
                      ~ "one hit test.", x, y, part, captured));
        ++checked;
    }
    assert(checked >= 2,
           format("only %d handle(s) were both hoverable and pressable at "
                  ~ "their own anchor; the agreement is not demonstrated",
                  checked));

    hoverAt(c, c.vx + 8, c.vy + 8);
}
