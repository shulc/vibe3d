// test_gizmo_handle_aa.d — how the move gizmo's arm ARRIVES ON PIXELS.
//
// Flows A and B: the gizmo's LINES are antialiased and its SOLIDS are not, and
// that asymmetry is the whole finding.
// Flow C (task 0603, added later): the solid in question — the arrowhead — is
// a one-quadrant WEDGE and not a cone of revolution, which is a fact only its
// pixels can settle and only across a range of camera rolls. It lives here
// rather than in a file of its own because it is the same part read with the
// same instrument (`findArm` + `crossSection` + the ink metric) that Flow B
// already builds; splitting it would have duplicated all of that to say a
// second thing about one arrowhead.
//
// WHY BOTH HALVES ARE IN ONE FILE. It would be easy to write a test that only
// says "the shaft has soft edges" and call the port done. That test passes on a
// build that antialiases EVERYTHING — which is the wrong port, and the one the
// implementation lane was explicitly warned off. The reference smooths line
// batches only: it never enables polygon smoothing anywhere, and it disables
// multisampling outright, so its arrowhead and centre cube were measured
// stepping from background straight to full colour with no intermediate value.
// A single test that asserts the ramp on the shaft AND its absence on the
// arrowhead pins the finding in both directions; either half alone does not.
//
// WHAT MAKES THIS NOT A SCREENSHOT TEST. It never looks at an image, never
// compares one, and never asks a human to judge one. It asks the renderer where
// the handle is, reads channel VALUES along a line it computes from that, and
// asserts on the SHAPE of the resulting profile. A failure names the sample.
//
// HOW THE ARROWHEAD IS FOUND. Not from a constant copied out of the draw code —
// that would just restate the implementation. The handles registry reports a
// grab anchor at 70% along the shaft, NOT the tip, so nothing in the JSON says
// where the cone starts. Instead the test walks outward along the arm and lets
// the cone announce itself as the WIDEST cross-section: the shaft is ~2 px, the
// cone base ~15 px, so the maximum is unambiguous and self-locating.
//
// VERIFIED TO FAIL BEFORE THE FIX: on the pre-task binary every shaft
// cross-section is a hard step (profile `0 0 178 178 178 0 0`), so Flow A fails
// with "no intermediate coverage on any of N shaft cross-sections". Flow B
// passes before and after — it is the half that stops the fix overshooting.

import http_client : testBaseUrl;
import http_command_helpers : commandBody;
import std.stdio      : writeln, writefln;
import std.net.curl   : HTTP;
import std.json       : parseJSON, JSONValue, JSONType;
import std.exception  : enforce;
import std.conv       : to;
import std.format     : format;
import std.math       : abs, sqrt, round;
import std.algorithm  : max, maxElement, filter, count;
import std.array      : array;
import core.thread    : Thread;
import core.time      : msecs;

// --------------------------------------------------------------------------
// Helpers (same shape as test_gizmo_handle_alpha.d)
// --------------------------------------------------------------------------

string baseUrl;

string httpGet(string path) {
    import std.net.curl : get;
    return cast(string)get(baseUrl ~ path);
}

string httpPost(string path, string body_) {
    auto http = HTTP();
    string result;
    http.onReceive = (ubyte[] data) { result ~= cast(string)data; return data.length; };
    http.postData = body_;
    http.addRequestHeader("Content-Type", "application/json");
    http.url = baseUrl ~ path;
    http.perform();
    return result;
}

void script(string line) {
    string resp = httpPost("/api/script", line);
    enforce(parseJSON(resp)["status"].str == "ok",
            "script `" ~ line ~ "` failed: " ~ resp);
}

void settle() { Thread.sleep(400.msecs); }

void resetApp() {
    httpPost("/api/command", commandBody("scene.reset", "{}"));
    settle();
}

double jsonNum(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    switch (cur.type) {
        case JSONType.float_:   return cur.floating;
        case JSONType.integer:  return cast(double)cur.integer;
        case JSONType.uinteger: return cast(double)cur.uinteger;
        default: throw new Exception("not a number at ." ~ path[$ - 1]);
    }
}

