// test_view_grid.d — task 0570: the grid step is a screen length, and it
// moves in RUNGS.
//
// The law under test:
//
//     gridSize = niceCeil(mask, 25 * pixelSize)
//
// i.e. the grid step is the world length of 25 screen pixels, pushed up to
// the next rung of a mantissa ladder ({1, 2, 5, 10} by default). vibe3d's
// grid used to be a fixed 1.0-unit world lattice, so at every zoom but one it
// was a different thing entirely.
//
// WHY THIS FILE EXISTS AT ALL, given source/viewgrid.d's own unittests: those
// pin the arithmetic. This pins that the arithmetic is what the RUNNING APP
// uses and DRAWS — a pure function nothing calls is not a grid.
//
// Three tiers, in increasing strength:
//
//   Flow A — the endpoint reports the law, at the app's own camera, over a
//            zoom sweep. Numbers, from the same snapshot the renderer gets.
//   Flow B — the reported step MOVES IN RUNGS: over a fine, continuous sweep
//            of the camera distance it takes a handful of ladder values, is
//            monotone, and never lands between rungs. A grid that glided
//            would pass every assertion in Flow A and fail here.
//   Flow C — the ladder is a SETTING and it is refused when nonsense.
//
// A PIXEL tier is deliberately absent HERE: at this commit the law is
// computed and reported but nothing draws it, so a pixel assertion would have
// nothing to assert. It arrives with the commit that wires the grid.
module test_view_grid;

import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.conv      : to;
import std.format    : format;
import std.math      : abs, log10, floor, pow, fabs;
import std.algorithm : canFind;
import core.thread   : Thread;
import core.time     : msecs;

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

string rawCommand(string cmd, string params) {
    JSONValue j;
    j["id"] = cmd;
    if (params.length) j["params"] = params;
    return httpPost("/api/command", j.toString);
}

/// The command takes its argument as a bare scalar, which over HTTP means
/// `"params": "<scalar>"` — the server hands the handler `j["params"].toString`,
/// so a nested object arrives DOUBLE-ENCODED and lands in the string arm.
/// (`postCommandRaw` in test_viewport_display.d exists for the same reason.)
void setLadder(string arg) { postCommand("viewport.gridSteps", arg); }

void postCommand(string cmd, string params = "") {
    string resp = rawCommand(cmd, params);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " failed: " ~ resp);
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

JSONValue gridDump() {
    return parseJSON(httpGet("/api/viewport/display"))["cells"].array[0]["grid"];
}

void setCamera(double az, double el, double dist) {
    httpPost("/api/camera",
        format(`{"azimuth":%.9g,"elevation":%.9g,"distance":%.9g}`, az, el, dist));
    Thread.sleep(120.msecs);
}

void resetApp() {
    httpPost("/api/reset", "{}");
    Thread.sleep(350.msecs);
}

// The ladder the shipped mask (5) admits. Written out here rather than read
// back from the app: a test that asks the product what the answer is and then
// checks the product against it asserts nothing.
immutable double[] kRungs5 = [1.0, 2.0, 5.0, 10.0];

/// True when `v` is `m * 10^n` for an `m` in `rungs`.
bool isRung(double v, const(double)[] rungs, double relTol = 1e-5) {
    if (!(v > 0)) return false;
    immutable double e = floor(log10(v));
    immutable double m = v / pow(10.0, e);
    foreach (r; rungs) {
        if (fabs(m - r)        <= relTol * r) return true;
        if (fabs(m * 10.0 - r) <= relTol * r) return true;   // decade edge
        if (fabs(m * 0.1  - r) <= relTol * r) return true;
    }
    return false;
}

/// The reference implementation of the law, written independently of the
/// product's: ceil onto the ladder by brute force over the decades, no logs,
/// no shared helper. If both are wrong they have to be wrong the same way by
/// accident.
double expectedCeil(double x, const(double)[] rungs) {
    enforce(x > 0);
    double best = double.max;
    foreach (e; -12 .. 13) {
        foreach (m; rungs) {
            immutable double cand = m * pow(10.0, cast(double)e);
            if (cand >= x * (1 - 1e-12) && cand < best) best = cand;
        }
    }
    enforce(best != double.max, format("no rung above %g", x));
    return best;
}

