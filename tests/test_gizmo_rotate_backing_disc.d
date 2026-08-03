// test_gizmo_rotate_backing_disc.d — the plate the rotation rings sit on.
//
// The backing disc is the one gizmo part with no clickable existence: it is
// drawn, it is never registered in the Test pass, and no API reports where it
// is. So every number here is recovered FROM THE PIXELS, and the geometry it
// is recovered at is found by the same sweep rather than copied out of the
// draw code. Nothing below reads a radius, a width or a colour from the
// application; the four properties this file pins are all solved for.
//
// WHAT IT PINS, AND WHY ALL FOUR
//
//   * the disc's COLOUR      — backdrop - 0.15 = (0.21, 0.25, 0.30)
//   * its FILL opacity       — 0.20
//   * its OUTLINE opacity    — 0.75
//   * its OUTLINE width      — 2.0 px, and NOT the rings' 2.5
//
// A test that checked only the colour would let the fill silently disappear
// again, which is exactly the state this replaced: an outline-only shape in
// pure black. A test that checked only the fill would not notice the colour
// going back to black, because a black fill at 0.2 is still a darkening. They
// are four independent ways for the shape to be wrong and they get four
// assertions.
//
// HOW EACH IS RECOVERED — the two-background solve
//
// A translucent part composites as  on = a*C + (1-a)*off,  linear in the
// background it lands on. The disc is 120 px across and covers several very
// different backgrounds at once (the mesh, the grid, the empty backdrop), so
// regressing the lit pixel against the SAME pixel with the tool dropped
// recovers the slope and the intercept — and from them BOTH the opacity `a`
// and the colour `C`, with neither one assumed to get the other. The control
// is not a second measurement to compare against; it is the x-axis of the fit.
//
// Which is why the readings do not depend on knowing the backdrop, the mesh
// shading, the grid, or the alpha the handle pass writes: all of that is in
// `off`. It is also why a *uniform* background would make the whole thing
// singular — the assertions on the span below are not decoration.
//
// HOW THE WIDTH IS RECOVERED — coverage integrated over an annulus
//
// A single cut across a 2 px stroke cannot measure it: the answer depends on
// where the pixel grid falls relative to the stroke, and swings by ±0.3 px
// between a cut through the centre of a pixel and one through its corner. So
// the coverage is integrated over the whole annulus instead. For a stroke of
// width w laid along a circle of radius R, the area integral of coverage over
// an angular sector is exactly  w * R * dtheta  — the phase averages away,
// and dividing by the arc length leaves w.
//
// The stroke's own radius is solved for in the same pass, by a fixed point on
// the coverage centroid. It has to be: the fill's edge sits at that same
// radius and the fill is not symmetric about it, so a centroid taken over the
// raw darkening is pulled inward by about 0.07 px — which lands on the width
// doubled, and is the difference between reading 2.02 and reading 2.13.
//
// THE CONTROL FOR THE WIDTH is the screen-plane ring, measured by the same
// function in the same frame. It is a 2.5 px stroke and it must read as one.
// Without it "the disc is 2.0 px" is a number with nothing to say — an
// instrument that reported 2.0 for everything would pass.
//
// VERIFIED BY MUTATION. Each was applied to the green tree, built, and run;
// the named assertion is the one that fired, with the value it reported:
//
//   * disc colour forced to Vec3(0,0,0)
//       -> Flow A, "colour drifted on channel 0: 0.0045, wanted 0.2100"
//   * fill removed (`hasFill` forced false)
//       -> Flow A, "no fill was found ... composites at opacity -0.0000"
//   * GIZMO_ALPHA_ROTATE_DISC_FILL 0.20 -> 0.10
//       -> Flow A, "FILL composites at opacity 0.0944, not 0.20"
//   * GIZMO_ALPHA_ROTATE_DISC_RING 0.75 -> 1.00
//       -> Flow B, "OUTLINE composites at opacity 1.0000, not 0.75"
//   * GIZMO_STROKE_ROTATE_DISC_PX 2.0 -> 2.5
//       -> Flow C, "integrates to 2.528 px of stroke ... not 2.0"
//   * `th.add(handler.bgCircle, base + 4)` in rotate.d's registerHandles
//       -> Flow D, "on the backing disc — went hot on part 14"
//
// The last one is the reason Flow D drives a pointer rather than counting the
// parts in the registry: registering the disc leaves Flows A, B and C green,
// because a handle that is only hot UNDER the pointer draws in its own colour
// for every frame this file measures.
//
// --------------------------------------------------------------------------

