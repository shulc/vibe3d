// test_viewport_display.d — task 0559 Phase 1: the drawing oracle.
//
// Phase 1 of the viewport display-modes feature adds no user-visible
// behaviour at all. What it adds is the ability to OBSERVE what the renderer
// decided to draw — which the codebase had no way to do before, and without
// which every later phase would be verified by looking at it.
//
// Two tiers are exercised here, and it is worth being clear about how much
// each is worth:
//
//   * PLAN assertions (/api/viewport/display) are real, because the endpoint
//     dumps the very struct the render pass consumes and the cell's dirty key
//     is stamped from. There is no second derivation that could drift.
//   * PIXEL probes (/api/viewport/probe) are the only tier that proves GL
//     actually did something. They are also the flakier one: the lane runs
//     software GL, so every assertion here is CATEGORICAL ("equals the clear
//     colour", "does not equal the clear colour", "changed") and never a
//     shading value.
//
// Flow A — the endpoints exist and the shipped default resolves to today's
//          exact behaviour.
// Flow B — the payload carries the ACTIVITY AXIS (active + backdrop), and the
//          two sides resolve independently.
// Flow C — the probe reads real pixels from the cell's framebuffer.
// Flow D — the plan and the pixels agree: the passes the plan describes are
//          the passes that ran.
// Flow E — the "--test renders only the active cell" trap is REPORTED by the
//          endpoints rather than left as a comment for a test to trip over.
module test_viewport_display;

import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.conv      : to;
import std.format    : format;
import std.math      : abs;
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

void postCommand(string cmd, string params = "") {
    JSONValue j;
    j["id"] = cmd;
    if (params.length) j["params"] = params;
    string resp = httpPost("/api/command", j.toString);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " failed: " ~ resp);
}

// The probe reads the last COMPLETED frame (the HTTP bridge is serviced
// before the scene render), so anything that changes the scene needs a frame
// to land before it is visible to a probe.
void resetApp() {
    httpPost("/api/reset", "{}");
    Thread.sleep(400.msecs);
}

bool jsonBool(JSONValue j, string[] path...) {
    JSONValue cur = j;
    foreach (k; path) cur = cur[k];
    enforce(cur.type == JSONType.TRUE || cur.type == JSONType.FALSE,
            "expected a bool at ." ~ path[$ - 1] ~ ", got " ~ cur.toString);
    return cur.type == JSONType.TRUE;
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

JSONValue displayDump() { return parseJSON(httpGet("/api/viewport/display")); }

struct Px { int x, y, r, g, b, a; bool valid; }

// The hardcoded scene clear colour. A pixel equal to it means NOTHING was
// drawn there — that is the categorical fact every probe assertion is built
// on. Tolerance is for byte rounding across drivers, not for shading.
enum int kClearR = 92, kClearG = 102, kClearB = 107;

bool isClear(Px p) {
    return abs(p.r - kClearR) <= 2 && abs(p.g - kClearG) <= 2
        && abs(p.b - kClearB) <= 2;
}

struct ProbeResult {
    int  w, h;
    bool renders;
    Px[] points;
    string hash;
}

ProbeResult probe(int cell, string points, bool wantHash = false) {
    string q = format("/api/viewport/probe?cell=%d", cell);
    if (points.length) q ~= "&points=" ~ points;
    if (wantHash)      q ~= "&hash=1";
    auto j = parseJSON(httpGet(q));
    enforce("error" !in j || j["points"].array.length > 0,
            "probe failed: " ~ j.toString);
    ProbeResult r;
    r.w       = cast(int)jsonNum(j, "w");
    r.h       = cast(int)jsonNum(j, "h");
    r.renders = jsonBool(j, "renders");
    if ("hash" in j) r.hash = j["hash"].str;
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

// --------------------------------------------------------------------------
// Flow A — the shipped default resolves to today's exact behaviour.
//
// This is the assertion that makes "Phase 1 changed nothing visible" a
// checkable claim about the model rather than a promise. If a default ever
// drifts — a style, an overlay mode, an opacity, the backdrop dim — this
// fails, and it fails naming the field.
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] Default display state + resolved plan...");
    resetApp();

    auto j = displayDump();
    enforce("cells" in j, "/api/viewport/display has no \"cells\": " ~ j.toString);
    enforce(j["cells"].array.length >= 1, "no viewport cells reported");
    auto c0 = j["cells"].array[0];

    // --- the STATE (what the user would set) ---
    enforce(c0["state"]["active"]["style"].str == "Shaded",
        "default surface style must be Shaded, got "
        ~ c0["state"]["active"]["style"].str);
    enforce(c0["state"]["active"]["wire"].str == "Uniform",
        "default wireframe overlay must be Uniform, got "
        ~ c0["state"]["active"]["wire"].str);
    enforce(jsonNum(c0, "state", "active", "wireAlpha") == 1.0,
        "default overlay opacity must be 1.0 (today's fully opaque lines)");
    enforce(c0["state"]["backdropStyle"].str == "SameAsActive",
        "default backdrop must be SameAsActive, got "
        ~ c0["state"]["backdropStyle"].str);
    writeln("    A1 PASS: state = Shaded / Uniform / alpha 1.0 / SameAsActive");

    // --- the resolved PLAN (what the renderer consumes) ---
    auto pa = c0["plan"]["active"];
    enforce(jsonBool(pa, "drawFaces"), "default plan must draw faces");
    enforce(jsonBool(pa, "facesLit"),  "default plan must light faces");
    enforce(jsonBool(pa, "drawWire"),  "default plan must draw the wireframe overlay");
    enforce(jsonNum(pa, "wireAlpha") == 1.0, "default overlay must be opaque");
    enforce(!jsonBool(pa, "drawVerts"),
        "default plan must NOT force vertex dots on — that is a lines-only "
        ~ "style's behaviour and would change every viewport");
    enforce(jsonNum(pa, "dim") == 1.0, "the active pass must not be dimmed");
    writeln("    A2 PASS: plan = faces+lit+wire, alpha 1.0, no forced verts, dim 1.0");

    // wireColor is CARRIED but not yet consumed by any pass (it is the
    // per-item overlay colour a later phase needs). Assert only that the
    // schema carries it — never infer rendering from it, or the assertion
    // passes forever.
    enforce("wireColor" in pa && pa["wireColor"].array.length == 3,
        "plan must carry a 3-component overlay colour");
    writeln("    A3 PASS: wireColor carried in the schema (not consumed yet)");

    return true;
}

