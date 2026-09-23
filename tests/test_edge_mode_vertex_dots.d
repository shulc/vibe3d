// Task 7127 (S9-R, item 7) — a vertex selection kept across a switch to EDGE
// mode must not be drawn in the selection colour.
//
// Law (frozen in tests/fixtures/editor_display_laws_w17.json,
// `vertex_dots_in_edge_mode`): in edge mode every vertex is still drawn as a
// dot in the UNSELECTED colour and size; the vertex selection survives the
// switch but is not shown. Five conditions were captured (perspective
// default / shaded / wireframe, front ortho shaded / wireframe), each with
// 30–36 selection-coloured pixels around a selected vertex in vertex mode and
// ZERO in edge mode. This file mirrors that measurement: it counts
// selection-coloured pixels in a window around each selected vertex.
//
// Why a pixel probe and not a draw-call census: the defect is a COLOUR — the
// dot pass runs either way, only the mark view it is handed differs, and a
// submission count is byte-identical for both.
//
// Order inside every block (CLAUDE.md "ORDER the asserts"):
//   1. rig premises (selection population, probe points inside the cell);
//   2. POSITIVE CONTROL — in vertex mode the same window finds the selection
//      colour (so the probe is on the dot, and a zero below is not a probe
//      that looks at nothing);
//   3. the switch by a real key (`2`, through /api/play-events), and a
//      population floor: the two vertices are STILL selected;
//   4. the named assert "selected vertex dot drawn in edge mode".
// The shaded conditions come first: on HEAD they draw no dots in edge mode at
// all, so their named assert holds and the run buys their green half before
// the wireframe block reddens.

import http_client : getJson, postJson, testBaseUrl;
import http_command_helpers : commandBody;
import std.json;
import std.format : format;
import std.math : round, abs, tan, PI;
import std.stdio : writeln;
import core.thread : Thread;
import core.time : msecs;

import drag_helpers : fetchCamera, viewportFromCamera, projectToWindow,
                      playAndWait, DHVec3 = Vec3;

void main() {}

alias baseUrl = testBaseUrl;

private void settle() { Thread.sleep(450.msecs); }

private void cmdOk(string body) {
    auto r = postJson("/api/command", body);
    assert(r["status"].str == "ok" || r["status"].str == "success",
           "command failed: " ~ body ~ " -> " ~ r.toString);
}

// ---------------------------------------------------------------------------
// Pixels
// ---------------------------------------------------------------------------

private struct Px {
    int r, g, b;
    bool valid;
    string toString() const {
        return valid ? format("(%d, %d, %d)", r, g, b) : "<unreadable>";
    }
}

private Px[] probe(const int[2][] pts) {
    Px[] outp;
    for (size_t i = 0; i < pts.length; i += 50) {
        auto slice = pts[i .. (i + 50 > pts.length ? pts.length : i + 50)];
        string q = "/api/viewport/probe?cell=0&points=";
        foreach (k, p; slice) {
            if (k) q ~= ";";
            q ~= format("%d,%d", p[0], p[1]);
        }
        auto j = getJson(q);
        assert("error" !in j, "probe failed: " ~ j.toString);
        // A never-rendered cell reads zeros, and "no selection colour" would
        // then pass for the wrong reason.
        assert(j["renders"].type == JSONType.true_,
            "the probed cell is not rendered; every reading below is void");
        foreach (e; j["points"].array) {
            Px p;
            if ("error" !in e) {
                p.r = cast(int)e["r"].integer;
                p.g = cast(int)e["g"].integer;
                p.b = cast(int)e["b"].integer;
                p.valid = true;
            }
            outp ~= p;
        }
    }
    return outp;
}

/// The selection colour the dot pass hands to GL, (1.00, 0.66, 0.16): none of
/// the three channels is a rounding tie (255.0, 168.3, 40.8).
private enum int[3] kSel = [255, 168, 41];

private bool isSel(Px p) {
    return p.valid && abs(p.r - kSel[0]) <= 2 && abs(p.g - kSel[1]) <= 2
        && abs(p.b - kSel[2]) <= 2;
}

/// Half-width of the square window counted around a vertex. The selected dot
/// is 6 px across (base 3 x 2), so 6 covers it with margin and stays clear of
/// the other selected vertex at both cameras below (checked per rig).
private enum int kHalf = 6;