import std.format    : format;
import std.json;
import std.math      : abs, sqrt, cos, sin, atan2, PI, round, floor, isNaN;
import std.algorithm : min, max, sort;
import std.net.curl  : get, post;
import core.thread   : Thread;
import core.time     : msecs;

import drag_helpers : playAndWait;

void main() {}

private enum string baseUrl = "http://localhost:8080";

// The scheme, restated as literals rather than imported — the same convention
// tests/test_gizmo_handle_colours.d and test_gizmo_hover_highlight.d use. A
// drift in viewport_scheme.d has to be acknowledged here too.
private enum double BACKDROP_R = 0.36, BACKDROP_G = 0.40, BACKDROP_B = 0.45;
private enum double DISC_DARKEN = 0.15;
// ...and what the derivation lands on. Written out so that BOTH the offset and
// the result have to be edited together if either moves.
private enum double DISC_R = 0.21, DISC_G = 0.25, DISC_B = 0.30;

private enum double FILL_ALPHA = 0.20;   // GIZMO_ALPHA_ROTATE_DISC_FILL
private enum double RING_ALPHA = 0.75;   // GIZMO_ALPHA_ROTATE_DISC_RING
private enum double DISC_WIDTH = 2.0;    // GIZMO_STROKE_ROTATE_DISC_PX
private enum double VIEW_WIDTH = 2.5;    // GIZMO_STROKE_ROTATE_RING_PX

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

private JSONValue getJson(string path) {
    return parseJSON(cast(string)get(baseUrl ~ path));
}

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
// The fit
// ---------------------------------------------------------------------------

// `alpha` is an ACCUMULATOR (the mean of the three channels' fits) and is
// therefore written `= 0`: `double.init` is NaN in D, and `NaN += x` is NaN,
// so the default would turn every reading below into "no fill found".
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

// ---------------------------------------------------------------------------
// The scan — done once, shared by every flow.
// ---------------------------------------------------------------------------

private struct Ring {
    double radius;                 // radius the sweep FOUND it at
    double alphaHint = 1.0;        // the stroke's own opacity, once solved for
    int[2][] pts;                  // cell-local annulus pixels
    double[] dist, ang;            // exact polar coords of each
    int[3][] on, off;
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
    Fit fill;                      // solved in Flow A, reused by B, C and D
    Fit outline;                   // solved in Flow B, reused by C
}

private Scan g_scan;

private void armRotate() {
    post(baseUrl ~ "/api/reset", "{}");
    settle();
    script("tool.set rotate");
    settle();
}

private void dropRotate() { script("tool.set rotate off"); settle(); }