struct Px { int x, y, r, g, b, a; bool valid; }

Px[] probe(int[2][] pts) {
    Px[] outp;
    // Chunked so the request line stays short regardless of how long a sweep is.
    for (size_t i = 0; i < pts.length; i += 60) {
        auto slice = pts[i .. (i + 60 > pts.length ? pts.length : i + 60)];
        string q = "/api/viewport/probe?points=";
        foreach (k, p; slice) {
            if (k) q ~= ";";
            q ~= format("%d,%d", p[0], p[1]);
        }
        auto j = parseJSON(httpGet(q));
        enforce("error" !in j, "probe failed: " ~ j.toString);
        enforce(j["renders"].type == JSONType.TRUE,
                "the probed cell is not rendered under --test; the reading is void");
        foreach (e; j["points"].array) {
            Px p;
            p.x = cast(int)jsonNum(e, "x");
            p.y = cast(int)jsonNum(e, "y");
            if ("error" in e) { p.valid = false; outp ~= p; continue; }
            p.r = cast(int)jsonNum(e, "r");
            p.g = cast(int)jsonNum(e, "g");
            p.b = cast(int)jsonNum(e, "b");
            p.a = cast(int)jsonNum(e, "a");
            p.valid = true;
            outp ~= p;
        }
    }
    return outp;
}

struct Handles {
    double[2][int] screen;
    int vx, vy;
}

Handles handles() {
    auto j = parseJSON(httpGet("/api/tool/handles"));
    enforce(j["handles"].type != JSONType.null_,
            "/api/tool/handles reports no handles — no tool is armed");
    auto h = j["handles"];
    Handles outh;
    outh.vx = cast(int)jsonNum(h, "viewport", "x");
    outh.vy = cast(int)jsonNum(h, "viewport", "y");
    foreach (e; h["parts"].array) {
        int id = cast(int)jsonNum(e, "part");
        outh.screen[id] = [e["screen"].array[0].floating,
                           e["screen"].array[1].floating];
    }
    return outh;
}

// The X arm is RED, so its "ink" is how far the red channel runs ahead of the
// other two. Background (grey mesh, grey backdrop, grid) sits at ~0 on this
// measure and full stroke at ~178 — the axis red 229/51/51 reaching the
// framebuffer through the arm's TWO emissions of its 0.95 alpha (task 0604;
// before that it was the 169 of a single one). Using an EXCESS rather than a
// distance-to-a-literal is what makes the test indifferent to what is behind
// the gizmo, and every threshold below except C3's is relative to a peak this
// function measures, so they did not move with it.
int ink(Px p) {
    if (!p.valid) return 0;
    return p.r - max(p.g, p.b);
}

// A sample is "intermediate" when it is neither background nor full stroke —
// i.e. genuine partial coverage. The bands are wide (15 counts) so that 8-bit
// rounding and the software rasteriser's last bit cannot manufacture one.
bool isIntermediate(int v, int peak) { return v > 15 && v < peak - 15; }

// --------------------------------------------------------------------------
// Geometry of the sweep, shared by both flows.
// --------------------------------------------------------------------------

struct Arm {
    double cx, cy;      // gizmo centre, window coords
    double ux, uy;      // unit vector along the arm
    double px, py;      // unit vector perpendicular to it
    int    vx, vy;      // cell origin, for window -> FBO
}

Arm findArm(const ref Handles h) {
    enforce(3 in h.screen && 0 in h.screen,
            "the move bank must publish a centre (part 3) and an X arm (part 0)");
    Arm a;
    a.cx = h.screen[3][0]; a.cy = h.screen[3][1];
    immutable double tx = h.screen[0][0], ty = h.screen[0][1];
    immutable double dx = tx - a.cx, dy = ty - a.cy;
    immutable double len = sqrt(dx*dx + dy*dy);
    enforce(len > 40, "the X arm projects to under 40 px; nothing to sample");
    a.ux = dx / len;  a.uy = dy / len;
    a.px = -a.uy;     a.py = a.ux;
    a.vx = h.vx;      a.vy = h.vy;
    return a;
}

