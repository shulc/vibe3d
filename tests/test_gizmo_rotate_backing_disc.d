// test_gizmo_rotate_backing_disc.d — the hairline the rotation rings sit on.
//
// The backing disc is the one gizmo part with no clickable existence: it is
// drawn, it is never registered in the Test pass, and no API reports where it
// is. So every number here is recovered FROM THE PIXELS, and the geometry it
// is recovered at is found by the same sweep rather than copied out of the
// draw code. Nothing below reads a radius, a width or a colour from the
// application; every property this file pins is solved for.
//
// THIS FILE USED TO ASSERT THE OPPOSITE OF HALF OF WHAT IT NOW ASSERTS, and
// that history is the reason it is shaped the way it is. It pinned a plate
// filled at alpha 0.20 under a smoothed 2 px outline at alpha 0.75. Those
// three numbers were ported from a reading of a draw function with two arms,
// which described the arm that the reference application never enters — both
// of its call sites select the other one. The three assertions were real, they
// were mutation-verified, and they were verifying a shape that should not
// exist. So the fill assertion is INVERTED rather than deleted: "there is no
// fill" is worth exactly as much as "there is a fill" was, it is proved by the
// same probe, and leaving the file with one fewer assertion would have been
// the wrong lesson to draw from having been wrong.
//
// WHAT IT PINS, AND WHY EACH
//
//   * the disc's COLOUR      — backdrop - 0.15 = (0.21, 0.25, 0.30)
//   * that it has NO FILL    — the interior is the control, to the bit
//   * its OPACITY            — 1.0, i.e. the same ink over two backgrounds
//   * its WIDTH              — 1.0 px, as a LAW at two radii, not a constant
//   * that it is NOT SMOOTHED— hard crossings, against a smoothed control
//   * that it is DECORATIVE  — unhittable, and it never repaints
//   * the view ring's RADIUS — 13/12 of the disc's, not equal to it
//
// Four of those are ways the shape can be wrong that no other one catches. A
// test that checked only the colour would let a fill come back. A test that
// checked only the width would not notice the alpha. And "no fill" and
// "opaque" pull in opposite directions on the same probe — the first says the
// shape must not touch the interior, the second says it must dominate its own
// pixels completely — so neither can be satisfied by a shape that simply is
// not drawn.
//
// HOW OPACITY AND COLOUR ARE RECOVERED — the two-background solve
//
// A part composites as  on = a*C + (1-a)*off,  linear in the background it
// lands on. The disc crosses several very different backgrounds (the mesh, the
// grid, the empty backdrop), so regressing the lit pixel against the SAME pixel
// with the tool dropped recovers the slope and the intercept — and from them
// BOTH the opacity `a` and the colour `C`, with neither assumed to get the
// other. The control is not a second measurement to compare against; it is the
// x-axis of the fit.
//
// For an OPAQUE part that fit is exactly the measurement that proves it opaque:
// `a = 1` means slope 0 means the lit value does not depend on the background
// at all. Flow B asserts it in both forms — as the fitted slope, and as the
// blunter statement that the ink over the darkest backgrounds and the ink over
// the brightest are the same 8-bit triple. At alpha 0.75 those two groups would
// sit about 30 counts apart.
//
// HOW THE WIDTH IS RECOVERED — coverage integrated over an annulus
//
// A single cut across a stroke cannot measure it: the answer depends on where
// the pixel grid falls, and swings between a cut through the centre of a pixel
// and one through its corner. So coverage is integrated over the annulus. For
// a stroke of width w laid along a circle of radius R, the area integral of
// coverage over an angular sector is  w * R * dtheta  — the phase averages
// away, and dividing by the arc length leaves w.
//
// Coverage per pixel is recovered by PROJECTION, not by matching a composite
// value: the scalar k in `k*colour + (1-k)*background`, fitted over all three
// channels with the residual kept as a rejection test. A +-N window around an
// expected composite is a different criterion for every colour it is applied
// to, and it decides sub-pixel-rounding questions the rasteriser owns; k is
// geometric and both rasterisers agree on it.
//
// AND WHY IT IS MEASURED AT TWO RADII. The width is a LAW, not a number: in
// the reference it tracks a line-width preference verbatim and does NOT track
// the handle scale, and it has no floor under it (the other three gizmo strokes
// do). We expose no such preference, so the only half of that law we can
// exercise is the second: at handle scale 2.0 the disc's radius doubles and its
// stroke must not move. A test at one radius would pass just as well on a disc
// whose width was a fraction of its radius.
//
// THE CONTROL FOR BOTH WIDTH AND SMOOTHING is the screen-plane ring, measured
// by the same functions in the same frame. It is 2.5 px and smoothed, and it
// must read as both. Without it, "the disc is 1 px" is a number with nothing to
// say — an instrument that reported 1 px for everything would pass — and, worse,
// "the disc has no soft edges" would pass on a build that had lost antialiasing
// everywhere.
//
// VERIFIED BY MUTATION. Each was applied to the green tree, built, run, and
// then reverted; the assertion named is the one that fired, quoting what it
// reported. Where a flow holds several independent assertions, the later ones
// were reached by neutering the earlier one for a run, so each is verified on
// its own rather than merely shadowed by its neighbour.
//
//   a fill restored at 0.20
//       -> Flow A regression:  "interior composites at opacity 0.2024"
//       -> Flow A census (+):  "2276 of 2374 interior pixels carry exactly the
//                               composite a fill at alpha 0.20 would have left"
//       -> Flow A census (-):  "only 0 of 2374 interior pixels are the
//                               tool-dropped frame bit for bit (0.0 %)"
//   GIZMO_ALPHA_ROTATE_DISC 1.00 -> 0.75
//       -> Flow B fit:         "composites at opacity 0.7509, not 1.00"
//       -> Flow B two-bkgnd:   "reads 66.91 over the darkest fifth ... and
//                               83.42 over the brightest fifth — a 16.52-count
//                               gap", against its own prediction of 16.7
//   rotateBackingDiscColor forced to Vec3(0,0,0)
//       -> Flow B colour:      "drifted on channel 0: -0.0002, wanted 0.2100"
//   bgCircle.smoothStroke = false deleted (the shape stops asking)
//       -> Flow C disc:        "only 4 of 112 sectors ... are a hard crossing
//                               (231 full-coverage pixels, 507 partial)"
//   u_smooth forced to 1.0 in drawThickLines (the mechanism breaks)
//       -> Flow C disc:        the same, 4 of 112
//   u_smooth forced to 0.0 in drawThickLines (AA lost EVERYWHERE)
//       -> Flow C CONTROL:     "only 0 of 180 sectors of the screen-plane ring
//                               hold a partially covered pixel (2048 full, 0
//                               partial)" — the assertion that exists so this
//                               build cannot pass by making the disc look right
//   GIZMO_STROKE_ROTATE_DISC_PX 1.0 -> 2.0
//       -> Flow D width:       "integrates to 1.912 px over 112 sectors"
//   disc width made proportional to the radius, tuned to read 1.0 px at the
//   default handle scale
//       -> Flow D 2nd radius:  "at 239.8 px of radius ... integrates to 1.911 px"
//       -> Flow D the LAW:     "measured 0.956 px at radius 119.9 and 1.911 px
//                               at radius 239.8 — it is tracking its own radius"
//       This is the mutation the single-radius version of this file would have
//       passed, and it is why Flow D steps the handle-size preference.
//   `th.add(handler.bgCircle, base + 4)` in rotate.d's registerHandles
//       -> Flow E hover:       "the pointer at (372, 382) ... went hot on part 14"
//
// The last one is the reason Flow E drives a pointer rather than counting the
// parts in the registry: registering the disc leaves every other flow green,
// because a handle that is only hot UNDER the pointer draws in its own colour
// for every frame those flows measure.
//
// FLOW ORDER IS LOAD-BEARING, twice over. Flow A must precede the ring solve,
// because a fill sits under the stroke as well as inside it and would break the
// instrument before the assertion that names it. And Flow C must precede Flow
// D: with antialiasing lost everywhere the ring geometry degrades enough that
// the WIDTH flow fails first, on a radius it could not locate, reporting
// nothing about the cause. Flow D also steps global state, so it belongs after
// everything that does not.
//
// --------------------------------------------------------------------------

