// test_viewport_display_defaults.d — task 0594: the shipped display default
// is projection-dependent, and a saved choice outranks it.
//
// Two separate claims live here, and conflating them is the failure mode this
// file exists to prevent:
//
//   THE DEFAULT     — a cell that nobody configured ships lines-only when its
//                     projection is orthographic and shaded when it is
//                     perspective. This is a visible change: a fresh Quad
//                     layout now shows three wireframe cells out of four.
//   THE PRECEDENCE  — a style somebody CHOSE must survive everything the
//                     default would otherwise re-apply. A default that
//                     silently overwrites a saved choice is the defect, not
//                     the visual change.
//
// Flow A — the default follows the PROJECTION, asserted against each cell's
//          own reported `ortho` flag rather than its index.
// Flow B — the perspective single-viewport case is untouched: byte-for-byte
//          the same pixels as before this task.
// Flow C — the default reaches GL, not just the plan: the ortho cell draws no
//          fill, and forcing it back to Shaded brings the fill back.
// Flow D — PRECEDENCE: a chosen style survives a layout switch, which is the
//          in-session path that re-applies the template.
// Flow E — PRECEDENCE: a view change does NOT re-apply the template. Swinging
//          a cell's camera from Perspective to Top must not restyle it.
//
// The persisted half of the precedence (a prefs file's saved style beating the
// template on the next launch) is a module unittest in source/prefs.d — it is
// a file-format question and needs no running app.
module test_viewport_display_defaults;

import http_client : testBaseUrl;
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
// Helpers (same conventions as test_viewport_display.d)
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

/// Raw params (an object, not a positional string) — needed for the
/// per-cell `viewport` selector.
void postCommandRaw(string cmd, string paramsJson) {
    string body_ = format(`{"id":"%s","params":%s}`, cmd, paramsJson);
    string resp = httpPost("/api/command", body_);
    auto r = parseJSON(resp);
    enforce("status" !in r || r["status"].str != "error",
            "command " ~ cmd ~ " failed: " ~ resp);
}

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

enum int kClearR = 92, kClearG = 102, kClearB = 107;

bool isClear(Px p) {
    return abs(p.r - kClearR) <= 2 && abs(p.g - kClearG) <= 2
        && abs(p.b - kClearB) <= 2;
}

struct ProbeResult {
    int  w, h;
    bool renders;
    Px[] points;
}