// Find the two outermost circular features by sweeping rays outward from the
// centre. The screen-plane ring is the outermost; the backing disc is the next
// one in. Nothing here knows either radius in advance — which is the point: a
// test that took 120 px from the source would still pass if the gizmo silently
// changed size.
//
// The disc is located by the OUTER EDGE of its lit region rather than by a
// peak. A peak search finds whichever thing is brightest, and an axis ring
// crossing near the rim is brighter than the disc is — the disc is barely
// darker than what it covers, which is the whole point of it. The outer edge
// has no such competitor: the rings all live at or inside the disc's radius,
// so the outermost lit pixel below the gap belongs to the disc whatever else
// is in the sector.
//
// It also reads the same on a disc with no fill, which matters: if the fill
// regresses, the failure that fires should be Flow A saying the fill is gone,
// not this sweep failing to find anything.
//
// Both values are only SEEDS — every radius that a measurement rests on is
// re-fitted per sector further down. ±2 px here is harmless.
private double[2] locateRings(ref Scan s) {
    enum int RAYS = 12, R0 = 55, R1 = 195;
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
        // The screen-plane ring: the outermost run, by its ink centroid.
        double numr = 0, den = 0;
        foreach (i; runs[$ - 1][0] .. runs[$ - 1][1] + 1) {
            immutable size_t idx = k * N + i;
            immutable double w = abs(on[idx][0] - off[idx][0])
                               + abs(on[idx][1] - off[idx][1])
                               + abs(on[idx][2] - off[idx][2]);
            numr += (R0 + i) * w; den += w;
        }
        if (den < 1.0) continue;
        outer ~= numr / den;
        // The disc: the outer end of the run below the gap, pulled back by the
        // stroke's own outer half plus the fringe the threshold above still saw.
        inner ~= R0 + runs[$ - 2][1] - 1.5;
    }
    assert(outer.length >= 8,
           format("only %d of %d rays found two concentric features — the "
                  ~ "rotate gizmo is not on screen as expected", outer.length, RAYS));
    outer.sort(); inner.sort();
    immutable double ro = outer[outer.length / 2], ri = inner[inner.length / 2];
    assert(ro - ri > 4.0 && ro - ri < 25.0,
           format("the two outermost features are %.1f px apart (%.1f and %.1f); "
                  ~ "that is not the screen-plane ring outside the backing disc",
                  ro - ri, ri, ro));
    return [ri, ro];
}