import http_client : getJson, testBaseUrl;
import http_command_helpers : commandBody;
import std.format    : format;
import std.json;
import std.math      : abs, sqrt, cos, sin, atan2, PI, round, floor, isNaN;
import std.algorithm : min, max, sort;
import std.net.curl  : get, post;
import core.thread   : Thread;
import core.time     : msecs;

import drag_helpers : playAndWait;

void main() {}

alias baseUrl = testBaseUrl;

// The scheme, restated as literals rather than imported — the same convention
// tests/test_gizmo_handle_colours.d and test_gizmo_hover_highlight.d use. A
// drift in viewport_scheme.d has to be acknowledged here too.
private enum double BACKDROP_R = 0.36, BACKDROP_G = 0.40, BACKDROP_B = 0.45;
private enum double DISC_DARKEN = 0.15;
// ...and what the derivation lands on. Written out so that BOTH the offset and
// the result have to be edited together if either moves.
private enum double DISC_R = 0.21, DISC_G = 0.25, DISC_B = 0.30;

private enum double DISC_ALPHA = 1.00;   // GIZMO_ALPHA_ROTATE_DISC
private enum double DISC_WIDTH = 1.0;    // GIZMO_STROKE_ROTATE_DISC_PX
private enum double VIEW_WIDTH = 2.5;    // GIZMO_STROKE_ROTATE_RING_PX
private enum double VIEW_RING_RATIO = 13.0 / 12.0;  // GIZMO_VIEW_RING_RADIUS

// The two values task 0610 retired, kept as literals because Flow A hunts for
// them BY NAME: the census below asks how many pixels carry the composite the
// deleted fill would have left, and the answer has to be zero.
private enum double RETIRED_FILL_ALPHA = 0.20;
private enum double RETIRED_RING_ALPHA = 0.75;

// SDL keycodes for the handle-size preference. '-' and '=' step it by +-0.5,
// clamped to [0.5, 5.0]; there is no absolute setter reachable over HTTP, which
// is why Flow D homes the preference by saturating it downward first.
private enum int SDLK_MINUS_  = 45;
private enum int SDLK_EQUALS_ = 61;

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

private void script(string line) {
    auto j = parseJSON(cast(string)post(baseUrl ~ "/api/script", line));
    assert(j["status"].str == "ok", "script `" ~ line ~ "` failed: " ~ j.toString);
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

private void settle() { Thread.sleep(350.msecs); }

private struct Cell { int vx, vy, vw, vh; }

private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int)num(c, "vpX"),   cast(int)num(c, "vpY"),
                cast(int)num(c, "width"), cast(int)num(c, "height"));
}

// Probe CELL-LOCAL pixels. Chunked so the request line stays short.
private int[3][] probe(const int[2][] pts) {
    int[3][] outp;
    for (size_t i = 0; i < pts.length; i += 60) {
        auto slice = pts[i .. min(i + 60, pts.length)];
        string q = "/api/viewport/probe?points=";
        foreach (k, p; slice) {
            if (k) q ~= ";";
            q ~= format("%d,%d", p[0], p[1]);
        }
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        // The --test single-rendered-cell trap: a probe at a never-filled FBO
        // reads zeros and every fit below would converge on nonsense.
        assert(j["renders"].type == JSONType.TRUE,
               "the probed cell is not rendered under --test; the reading is void");
        foreach (e; j["points"].array) {
            if ("error" in e) { outp ~= [-1, -1, -1]; continue; }
            outp ~= [cast(int)num(e, "r"), cast(int)num(e, "g"), cast(int)num(e, "b")];
        }
    }
    return outp;
}

// The FBO's ALPHA channel at those same pixels. Kept separate from `probe`
// because every other reading here is a colour and carrying a fourth number
// through the fits would only invite it to be fitted.
private int[] probeAlpha(const int[2][] pts) {
    int[] outp;
    for (size_t i = 0; i < pts.length; i += 60) {
        auto slice = pts[i .. min(i + 60, pts.length)];
        string q = "/api/viewport/probe?points=";
        foreach (k, p; slice) {
            if (k) q ~= ";";
            q ~= format("%d,%d", p[0], p[1]);
        }
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        assert(j["renders"].type == JSONType.TRUE,
               "the probed cell is not rendered under --test; the reading is void");
        foreach (e; j["points"].array)
            outp ~= ("error" in e) ? -1 : cast(int)num(e, "a");
    }
    return outp;
}

private struct Handles { double[2][int] screen; int hot; int vx, vy; }

private Handles handles() {
    auto j = getJson("/api/tool/handles");
    assert(j["handles"].type != JSONType.null_,
           "/api/tool/handles reports no handles — no tool is armed");
    auto h = j["handles"];
    Handles o;
    o.hot = cast(int)num(h, "hot");
    o.vx  = cast(int)num(h, "viewport", "x");
    o.vy  = cast(int)num(h, "viewport", "y");
    foreach (e; h["parts"].array)
        o.screen[cast(int)num(e, "part")] =
            [e["screen"].array[0].floating, e["screen"].array[1].floating];
    return o;
}

// Park the pointer, with no button pressed, and leave it there — the player's
// mouse override is never cleared, so the hover persists into every frame
// drawn afterwards. Same mechanism as test_gizmo_hover_highlight.d.
private void hoverAt(Cell c, int wx, int wy) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n", c.vx, c.vy, c.vw, c.vh);
    foreach (i; 0 .. 5)
        log ~= format(
            `{"t":%.3f,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}`
            ~ "\n", 50.0 + i * 20.0, wx, wy);
    playAndWait(log);
}

// ---------------------------------------------------------------------------
// The handle-size preference, driven the only way a test can reach it
// ---------------------------------------------------------------------------

