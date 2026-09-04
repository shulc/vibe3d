// test_gizmo_handle_alpha.d — the gizmo's LINES must reach the framebuffer
// opaque, not just correctly coloured.
//
// WHY THIS FILE EXISTS, AND WHY test_gizmo_handle_colours.d COULD NOT COVER IT.
// That test pins the constant on the constructed handle: `arrowX.color` is the
// X-axis red, `ring.color` is the ring's own. It passed throughout the bug.
// What it cannot see is everything BETWEEN the constant and the pixel — and
// that is where this defect lived: the arm shafts and the rotate rings reached
// the cell's framebuffer with the RIGHT rgb and an alpha of ZERO, because the
// thick-line program never seeded the `u_alpha` uniform that was later added to
// the fragment shader it shares with the regular one. The cell's colour texture
// is composited with SRC_ALPHA blending, so a zero-coverage line is blended
// away and the panel behind it shows through — the lines read as grey while the
// arrowheads, drawn by the other program, kept their colour.
//
// So the assertion has to be made on the FRAMEBUFFER, and specifically on the
// ALPHA CHANNEL, which no other test in the suite reads. `/api/viewport/probe`
// already returns it (task 0559); nothing had ever asserted on it.
//
// WHAT MAKES THIS NOT A SCREENSHOT TEST. It never looks at an image and never
// compares one. It asks the renderer for the handle's own reported screen
// position, reads the four channel VALUES at that position, and asserts them
// against the scheme colour restated as a literal plus a categorical alpha of
// 255. A mismatch names the channel and the handle.
//
// Flow A — Move bank: an arm's SHAFT (thick-line program) is opaque, and so is
//          the centre BOX (regular program). The box is the control: it was
//          always opaque, so its passing next to a failing shaft is what says
//          "the probe is reading a live frame and only one program is wrong".
// Flow B — Rotate bank: EVERY ring pixel found is opaque. This is the bank the
//          user saw entirely grey, because it is drawn entirely from lines.
//
// VERIFIED TO FAIL BEFORE THE FIX: on the unfixed binary both flows fail with
// "alpha 0, expected 255" at the same pixels this passes at afterwards.
//
// --------------------------------------------------------------------------
// HOW THE STROKE IS LOCATED, AND WHY THAT CHANGED (task 0600)
//
// This file used to find a stroke pixel by matching the scheme colour EXACTLY,
// on the stated premise that "these are UNBLENDED writes (blending is off for
// the handle passes), so the value is the uniform, not a mix". That premise is
// now false, deliberately: the gizmo's lines and arms are drawn at their
// measured alpha of 0.95 over a live blend, so a shaft pixel is
// `0.95*axis + 0.05*background` — about 6 counts off the raw colour on the
// saturated channel, which the old +-3 window rejects. The test failed exactly
// there, and the centre box (measured fully opaque, and therefore still an
// unblended write) went on passing beside it.
//
// The fix is NOT to widen the window to swallow the difference. That would
// weaken the only thing keeping this test pointed at a handle rather than at
// some other red thing. Instead the background is now MEASURED — the same
// points are probed a second time with the tool dropped — and the expectation
// is the exact composite of the two. That is strictly tighter than what it
// replaced: the old test could not see the alpha VALUE at all, and this one
// fails if the arm is drawn at 1.0, or at 0.8, or blended against the wrong
// destination. The alpha-CHANNEL assertion it was written for is untouched.
//
// A pleasant side effect: because full coverage only occurs along the stroke's
// centreline once the edges are antialiased, "the pixel matching the composite"
// IS the centreline pixel. So the 255 below is asserted where a correctly
// antialiased line must still be opaque, which is the property that separates
// working AA from a coverage function that has gone wrong.
//
// --------------------------------------------------------------------------
// WHAT THE ARM'S EXPECTATION IS NOW, AND WHY IT MOVED (task 0604)
//
// The arm's shaft is emitted TWICE, because the batch it ports is (four
// vertices in one LINES batch, the third resetting to the shaft's own start).
// Two composites of the measured 0.95 give 1-(1-0.95)^2 = 0.9975, so Flow A's
// expectation for the arm is 0.9975 and NOT 0.95. That is a change of
// expectation, and it is stated here rather than absorbed: the old value is
// ~6 counts away on the saturated channel and this file would have failed at
// "no pixel matching the X arm" until it was made.
//
// WHAT THAT COSTS, HONESTLY. A doubled emission compresses the top of the alpha
// range: the observed opacity is `1-(1-a)^2`, whose slope at a = 0.95 is 0.1.
// So this file can still exclude a SINGLE emission (0.95 against 0.9975 is
// ~6 counts over the backgrounds available) but it can NOT separate 0.9975
// from a folded alpha of 1.0, which is 0.3 counts — under quantisation. The
// two brackets that used to sit on either side of the arm's 0.95 therefore
// move, rather than being widened until they hold nothing:
//
//   * BELOW — Flow A and Flow C both exclude one layer. Flow C does it the way
//     the reference was measured: the same handle pixel over two backgrounds
//     64+ levels apart, asserting the observed colour does not move. That
//     separates "opaque" from "translucent at the right value", which a single
//     background cannot.
//   * ABOVE — Flow B. The rotate ring is emitted ONCE at the same measured
//     literal, so its composite still tracks that literal 1:1 and its 0.95 is
//     still bracketed from both sides here, at +-3 counts. A `unittest` beside
//     the constants (handles/gl_util.d) asserts the arm and the ring ARE that
//     one literal, which is what carries this bracket back to the arm.
//   * THE MECHANISM — a `unittest` in handles/shapes.d asserts the shaft batch
//     carries two identical segments. No probe can see the difference between
//     drawing twice at 0.95 and drawing once at 1.0 in the stroke's core, and
//     the difference at its antialiased EDGE (`1-(1-0.95c)^2` against `c`)
//     cannot be read without knowing each fringe pixel's coverage. So the
//     mechanism is pinned structurally, where it is unambiguous.
//
// VERIFIED BY MUTATION. `MoveHandler`'s `doubledShaft = true` set back to
// false, built and run:
//   -> Flow A, "no pixel matching the X arm composited at its effective
//      opacity 0.9975".
//   -> Flow C, "the arm's r channel moved -3 counts when its background moved
//      -64", against the -3.2 a single 0.95 predicts and the -0.2 two
//      emissions predict. The mutated arm read (57,202,57) over the light
//      background and (54,199,54) over the dark one — i.e. it moved WITH the
//      background, which is precisely what this flow exists to detect.
//   Flow B stayed green throughout, which is the point of keeping it: the
//   rings are a different batch and the mutation was not global.
// --------------------------------------------------------------------------

