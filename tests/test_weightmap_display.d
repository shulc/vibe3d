// test_weightmap_display.d — task 1090, the weight-map surface style.
//
// TIER 2 OF TWO. `tests/unit/weightmap_color_test.d` pins the LAW and cannot
// see whether it reaches a pixel. This file pins the PLUMBING — and it reads
// every expected byte out of the SAME frozen fixture the unit test asserts
// against, so it carries no colour constants of its own and the two tiers
// cannot drift apart.
//
// WHAT MAKES THE ASSERTIONS HERE VALUES AND NOT CATEGORIES. Its sibling
// `test_viewport_display.d` warns in its own header that every pixel claim it
// makes must stay CATEGORICAL ("equals the clear colour", "changed"), because
// the lane runs software GL and shading arithmetic can differ. This style has
// no shading arithmetic: it is unlit, and a fragment is a plain interpolation
// of a per-vertex constant. Under a UNIFORM weight there is not even an
// interpolation left. So the only conversion between our float and the
// measured byte is GL's float->unorm8, and the one place that is allowed to
// differ is an exact `.5` tie, which GL 3.3 §2.1.2 leaves unspecified. That is
// the entire tolerance budget, it is spent in one named place, and everywhere
// else these assertions are exact.
//
// Flow L0 — the shared lattice and its inverse agree (the arithmetic every
//           other flow's sample locations rest on).
// Flow A  — a uniform weight paints the measured colour, and does not vary
//           with the surface normal the way a lit render must.
// Flow A2 — editing a weight VALUE reaches the screen (the DisplayRefreshMask
//           coupling, which nothing else in the tree would notice breaking).
// Flow B  — the sign: a negative weight is blue, not red.
// Flow C  — the surface follows the map SELECTION, with no mesh edit at all.
// Flow C2 — the style is per CELL; the map is not.
// Flow D  — no map, and a dangling map, both render the neutral — and the
//           endpoint still tells them apart.
// Flow E  — a subpatch preview renders the neutral rather than reading a cage
//           weight array by a preview vertex index.
// Flow F  — the colours survive a topology edit (the stale attribute pointer).
// Flow G  — the overlays survive the style: selection stipples exactly a
//           quarter of the pixels and hover tints, both over weight colour.
// Flow H  — the clamp is on the blend factor, not on the output.
module test_weightmap_display;

import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.conv      : to;
import std.format    : format;
import std.math      : abs;
import std.algorithm : sort;
import core.thread   : Thread;
import core.time     : msecs;

import viewport_lattice_helpers : kFillNX, kFillNY, kFillStride,
                                  fillLattice, latticePoint,
                                  erodedFillIndices;

// --------------------------------------------------------------------------
// HTTP plumbing
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

void postCommand(string cmd, string params = "") {
    JSONValue j;
    j["id"] = cmd;
    if (params.length) j["params"] = params;
    string resp = httpPost("/api/command", j.toString);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " failed: " ~ resp);
}

/// POST a command whose `params` is a JSON OBJECT rather than a bare string.
void postCommandObj(string cmd, string paramsJson) {
    string body_ = `{"id":"` ~ cmd ~ `","params":` ~ paramsJson ~ `}`;
    string resp = httpPost("/api/command", body_);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " " ~ paramsJson ~ " failed: " ~ resp);
}

/// The probe reads the last COMPLETED frame (the HTTP bridge is serviced
/// before the scene render), so anything that changes the scene needs a frame
/// to land before it is visible to a probe.
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

bool jsonBool(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    enforce(cur.type == JSONType.TRUE || cur.type == JSONType.FALSE,
            "expected a bool at ." ~ path[$ - 1] ~ ", got " ~ cur.toString);
    return cur.type == JSONType.TRUE;
}

JSONValue displayDump() { return parseJSON(httpGet("/api/viewport/display")); }
JSONValue model()       { return parseJSON(httpGet("/api/model")); }
JSONValue selection()   { return parseJSON(httpGet("/api/selection")); }

/// How many of the mesh's undirected edges do NOT border exactly two faces.
///
/// Zero means a CLOSED solid. Flow G's premise block below is the only caller
/// and carries the reason it needs that property; `/api/model` publishes no
/// adjacency, so it is recomputed here from the face loops it does publish.
size_t openEdgeCount(JSONValue mdl) {
    size_t[int[2]] use;
    foreach (f; mdl["faces"].array) {
        auto vs = f.array;
        foreach (j; 0 .. vs.length) {
            immutable int a = cast(int)vs[j].integer;
            immutable int b = cast(int)vs[(j + 1) % vs.length].integer;
            immutable int[2] key = a < b ? [a, b] : [b, a];
            use[key] = use.get(key, 0) + 1;
        }
    }
    size_t bad = 0;
    foreach (n; use.byValue) if (n != 2) bad++;
    return bad;
}

struct Px { int x, y, r, g, b, a; bool valid; }

/// The hardcoded scene clear colour, from `test_viewport_display.d`. A sample
/// equal to it means NOTHING was drawn there.
enum int kClearR = 92, kClearG = 102, kClearB = 107;

bool isClear(Px p) {
    return abs(p.r - kClearR) <= 2 && abs(p.g - kClearG) <= 2
        && abs(p.b - kClearB) <= 2;
}

bool samePixel(Px a, Px b) {
    return a.valid && b.valid && a.r == b.r && a.g == b.g && a.b == b.b;
}

struct ProbeResult { int w, h; bool renders; Px[] points; }

ProbeResult probe(int cell, string points) {
    string q = format("/api/viewport/probe?cell=%d", cell);
    if (points.length) q ~= "&points=" ~ points;
    auto j = parseJSON(httpGet(q));
    enforce("error" !in j || j["points"].array.length > 0,
            "probe failed: " ~ j.toString);
    ProbeResult r;
    r.w       = cast(int)jsonNum(j, "w");
    r.h       = cast(int)jsonNum(j, "h");
    r.renders = jsonBool(j, "renders");
    foreach (e; j["points"].array) {
        Px p;
        p.x = cast(int)jsonNum(e, "x");
        p.y = cast(int)jsonNum(e, "y");
        if ("error" in e) { p.valid = false; r.points ~= p; continue; }
        p.r = cast(int)jsonNum(e, "r");
        p.g = cast(int)jsonNum(e, "g");
        p.b = cast(int)jsonNum(e, "b");
        p.a = cast(int)jsonNum(e, "a");
        p.valid = true;
        r.points ~= p;
    }
    return r;
}

