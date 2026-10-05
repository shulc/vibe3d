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
//          Measured: hover recolours the ring AND the disc and touches neither
//          alpha; a grab gives the ring its axis colour BACK and takes the
//          disc to full opacity. So the two states differ by a COLOUR step on
//          one element and an ALPHA step on the other, and both are asserted.
//          The skeleton is a pure differential — the set of pixels a hover
//          changes must be a STRICT SUPERSET of the set a grab changes — so it
//          needs to know nothing about where the ring is, and the pixels in
//          the difference are then identified by value as the ring. A
//          two-state colour law cannot pass this flow in either direction.
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
//          NO LONGER CAUGHT since task 0604, and the honest reason is worth
//          more than a green tick: the arm is emitted twice, so what reaches
//          the framebuffer is `1-(1-a)^2`, whose slope at a = 0.95 is 0.1.
//          Both mutations land under one 8-bit level of the correct value.
//          What Flow A still catches is the arm being emitted ONCE (~6 counts)
//          or its alpha collapsing far (0.80 -> effective 0.96, ~2.5 counts).
//          The value itself is pinned via the ring — see ARM_ALPHA below.
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
// a live blend (ARM_ALPHA, RING_ALPHA below), so an arm shaft pixel was
// `0.95*axis + 0.05*background` — about 6 counts off the raw colour on the
// saturated channel, which the +-3 byte-slop window rightly rejects. (Task
// 0604 then doubled the arm's emission, so the arm specifically is back at the
// raw colour to within a rounding step while the plane ring is not. The
// machinery below did not change for it — only the number ARM_ALPHA holds.)
// Flow A failed exactly there, at "the arm was not drawn". Flow B was hidden behind
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
//     see the alpha VALUE at all. How much of the value it can see depends on
//     how many times the part is emitted — see the mutation list above and
//     ARM_ALPHA below, where task 0604 wrote down what the arm's doubling
//     costs this flow and where the missing half went.
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
// WHY A FOOTPRINT IS NOT A SET OF COLOUR-MATCHED PIXELS (task 0609)
//
// Flow A used to name the arm's footprint by matching an exact composite: the
// pixels reading `axis at ARM_ALPHA over their background` when idle, and the
// pixels reading `active at ARM_ALPHA over their background` when hovered, and
// then required the two index sets to be equal. That conflates the two things
// the assertion means to separate — WHICH pixels the arm covers, and WHAT
// COLOUR they carry — because it derives the first from the second. It failed
// on CI, deterministically, for exactly that reason.
//
// The mechanism, measured. A +-3 count window around a composite is a window
// on the pixel's VALUE, and a value window converts into a COVERAGE window by
// dividing by the distance from the background to the stroke's colour. Over
// this scene's background rgb(105,105,105) the two colours sit at different
// distances — the axis red is 124 counts away on its widest channel, the
// active yellow 150 — so the SAME +-3 admits coverage down to 0.972 for the
// axis colour and only to 0.977 for the active one. Any pixel landing in that
// 0.005-wide band is inside one window and outside the other, and the sets
// differ by it. The band is about half an 8-bit level wide: whether a given
// build lands a pixel in it is a question about the rasteriser's sub-pixel
// rounding, not about the renderer under test.
//
// And that is what happened. At pixel (518,308) — one fringe pixel beside the
// shaft's full-coverage core — hardware GL reads red 225 and llvmpipe reads
// 226. ONE COUNT. 225 is outside both windows (the pixel is simply not in
// either set, and the sets match); 226 is inside the axis window and outside
// the active one, so idle names 5 pixels, hovered names 4, and the assertion
// fires. Both rasterisers agree about everything else, including a core of
// four pixels at coverage exactly 1.000.
//
// Note what this says about the local pass: it was 4 == 4, not a comfortable
// margin. The old form was one count from red on the machine it was written
// on.
//
// The replacement measures the footprint as COVERAGE — for each sampled pixel,
// the single scalar k in `k*colour + (1-k)*background` that its value implies,
// with the residual checked so that "not this colour" is still rejected. k is
// geometric: it is how much of the pixel the stroke covers times the alpha it
// is drawn at, so recolouring the stroke may not move it. The flow then
// asserts the profile is the same idle and hovered (the footprint), that the
// hovered reading fits the ACTIVE colour and the idle one does not (the
// colour), and that each pixel's step from one to the other is the recolour
// direction scaled by that same k (the repaint, cross-checked without any
// background at all).
//
// This is not a widened window. The +-3 survives only as the residual bound on
// a FIT, where it is not being asked to discriminate two colours: fitting the
// idle arm to the active colour misses by ~90 counts, thirty times the bound.
// What was widened is nothing; what was replaced is the quantity being
// compared. And the flow got stronger — the old set comparison was blind to
// every fringe pixel, which is most of an antialiased 2 px stroke, while the
// profile covers all of them and would fail on a tenth-pixel width change.
// --------------------------------------------------------------------------