import http_client : testBaseUrl;
import std.stdio      : writeln, writefln;
import std.net.curl   : HTTP;
import std.json       : parseJSON, JSONValue, JSONType;
import std.exception  : enforce;
import std.conv       : to;
import std.format     : format;
import std.math       : abs, sqrt, round;
import core.thread    : Thread;
import core.time      : msecs;

// --------------------------------------------------------------------------
// Helpers
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

// `tool.set` is an argstring command, not a JSON one — /api/script is the
// endpoint that takes it (same route the ACEN tests use to arm a tool).
void script(string line) {
    string resp = httpPost("/api/script", line);
    enforce(parseJSON(resp)["status"].str == "ok",
            "script `" ~ line ~ "` failed: " ~ resp);
}

// The probe reads the last COMPLETED frame (the HTTP bridge is serviced before
// the scene render), so anything that changes the scene needs a frame to land
// before it is visible to a probe.
void settle() { Thread.sleep(400.msecs); }

void resetApp() {
    httpPost("/api/reset", "{}");
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

// One probe request over a list of FBO points (top-left origin). The cell is
// left to the endpoint's default, which is the ACTIVE cell — the only one
// --test renders, and the one the gizmo is drawn into.
Px[] probe(int[2][] pts) {
    string q = "/api/viewport/probe?points=";
    foreach (i, p; pts) {
        if (i) q ~= ";";
        q ~= format("%d,%d", p[0], p[1]);
    }
    auto j = parseJSON(httpGet(q));
    enforce("error" !in j, "probe failed: " ~ j.toString);
    // The --test single-rendered-cell trap: a probe at a never-filled FBO
    // reads zeros and every alpha assertion below would fail for the WRONG
    // reason. Assert the flag rather than trusting the default.
    enforce(j["renders"].type == JSONType.TRUE,
            "the probed cell is not rendered under --test; the reading is void");
    Px[] outp;
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
    return outp;
}

// The scheme, restated as 8-bit literals — the same independent-restatement
// convention test_gizmo_handle_colours.d uses. These are `round(255 * c)` of
// the Vec3 entries that test pins.
enum int[3] RGB_AXIS_X = [229,  51,  51];   // 0.9, 0.2, 0.2
enum int[3] RGB_AXIS_Y = [ 51, 204,  51];   // 0.2, 0.8, 0.2
enum int[3] RGB_AXIS_Z = [ 51, 102, 255];   // 0.2, 0.4, 1.0
enum int[3] RGB_HANDLE = [102, 255, 255];   // 0.4, 1.0, 1.0  (centre box)

// Software GL rounds the last bit differently across drivers; 3/255 is byte
// slop, not a shading tolerance.
//
// `isColor` is for the parts that are still UNBLENDED writes — the centre box,
// which is measured fully opaque — where the value really is the uniform.
bool isColor(Px p, const int[3] want) {
    return p.valid && abs(p.r - want[0]) <= 3
                   && abs(p.g - want[1]) <= 3
                   && abs(p.b - want[2]) <= 3;
}

/// The alpha every gizmo LINE batch is drawn at. Measured, and restated here as
/// a literal rather than read back from the app, so that changing it in the
/// renderer has to fail here and be re-justified.
enum double kStrokeAlpha = 0.95;

/// ...and the opacity an ARM reaches the framebuffer at, which is not the same
/// number, because its shaft is emitted twice: `1 - (1 - 0.95)^2`. Written as
/// the composition rather than as 0.9975 so that the reason survives beside the
/// value. See the task-0604 block at the top.
enum double kArmEffective = 1.0 - (1.0 - kStrokeAlpha) * (1.0 - kStrokeAlpha);

/// Is `p` the fully-covered composite of `want` at `alpha` over the background
/// `bg` measured at the same pixel with the gizmo dropped?
///
/// The same +-3 byte slop as `isColor`. Partial-coverage fringe pixels do NOT
/// satisfy this — their effective alpha is lower — which is exactly what makes
/// a match mean "centreline".
bool isStroke(Px p, Px bg, const int[3] want, double alpha) {
    if (!p.valid || !bg.valid) return false;
    int mix(int fg, int back) {
        return cast(int)(alpha * fg + (1.0 - alpha) * back + 0.5);
    }
    return abs(p.r - mix(want[0], bg.r)) <= 3
        && abs(p.g - mix(want[1], bg.g)) <= 3
        && abs(p.b - mix(want[2], bg.b)) <= 3;
}

// The handle registry, with the cell rectangle it was measured in.
struct Handles {
    double[2][int] screen;      // part id -> window-space position
    int vx, vy, vw, vh;         // the cell's rectangle in window space
}

Handles handles() {
    auto j = parseJSON(httpGet("/api/tool/handles"));
    enforce(j["handles"].type != JSONType.null_,
            "/api/tool/handles reports no handles — no tool is armed");
    auto h = j["handles"];
    Handles outh;
    outh.vx = cast(int)jsonNum(h, "viewport", "x");
    outh.vy = cast(int)jsonNum(h, "viewport", "y");
    outh.vw = cast(int)jsonNum(h, "viewport", "width");
    outh.vh = cast(int)jsonNum(h, "viewport", "height");
    foreach (e; h["parts"].array) {
        int id = cast(int)jsonNum(e, "part");
        outh.screen[id] = [e["screen"].array[0].floating,
                           e["screen"].array[1].floating];
    }
    return outh;
}

// Window coordinates -> the probe's FBO coordinates. Both are top-left origin;
// the cell's own corner is the only difference.
int[2] toFbo(const ref Handles h, double sx, double sy) {
    return [cast(int)round(sx - h.vx), cast(int)round(sy - h.vy)];
}

// --------------------------------------------------------------------------
// Flow A — the Move bank: shaft and box must BOTH be opaque
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] Move bank — arm shaft and centre box alpha...");
    resetApp();
    script("tool.set move");
    settle();
    scope(exit) { script("tool.set move off"); settle(); }

    auto h = handles();
    enforce(3 in h.screen && 0 in h.screen,
            "the move bank must publish a centre (part 3) and an X arm (part 0)");
    immutable double cx = h.screen[3][0], cy = h.screen[3][1];
    immutable double tx = h.screen[0][0], ty = h.screen[0][1];

    // --- A1: the centre BOX. Drawn as triangles on the regular program, which
    // has always seeded its uniforms. It is the CONTROL: it must be opaque on
    // the broken build too, which is what proves a failing A2 is about one
    // program rather than about the probe, the frame, or the camera.
    {
        auto pts = [toFbo(h, cx, cy)];
        auto got = probe(pts)[0];
        enforce(isColor(got, RGB_HANDLE),
            format("centre box: expected rgb(%d,%d,%d), got rgb(%d,%d,%d) — "
                   ~ "the probe is not looking at the gizmo centre",
                   RGB_HANDLE[0], RGB_HANDLE[1], RGB_HANDLE[2],
                   got.r, got.g, got.b));
        enforce(got.a == 255,
            format("centre box alpha %d, expected 255", got.a));
        writeln("    A1 PASS: centre box rgb + alpha 255 (control)");
    }

    // --- A2: the arm SHAFT. Drawn through the thick-line program. Sample the
    // segment centre->tip well inside the shaft (past the 1/5 inset, short of
    // the cone) and sweep perpendicular, because the drawn line is only a few
    // pixels wide and its exact row depends on the camera.
    {
        immutable double dx = tx - cx, dy = ty - cy;
        immutable double len = sqrt(dx*dx + dy*dy);
        enforce(len > 20, "the X arm projects to under 20 px; nothing to sample");
        immutable double ux = dx / len,  uy = dy / len;
        immutable double px = -uy,       py = ux;      // screen-space perpendicular

        int[2][] pts;
        foreach (ti; 0 .. 3) {
            immutable double t = 0.40 + 0.10 * ti;
            foreach (d; -5 .. 6)
                pts ~= toFbo(h, cx + dx*t + px*d, cy + dy*t + py*d);
        }
        auto got = probe(pts);

        // Second pass over the SAME points with the gizmo gone, so the
        // composite the stroke is checked against is measured rather than
        // assumed. Dropping the tool changes nothing else in the scene.
        script("tool.set move off");
        settle();
        auto bg = probe(pts);
        script("tool.set move");
        settle();
        enforce(bg.length == got.length, "the two probe passes disagree in length");

        Px[] onShaft;
        foreach (i, p; got)
            if (isStroke(p, bg[i], RGB_AXIS_X, kArmEffective)) onShaft ~= p;
        enforce(onShaft.length > 0,
            format("no pixel matching the X arm composited at its effective "
                   ~ "opacity %.4f (two emissions of %.2f) over its own "
                   ~ "measured background was found along the centre->tip "
                   ~ "segment. Either the arm was not drawn, or the shaft is "
                   ~ "reaching the framebuffer through ONE emission — a single "
                   ~ "%.2f lands ~6 counts short of this on the saturated "
                   ~ "channel (rgb(%d,%d,%d) is the unblended colour it "
                   ~ "composites FROM). See ShaftedArrow.doubledShaft",
                   kArmEffective, kStrokeAlpha, kStrokeAlpha,
                   RGB_AXIS_X[0], RGB_AXIS_X[1], RGB_AXIS_X[2]));

        foreach (p; onShaft)
            enforce(p.a == 255,
                format("X arm shaft at (%d,%d): rgb is right but alpha is %d, "
                       ~ "expected 255. A zero-coverage line is composited away "
                       ~ "and reads as the panel behind it — check that every "
                       ~ "program built on the shared fragment contract seeds "
                       ~ "u_alpha (shader.seedSharedFragUniforms), and that the "
                       ~ "handle blend leaves DESTINATION alpha alone "
                       ~ "(GL_ZERO/GL_ONE on the alpha channel)",
                       p.x, p.y, p.a));
        writefln("    A2 PASS: %d full-coverage shaft pixels, all alpha 255",
                 onShaft.length);
    }
    return true;
}

