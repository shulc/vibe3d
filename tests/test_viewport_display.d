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

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