// --------------------------------------------------------------------------
// Flow B — the ACTIVITY AXIS is in the model from the first commit.
//
// The reference carries a full parallel control set for background layers,
// with a foreground/background definition identical to our own document
// predicates. Modelling it later would mean touching the struct, the dirty
// key, the prefs schema, the command set, the endpoint payload and every test
// that asserts a plan — so it is modelled now, and this flow is what stops it
// being quietly dropped back to one control set.
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] Activity axis carried in state and plan...");
    resetApp();

    auto c0 = displayDump()["cells"].array[0];

    // Both activity states carry the FULL control set, not a scalar.
    foreach (side; ["active", "backdrop"]) {
        auto s = c0["state"][side];
        foreach (field; ["style", "wire", "wireAlpha"])
            enforce(field in s,
                format("state.%s is missing \"%s\" — the backdrop must be a "
                       ~ "full control set, not a dimming factor", side, field));
    }
    writeln("    B1 PASS: state.active and state.backdrop both carry style/wire/wireAlpha");

    // Both sides are RESOLVED, separately.
    enforce("active" in c0["plan"] && "backdrop" in c0["plan"],
        "plan must be resolved for both activity states");
    auto pa = c0["plan"]["active"];
    auto pb = c0["plan"]["backdrop"];
    foreach (field; ["drawFaces", "facesLit", "drawWire", "wireAlpha",
                     "wireColor", "drawVerts", "dim"])
        enforce(field in pb,
            format("plan.backdrop is missing \"%s\" — it must be the same "
                   ~ "DrawPlan shape as the active side", field));
    writeln("    B2 PASS: plan.backdrop is a full DrawPlan, same shape as active");

    // And they are genuinely resolved apart: today the only difference is our
    // dim factor, and that difference is exactly what proves the backdrop is
    // not a copy of the active plan.
    enforce(jsonNum(pb, "dim") != jsonNum(pa, "dim"),
        "backdrop and active plans must not share a dim — the backdrop side "
        ~ "is resolved separately");
    enforce(abs(jsonNum(pb, "dim") - 0.45) < 1e-6,
        format("backdrop dim must be the dim factor background layers have "
               ~ "always drawn with, got %.6f", jsonNum(pb, "dim")));
    writeln("    B3 PASS: backdrop resolves separately (dim 0.45 vs active 1.0)");

    return true;
}

// --------------------------------------------------------------------------
// Flow C — the probe reads real pixels.
//
// Everything above is CPU-side data. This is the only tier that proves the GL
// side exists at all, so it is worth pinning that the probe is reading a real
// framebuffer and not returning a constant.
// --------------------------------------------------------------------------

bool testFlowC() {
    writeln("  [C] Pixel probe reads the cell framebuffer...");
    resetApp();

    auto r = probe(0, "", true);
    enforce(r.w > 0 && r.h > 0, "probe reports an empty framebuffer");
    enforce(r.renders, "cell 0 is the active cell and must be rendering");
    enforce(r.hash.length == 16, "whole-buffer digest missing or malformed");
    writefln("    C1 PASS: cell 0 fbo %dx%d, digest %s", r.w, r.h, r.hash);

    // The digest is deterministic for an unchanged scene...
    auto r2 = probe(0, "", true);
    enforce(r.hash == r2.hash,
        "the digest must be stable for an unchanged scene — got "
        ~ r.hash ~ " then " ~ r2.hash);
    writeln("    C2 PASS: digest stable across repeats");

    // ...and it is NOT a constant: moving the camera must change it. Without
    // this, a probe that silently returned zeros would pass C2 forever.
    httpPost("/api/camera", `{"azimuth":0.9,"elevation":0.4,"distance":7.5}`);
    Thread.sleep(400.msecs);
    auto r3 = probe(0, "", true);
    enforce(r3.hash != r.hash,
        "the digest must change when the scene changes — the probe is "
        ~ "returning a constant, not reading the framebuffer");
    writeln("    C3 PASS: digest tracks a camera change");

    // Coordinates are FBO pixels with a TOP-LEFT origin, and out-of-range
    // points are reported rather than silently clamped or dropped.
    auto rr = probe(0, format("%d,%d", r.w + 50, r.h + 50));
    enforce(rr.points.length == 1 && !rr.points[0].valid,
        "a point outside the cell must come back flagged, not silently "
        ~ "clamped to an edge pixel");
    writeln("    C4 PASS: out-of-range point reported, not clamped");

    return true;
}