private void pressKey(Cell c, int sym, int times) {
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}`
        ~ "\n", c.vx, c.vy, c.vw, c.vh);
    double t = 30.0;
    foreach (i; 0 .. times) {
        log ~= format(
            `{"t":%.3f,"type":"SDL_KEYDOWN","sym":%d,"scan":0,"mod":0,"repeat":0}`
            ~ "\n", t, sym);
        t += 12.0;
    }
    playAndWait(log);
    settle();
}

// Put the handle-size preference on a KNOWN value, from whatever it happens to
// be. There is no absolute setter over HTTP and `/api/reset` does not restore
// it — it is process-global state that outlives a reset, so a test that stepped
// it and returned would hand the next test in the same worker a gizmo of the
// wrong size. Saturating downward first (the preference clamps at 0.5) makes
// this idempotent and independent of the inbound state, including a leak from
// an earlier failure.
//
// `stepsUp` counts +0.5 presses from that floor: 1 -> 1.0, 3 -> 2.0.
private void homeHandleScale(Cell c, int stepsUp) {
    pressKey(c, SDLK_MINUS_, 12);
    if (stepsUp > 0) pressKey(c, SDLK_EQUALS_, stepsUp);
}

// ---------------------------------------------------------------------------
// The fits
// ---------------------------------------------------------------------------

// `alpha` is an ACCUMULATOR (the mean of the three channels' fits) and is
// therefore written `= 0`: `double.init` is NaN in D, and `NaN += x` is NaN,
// so the default would turn every reading below into "nothing found".
private struct Fit { double alpha = 0; double[3] color; size_t kept, total; }

// on = a*C + (1-a)*off, per channel, with iterative outlier rejection. The
// outliers are not noise — they are the pixels an axis ring also covers, which
// obey a different law and would otherwise drag the line.
private Fit solve(const int[3][] on, const int[3][] off) {
    assert(on.length == off.length);
    Fit f;
    foreach (ch; 0 .. 3) {
        double[] xs, ys;
        foreach (i; 0 .. on.length) {
            if (on[i][0] < 0 || off[i][0] < 0) continue;
            xs ~= cast(double)off[i][ch];
            ys ~= cast(double)on[i][ch];
        }
        assert(xs.length >= 50,
               format("only %d usable pixels for channel %d", xs.length, ch));
        bool[] keep = new bool[xs.length];
        keep[] = true;
        double a = 0, c = 0;
        foreach (iter; 0 .. 6) {
            double sx = 0, sy = 0; size_t n = 0;
            foreach (i; 0 .. xs.length) if (keep[i]) { sx += xs[i]; sy += ys[i]; ++n; }
            assert(n >= 50, "outlier rejection ate the sample");
            immutable double mx = sx / n, my = sy / n;
            double sxx = 0, sxy = 0;
            foreach (i; 0 .. xs.length) if (keep[i]) {
                sxx += (xs[i] - mx) * (xs[i] - mx);
                sxy += (xs[i] - mx) * (ys[i] - my);
            }
            assert(sxx > 1.0,
                   "the backgrounds under the sampled pixels are all the same "
                   ~ "value, so slope and intercept cannot be separated — the "
                   ~ "solve needs the disc to span more than one background");
            immutable double slope = sxy / sxx;
            a = 1.0 - slope;
            c = (my - slope * mx) / (abs(a) > 1e-6 ? a : 1e-6);
            // Median absolute residual sets the rejection band, so one bright
            // ring crossing cannot widen it enough to keep itself.
            double[] res;
            foreach (i; 0 .. xs.length) if (keep[i])
                res ~= abs(ys[i] - (slope * xs[i] + (my - slope * mx)));
            res.sort();
            immutable double thr = max(2.0, 4.0 * res[res.length / 2] + 1.0);
            size_t left = 0;
            foreach (i; 0 .. xs.length) {
                keep[i] = keep[i] && abs(ys[i] - (slope * xs[i] + (my - slope * mx))) <= thr;
                if (keep[i]) ++left;
            }
            if (left < 50) break;
        }
        f.alpha += a / 3.0;
        f.color[ch] = c;
        if (ch == 0) {
            f.total = xs.length;
            size_t k = 0; foreach (b; keep) if (b) ++k;
            f.kept = k;
        }
    }
    return f;
}

// COVERAGE at one pixel, by projection: the scalar k in
//   on = k*colour + (1-k)*off
// fitted across all three channels at once, with `residual` reporting how far
// the pixel is from lying on that line at all.
//
// This replaces matching against an expected composite VALUE. A `+-N` window
// around a composite converts into a different coverage window for every colour
// it is applied to — divide the window by the distance from background to ink —
// so two shapes compared that way are compared by two different criteria, and
// whether a given pixel falls inside is a fact about the rasteriser's sub-pixel
// rounding rather than about the shape. `k` is geometric: it is pixel coverage
// times the part's own alpha, it is what the two estimators below actually
// want, and the software and hardware rasterisers agree on it.
//
// `residual` is the rejection test that keeps "not this colour at all" out: a
// saturated axis ring crossing the annulus does not lie near this line and is
// dropped, rather than contributing a nonsense k.
//
// Returns NaN when the background is too close to the ink to carry a reading —
// the projection's denominator, not an arbitrary threshold.
private double covOf(const int[3] on, const int[3] off, const double[3] colour,
                     out double residual)
{
    residual = double.nan;
    if (on[0] < 0 || off[0] < 0) return double.nan;
    double dd = 0;
    double[3] d;
    foreach (ch; 0 .. 3) {
        d[ch] = colour[ch] - off[ch];
        dd += d[ch] * d[ch];
    }
    if (dd < 400.0) return double.nan;      // < 20 counts of total contrast
    double numr = 0;
    foreach (ch; 0 .. 3) numr += (on[ch] - off[ch]) * d[ch];
    immutable double k = numr / dd;
    double r = 0;
    foreach (ch; 0 .. 3) r = max(r, abs((on[ch] - off[ch]) - k * d[ch]));
    residual = r;
    return k;
}

// ---------------------------------------------------------------------------
// The scan — done once at handle scale 1.0, shared by every flow.
// ---------------------------------------------------------------------------

private struct Ring {
    double radius;                 // radius the sweep FOUND it at
    int[2][] pts;                  // cell-local annulus pixels
    double[] dist, ang;            // exact polar coords of each
    int[3][] on, off;
    double[3] colour;              // solved from its own full-coverage core
    double alpha;                  // ...and so is this
    // The k a fully-covered pixel of THIS ring reaches, i.e. its opacity.
    // `covOf` reports coverage times opacity; the two estimators below want
    // coverage alone, so both divide by this. Without it a ring's measured
    // WIDTH quietly carries its alpha as a factor — the screen-plane ring at
    // 0.95 read 2.36 px for a 2.5 px stroke — and its measured EDGES would
    // classify a fully covered pixel as partial on any part below 0.88.
    double plateau = 1.0;
}

private struct Scan {
    bool ready;
    Cell c;
    double cx, cy;                 // gizmo centre, cell-local
    int[2][] inner;                // disc interior, subsampled
    int[3][] innerOn, innerOff;
    int[2][] alphaPts;             // a thinner subset, read on the ALPHA channel
    int[]    alphaOn, alphaOff;
    Ring disc, view;
}

private Scan g_scan;

private void armRotate() {
    post(baseUrl ~ "/api/command", commandBody("scene.reset", "{}"));
    settle();
    script("tool.set rotate");
    settle();
}

private void dropRotate() { script("tool.set rotate off"); settle(); }

// Find the two outermost circular features by sweeping rays outward from the
// centre. The screen-plane ring is the outermost; the backing disc is the next
// one in. Nothing here knows either radius in advance — which is the point: a
// test that took 120 px from the source would still pass if the gizmo silently
// changed size, and Flow D deliberately CHANGES the size and re-runs this.
//
// Each feature is located by the ink CENTROID of its own contiguous run, which
// is exact for a 1 px stroke and unbiased for a wider one. (It used to pull the
// disc's reading 1.5 px inward to compensate for a fill's outer edge sitting at
// the same radius; there is no fill, so there is nothing to compensate for.)
//
// Both values are only SEEDS — every radius a measurement rests on is re-fitted
// from the coverage centroid further down. +-2 px here is harmless.
private double[2] locateRings(ref Scan s, int R0, int R1) {
    enum int RAYS = 12;
    int[2][] pts;
    foreach (k; 0 .. RAYS) {
        immutable double t = 2.0 * PI * k / RAYS;
        foreach (r; R0 .. R1 + 1)
            pts ~= [cast(int)round(s.cx + cos(t) * r), cast(int)round(s.cy + sin(t) * r)];
    }
    script("tool.set rotate"); settle();
    auto on = probe(pts);
    dropRotate();
    auto off = probe(pts);
    script("tool.set rotate"); settle();

    double[] outer, inner;
    immutable int N = R1 - R0 + 1;
    foreach (k; 0 .. RAYS) {
        // Contiguous runs of changed pixels along this ray, innermost first.
        int[2][] runs;
        int runA = -1, runB = -1;
        foreach (i; 0 .. N) {
            immutable size_t idx = k * N + i;
            immutable bool lit = on[idx][0] >= 0 && off[idx][0] >= 0
                && (abs(on[idx][0] - off[idx][0]) + abs(on[idx][1] - off[idx][1])
                    + abs(on[idx][2] - off[idx][2])) > 10;
            if (lit) { if (runA < 0) runA = i; runB = i; }
            else if (runA >= 0) { runs ~= [runA, runB]; runA = -1; }
        }
        if (runA >= 0) runs ~= [runA, runB];
        if (runs.length < 2) continue;
        // Ink centroid of a run, weighted by how far it moved the pixel.
        double centroid(int[2] run) {
            double numr = 0, den = 0;
            foreach (i; run[0] .. run[1] + 1) {
                immutable size_t idx = k * N + i;
                immutable double w = abs(on[idx][0] - off[idx][0])
                                   + abs(on[idx][1] - off[idx][1])
                                   + abs(on[idx][2] - off[idx][2]);
                numr += (R0 + i) * w; den += w;
            }
            return den < 1.0 ? double.nan : numr / den;
        }
        immutable double ro = centroid(runs[$ - 1]);
        immutable double ri = centroid(runs[$ - 2]);
        if (isNaN(ro) || isNaN(ri)) continue;
        outer ~= ro;
        inner ~= ri;
    }
    assert(outer.length >= 8,
           format("only %d of %d rays found two concentric features between "
                  ~ "%d and %d px — the rotate gizmo is not on screen as "
                  ~ "expected", outer.length, RAYS, R0, R1));
    outer.sort(); inner.sort();
    immutable double ro = outer[outer.length / 2], ri = inner[inner.length / 2];
    assert(ro - ri > 4.0 && ro - ri < 0.30 * ro,
           format("the two outermost features are %.1f px apart (%.1f and %.1f); "
                  ~ "that is not the screen-plane ring outside the backing disc",
                  ro - ri, ri, ro));
    return [ri, ro];
}

private void scanRing(ref Ring rg, ref Scan s, double halfBand) {
    rg.pts = null; rg.dist = null; rg.ang = null;
    foreach (y; cast(int)floor(s.cy - rg.radius - halfBand - 2)
              .. cast(int)(s.cy + rg.radius + halfBand + 3))
    foreach (x; cast(int)floor(s.cx - rg.radius - halfBand - 2)
              .. cast(int)(s.cx + rg.radius + halfBand + 3)) {
        immutable double dx = x + 0.5 - s.cx, dy = y + 0.5 - s.cy;
        immutable double d = sqrt(dx * dx + dy * dy);
        if (d < rg.radius - halfBand || d > rg.radius + halfBand) continue;
        if (x < 0 || y < 0 || x >= s.c.vw || y >= s.c.vh) continue;
        rg.pts ~= [x, y];
        rg.dist ~= d;
        double a = atan2(dy, dx) * 180.0 / PI;
        if (a < 0) a += 360.0;
        rg.ang ~= a;
    }
    assert(rg.pts.length > 500, "annulus is too small to integrate over");
}

// Probe one annulus lit and unlit, then solve its own colour, opacity and
// radius from its own pixels. Every ring here is measured on its OWN recovered
// values, so nothing about the screen-plane ring is assumed when it is used as
// a control for the disc, and nothing about the disc's colour is assumed when
// its opacity is read.
//
// THE THREE-STAGE BOOTSTRAP, and why each stage is needed.
//
// (1) A PER-SECTOR radius, from a colour-free ink centroid. A GLOBAL centroid
//     is not good enough here, and the reason is specific: the three axis arcs
//     lie at the SAME radius as the backing disc and are 2.5 px wide and
//     smoothed, so they drag the global figure outward by ~0.4 px — measured,
//     120.29 against the disc's true 119.87. A quarter-pixel core band taken at
//     the wrong centre lands one quarter ON the stroke and the rest on unlit
//     background, and unlit pixels read as coverage 0 and pull the fitted
//     opacity down (measured: 0.91 for a stroke that is 1.00). Per sector, the
//     figure is also free of the 64-gon's 0.14 px dip between vertices.
//
// (2) A first robust fit on that geometric core. It still contains the axis
//     arcs where they cross, but they are a minority in three different
//     saturated colours while the disc is one colour, so the median-residual
//     rejection inside `solve` converges on the disc.
//
// (3) A re-selection by PARALLELISM to the colour stage 2 recovered, then the
//     fit that is actually reported. This is deliberately not a re-selection by
//     value: the residual test asks only that a pixel lies on the line from its
//     own background toward that colour, and leaves the DISTANCE along that
//     line — which is coverage times opacity, i.e. the answer — completely
//     free. A stroke of the same colour at half the opacity is selected by this
//     step and then reported as half the opacity.
private void readRing(ref Ring rg, ref Scan s) {
    script("tool.set rotate"); settle();
    rg.on  = probe(rg.pts);
    dropRotate();
    rg.off = probe(rg.pts);
    script("tool.set rotate"); settle();

    // ---- (1) per-sector radius, colour-free ------------------------------
    enum double BIN = 2.0;
    size_t[][int] grouped;
    foreach (i; 0 .. rg.pts.length)
        grouped[cast(int)floor(rg.ang[i] / BIN)] ~= i;

    double[int] secR;
    double[] all;
    foreach (k, idxs; grouped) {
        double numr = 0, den = 0;
        foreach (i; idxs) {
            if (rg.on[i][0] < 0 || rg.off[i][0] < 0) continue;
            immutable double w = abs(rg.on[i][0] - rg.off[i][0])
                               + abs(rg.on[i][1] - rg.off[i][1])
                               + abs(rg.on[i][2] - rg.off[i][2]);
            numr += rg.dist[i] * w; den += w;
        }
        if (den < 1.0) continue;
        secR[k] = numr / den;
        all ~= numr / den;
    }
    assert(all.length >= 40,
           format("only %d angular sectors of this ring left any ink at all",
                  all.length));
    all.sort();
    immutable double medR = all[all.length / 2];

    // ---- (2) first fit, on sectors that agree with that median ------------
    // A sector whose own ink centroid disagrees with the ring's is a sector
    // with something else in it. Colour-free, so it runs before any colour is
    // known, and it removes most of the axis-arc contamination up front.
    int[3][] on1, off1;
    foreach (k, idxs; grouped) {
        auto pr = k in secR;
        if (pr is null || abs(*pr - medR) > 0.6) continue;
        foreach (i; idxs)
            if (abs(rg.dist[i] - *pr) < 0.25 && rg.on[i][0] >= 0 && rg.off[i][0] >= 0) {
                on1 ~= rg.on[i]; off1 ~= rg.off[i];
            }
    }
    assert(on1.length >= 60,
           format("this ring's geometric core held only %d pixels", on1.length));
    auto f1 = solve(on1, off1);

    // ---- (3) re-select by parallelism, then the reported fit --------------
    //
    // `covOf` returns coverage TIMES opacity, and only the first factor is
    // meant to select here. So the full-coverage set is taken relative to the
    // ring's OWN plateau — the value k settles at where the stroke covers a
    // pixel completely — rather than against an absolute 1.0. Against an
    // absolute threshold this step silently empties for any stroke below that
    // opacity, and the first thing to fail is the instrument rather than the
    // opacity assertion that should have caught it. (Measured: at opacity 0.75
    // a `k >= 0.90` rule selects nothing at all.)
    double[] ks;
    foreach (i; 0 .. rg.pts.length) {
        double res;
        immutable double k = covOf(rg.on[i], rg.off[i], f1.color, res);
        if (isNaN(k) || isNaN(res) || res > 6.0) continue;
        ks ~= k;
    }
    assert(ks.length >= 100,
           format("only %d pixels of this ring's annulus are explained by its "
                  ~ "own colour", ks.length));
    ks.sort();
    immutable double kPeak = ks[cast(size_t)(ks.length * 97 / 100)];
    assert(kPeak > 0.10,
           format("this ring's strongest pixels reach only %.3f of its own "
                  ~ "colour; there is no stroke here to measure", kPeak));

    int[3][] on2, off2;
    double numr2 = 0, den2 = 0;
    foreach (i; 0 .. rg.pts.length) {
        double res;
        immutable double k = covOf(rg.on[i], rg.off[i], f1.color, res);
        if (isNaN(k) || isNaN(res) || res > 6.0) continue;
        if (k > 0.05 * kPeak) { numr2 += rg.dist[i] * k; den2 += k; }
        if (k >= 0.90 * kPeak) { on2 ~= rg.on[i]; off2 ~= rg.off[i]; }
    }
    assert(on2.length >= 60,
           format("this ring's full-coverage set held only %d pixels", on2.length));
    assert(den2 > 1.0, "this ring left no coverage to centre on");
    auto f2 = solve(on2, off2);
    rg.alpha  = f2.alpha;
    rg.colour = f2.color;
    rg.radius = numr2 / den2;
    // The plateau the two estimators below normalise by. Taken from the FIT
    // rather than from the percentile above, so it is the opacity the flow
    // reports and not a sample statistic of it.
    rg.plateau = f2.alpha;
    assert(rg.plateau > 0.10,
           format("this ring fitted an opacity of %.3f", rg.plateau));
}

// Returns a POINTER, not a reference, and that is not a style choice: `auto s
// = scan()` on a `ref Scan` silently takes a COPY, so a flow that captured the
// scan before `solveRings` filled in the rings' colours read them back as the
// `double.init` NaN they started as. Through a pointer every flow sees the live
// state whatever order the fills happen in.
private Scan* scan() {
    if (g_scan.ready) return &g_scan;
    armRotate();
    g_scan.c = cell();

    // The preference is process-global and survives /api/reset, so put it on
    // its default before anything is measured at it.
    homeHandleScale(g_scan.c, 1);
    script("tool.set rotate"); settle();

    auto h = handles();
    assert(10 in h.screen,
           "the rotate bank publishes no ring parts — nothing to centre on");
    g_scan.cx = h.screen[10][0] - h.vx;
    g_scan.cy = h.screen[10][1] - h.vy;

    immutable double[2] radii = locateRings(g_scan, 55, 195);
    g_scan.disc.radius = radii[0];
    g_scan.view.radius = radii[1];

    // Interior: every third pixel, out to well clear of the stroke.
    foreach (y; cast(int)(g_scan.cy - g_scan.disc.radius)
              .. cast(int)(g_scan.cy + g_scan.disc.radius + 1)) {
        if (y % 3) continue;
        foreach (x; cast(int)(g_scan.cx - g_scan.disc.radius)
                  .. cast(int)(g_scan.cx + g_scan.disc.radius + 1)) {
            if (x % 3) continue;
            immutable double dx = x + 0.5 - g_scan.cx, dy = y + 0.5 - g_scan.cy;
            immutable double d = sqrt(dx * dx + dy * dy);
            if (d < 22.0 || d > g_scan.disc.radius - 7.0) continue;
            if (x < 0 || y < 0 || x >= g_scan.c.vw || y >= g_scan.c.vh) continue;
            g_scan.inner ~= [x, y];
        }
    }
    assert(g_scan.inner.length > 500, "the disc interior sampled too few pixels");

    scanRing(g_scan.disc, g_scan, 3.0);
    scanRing(g_scan.view, g_scan, 3.5);

    // A thin subset of the DISC'S OWN ANNULUS, read on the alpha channel. On
    // the stroke and its immediate surround, deliberately: that band is where
    // the hard-edged path writes zero-coverage fragments, and zero-coverage is
    // exactly what would punch a hole if the alpha blend were ever changed away
    // from GL_ZERO/GL_ONE. The interior, where this used to sample, is now a
    // band nothing draws in at all.
    for (size_t i = 0; i < g_scan.disc.pts.length;
         i += g_scan.disc.pts.length / 60 + 1)
        g_scan.alphaPts ~= g_scan.disc.pts[i];

    script("tool.set rotate"); settle();
    g_scan.innerOn  = probe(g_scan.inner);
    g_scan.alphaOn  = probeAlpha(g_scan.alphaPts);
    dropRotate();
    g_scan.innerOff = probe(g_scan.inner);
    g_scan.alphaOff = probeAlpha(g_scan.alphaPts);
    script("tool.set rotate"); settle();

    g_scan.ready = true;
    return &g_scan;
}