private void scanRing(ref Ring rg, ref Scan s, double halfBand) {
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

private ref Scan scan() {
    if (g_scan.ready) return g_scan;
    armRotate();
    g_scan.c = cell();
    auto h = handles();
    assert(10 in h.screen,
           "the rotate bank publishes no ring parts — nothing to centre on");
    g_scan.cx = h.screen[10][0] - h.vx;
    g_scan.cy = h.screen[10][1] - h.vy;

    immutable double[2] radii = locateRings(g_scan);
    g_scan.disc.radius = radii[0];
    g_scan.view.radius = radii[1];

    // Interior: every third pixel, out to well inside the outline's fringe.
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

    scanRing(g_scan.disc, g_scan, 4.5);
    scanRing(g_scan.view, g_scan, 4.5);

    // A thin subset for the alpha-channel differential; spread across the whole
    // interior so it lands on mesh, grid and empty backdrop alike.
    for (size_t i = 0; i < g_scan.inner.length; i += g_scan.inner.length / 40 + 1)
        g_scan.alphaPts ~= g_scan.inner[i];

    script("tool.set rotate"); settle();
    g_scan.innerOn    = probe(g_scan.inner);
    g_scan.disc.on    = probe(g_scan.disc.pts);
    g_scan.view.on    = probe(g_scan.view.pts);
    g_scan.alphaOn    = probeAlpha(g_scan.alphaPts);
    dropRotate();
    g_scan.innerOff   = probe(g_scan.inner);
    g_scan.disc.off   = probe(g_scan.disc.pts);
    g_scan.view.off   = probe(g_scan.view.pts);
    g_scan.alphaOff   = probeAlpha(g_scan.alphaPts);
    script("tool.set rotate"); settle();

    g_scan.ready = true;
    return g_scan;
}

// ---------------------------------------------------------------------------
// Flow A — the FILL: it exists, at 0.20, in the derived colour.
// ---------------------------------------------------------------------------

unittest {
    auto s = scan();

    // The lever the solve rests on. A disc lying entirely on flat backdrop
    // would make the regression singular and every number below meaningless,
    // so the span is asserted before anything is read off it.
    int lo = 255, hi = 0;
    foreach (p; s.innerOff) if (p[0] >= 0) { lo = min(lo, p[0]); hi = max(hi, p[0]); }
    assert(hi - lo >= 40,
           format("the disc interior spans only %d counts of background "
                  ~ "(%d..%d); the two-background solve has no lever and "
                  ~ "cannot separate opacity from colour", hi - lo, lo, hi));

    auto f = solve(s.innerOn, s.innerOff);
    g_scan.fill = f;

    assert(!isNaN(f.alpha) && f.alpha > 0.05,
           format("no fill was found behind the rotate rings: the disc's "
                  ~ "interior composites at opacity %.4f, i.e. the lit frame "
                  ~ "and the control are the same picture there. The backing "
                  ~ "disc must be FILLED at %.2f as well as outlined — an "
                  ~ "outline on its own is a third ring, not a disc.",
                  f.alpha, FILL_ALPHA));

    assert(abs(f.alpha - FILL_ALPHA) <= 0.02,
           format("the backing disc's FILL composites at opacity %.4f, not "
                  ~ "%.2f (recovered from %d of %d interior pixels)",
                  f.alpha, FILL_ALPHA, f.kept, f.total));

    immutable double[3] want = [DISC_R, DISC_G, DISC_B];
    foreach (ch; 0 .. 3) {
        immutable double got = f.color[ch] / 255.0;
        assert(abs(got - want[ch]) <= 0.02,
               format("the backing disc's colour drifted on channel %d: %.4f, "
                      ~ "wanted %.4f. The disc is the viewport backdrop minus "
                      ~ "%.2f per channel and must be DERIVED from "
                      ~ "SchemeColor.backdrop, never written down. (Pure black "
                      ~ "— %.4f — is what it used to be, and is what a reading "
                      ~ "near 0 means.)", ch, got, want[ch], DISC_DARKEN, 0.0));
    }

    // THE CELL'S OWN ALPHA, under the new geometry. The fill is the first
    // translucent TRIANGLE batch this bank ever drew, and the cell FBO's alpha
    // is what ImGui composites the cell with — a batch that let its own 0.2
    // through to the destination would punch an 80 %-transparent hole the size
    // of the whole disc, and the panel behind would show through the gizmo.
    // The blend has to be `GL_ZERO / GL_ONE` on alpha, i.e. destination alpha
    // untouched.
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
               format("%d of %d pixels inside the backing disc changed the "
                      ~ "cell FBO's ALPHA when the gizmo was drawn — e.g. "
                      ~ "(%d, %d) went %d -> %d. The disc's fill is writing the "
                      ~ "destination alpha; the handle pass must blend colour "
                      ~ "normally and leave alpha alone (GL_ZERO/GL_ONE), or "
                      ~ "ImGui composites a hole where the gizmo is.",
                      moved, s.alphaPts.length,
                      s.alphaPts[firstK][0], s.alphaPts[firstK][1],
                      s.alphaOff[firstK], s.alphaOn[firstK]));
    }

    // The derivation, checked against the backdrop as measured in this very
    // frame rather than against the literal above: find the emptiest pixels in
    // the control and require the disc to sit exactly `DISC_DARKEN` below them.
    // This is what would catch a re-themed backdrop that the disc did not
    // follow — the failure a hardcoded triple is silent about.
    immutable double[3] backdrop = [BACKDROP_R, BACKDROP_G, BACKDROP_B];
    foreach (ch; 0 .. 3)
        assert(abs((backdrop[ch] - DISC_DARKEN) - want[ch]) < 1e-9,
               "the restated backdrop and the restated disc colour disagree; "
               ~ "one of the two literals at the top of this file is stale");
}

// ---------------------------------------------------------------------------
// Flow B — the OUTLINE: 0.75, in the same colour as the fill.
//
// Sampled in the band just OUTSIDE the fill polygon and still at full stroke
// coverage. Outside, because the fill under the inner half would make the
// background of the solve a composite rather than the control pixel; full
// coverage, because a partially covered pixel carries an unknown factor into
// the slope. The band is narrow, so it is found from the fitted radius rather
// than assumed.
// ---------------------------------------------------------------------------

private double[double] ringRadiusByBin(ref Ring rg, double fillAlpha,
                                        const double[3] colour, double binDeg)
{
    double[double] outR;
    size_t[][double] bins;
    foreach (i; 0 .. rg.pts.length)
        bins[floor(rg.ang[i] / binDeg)] ~= i;

    foreach (k, idxs; bins) {
        if (!binIsClean(rg, idxs, colour)) continue;
        double R = rg.radius;
        bool ok = false;
        foreach (iter; 0 .. 8) {
            double numr = 0, den = 0;
            foreach (i; idxs) {
                immutable double q = qOf(rg, i, colour);
                if (isNaN(q)) continue;
                immutable double sgn = strokeSignal(q, rg.dist[i] < polyR(R, rg.ang[i]),
                                                   fillAlpha);
                if (sgn <= 0.02) continue;
                numr += rg.dist[i] * sgn; den += sgn;
            }
            if (den < 0.5) { ok = false; break; }   // no stroke in this sector
            immutable double Rn = numr / den;
            immutable bool done = abs(Rn - R) < 1e-4;
            R = Rn;
            ok = true;
            if (done) break;
        }
        // A sector whose fitted radius ran away from where the sweep found the
        // feature is a fit that did not converge on the stroke; drop it rather
        // than integrate over the wrong band.
        if (ok && abs(R - rg.radius) < 3.0) outR[k] = R;
    }
    return outR;
}