/// Largest per-channel spread over a set of samples — 0 means every sample is
/// literally the same colour.
int channelSpread(in Px[] img, in size_t[] idx) {
    int worst = 0;
    foreach (c; 0 .. 3) {
        int lo = 255, hi = 0;
        foreach (i; idx) {
            immutable int v = (c == 0) ? img[i].r : (c == 1) ? img[i].g : img[i].b;
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        if (hi - lo > worst) worst = hi - lo;
    }
    return worst;
}

// --------------------------------------------------------------------------
// The frozen fixture — the ONE source of every expected colour here
//
// Embedded at COMPILE time via `-J=tests`, the convention `fixture_helpers.d`
// established, so the assertion does not depend on the binary's working
// directory. The unit test reads the same file at run time and asserts the
// module function against it; this file reads it and asserts the FRAMEBUFFER
// against it. Neither carries a colour literal.
// --------------------------------------------------------------------------

enum string kFixtureSrc = import("fixtures/weightmap_display/ramp.json");

JSONValue fixture() {
    static JSONValue cached;
    static bool loaded = false;
    if (!loaded) { cached = parseJSON(kFixtureSrc); loaded = true; }
    return cached;
}

/// The measured byte triple for weight `w`.
int[3] fixtureRgb(double w) {
    foreach (c; fixture()["cases"].array) {
        double cw;
        switch (c["weight"].type) {
            case JSONType.float_:   cw = c["weight"].floating; break;
            case JSONType.integer:  cw = cast(double)c["weight"].integer; break;
            case JSONType.uinteger: cw = cast(double)c["weight"].uinteger; break;
            default: continue;
        }
        if (abs(cw - w) > 1e-9) continue;
        auto a = c["rgb8"].array;
        return [cast(int)a[0].integer, cast(int)a[1].integer,
                cast(int)a[2].integer];
    }
    throw new Exception(format(
        "no frozen cell for weight %.10g — this flow is driving a weight the "
        ~ "capture never measured, so there is nothing to assert against",
        w));
}

/// Does a probed pixel carry the measured colour for weight `w`?
///
/// EXACT, with ONE named exception. `w = 0` is the neutral, whose red and blue
/// products are exactly `0.5 * 255 = 127.5` — a tie, and GL 3.3 does not
/// specify which way an unorm8 conversion breaks one. Every other weight this
/// suite drives lands off a tie, and is asserted to the byte. The allowance is
/// keyed on the WEIGHT, not applied to every comparison, so it cannot quietly
/// cover a real one-level error somewhere else.
///
/// If a future flow needs a NEAR-tie weight (the two the fixture registers as
/// a divergence), it must inherit the unit test's named-instance rule and NOT
/// widen this.
bool matchesWeight(Px p, double w, out string why) {
    immutable int[3] want = fixtureRgb(w);
    immutable bool tie = (w == 0.0);
    immutable int[3] got = [p.r, p.g, p.b];
    static immutable string[3] chName = ["red", "green", "blue"];
    foreach (ch; 0 .. 3) {
        // Only red and blue are ties at w = 0; green there is 140.25, which is
        // not one, so it is asserted exactly even in the tie case.
        immutable int allow = (tie && ch != 1) ? 1 : 0;
        if (abs(got[ch] - want[ch]) > allow) {
            why = format("%s: measured %d, got %d (allowance %d) at (%d,%d)",
                         chName[ch], want[ch], got[ch], allow, p.x, p.y);
            return false;
        }
    }
    why = "";
    return true;
}

// --------------------------------------------------------------------------
// Rig
// --------------------------------------------------------------------------

/// The same camera `test_viewport_display.d` uses for its fill flows: the
/// stock cube framed with its SIDE faces dominant, so a lit control really
/// does vary across the samples.
enum double kAz = 0.6, kEl = 0.35, kDist = 6.0;

void setCamera(double azimuth = kAz) {
    httpPost("/api/camera", format(
        `{"azimuth":%.10f,"elevation":%.10f,"distance":%.10f}`,
        azimuth, kEl, kDist));
    settle();
}

void setStyle(string s) {
    postCommand("viewport.displayStyle", s);
    settle();
}

void selectMap(string name) {
    postCommandObj("mesh.weightmap.select", format(`{"name":%s}`,
                                                   JSONValue(name).toString()));
    settle();
}

/// Create `name` and set EVERY vertex of the current mesh to `w`.
///
/// Eight commands and eight undo entries for the stock cube: `mesh.weightmap.set`
/// takes ONE vertex, and each is a full mesh snapshot. That is the shipped
/// command surface, not an oversight of this rig.
void makeUniformMap(string name, double w) {
    postCommandObj("mesh.weightmap.create", format(`{"name":%s}`,
                                                   JSONValue(name).toString()));
    immutable size_t n = model()["vertices"].array.length;
    enforce(n > 0, "the mesh has no vertices — rig broken");
    foreach (v; 0 .. n)
        postCommandObj("mesh.weightmap.set",
            format(`{"name":%s,"vert":%d,"weight":%.10g}`,
                   JSONValue(name).toString(), v, w));
    settle();
}

/// Set every vertex of the CURRENT mesh (which may have grown) to `w`.
void setAllWeights(string name, double w) {
    immutable size_t n = model()["vertices"].array.length;
    foreach (v; 0 .. n)
        postCommandObj("mesh.weightmap.set",
            format(`{"name":%s,"vert":%d,"weight":%.10g}`,
                   JSONValue(name).toString(), v, w));
    settle();
}

/// The vertex of the current mesh nearest the camera eye.
///
/// A visible corner, by construction — which matters because an edit to a
/// vertex on the FAR side of a closed solid changes no visible pixel at all,
/// and a flow that used vertex 0 would be asserting against whichever side of
/// the cube index 0 happened to land on. (Measured: on the stock cube under
/// this camera, vertex 0 is a back corner and a -1.0 edit there moves nothing.)
int nearestVertexToEye() {
    auto cam = parseJSON(httpGet("/api/camera"));
    immutable double ex = jsonNum(cam, "eye", "x");
    immutable double ey = jsonNum(cam, "eye", "y");
    immutable double ez = jsonNum(cam, "eye", "z");
    auto vs = model()["vertices"].array;
    enforce(vs.length > 0, "the mesh has no vertices");
    int best = 0;
    double bestD = double.max;
    foreach (i, v; vs) {
        auto a = v.array;
        double num(JSONValue x) {
            switch (x.type) {
                case JSONType.float_:   return x.floating;
                case JSONType.integer:  return cast(double)x.integer;
                case JSONType.uinteger: return cast(double)x.uinteger;
                default: throw new Exception("vertex component is not a number");
            }
        }
        immutable double dx = num(a[0]) - ex, dy = num(a[1]) - ey,
                         dz = num(a[2]) - ez;
        immutable double d = dx*dx + dy*dy + dz*dz;
        if (d < bestD) { bestD = d; best = cast(int)i; }
    }
    return best;
}

/// Locate the model's face fill: the lattice samples that differ between a
/// shaded render and a lines-only one, eroded by a lattice step. Leaves the
/// style at `weight`.
size_t[] locateFill(int W, int H, out Px[] weightSamples,
                    size_t minSamples = 150) {
    immutable string pts = fillLattice(W, H);
    setStyle("shaded");    auto shaded = probe(0, pts).points;
    setStyle("wireframe"); auto wire   = probe(0, pts).points;
    setStyle("weight");    weightSamples = probe(0, pts).points;

    enforce(shaded.length == kFillNX * kFillNY
         && wire.length   == shaded.length
         && weightSamples.length == shaded.length,
        "the probe did not return the full lattice");

    auto isFill = new bool[](shaded.length);
    foreach (i; 0 .. shaded.length)
        isFill[i] = shaded[i].valid && wire[i].valid
                 && !samePixel(shaded[i], wire[i]);
    auto idx = erodedFillIndices(isFill);
    enforce(idx.length >= minSamples,
        format("only %d eroded face-fill samples (needed %d) — the model is "
               ~ "not framed where this suite expects it and no conclusion "
               ~ "below would mean anything", idx.length, minSamples));
    return idx;
}

/// A FOLLOW-UP probe of the same fill lattice, carrying `locateFill`'s length
/// check.
///
/// Every such probe is then indexed by an `idx` set that was chosen against
/// the FULL lattice, so a short return is an out-of-range read, and a raw
/// `probe(...).points` would surface it as a bare range error from inside a
/// `foreach` — with no mention of the probe, the lattice, or which flow was
/// running. This names it at the point where the length is still known.
Px[] probeFill(int W, int H) {
    auto pts = probe(0, fillLattice(W, H)).points;
    enforce(pts.length == kFillNX * kFillNY,
        format("the probe did not return the full lattice: %d points, not "
               ~ "%d — the sample indices below were chosen against the full "
               ~ "one and would read past the end",
               pts.length, kFillNX * kFillNY));
    return pts;
}

void restoreDefaults() {
    foreach (cell; 0 .. 4) {
        try {
            postCommandObj("viewport.displayStyle",
                format(`{"_positional":["shaded"],"viewport":%d}`, cell));
        } catch (Exception) { /* cell not in this layout */ }
    }
    try { postCommand("viewport.layout", "Single"); } catch (Exception) {}
    try { selectMap(""); } catch (Exception) {}
    settle();
}

// --------------------------------------------------------------------------
// Flow L0 — the lattice arithmetic every other flow rests on.
//
// `fillLattice` emits the sample list and `latticePoint` is its inverse; the
// ratio block in Flow G uses the inverse to put a contiguous window where the
// lattice found fill. Two copies of one origin computation, so they are
// compared — at the cell's REAL dimensions, which is the thing a hand-written
// case could not have picked.
// --------------------------------------------------------------------------

bool testFlowL0() {
    writeln("  [L0] The shared lattice and its inverse agree...");
    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    enforce(W > 64 && H > 64, "implausible cell size");

    import std.array : split;
    import std.string : strip;
    auto pts = fillLattice(W, H).split(";");
    size_t n = 0;
    foreach (p; pts) {
        if (p.strip.length == 0) continue;
        auto xy = p.split(",");
        immutable int px = xy[0].strip.to!int;
        immutable int py = xy[1].strip.to!int;
        immutable int[2] q = latticePoint(W, H, n);
        enforce(px == q[0] && py == q[1], format(
            "lattice index %d: fillLattice says (%d,%d), latticePoint says "
            ~ "(%d,%d) at %dx%d — the ratio block would sample somewhere "
            ~ "other than where the fill was located, and would still return "
            ~ "a plausible number", n, px, py, q[0], q[1], W, H));
        n++;
    }
    enforce(n == kFillNX * kFillNY,
        format("fillLattice emitted %d points, not %d", n, kFillNX * kFillNY));
    writefln("    L0 PASS: %d lattice points round-trip at %dx%d", n, W, H);
    return true;
}

// --------------------------------------------------------------------------
// Flow A — a uniform weight paints the measured colour, and is UNLIT.
//
// The uniformity arm is not decoration and it is not a second way of saying
// the same thing: a lit render of a cube CANNOT be uniform across its visible
// faces, because they have different normals. So "every eroded sample is the
// same colour" is the assertion that there is no light term, and the shaded
// control on the SAME samples is what proves the camera could have shown one.
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] A uniform weight paints the measured colour, unlit...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();
    makeUniformMap("wmA", 0.2);
    selectMap("wmA");

    immutable string pts = fillLattice(W, H);
    setStyle("shaded");    auto shaded = probe(0, pts).points;
    setStyle("wireframe"); auto wire   = probe(0, pts).points;
    setStyle("weight");    auto weight = probe(0, pts).points;

    auto isFill = new bool[](shaded.length);
    foreach (i; 0 .. shaded.length)
        isFill[i] = shaded[i].valid && wire[i].valid
                 && !samePixel(shaded[i], wire[i]);
    auto idx = erodedFillIndices(isFill);
    enforce(idx.length >= 150,
        format("only %d eroded face-fill samples located", idx.length));

    // A1 — the plan says what it is about to draw.
    auto c0 = displayDump()["cells"].array[0];
    enforce(c0["plan"]["active"]["shading"].str == "Weight",
        "the cell did not resolve to the weight shading arm");
    enforce(jsonBool(c0["plan"]["active"], "drawFaces"),
        "the weight style draws a filled surface");
    enforce(displayDump()["weightMap"].str == "wmA"
         && jsonBool(displayDump(), "weightMapResolved"),
        "the endpoint must report the selected map as resolved");
    writeln("    A1 PASS: plan = faces on, shading Weight, map wmA resolved");

    // A2 — the measured colour, exactly.
    size_t off = 0;
    string firstWhy;
    foreach (i; idx) {
        string why;
        if (!matchesWeight(weight[i], 0.2, why)) {
            if (off == 0) firstWhy = why;
            off++;
        }
    }
    immutable int[3] want = fixtureRgb(0.2);
    enforce(off == 0, format(
        "%d of %d fill samples are not the frozen colour for w = 0.2 "
        ~ "(%d,%d,%d). First: %s",
        off, idx.length, want[0], want[1], want[2], firstWhy));
    writefln("    A2 PASS: %d/%d samples at the frozen (%d,%d,%d)",
             idx.length, idx.length, want[0], want[1], want[2]);

    // A3 — UNLIT: uniform here, and the same samples DO vary when shaded.
    immutable int wSpread = channelSpread(weight, idx);
    immutable int sSpread = channelSpread(shaded, idx);
    enforce(wSpread == 0, format(
        "the weight surface varies by %d levels across the faces of a cube "
        ~ "whose every vertex carries the same weight — something is shading "
        ~ "it (the shaded control varies by %d over the same samples)",
        wSpread, sSpread));
    enforce(sSpread >= 20, format(
        "the SHADED control varies by only %d levels — under this camera "
        ~ "this flow cannot tell an unlit surface from a lit one, so A3's "
        ~ "pass would mean nothing", sSpread));
    writefln("    A3 PASS: weight spread 0, shaded control spread %d", sSpread);
    return true;
}