// The two rings' colour / opacity / radius, solved on demand.
//
// DELIBERATELY NOT PART OF `scan()`. Flow A — "there is no fill" — needs the
// interior and nothing else, and it must be able to report a fill that has come
// back. Solving the STROKE first would put the instrument in front of that
// assertion: a fill sits under the stroke as well as inside it, so it moves the
// pixels `readRing` bootstraps from, and the first thing to fail would be a
// message about a ring's full-coverage set being empty. Which is true, and
// says nothing. Flow A runs first and answers first.
private bool g_ringsReady;

private void solveRings() {
    if (g_ringsReady) return;
    auto s = scan();
    readRing(g_scan.disc, g_scan);
    readRing(g_scan.view, g_scan);
    g_ringsReady = true;
}

// ---------------------------------------------------------------------------
// Flow A — there is NO FILL: the interior is the control, to the bit.
// ---------------------------------------------------------------------------

unittest {
    auto s = scan();

    // The lever the solve rests on, kept from when this flow measured a fill:
    // an interior lying on one flat background would make the regression
    // singular. It still matters — it is what makes "the interior did not move"
    // a strong statement rather than a tautology about a uniform field.
    int lo = 255, hi = 0;
    foreach (p; s.innerOff) if (p[0] >= 0) { lo = min(lo, p[0]); hi = max(hi, p[0]); }
    assert(hi - lo >= 40,
           format("the disc interior spans only %d counts of background "
                  ~ "(%d..%d); with no lever, 'nothing composited here' is not "
                  ~ "a claim about the disc", hi - lo, lo, hi));

    // (1) THE REGRESSION. The same fit that used to report 0.20 must now
    // report nothing. It is the sensitive half of this flow: it would catch a
    // fill at an alpha far too low to leave a recognisable composite value.
    auto f = solve(s.innerOn, s.innerOff);
    assert(abs(f.alpha) <= 0.03,
           format("the disc's interior composites at opacity %.4f — something "
                  ~ "is being drawn across the whole inside of the backing "
                  ~ "disc. There is no fill: the reference emits ONE batch for "
                  ~ "this shape and it is a line batch. (This assertion used to "
                  ~ "demand %.2f, from a reading of a draw path the reference "
                  ~ "never takes.)", f.alpha, RETIRED_FILL_ALPHA));

    // (2) THE CENSUS, positive form: how many pixels carry the exact composite
    // the deleted fill would have left. Only pixels where that composite is
    // DISTINGUISHABLE from the bare background are counted — over a background
    // already near the disc's own colour a fill changes nothing, and counting
    // those would quietly turn this into a weaker test than it looks.
    immutable double[3] disc = [DISC_R * 255.0, DISC_G * 255.0, DISC_B * 255.0];
    foreach (a; [RETIRED_FILL_ALPHA, 0.10, 0.30]) {
        size_t discriminating = 0, matched = 0;
        foreach (i; 0 .. s.inner.length) {
            if (s.innerOn[i][0] < 0 || s.innerOff[i][0] < 0) continue;
            int[3] pred;
            int sep = 0;
            foreach (ch; 0 .. 3) {
                pred[ch] = cast(int)round(a * disc[ch] + (1.0 - a) * s.innerOff[i][ch]);
                sep = max(sep, cast(int)abs(pred[ch] - s.innerOff[i][ch]));
            }
            if (sep < 3) continue;
            ++discriminating;
            int err = 0;
            foreach (ch; 0 .. 3) err = max(err, cast(int)abs(s.innerOn[i][ch] - pred[ch]));
            if (err <= 1) ++matched;
        }
        assert(discriminating >= 500,
               format("only %d interior pixels could tell a fill at %.2f from "
                      ~ "no fill; the census has nothing to say", discriminating, a));
        assert(matched * 200 <= discriminating,
               format("%d of %d interior pixels carry exactly the composite a "
                      ~ "fill at alpha %.2f would have left. The backing disc "
                      ~ "must have NO fill at any opacity.",
                      matched, discriminating, a));
    }

    // (3) THE CENSUS, negative form: how much of the interior is the control
    // BIT FOR BIT. A fill at any opacity above zero would have tinted every one
    // of these pixels. The remainder is the rings, the arms, the centre handle,
    // the work-plane grid and the rig mesh, all of which legitimately cross.
    size_t exact = 0, usable = 0;
    foreach (i; 0 .. s.inner.length) {
        if (s.innerOn[i][0] < 0 || s.innerOff[i][0] < 0) continue;
        ++usable;
        if (s.innerOn[i] == s.innerOff[i]) ++exact;
    }
    assert(exact * 4 >= usable * 3,
           format("only %d of %d interior pixels are the tool-dropped frame bit "
                  ~ "for bit (%.1f %%). The inside of the backing disc is where "
                  ~ "nothing is drawn.", exact, usable, 100.0 * exact / usable));

    // THE CELL'S OWN ALPHA, on the stroke band. Two things could move it: a
    // batch that writes destination alpha at all, and — specific to the
    // hard-edged path — the zero-coverage fragments the geometry stage still
    // rasterises OUTSIDE the stroke, which reach the framebuffer at alpha 0.
    // Neither may touch it, because the cell FBO's alpha is what ImGui
    // composites the cell with and a hole there shows the panel through the
    // gizmo. The blend has to stay `GL_ZERO / GL_ONE` on alpha.
    //
    // Asserted as a DIFFERENCE, not against 255. The cell is not uniformly
    // opaque to begin with — the mesh's own antialiased wireframe leaves 248 on
    // the pixels it covers, with no gizmo anywhere near — so "alpha is 255"
    // would be a claim about the mesh, and it fails on a tree where nothing is
    // wrong. What the disc owes is that it does not MOVE the number.
    {
        assert(s.alphaPts.length >= 20, "too few alpha samples to mean anything");
        size_t moved = 0; size_t firstK = 0;
        foreach (k; 0 .. s.alphaPts.length)
            if (s.alphaOn[k] != s.alphaOff[k]) { if (!moved) firstK = k; ++moved; }
        assert(moved == 0,
               format("%d of %d pixels on the backing disc's stroke band changed "
                      ~ "the cell FBO's ALPHA when the gizmo was drawn — e.g. "
                      ~ "(%d, %d) went %d -> %d. The handle pass must blend "
                      ~ "colour normally and leave alpha alone (GL_ZERO/GL_ONE), "
                      ~ "or ImGui composites a hole where the gizmo is.",
                      moved, s.alphaPts.length,
                      s.alphaPts[firstK][0], s.alphaPts[firstK][1],
                      s.alphaOff[firstK], s.alphaOn[firstK]));
    }
}