// The fill is a 64-gon inscribed at radius R, so its boundary dips to
// R*cos(pi/64) between vertices. Pixels are classified against the polygon,
// not against the circle — a 0.15 px difference that decides whether a pixel's
// background is the control or the control WITH the fill on it.
private double polyR(double R, double angDeg) {
    enum double SEG = 2.0 * PI / 64.0;
    double t = (angDeg * PI / 180.0) % SEG;
    return R * cos(PI / 64.0) / cos(t - PI / 64.0);
}

// The total effective opacity applied at this pixel, averaged over whichever
// channels have enough contrast between the disc colour and the background to
// carry a reading.
private double qOf(ref Ring rg, size_t i, const double[3] colour) {
    if (rg.on[i][0] < 0 || rg.off[i][0] < 0) return double.nan;
    double sum = 0; int n = 0;
    foreach (ch; 0 .. 3) {
        immutable double den = colour[ch] - rg.off[i][ch];
        if (abs(den) < 25) continue;
        sum += (rg.on[i][ch] - rg.off[i][ch]) / den; ++n;
    }
    return n ? sum / n : double.nan;
}

// Strip the fill's contribution, leaving the stroke's own coverage*alpha.
//   over bare background : q = c*a
//   over the fill        : q = c*a + (1-c*a)*aFill
private double strokeSignal(double q, bool overFill, double fillAlpha) {
    return overFill ? (q - fillAlpha) / (1.0 - fillAlpha) : q;
}

// Two ways a sector is disqualified, and both matter for the INTEGRAL — a
// pixel that cannot be read contributes zero to it and quietly shortens the
// stroke, so a sector containing one is dropped whole rather than in part.
//
//   * an axis ring crosses it — not explained by ONE opacity shared across the
//     three channels. Brightness is not the test: how bright a ring lands
//     depends on what is behind it.
//   * some pixel there sits on a background too close to the disc's own colour
//     to carry a reading at all (`qOf` returns NaN).
private bool binIsClean(ref Ring rg, const size_t[] idxs, const double[3] colour) {
    foreach (i; idxs) {
        if (rg.on[i][0] < 0 || rg.off[i][0] < 0) return false;
        double lo = 2, hi = -2; int n = 0;
        foreach (ch; 0 .. 3) {
            immutable double den = colour[ch] - rg.off[i][ch];
            if (abs(den) < 25) continue;
            immutable double v = (rg.on[i][ch] - rg.off[i][ch]) / den;
            lo = min(lo, v); hi = max(hi, v); ++n;
        }
        if (n == 0) return false;
        // The channel-spread check is the discriminator that does the work: a
        // ring in a saturated axis colour lands on wildly different implied
        // opacities per channel (an axis green over grey reads +1.0, -2.3,
        // +1.8), while the disc reads the same value on all three whatever is
        // behind it.
        if (n >= 2 && hi - lo > 0.06) return false;
        // The absolute bounds only reject the physically impossible. They are
        // deliberately loose ON THE HIGH SIDE: a tight ceiling here would
        // encode an assumption about the outline's own opacity, and would
        // then reject the whole disc as "contaminated" if that opacity ever
        // rose — reporting a missing sector instead of the alpha that moved.
        if (hi > 1.15 || lo < -0.06) return false;
    }
    return true;
}