// --------------------------------------------------------------------------
// Flow D — the plan and the pixels agree.
//
// This is the joint that matters. The plan says a face pass runs; the pixels
// have to show a face pass ran. If a later phase makes the plan describe
// something the renderer ignores — "resolved but not consumed", the named
// failure mode of this design — this is what catches it.
//
// NOTE on why this samples a REGION and not the centre pixel. The obvious
// version of D1 probes the middle of the viewport and asserts it is not the
// clear colour. That version PASSES with the face pass deleted: the ground
// grid's origin axis line runs straight through the screen centre, and with
// no faces to hide behind it, the centre pixel is the axis, not background.
// Found by mutation, not by reasoning. Sampling a region and requiring that
// nearly all of it is covered cannot be satisfied by a one-pixel-wide line.
// --------------------------------------------------------------------------

bool testFlowD() {
    writeln("  [D] Plan and pixels agree about which passes ran...");
    resetApp();

    auto c0 = displayDump()["cells"].array[0];
    enforce(jsonBool(c0["plan"]["active"], "drawFaces"),
        "precondition: the default plan draws faces");

    auto r = probe(0, "", true);

    // A 6x6 lattice well inside the default cube's screen footprint, in
    // fractions of the framebuffer so it survives a different viewport size.
    string pts;
    enum int kN = 6;
    foreach (iy; 0 .. kN) {
        foreach (ix; 0 .. kN) {
            immutable int px = cast(int)(r.w * (0.42 + 0.16 * ix / (kN - 1.0)));
            immutable int py = cast(int)(r.h * (0.43 + 0.17 * iy / (kN - 1.0)));
            if (pts.length) pts ~= ";";
            pts ~= format("%d,%d", px, py);
        }
    }
    auto region = probe(0, pts);
    enforce(region.points.length == kN * kN, "region probe returned the wrong count");

    int covered = 0;
    foreach (p; region.points) {
        enforce(p.valid, format("region probe point (%d,%d) failed", p.x, p.y));
        if (!isClear(p)) covered++;
    }
    enforce(covered >= kN * kN - 3,
        format("the plan says drawFaces=true, so the model's interior must be "
               ~ "covered — only %d of %d sampled points are non-background. "
               ~ "Either the face pass was dropped or the plan is not being "
               ~ "consumed. (A one-pixel line such as the grid's origin axis "
               ~ "cannot cover a lattice, which is why this samples a region.)",
               covered, kN * kN));
    writefln("    D1 PASS: face pass ran — %d/%d interior samples covered, "
             ~ "e.g. (%d,%d) = (%d,%d,%d)",
             covered, kN * kN, region.points[0].x, region.points[0].y,
             region.points[0].r, region.points[0].g, region.points[0].b);

    // The complementary half: a corner well outside the model IS the clear
    // colour. Without this, "not clear" above could be satisfied by a probe
    // that returned garbage for every point.
    auto corner = probe(0, "4,4").points[0];
    enforce(corner.valid, "corner probe failed");
    enforce(isClear(corner),
        format("a pixel outside the model must be the clear colour, got "
               ~ "(%d,%d,%d) — the probe is not reading what it claims to",
               corner.r, corner.g, corner.b));
    writefln("    D2 PASS: empty region = clear colour (%d,%d,%d)",
             corner.r, corner.g, corner.b);

    return true;
}

// --------------------------------------------------------------------------
// Flow E — the single-rendered-cell trap is reported, not hidden.
//
// Under --test only the ACTIVE cell is rendered each frame. A multi-cell
// pixel assertion written naively passes by reading a framebuffer that was
// never filled. Rather than leave that as a comment for a future test to trip
// over, both endpoints report a per-cell `renders` flag — so a test can
// assert on it, and this flow pins that the flag tells the truth.
// --------------------------------------------------------------------------

bool testFlowE() {
    writeln("  [E] Per-cell `renders` flag reports the --test limitation...");
    resetApp();
    postCommand("viewport.layout", "Quad");
    Thread.sleep(400.msecs);

    auto j = displayDump();
    enforce(cast(int)jsonNum(j, "cellCount") == 4,
        "Quad layout must report four cells");
    immutable int activeId = cast(int)jsonNum(j, "activeId");

    foreach (i, cell; j["cells"].array) {
        immutable int id = cast(int)jsonNum(cell, "id");
        enforce(id == cast(int)i, "cells must be reported in index order");
        immutable bool renders = jsonBool(cell, "renders");
        enforce(renders == (id == activeId),
            format("cell %d reports renders=%s but only the active cell (%d) "
                   ~ "is rendered under --test; a pixel assertion aimed at a "
                   ~ "non-rendered cell would pass for the wrong reason",
                   id, renders, activeId));
    }
    writefln("    E1 PASS: only cell %d reports renders=true, cells 0-3 all listed",
             activeId);

    // The probe agrees with the dump — a probe aimed at a cell that is not
    // being rendered says so, in the response, where a test can see it.
    immutable int other = (activeId == 0) ? 3 : 0;
    auto r = probe(other, "");
    enforce(!r.renders,
        format("probing non-active cell %d must report renders=false", other));
    writefln("    E2 PASS: probe of non-active cell %d reports renders=false", other);

    // Every cell still gets a full, independently resolved plan — a cell that
    // is not rendered is not a cell without state.
    foreach (cell; j["cells"].array) {
        enforce("active" in cell["plan"] && "backdrop" in cell["plan"],
            "every cell must carry both resolved plans, rendered or not");
        enforce("backdropStyle" in cell["state"],
            "every cell must carry the full display state");
    }
    writeln("    E3 PASS: all four cells carry state + both resolved plans");

    postCommand("viewport.layout", "Single");
    Thread.sleep(200.msecs);
    return true;
}