// ---------------------------------------------------------------------------
// Flow B — the stroke is OPAQUE, and in the derived colour.
//
// Opacity is asserted twice, from the same pixels, in two forms that fail for
// different reasons. The FIT is sensitive and continuous; the TWO-GROUP
// comparison is the statement in its blunt form — the same ink over two very
// different backgrounds — and it is the one that reads as an explanation when
// it fires.
// ---------------------------------------------------------------------------

unittest {
    auto s = scan();
    solveRings();

    assert(abs(s.disc.alpha - DISC_ALPHA) <= 0.06,
           format("the backing disc's stroke composites at opacity %.4f, not "
                  ~ "%.2f. It carries no alpha at all in the reference, which "
                  ~ "on that path means blending is switched off for it; ours "
                  ~ "reaches the same pixels at exactly 1.0. (This assertion "
                  ~ "used to demand %.2f.)",
                  s.disc.alpha, DISC_ALPHA, RETIRED_RING_ALPHA));

    immutable double[3] want = [DISC_R, DISC_G, DISC_B];
    foreach (ch; 0 .. 3) {
        immutable double got = s.disc.colour[ch] / 255.0;
        assert(abs(got - want[ch]) <= 0.02,
               format("the backing disc's colour drifted on channel %d: %.4f, "
                      ~ "wanted %.4f. The disc is the viewport backdrop minus "
                      ~ "%.2f per channel and must be DERIVED from "
                      ~ "SchemeColor.backdrop, never written down. (Pure black "
                      ~ "— %.4f — is what it used to be, and is what a reading "
                      ~ "near 0 means.)", ch, got, want[ch], DISC_DARKEN, 0.0));
    }

    // THE TWO-BACKGROUND COMPARISON. Split the stroke's fully-covered pixels by
    // the brightness of what they cover, and compare the ink itself. An opaque
    // stroke reads identically in both groups; one at alpha `a` reads
    // `(1-a) * (bgHi - bgLo)` apart, which at 0.75 over the span asserted below
    // is tens of counts.
    double[] bgs;
    size_t[] full;
    foreach (i; 0 .. s.disc.pts.length) {
        double res;
        immutable double k = covOf(s.disc.on[i], s.disc.off[i], s.disc.colour, res);
        // 0.98 rather than 0.95: on a SMOOTHED stroke the looser bound admits
        // fringe pixels whose coverage is high but not 1, and those do vary
        // with the background — which would make this flow fire for a
        // smoothing change, i.e. for Flow C's reason under Flow B's name.
        if (isNaN(k) || isNaN(res) || res > 6.0 || k < 0.98 * s.disc.plateau)
            continue;
        full ~= i;
        bgs  ~= cast(double)s.disc.off[i][1];
    }
    assert(full.length >= 60,
           format("only %d fully-covered stroke pixels; the two-background "
                  ~ "comparison would be noise", full.length));

    // The two groups are the TAILS — the darkest fifth of the backgrounds the
    // stroke crosses and the brightest fifth — rather than the halves either
    // side of the median. What the disc lies on is not evenly spread (about
    // half of it is over one flat backdrop value), so a median split puts two
    // nearly identical groups on the two sides and throws the lever away; the
    // tails keep the widest separation the frame actually offers.
    auto order = new size_t[full.length];
    foreach (j; 0 .. full.length) order[j] = j;
    order.sort!((x, y) => bgs[x] < bgs[y]);
    immutable size_t tail = max(cast(size_t)15, full.length / 5);
    assert(2 * tail <= full.length,
           format("only %d fully-covered pixels — too few to split into tails",
                  full.length));

    double[3] sumLo = 0, sumHi = 0;
    double bgLo = 0, bgHi = 0;
    foreach (j; 0 .. tail) {
        immutable size_t iLo = full[order[j]];
        immutable size_t iHi = full[order[$ - 1 - j]];
        bgLo += bgs[order[j]];
        bgHi += bgs[order[$ - 1 - j]];
        foreach (ch; 0 .. 3) {
            sumLo[ch] += s.disc.on[iLo][ch];
            sumHi[ch] += s.disc.on[iHi][ch];
        }
    }
    immutable size_t nLo = tail, nHi = tail;
    bgLo /= tail; bgHi /= tail;
    assert(bgHi - bgLo >= 25.0,
           format("the stroke's fully-covered pixels cover backgrounds spanning "
                  ~ "only %.1f counts (mean %.0f against mean %.0f over %d "
                  ~ "pixels each). Two backgrounds that alike cannot separate "
                  ~ "an opaque stroke from a translucent one.",
                  bgHi - bgLo, bgLo, bgHi, tail));
    foreach (ch; 0 .. 3) {
        immutable double mLo = sumLo[ch] / nLo, mHi = sumHi[ch] / nHi;
        // What a translucent stroke would have shown here, so the failure names
        // its own margin rather than only its tolerance.
        immutable double predicted = (1.0 - RETIRED_RING_ALPHA) * (bgHi - bgLo);
        // Tolerance from the SIGNAL, not from taste: the opacity this replaced
        // would show ~17 counts here, and residual sub-pixel effects show ~2.
        // 4.0 sits between them with a 4x margin on the thing it must catch.
        assert(abs(mLo - mHi) <= 4.0,
               format("channel %d of the backing disc's ink reads %.2f over the "
                      ~ "darker quarter of its backgrounds and %.2f over the "
                      ~ "brightest fifth — a %.2f-count gap. An OPAQUE stroke reads "
                      ~ "the same over both. At alpha %.2f the gap would be "
                      ~ "about %.1f counts, which is what this shape used to be "
                      ~ "asserted to have.",
                      ch, mLo, mHi, abs(mLo - mHi), RETIRED_RING_ALPHA, predicted));
    }

    // The derivation, checked against the backdrop restated at the top of this
    // file rather than against a second copy of the triple.
    immutable double[3] backdrop = [BACKDROP_R, BACKDROP_G, BACKDROP_B];
    foreach (ch; 0 .. 3)
        assert(abs((backdrop[ch] - DISC_DARKEN) - want[ch]) < 1e-9,
               "the restated backdrop and the restated disc colour disagree; "
               ~ "one of the two literals at the top of this file is stale");
}