// --------------------------------------------------------------------------
// Flow B — the Rotate bank: every ring is a line, so ALL of it was grey
//
// Since task 0604 this flow carries a second job. The rotate ring is emitted
// ONCE, at the same measured 0.95 the arms are drawn at, so its composite is
// the only place in this file where that literal still moves the pixels 1:1 —
// which makes it the two-sided bracket on the value AND the in-frame proof
// that per-batch alpha is honoured at all. (Without it, "the arm reads its raw
// colour" would be equally consistent with a build that had stopped applying
// alpha anywhere. The reference's own measurement leaned on exactly this
// control, on its plane ring.)
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] Rotate bank — ring alpha...");
    resetApp();
    script("tool.set rotate");
    settle();
    scope(exit) { script("tool.set rotate off"); settle(); }

    auto h = handles();
    enforce(h.screen.length > 0, "the rotate bank must publish at least one handle");
    // NO part id is named here, deliberately: the banks have disjoint id bases
    // (the move arms start at 0, the rotate rings at 10) and hard-coding one
    // would make this test a hostage to that numbering. Every rotate part
    // reports the RING CENTRE as its screen position, so the centroid of
    // whatever was published is the centre to scan out from.
    double cx = 0, cy = 0;
    foreach (_, s; h.screen) { cx += s[0]; cy += s[1]; }
    cx /= h.screen.length;
    cy /= h.screen.length;

    // Scan a ray outward and collect every pixel wearing one of the three
    // saturated axis colours. Only the saturated ones: the view ring's grey is
    // close enough to the shaded mesh and the grid that matching it would risk
    // asserting alpha on a pixel that is not a ring at all.
    int[2][] pts;
    foreach (d; 0 .. 140) pts ~= toFbo(h, cx + d, cy);

    // Same two-pass measurement as Flow A: read the ray with the rings up, then
    // read it again with them gone, and require the exact composite of the two.
    Px[] withRings, background;
    for (size_t i = 0; i < pts.length; i += 70) {
        auto slice = pts[i .. (i + 70 > pts.length ? pts.length : i + 70)];
        withRings ~= probe(slice);
    }
    script("tool.set rotate off");
    settle();
    for (size_t i = 0; i < pts.length; i += 70) {
        auto slice = pts[i .. (i + 70 > pts.length ? pts.length : i + 70)];
        background ~= probe(slice);
    }
    script("tool.set rotate");
    settle();
    enforce(withRings.length == background.length,
            "the two probe passes disagree in length");

    Px[] onRing;
    foreach (i, p; withRings)
        if (isStroke(p, background[i], RGB_AXIS_X, kStrokeAlpha)
         || isStroke(p, background[i], RGB_AXIS_Y, kStrokeAlpha)
         || isStroke(p, background[i], RGB_AXIS_Z, kStrokeAlpha))
            onRing ~= p;

    enforce(onRing.length > 0,
        format("no ring pixel matching an axis colour composited at alpha %.2f "
               ~ "over its own measured background was found on a ray out of "
               ~ "the rotate gizmo centre — the rings were not drawn, or not at "
               ~ "that alpha", kStrokeAlpha));
    foreach (p; onRing)
        enforce(p.a == 255,
            format("rotate ring at (%d,%d): rgb(%d,%d,%d) is right but alpha is "
                   ~ "%d, expected 255. The whole rotate bank is drawn from "
                   ~ "lines, so an unseeded u_alpha greys ALL of it",
                   p.x, p.y, p.r, p.g, p.b, p.a));
    writefln("    B1 PASS: %d ring pixels, all alpha 255", onRing.length);
    return true;
}