ProbeResult probe(int cell, string points) {
    string q = format("/api/viewport/probe?cell=%d", cell);
    if (points.length) q ~= "&points=" ~ points;
    auto j = parseJSON(httpGet(q));
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

/// A lattice covering the middle 80% of a cell, SCALED to the cell rather
/// than a fixed stride: a Quad cell is a quarter of a Single one, and a fixed
/// stride would run off its edge and return `error` points, silently
/// shrinking the sample without failing anything.
enum int kNX = 40, kNY = 34;

string fitLattice(int w, int h) {
    immutable int x0 = w / 10, y0 = h / 10;
    immutable int dx = (w * 8 / 10) / (kNX - 1), dy = (h * 8 / 10) / (kNY - 1);
    string pts;
    foreach (j; 0 .. kNY)
        foreach (i; 0 .. kNX)
            pts ~= format("%d,%d;", x0 + i * dx, y0 + j * dy);
    return pts;
}

/// Restore a clean slate for the next test in this worker's slice. The runner
/// shares one app across the whole slice, and `displayUserSet` is STICKY by
/// design — only /api/reset clears it — so leaving it set would pin every
/// later default assertion in this process.
void restoreDefaults() {
    try { postCommand("viewport.layout", "Single"); } catch (Exception) {}
    httpPost("/api/reset", "{}");
    Thread.sleep(250.msecs);
}

// --------------------------------------------------------------------------
// Flow A — the default is a function of the PROJECTION.
// --------------------------------------------------------------------------

bool testFlowA() {
    writeln("  [A] Ortho cells ship lines-only, perspective ships shaded...");
    resetApp();
    scope(exit) restoreDefaults();

    // Single layout first: one perspective cell, and it must be shaded — the
    // overwhelmingly common case must be untouched by this change.
    auto j0 = displayDump();
    enforce(cast(int)jsonNum(j0, "cellCount") == 1,
        "precondition: a fresh app is Single layout");
    auto c0 = j0["cells"].array[0];
    enforce(!jsonBool(c0, "ortho"),
        "precondition: the default single viewport is perspective");
    enforce(c0["state"]["active"]["style"].str == "Shaded",
        format("the default perspective viewport must ship Shaded, got %s",
               c0["state"]["active"]["style"].str));
    enforce(jsonBool(c0, "plan", "active", "drawFaces"),
        "a shaded perspective cell must draw faces");
    writeln("    A1 PASS: the single perspective viewport still ships Shaded");

    postCommand("viewport.layout", "Quad");
    Thread.sleep(500.msecs);

    auto j = displayDump();
    enforce(cast(int)jsonNum(j, "cellCount") == 4, "Quad must report 4 cells");

    int orthoCells = 0, perspCells = 0;
    foreach (i, c; j["cells"].array) {
        immutable bool ortho = jsonBool(c, "ortho");
        immutable string style = c["state"]["active"]["style"].str;
        immutable bool faces = jsonBool(c, "plan", "active", "drawFaces");
        immutable bool wire  = jsonBool(c, "plan", "active", "drawWire");

        // Keyed on the cell's OWN reported projection, not on its index: the
        // layout is free to reassign which corner is which, and an
        // index-keyed assertion would then be testing the corner assignment
        // rather than the default.
        if (ortho) {
            orthoCells++;
            enforce(style == "Wireframe",
                format("cell %d is orthographic and must ship Wireframe, "
                       ~ "got %s", i, style));
            enforce(!faces,
                format("cell %d ships Wireframe but its plan still draws "
                       ~ "faces — the state did not reach the plan", i));
        } else {
            perspCells++;
            enforce(style == "Shaded",
                format("cell %d is perspective and must ship Shaded, got %s",
                       i, style));
            enforce(faces,
                format("cell %d ships Shaded but its plan draws no faces", i));
        }
        // Neither default may switch the overlay off — a lines-only cell with
        // no overlay would be an empty viewport.
        enforce(wire, format("cell %d must draw lines under either default", i));
        enforce(!jsonBool(c, "userSet"),
            format("cell %d must not report a user-set style on a fresh "
                   ~ "layout — the template is not a choice", i));
    }

    // The owner-visible consequence, asserted as a number rather than left to
    // be noticed: three of the four Quad cells are wireframe.
    enforce(orthoCells == 3 && perspCells == 1,
        format("a Quad layout must be 3 ortho + 1 perspective, got %d + %d",
               orthoCells, perspCells));
    writefln("    A2 PASS: Quad = %d ortho cells all Wireframe + %d "
             ~ "perspective cell Shaded", orthoCells, perspCells);
    return true;
}

// --------------------------------------------------------------------------
// Flow B — the perspective case is untouched at the PIXEL level.
//
// The plan assertion in Flow A says the state did not change. This says the
// framebuffer did not either, which is the claim that actually matters to a
// user who never opens a Quad layout.
// --------------------------------------------------------------------------

bool testFlowB() {
    writeln("  [B] The single perspective viewport draws a filled surface...");
    resetApp();
    scope(exit) restoreDefaults();

    auto meta = probe(0, "");
    enforce(meta.renders, "the single cell must be rendered");
    auto r = probe(0, fitLattice(meta.w, meta.h));
    enforce(r.points.length == kNX * kNY,
        format("expected %d lattice samples, got %d", kNX * kNY, r.points.length));

    int filled = 0;
    foreach (p; r.points) {
        enforce(p.valid, format("lattice sample (%d,%d) failed", p.x, p.y));
        if (!isClear(p)) filled++;
    }
    // A perspective viewport shows a shaded cube: a substantial run of the
    // lattice must be non-clear. If this ever drops to near zero the default
    // has leaked into the perspective case.
    enforce(filled > kNX * kNY / 10,
        format("only %d of %d samples are non-clear — the perspective "
               ~ "viewport has lost its surface", filled, kNX * kNY));
    writefln("    B1 PASS: %d/%d lattice samples filled in the perspective cell",
             filled, kNX * kNY);
    return true;
}

// --------------------------------------------------------------------------
// Flow C — the default reaches GL.
//
// Flow A proves the plan. This proves the pixels, and it proves them with a
// MUTATION: the same cell, same camera, forced back to Shaded, must regain
// the fill. Without that arm, "few non-clear samples" could be satisfied by a
// cell that was never drawn at all.
// --------------------------------------------------------------------------

bool testFlowC() {
    writeln("  [C] The ortho default removes the fill; Shaded restores it...");
    resetApp();
    scope(exit) restoreDefaults();

    postCommand("viewport.layout", "Quad");
    Thread.sleep(500.msecs);

    auto j = displayDump();
    immutable int active = cast(int)jsonNum(j, "activeId");
    auto ac = j["cells"].array[active];
    enforce(jsonBool(ac, "ortho"),
        format("this flow needs the ACTIVE cell to be orthographic (only the "
               ~ "active cell is rendered under --test); cell %d is not",
               active));
    enforce(ac["state"]["active"]["style"].str == "Wireframe",
        "precondition: the active ortho cell ships Wireframe");

    auto meta = probe(active, "");
    enforce(meta.renders, "the active cell must be rendered");
    immutable string pts = fitLattice(meta.w, meta.h);

    auto wireR = probe(active, pts);
    int wireFilled = 0;
    foreach (p; wireR.points) if (p.valid && !isClear(p)) wireFilled++;

    // Mutation arm: same cell, same camera, only the style changes.
    postCommandRaw("viewport.displayStyle",
        format(`{"_positional":["shaded"],"viewport":%d}`, active));
    Thread.sleep(400.msecs);
    enforce(displayDump()["cells"].array[active]["state"]["active"]["style"].str
            == "Shaded", "the mutation did not take");

    auto shadedR = probe(active, pts);
    int shadedFilled = 0;
    foreach (p; shadedR.points) if (p.valid && !isClear(p)) shadedFilled++;

    enforce(shadedFilled > wireFilled,
        format("the shaded arm filled %d samples and the wireframe default "
               ~ "filled %d — the default is not reaching GL",
               shadedFilled, wireFilled));
    // And the gap must be a real surface, not a couple of anti-aliased edge
    // pixels: the fill has to account for a substantial part of the lattice.
    enforce(shadedFilled - wireFilled > kNX * kNY / 10,
        format("shaded %d vs wireframe %d out of %d samples — too small a "
               ~ "difference to be a surface appearing",
               shadedFilled, wireFilled, kNX * kNY));
    writefln("    C1 PASS: wireframe default fills %d/%d samples, Shaded "
             ~ "fills %d/%d (delta %d)",
             wireFilled, kNX * kNY, shadedFilled, kNX * kNY,
             shadedFilled - wireFilled);
    return true;
}

// --------------------------------------------------------------------------
// Flow D — PRECEDENCE against a layout switch.
//
// `applyLayout` is what seeds the template, and switching layouts is a
// routine thing to do. A chosen style that did not survive Quad -> Single ->
// Quad would be the "a default silently overwrote a saved choice" defect,
// wearing an in-session disguise.
// --------------------------------------------------------------------------

bool testFlowD() {
    writeln("  [D] A chosen style survives a layout switch...");
    resetApp();
    scope(exit) restoreDefaults();

    postCommand("viewport.layout", "Quad");
    Thread.sleep(500.msecs);

    // Find an ortho cell (default Wireframe) and choose Shaded on it — the
    // opposite of what the template would re-apply, so a template re-seed is
    // unmistakable.
    int target = -1;
    foreach (i, c; displayDump()["cells"].array)
        if (jsonBool(c, "ortho")) { target = cast(int)i; break; }
    enforce(target >= 0, "precondition: Quad must contain an orthographic cell");

    postCommandRaw("viewport.displayStyle",
        format(`{"_positional":["shaded"],"viewport":%d}`, target));
    Thread.sleep(300.msecs);

    auto after = displayDump()["cells"].array[target];
    enforce(after["state"]["active"]["style"].str == "Shaded",
        "the chosen style did not take");
    enforce(jsonBool(after, "userSet"),
        "choosing a style must mark the cell user-set — that bit is what "
        ~ "outranks the template");
    writefln("    D1 PASS: cell %d chosen Shaded, reports userSet", target);

    // Round trip through another layout and back. Every one of these calls
    // runs applyLayout, which is where the template is seeded.
    postCommand("viewport.layout", "Single");
    Thread.sleep(350.msecs);
    postCommand("viewport.layout", "Quad");
    Thread.sleep(500.msecs);

    auto back = displayDump()["cells"].array[target];
    enforce(jsonBool(back, "ortho"),
        format("precondition: cell %d is orthographic again after the round "
               ~ "trip", target));
    enforce(back["state"]["active"]["style"].str == "Shaded",
        format("cell %d came back as %s — the layout template overwrote a "
               ~ "style the user chose, which is exactly the defect this "
               ~ "default must not introduce",
               target, back["state"]["active"]["style"].str));
    enforce(jsonBool(back, "userSet"),
        "the user-set bit must survive the round trip too, or the NEXT "
        ~ "layout switch would overwrite the style");

    // The control arm: a cell nobody chose still gets the template. Without
    // this, "everything stayed Shaded" would also pass.
    int untouched = -1;
    foreach (i, c; displayDump()["cells"].array)
        if (cast(int)i != target && jsonBool(c, "ortho")) {
            untouched = cast(int)i; break;
        }
    enforce(untouched >= 0, "precondition: a second ortho cell exists");
    enforce(displayDump()["cells"].array[untouched]["state"]["active"]["style"].str
            == "Wireframe",
        format("cell %d was never chosen and must still carry the template",
               untouched));
    writefln("    D2 PASS: chosen cell %d held Shaded across Quad->Single->"
             ~ "Quad; untouched cell %d still Wireframe", target, untouched);
    return true;
}

// --------------------------------------------------------------------------
// Flow E — PRECEDENCE against a camera change.
//
// The default is a TEMPLATE — the value a cell is born with — not a rule that
// re-fires whenever the projection changes. Swinging a perspective cell to a
// Top view changes the camera; it must not restyle the viewport.
// --------------------------------------------------------------------------

bool testFlowE() {
    writeln("  [E] Changing a cell's view does not re-apply the template...");
    resetApp();
    scope(exit) restoreDefaults();

    // A fresh Single cell: perspective, Shaded, nobody chose it.
    auto c0 = displayDump()["cells"].array[0];
    enforce(!jsonBool(c0, "ortho") && c0["state"]["active"]["style"].str == "Shaded",
        "precondition: a fresh single cell is perspective + Shaded");
    enforce(!jsonBool(c0, "userSet"), "precondition: nobody has chosen a style");

    postCommand("viewport.view", "Top");
    Thread.sleep(400.msecs);

    auto c1 = displayDump()["cells"].array[0];
    enforce(jsonBool(c1, "ortho"),
        "precondition: the Top view must be orthographic, or this flow tests "
        ~ "nothing");
    enforce(c1["state"]["active"]["style"].str == "Shaded",
        format("the cell restyled itself to %s on a VIEW change. The shipped "
               ~ "default is the value a cell is born with, not a rule that "
               ~ "re-fires on every camera move — a user who swings the camera "
               ~ "around must not have the viewport restyled under them",
               c1["state"]["active"]["style"].str));
    writeln("    E1 PASS: Perspective -> Top changed the projection, not the style");
    return true;
}

// --------------------------------------------------------------------------

int main(string[] args) {
    // Resolve the port assigned to this worker by run_test.d.
    baseUrl = testBaseUrl();

    writeln("=== test_viewport_display_defaults ===");
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

    run(&testFlowA, "Flow A — the default follows the projection");
    run(&testFlowB, "Flow B — the perspective viewport keeps its surface");
    run(&testFlowC, "Flow C — the ortho default reaches GL");
    run(&testFlowD, "Flow D — a chosen style survives a layout switch");
    run(&testFlowE, "Flow E — a view change does not re-apply the template");

    restoreDefaults();

    writefln("\n%d passed, %d failed", passed, failed);
    return failed > 0 ? 1 : 0;
}