private int selCountAround(int[2] c) {
    int[2][] pts;
    foreach (dy; -kHalf .. kHalf + 1)
        foreach (dx; -kHalf .. kHalf + 1)
            pts ~= [c[0] + dx, c[1] + dy];
    int n = 0;
    foreach (p; probe(pts)) if (isSel(p)) ++n;
    return n;
}

// ---------------------------------------------------------------------------
// Rig
// ---------------------------------------------------------------------------

private struct Cell { int vx, vy, vw, vh; }

private Cell cell() {
    auto c = getJson("/api/camera");
    return Cell(cast(int)c["vpX"].integer,  cast(int)c["vpY"].integer,
                cast(int)c["width"].integer, cast(int)c["height"].integer);
}

/// World -> cell pixel for the PERSPECTIVE camera, through the live matrices.
private int[2] perspPx(DHVec3 w) {
    auto camS = fetchCamera(baseUrl);
    auto vp   = viewportFromCamera(camS);
    float px, py;
    assert(projectToWindow(w, vp, px, py),
        format("rig: world point (%g, %g, %g) is behind the camera", w.x, w.y, w.z));
    return [cast(int)round(px) - camS.vpX, cast(int)round(py) - camS.vpY];
}

/// World -> cell pixel for the FRONT orthographic camera: x right, y up,
/// scale read back from /api/camera (same derivation as
/// test_region_pick_coincident.d).
private int[2] frontPx(DHVec3 wp) {
    auto j = getJson("/api/camera");
    assert(j["projKind"].str == "Ortho" && j["viewPreset"].str == "Front",
           "rig: expected the Front orthographic view: " ~ j.toString);
    immutable float fx = cast(float)j["focus"]["x"].floating;
    immutable float fy = cast(float)j["focus"]["y"].floating;
    immutable int   w  = cast(int)j["width"].integer;
    immutable int   h  = cast(int)j["height"].integer;
    immutable float d  = cast(float)j["distance"].floating;
    immutable float ppu = h / (2.0f * d * tan(cast(float)(PI / 8.0)));
    return [cast(int)round(w * 0.5f + (wp.x - fx) * ppu),
            cast(int)round(h * 0.5f - (wp.y - fy) * ppu)];
}

/// Real SDL key press through the event player (the path keys 1/2/3 take).
private void pressKey(int sym, int scan) {
    auto c = cell();
    string log = format(
        `{"t":0.000,"type":"VIEWPORT","vpX":%d,"vpY":%d,"vpW":%d,"vpH":%d,`
        ~ `"fovY":0.785398}` ~ "\n", c.vx, c.vy, c.vw, c.vh);
    // The pointer is parked in a corner of the cell first, so nothing is
    // pre-highlighted (a third colour) while the probes read.
    log ~= format(`{"t":20.000,"type":"SDL_MOUSEMOTION","x":%d,"y":%d,`
                  ~ `"xrel":0,"yrel":0,"state":0,"mod":0}` ~ "\n",
                  c.vx + 10, c.vy + c.vh - 10);
    log ~= format(`{"t":40.000,"type":"SDL_KEYDOWN","sym":%d,"scan":%d,"mod":0,"repeat":0}` ~ "\n",
                  sym, scan);
    log ~= format(`{"t":60.000,"type":"SDL_KEYUP","sym":%d,"scan":%d,"mod":0,"repeat":0}` ~ "\n",
                  sym, scan);
    playAndWait(log, baseUrl);
    settle();
}

private void pressVertexKey() { pressKey(49, 30); }  // '1'
private void pressEdgeKey()   { pressKey(50, 31); }  // '2'

private long[] selectedVertices() {
    long[] r;
    foreach (v; getJson("/api/selection")["selectedVertices"].array)
        r ~= v.integer;
    return r;
}

private string selType() { return getJson("/api/selection")["selType"].str; }

private string activeStyle() {
    return getJson("/api/viewport/display")["cells"].array[0]["state"]
        ["active"]["style"].str;
}