// --------------------------------------------------------------------------
// Flow F — the BACKDROP plan is consumed, not just resolved.
//
// The riskiest single edit in this phase: background layers used to be dimmed
// by a constant declared inside the render function, and that constant is now
// an output of plan resolution. "Resolved but not consumed" would leave the
// endpoint reporting a backdrop dim that no pixel obeys — which is exactly the
// failure mode this whole design exists to make impossible, so it gets a test
// that reads the dim off the endpoint and then checks the framebuffer for it.
// --------------------------------------------------------------------------

bool testFlowF() {
    writeln("  [F] Backdrop plan reaches the pixels...");
    resetApp();

    auto r = probe(0, "", false);
    // A short lattice inside the model, same construction as Flow D.
    string pts;
    enum int kN = 4;
    foreach (iy; 0 .. kN) {
        foreach (ix; 0 .. kN) {
            immutable int px = cast(int)(r.w * (0.44 + 0.12 * ix / (kN - 1.0)));
            immutable int py = cast(int)(r.h * (0.45 + 0.13 * iy / (kN - 1.0)));
            if (pts.length) pts ~= ";";
            pts ~= format("%d,%d", px, py);
        }
    }

    auto fg = probe(0, pts);
    foreach (p; fg.points)
        enforce(p.valid && !isClear(p),
            "precondition: the model must cover the sampled region while it "
            ~ "is the foreground layer");

    // Add an empty layer: it becomes primary, so the cube demotes to a
    // background layer and now draws through the BACKDROP plan.
    postCommand("layer.add");
    Thread.sleep(500.msecs);

    auto dump = displayDump()["cells"].array[0];
    immutable double planDim = jsonNum(dump, "plan", "backdrop", "dim");
    enforce(planDim < 1.0,
        "precondition: the backdrop plan must report a dim below 1.0");

    auto bg = probe(0, pts);
    int compared = 0;
    double worst = 0;
    foreach (i, p; bg.points) {
        enforce(p.valid, "backdrop probe point failed");
        enforce(!isClear(p),
            format("the backdrop plan says drawFaces=true, so the background "
                   ~ "layer must still be drawn — (%d,%d) is background colour",
                   p.x, p.y));
        // Compare only samples bright enough for the ratio to mean something.
        if (fg.points[i].r < 40) continue;
        immutable double ratio = cast(double)p.r / cast(double)fg.points[i].r;
        immutable double err   = abs(ratio - planDim);
        if (err > worst) worst = err;
        enforce(err < 0.05,
            format("the endpoint reports a backdrop dim of %.3f but the "
                   ~ "pixels at (%d,%d) went %d -> %d, a ratio of %.3f. The "
                   ~ "backdrop plan is resolved but not consumed.",
                   planDim, p.x, p.y, fg.points[i].r, p.r, ratio));
        compared++;
    }
    enforce(compared >= kN * kN / 2, "too few comparable samples");
    writefln("    F1 PASS: %d samples dim to the plan's %.3f (worst error %.4f)",
             compared, planDim, worst);

    return true;
}

// ==========================================================================
// Phase 2/3 — the state becomes settable, the overlay axis becomes real, and
// the lines-only surface style becomes reachable.
// ==========================================================================

// --------------------------------------------------------------------------
// Restoring shared state — READ THIS BEFORE ADDING A FLOW BELOW.
//
// The runner reuses ONE `vibe3d --test` per worker across that worker's whole
// slice of test binaries, and its between-tests reset covers the document,
// the event player, the active tool and the undo stack — NOT the viewport's
// display state and NOT the cell layout. Neither is document state, so
// /api/reset does not touch them either.
//
// So every flow from here down mutates state that would otherwise still be
// set when an unrelated test binary starts. A lines-only viewport left behind
// would be invisible here and would surface as an inexplicable failure
// somewhere else in the slice. Each mutating flow therefore restores in a
// `scope(exit)`, not at the end of its body: the runner catches a failing
// flow's exception and keeps going, so a mid-flow failure must still put the
// viewport back.
// --------------------------------------------------------------------------

void restoreDisplayDefaults() {
    foreach (cell; 0 .. 4) {
        // Addressed per cell, and tolerant of the layout: cells the current
        // layout does not show reject the write, which is fine — this is a
        // best-effort restore, and a cell that cannot be addressed cannot
        // have been changed either.
        try {
            postCommandRaw("viewport.displayStyle",
                format(`{"_positional":["shaded"],"viewport":%d}`, cell));
            postCommandRaw("viewport.wireOverlay",
                format(`{"_positional":["uniform"],"viewport":%d}`, cell));
            postCommandRaw("viewport.wireAlpha",
                format(`{"_positional":[1.0],"viewport":%d}`, cell));
        } catch (Exception) { /* cell not in this layout */ }
    }
    try { postCommand("viewport.layout", "Single"); } catch (Exception) {}
    Thread.sleep(250.msecs);
}

// POST a command in ARGSTRING form ("id arg arg ..."). The endpoint routes a
// body that does not start with '{' through its argstring parser, which is
// what fills `_positional` — the JSON form with a bare string `params` does
// NOT, so the selection commands below have to use this one.
void postArgstring(string line) {
    auto r = parseJSON(httpPost("/api/command", line));
    enforce("status" !in r || r["status"].str != "error",
            "argstring command `" ~ line ~ "` failed: " ~ r.toString);
}