// --------------------------------------------------------------------------
// Flow C — the arm's opacity does not move with what is behind it
//
// This is the flow that separates "opaque" from "translucent at the right
// value", and a single background cannot do it: over ONE destination a stroke
// at 0.95 and a stroke at 0.9975 are just two numbers, and either could be
// explained by the wrong colour, the wrong destination, or an alpha that is
// not being applied at all. Read the SAME handle pixel over two very different
// backgrounds and the model drops out —
//
//     A = 1 - (O1 - O2) / (B1 - B2)
//
// needs neither the stroke's colour nor the display's transfer function. This
// is the reference's own measurement restated against our renderer.
//
// "The same pixel" is a checked premise, not an assumption: the gizmo is
// screen-sized and anchored on the projected action centre, so changing only
// the camera DISTANCE moves the scene behind it and leaves its own screen
// geometry alone — and the flow asserts that the handle registry agrees before
// it compares any pixel.
//
// The pixels are selected by HUE (an arm pixel is the one where the axis
// channel runs far ahead of the other two), never by the expectation under
// test, so the opacity assertion below is a measurement and not a tautology.
// --------------------------------------------------------------------------

void setCamera(double distance) {
    httpPost("/api/camera",
             format(`{"azimuth":0.5,"elevation":0.4,"distance":%.3f,`
                    ~ `"focus":{"x":0.0,"y":0.0,"z":0.0}}`, distance));
    settle();
}