// ---------------------------------------------------------------------------
// Flow C — the stroke is NOT ANTIALIASED, with the screen-plane ring as the
// positive control in the same frame.
//
// Smoothing is coverage-into-alpha, so a smoothed stroke MUST leave partially
// covered pixels at its edges and an unsmoothed one CANNOT. Classify every
// clean sector by whether it holds any partial coverage at all, and run the
// identical classifier on both rings.
//
// THE CONTROL IS THE POINT. "The disc has no soft edges" is also true of a
// build whose antialiasing has stopped working everywhere, or one whose probe
// is quantising, and a test without a smoothed shape beside it in the same
// frame cannot tell those from the shape being right.
// ---------------------------------------------------------------------------

private struct Edges { size_t clean, hard, soft, fullPx, partPx; }

private Edges edgeCharacter(ref Ring rg) {
    enum double BIN = 2.0;
    size_t[][int] grouped;
    foreach (i; 0 .. rg.pts.length)
        grouped[cast(int)floor(rg.ang[i] / BIN)] ~= i;

    Edges e;
    foreach (k, idxs; grouped) {
        double[] ks;
        bool clean = true;
        foreach (i; idxs) {
            double res;
            immutable double c = covOf(rg.on[i], rg.off[i], rg.colour, res);
            if (isNaN(c) || isNaN(res) || res > 6.0) { clean = false; break; }
            ks ~= c / rg.plateau;
        }
        if (!clean) continue;
        bool anyFull = false, anyPart = false;
        foreach (c; ks) {
            if (c > 0.88)      { anyFull = true; ++e.fullPx; }
            else if (c > 0.12) { anyPart = true; ++e.partPx; }
        }
        if (!anyFull && !anyPart) continue;   // sector holds no stroke
        ++e.clean;
        if (anyPart) ++e.soft;
        else         ++e.hard;
    }
    return e;
}

