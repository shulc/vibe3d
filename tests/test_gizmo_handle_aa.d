// test_gizmo_handle_aa.d — the gizmo's LINES are antialiased and its SOLIDS
// are not, and that asymmetry is the whole finding.
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
// measure and full stroke at ~169 — the axis red 229/51/51 composited at the
// arm's own 0.95 alpha. Using an EXCESS rather than a distance-to-a-literal is
// what makes the test indifferent to what is behind the gizmo.
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

int main(string[] args) {
    // NOTE: keep the literal "http://localhost:8080" — run_test.d isolates
    // parallel workers by textually rewriting "localhost:8080" to the worker's
    // port in a scratch copy of the source.
    baseUrl = "http://localhost:8080";

    writeln("=== test_gizmo_handle_aa ===");
    int passed = 0, failed = 0;

    void run(bool function() fn, string name) {
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

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