// --------------------------------------------------------------------------
// Flow A — the endpoint reports the law
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] gridSize == niceCeil(25 * pixelSize), at the app's camera...");
    resetApp();

    // A wide spread of zooms, deliberately including values whose raw
    // 25*pixelSize lands near a rung boundary from both sides.
    foreach (dist; [0.4, 1.0, 2.0, 3.86, 5.0, 8.0, 20.0, 60.0, 200.0]) {
        setCamera(0.5, 0.3, dist);
        auto g = gridDump();
        immutable double px   = jsonNum(g, "pixelSize");
        immutable double size = jsonNum(g, "size");
        immutable double cell = jsonNum(g, "cellPixels");

        enforce(px > 0, format("dist %g: pixelSize must be positive, got %g", dist, px));
        immutable double want = expectedCeil(25.0 * px, kRungs5);
        enforce(fabs(size - want) <= 1e-6 * want,
            format("dist %g: gridSize %.9g != niceCeil(25*%.9g) = %.9g",
                   dist, size, px, want));

        // The claim restated in the units it is ABOUT: a cell is never
        // narrower than 25 screen pixels, and never wider than the ladder's
        // worst gap (5/2) times that.
        enforce(cell >= 25.0 * (1 - 1e-4),
            format("dist %g: a cell is %.4f px — narrower than the 25-pixel floor",
                   dist, cell));
        enforce(cell <= 62.5 * (1 + 1e-4),
            format("dist %g: a cell is %.4f px — wider than the ladder allows",
                   dist, cell));
        enforce(isRung(size, kRungs5),
            format("dist %g: step %.9g is not on the {1,2,5,10} ladder", dist, size));
    }
    writeln("    A1 PASS: nine zooms, step == niceCeil(25*px), cell in [25, 62.5] px");

    // pixelSize itself must scale with the camera distance: ten times as far
    // is ten times the world per pixel, and therefore (the ladder being
    // closed under x10) exactly ten times the step.
    setCamera(0.5, 0.3, 2.0);
    immutable double s2 = jsonNum(gridDump(), "size");
    setCamera(0.5, 0.3, 20.0);
    immutable double s20 = jsonNum(gridDump(), "size");
    enforce(fabs(s20 - 10.0 * s2) <= 1e-5 * s20,
        format("ten times the distance must be ten times the step: %.9g vs %.9g",
               s2, s20));
    writeln("    A2 PASS: 10x the distance is exactly 10x the step");

    // The sub-step is a SEPARATE number and is one screen pixel, not a tenth
    // of the drawn step. (A tenth would be 2.5 px — these are distinguishable.)
    setCamera(0.5, 0.3, 3.86);
    auto g3 = gridDump();
    immutable double px3 = jsonNum(g3, "pixelSize");
    immutable double ss3 = jsonNum(g3, "subStep");
    enforce(fabs(ss3 - expectedCeil(px3, kRungs5)) <= 1e-6 * ss3,
        format("subStep %.9g != niceCeil(1 * %.9g)", ss3, px3));
    enforce(ss3 < jsonNum(g3, "size"),
        "the sub-step must be finer than the drawn step");
    writeln("    A3 PASS: subStep == niceCeil(one pixel), finer than the step");
    return true;
}

// --------------------------------------------------------------------------
// Flow B — it moves in RUNGS, not continuously
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] the step is a STAIRCASE over a continuous zoom sweep...");
    resetApp();

    // A geometric sweep across one full decade of distance, fine enough that
    // a continuous law would show ~40 distinct values.
    enum int N = 40;
    double[] steps;
    double prev = 0;
    foreach (i; 0 .. N + 1) {
        immutable double dist = 2.0 * pow(10.0, cast(double)i / N);
        setCamera(0.5, 0.3, dist);
        immutable double s = jsonNum(gridDump(), "size");
        enforce(isRung(s, kRungs5),
            format("dist %.4f: step %.9g is not a rung — the grid is gliding",
                   dist, s));
        enforce(s >= prev * (1 - 1e-6),
            format("dist %.4f: step went DOWN (%.9g after %.9g) while zooming out",
                   dist, s, prev));
        prev = s;
        if (!steps.canFind!(v => fabs(v - s) <= 1e-9 * s)) steps ~= s;
    }

    // A decade of zoom crosses the ladder exactly once, so it produces the
    // ladder's worth of distinct steps — four or five depending on where the
    // endpoints fall. THIS is the assertion that a smoothly-scaled grid
    // fails: it would report ~41.
    enforce(steps.length >= 3 && steps.length <= 6,
        format("a decade of zoom produced %d distinct steps — a staircase has "
               ~ "about four, a continuum has %d", steps.length, N + 1));
    writefln("    B1 PASS: %d distinct steps over 41 zooms across a decade %s",
             steps.length, steps);

    // Consecutive distinct steps are ladder RATIOS (2, 2.5, 2 within
    // {1,2,5,10}), never arbitrary.
    foreach (i; 1 .. steps.length) {
        immutable double ratio = steps[i] / steps[i - 1];
        enforce(fabs(ratio - 2.0) < 1e-4 || fabs(ratio - 2.5) < 1e-4,
            format("step jumped by %.6f — not a {1,2,5,10} ladder ratio", ratio));
    }
    writeln("    B2 PASS: every jump is a ladder ratio (2 or 2.5)");
    return true;
}