unittest {
    auto s = scan();
    solveRings();

    auto d = edgeCharacter(g_scan.disc);
    auto v = edgeCharacter(g_scan.view);

    assert(d.clean >= 40 && v.clean >= 40,
           format("too few clean sectors to compare edges: disc %d, ring %d",
                  d.clean, v.clean));

    // THE CONTROL, asserted FIRST so that a build with no antialiasing at all
    // fails here and reports why, rather than passing the disc's assertion for
    // the wrong reason.
    assert(v.soft * 20 >= v.clean * 19,
           format("the CONTROL failed: only %d of %d sectors of the "
                  ~ "screen-plane ring hold a partially covered pixel (%d full, "
                  ~ "%d partial). That ring IS smoothed, so a frame in which it "
                  ~ "has hard edges is a frame in which line antialiasing has "
                  ~ "stopped working — and the disc's own hardness below would "
                  ~ "then mean nothing.",
                  v.soft, v.clean, v.fullPx, v.partPx));
    assert(v.hard * 20 <= v.clean,
           format("the CONTROL failed: %d of %d sectors of the screen-plane "
                  ~ "ring cross it with no graded pixel at all", v.hard, v.clean));

    // ...and the disc, by the same instrument in the same frame.
    assert(d.hard * 20 >= d.clean * 19,
           format("only %d of %d sectors of the backing disc are a hard "
                  ~ "crossing (%d full-coverage pixels, %d partial). The disc "
                  ~ "is NOT antialiased: the reference does not request "
                  ~ "smoothing for this batch, and ours opts out through "
                  ~ "FullCircleHandler.smoothStroke. In the same frame the "
                  ~ "screen-plane ring measured %d of %d sectors soft, so the "
                  ~ "instrument is working.",
                  d.hard, d.clean, d.fullPx, d.partPx, v.soft, v.clean));
    assert(d.partPx * 20 <= d.fullPx,
           format("the backing disc left %d partially covered pixels against "
                  ~ "%d fully covered ones. An unsmoothed stroke covers a pixel "
                  ~ "or it does not.", d.partPx, d.fullPx));
}

// ---------------------------------------------------------------------------
// Flow D — the WIDTH is 1.0 px, at TWO radii, and the rings' 2.5 is the
// control that proves the instrument can tell widths apart at all.
// ---------------------------------------------------------------------------

// Integrate coverage over each angular sector and divide by the arc length.
// Sectors are dropped WHOLE when any pixel in them fails the projection's
// residual test — a pixel that cannot be read contributes zero to the integral
// and would quietly shorten the stroke, so half a sector is worse than none.
private double widthOf(ref Ring rg, out size_t bins) {
    enum double BIN = 2.0;
    size_t[][int] grouped;
    foreach (i; 0 .. rg.pts.length)
        grouped[cast(int)floor(rg.ang[i] / BIN)] ~= i;

    double[] ws;
    foreach (k, idxs; grouped) {
        double tot = 0;
        bool clean = true;
        foreach (i; idxs) {
            double res;
            immutable double c = covOf(rg.on[i], rg.off[i], rg.colour, res);
            if (isNaN(c) || isNaN(res) || res > 6.0) { clean = false; break; }
            tot += max(0.0, c) / rg.plateau;
        }
        if (!clean) continue;
        // tot is  sum(coverage) over one sector; the area integral of coverage
        // over that sector is  width * R * dtheta.
        ws ~= tot / (rg.radius * BIN * PI / 180.0);
    }
    assert(ws.length >= 20,
           format("only %d clean sectors to take a width from", ws.length));
    ws.sort();
    bins = ws.length;
    return ws[ws.length / 2];
}