// --------------------------------------------------------------------------
// Flow A2 — editing a weight VALUE reaches the screen.
//
// This is the DisplayRefreshMask coupling, and it is the one thing in the
// feature that nothing else would notice breaking: `mesh.weightmap.set`
// publishes `MeshEditScope.Material`, and Material is in the mask ONLY because
// per-face material ids are baked into the VBO. Narrow the mask for that
// reason and the weight colours freeze — with the new value visible in
// /api/model and nowhere on screen.
// --------------------------------------------------------------------------

bool testFlowA2() {
    writeln("  [A2] A weight edit reaches the framebuffer...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();
    makeUniformMap("wmA", 0.2);
    selectMap("wmA");

    Px[] before;
    auto idx = locateFill(W, H, before);

    // ONE vertex to the opposite extreme, and specifically a VISIBLE one.
    // Not all of them: a whole-mesh rewrite would also pass if the pipeline
    // only ever rebuilt on a wholesale change, and one vertex is the smallest
    // edit the command can express. Not vertex 0 either — on a closed solid
    // half the vertices are on faces the camera cannot see, and index 0 is
    // one of them under this camera.
    immutable int vis = nearestVertexToEye();
    postCommandObj("mesh.weightmap.set",
        format(`{"name":"wmA","vert":%d,"weight":-1.0}`, vis));
    settle();
    auto after = probeFill(W, H);

    size_t moved = 0;
    foreach (i; idx) if (!samePixel(before[i], after[i])) moved++;
    enforce(moved > 0, format(
        "not one of %d fill samples changed after setting vertex %d — the "
        ~ "corner nearest the camera — from 0.2 to -1.0. The edit reached the "
        ~ "mesh (it is a Material-class change) but not the vertex colour "
        ~ "buffer: check that MeshEditScope.Material is still in "
        ~ "DisplayRefreshMask, which is the only thing that drives the "
        ~ "re-upload that invalidates the colours", idx.length, vis));
    writefln("    A2 PASS: %d/%d fill samples moved after editing vertex %d",
             moved, idx.length, vis);
    return true;
}

// --------------------------------------------------------------------------
// Flow B — the sign. A red/blue swap anywhere passes Flow A and fails here.
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] A negative weight is blue, not red...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();
    makeUniformMap("wmA", -0.5);
    selectMap("wmA");

    Px[] weight;
    auto idx = locateFill(W, H, weight);

    immutable int[3] want = fixtureRgb(-0.5);
    size_t off = 0; string firstWhy;
    foreach (i; idx) {
        string why;
        if (!matchesWeight(weight[i], -0.5, why)) { if (!off) firstWhy = why; off++; }
    }
    enforce(off == 0, format(
        "%d of %d samples are not the frozen colour for w = -0.5 (%d,%d,%d). "
        ~ "First: %s. Note the positive mirror is (%d,%d,%d) — if that is "
        ~ "what was drawn, the sign branch is inverted",
        off, idx.length, want[0], want[1], want[2], firstWhy,
        fixtureRgb(0.5)[0], fixtureRgb(0.5)[1], fixtureRgb(0.5)[2]));
    writefln("    B PASS: %d samples at the frozen (%d,%d,%d)",
             idx.length, want[0], want[1], want[2]);
    return true;
}

