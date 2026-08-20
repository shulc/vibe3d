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
// Flow E — the `--test` render set is REPORTED by the endpoints rather than
//          left as a comment for a test to trip over. (Task 1650 widened that
//          set to every cell of a multi-cell layout; see the flow's own
//          comment for why the old rule made the multi-cell overlay replica
//          untestable.)
//
// Task 0589 adds the third surface style:
// Flow L — Solid draws a fill and does NOT shade it: uniform across faces, at
//          the material's own colour, and distinct from BOTH neighbours on the
//          axis (Shaded varies; Wireframe has no fill).
// Flow M — the law behind Flow L, stated as an invariance: turn the view a
//          quarter turn about the world up axis and a Solid render must not
//          move a single pixel, while the same turn moves a shaded one.
module test_viewport_display;

import std.stdio     : writeln, writefln;
import std.net.curl  : HTTP;
import std.json      : parseJSON, JSONValue, JSONType;
import std.exception : enforce;
import std.conv      : to;
import std.format    : format;
import std.math      : abs;
import std.algorithm : maxElement;
import core.thread   : Thread;
import core.time     : msecs;

// Task 1090: the sampling lattice, shared with tests/test_weightmap_display.d
// so the two suites cannot disagree about which pixels they read.
import viewport_lattice_helpers : kFillNX, kFillNY, kFillStride,
                                  fillLattice, latticePoint,
                                  sharedErodedFillIndices = erodedFillIndices;

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
// Flow E — the render set is reported, not hidden.
//
// A pixel assertion aimed at a cell that was never rendered passes by reading
// a framebuffer nobody filled. Rather than leave that as a comment for a
// future test to trip over, both endpoints report a per-cell `renders` flag —
// so a test can assert on it, and this flow pins that the flag tells the truth.
//
// TASK 1650 CHANGED THE RULE THIS FLOW PINS. `--test` used to render the
// ACTIVE cell and nothing else; it now renders every cell of a MULTI-cell
// layout as well (`viewport.testRendersCell`). The old rule made the
// `OverlayMode.Visual` replica path structurally unreachable from the test
// lane — under `--test` the overlay owner is always the active cell, so the
// only cell that rendered was the only cell that did not draw a replica, and
// an assertion about the replica could not come out differently whatever the
// code did. A SINGLE-cell layout still renders exactly one cell, which is
// every live cell there, so nothing that never touches `viewport.layout`
// changed. What this flow asserts is unchanged in KIND: the flag agrees with
// the loop.
// --------------------------------------------------------------------------