// How far an arm's own channel runs ahead of the other two. Background — grey
// mesh, grey backdrop, grid — sits near 0 on this measure whatever its
// brightness, which is exactly why it identifies the arm without knowing what
// is behind it, and without reference to the opacity under test.
int ink(Px p, int dom) {
    if (!p.valid) return 0;
    immutable int[3] ch = [p.r, p.g, p.b];
    int other = int.min;
    foreach (c; 0 .. 3) if (c != dom && ch[c] > other) other = ch[c];
    return ch[dom] - other;
}

bool testFlowC() {
    writeln("  [C] the arm's opacity is invariant to its background...");
    resetApp();
    script("tool.set move");
    settle();
    scope(exit) { script("tool.set move off"); settle(); setCamera(3.0); }

    struct Pose { Px[] fg, bg; double cx, cy, tx, ty; }
    Pose[2] pose;
    immutable double[2] dists = [3.0, 0.75];
    // The Y arm, and the choice is load-bearing: it is the one that reaches up
    // across the backdrop's brighter band at the far camera and is covered by
    // the mesh at the near one. The X arm stays over two greys 13 levels apart,
    // which is not enough contrast to decide anything.
    enum int PART_ARM = 1;
    enum int DOM = 1;                       // the Y arm's own channel

    int[2][] pts;
    foreach (k, dist; dists) {
        setCamera(dist);
        auto h = handles();
        enforce(3 in h.screen && PART_ARM in h.screen,
                "the move bank must publish a centre (part 3) and a Y arm (part 1)");
        pose[k].cx = h.screen[3][0]; pose[k].cy = h.screen[3][1];
        pose[k].tx = h.screen[PART_ARM][0]; pose[k].ty = h.screen[PART_ARM][1];

        if (k == 0) {
            // Sample the SHAFT only — short of the head, so this flow is about
            // the doubled stroke and not about the solid beside it.
            immutable double dx = pose[0].tx - pose[0].cx;
            immutable double dy = pose[0].ty - pose[0].cy;
            immutable double len = sqrt(dx*dx + dy*dy);
            enforce(len > 20, "the Y arm projects to under 20 px; nothing to sample");
            immutable double px = -dy/len, py = dx/len;
            // The published anchor is 70 % along the arm, so t up to 1.0 is
            // still shaft with the head beyond it.
            foreach (ti; 0 .. 15) {
                immutable double t = 0.30 + 0.05 * ti;
                foreach (d; -4 .. 5)
                    pts ~= toFbo(h, pose[0].cx + dx*t + px*d,
                                    pose[0].cy + dy*t + py*d);
            }
        } else {
            enforce(abs(pose[1].cx - pose[0].cx) < 0.5
                 && abs(pose[1].cy - pose[0].cy) < 0.5
                 && abs(pose[1].tx - pose[0].tx) < 0.5
                 && abs(pose[1].ty - pose[0].ty) < 0.5,
                 "the gizmo moved between the two camera distances, so the two "
                 ~ "readings are not of the same handle pixel and the "
                 ~ "background swap is not isolated");
        }

        pose[k].fg = probe(pts);
        script("tool.set move off");
        settle();
        pose[k].bg = probe(pts);
        script("tool.set move");
        settle();
    }

    // Among the pixels that are unambiguously arm in BOTH poses, take the one
    // whose two backgrounds differ most.
    int best = -1, bestDelta = 0;
    foreach (i; 0 .. cast(int)pts.length) {
        if (!pose[0].bg[i].valid || !pose[1].bg[i].valid) continue;
        if (ink(pose[0].fg[i], DOM) < 100 || ink(pose[1].fg[i], DOM) < 100) continue;
        immutable int d = abs(pose[0].bg[i].r - pose[1].bg[i].r);
        if (d > bestDelta) { bestDelta = d; best = i; }
    }
    enforce(best >= 0 && bestDelta >= 40,
        format("no arm pixel sat over two backgrounds at least 40 levels "
               ~ "apart across the two camera distances (best found: %d). "
               ~ "Without that contrast this flow cannot distinguish an opaque "
               ~ "arm from a translucent one and must not report a pass — "
               ~ "re-pick the poses so the arm crosses the backdrop in one and "
               ~ "the mesh in the other", bestDelta));

    immutable Px o1 = pose[0].fg[best], b1 = pose[0].bg[best];
    immutable Px o2 = pose[1].fg[best], b2 = pose[1].bg[best];
    writefln("    arm pixel (%d,%d): O=(%d,%d,%d) over B=(%d,%d,%d)  and  "
             ~ "O=(%d,%d,%d) over B=(%d,%d,%d)",
             o1.x, o1.y, o1.r, o1.g, o1.b, b1.r, b1.g, b1.b,
             o2.r, o2.g, o2.b, b2.r, b2.g, b2.b);

    // The model-free estimate, per channel, on every channel with contrast.
    immutable int[3] dB = [b2.r - b1.r, b2.g - b1.g, b2.b - b1.b];
    immutable int[3] dO = [o2.r - o1.r, o2.g - o1.g, o2.b - o1.b];
    immutable string names = "rgb";
    int tested = 0;
    foreach (c; 0 .. 3) {
        if (abs(dB[c]) < 40) continue;
        tested++;
        immutable double a = 1.0 - cast(double)dO[c] / cast(double)dB[c];
        writefln("    %c: dB=%+4d dO=%+3d -> observed opacity %.4f",
                 names[c], dB[c], dO[c], a);
        // One 8-bit step of slack, which is all the quantisation can hide.
        enforce(abs(dO[c]) <= 1,
            format("the arm's %c channel moved %d counts when its background "
                   ~ "moved %d. A single emission of %.2f predicts exactly "
                   ~ "this: %.1f counts. Two emissions predict %.1f. The arm "
                   ~ "is reaching the framebuffer through one layer",
                   names[c], dO[c], dB[c], kStrokeAlpha,
                   (1.0 - kStrokeAlpha) * dB[c],
                   (1.0 - kArmEffective) * dB[c]));
    }
    enforce(tested > 0, "no channel carried 40 levels of background contrast");
    writefln("    C1 PASS: opacity invariant across a %d-level background "
             ~ "change on %d channel(s) — one emission is excluded",
             bestDelta, tested);
    return true;
}

// --------------------------------------------------------------------------

int main(string[] args) {
    // Resolve the port assigned to this worker by run_test.d.
    baseUrl = testBaseUrl();

    writeln("=== test_gizmo_handle_alpha ===");
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

    run(&testFlowA, "Flow A — move arm shaft reaches the framebuffer opaque");
    run(&testFlowB, "Flow B — rotate rings reach the framebuffer opaque");
    run(&testFlowC, "Flow C — the arm's opacity does not move with its background");

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