// One perpendicular cross-section `s` pixels out along the arm, `half` px each
// side. Returns the ink profile.
int[] crossSection(const ref Arm a, int s, int half) {
    int[2][] pts;
    foreach (d; -half .. half + 1)
        pts ~= [cast(int)round(a.cx + a.ux*s + a.px*d - a.vx),
                cast(int)round(a.cy + a.uy*s + a.py*d - a.vy)];
    int[] vals;
    foreach (p; probe(pts)) vals ~= ink(p);
    return vals;
}

// --------------------------------------------------------------------------
// Flow A — the SHAFT ramps. Sweep perpendicular across the stroke at several
// points and require partial coverage at its edges.
//
// Not "at every cross-section": a stroke whose centreline happens to land on a
// pixel boundary is genuinely crisp even when antialiased — that is what real
// line AA does, and demanding a ramp everywhere would pin an artifact instead
// of the law. The arm is slanted, so its sub-pixel offset walks as we move
// along it and most cross-sections must ramp. The threshold is a majority.
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] Move arm SHAFT — perpendicular sweep must show a coverage ramp...");
    resetApp();
    script("tool.set move");
    settle();
    scope(exit) { script("tool.set move off"); settle(); }

    auto h = handles();
    auto a = findArm(h);

    // Well inside the shaft: past the 1/5 inset at the centre end, short of the
    // arrowhead at the far end (which Flow B locates independently).
    enum int kFirst = 26, kLast = 62, kStep = 4;
    int sampled = 0, ramped = 0;
    int[] peaks;
    foreach (s; kFirst .. kLast + 1) {
        if ((s - kFirst) % kStep) continue;
        auto prof = crossSection(a, s, 8);
        immutable int peak = prof.maxElement;
        if (peak < 60) continue;            // no stroke found at this station
        sampled++;
        peaks ~= peak;
        if (prof.filter!(v => isIntermediate(v, peak)).count > 0) ramped++;
    }

    enforce(sampled >= 6,
        format("only %d shaft cross-sections carried any stroke at all — the "
               ~ "sweep is not crossing the arm", sampled));

    // The CONTROL, and the reason a null result here is readable: a station far
    // to the side of the arm must be background. If this were also "ink", the
    // probe or the colour metric would be broken and the ramp count meaningless.
    {
        auto off = crossSection(a, 44, 40);
        enforce(off[0] <= 15 && off[$ - 1] <= 15,
            format("control failed: 40 px off the arm axis is not background "
                   ~ "(ink %d and %d) — the ink metric is picking up something "
                   ~ "other than the arm", off[0], off[$ - 1]));
    }

    writefln("    %d/%d shaft cross-sections show partial coverage (peak ink ~%d)",
             ramped, sampled, peaks.maxElement);
    enforce(ramped * 2 > sampled,
        format("only %d of %d shaft cross-sections had ANY intermediate value. "
               ~ "The stroke is stepping background->full with nothing between, "
               ~ "i.e. it is not antialiased. The line path must carry the "
               ~ "perpendicular distance into the fragment stage and turn it "
               ~ "into coverage (see shader.thickLineFragSrc)", ramped, sampled));
    writeln("    A1 PASS: the shaft's edges carry partial coverage");
    return true;
}