// POST a command whose `params` is a JSON OBJECT rather than a bare string —
// needed for the cell selector, which no other viewport command has.
void postCommandRaw(string cmd, string paramsJson) {
    string body_ = `{"id":"` ~ cmd ~ `","params":` ~ paramsJson ~ `}`;
    string resp = httpPost("/api/command", body_);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " " ~ paramsJson ~ " failed: " ~ resp);
}

/// POST a command and REQUIRE it to be refused, returning the message.
string postCommandExpectingRefusal(string cmd, string paramsJson) {
    string body_ = `{"id":"` ~ cmd ~ `","params":` ~ paramsJson ~ `}`;
    auto r = parseJSON(httpPost("/api/command", body_));
    enforce("status" in r && r["status"].str == "error",
        "expected " ~ cmd ~ " " ~ paramsJson ~ " to be REFUSED, but it "
        ~ "succeeded — a command that accepts a value the renderer does not "
        ~ "draw is a silent lie, and a test written against it passes forever");
    return ("message" in r) ? r["message"].str : "";
}

string bufferHash(int cell = 0) {
    Thread.sleep(500.msecs);          // let the change land in a completed frame
    auto j = parseJSON(httpGet(format("/api/viewport/probe?cell=%d&hash=1", cell)));
    enforce("hash" in j, "probe did not return a buffer digest: " ~ j.toString);
    return j["hash"].str;
}

// Pixel-classification helpers. CATEGORICAL only — never a shading value.
/// Two probe samples that are the same pixel, to within byte rounding.
/// Software GL is deterministic here, so this is an equality test with a
/// driver-rounding allowance and NOT a similarity threshold.
bool samePixel(Px a, Px b) {
    return abs(a.r - b.r) <= 2 && abs(a.g - b.g) <= 2 && abs(a.b - b.b) <= 2;
}

bool isSurfaceGrey(Px p) {
    // Lit cube surface: near-neutral, and not the background.
    return abs(p.r - p.g) <= 8 && abs(p.g - p.b) <= 12 && !isClear(p);
}
bool isSaturated(Px p) {
    // A coloured line (the world axes). Nothing on the lit cube, and nothing
    // in the background, comes close to this much channel spread.
    int mx = p.r; if (p.g > mx) mx = p.g; if (p.b > mx) mx = p.b;
    int mn = p.r; if (p.g < mn) mn = p.g; if (p.b < mn) mn = p.b;
    return mx - mn > 30;
}

// --------------------------------------------------------------------------
// Flow G — the lines-only surface style.
//
// Two separate claims, and they need different sampling, which is the whole
// lesson of this flow:
//
//   * "faces are off" is an AREA claim, and an area grid answers it with an
//     enormous margin.
//   * "you can see THROUGH the model" is a claim about a 1-pixel line, and a
//     grid is the wrong instrument for it — during development a grid whose
//     x-stride happened to land on odd columns found zero line pixels in an
//     image that was full of them. Lines are sampled with FULL-DENSITY
//     scanlines laid ACROSS them: the world axis renders as a near-horizontal
//     line, so vertical scanlines cross it, and every column crosses it
//     exactly once. That is a construction that cannot miss, not a stride
//     that happened to work.
//
// The see-through claim is also made self-locating: the evidence is found in
// the lines-only image (saturated axis pixels) and then checked against the
// shaded one (the same pixels were opaque surface). So the test does not need
// to know where anything is on screen.
// --------------------------------------------------------------------------