import http_client : getJson, postJson, testBaseUrl;
import http_command_helpers : commandBody;
import std.format : format;
import std.json;
import std.math : abs, round, cos, sin, PI;
import std.net.curl : get, post;

import drag_helpers : playAndWait;

void main() {}

alias baseUrl = testBaseUrl;

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
// re-justified.
//
// ARM_ALPHA is the opacity an arm REACHES THE FRAMEBUFFER at, which since task
// 0604 is not the same as the alpha its batch is drawn with: the shaft is
// emitted twice (the reference emits it twice), so the measured 0.95 arrives as
// `1-(1-0.95)^2` and the arrowhead, no longer culled, composites its near and
// far faces for the same result. Hence 0.9975 here — and hence, one assertion
// below having to be retired rather than adjusted; see "the arm is
// TRANSLUCENT" in Flow A for where that bracket went.
//
// RING_ALPHA is untouched: the plane ring is one emission of one batch, so it
// is still bracketed from BOTH sides below — too low matches no composite, too
// high overshoots the recolour gain — and it is the in-frame evidence that
// per-batch alpha is still being applied at all.
private enum double ARM_ALPHA  = 0.9975; // move/scale arms: 0.95, twice over
private enum double RING_ALPHA = 0.80;   // the plane handle's outline ring

// How much a pixel's COVERAGE by a stroke may differ between two readings that
// differ only in the stroke's colour. It is a noise budget on a geometric
// quantity, not a colour tolerance — see task 0609 in the header for why Flow
// A compares coverages instead of sets of colour-matched pixels.
//
// Where 0.04 comes from. Two effects move a recovered coverage without the
// stroke moving:
//   * 8-bit quantisation. Coverage is recovered by projection over three
//     channels, so a half-count of rounding per channel is +-0.5/|colour - bg|
//     ~ +-0.004 for the arm over this scene's background, in each of the two
//     readings.
//   * The colour literals above are rounded to 8 bits (0.9*255 = 229.5 -> 230)
//     while the renderer rounds the other way, which biases one colour's
//     recovered coverage against the other's by up to ~0.004.
// MEASURED across the whole X-arm sweep: idle-vs-hovered coverage drifts by at
// most 0.008, on hardware GL and on llvmpipe alike. 0.04 is five times that.
//
// What it still catches, MEASURED by mutation rather than extrapolated: a
// shaft re-stroked 0.3 px wider on hover moves a fringe pixel from 0.922 to
// 0.986 covered, i.e. 0.064 — 1.6x this tolerance, and the smallest re-stroke
// that was tried. (The full 1 px mutation moves that same pixel only a little
// further, to 0.997, because it is near saturation; the pixels that move most
// under a width change are the ones the stroke's new edge sweeps across.)
private enum double COV_TOL = 0.04;

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