// --------------------------------------------------------------------------
// Flow B — the ARROWHEAD does NOT ramp. Same instrument, opposite assertion.
//
// This is the half that fails if someone "fixes" antialiasing by turning on
// multisampling or by smoothing polygons: the reference does neither, and its
// arrowhead is a staircase.
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] Move arm ARROWHEAD — perpendicular sweep must NOT ramp...");
    resetApp();
    script("tool.set move");
    settle();
    scope(exit) { script("tool.set move off"); settle(); }

    auto h = handles();
    auto a = findArm(h);

    // Locate the cone by its own signature: the widest cross-section on the
    // arm. Nothing here is copied from the draw code.
    enum int kHalf = 20;
    int bestS = -1, bestWide = 0;
    foreach (s; 70 .. 130) {
        auto prof = crossSection(a, s, kHalf);
        immutable int peak = prof.maxElement;
        if (peak < 60) continue;
        immutable int wide = cast(int)prof.filter!(v => v > peak - 15).count;
        if (wide > bestWide) { bestWide = wide; bestS = s; }
    }
    enforce(bestS > 0 && bestWide >= 6,
        format("no wide cross-section found along the arm (widest %d px at "
               ~ "s=%d) — the arrowhead was not drawn, or it is no wider than "
               ~ "the shaft", bestWide, bestS));
    writefln("    arrowhead located at s=%d px, %d px across", bestS, bestWide);

    // Sample AT the widest station and toward the TIP from it. Deliberately not
    // toward the centre: there the antialiased shaft is still present and its
    // fringe would be read as the cone's, which would make this assert the
    // wrong thing about the wrong part.
    int checked = 0;
    foreach (s; [bestS, bestS + 2, bestS + 4]) {
        auto prof = crossSection(a, s, kHalf);
        immutable int peak = prof.maxElement;
        if (peak < 60) continue;
        immutable int wide = cast(int)prof.filter!(v => v > peak - 15).count;
        if (wide < 6) continue;             // too near the tip to be decisive
        checked++;
        auto mids = prof.filter!(v => isIntermediate(v, peak)).array;
        enforce(mids.length == 0,
            format("arrowhead cross-section at s=%d has %d intermediate "
                   ~ "value(s) %s between background and full ink %d. The "
                   ~ "solid handle geometry must NOT be antialiased — the "
                   ~ "reference never enables polygon smoothing and disables "
                   ~ "multisampling, and its arrowhead steps straight from "
                   ~ "background to full colour. Check that nothing turned on "
                   ~ "GL_MULTISAMPLE or applied the line coverage term to the "
                   ~ "triangle path", s, mids.length, mids, peak));
    }
    enforce(checked >= 2,
        format("only %d arrowhead cross-sections were wide enough to judge; "
               ~ "the assertion would be vacuous", checked));

    writefln("    B1 PASS: %d arrowhead cross-sections, every one a hard step", checked);
    return true;
}

// --------------------------------------------------------------------------
// Flow C — the arrowhead is a ONE-QUADRANT WEDGE, not a cone of revolution.
//
// Same instrument as Flow B (the ink profile of a perpendicular cross-section),
// pointed at a different property: the head's SHAPE. The measured head is a
// tetrahedron whose apex and one base corner sit ON the arm's axis while the
// other two base corners are pushed out along the two lateral directions. Its
// body is therefore entirely in one quadrant: it reaches its full half-width on
// one side of the arm and exactly ZERO on the other, and what the camera
// changes is which way it leans.
//
// WHY A ROLL SWEEP AND NOT ONE CAMERA. At a single camera angle a cone and a
// wedge differ only by a number, and any number can be matched by re-tuning a
// radius — a one-angle test would pass on either shape, which is exactly the
// trap this flow exists to avoid. It is the VARIATION that names the shape: a
// solid of revolution about the arm presents the same silhouette from every
// roll, so no radius can make its width breathe or its reach go lopsided.
//
// MEASURED BOTH WAYS ON THIS BUILD, which is what makes the thresholds below
// numbers rather than hopes. With the wedge the widest cross-section runs
// 5..10 px across the sweep and the two sides' reach differs by up to 7 px.
// With the cone restored (the lateral directions cleared, nothing else
// touched) every single roll gives 14 px and a span of [-7..+6] — constant to
// the pixel, and symmetric to within the one pixel of rounding. The gates are
// set at 4, a bit over halfway between the two, so neither reading is close.
//
// THE CAMERA, AND WHY THIS ONE ANGLE SWEEPS THE ROLL. At azimuth 0 the view
// forward has no X component for any elevation, so screen-right stays world +X
// and the X arm lies across the screen at full length no matter the elevation
// — while the plane containing the other two axes turns. The elevation IS the
// roll about that arm. The arm's projected length is asserted constant across
// the sweep for exactly this reason: if it moved, the widths would not be
// comparable and a foreshortening artifact could masquerade as the finding.
// --------------------------------------------------------------------------