unittest {
    auto s = scan();
    assert(s.fill.alpha > 0.05, "Flow A must run first — it recovers the colour");

    enum double BIN = 2.0;
    auto Rb = ringRadiusByBin(g_scan.disc, s.fill.alpha, s.fill.color, BIN);
    assert(Rb.length >= 30,
           format("only %d angular sectors of the backing disc were free of an "
                  ~ "axis ring; not enough to read the outline from", Rb.length));

    int[3][] on, off;
    foreach (i; 0 .. g_scan.disc.pts.length) {
        immutable double k = floor(g_scan.disc.ang[i] / BIN);
        auto pR = k in Rb;
        if (pR is null) continue;
        immutable double d = g_scan.disc.dist[i] - *pR;
        if (d <= 0.20 || d >= 0.50) continue;   // outside the fill, full coverage
        on  ~= g_scan.disc.on[i];
        off ~= g_scan.disc.off[i];
    }
    assert(on.length >= 60,
           format("only %d pixels landed in the outline's full-coverage band; "
                  ~ "the solve would be noise", on.length));

    auto f = solve(on, off);
    g_scan.outline = f;
    assert(abs(f.alpha - RING_ALPHA) <= 0.02,
           format("the backing disc's OUTLINE composites at opacity %.4f, not "
                  ~ "%.2f (from %d band pixels)", f.alpha, RING_ALPHA, on.length));

    immutable double[3] want = [DISC_R, DISC_G, DISC_B];
    foreach (ch; 0 .. 3) {
        immutable double got = f.color[ch] / 255.0;
        assert(abs(got - want[ch]) <= 0.02,
               format("the OUTLINE's colour on channel %d is %.4f, wanted %.4f. "
                      ~ "Fill and outline are one colour at two opacities; if "
                      ~ "only one of them moved, they have come apart.",
                      ch, got, want[ch]));
        assert(abs(got - s.fill.color[ch] / 255.0) <= 0.025,
               format("the outline (%.4f) and the fill (%.4f) are drawn in "
                      ~ "different colours on channel %d", got,
                      s.fill.color[ch] / 255.0, ch));
    }
}

// ---------------------------------------------------------------------------
// Flow C — the outline's WIDTH is 2.0 px, and the screen-plane ring's is 2.5.
// ---------------------------------------------------------------------------

private double widthOf(ref Ring rg, double fillAlpha, const double[3] colour,
                       out size_t bins)
{
    enum double BIN = 2.0;
    auto Rb = ringRadiusByBin(rg, fillAlpha, colour, BIN);
    double[] ws;
    size_t[][double] grouped;
    foreach (i; 0 .. rg.pts.length) grouped[floor(rg.ang[i] / BIN)] ~= i;
    foreach (k, idxs; grouped) {
        auto pR = k in Rb;
        if (pR is null) continue;
        double tot = 0;
        foreach (i; idxs) {
            immutable double q = qOf(rg, i, colour);
            if (isNaN(q)) continue;
            tot += max(0.0, strokeSignal(q, rg.dist[i] < polyR(*pR, rg.ang[i]),
                                         fillAlpha));
        }
        // tot is  sum(coverage * alpha)  over one sector; the area integral of
        // coverage over that sector is  width * R * dtheta.
        ws ~= tot / rg.alphaHint / (*pR * BIN * PI / 180.0);
    }
    assert(ws.length >= 20, "too few clean sectors to take a width from");
    ws.sort();
    bins = ws.length;
    return ws[ws.length / 2];
}