unittest {
    auto s = scan();
    solveRings();

    size_t nDisc, nView;
    immutable double wDisc = widthOf(g_scan.disc, nDisc);
    immutable double wView = widthOf(g_scan.view, nView);

    assert(abs(wDisc - DISC_WIDTH) <= 0.25,
           format("the backing disc's stroke integrates to %.3f px over %d "
                  ~ "sectors, not %.1f. This is the one stroke on the gizmo "
                  ~ "with no floor under it — it is a hairline, and it was "
                  ~ "shipped at 2.0 on a reading of a dead branch.",
                  wDisc, nDisc, DISC_WIDTH));
    assert(abs(wView - VIEW_WIDTH) <= 0.30,
           format("the CONTROL failed: the screen-plane ring integrates to "
                  ~ "%.3f px over %d sectors, not %.1f. The instrument is "
                  ~ "mis-reading widths, so the disc's %.3f says nothing.",
                  wView, nView, VIEW_WIDTH, wDisc));
    assert(wView - wDisc >= 1.00,
           format("the disc (%.3f px) and the rings (%.3f px) measured within "
                  ~ "%.3f px of each other. They are 1.0 and 2.5 by law — a "
                  ~ "sweep that cannot separate them is not measuring width.",
                  wDisc, wView, wView - wDisc));

    // THE INCIDENTAL RADIUS FINDING, pinned while both rings are in hand: the
    // screen-plane ring is 13/12 of the arm and the disc is the arm, so the two
    // are NOT concentric-and-equal. Measured off the coverage centroids solved
    // in `readRing`, which is why it costs nothing to assert here.
    immutable double ratio = g_scan.disc.radius / g_scan.view.radius;
    assert(abs(ratio - 1.0 / VIEW_RING_RATIO) <= 0.01,
           format("the backing disc sits at %.3f of the screen-plane ring's "
                  ~ "radius (%.2f px and %.2f px), not %.4f. The disc takes the "
                  ~ "arm's length and the view ring takes 13/12 of it; drawing "
                  ~ "them at one radius puts a hairline under a 2.5 px ring "
                  ~ "where it cannot be seen.",
                  ratio, g_scan.disc.radius, g_scan.view.radius,
                  1.0 / VIEW_RING_RATIO));

    // ---- THE LAW: the same stroke at a different radius --------------------
    //
    // Everything above is one measurement at one size, and a width defined as a
    // fraction of the radius would satisfy all of it. Step the handle-size
    // preference to 2.0 — which doubles the arm, and with it the disc — and
    // measure again. The stroke is in WINDOW PIXELS and must not move.
    //
    // The preference outlives /api/reset, so it is restored before this block
    // can leave by any path.
    scope(exit) {
        homeHandleScale(s.c, 1);
        script("tool.set rotate");
        settle();
    }

    homeHandleScale(s.c, 3);            // 0.5 floor + 3 steps = 2.0
    script("tool.set rotate"); settle();

    Scan big;
    big.c  = s.c;
    big.cx = s.cx;
    big.cy = s.cy;
    immutable double[2] radii2 = locateRings(big, 150, 275);
    big.disc.radius = radii2[0];
    big.view.radius = radii2[1];

    assert(big.disc.radius > 1.6 * g_scan.disc.radius,
           format("stepping the handle-size preference to 2.0 moved the disc "
                  ~ "from %.1f px to %.1f px; the second measurement is not at "
                  ~ "a meaningfully different radius, so it cannot separate a "
                  ~ "width in pixels from a width in radii.",
                  g_scan.disc.radius, big.disc.radius));

    scanRing(big.disc, big, 3.0);
    readRing(big.disc, big);

    size_t nBig;
    immutable double wBig = widthOf(big.disc, nBig);

    assert(abs(wBig - DISC_WIDTH) <= 0.25,
           format("at %.1f px of radius the backing disc's stroke integrates to "
                  ~ "%.3f px over %d sectors, not %.1f", big.disc.radius,
                  wBig, nBig, DISC_WIDTH));

    // ...and the two readings are the same reading. This is the assertion a
    // radius-proportional width fails and a constant passes: at these two radii
    // such a width would read %.3f and about twice that.
    assert(abs(wBig - wDisc) <= 0.20,
           format("the backing disc's stroke measured %.3f px at radius %.1f "
                  ~ "and %.3f px at radius %.1f — it is tracking its own "
                  ~ "radius. The width is in WINDOW PIXELS and is independent "
                  ~ "of the handle-size preference; only the radius scales.",
                  wDisc, g_scan.disc.radius, wBig, big.disc.radius));
}

// ---------------------------------------------------------------------------
// Flow E — the disc is DECORATIVE: it cannot be hit and it never highlights.
// ---------------------------------------------------------------------------

unittest {
    auto s = scan();
    solveRings();

    // A sector clear of every axis ring, wide enough that the pick radius
    // around the probe point cannot reach one either. Self-located by the same
    // projection test the other flows use: a run of adjacent bins in which
    // every pixel is explained by the disc's own colour.
    enum double BIN = 2.0;
    size_t[][int] grouped;
    foreach (i; 0 .. g_scan.disc.pts.length)
        grouped[cast(int)floor(g_scan.disc.ang[i] / BIN)] ~= i;

    bool binIsClean(int k) {
        auto p = k in grouped;
        if (p is null) return false;
        foreach (i; *p) {
            double res;
            immutable double c = covOf(g_scan.disc.on[i], g_scan.disc.off[i],
                                       g_scan.disc.colour, res);
            if (isNaN(c) || isNaN(res) || res > 6.0) return false;
        }
        return true;
    }

    // Every sector with a clear 22-degree stretch around it — at this radius,
    // 22 px of arc either side, comfortably outside the 8 px pick radius.
    int[] clear;
    foreach (k; 0 .. 180) {
        bool ok = true;
        foreach (o; -5 .. 6)
            if (!binIsClean(cast(int)((k + o + 180) % 180))) { ok = false; break; }
        if (ok) clear ~= k;
    }
    assert(clear.length >= 2,
           "no 22-degree stretch of the backing disc was clear of the axis "
           ~ "rings; a hover there could not be attributed to the disc");

    // TWO probe points, both ON THE STROKE, as far apart as the frame allows.
    //
    // The second one used to be at 0.45 of the radius — INSIDE the disc, back
    // when the disc had a fill and the inside was part of the shape. It is not
    // any more: with no fill the disc IS its rim, and a point in the middle of
    // it is a point on the empty background between the rings, where whatever
    // the hit test says is a fact about some other handle. (Concretely: an axis
    // ring seen edge-on projects to a segment through the centre, so the old
    // interior point sat within the pick radius of one — the assertion there
    // was never about the disc.) Two widely separated rim points test the same
    // claim on the geometry that actually exists.
    int second = clear[0];
    foreach (k; clear)
        if (abs(cast(int)(k - clear[0])) > abs(cast(int)(second - clear[0]))
            && abs(cast(int)(k - clear[0])) <= 120)
            second = k;
    assert(second != clear[0],
           "only one clear stretch of the backing disc; the two hover probes "
           ~ "would land on the same place");

    immutable double t  = (clear[0] + 0.5) * BIN * PI / 180.0;
    immutable double t2 = (second   + 0.5) * BIN * PI / 180.0;
    immutable int rimX = cast(int)round(g_scan.cx + cos(t) * g_scan.disc.radius);
    immutable int rimY = cast(int)round(g_scan.cy + sin(t) * g_scan.disc.radius);
    immutable int inX  = cast(int)round(g_scan.cx + cos(t2) * g_scan.disc.radius);
    immutable int inY  = cast(int)round(g_scan.cy + sin(t2) * g_scan.disc.radius);

    // Pixels to watch: a short arc of the rim through the chosen sector.
    int[2][] watch;
    foreach (o; -6 .. 7) {
        immutable double tt = t + o * 0.004;
        foreach (dr; -2 .. 3)
            watch ~= [cast(int)round(g_scan.cx + cos(tt) * (g_scan.disc.radius + dr)),
                      cast(int)round(g_scan.cy + sin(tt) * (g_scan.disc.radius + dr))];
    }

    // Pointer parked in an empty corner: the reference reading.
    hoverAt(s.c, s.c.vx + 6, s.c.vy + 6);
    assert(handles().hot == -1, "something was already hot with the pointer parked away");
    auto before = probe(watch);

    foreach (pt; [[rimX, rimY], [inX, inY]]) {
        hoverAt(s.c, pt[0] + s.c.vx, pt[1] + s.c.vy);
        immutable int hot = handles().hot;
        assert(hot == -1,
               format("the pointer at (%d, %d) — on the backing disc — went "
                      ~ "hot on part %d. The disc is decorative: it is drawn "
                      ~ "but must never be registered in the Test pass, so it "
                      ~ "cannot be grabbed and cannot highlight. The reference "
                      ~ "hands this batch a no-part sentinel that its own hover "
                      ~ "path skips, so it cannot go hot even in principle.",
                      pt[0], pt[1], hot));
    }

    // ...and by value, which is the assertion that survives the registry
    // changing shape: the disc's own pixels are the same picture with the
    // pointer on it as with the pointer in the corner.
    hoverAt(s.c, rimX + s.c.vx, rimY + s.c.vy);
    auto after = probe(watch);
    size_t moved = 0;
    foreach (i; 0 .. watch.length)
        if (before[i] != after[i]) ++moved;
    assert(moved == 0,
           format("%d of %d backing-disc pixels changed value when the pointer "
                  ~ "was moved onto the disc. It must not repaint under the "
                  ~ "pointer — it holds HandleState.Normal for the life of the "
                  ~ "gizmo.", moved, watch.length));

    hoverAt(s.c, s.c.vx + 6, s.c.vy + 6);
    homeHandleScale(s.c, 1);
    dropRotate();
}