// The widest cross-section at station `s`, as (width, lowest offset, highest
// offset) in pixels perpendicular to the arm, or width 0 if no stroke is there.
struct Span { int width, lo, hi, peak; }

Span spanAt(const ref Arm a, int s, int half) {
    auto prof = crossSection(a, s, half);
    Span sp;
    sp.peak = prof.maxElement;
    if (sp.peak < 60) return sp;
    int lo = int.max, hi = int.min;
    foreach (i, v; prof) {
        if (v <= sp.peak - 15) continue;
        immutable int d = cast(int)i - half;
        if (d < lo) lo = d;
        if (d > hi) hi = d;
        sp.width++;
    }
    sp.lo = lo; sp.hi = hi;
    return sp;
}

bool testFlowC() {
    writeln("  [C] Move arm ARROWHEAD — its width must BREATHE with the roll ...");
    resetApp();
    script("tool.set move");
    settle();
    // /api/reset restores the default camera, so this puts the shared instance
    // back for whatever test the worker runs next as well as for this file.
    scope(exit) { script("tool.set move off"); settle(); resetApp(); }

    enum int kHalf = 14;              // > any reach the head can have
    // Includes the two rolls where the law is extreme (-45 narrowest, +45
    // widest) and both ends, where the head sits wholly on one side.
    immutable int[] rolls = [-80, -60, -45, -20, 0, 20, 45, 65, 85];

    void setRoll(int deg) {
        import std.math : PI;
        httpPost("/api/camera",
                 format(`{"azimuth":0.0,"elevation":%.9g}`, deg * PI / 180.0));
        settle();
    }

    // Locate the head once, coarsely, at the first roll. Nothing here is copied
    // from the draw code — the head announces itself as the widest station, as
    // in Flow B — and the arm-length control below is what licenses reusing the
    // station across the rest of the sweep.
    setRoll(rolls[0]);
    auto h0 = handles();
    auto a0 = findArm(h0);
    int baseS = -1, baseW = 0;
    for (int s = 60; s <= 150; s += 4) {
        auto sp = spanAt(a0, s, kHalf);
        if (sp.width > baseW) { baseW = sp.width; baseS = s; }
    }
    enforce(baseS > 0 && baseW >= 4,
        format("no arrowhead found along the arm (widest %d px at s=%d)",
               baseW, baseS));

    struct Row { int roll, width, lo, hi, above, below; double armPx; }
    Row[] rows;
    foreach (roll; rolls) {
        setRoll(roll);
        auto h = handles();
        auto a = findArm(h);
        immutable double dx = h.screen[0][0] - h.screen[3][0];
        immutable double dy = h.screen[0][1] - h.screen[3][1];
        Span best;
        for (int s = baseS - 6; s <= baseS + 6; ++s) {
            auto sp = spanAt(a, s, kHalf);
            if (sp.width > best.width) best = sp;
        }
        enforce(best.width > 0,
            format("roll %d: no arrowhead ink near s=%d", roll, baseS));
        Row r;
        r.roll = roll; r.width = best.width; r.lo = best.lo; r.hi = best.hi;
        // Reach measured from the ARM'S OWN LINE, one side at a time. A cone
        // is symmetric about that line at every roll, so it pins these equal.
        r.above  = best.hi > 0 ? best.hi : 0;
        r.below  = best.lo < 0 ? -best.lo : 0;
        r.armPx  = sqrt(dx*dx + dy*dy);
        rows ~= r;
        writefln("    roll %+3d: width %2d px, perp [%+3d .. %+3d], "
                 ~ "reach %d / %d, arm %.1f px, peak ink %d",
                 r.roll, r.width, r.lo, r.hi, r.below, r.above, r.armPx, best.peak);
    }

    // CONTROL 1 — the arm itself did not move. Every roll must project the arm
    // to the same length; otherwise the sweep is changing the gizmo's size and
    // the width readings are not comparable across rows.
    double armMin = rows[0].armPx, armMax = rows[0].armPx;
    foreach (r; rows) {
        if (r.armPx < armMin) armMin = r.armPx;
        if (r.armPx > armMax) armMax = r.armPx;
    }
    enforce(armMax - armMin < 1.0,
        format("control failed: the arm's projected length varied %.2f px over "
               ~ "the sweep (%.1f .. %.1f). The camera is not rolling ABOUT the "
               ~ "arm, so any change in the head's width could be perspective "
               ~ "rather than shape", armMax - armMin, armMin, armMax));

    // CONTROL 2 — well off the arm is background, so "ink" is the arm's ink.
    {
        setRoll(0);
        auto hc = handles();
        auto a = findArm(hc);
        auto off = crossSection(a, baseS, 40);
        enforce(off[0] <= 15 && off[$ - 1] <= 15,
            format("control failed: 40 px off the arm axis is not background "
                   ~ "(ink %d and %d)", off[0], off[$ - 1]));
    }

    // C1 — the WIDTH breathes. A solid of revolution cannot: its silhouette
    // perpendicular to its own axis is its diameter at every roll.
    int wMin = rows[0].width, wMax = rows[0].width;
    foreach (r; rows) {
        if (r.width < wMin) wMin = r.width;
        if (r.width > wMax) wMax = r.width;
    }
    writefln("    width over the sweep: %d .. %d px (spread %d)",
             wMin, wMax, wMax - wMin);
    enforce(wMax - wMin >= 4,
        format("the arrowhead's screen width only varied %d px (%d..%d) over "
               ~ "%d rolls about its own arm. A head that keeps one width from "
               ~ "every angle is a solid of REVOLUTION — the measured head is a "
               ~ "tetrahedron with two base corners off the axis and the third "
               ~ "ON it, so its width must run from H to H*sqrt(2). Check that "
               ~ "the head is built by handles.gl_util.buildWedgeHeadData and "
               ~ "not by the cone tessellation", wMax - wMin, wMin, wMax,
               cast(int)rows.length));

    // C2 — the REACH is one-sided. This is the model-free half: it needs no fit
    // and no predicted law, only the observation that at some roll the head is
    // far more on one side of the arm than the other. Symmetric shapes — a cone
    // of revolution, a flat two-triangle head, a pyramid — all force it to ~0.
    int lopMax = 0, lopRoll = 0;
    foreach (r; rows) {
        immutable int lop = r.above > r.below ? r.above - r.below
                                              : r.below - r.above;
        if (lop > lopMax) { lopMax = lop; lopRoll = r.roll; }
    }
    writefln("    most lopsided roll: %+d, reach differs by %d px",
             lopRoll, lopMax);
    enforce(lopMax >= 4,
        format("the arrowhead never reached more than %d px further on one "
               ~ "side of the arm than the other, over %d rolls. It is "
               ~ "SYMMETRIC about the arm at every angle, which is what a cone "
               ~ "of revolution is and what the measured head is not: two of "
               ~ "its three base corners are offset from the axis and the third "
               ~ "sits on it, so the head leans into one quadrant and swaps "
               ~ "sides as the view rolls past the diagonal",
               lopMax, cast(int)rows.length));

    // C3 — the head composites exactly TWICE.
    //
    // THIS ASSERTION USED TO BE ITS OWN OPPOSITE, and the reversal is the whole
    // of task 0604's second port. The head is a closed capped solid on a
    // depth-off pass, so every face of it lands on the same pixels; this test
    // was written when we culled it to one layer, on the reasoning that a
    // translucent solid otherwise stacks its own alpha. The reasoning was right
    // in kind and wrong for this shape: the reference does not cull, its head
    // is a TETRAHEDRON — convex, so a ray crosses exactly two faces, not three
    // — and its arm was measured holding its colour across a 74-level
    // background change, which one 0.95 composite cannot do. Culling was
    // therefore making our head a measurable ~9 counts lighter than the head it
    // is a port of, and the fix is to stop.
    //
    // Read straight off the ink, which is background-free: the axis red is
    // (229,51,51), so the raw colour is 178, one 0.95 composite is 169, and two
    // are 0.9975*178 = 178 again. The 169/178 separation this used to rely on
    // is exactly the separation it relies on now, with the sides swapped — so
    // re-adding the cull fails here, as loudly as removing it once did.
    //
    // The layer COUNT is not inferred from this number, which cannot tell two
    // layers from three (0.9975 against 0.999875 is under a quarter of a
    // level). It was measured directly, by rebuilding at a diagnostic alpha of
    // 0.5 where the layers separate by 0.25 each: this head read 0.746/0.748,
    // i.e. two, while the scale bank's still-culled box read 0.496/0.500 in the
    // same frames as a control that the reading can tell one layer from two.
    //
    // VERIFIED BY MUTATION: `Arrow.draw` passing `HandleFacing.outwardCCW` for
    // the wedge again — i.e. the cull restored — built and run, fires exactly
    // this assertion at "head interior peak ink 169".
    {
        setRoll(0);
        auto hk = handles();
        auto a = findArm(hk);
        auto sp = spanAt(a, baseS, kHalf);
        enforce(sp.width >= 4, "no head found for the compositing check");
        auto prof = crossSection(a, baseS, kHalf);
        // Inside the head but clear of the shaft's own translucent stroke,
        // which lies on the arm's line and would legitimately stack with it.
        int peak = 0, deep = 0;
        foreach (d; sp.lo .. sp.hi + 1) {
            if (d >= -2 && d <= 2) continue;
            deep++;
            immutable int v = prof[d + kHalf];
            if (v > peak) peak = v;
        }
        enforce(deep >= 3,
            "the head does not extend far enough off the shaft to sample it "
            ~ "clear of the shaft's own stroke");
        writefln("    head interior peak ink %d (169 = one 0.95 layer, "
                 ~ "178 = two)", peak);
        enforce(peak >= 176,
            format("the arrowhead's deepest pixel read ink %d — the 169 that a "
                   ~ "SINGLE 0.95 composite gives, not the 178 of two. The "
                   ~ "head is being culled to one layer again: check that "
                   ~ "Arrow.draw still passes HandleFacing.twoLayer for the "
                   ~ "wedge and that beginHandleFill still treats it as "
                   ~ "cull-nothing", peak));
    }

    writeln("    C PASS: the head breathes, leans, and composites twice");
    return true;
}

// --------------------------------------------------------------------------

int main(string[] args) {
    // Resolve the port assigned to this worker by run_test.d.
    baseUrl = testBaseUrl();

    writeln("=== test_gizmo_handle_aa ===");
    int passed = 0, failed = 0;

    void run(bool function() fn, string name) {
        // Task 1111: report the ATTEMPT to the liveness gate before the case
        // can throw. A binary that reaches its exit having executed neither a
        // unittest of its own nor one counted scenario dies with code 3
        // instead of printing a pass over nothing — see tests/liveness_gate.d.
        import liveness_gate : scenario;
        scenario(name);
        try {
            if (fn()) { writeln("  PASS: ", name); passed++; }
            else      { writeln("  FAIL: ", name); failed++; }
        } catch (Exception e) {
            writefln("  FAIL: %s — %s", name, e.msg);
            failed++;
        }
    }

    run(&testFlowA, "Flow A — the line stroke is antialiased");
    run(&testFlowB, "Flow B — the solid arrowhead is NOT antialiased");
    run(&testFlowC, "Flow C — the arrowhead is a one-quadrant wedge");

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