/// Model indices of the two captured selected vertices, derived from
/// /api/model rather than typed: (0.5, 0.5, 0.5) and (-0.5, 0.5, 0.5).
private long vertexAt(double x, double y, double z) {
    foreach (i, v; getJson("/api/model")["vertices"].array) {
        auto a = v.array;
        if (abs(a[0].floating - x) < 1e-6 && abs(a[1].floating - y) < 1e-6
            && abs(a[2].floating - z) < 1e-6)
            return cast(long)i;
    }
    assert(false, format("rig: the reset cube has no vertex at (%g, %g, %g)", x, y, z));
}

/// One captured condition. `style` null = leave the reset default alone
/// (the "default" condition); `front` = the Front orthographic view.
private void runCondition(string name, string style, bool front,
                          int expectedEdgePx) {
    postJson("/api/command", commandBody("scene.reset", "{}"));
    settle();
    // /api/reset does not restore the projection, so every block sets its own
    // and the last one restores perspective on exit.
    cmdOk(front ? `viewport.view Front` : `viewport.view Perspective`);
    if (style !is null)
        cmdOk(commandBody("viewport.displayStyle", format(`"%s"`, style)));
    settle();
    if (front) {
        // 100 px per unit: the two selected vertices 100 px apart, well
        // clear of each other's window.
        auto before = getJson("/api/camera");
        immutable int h = cast(int)before["height"].integer;
        immutable float dist = h / (2.0f * 100.0f * tan(cast(float)(PI / 8.0)));
        postJson("/api/camera", format(
            `{"distance":%.9g,"focus":{"x":0,"y":0,"z":0}}`, dist));
        settle();
    }

    immutable string wantStyle = style is null ? "Shaded"
        : (style == "wireframe" ? "Wireframe" : "Shaded");
    assert(activeStyle() == wantStyle,
        format("[%s] rig: display style is %s, expected %s", name,
               activeStyle(), wantStyle));

    immutable long a = vertexAt( 0.5, 0.5, 0.5);
    immutable long b = vertexAt(-0.5, 0.5, 0.5);

    // Vertex mode by the real key, then the two captured vertices selected.
    pressVertexKey();
    cmdOk(commandBody("mesh.select",
        format(`{"mode":"vertices","indices":[%d,%d]}`, a, b)));
    settle();
    pressVertexKey();   // re-park the pointer after the select
    assert(selType() == "vertex", format("[%s] rig: not in vertex mode", name));
    assert(selectedVertices().length == 2,
        format("[%s] rig: expected 2 selected vertices, got %s", name,
               selectedVertices()));

    immutable DHVec3 wa = DHVec3( 0.5f, 0.5f, 0.5f);
    immutable DHVec3 wb = DHVec3(-0.5f, 0.5f, 0.5f);
    immutable int[2] pa = front ? frontPx(wa) : perspPx(wa);
    immutable int[2] pb = front ? frontPx(wb) : perspPx(wb);
    auto c = cell();
    foreach (p; [pa, pb])
        assert(p[0] >= kHalf && p[1] >= kHalf
            && p[0] < c.vw - kHalf && p[1] < c.vh - kHalf,
            format("[%s] rig: probe window at (%d, %d) leaves the %dx%d cell",
                   name, p[0], p[1], c.vw, c.vh));
    assert(abs(pa[0] - pb[0]) > 2 * kHalf + 1 || abs(pa[1] - pb[1]) > 2 * kHalf + 1,
        format("[%s] rig: the two probe windows overlap: (%d,%d) (%d,%d)",
               name, pa[0], pa[1], pb[0], pb[1]));

    // ---- POSITIVE CONTROL: vertex mode shows the selection ---------------
    // Must hold on HEAD and after the fix alike. The selected dot is 6 x 6 =
    // 36 px; the edges drawn over it take a few (measured on this rig 32..36
    // across all five conditions, capture 30..36), so 30 is the floor and 36
    // the ceiling: a probe window off the dot reads 0, a larger dot reads more.
    immutable int va = selCountAround(pa), vb = selCountAround(pb);
    foreach (n; [va, vb])
        assert(n >= kVertexModeFloor && n <= kVertexModeCeiling,
            format("[%s] positive control: in VERTEX mode a selected vertex "
                   ~ "must show %d..%d selection-coloured px, got %d / %d — the "
                   ~ "probe is not on the dot and the edge-mode zero below would "
                   ~ "be vacuous", name, kVertexModeFloor, kVertexModeCeiling,
                   va, vb));
    // The unselected dot colour, read live at an unselected vertex's centre
    // (used only by the post-fix floor at the end of the block).
    immutable DHVec3 wu = DHVec3(0.5f, -0.5f, 0.5f);
    immutable int[2] pu = front ? frontPx(wu) : perspPx(wu);
    immutable Px unselCentre = probe([pu])[0];

    // ---- the switch, by key 2 --------------------------------------------
    pressEdgeKey();
    assert(selType() == "edge",
        format("[%s] rig: key 2 did not switch to edge mode (selType %s)",
               name, selType()));
    // Population floor: the selection SURVIVES the switch (captured: 2
    // vertices). Without it "nothing selected is drawn" is vacuous.
    auto sv = selectedVertices();
    assert(sv.length == 2 && ((sv[0] == a && sv[1] == b) || (sv[0] == b && sv[1] == a)),
        format("[%s] the vertex selection must survive the switch to edge "
               ~ "mode as vertices %d and %d, got %s", name, a, b, sv));

    immutable int ea = selCountAround(pa), eb = selCountAround(pb);
    writeln(format("[%s] vertex mode %d / %d, edge mode %d / %d "
                   ~ "selection-coloured px", name, va, vb, ea, eb));
    assert(ea == expectedEdgePx && eb == expectedEdgePx,
        format("[%s] selected vertex dot drawn in edge mode: %d / %d "
               ~ "selection-coloured px around the two selected vertices, the "
               ~ "capture reads %d", name, ea, eb, expectedEdgePx));

    // ---- post-fix floor (not reached on HEAD in the wireframe blocks) -----
    // Under a style that draws dots, the dot is still there in edge mode, in
    // the UNSELECTED colour (capture: centre pixel = the unselected dot).
    if (style == "wireframe") {
        foreach (p; [pa, pb]) {
            immutable Px centre = probe([p])[0];
            assert(centre.valid && unselCentre.valid
                && abs(centre.r - unselCentre.r) <= 2
                && abs(centre.g - unselCentre.g) <= 2
                && abs(centre.b - unselCentre.b) <= 2,
                format("[%s] in edge mode the selected vertex must still be "
                       ~ "drawn as an UNSELECTED dot %s, its centre reads %s",
                       name, unselCentre, centre));
        }
    }
}