bool testFlowE() {
    writeln("  [E] Per-cell `renders` flag agrees with the --test render set...");
    resetApp();

    // Single layout first: one cell, and it renders. This is the arm that
    // would catch "renders was hard-wired to true" — without it, the Quad
    // assertions below are satisfied by a constant.
    auto s = displayDump();
    enforce(cast(int)jsonNum(s, "cellCount") == 1,
        "precondition: --test starts in the Single layout");
    enforce(jsonBool(s["cells"].array[0], "renders"),
        "the single cell must be rendered");

    postCommand("viewport.layout", "Quad");
    Thread.sleep(400.msecs);

    auto j = displayDump();
    enforce(cast(int)jsonNum(j, "cellCount") == 4,
        "Quad layout must report four cells");
    immutable int activeId = cast(int)jsonNum(j, "activeId");

    foreach (i, cell; j["cells"].array) {
        immutable int id = cast(int)jsonNum(cell, "id");
        enforce(id == cast(int)i, "cells must be reported in index order");
        enforce(jsonBool(cell, "renders"),
            format("cell %d reports renders=false in a Quad layout. Since task "
                   ~ "1650 every cell of a multi-cell layout is rendered under "
                   ~ "--test; a cell that is not leaves its framebuffer unfilled "
                   ~ "and makes any pixel assertion on it pass for the wrong "
                   ~ "reason — and it puts the OverlayMode.Visual replica path "
                   ~ "back out of the test lane's reach", id));
    }
    writefln("    E1 PASS: all four cells report renders=true (active is %d)",
             activeId);

    // The probe agrees with the dump — one predicate, two endpoints.
    immutable int other = (activeId == 0) ? 3 : 0;
    auto r = probe(other, "");
    enforce(r.renders,
        format("the dump says cell %d renders but the probe says it does not — "
               ~ "the two endpoints must read the same predicate", other));
    writefln("    E2 PASS: probe of non-active cell %d agrees: renders=true", other);

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

// --------------------------------------------------------------------------
// Locating the model's FILL without knowing where the model is (task 0589).
//
// Flows L and M both need the set of samples that a FACE covered, and they
// must not need to know where the cube is on screen or how big it is — Flow G
// records what happened the last time a flow assumed that.
//
// The construction: faces are drawn LAST and OPAQUE, so a pixel a face covered
// is a pixel that DIFFERS between the shaded image and the lines-only image,
// and a pixel a face did not cover is byte-identical between them. That single
// criterion is self-locating and it does something else worth having for free:
//
//   * wireframe-overlay lines are EXCLUDED automatically, because the overlay
//     draws in both styles at the same place in the same colour, so those
//     pixels are identical and never enter the set;
//   * grid and background pixels outside the model are excluded for the same
//     reason;
//   * so the set is exactly "face fill", which is the thing under test.
//
// Then an EROSION on the lattice (keep a sample only if its four lattice
// neighbours are also fill) puts every surviving sample at least one stride
// away from a silhouette. That is what makes Flow M's zero-tolerance claim
// safe: the two camera positions it compares are congruent only to float
// precision, so the silhouette may land a hair differently, and no assertion
// should depend on which side of a boundary a rounding went.
// --------------------------------------------------------------------------

// TASK 1090 MOVED THE LATTICE ITSELF into `tests/viewport_lattice_helpers.d`,
// imported at the top of this file, because a second suite needs to sample the
// same pixels and a copy is how the two would drift. `kFillNX`, `kFillNY`,
// `kFillStride`, `fillLattice` and the erosion now live there unchanged; what
// stays here is the part that is about THIS file's pixel type.

/// Indices into a `fillLattice` probe that a face covered, eroded by one
/// lattice step. `shaded` and `wire` are probes of the SAME lattice in the
/// shaded and lines-only styles.
///
/// The fill CRITERION is local (it needs `Px` and `samePixel`); the erosion
/// and the grid are shared. Same behaviour as before the extraction — this is
/// the same body with its middle third called instead of inlined.
size_t[] erodedFillIndices(in Px[] shaded, in Px[] wire) {
    enforce(shaded.length == kFillNX * kFillNY && wire.length == shaded.length,
        format("the probe returned %d/%d points for a %d-point lattice — the "
               ~ "index arithmetic below is only valid on the full grid",
               shaded.length, wire.length, kFillNX * kFillNY));
    auto isFill = new bool[](shaded.length);
    foreach (i; 0 .. shaded.length)
        isFill[i] = shaded[i].valid && wire[i].valid
                 && !samePixel(shaded[i], wire[i]);
    return sharedErodedFillIndices(isFill);
}

/// A camera that frames the stock cube with its SIDE faces dominant (a
/// near-overhead view would fill the lattice with the one face that a
/// rotation about the world up axis maps to itself, which would weaken
/// Flow M's control arm without failing it).
enum double kSolidAz = 0.6, kSolidEl = 0.35, kSolidDist = 6.0;

void setSolidCamera(double azimuth) {
    httpPost("/api/camera", format(
        `{"azimuth":%.10f,"elevation":%.10f,"distance":%.10f}`,
        azimuth, kSolidEl, kSolidDist));
    Thread.sleep(400.msecs);
}

void setStyle(string s) {
    postCommand("viewport.displayStyle", s);
    Thread.sleep(400.msecs);
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

    // The BASELINE is measured, not assumed (task 0594). This flow's claim is
    // ISOLATION — "a write addressed at one cell reaches that cell and no
    // other" — which says nothing about what the other cells happen to hold.
    // Hardcoding "Shaded" for them bolted that claim onto the shipped default,
    // and the shipped default is now projection-dependent: a Quad's three
    // ortho cells ship lines-only. Capturing the before-state keeps the real
    // assertion and makes it STRICTER, because a non-target cell that moves in
    // ANY direction now fails rather than only one that moves away from a
    // named constant.
    auto before = displayDump()["cells"].array;
    string[] baseStyle;
    double[] baseAlpha;
    bool[]   baseFaces;
    foreach (c; before) {
        baseStyle ~= c["state"]["active"]["style"].str;
        baseAlpha ~= jsonNum(c, "state", "active", "wireAlpha");
        baseFaces ~= jsonBool(c, "plan", "active", "drawFaces");
    }

    // Write a style that DIFFERS from cell 2's own baseline, or the write
    // would be a no-op and the flow would pass without testing anything.
    immutable bool   toWire = (baseStyle[2] != "Wireframe");
    immutable string want   = toWire ? "Wireframe" : "Shaded";
    immutable string wantId = toWire ? "wireframe" : "shaded";
    postCommandRaw("viewport.displayStyle",
        format(`{"_positional":["%s"],"viewport":2}`, wantId));
    postCommandRaw("viewport.wireAlpha", `{"_positional":[0.25],"viewport":2}`);
    Thread.sleep(300.msecs);

    enforce(want != baseStyle[2],
        "the write must change cell 2, or this flow asserts nothing");

    auto cells = displayDump()["cells"].array;
    foreach (i, c; cells) {
        immutable bool isTarget = (i == 2);
        immutable string style  = c["state"]["active"]["style"].str;
        immutable double alpha  = jsonNum(c, "state", "active", "wireAlpha");
        immutable string wantStyle = isTarget ? want : baseStyle[i];
        enforce(style == wantStyle,
            format("cell %d style is %s, expected %s; a display write "
                   ~ "addressed at cell 2 must reach cell 2 and no other — if "
                   ~ "every cell changed, the state is not per-cell",
                   i, style, wantStyle));
        enforce(abs(alpha - (isTarget ? 0.25 : baseAlpha[i])) < 1e-4,
            format("cell %d opacity is %.3f, expected %.2f", i, alpha,
                   isTarget ? 0.25 : baseAlpha[i]));
        // The resolved plan has to follow the state, per cell.
        immutable bool wantFaces = isTarget ? (want != "Wireframe") : baseFaces[i];
        enforce(jsonBool(c, "plan", "active", "drawFaces") == wantFaces,
            format("cell %d: the resolved plan does not follow that cell's "
                   ~ "own state", i));
    }
    writefln("    J1 PASS: cell 2 changed to %s, cells 0/1/3 held their "
             ~ "baseline (%s), plans follow", want, baseStyle);

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

    // TASK 0589 MOVED ONE VALUE ACROSS THIS LINE. `"solid"` was refused here,
    // with a message naming what was missing ("an unlit surface needs a shader
    // uniform that does not exist"). That uniform exists now and the face pass
    // reads `DrawPlan.facesLit`, so the refusal would itself be the lie this
    // flow exists to prevent — a viewport that CAN draw an unshaded fill while
    // the command insists it cannot. What it actually draws is Flow L's and
    // Flow M's job; all this flow claims is that it is no longer refused.
    postCommand("viewport.displayStyle", "solid");
    enforce(displayDump()["cells"].array[0]["state"]["active"]["style"].str == "Solid",
        "'solid' is accepted now, so it must also STICK — a command that "
        ~ "reports ok and leaves the state alone is the same silent lie in a "
        ~ "different shape");
    postCommand("viewport.displayStyle", "shaded");

    postCommandExpectingRefusal("viewport.wireOverlay",  `"colored"`);
    writeln("    K1 PASS: the per-item overlay colour is still refused; the "
            ~ "unshaded fill is accepted and sticks");

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
// Flow L — the unshaded fill. What Solid draws, and what it does NOT.
//
// Solid renders the geometry WITHOUT shading. It is a third surface style, not
// Shaded under another name and not Wireframe with a fill bolted on, and the
// two things it is most likely to be confused with are exactly the two other
// values of the axis — so both are measured here against the same samples.
//
//   * NOT Shaded: the fill is UNIFORM. Every face of the stock cube carries
//     the same surface, and with no lighting term every one of them lands on
//     the same colour, whichever way it faces. A shaded render of the same
//     cube cannot do that — the visible faces have different normals, so they
//     have different colours.
//   * NOT Wireframe: faces are drawn at all.
//
// The uniform value is checked against a KNOWN colour rather than just "some
// constant", which is the difference between "no shading" and "shading with a
// constant light" — a constant light is uniform too, merely darker.
//
// WHICH known colour: THE ANCHOR MOVED IN TASK 0592, and the two candidates
// are both named below on purpose, because the shape of this check is right
// and only its anchor was wrong.
//
//   kFillMeasured = 153 — THEIRS, and what we now draw. The reference's
//       unshaded style resolves its fill from a VIEWPORT COLOUR-SCHEME entry
//       and never consults a surface at all; its shipped scheme sets that
//       entry to 0.6 grey, and round(0.6 * 255) == 153.
//
//   kFillOursWas0589 = 204 — OURS, and wrong. Task 0589 anchored the fill on
//       the surface material, reasoning that "Solid is Shaded minus shading"
//       leaves the material in place. `LitShader` seeds material slot 0 to 0.8
//       grey for meshes carrying no surfaces (every procedural primitive), and
//       round(0.8 * 255) == 204. A later static read of the reference's own
//       shading machinery refuted that reasoning, so this assertion is not
//       being relaxed to make a change pass — it is being corrected to the
//       number the measurement produced, and the number it used to hold stays
//       written down right here so the correction is legible.
// --------------------------------------------------------------------------

enum int kFillMeasured     = 153;  // THEIRS, measured: round(0.6 * 255)
enum int kFillOursWas0589  = 204;  // OURS before 0592: round(0.8 * 255), the
                                   // LitShader material grey — superseded
static assert(kFillMeasured != kFillOursWas0589,
    "the corrected anchor must differ from the one it replaces, or L4 cannot "
    ~ "tell the two apart and the correction is untested");

bool testFlowL() {
    writeln("  [L] Solid: an unshaded fill, uniform across faces...");
    resetApp();
    scope(exit) restoreDisplayDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    enforce(W > 64 && H > 64, "implausible cell size");
    setSolidCamera(kSolidAz);

    immutable string pts = fillLattice(W, H);

    setStyle("shaded");    auto shaded = probe(0, pts).points;
    setStyle("wireframe"); auto wire   = probe(0, pts).points;
    setStyle("solid");     auto solid  = probe(0, pts).points;

    // --- L1: the plan. Faces on, lighting off, overlay untouched. ---
    auto pa = displayDump()["cells"].array[0];
    enforce(pa["state"]["active"]["style"].str == "Solid",
        "the cell did not end up in the unshaded-fill style");
    enforce(jsonBool(pa["plan"]["active"], "drawFaces"),
        "Solid draws a filled surface — it is not a lines-only style");
    enforce(!jsonBool(pa["plan"]["active"], "facesLit"),
        "Solid renders the geometry WITHOUT shading");
    enforce(jsonBool(pa["plan"]["active"], "drawWire"),
        "the surface style must not disturb the overlay axis");
    // The fill colour the renderer will actually use, off the same dump the
    // renderer consumes — so L4's pixel number below has a stated source
    // rather than being a bare constant someone tuned until it matched.
    {
        auto fc = pa["plan"]["active"]["fillColor"].array;
        foreach (k, ch; fc)
            enforce(abs(ch.get!double - 0.6) < 1e-6,
                format("the resolved unshaded fill must be the measured "
                       ~ "scheme colour 0.6 grey; channel %d reports %.6f "
                       ~ "(0.8 would mean the surface material — our "
                       ~ "superseded 0589 anchor)", k, ch.get!double));
    }
    writeln("    L1 PASS: plan = faces on, lighting off, overlay untouched, "
            ~ "fill = the scheme colour 0.6");

    // --- L2: find the fill, and refuse to conclude anything from too little ---
    auto idx = erodedFillIndices(shaded, wire);
    enforce(idx.length >= 150,
        format("only %d eroded face-fill samples — the model is not framed "
               ~ "where this flow expects it and no conclusion below would "
               ~ "mean anything", idx.length));
    writefln("    L2 PASS: %d eroded face-fill samples located", idx.length);

    // --- L3: it is not Wireframe — faces are actually drawn ---
    //
    // THIS RUNS BEFORE THE UNSHADED CHECK ON PURPOSE. Both orders fail when
    // the face pass is dropped, but only this one says why: with no fill, the
    // samples show grid and background and the uniformity check below reports
    // "something is still shading it", which is a true statement about the
    // numbers and a wrong diagnosis. Establish that there IS a fill, then ask
    // whether it is shaded.
    size_t drewOver = 0;
    foreach (i; idx) if (!samePixel(solid[i], wire[i])) drewOver++;
    enforce(drewOver >= idx.length * 95 / 100,
        format("only %d of %d fill samples differ from the lines-only image — "
               ~ "the face pass is not running under Solid, which makes it "
               ~ "Wireframe with a different name", drewOver, idx.length));
    writefln("    L3 PASS: %d/%d samples show a drawn face (vs lines-only)",
             drewOver, idx.length);

    // --- L4: THE DISCRIMINATOR. Uniform, and equal to the material colour. ---
    immutable int solidSpread  = channelSpread(solid,  idx);
    immutable int shadedSpread = channelSpread(shaded, idx);
    enforce(solidSpread <= 2,
        format("the unshaded fill varies by %d levels across the faces of a "
               ~ "one-surface cube — something is still shading it (a shaded "
               ~ "render of these same samples varies by %d)",
               solidSpread, shadedSpread));
    enforce(shadedSpread >= 20,
        format("the SHADED control varies by only %d levels — this flow cannot "
               ~ "tell an unshaded fill from a shaded surface under this "
               ~ "camera, so L4's pass would mean nothing", shadedSpread));

    int offBase = 0, atOldMaterialAnchor = 0;
    foreach (i; idx) {
        if (abs(solid[i].r - kFillMeasured) > 2
            || abs(solid[i].g - kFillMeasured) > 2
            || abs(solid[i].b - kFillMeasured) > 2) offBase++;
        if (abs(solid[i].r - kFillOursWas0589) <= 2) atOldMaterialAnchor++;
    }
    enforce(offBase == 0,
        format("%d of %d fill samples are not the MEASURED scheme fill "
               ~ "(%d = round(0.6*255)); %d of them sit at %d instead, which "
               ~ "is OUR superseded anchor — the surface material grey that "
               ~ "task 0589 wrongly took the fill from. A fill that tracks the "
               ~ "material means the material is still being consulted; a "
               ~ "UNIFORM fill darker than its base means shading with a "
               ~ "CONSTANT light. The uniformity check above passes on both, "
               ~ "which is exactly why this one follows it",
               offBase, idx.length, kFillMeasured,
               atOldMaterialAnchor, kFillOursWas0589));
    writefln("    L4 PASS: fill uniform (spread %d) at the measured scheme "
             ~ "colour %d (not the material anchor %d we shipped in 0589); "
             ~ "the shaded control spreads %d levels over the same samples",
             solidSpread, kFillMeasured, kFillOursWas0589, shadedSpread);

    return true;
}

// --------------------------------------------------------------------------
// Flow M — orientation invariance, which is the whole point of the style.
//
// "It looks flat" is not a check. The law is that a Solid render carries NO
// information about how the surface is oriented relative to the light, and the
// way to assert a law rather than an appearance is to find an operation that
// changes the orientation while leaving everything else alone, and require the
// pixels not to move.
//
// The operation: rotate the view a quarter turn about the world up axis. The
// stock cube is symmetric under that rotation, so its projection is CONGRUENT
// — same silhouette, same faces at the same screen positions, same wireframe —
// while the key light, which is fixed in world space, now falls on a different
// face at every one of those positions. (The +Y face maps to itself, but the
// eye moved, so its specular term moves too.)
//
// So over the face-fill samples:
//   * Solid  must not change AT ALL. Not "changes little" — the fill is one
//     colour over the whole model, so a congruent projection reproduces it
//     exactly, and the erosion keeps every sample a stride away from the
//     silhouette where float congruence is only approximate.
//   * Shaded MUST change, a lot. That arm is not decoration: without it, a
//     camera command that silently did nothing would make the Solid arm pass
//     for the wrong reason, and so would a probe that returned a stale frame.
//     It is the mutation guard for the assertion above it.
//
// This is the pair the whole task turns on: the two arms are two different
// laws measured by one operation, rather than one law described twice.
// --------------------------------------------------------------------------

bool testFlowM() {
    writeln("  [M] Solid is invariant to orientation; Shaded is not...");
    resetApp();
    scope(exit) restoreDisplayDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    enforce(W > 64 && H > 64, "implausible cell size");
    immutable string pts = fillLattice(W, H);

    // A quarter turn. The cube's symmetry is what makes the projection
    // congruent, so this constant is not a tuning knob — any other angle
    // changes the silhouette and the flow stops meaning anything.
    enum double kQuarterTurn = 1.5707963267948966;

    setSolidCamera(kSolidAz);
    setStyle("shaded");    auto shadedA = probe(0, pts).points;
    setStyle("wireframe"); auto wireA   = probe(0, pts).points;
    setStyle("solid");     auto solidA  = probe(0, pts).points;

    auto idx = erodedFillIndices(shadedA, wireA);
    enforce(idx.length >= 150,
        format("only %d eroded face-fill samples to compare", idx.length));

    setSolidCamera(kSolidAz + kQuarterTurn);
    auto solidB = probe(0, pts).points;
    setStyle("shaded");
    auto shadedB = probe(0, pts).points;

    // --- M1: the SHADED control first, because M2 is worthless without it ---
    size_t shadedMoved = 0;
    int    shadedDelta = 0;
    foreach (i; idx) {
        if (!samePixel(shadedA[i], shadedB[i])) shadedMoved++;
        immutable int d = [abs(shadedA[i].r - shadedB[i].r),
                           abs(shadedA[i].g - shadedB[i].g),
                           abs(shadedA[i].b - shadedB[i].b)].maxElement;
        if (d > shadedDelta) shadedDelta = d;
    }
    enforce(shadedMoved >= idx.length * 40 / 100,
        format("only %d of %d samples changed when the SHADED view turned a "
               ~ "quarter turn (max channel delta %d). The operation is not "
               ~ "reaching the renderer — a camera command that did nothing, "
               ~ "or a probe reading a stale frame, would look exactly like "
               ~ "this, and would make the invariance arm below pass for the "
               ~ "wrong reason", shadedMoved, idx.length, shadedDelta));
    writefln("    M1 PASS: the turn is real — %d/%d shaded samples changed, "
             ~ "max channel delta %d", shadedMoved, idx.length, shadedDelta);

    // --- M2: THE LAW. Solid does not know which way the model faces. ---
    size_t solidMoved = 0;
    int    solidDelta = 0;
    foreach (i; idx) {
        if (!samePixel(solidA[i], solidB[i])) solidMoved++;
        immutable int d = [abs(solidA[i].r - solidB[i].r),
                           abs(solidA[i].g - solidB[i].g),
                           abs(solidA[i].b - solidB[i].b)].maxElement;
        if (d > solidDelta) solidDelta = d;
    }
    enforce(solidMoved == 0,
        format("%d of %d fill samples changed when the view turned a quarter "
               ~ "turn under Solid (max channel delta %d), while the shaded "
               ~ "control moved %d of them. A fill that responds to the "
               ~ "model's orientation is a SHADED render — this is the "
               ~ "assertion that separates the two, and the tolerance is zero "
               ~ "on purpose: an unshaded fill is one colour, so a congruent "
               ~ "projection reproduces it exactly",
               solidMoved, idx.length, solidDelta, shadedMoved));
    writefln("    M2 PASS: %d/%d Solid samples changed (max channel delta %d) "
             ~ "— the fill carries no orientation", solidMoved, idx.length,
             solidDelta);

    return true;
}

// --------------------------------------------------------------------------
// Flow N — Solid runs NO BACKDROP FACE PASS, and background layers do not
// vanish (task 0592).
//
// MEASURED: in the reference's style registry every shaded style installs
// three model-draw sub-passes — a background one, the main one, and a
// transparency one — while the unshaded solid style installs exactly one, the
// main one. So a backdrop that mirrors the active style cannot re-run the
// unshaded fill for background layers: running a background face pass is the
// one thing that style provably does not do. (We have no transparency pass at
// all, so the other missing sub-pass costs us nothing to match.)
//
// THE OVER-READ THIS FLOW REFUSES TO IMPLEMENT. "No background step" is a
// fact about the STYLE's callback record. It does NOT say background layers
// disappear, and N3 is what stops this flow from passing on that stronger,
// unsupported claim: with the layer still there under Solid, the frame must
// differ from the frame with the layer HIDDEN. If the two matched, we would
// have shipped "Solid solos the active layer" — a real behaviour change wearing
// a measurement's clothes.
//
// The three arms are ordered so each one's precondition is already proven:
//   N1  the plan says it (and the Shaded control says the opposite)
//   N2  the pixels obey it — the fill is gone, and what is left is what a
//       hidden layer would have left
//   N3  the layer is nevertheless still drawn
// --------------------------------------------------------------------------

bool testFlowN() {
    writeln("  [N] Solid: no backdrop face pass, background layers still drawn...");
    resetApp();
    scope(exit) restoreDisplayDefaults();

    auto geom = probe(0, "");
    immutable int W = geom.w, H = geom.h;
    enforce(W > 64 && H > 64, "implausible cell size");
    setSolidCamera(kSolidAz);

    immutable string pts = fillLattice(W, H);

    // Locate the face fill while the cube is still the FOREGROUND layer — the
    // same self-locating criterion Flows L/M use, and it has to happen now
    // because the whole point below is that the backdrop stops filling.
    setStyle("shaded");    auto fgShaded = probe(0, pts).points;
    setStyle("wireframe"); auto fgWire   = probe(0, pts).points;
    auto idx = erodedFillIndices(fgShaded, fgWire);
    enforce(idx.length >= 150,
        format("only %d eroded face-fill samples — the model is not framed "
               ~ "where this flow expects it and nothing below would mean "
               ~ "anything", idx.length));

    // Demote the cube to a background layer: an added empty layer becomes
    // primary, so layer 0 (the cube) becomes visible-but-not-selected.
    postCommand("layer.add");
    Thread.sleep(500.msecs);

    setStyle("shaded");    auto bgShaded = probe(0, pts).points;
    setStyle("wireframe"); auto bgWire   = probe(0, pts).points;
    setStyle("solid");     auto bgSolid  = probe(0, pts).points;

    // --- N1: the plan, with its control ---
    auto pSolid = displayDump()["cells"].array[0];
    enforce(pSolid["state"]["active"]["style"].str == "Solid",
        "the cell did not end up in the unshaded-fill style");
    enforce(!jsonBool(pSolid["plan"]["backdrop"], "drawFaces"),
        "the unshaded style installs no background face step, so the mirrored "
        ~ "backdrop plan must not resolve one");
    enforce(jsonBool(pSolid["plan"]["backdrop"], "drawWire"),
        "the overlay is a SEPARATE axis — suppressing the backdrop fill must "
        ~ "not suppress the backdrop's lines");
    enforce(jsonBool(pSolid["plan"]["active"], "drawFaces"),
        "the rule is about the BACKDROP pass; the active surface still fills");

    setStyle("shaded");
    auto pShaded = displayDump()["cells"].array[0];
    enforce(jsonBool(pShaded["plan"]["backdrop"], "drawFaces"),
        "CONTROL: a shaded style DOES install a background step, so this flow "
        ~ "would be asserting a constant if the backdrop never filled");
    writeln("    N1 PASS: backdrop drawFaces false under Solid, true under "
            ~ "Shaded; backdrop overlay untouched by both");

    // --- N2: the pixels. The fill is gone, and the layer is not repainting
    //         something else in its place. ---
    //
    // The reference frame for "gone" is the SAME SCENE WITH THE LAYER HIDDEN,
    // not the clear colour: the grid draws behind the model, so "no face pass"
    // does not mean "background colour" at these samples.
    setStyle("solid");
    // NAMED params go through postCommandRaw (params as a JSON OBJECT). The
    // `postCommand(cmd, string)` form carries ONE positional value, and
    // handing it an object literal as a string is accepted with
    // `{"status":"ok"}` and then silently ignored — the command runs on its
    // defaults (index -1 = the active layer, value = true) and changes
    // nothing. That is how this arm first ran vacuously: every probe below
    // compared a frame against itself, N3 read 0 differences, and the "layers
    // vanished" failure it reported was the harness, not the renderer.
    postCommandRaw("layer.setVisible", `{"index":0,"value":false}`);
    Thread.sleep(500.msecs);
    auto lay = parseJSON(httpGet("/api/layers"));
    enforce(!jsonBool(lay["layers"].array[0], "visible"),
        "precondition: layer 0 must actually be hidden — this flow's whole "
        ~ "reference frame is 'the same scene without that layer', and a "
        ~ "setVisible that no-ops makes every comparison below vacuous");
    auto bgHidden = probe(0, pts).points;

    size_t fillGone = 0, matchesHidden = 0;
    foreach (i; idx) {
        if (!samePixel(bgShaded[i], bgSolid[i]))  fillGone++;
        if (samePixel(bgSolid[i],  bgHidden[i]))  matchesHidden++;
    }
    enforce(fillGone >= idx.length * 95 / 100,
        format("only %d of %d backdrop fill samples changed when the style "
               ~ "went Shaded -> Solid — the backdrop face pass is still "
               ~ "running, so the plan is resolved but not consumed",
               fillGone, idx.length));
    enforce(matchesHidden >= idx.length * 90 / 100,
        format("only %d of %d samples match the layer-hidden frame — the "
               ~ "backdrop stopped filling but is painting something else "
               ~ "there. (Some mismatch is expected and allowed: the cube's "
               ~ "INTERIOR wireframe edges cross this set, and those lines "
               ~ "correctly survive.)", matchesHidden, idx.length));
    writefln("    N2 PASS: %d/%d fill samples changed; %d/%d now read as if "
             ~ "the layer were not there", fillGone, idx.length,
             matchesHidden, idx.length);

    // --- N3: THE DISCRIMINATOR AGAINST THE OVER-READ. ---
    //
    // Over the WHOLE lattice this time, not the eroded fill set: the samples
    // that separate "still drawn" from "vanished" are the ones ON the lines,
    // and erosion deliberately removes those. Self-locating — this never needs
    // to know where a line is, only that hiding the layer changed something.
    //
    // Two arms, because either alone is satisfiable by the wrong build:
    //   N3a  EXACT equality with the lines-only style's backdrop. Under
    //        Wireframe the backdrop already resolved "no faces, lines on",
    //        which is exactly what Solid's backdrop must now resolve — so the
    //        two frames must agree byte for byte. Zero tolerance, no
    //        threshold to tune. This pins the fill OFF and the lines ON in one
    //        assertion, and it fails in both directions.
    //   N3b  the frame must nevertheless DIFFER from the layer-hidden one.
    //        N3a alone would still pass if the backdrop drew nothing at all
    //        AND the lines-only backdrop drew nothing either; this is what
    //        makes "vanished" a failure rather than a second way to agree.
    size_t vsWire = 0, stillDrawn = 0;
    foreach (i; 0 .. bgSolid.length) {
        if (!bgSolid[i].valid) continue;
        if (bgWire[i].valid   && !samePixel(bgSolid[i], bgWire[i]))   vsWire++;
        if (bgHidden[i].valid && !samePixel(bgSolid[i], bgHidden[i])) stillDrawn++;
    }
    enforce(vsWire == 0,
        format("%d of %d samples differ between the Solid backdrop and the "
               ~ "lines-only backdrop. Both resolve to the same passes — no "
               ~ "face step, overlay on — so the two frames must be identical; "
               ~ "a difference means the backdrop is still filling, or has "
               ~ "lost its lines", vsWire, bgSolid.length));
    // The floor is a long way under what this camera actually produces (23 of
    // 3000 measured), and a long way over the 0 the over-read would give. It
    // is a "did anything at all draw" gate, not a count of lines.
    enforce(stillDrawn >= 10,
        format("only %d of %d samples differ between the Solid backdrop and "
               ~ "the same scene with the layer HIDDEN — the background layer "
               ~ "has effectively vanished. The measurement says the unshaded "
               ~ "style installs no background FACE step; it does not say the "
               ~ "layer stops being drawn, and this build implements the "
               ~ "stronger claim", stillDrawn, bgSolid.length));
    writefln("    N3 PASS: identical to the lines-only backdrop (0 differing), "
             ~ "and %d/%d samples still show the background layer — it lost "
             ~ "its fill, not its existence", stillDrawn, bgSolid.length);

    postCommandRaw("layer.setVisible", `{"index":0,"value":true}`);
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

    run(&testFlowA, "Flow A — default state + resolved plan is today's behaviour");
    run(&testFlowB, "Flow B — activity axis carried in state and plan");
    run(&testFlowC, "Flow C — pixel probe reads the cell framebuffer");
    run(&testFlowD, "Flow D — plan and pixels agree about which passes ran");
    run(&testFlowE, "Flow E — per-cell renders flag agrees with the render set");
    run(&testFlowF, "Flow F — backdrop plan reaches the pixels");
    run(&testFlowG, "Flow G — lines-only style: faces off, model see-through");
    run(&testFlowH, "Flow H — overlay axis on/off, selection surviving None");
    run(&testFlowI, "Flow I — overlay opacity reaches the pixels");
    run(&testFlowJ, "Flow J — a display change reaches exactly one cell");
    run(&testFlowK, "Flow K — undrawable values are refused");
    run(&testFlowL, "Flow L — Solid: an unshaded fill, uniform across faces");
    run(&testFlowM, "Flow M — Solid is orientation-invariant, Shaded is not");
    run(&testFlowN, "Flow N — Solid runs no backdrop face pass, layers remain");

    // Belt-and-suspenders: the runner shares one app across a worker's whole
    // slice and its between-tests reset does not cover viewport display state
    // or layout. Every mutating flow restores in a scope(exit); this catches
    // the case where a flow died somewhere that skipped even that.
    restoreDisplayDefaults();

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