unittest {
    auto s = scan();
    assert(s.fill.alpha > 0.05, "Flow A must run first");
    assert(s.outline.alpha > 0.05, "Flow B must run first — it recovers the "
           ~ "opacity the coverage integral divides by");

    // The stroke's OWN measured opacity, not the literal: a width read through
    // an assumed alpha would fail for whichever of the two actually moved.
    g_scan.disc.alphaHint = s.outline.alpha;
    size_t nDisc;
    immutable double wDisc = widthOf(g_scan.disc, s.fill.alpha, s.fill.color, nDisc);

    // The CONTROL: the screen-plane ring, same instrument, same frame, no fill
    // under it. Its colour and opacity are solved for exactly as the disc's
    // were, so nothing about it is assumed either.
    auto vf = solveRingCore(g_scan.view);
    g_scan.view.alphaHint = vf.alpha;
    size_t nView;
    immutable double wView = widthOf(g_scan.view, 0.0, vf.color, nView);

    assert(abs(wDisc - DISC_WIDTH) <= 0.25,
           format("the backing disc's outline integrates to %.3f px of stroke "
                  ~ "over %d sectors, not %.1f", wDisc, nDisc, DISC_WIDTH));
    assert(abs(wView - VIEW_WIDTH) <= 0.25,
           format("the CONTROL failed: the screen-plane ring integrates to "
                  ~ "%.3f px over %d sectors, not %.1f. The instrument is "
                  ~ "mis-reading widths, so the disc's %.3f says nothing.",
                  wView, nView, VIEW_WIDTH, wDisc));

    // ...and the instrument can tell them apart at all. Without this, both
    // readings could be the same number inside both tolerances.
    assert(wView - wDisc >= 0.30,
           format("the disc (%.3f px) and the rings (%.3f px) measured within "
                  ~ "%.3f px of each other. They are 2.0 and 2.5 by law — a "
                  ~ "sweep that cannot separate them is not measuring width.",
                  wDisc, wView, wView - wDisc));
}

// The screen-plane ring's own colour and opacity, from its full-coverage core.
// Its radius is used only to find that core, so a 0.1 px error is harmless.
private Fit solveRingCore(ref Ring rg) {
    double R = rg.radius;
    foreach (iter; 0 .. 6) {
        double numr = 0, den = 0;
        foreach (i; 0 .. rg.pts.length) {
            if (rg.on[i][0] < 0 || rg.off[i][0] < 0) continue;
            immutable double w = abs(rg.on[i][1] - rg.off[i][1]);
            numr += rg.dist[i] * w; den += w;
        }
        assert(den > 1.0, "the screen-plane ring left no ink to centre on");
        R = numr / den;
        break;
    }
    rg.radius = R;
    int[3][] on, off;
    foreach (i; 0 .. rg.pts.length)
        if (abs(rg.dist[i] - R) < 0.25) { on ~= rg.on[i]; off ~= rg.off[i]; }
    assert(on.length >= 60,
           format("the screen-plane ring's core held only %d pixels", on.length));
    return solve(on, off);
}

// ---------------------------------------------------------------------------
// Flow D — the disc is DECORATIVE: it cannot be hit and it never highlights.
// ---------------------------------------------------------------------------

unittest {
    auto s = scan();
    assert(s.fill.alpha > 0.05, "Flow A must run first");

    // A sector clear of every axis ring, wide enough that the 8 px pick radius
    // around the probe point cannot reach one either. Self-located: the same
    // channel-agreement test Flow B uses, applied to a run of adjacent bins.
    enum double BIN = 2.0;
    size_t[][double] grouped;
    foreach (i; 0 .. g_scan.disc.pts.length)
        grouped[floor(g_scan.disc.ang[i] / BIN)] ~= i;
    double chosen = double.nan;
    foreach (k, idxs; grouped) {
        bool ok = true;
        foreach (o; -4 .. 5) {
            immutable double kk = (k + o + 180.0) % 180.0;
            auto p = kk in grouped;
            if (p is null || !binIsClean(g_scan.disc, *p, s.fill.color)) { ok = false; break; }
        }
        if (ok) { chosen = k; break; }
    }
    assert(!isNaN(chosen),
           "no 18-degree stretch of the backing disc was clear of the axis "
           ~ "rings; a hover there could not be attributed to the disc");

    immutable double t = (chosen + 0.5) * BIN * PI / 180.0;
    immutable int rimX = cast(int)round(g_scan.cx + cos(t) * g_scan.disc.radius);
    immutable int rimY = cast(int)round(g_scan.cy + sin(t) * g_scan.disc.radius);
    immutable int inX  = cast(int)round(g_scan.cx + cos(t) * g_scan.disc.radius * 0.45);
    immutable int inY  = cast(int)round(g_scan.cy + sin(t) * g_scan.disc.radius * 0.45);

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
                      ~ "cannot be grabbed and cannot highlight. Adding its "
                      ~ "fill added geometry to the DRAW, not a target.",
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
    dropRotate();
}