bool testFlowG() {
    writeln("  [G] Lines-only style: faces off, and the model is see-through...");
    resetApp();
    scope(exit) restoreDisplayDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    enforce(W > 64 && H > 64, "implausible cell size");

    // Vertical scanlines (cross the near-horizontal axis line) + an area grid.
    string pts;
    int[] colXs;
    foreach (i; 0 .. 11) {
        immutable int x = cast(int)(W * (0.30 + 0.04 * i));
        colXs ~= x;
        for (int y = cast(int)(H * 0.24); y < cast(int)(H * 0.76); y++)
            pts ~= format("%d,%d;", x, y);
    }
    size_t areaStart;
    {
        // Remember where the area samples begin so the two claims stay separate.
        areaStart = 0;
        foreach (ch; pts) if (ch == ';') areaStart++;
    }
    for (int y = cast(int)(H * 0.30); y < cast(int)(H * 0.64); y += 4)
        for (int x = cast(int)(W * 0.26); x < cast(int)(W * 0.76); x += 4)
            pts ~= format("%d,%d;", x, y);

    postCommand("viewport.displayStyle", "shaded");
    Thread.sleep(400.msecs);
    auto shaded = probe(0, pts);
    postCommand("viewport.displayStyle", "wireframe");
    Thread.sleep(400.msecs);
    auto wire = probe(0, pts);
    enforce(shaded.points.length == wire.points.length,
            "probe returned a different number of points for the two styles");

    // --- the PLAN, first: what the renderer was told to do ---
    auto pa = displayDump()["cells"].array[0]["plan"]["active"];
    enforce(!jsonBool(pa, "drawFaces"),
        "the lines-only style must draw NO faces — not even a depth-only pass, "
        ~ "or the model stops being see-through");
    enforce(jsonBool(pa, "drawWire"), "the lines-only style must draw lines");
    enforce(jsonBool(pa, "drawVerts"),
        "the lines-only style draws vertices as well as the edges between them");
    writeln("    G1 PASS: plan = no faces, lines on, vertex dots forced on");

    // --- claim 1 (AREA): the solid surface is gone ---
    //
    // "GONE" MEANS *CHANGED*, NOT "BECAME THE CLEAR COLOUR", and the
    // difference is not pedantry — the original oracle was
    // `isClear(wire.points[i])`, which silently assumed that the only thing
    // behind the model was the background. That was true while the ground
    // grid was a fixed 1-unit world lattice (the stock cube spanned two
    // cells, so almost nothing was behind it). Task 0570 made the grid a
    // SCREEN length — about forty lines across the pane at any zoom — so a
    // real fraction of these samples now show a grid line through the
    // model instead of the background, and the old oracle scored that as
    // "the face pass is still writing colour" (77% against a 90% floor).
    //
    // A grid line reads as `isSurfaceGrey` too (it is a neutral grey blended
    // over a neutral background), so tightening the classifier does not help
    // and would only move the confound.
    //
    // The claim this flow actually makes is that the FACE PASS STOPPED
    // WRITING THESE PIXELS. If it had not, each sample would be byte-identical
    // between the two styles — faces are drawn last over the grid and are
    // opaque. So "differs from the shaded image" is exactly the claim, and it
    // is independent of whatever is behind. Note this is the SAME phenomenon
    // G3 below asserts on purpose: geometry behind the model becoming
    // visible is the feature, and the grid is geometry behind the model.
    size_t surf = 0, surfGone = 0, surfToBackground = 0;
    foreach (i; areaStart .. shaded.points.length) {
        if (!shaded.points[i].valid || !wire.points[i].valid) continue;
        if (!isSurfaceGrey(shaded.points[i])) continue;
        surf++;
        if (!samePixel(shaded.points[i], wire.points[i])) surfGone++;
        if (isClear(wire.points[i])) surfToBackground++;
    }
    enforce(surf >= 200, format("too few surface samples to conclude anything (%d)", surf));
    immutable double gone = cast(double)surfGone / cast(double)surf;
    enforce(gone >= 0.90,
        format("only %.1f%% of the %d lit-surface samples changed at all in "
               ~ "the lines-only style — the face pass is still writing colour "
               ~ "(an unchanged pixel is the signature: faces draw last and "
               ~ "opaque, so a drawn face reproduces the shaded image exactly)",
               gone * 100, surf));
    writefln("    G2 PASS: %d/%d (%.1f%%) lit-surface samples stopped showing "
             ~ "the surface (%d of them are bare background; the rest are "
             ~ "grid/axis lines that were behind the model)",
             surfGone, surf, gone * 100, surfToBackground);

    // --- claim 2 (LINES): geometry BEHIND the model became visible ---
    // The world axis is drawn before the mesh and is depth-occluded by the
    // faces. With no faces it shows through. This is the difference between
    // line soup and hidden-line removal, and it is the one property most
    // likely to be "improved" away later.
    // NOTE the conjunction, and why there is no precondition about the shaded
    // image as a whole: a sample only counts when it was OPAQUE LIT SURFACE
    // when shaded and is a COLOURED LINE when lines-only. A pixel that was lit
    // surface cannot itself have been the axis, so the pairing alone proves
    // the axis was behind the model and became visible. An earlier revision
    // also demanded that NO sample anywhere on these scanlines be coloured in
    // the shaded image; that is a claim about where the model happens to sit
    // on screen, not about this feature, and it broke the moment a preceding
    // flow left the camera somewhere else.
    int revealed = 0, saturatedWhenShaded = 0;
    foreach (i; 0 .. areaStart) {
        if (!shaded.points[i].valid || !wire.points[i].valid) continue;
        if (isSaturated(shaded.points[i])) saturatedWhenShaded++;
        if (isSaturated(wire.points[i]) && isSurfaceGrey(shaded.points[i]))
            revealed++;
    }
    enforce(revealed >= 4,
        format("only %d sample(s) went from opaque surface to a coloured line "
               ~ "behind the model. The lines-only style must be see-through — "
               ~ "if this dropped to zero, something turned it into hidden-line "
               ~ "removal, or added a depth-only face pass", revealed));
    writefln("    G3 PASS: %d samples show geometry BEHIND the model, opaque "
             ~ "surface when shaded (%d columns sampled, %d already-coloured "
             ~ "samples ignored)",
             revealed, cast(int)colXs.length, saturatedWhenShaded);

    // --- lines are actually still drawn (an empty viewport would pass G2) ---
    int linePx = 0;
    foreach (i; 0 .. areaStart)
        if (wire.points[i].valid && !isClear(wire.points[i])) linePx++;
    enforce(linePx > 0,
        "the lines-only style drew nothing at all over the scanlines — G2 "
        ~ "alone is also satisfied by an empty viewport, which is why this "
        ~ "assertion exists");
    writefln("    G4 PASS: %d non-background samples remain (the lines)", linePx);

    return true;
}

// --------------------------------------------------------------------------
// Flow H — the overlay axis, and the wrong implementation of it.
//
// Deliberately hash-based rather than pixel-counted. The overlay is a
// 1-pixel-wide feature and the sampling problem in Flow G applies here with
// no convenient scanline geometry to exploit; a whole-buffer digest answers
// "did this reach the framebuffer at all" exactly, with no stride to get
// wrong. The digest was verified bit-stable across repeated reads.
//
// The load-bearing assertion is H3. Switching the overlay off must NOT take
// selection feedback with it — selection highlight is its own display axis.
// The obvious implementation (gate the edge draw, or early-return from it)
// passes every other assertion in this file and fails only this one.
// --------------------------------------------------------------------------