// --------------------------------------------------------------------------
// Flow C — the surface follows the map SELECTION, with no mesh edit between.
//
// SINGLE LAYOUT ONLY, deliberately. Under `--test` only the active cell is
// rendered at all, and the endpoint says so per cell (`renders`); a Quad run
// of this would probe a never-filled framebuffer and pass or fail for reasons
// that have nothing to do with the map.
// --------------------------------------------------------------------------

bool testFlowC() {
    writeln("  [C] The surface follows the map selection...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();
    makeUniformMap("wmA", 0.2);
    makeUniformMap("wmB", -0.5);

    selectMap("wmA");
    Px[] a;
    auto idx = locateFill(W, H, a);

    // No mesh command at all between these two probes — only the selection.
    selectMap("wmB");
    auto b = probeFill(W, H);

    size_t offA = 0, offB = 0;
    foreach (i; idx) {
        string why;
        if (!matchesWeight(a[i], 0.2,  why)) offA++;
        if (!matchesWeight(b[i], -0.5, why)) offB++;
    }
    enforce(offA == 0, format("%d/%d samples wrong under wmA", offA, idx.length));
    enforce(offB == 0, format(
        "%d of %d samples did not follow the selection to wmB — the surface "
        ~ "is still showing the first map. Either the stamp ignores the map "
        ~ "NAME (so the second upload was skipped as already-current) or the "
        ~ "render pass is not reading the current name", offB, idx.length));

    enforce(displayDump()["weightMap"].str == "wmB",
        "the endpoint must report the newly selected map");
    writefln("    C PASS: %d samples followed the selection wmA -> wmB",
             idx.length);
    return true;
}

// --------------------------------------------------------------------------
// Flow C2 — the STYLE is per cell; the map is not.
//
// A STATE assertion only, and that is the point: under `--test` only the
// active cell renders, so a pixel claim about cell 1 would be a claim about a
// framebuffer nothing filled. The endpoint reports `renders` per cell for
// exactly this reason and it is asserted here rather than assumed.
// --------------------------------------------------------------------------

bool testFlowC2() {
    writeln("  [C2] The style is per cell; the map is global...");
    resetApp();
    scope(exit) restoreDefaults();

    postCommand("viewport.layout", "Quad");
    settle();
    postCommandObj("viewport.displayStyle", `{"_positional":["weight"],"viewport":0}`);
    postCommandObj("viewport.displayStyle", `{"_positional":["shaded"],"viewport":1}`);
    settle();

    auto j = displayDump();
    enforce(cast(int)jsonNum(j, "cellCount") >= 2, "Quad layout did not take");
    auto cells = j["cells"].array;
    enforce(cells[0]["plan"]["active"]["shading"].str == "Weight",
        "cell 0 must resolve to the weight arm");
    enforce(cells[1]["plan"]["active"]["shading"].str == "Material",
        "cell 1 must be untouched by a write to cell 0");
    // The map name is NOT per cell — it is one field on the whole dump. That
    // is the shape being asserted, not an accident of where it was printed.
    enforce("weightMap" in j && "weightMap" !in cells[0].object,
        "the current map is session state and must be reported once for the "
        ~ "document, not per cell — a per-cell map is a state this mode does "
        ~ "not have");
    writeln("    C2 PASS: shading differs per cell, the map is reported once");
    return true;
}

// --------------------------------------------------------------------------
// Flow D — no map, and a DANGLING map, both render the neutral.
//
// The two states are identical on screen by design, so this flow needs the
// endpoint to tell them apart — otherwise "select a name that does not exist"
// would be indistinguishable from "the select command did nothing".
//
// And it asserts the neutral is not the CLEAR colour, because a flow that
// probed a frame in which nothing drew at all would otherwise pass.
// --------------------------------------------------------------------------

bool testFlowD() {
    writeln("  [D] No map and a dangling map both render the neutral...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();

    // --- nothing selected ---
    selectMap("");
    Px[] none;
    auto idx = locateFill(W, H, none);

    auto j = displayDump();
    enforce(j["weightMap"].str.length == 0
         && !jsonBool(j, "weightMapResolved"),
        "with nothing selected the endpoint must report an empty name and "
        ~ "no resolution");

    immutable int[3] neutral = fixtureRgb(0.0);
    size_t off = 0, clear = 0; string firstWhy;
    foreach (i; idx) {
        string why;
        if (!matchesWeight(none[i], 0.0, why)) { if (!off) firstWhy = why; off++; }
        if (isClear(none[i])) clear++;
    }
    enforce(off == 0, format(
        "%d of %d samples are not the frozen neutral (%d,%d,%d) with no map "
        ~ "selected. First: %s. Black here means the parked generic vertex "
        ~ "attribute is missing — GL's own default for a disabled attribute "
        ~ "array is (0,0,0,1)", off, idx.length,
        neutral[0], neutral[1], neutral[2], firstWhy));
    enforce(clear == 0, format(
        "%d of %d 'fill' samples equal the CLEAR colour (%d,%d,%d) — nothing "
        ~ "was drawn there, so this flow would be asserting the neutral "
        ~ "against an empty frame", clear, idx.length,
        kClearR, kClearG, kClearB));
    writefln("    D1 PASS: %d samples at the frozen neutral (%d,%d,%d), none "
             ~ "clear", idx.length, neutral[0], neutral[1], neutral[2]);

    // --- a name that does not resolve ---
    selectMap("no-such-map");
    auto dangling = probeFill(W, H);
    j = displayDump();
    enforce(j["weightMap"].str == "no-such-map",
        "the command must ACCEPT a name no map carries — resolution is lazy, "
        ~ "and refusing would make 'select then create' impossible");
    enforce(!jsonBool(j, "weightMapResolved"),
        "an absent map must report as unresolved — this field is the only "
        ~ "thing that separates it from 'nothing selected', which it renders "
        ~ "identically to");

    off = 0;
    foreach (i; idx) {
        string why;
        if (!matchesWeight(dangling[i], 0.0, why)) { if (!off) firstWhy = why; off++; }
    }
    enforce(off == 0, format(
        "%d of %d samples are not the neutral under a dangling map name. "
        ~ "First: %s", off, idx.length, firstWhy));
    writeln("    D2 PASS: a dangling name renders the neutral and reports "
            ~ "weightMapResolved:false");

    // --- and a map that exists again resolves, so D1/D2 are not vacuous ---
    makeUniformMap("wmA", 1.0);
    selectMap("wmA");
    enforce(jsonBool(displayDump(), "weightMapResolved"),
        "a map that DOES exist must report as resolved — without this arm, a "
        ~ "weightMapResolved hardwired to false would pass D1 and D2");
    writeln("    D3 PASS: a real map reports resolved (the control on D1/D2)");
    return true;
}

// --------------------------------------------------------------------------
// Flow E — a subpatch preview renders the neutral.
//
// NOT a scope note: under a preview the face VBO was built from the SUBDIVIDED
// mesh, so its per-corner source-vertex map holds PREVIEW indices — while the
// weight array being resolved belongs to the CAGE, because that is the mesh
// the pass draws and the mesh that carries the map. Indexing one by the other
// is an out-of-range read of a `float[]`, which in a release build is silent.
// --------------------------------------------------------------------------

bool testFlowE() {
    writeln("  [E] A subpatch preview renders the neutral, not garbage...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();
    makeUniformMap("wmA", 1.0);
    selectMap("wmA");

    // Sanity: the cage really is showing the weight colour first, so a neutral
    // reading after the toggle is the TOGGLE's doing.
    Px[] cage;
    auto idx = locateFill(W, H, cage);
    size_t off = 0;
    foreach (i; idx) { string why; if (!matchesWeight(cage[i], 1.0, why)) off++; }
    enforce(off == 0,
        "the cage must show the w = 1.0 colour before the preview is turned "
        ~ "on, or this flow cannot attribute what it sees afterwards");

    httpPost("/api/select", `{"mode":"polygons","indices":[0,1,2,3,4,5]}`);
    settle();
    postCommand("mesh.subpatch_toggle");
    // AND DROP THE SELECTION AGAIN before probing. The toggle needs a polygon
    // selection; the selection overlay then stipples a quarter of the surface
    // in its own colour, and over this lattice — whose step is even, so every
    // sample shares one x-parity — that reads as half the samples, not a
    // quarter. Leaving it selected made this flow fail on the OVERLAY while
    // reporting it as a weight-colour fault. The overlay is Flow G's subject.
    httpPost("/api/select", `{"mode":"polygons","indices":[]}`);
    settle();

    // RE-LOCATE the fill against the PREVIEW, rather than reusing the cage's
    // sample set. The subdivided surface has a different silhouette and the
    // wireframe overlay lands in different places, so cage samples that were
    // interior are not all interior now — and a sample that has drifted onto
    // a wire line is neither the neutral nor evidence of anything. The
    // shaded/lines-only difference locates the preview's own fill exactly the
    // way it located the cage's.
    // A LOWER FLOOR than the cage's 150, and it is measured, not slack: a
    // subdivided cube's limit surface is visibly smaller than its cage, so the
    // same lattice covers less of it — 112 eroded samples here against 322 on
    // the cage. Still two orders of magnitude more than one pixel, and the
    // assertion below is over every one of them.
    Px[] prevSamples;
    auto pidx = locateFill(W, H, prevSamples, 100);

    // Still the weight STYLE — the guard withholds colours, it does not
    // change the plan.
    enforce(displayDump()["cells"].array[0]["plan"]["active"]["shading"].str
                == "Weight",
        "the subpatch preview must not change which style the cell is in");
    enforce(model()["isSubpatch"].array.length > 0
         && model()["isSubpatch"].array[0].type == JSONType.TRUE,
        "the subpatch toggle did not take — this flow would then be "
        ~ "re-measuring the cage and passing for the wrong reason");

    size_t neutralCount = 0, other = 0;
    string firstWhy;
    immutable int[3] neutral = fixtureRgb(0.0);
    foreach (i; pidx) {
        string why;
        if (matchesWeight(prevSamples[i], 0.0, why)) neutralCount++;
        else { if (!other) firstWhy = why; other++; }
    }
    enforce(neutralCount + other >= 100, format(
        "only %d eroded preview samples — too few to conclude anything",
        neutralCount + other));
    enforce(other == 0, format(
        "%d of %d eroded preview samples are not the neutral (%d,%d,%d) — a "
        ~ "preview must upload no weight colours at all. First: %s. Anything "
        ~ "else means the cage's weight array is being indexed by PREVIEW "
        ~ "vertex indices, which is an out-of-range read",
        other, neutralCount + other, neutral[0], neutral[1], neutral[2],
        firstWhy));
    writefln("    E PASS: %d preview surface samples, all neutral", neutralCount);

    postCommand("mesh.subpatch_toggle");
    settle();
    return true;
}

// --------------------------------------------------------------------------
// Flow F — the colours survive a topology edit.
//
// The failure this exists for is invisible on a static mesh: `upload()`
// rebinds the face VAO and rewrites locations 0, 1 and 2, but never touches
// the weight colour attribute at location 3. Without an explicit invalidation
// that attribute stays enabled, pointing at a buffer sized for the PREVIOUS
// corner count — and the mesh here GROWS, so the stale buffer is too small.
// --------------------------------------------------------------------------

bool testFlowF() {
    writeln("  [F] The colours survive a topology edit...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();
    makeUniformMap("wmA", 1.0);
    selectMap("wmA");

    Px[] before;
    auto idx = locateFill(W, H, before);
    size_t off = 0;
    foreach (i; idx) { string why; if (!matchesWeight(before[i], 1.0, why)) off++; }
    enforce(off == 0, "the pre-edit surface must already be the w = 1.0 colour");

    // THE EDIT IS `poly_inset` AND NOT `subdivide`, and that is a measured
    // choice: `mesh.subdivide` builds a fresh mesh and does NOT carry the
    // mesh-map registry across, so the map is simply gone afterwards and this
    // flow would fail on a missing map rather than on the buffer it is about.
    // (Worth knowing on its own; it is filed as a gap, not worked around
    // here.) `mesh.poly_inset` keeps the registry and grows the corner count
    // about five-fold, which is the direction that turns a stale attribute
    // pointer into an out-of-range fetch.
    immutable size_t vBefore = model()["vertices"].array.length;
    httpPost("/api/select", `{"mode":"polygons","indices":[0,1,2,3,4,5]}`);
    settle();
    postCommand("mesh.poly_inset");
    settle();
    httpPost("/api/select", `{"mode":"polygons","indices":[]}`);
    settle();
    immutable size_t vAfter = model()["vertices"].array.length;
    enforce(vAfter > vBefore, format(
        "the topology edit added no vertices (%d -> %d) — the face buffer did "
        ~ "not grow and this flow would prove nothing", vBefore, vAfter));

    // The new vertices arrive at weight 0; set the whole (larger) map to 1.0
    // again so the expected surface is uniform, and so the colour buffer must
    // be rebuilt at the NEW corner count.
    setAllWeights("wmA", 1.0);

    Px[] after;
    auto idx2 = locateFill(W, H, after);
    off = 0; string firstWhy;
    foreach (i; idx2) {
        string why;
        if (!matchesWeight(after[i], 1.0, why)) { if (!off) firstWhy = why; off++; }
    }
    immutable int[3] want = fixtureRgb(1.0);
    enforce(off == 0, format(
        "%d of %d samples are not (%d,%d,%d) after the mesh grew from %d to "
        ~ "%d vertices. First: %s. A stale colour attribute — one that "
        ~ "survived the re-upload still bound to the old, smaller buffer — is "
        ~ "the failure this flow is for",
        off, idx2.length, want[0], want[1], want[2], vBefore, vAfter,
        firstWhy));
    writefln("    F PASS: %d samples still (%d,%d,%d) after %d -> %d vertices",
             idx2.length, want[0], want[1], want[2], vBefore, vAfter);
    return true;
}

// --------------------------------------------------------------------------
// Flow G — the overlays survive the style.
//
// THE LATTICE CANNOT ASSERT THE RATIO, and that is worth stating because it
// looks as though it could. Its step is 6 — even — so every lattice sample
// shares one x-parity; the selection stipple discards on `x % 2 == 0`, so over
// the lattice the coverage reads as 0 % or 50 % depending on the cell width,
// deterministically, and never as the 25 % it actually is. A "50 %" that moves
// with the window size would look like a real measurement.
//
// So the lattice keeps its real job — LOCATING the fill — and the ratio is
// asserted over a contiguous stride-1 block placed at one of its samples. The
// pattern has period 4 in x and 2 in y, so an 8x4 block covers exactly two
// periods in each direction and 8/32 is exact for ANY origin.
// --------------------------------------------------------------------------

bool testFlowG() {
    writeln("  [G] Selection and hover survive the weight style...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();
    makeUniformMap("wmA", 1.0);
    selectMap("wmA");

    Px[] weight;
    auto idx = locateFill(W, H, weight);

    // Find a lattice sample whose 8x4 neighbourhood is ENTIRELY the weight
    // colour with nothing selected. That block is the positive control: it
    // proves the window is pure surface — no wire, no vertex dot, no
    // silhouette — before any ratio is counted over it.
    immutable int[3] wantW = fixtureRgb(1.0);
    string blockPts;
    int bx, by;
    bool found = false;
    foreach (k; idx) {
        immutable int[2] p = latticePoint(W, H, k);
        immutable int ox = p[0] - 4, oy = p[1] - 2;
        if (ox < 0 || oy < 0 || ox + 8 > W || oy + 4 > H) continue;
        string pts;
        foreach (j; 0 .. 4) foreach (i; 0 .. 8)
            pts ~= format("%d,%d;", ox + i, oy + j);
        auto blk = probe(0, pts).points;
        bool allWeight = blk.length == 32;
        foreach (px; blk) {
            string why;
            if (!px.valid || !matchesWeight(px, 1.0, why)) { allWeight = false; break; }
        }
        if (allWeight) { blockPts = pts; bx = ox; by = oy; found = true; break; }
    }
    enforce(found, format(
        "no 8x4 block of pure weight colour (%d,%d,%d) found at any of the %d "
        ~ "eroded fill samples — without that positive control the counts "
        ~ "below would be counting wireframe and silhouette pixels",
        wantW[0], wantW[1], wantW[2], idx.length));
    writefln("    G1 PASS: an 8x4 all-weight block at (%d,%d)", bx, by);

    // --- selection: exactly a quarter of the block, ONE colour where it covers ---
    httpPost("/api/select", `{"mode":"polygons","indices":[0,1,2,3,4,5]}`);
    settle();

    // THE PREMISE THE OVERLAY ASSERTIONS BELOW REST ON (task 1862), asserted
    // here rather than assumed from "the fixture is a cube".
    //
    // Since 1862 the selected-face fill is TWO passes — a depth-tested visible
    // one at full strength and an occluded one at 0.30 (`OccludedPass`,
    // `source/mesh_gpu.d`). Both stipple the SAME screen-space lattice, so at
    // every covered pixel of this block the visible pass writes the selection
    // colour and the occluded pass (the cube's far faces, selected and behind
    // the near one) blends that same colour OVER ITSELF: 0.30*sel + 0.70*sel
    // == sel. What this block reads is therefore the selection colour at FULL
    // STRENGTH, and it is one colour — by that identity, not because the
    // overlay is opaque wherever it draws. It is not, any more.
    //
    // The identity needs EVERY face selected on a CLOSED solid. Under a
    // partial selection the occluded half can land on pixels the visible half
    // never painted, and the overlay reads 0.30 of the selection colour over
    // the weight colour instead.
    //
    // AND NOTHING BELOW WOULD CATCH THAT — measured, not supposed. Re-running
    // this flow with `indices":[0,1,2]` and these two enforces neutralised
    // leaves Flow G fully GREEN: the count assertion still splits 8/32, and
    // the one-colour assertion still passes because a uniformly blended
    // overlay is also a single colour. The colour ITSELF is a registered
    // divergence and is deliberately not asserted, so the blend has nowhere to
    // surface. That is what makes this premise load-bearing rather than
    // decorative, and why it is a check and not a comment.
    {
        auto mdl = model();
        immutable size_t nFaces  = mdl["faces"].array.length;
        immutable size_t nSelFac = selection()["selectedFaces"].array.length;
        enforce(nFaces > 0 && nSelFac == nFaces, format(
            "Flow G needs EVERY face selected — %d of %d are. The overlay "
            ~ "readings below are the selection colour at full strength only "
            ~ "while the occluded half of the fill blends it over itself; "
            ~ "under a partial selection it blends over the weight colour and "
            ~ "the block goes uniformly dimmer — which every assertion below "
            ~ "absorbs silently", nSelFac, nFaces));
        immutable size_t openEdges = openEdgeCount(mdl);
        enforce(openEdges == 0, format(
            "Flow G needs a CLOSED solid — %d of the fixture's edges do not "
            ~ "border exactly two faces. On an open mesh a covered pixel can "
            ~ "have an occluded selected face behind it with no selected "
            ~ "surface in front, which dims the overlay the same way",
            openEdges));
    }

    auto sel = probe(0, blockPts).points;
    enforce(sel.length == 32, "the probe did not return the whole block");

    size_t nSelColour = 0, nWeightColour = 0, nOther = 0;
    foreach (px; sel) {
        string why;
        if (matchesWeight(px, 1.0, why)) { nWeightColour++; continue; }
        // Anything that is not the weight colour must be ONE other colour —
        // under this fixture, for the reason the premise block above pins.
        // Which colour is a registered divergence (ours is not the
        // reference's), so it is not asserted — but that it is a single
        // colour, and covers exactly a quarter, is the measured SHAPE.
        nSelColour++;
    }
    // Every non-weight pixel must be the SAME colour.
    //
    // NOT because the overlay never blends — since 1862 the occluded pass DOES
    // blend, and it contributes at every one of these pixels (the cube's far
    // faces are selected and occluded). One colour survives because that blend
    // is the selection colour over the selection colour, an identity the
    // premise block above pins by asserting its two fixture properties. What
    // is left for this block to catch is a stipple that blends against
    // something ELSE at only SOME pixels — a lattice that drifted between the
    // two passes, so the occluded half lands partly on weight-coloured pixels
    // the visible half did not cover.
    Px firstSel;
    bool haveFirst = false;
    foreach (px; sel) {
        string why;
        if (matchesWeight(px, 1.0, why)) continue;
        if (!haveFirst) { firstSel = px; haveFirst = true; continue; }
        if (!samePixel(firstSel, px)) nOther++;
    }
    enforce(nOther == 0, format(
        "%d of the %d overlay pixels differ from each other — the fill must "
        ~ "contribute exactly ONE colour over this block. Its visible pass "
        ~ "paints the selection colour opaque and its occluded pass re-blends "
        ~ "the SAME colour over it at 0.30, which is the identity (the premise "
        ~ "block above pins the fixture properties that make it so). More than "
        ~ "one colour means the two passes stopped covering the same pixels — "
        ~ "it does NOT mean the overlay stopped being opaque",
        nOther, nSelColour));
    enforce(nSelColour == 8 && nWeightColour == 24, format(
        "the selection overlay covers %d of 32 block pixels and leaves %d at "
        ~ "the weight colour; the measured shape is exactly 8 and 24 (a 25 %% "
        ~ "diagonal stipple over an 8x4 window, which is two full periods in "
        ~ "each direction). 32/0 means the overlay went opaque over the whole "
        ~ "face; 16/16 means the coverage doubled",
        nSelColour, nWeightColour));

    // --- and it is DIAGONAL, not merely 25 % dense ---
    //
    // THE COUNT ALONE IS NOT ENOUGH, and this is measured rather than
    // supposed: changing the stipple's period from 2 to 4 rearranges the
    // pattern into vertical pairs and leaves the count at exactly 8/32, so the
    // assertion above passes on it unchanged. What the capture measured is a
    // 25 % DIAGONAL, so the diagonality is asserted too — structurally, and
    // without re-deriving the shader's predicate here (which would be checking
    // our code against a copy of itself):
    //
    //   * coverage lives in alternate COLUMNS — four of the eight carry it
    //     and four carry none;
    //   * each covered column carries exactly two of the four rows;
    //   * and consecutive covered columns carry DIFFERENT rows. That last
    //     clause is the diagonal. Vertical pairs share their rows and fail it.
    {
        bool[4][8] covered;
        foreach (n, px; sel) {
            string why;
            immutable size_t i = n % 8, j = n / 8;
            covered[i][j] = !matchesWeight(px, 1.0, why);
        }
        size_t[] coveredCols;
        foreach (i; 0 .. 8) {
            size_t c = 0;
            foreach (j; 0 .. 4) if (covered[i][j]) c++;
            enforce(c == 0 || c == 2, format(
                "block column %d carries %d covered pixels; a 25 %% stipple "
                ~ "over four rows carries either none or exactly two", i, c));
            if (c == 2) coveredCols ~= i;
        }
        enforce(coveredCols.length == 4, format(
            "%d of 8 block columns carry coverage; the measured stipple "
            ~ "covers alternate columns, so it must be four",
            coveredCols.length));
        foreach (k; 1 .. coveredCols.length)
            enforce(coveredCols[k] == coveredCols[k - 1] + 2, format(
                "covered columns %d and %d are not adjacent-alternate — the "
                ~ "stipple is not on every other column",
                coveredCols[k - 1], coveredCols[k]));
        foreach (k; 1 .. coveredCols.length) {
            bool same = true;
            foreach (j; 0 .. 4)
                if (covered[coveredCols[k]][j] != covered[coveredCols[k - 1]][j])
                    { same = false; break; }
            enforce(!same, format(
                "covered columns %d and %d cover the SAME rows — the pattern "
                ~ "is vertical pairs, not a diagonal. The count is still 8/32 "
                ~ "either way, which is why this clause exists",
                coveredCols[k - 1], coveredCols[k]));
        }
    }
    writefln("    G2 PASS: selection covers exactly 8/32 on a diagonal, "
             ~ "weight keeps 24/32");

    // --- hover: the override colour must still reach the weight arm ---
    //
    // Mechanism divergence, registered: ours tints the WHOLE hovered face
    // where the reference stipples it. So what is asserted here is that the
    // hover override reaches this style AT ALL — i.e. that the weight branch
    // kept its `u_overrideMix` mix, which `display_state.d`'s standing
    // invariant requires of every surface style.
    auto cam = parseJSON(httpGet("/api/camera"));
    immutable int vpX = cast(int)jsonNum(cam, "vpX");
    immutable int vpY = cast(int)jsonNum(cam, "vpY");
    immutable int cw  = cast(int)jsonNum(cam, "width");
    immutable int ch  = cast(int)jsonNum(cam, "height");
    immutable int hx  = vpX + bx + 4, hy = vpY + by + 2;
    string log =
        format(`{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,"fovY":0.785398}` ~ "\n",
               vpX, vpY, cw, ch)
      ~ format(`{"t":1.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
               hx, hy);
    // The endpoint takes the RAW JSON-lines log as the body, not a wrapper.
    {
        auto resp = httpPost("/api/play-events", log);
        auto pj = parseJSON(resp);
        enforce(pj["status"].str == "success",
                "play-events failed: " ~ resp);
        bool done = false;
        foreach (i; 0 .. 200) {
            auto st = parseJSON(httpGet("/api/play-events/status"));
            if (st["finished"].type == JSONType.TRUE) { done = true; break; }
            Thread.sleep(50.msecs);
        }
        enforce(done, "play-events did not finish within 10s");
    }
    settle();

    auto hov = probe(0, blockPts).points;
    size_t stillWeight = 0;
    foreach (px; hov) { string why; if (matchesWeight(px, 1.0, why)) stillWeight++; }
    enforce(stillWeight < 24, format(
        "%d of 32 block pixels still carry the plain weight colour after "
        ~ "hovering the face under them — the hover override did not reach "
        ~ "the weight shading arm. That arm must keep the u_overrideMix mix: "
        ~ "selection and rollover are their own display axes and have to "
        ~ "survive every surface style", stillWeight));
    writefln("    G3 PASS: hover reaches the weight arm (%d/32 pixels left at "
             ~ "the plain colour)", stillWeight);
    return true;
}

// --------------------------------------------------------------------------
// Flow H — the clamp is on the BLEND FACTOR, not on the output.
//
// `w = 2.0` reproducing `w = 1.0` proves little on its own: an implementation
// that extrapolated the colour past the extreme and let the framebuffer clip
// would give the same answer, because the extreme happens to be a corner of
// the unit cube. `w = 1.5` is the discriminator only in combination with the
// SIGN mirror — so both are driven, and the negative side too, where the
// clipped and clamped answers also coincide but the CHANNELS differ.
// --------------------------------------------------------------------------

bool testFlowH() {
    writeln("  [H] The clamp holds past the extremes...");
    resetApp();
    scope(exit) restoreDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    setCamera();
    makeUniformMap("wmA", 1.0);
    selectMap("wmA");

    Px[] at1;
    auto idx = locateFill(W, H, at1);

    void checkAt(double w, double sameAs) {
        setAllWeights("wmA", w);
        auto img = probeFill(W, H);
        size_t off = 0; string firstWhy;
        foreach (i; idx) {
            string why;
            if (!matchesWeight(img[i], sameAs, why)) { if (!off) firstWhy = why; off++; }
        }
        immutable int[3] want = fixtureRgb(sameAs);
        enforce(off == 0, format(
            "w = %.10g must render exactly what w = %.10g does (%d,%d,%d); "
            ~ "%d of %d samples differ. First: %s",
            w, sameAs, want[0], want[1], want[2], off, idx.length, firstWhy));
    }

    checkAt(1.5,  1.0);
    checkAt(2.0,  1.0);
    checkAt(-1.0, -1.0);
    checkAt(-1.5, -1.0);
    checkAt(-2.0, -1.0);
    writefln("    H PASS: 1.5 and 2.0 equal 1.0, -1.5 and -2.0 equal -1.0, "
             ~ "over %d samples each", idx.length);
    return true;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------

int main(string[] args) {
    // NOTE: keep the literal "http://localhost:8080" — run_test.d isolates
    // parallel workers by textually rewriting "localhost:8080" to the worker's
    // port in a scratch copy of the source.
    baseUrl = "http://localhost:8080";

    writeln("=== test_weightmap_display ===");
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

    run(&testFlowL0, "Flow L0 — the shared lattice and its inverse agree");
    run(&testFlowA,  "Flow A — a uniform weight paints the measured colour, unlit");
    run(&testFlowA2, "Flow A2 — a weight edit reaches the framebuffer");
    run(&testFlowB,  "Flow B — a negative weight is blue");
    run(&testFlowC,  "Flow C — the surface follows the map selection");
    run(&testFlowC2, "Flow C2 — the style is per cell, the map is global");
    run(&testFlowD,  "Flow D — no map and a dangling map render the neutral");
    run(&testFlowE,  "Flow E — a subpatch preview renders the neutral");
    run(&testFlowF,  "Flow F — the colours survive a topology edit");
    run(&testFlowG,  "Flow G — selection and hover survive the weight style");
    run(&testFlowH,  "Flow H — the clamp holds past the extremes");

    // Belt-and-suspenders: the runner shares one app across a worker's whole
    // slice and its between-tests reset covers neither the viewport display
    // state, nor the layout, nor the session's current weight map. Every flow
    // restores in a scope(exit); this catches a flow that died somewhere that
    // skipped even that.
    restoreDefaults();
    try { httpPost("/api/reset", "{}"); } catch (Exception) {}

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