/// Our side of the positive control, see the block above.
private enum int kVertexModeFloor   = 30;
private enum int kVertexModeCeiling = 36;

/// The five captured conditions, in the order this file runs them: the
/// three that are green on HEAD first, then the two wireframe ones.
private immutable string[5] kOrder =
    ["psp_default", "psp_shade", "fnt_shade", "psp_wire", "fnt_wire"];

unittest {
    import std.file : readText;
    import std.path : buildPath, dirName;
    enum repoRoot = dirName(dirName(__FILE_FULL_PATH__));
    auto fx = parseJSON(readText(buildPath(repoRoot, "tests", "fixtures",
        "editor_display_laws_w17.json")))["vertex_dots_in_edge_mode"];
    auto conds = fx["conditions"].object;
    // Population floor on the fixture: exactly the five captured conditions,
    // two selected vertices each.
    assert(conds.length == 5,
        format("fixture: expected 5 captured conditions, got %d", conds.length));
    assert(fx["rig"]["selected_vertices"].array.length == 2,
        "fixture: expected 2 selected vertices in the rig");

    scope (exit) {
        cmdOk(`viewport.view Perspective`);
        cmdOk(commandBody("viewport.displayStyle", `"shaded"`));
    }
    foreach (name; kOrder) {
        assert(name in conds, "fixture: missing condition " ~ name);
        auto rows = conds[name].array;
        assert(rows.length == 2, "fixture: expected 2 vertex rows for " ~ name);
        long want = -1;
        foreach (r; rows) {
            immutable long e = r["selection_coloured_px_edge_mode"].integer;
            assert(want < 0 || want == e, "fixture: rows disagree for " ~ name);
            want = e;
            assert(r["selection_coloured_px_vertex_mode"].integer >= kVertexModeFloor,
                "fixture: a captured vertex-mode count is below our floor");
        }
        immutable bool front = name[0 .. 3] == "fnt";
        immutable string style = name[4 .. $] == "wire" ? "wireframe"
            : name[4 .. $] == "shade" ? "shaded" : null;
        runCondition(name, style, front, cast(int)want);
    }
}