// HOW MUCH of `p` is `want`, over the background `bg` measured at that same
// pixel with the gizmo dropped?
//
// A blended, antialiased stroke writes `k*want + (1-k)*bg`, where
// `k = alpha * coverage` — ONE scalar for all three channels. Recover it by
// projecting the pixel's step off its background onto the step the UNBLENDED
// colour would make, and check the residual: a pixel that is not `want` over
// `bg` does not lie on that line and is rejected however large `k` comes out.
//
// The point of `k` is that it is a GEOMETRIC quantity — the fraction of the
// pixel the stroke covers, times the alpha it is drawn at. It is a property of
// where the stroke IS, so recolouring the stroke must not move it. That is
// what makes it the right thing to compare across a hover; see COV_TOL.
private bool strokeCoverage(Px p, Px bg, const int[3] want, out double k) {
    k = 0;                                  // `out` starts at double.init = NaN
    if (!p.valid || !bg.valid) return false;
    immutable double dr = want[0] - bg.r, dg = want[1] - bg.g, db = want[2] - bg.b;
    immutable double den = dr*dr + dg*dg + db*db;
    if (den < 1.0) return false;            // the stroke's colour IS the background
    immutable double cr = p.r - bg.r, cg = p.g - bg.g, cb = p.b - bg.b;
    k = (cr*dr + cg*dg + cb*db) / den;
    return abs(cr - k*dr) <= SLOP
        && abs(cg - k*dg) <= SLOP
        && abs(cb - k*db) <= SLOP;
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

// Is the step from `a` to `b` the SAME stroke at a HIGHER alpha?
//
// Raising a stroke's alpha over an unknown destination D moves the pixel along
// the straight line from where it already is toward the stroke's own colour:
// `a = m*C + (1-m)*D` and `b = n*C + (1-n)*D` with `n > m` give
// `b - a = ((n-m)/(1-m)) * (C - a)`. So one scalar in (0, 1] has to explain all
// three channels, and every quantity in the test is measured except `C`. This
// is `recolourGain`'s companion for the one part of the gizmo whose alpha
// changes between states, and it works at any coverage — a half-covered fringe
// pixel obeys it exactly as the centreline does.
private bool opacityStep(Px a, Px b, const int[3] want, out double k) {
    k = 0;                                  // `out` starts at double.init = NaN
    if (!a.valid || !b.valid) return false;
    immutable double dr = want[0] - a.r, dg = want[1] - a.g, db = want[2] - a.b;
    immutable double den = dr*dr + dg*dg + db*db;
    if (den < 1.0) return false;            // already AT the colour
    immutable double cr = b.r - a.r, cg = b.g - a.g, cb = b.b - a.b;
    k = (cr*dr + cg*dg + cb*db) / den;
    if (k <= 0.02 || k > 1.05) return false;
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

// The coverage of `want` at every index of a reading, against the background
// measured at that same index — the stroke's FOOTPRINT, as a profile rather
// than a set.
//
// Every point is required to fit: a sweep across one stroke is either that
// stroke over its background (0 < k <= alpha) or the background itself (k = 0,
// which fits exactly), and anything else on the sweep — a second handle, a
// shading change, a frame that moved between the reading and the background —
// lands off the line and is reported rather than silently dropped. `what`
// names the reading for that message.
private double[] coverProfile(const Px[] pxs, const Px[] bg, const int[3] want,
                              string what)
{
    assert(pxs.length == bg.length, "reading and background differ in length");
    auto ks = new double[pxs.length];
    foreach (i, p; pxs)
        assert(strokeCoverage(p, bg[i], want, ks[i]),
               format("%s: pixel (%d,%d) reads rgb(%d,%d,%d) over a measured "
                      ~ "background of rgb(%d,%d,%d), which no coverage of "
                      ~ "rgb(%(%d,%)) explains — no single scalar fits all "
                      ~ "three channels, so this pixel is not that stroke over "
                      ~ "that background",
                      what, p.x, p.y, p.r, p.g, p.b,
                      bg[i].r, bg[i].g, bg[i].b, want[]));
    return ks;
}

private double maxOf(const double[] xs) {
    double m = 0;
    foreach (x; xs) if (x > m) m = x;
    return m;
}

private size_t argMax(const double[] xs) {
    size_t bi = 0;
    foreach (i, x; xs) if (x > xs[bi]) bi = i;
    return bi;
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
    postJson("/api/command", commandBody("scene.reset"));
    postJson("/api/command", commandBody("mesh.select", `{"mode":"vertices","indices":[0,1,2,3,4,5,6,7]}`));
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

    // The arm's FOOTPRINT on this sweep: how much of each sampled pixel the
    // shaft covers, measured against that pixel's own background. Requiring
    // every point to fit is itself a claim — that nothing but the X arm and
    // the scene behind it is on this sweep.
    auto covIdleX = coverProfile(idleX, bgX, RGB_AXIS_X, "the idle X arm");
    auto covIdleY = coverProfile(idleY, bgY, RGB_AXIS_Y, "the idle Y arm");

    // The arm is drawn, and drawn at ARM_ALPHA: somewhere on the sweep the
    // shaft covers a whole pixel, so the coverage there IS the alpha.
    //
    // This replaces "some pixel reads the exact composite of the colour at
    // ARM_ALPHA over its background", which said the same thing through a
    // +-3 byte window and could therefore be answered differently by two
    // rasterisers — see COV_TOL. Only the LOWER half is asserted: 0.9975 and
    // 1.0 differ by 0.3 of an 8-bit level, so no probe can hold the upper one
    // (the reasoning retired with the TRANSLUCENT bracket below).
    assert(maxOf(covIdleX) >= ARM_ALPHA - COV_TOL,
           format("the X arm's peak coverage on the centre->tip sweep is only "
                  ~ "%.3f of its colour rgb(%(%d,%)); a shaft drawn at alpha "
                  ~ "%.4f must cover some pixel whole. The arm was not drawn, "
                  ~ "the scheme changed without this test, or it is not being "
                  ~ "drawn at that alpha",
                  maxOf(covIdleX), RGB_AXIS_X[], ARM_ALPHA));
    assert(maxOf(covIdleY) >= ARM_ALPHA - COV_TOL,
           format("the Y arm's peak coverage of rgb(%(%d,%)) is only %.3f — "
                  ~ "the control arm is not on screen, so its silence below "
                  ~ "would prove nothing", RGB_AXIS_Y[], maxOf(covIdleY)));

    // The arm is TRANSLUCENT — RETIRED at task 0604, and deliberately not
    // replaced by something weaker in the same place.
    //
    // This used to be the upper half of a two-sided bracket: nothing on the
    // sweep might read the RAW axis colour, because at one composite of 0.95
    // the centreline lands ~6 counts short of it and the window is 3. The arm
    // is now emitted twice, so its centreline reads 0.9975 — which rounds to
    // the raw colour on every channel over every background this scene offers.
    // The assertion would now fire on a CORRECT build, and widening it to
    // "no more opaque than 0.9975" is not a test at all: 0.9975 and 1.0 differ
    // by 0.3 of an 8-bit level over the widest contrast available, so no probe
    // anywhere can hold that line.
    //
    // The bracket is not abandoned, it moved to where it can still be paid:
    //   * RING_ALPHA below is one emission, still bracketed both ways here, and
    //     is this frame's evidence that alpha is applied per batch at all —
    //     which is the alternative explanation an "arm reads raw" reading
    //     would otherwise leave open.
    //   * tests/test_gizmo_handle_alpha.d Flow B does the same for the rotate
    //     ring at the arm's own literal, and a unittest beside the constants
    //     (handles/gl_util.d) asserts the arm and the ring ARE that one
    //     literal — the link that carries the ring's bracket to the arm.
    //   * Flow C of that file excludes a single emission the way the reference
    //     was measured: the same pixel over two backgrounds 60+ levels apart.
    //   * A unittest in handles/shapes.d asserts the shaft batch really holds
    //     two identical segments, which is the only unambiguous statement of
    //     the mechanism, pixels being unable to make it.

    // Nothing is highlighted yet. Stated explicitly so a build that paints the
    // whole gizmo active could not sail through the comparison.
    //
    // Said at the pixel the arm covers MOST, where a wrong colour has the
    // furthest to travel: the idle reading there must not be explicable as any
    // coverage of the active colour. The rejection is not marginal — the axis
    // colour over this scene's background misses the active colour's line by
    // ~90 counts against a tolerance of 3, so the two remain unconfusable at
    // any byte slop this file could plausibly carry.
    {
        immutable size_t peak = argMax(covIdleX);
        double kBad;
        assert(!strokeCoverage(idleX[peak], bgX[peak], RGB_ACTIVE, kBad),
               format("an unhovered X arm already wears the active colour: "
                      ~ "pixel (%d,%d) reads rgb(%d,%d,%d), which is coverage "
                      ~ "%.3f of rgb(%(%d,%)) over its background",
                      idleX[peak].x, idleX[peak].y,
                      idleX[peak].r, idleX[peak].g, idleX[peak].b,
                      kBad, RGB_ACTIVE[]));
    }

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

    // 1. The arm is now the ACTIVE colour, at every coverage it had. Requiring
    //    the whole sweep to fit is the "colour" half: a pixel still carrying
    //    the axis colour, or carrying a blend of the two, does not lie on the
    //    active colour's line at all.
    //
    //    Said first at the pixel the arm covers MOST, and only then over the
    //    whole sweep, so that a build with no hover cue at all fails on "the
    //    arm did not change colour" rather than on a fit message about the
    //    first fringe pixel in the list.
    {
        immutable size_t peak = argMax(covIdleX);
        double kNow;
        assert(strokeCoverage(hovX[peak], bgX[peak], RGB_ACTIVE, kNow),
               format("the X arm did not change colour under the pointer: its "
                      ~ "most-covered pixel (%d,%d) reads rgb(%d,%d,%d), which "
                      ~ "is no coverage of the active rgb(%(%d,%)) over its "
                      ~ "background rgb(%d,%d,%d) — it is still %.3f covered by "
                      ~ "the axis rgb(%(%d,%)). The hover state is not reaching "
                      ~ "the draw.",
                      hovX[peak].x, hovX[peak].y,
                      hovX[peak].r, hovX[peak].g, hovX[peak].b, RGB_ACTIVE[],
                      bgX[peak].r, bgX[peak].g, bgX[peak].b,
                      covIdleX[peak], RGB_AXIS_X[]));
    }
    auto covHovX = coverProfile(hovX, bgX, RGB_ACTIVE, "the hovered X arm");

    // 2. ...and it covers exactly what it covered before — the FOOTPRINT is
    //    unchanged, pixel for pixel and fringe included. This is the half that
    //    says "colour, and nothing but colour": a size, line-width, outline or
    //    glow change moves how much of a pixel the stroke covers, and the two
    //    profiles stop agreeing.
    //
    //    Compared as coverage rather than as two sets of pixels-that-matched-a-
    //    composite (task 0609). See COV_TOL for why that distinction is the
    //    whole point and not a restatement.
    foreach (i; 0 .. covIdleX.length)
        assert(abs(covIdleX[i] - covHovX[i]) <= COV_TOL,
               format("the X arm's footprint changed under the pointer: pixel "
                      ~ "(%d,%d) was %.3f covered by the arm and is now %.3f "
                      ~ "covered — it reads rgb(%d,%d,%d) where it read "
                      ~ "rgb(%d,%d,%d), over a background of rgb(%d,%d,%d). "
                      ~ "Hover must repaint the handle, not resize or "
                      ~ "re-stroke it.",
                      sweepX[i][0], sweepX[i][1], covIdleX[i], covHovX[i],
                      hovX[i].r, hovX[i].g, hovX[i].b,
                      idleX[i].r, idleX[i].g, idleX[i].b,
                      bgX[i].r, bgX[i].g, bgX[i].b));

    // 3. ...and every pixel got there by the arm being REPAINTED: the step it
    //    took from idle to hovered is along `active - axis`, and its length is
    //    the coverage that pixel has. One equation, and it needs no background
    //    at all — the destination cancels out of a difference — so it is an
    //    independent check on (1) and (2) rather than a third reading of them.
    //
    //    It is also what makes the highlight COMPLETE rather than partial: a
    //    pixel the highlight missed keeps its colour, so it steps by 0 while
    //    still being covered, and fails here by its full coverage. A build with
    //    no hover cue at all fails it at every covered pixel.
    size_t repainted = 0;
    foreach (i; 0 .. sweepX.length) {
        double kStep;
        assert(recolourGain(idleX[i], hovX[i], RGB_AXIS_X, RGB_ACTIVE, kStep),
               format("pixel (%d,%d) changed from rgb(%d,%d,%d) to "
                      ~ "rgb(%d,%d,%d), which is not the X arm repainted from "
                      ~ "rgb(%(%d,%)) to rgb(%(%d,%)) — no single coverage "
                      ~ "explains all three channels",
                      sweepX[i][0], sweepX[i][1],
                      idleX[i].r, idleX[i].g, idleX[i].b,
                      hovX[i].r, hovX[i].g, hovX[i].b,
                      RGB_AXIS_X[], RGB_ACTIVE[]));
        assert(abs(kStep - covIdleX[i]) <= COV_TOL,
               format("pixel (%d,%d) is %.3f covered by the X arm but moved as "
                      ~ "though it were %.3f covered. The hover either did not "
                      ~ "reach this part of the handle, or it repainted "
                      ~ "something that is not the shape the arm occupies.",
                      sweepX[i][0], sweepX[i][1], covIdleX[i], kStep));
        if (covIdleX[i] > 0.5) ++repainted;
    }
    assert(repainted > 0,
           "no pixel on the sweep is even half covered by the X arm, so the "
           ~ "repaint above was asserted over nothing");

    // 4. The control: the Y arm beside it is untouched, pixel for pixel. One
    //    part lights at a time, and the probe is not simply reporting a
    //    global recolour.
    assert(changedIdx(idleY, hovY).length == 0,
           format("hovering the X arm changed %d pixels of the Y arm",
                  changedIdx(idleY, hovY).length));
    auto covHovY = coverProfile(hovY, bgY, RGB_AXIS_Y, "the Y arm, X hovered");
    foreach (i; 0 .. covIdleY.length)
        assert(abs(covIdleY[i] - covHovY[i]) <= COV_TOL,
               format("the Y arm's own footprint moved while the X arm was "
                      ~ "hovered: pixel (%d,%d) went from %.3f to %.3f covered",
                      sweepY[i][0], sweepY[i][1], covIdleY[i], covHovY[i]));
    {
        immutable size_t peakY = argMax(covHovY);
        double kBad;
        assert(!strokeCoverage(hovY[peakY], bgY[peakY], RGB_ACTIVE, kBad),
               format("the Y arm lit up while the pointer was on the X arm: "
                      ~ "pixel (%d,%d) reads rgb(%d,%d,%d), coverage %.3f of "
                      ~ "the active rgb(%(%d,%))",
                      hovY[peakY].x, hovY[peakY].y,
                      hovY[peakY].r, hovY[peakY].g, hovY[peakY].b,
                      kBad, RGB_ACTIVE[]));
    }

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

    // The other half of the exception. Hovered and grabbed differ on BOTH
    // elements now, and by two DIFFERENT mechanisms — which is exactly what
    // makes this handle worth a flow of its own:
    //
    //   the RING — one stroke repainted from the active colour back to its
    //              axis colour, at an unchanged alpha;
    //   the DISC — the same colour at a raised ALPHA (0.2 hovered, 1.0
    //              grabbed), which moves the pixel along the straight line
    //              from wherever it is toward the colour itself.
    //
    // Every pixel on which the two states disagree must be one or the other.
    // A different part, a shading change or a frame shift satisfies neither.
    //
    // Task 0602 note: until the grabbed disc was made opaque this block read
    // "only the RING may tell hovered from grabbed", because the disc had one
    // alpha in both states and its pixels were bit-identical. That premise was
    // an artefact of the missing alpha, not a law — the disc's opacity step is
    // the second half of the measured grab and is now asserted rather than
    // assumed absent.
    size_t nRingStep = 0, nDiscStep = 0;
    auto hovVsGrb = changedIdx(grb, hov);
    foreach (i; hovVsGrb) {
        double kd;
        if (opacityStep(hov[i], grb[i], RGB_ACTIVE, kd)) { ++nDiscStep; continue; }
        double kr;
        if (recolourGain(grb[i], hov[i], RGB_RING, RGB_ACTIVE, kr) && kr > 0) {
            ++nRingStep;
            continue;
        }
        assert(false,
               format("pixel (%d,%d) differs between hovered and grabbed by "
                      ~ "something that is neither the ring's recolour nor the "
                      ~ "disc's opacity step: rgb(%d,%d,%d) vs rgb(%d,%d,%d). "
                      ~ "Those two are the whole of the difference.",
                      rays[i][0], rays[i][1],
                      hov[i].r, hov[i].g, hov[i].b,
                      grb[i].r, grb[i].g, grb[i].b));
    }
    assert(nRingStep > 0,
           "no pixel differs between hovered and grabbed by the RING's own "
           ~ "recolour — the ring is supposed to give its axis colour back on "
           ~ "the grab, and nothing here shows it doing so");
    assert(nDiscStep > 0,
           "no pixel differs between hovered and grabbed by the DISC's opacity "
           ~ "step — the grab is supposed to take the disc to full alpha");

    // ...and the alpha that step lands on is bracketed from both sides, which
    // a direction test alone cannot do. At exactly 1.0 the batch never reaches
    // the blending path, so the disc's centreline reads the RAW colour; at the
    // hover's 0.2 no pixel can, whatever it is drawn over.
    size_t discRaw = 0;
    foreach (i; grbChanged) if (isColor(grb[i], RGB_ACTIVE)) ++discRaw;
    assert(discRaw > 0,
           format("not one of the %d pixels the grab lit reads the raw active "
                  ~ "colour — a grabbed disc is fully opaque and its centreline "
                  ~ "must", grbChanged.length));
    foreach (i; grbChanged)
        assert(!isColor(hov[i], RGB_ACTIVE),
               format("pixel (%d,%d) reads the raw active colour while merely "
                      ~ "HOVERED — hover recolours the disc and must leave its "
                      ~ "alpha at %.2f", rays[i][0], rays[i][1],
                      cast(double)0.20));

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