bool testFlowH() {
    writeln("  [H] Overlay axis on/off, and selection surviving it...");
    resetApp();
    scope(exit) { postArgstring("select.element edge set");
                  restoreDisplayDefaults(); }

    postArgstring("select.typeFrom edge");
    postArgstring("select.element edge set 0 1 2 3 4 5 6 7");

    postCommand("viewport.wireOverlay", "uniform");
    immutable string hUniformSel = bufferHash();
    postCommand("viewport.wireOverlay", "none");
    immutable string hNoneSel    = bufferHash();

    auto pa = displayDump()["cells"].array[0]["plan"]["active"];
    enforce(!jsonBool(pa, "drawWire"), "overlay None must resolve drawWire=false");
    writeln("    H1 PASS: overlay None resolves to drawWire=false");

    enforce(hUniformSel != hNoneSel,
        "switching the wireframe overlay off changed no pixels at all — it is "
        ~ "resolved but not consumed");
    writeln("    H2 PASS: the overlay axis reaches the framebuffer");

    // THE assertion. Same overlay setting (off), selection dropped: if the
    // framebuffer is unchanged, the selection was never being drawn once the
    // overlay went off.
    postArgstring("select.element edge set");
    immutable string hNoneNoSel = bufferHash();
    enforce(hNoneSel != hNoneNoSel,
        "with the overlay switched OFF, selecting edges changed nothing on "
        ~ "screen. Selection highlight is a separate display axis and must "
        ~ "survive the overlay being off — this is what a blanket gate on the "
        ~ "edge draw looks like from the outside");
    writeln("    H3 PASS: selection feedback still draws with the overlay off");

    // And the forcing relation: a lines-only surface with the overlay off is
    // not an empty viewport.
    postCommand("viewport.displayStyle", "wireframe");
    Thread.sleep(300.msecs);
    auto pw = displayDump()["cells"].array[0]["plan"]["active"];
    enforce(jsonBool(pw, "drawWire"),
        "a lines-only surface style with the overlay set to None must still "
        ~ "force lines on, or the viewport is empty");
    writeln("    H4 PASS: lines-only + overlay None still forces lines on");

    return true;
}

// --------------------------------------------------------------------------
// Flow I — overlay opacity reaches the pixels.
//
// wireAlpha was resolved and dumped by the display endpoint from the first
// commit of this feature, and consumed by nothing. That is precisely the
// shape of assertion that passes forever while the feature does not work, so
// it gets a directional pixel check on top of the digest.
// --------------------------------------------------------------------------

bool testFlowI() {
    writeln("  [I] Overlay opacity reaches the pixels...");
    resetApp();
    scope(exit) restoreDisplayDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    string pts;
    foreach (i; 0 .. 11) {
        immutable int x = cast(int)(W * (0.30 + 0.04 * i));
        for (int y = cast(int)(H * 0.24); y < cast(int)(H * 0.76); y++)
            pts ~= format("%d,%d;", x, y);
    }
    foreach (i; 0 .. 11) {
        immutable int y = cast(int)(H * (0.30 + 0.035 * i));
        for (int x = cast(int)(W * 0.22); x < cast(int)(W * 0.80); x++)
            pts ~= format("%d,%d;", x, y);
    }

    postCommand("viewport.displayStyle", "shaded");
    postCommand("viewport.wireOverlay", "uniform");
    postCommand("viewport.wireAlpha", "1.0");
    Thread.sleep(400.msecs);
    auto opaque = probe(0, pts);

    // The measurement set is defined BY the opaque image — the pixels the
    // base line pass actually covers — so the test never needs to know where
    // an edge is.
    size_t[] linePx;
    foreach (i, p; opaque.points) {
        if (!p.valid) continue;
        immutable int mn = (p.r < p.g ? (p.r < p.b ? p.r : p.b) : (p.g < p.b ? p.g : p.b));
        if (mn >= 200) linePx ~= i;
    }
    enforce(linePx.length >= 20,
        format("only %d fully-lit line samples found; too few to measure "
               ~ "opacity against", linePx.length));

    double meanRedAt(string alpha) {
        postCommand("viewport.wireAlpha", alpha);
        Thread.sleep(400.msecs);
        auto s = probe(0, pts);
        double acc = 0;
        foreach (i; linePx) acc += s.points[i].r;
        return acc / cast(double)linePx.length;
    }

    immutable double m10 = meanRedAt("1.0");
    immutable double m05 = meanRedAt("0.5");
    immutable double m00 = meanRedAt("0.0");

    // Directional and categorical: lines get closer to what is behind them as
    // opacity falls. No shading value is asserted.
    enforce(m10 > m05 + 12.0 && m05 > m00 + 12.0,
        format("overlay opacity did not reach the pixels: means were "
               ~ "%.1f (opaque) / %.1f (half) / %.1f (clear) over %d line "
               ~ "samples — expected a strict, substantial decrease",
               m10, m05, m00, linePx.length));
    writefln("    I1 PASS: %d line samples fade %.1f -> %.1f -> %.1f as "
             ~ "opacity drops 1.0 -> 0.5 -> 0.0", linePx.length, m10, m05, m00);

    enforce(jsonNum(displayDump()["cells"].array[0], "plan", "active", "wireAlpha") == 0.0,
        "the plan must report the opacity that was set");
    writeln("    I2 PASS: the dumped plan agrees with what was set");

    return true;
}

// --------------------------------------------------------------------------
// Flow J — a display change reaches EXACTLY ONE cell.
//
// Every other term of a cell's dirty key is shared: the render loop stamps
// the same value into all four cells. Display style is the first genuinely
// per-cell render input, and an implementation that stamped it from a frame
// value instead of from the cell would look completely correct in the
// single-cell layout everything else is tested in.
//
// This is a STATE assertion on purpose. Under --test only the active cell is
// rendered, so a pixel assertion aimed at cell 2 would pass against an FBO
// that was never drawn (Flow E pins that limitation).
// --------------------------------------------------------------------------