/// D forbids a `catch` inside a `scope(exit)` body, so the restore is a named
/// function rather than an inline try/catch. It is also the thing every
/// mutating flow owes the next test in the worker's slice: the ladder is an
/// APP-WIDE setting and `/api/reset` does not touch it.
void restoreLadder() {
    try setLadder("5");
    catch (Exception) {}
}

// --------------------------------------------------------------------------
// Flow C — the ladder is a setting
// --------------------------------------------------------------------------

bool testFlowC() {
    writeln("  [C] the mantissa ladder is a setting, and a checked one...");
    resetApp();
    scope(exit) restoreLadder();

    setCamera(0.5, 0.3, 3.86);
    enforce(jsonNum(gridDump(), "mask") == 5, "the shipped ladder must be mask 5");

    // Mask 0 is {1, 10}: the same camera whose step was 0.2 under {1,2,5,10}
    // has to round up to 1.0, because 0.2 is not on {1,10}.
    immutable double before = jsonNum(gridDump(), "size");
    setLadder("0");
    Thread.sleep(150.msecs);
    auto g0 = gridDump();
    enforce(jsonNum(g0, "mask") == 0, "the command must change the live mask");
    immutable double after = jsonNum(g0, "size");
    enforce(isRung(after, [1.0, 10.0]),
        format("under mask 0 the step %.9g must be on {1,10}", after));
    enforce(after > before,
        format("a coarser ladder cannot give a finer step (%.9g -> %.9g)",
               before, after));
    writefln("    C1 PASS: mask 0 lifts the step %.4g -> %.4g and stays on {1,10}",
             before, after);

    // Every mask is reachable, and the rung-set spelling reaches the same one
    // as the number — a UI and a test naming the same ladder differently is
    // how the two drift.
    setLadder("1,2,2.5,5,10");
    Thread.sleep(120.msecs);
    enforce(jsonNum(gridDump(), "mask") == 7,
        "the spelled-out rung set must resolve to the same mask as the number");
    writeln("    C2 PASS: \"1,2,2.5,5,10\" resolves to mask 7");

    // Out of range is REFUSED, not clamped. 8 is not a coarser 7.
    //
    // THE REASON IS ASSERTED, NOT JUST THE REFUSAL, and that is not
    // belt-and-braces: the first cut of this check passed against a build
    // that clamped, because it double-encoded its own argument and was
    // measuring "an unparseable string is refused" instead. A refusal whose
    // message does not name the range is not evidence about the range.
    struct Bad { string arg; string wants; }
    foreach (b; [Bad("8",      "outside 0..7"),
                 Bad("-1",     "outside 0..7"),
                 Bad("1,3,10", "neither a mask"),
                 Bad("banana", "neither a mask")]) {
        string resp = rawCommand("viewport.gridSteps", b.arg);
        auto r = parseJSON(resp);
        enforce("status" in r && r["status"].str == "error",
            format("viewport.gridSteps %s must be refused, got: %s", b.arg, resp));
        enforce(r["message"].str.canFind(b.wants),
            format("viewport.gridSteps %s was refused, but for the wrong "
                   ~ "reason — expected a message naming '%s', got: %s",
                   b.arg, b.wants, r["message"].str));
    }
    // ...and the refusal left the live setting alone.
    enforce(jsonNum(gridDump(), "mask") == 7,
        "a refused command must not have changed the mask");
    writeln("    C3 PASS: 8 / -1 / an unknown rung set refused BY REASON, state intact");
    return true;
}

// --------------------------------------------------------------------------

int main(string[] args) {
    // NOTE: keep the literal "http://localhost:8080" — run_test.d isolates
    // parallel workers by textually rewriting "localhost:8080" to the worker's
    // port in a scratch copy of the source.
    baseUrl = "http://localhost:8080";

    writeln("=== test_view_grid ===");
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

    run(&testFlowA, "Flow A — gridSize is niceCeil(25 * pixelSize) in the app");
    run(&testFlowB, "Flow B — the step is a staircase, not a continuum");
    run(&testFlowC, "Flow C — the ladder is a setting, and out-of-range is refused");

    // The runner shares one app across a worker's slice and its between-tests
    // reset does not cover the grid ladder (an app-wide setting, not document
    // state). Every flow restores in a scope(exit); this catches a flow that
    // died somewhere that skipped even that.
    restoreLadder();

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