bool testFlowJ() {
    writeln("  [J] A per-cell display change reaches exactly one cell...");
    resetApp();
    scope(exit) restoreDisplayDefaults();

    postCommand("viewport.layout", "Quad");
    Thread.sleep(400.msecs);
    enforce(cast(int)jsonNum(displayDump(), "cellCount") == 4,
        "precondition: Quad must report four cells");

    postCommandRaw("viewport.displayStyle",
        `{"_positional":["wireframe"],"viewport":2}`);
    postCommandRaw("viewport.wireAlpha", `{"_positional":[0.25],"viewport":2}`);
    Thread.sleep(300.msecs);

    auto cells = displayDump()["cells"].array;
    foreach (i, c; cells) {
        immutable bool isTarget = (i == 2);
        immutable string style  = c["state"]["active"]["style"].str;
        immutable double alpha  = jsonNum(c, "state", "active", "wireAlpha");
        enforce(style == (isTarget ? "Wireframe" : "Shaded"),
            format("cell %d style is %s; a display write addressed at cell 2 "
                   ~ "must reach cell 2 and no other — if every cell changed, "
                   ~ "the state is not per-cell", i, style));
        enforce(abs(alpha - (isTarget ? 0.25 : 1.0)) < 1e-4,
            format("cell %d opacity is %.3f, expected %.2f", i, alpha,
                   isTarget ? 0.25 : 1.0));
        // The resolved plan has to follow the state, per cell.
        enforce(jsonBool(c, "plan", "active", "drawFaces") == !isTarget,
            format("cell %d: the resolved plan does not follow that cell's "
                   ~ "own state", i));
    }
    writeln("    J1 PASS: cell 2 changed, cells 0/1/3 untouched, plans follow");

    // Addressing a cell the layout does not have must FAIL rather than
    // silently land on the active cell — a test that quietly retargeted would
    // assert nothing.
    postCommand("viewport.layout", "Single");
    Thread.sleep(300.msecs);
    auto msg = postCommandExpectingRefusal("viewport.displayStyle",
        `{"_positional":["wireframe"],"viewport":3}`);
    enforce(msg.length > 0, "the refusal must carry a message");
    writefln("    J2 PASS: out-of-layout cell refused — %s", msg);

    return true;
}

// --------------------------------------------------------------------------
// Flow K — the commands refuse what no pass can draw.
//
// The display enums are declared wider than the renderer honours, so the
// value space is right from the start. That is only safe if the unreachable
// values are genuinely unreachable: a command that accepts one and then
// renders something else is a lie that no assertion in this file could catch,
// because the endpoint would faithfully report the state it was given.
// --------------------------------------------------------------------------

bool testFlowK() {
    writeln("  [K] Values no pass draws are refused, not silently accepted...");
    resetApp();
    scope(exit) restoreDisplayDefaults();

    postCommandExpectingRefusal("viewport.displayStyle", `"solid"`);
    postCommandExpectingRefusal("viewport.wireOverlay",  `"colored"`);
    writeln("    K1 PASS: the unlit style and the per-item overlay colour are refused");

    postCommandExpectingRefusal("viewport.displayStyle", `"gouraud"`);
    postCommandExpectingRefusal("viewport.wireOverlay",  `"dotted"`);
    writeln("    K2 PASS: unknown names are refused");

    postCommandExpectingRefusal("viewport.wireAlpha", `1.7`);
    postCommandExpectingRefusal("viewport.wireAlpha", `-0.5`);
    postCommandExpectingRefusal("viewport.wireAlpha", `"opaque"`);
    writeln("    K3 PASS: opacity outside 0..1, and non-numeric opacity, are refused");

    // A refusal must leave the viewport exactly as it was.
    auto after = displayDump()["cells"].array[0];
    enforce(after["state"]["active"]["style"].str == "Shaded"
         && after["state"]["active"]["wire"].str == "Uniform"
         && jsonNum(after, "state", "active", "wireAlpha") == 1.0,
        "a refused command must not partially apply: " ~ after["state"].toString);
    writeln("    K4 PASS: refusals leave the display state untouched");

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

    writeln("=== test_viewport_display ===");
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

    run(&testFlowA, "Flow A — default state + resolved plan is today's behaviour");
    run(&testFlowB, "Flow B — activity axis carried in state and plan");
    run(&testFlowC, "Flow C — pixel probe reads the cell framebuffer");
    run(&testFlowD, "Flow D — plan and pixels agree about which passes ran");
    run(&testFlowE, "Flow E — per-cell renders flag reports the --test limit");
    run(&testFlowF, "Flow F — backdrop plan reaches the pixels");
    run(&testFlowG, "Flow G — lines-only style: faces off, model see-through");
    run(&testFlowH, "Flow H — overlay axis on/off, selection surviving None");
    run(&testFlowI, "Flow I — overlay opacity reaches the pixels");
    run(&testFlowJ, "Flow J — a display change reaches exactly one cell");
    run(&testFlowK, "Flow K — undrawable values are refused");

    // Belt-and-suspenders: the runner shares one app across a worker's whole
    // slice and its between-tests reset does not cover viewport display state
    // or layout. Every mutating flow restores in a scope(exit); this catches
    // the case where a flow died somewhere that skipped even that.
    restoreDisplayDefaults();

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
