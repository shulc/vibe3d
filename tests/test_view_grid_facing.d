// test_view_grid_facing.d — task 9451: under the AUTO work plane an ortho view
// draws the grid in the most-facing world plane (capture K-D, cell D3: front
// ortho shows a full 0/90° lattice, not an edge-on XZ line; top is the control).
//
// The witness is pixels on an EMPTY scene: a scan line away from the horizon
// crosses the lattice many times when the grid faces the view and never when
// it is the edge-on XZ grid. The scan runs both ways (a row and a column), so
// a lattice drawn in only one direction cannot pass. Perspective (task 9509,
// K-GR GR_P): the second, work-plane lattice — cells `persp` at the bottom;
// the pure plane choice is pinned in tests/unit/ui/grid_plane_test.d.
module test_view_grid_facing;

import http_client : getJson, postJson, frameFence;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, Viewport, Vec3, projectToWindow;

import std.format : format;
import std.json;
import std.stdio : writefln;

void main() {}

/// VIBE3D_CELL=<name> runs one cell alone (a mutation's own witness).
bool cellOn(string id) {
    import std.process : environment;
    immutable e = environment.get("VIBE3D_CELL", "");
    return e.length == 0 || e == id;
}

void cmd(string line) {
    auto r = postJson("/api/command", line);
    assert(r["status"].str == "ok", "/api/command '" ~ line ~ "' failed: " ~ r.toString);
}

int[3][] probe(int[2][] pts) {
    string q;
    foreach (i, p; pts) q ~= format("%s%d,%d", i ? ";" : "", p[0], p[1]);
    auto j = getJson(format("/api/viewport/probe?cell=0&points=%s", q));
    assert(j["renders"].type == JSONType.true_, "probe: cell 0 must be rendering");
    int[3][] o;
    foreach (e; j["points"].array) {
        assert(("error" in e) is null, "probe point refused: " ~ e.toString);
        o ~= [cast(int)e["r"].integer, cast(int)e["g"].integer, cast(int)e["b"].integer];
    }
    assert(o.length == pts.length, "probe: point count");
    return o;
}

/// The number of maximal runs of pixels that differ from the scan's most
/// common colour by more than 4 in any channel: one per crossed grid line.
size_t lineRuns(int[3][] px) {
    import std.math : abs;
    size_t[int[3]] freq;
    foreach (c; px) ++freq[c];
    int[3] mode;
    size_t best;
    foreach (c, n; freq) if (n > best) { best = n; mode = c; }
    size_t runs;
    bool inRun;
    foreach (c; px) {
        immutable bool off = abs(c[0] - mode[0]) > 4 || abs(c[1] - mode[1]) > 4
                          || abs(c[2] - mode[2]) > 4;
        if (off && !inRun) ++runs;
        inRun = off;
    }
    return runs;
}

/// Row at a quarter of the height and column at a quarter of the width, both
/// over most of the other dimension's span and clear of the horizon. At the
/// test cell (650x544) a facing lattice crosses 9 / 5 lines; the edge-on
/// ground grid 0 / 0 (measured on the parent commit).
size_t[2] scan(string view, string pin = null) {
    cmd(commandBody("scene.reset", `{"empty":true}`));
    if (pin !is null) cmd("tool.pipe.attr workplane mode " ~ pin);
    cmd("viewport.view " ~ view);
    frameFence(null, 3);
    Viewport vp = viewportFromCameraMatrices();
    immutable int W = vp.width, H = vp.height;
    int[2][] row, col;
    foreach (x; W / 5 .. 4 * W / 5) row ~= [x, H / 4];
    foreach (y; H / 20 .. 9 * H / 20) col ~= [W / 4, y];
    size_t[2] r = [lineRuns(probe(row)), lineRuns(probe(col))];
    writefln("%s: %dx%d, row y=%d crosses %d lines, column x=%d crosses %d",
             view, W, H, H / 4, r[0], W / 4, r[1]);
    return r;
}

unittest { // Top — the control: the ground grid faces this view on every build
    if (!cellOn("lattice")) return;
    auto r = scan("Top");
    assert(r[0] >= 3 && r[1] >= 3,
        format("Top: the grid must be a lattice both ways, got row %d / column %d", r[0], r[1]));
}

unittest { // Front — D3: the facing (XY) lattice, not the edge-on ground grid
    if (!cellOn("lattice")) return;
    auto r = scan("Front");
    assert(r[0] >= 3 && r[1] >= 3,
        format("Front: the grid must face the view (a lattice both ways), got "
               ~ "row %d / column %d", r[0], r[1]));
}

unittest { // Right — the same law on the third axis (the YZ plane)
    if (!cellOn("lattice")) return;
    auto r = scan("Right");
    assert(r[0] >= 3 && r[1] >= 3,
        format("Right: the grid must face the view (a lattice both ways), got "
               ~ "row %d / column %d", r[0], r[1]));
}

unittest { // Front under a PINNED ground plane: the grid is the stage's (edge-on) —
    // the renderer reads the pinned stage, not only the view.
    if (!cellOn("pinned")) return;
    auto r = scan("Front", "worldY");
    assert(r[0] == 0 && r[1] == 0,
        format("Front, ground plane pinned: the grid must be the pinned XZ plane "
               ~ "(edge-on, no lattice), got row %d / column %d", r[0], r[1]));
}

/// The settled whole-frame digest of cell 0 (two equal consecutive reads).
string frameHash(string view) {
    import core.thread : Thread;
    import core.time : msecs;
    cmd(commandBody("scene.reset", `{"empty":true}`));
    cmd("viewport.view " ~ view);
    frameFence(null, 3);
    string prev;
    foreach (i; 0 .. 8) {
        auto j = getJson("/api/viewport/probe?cell=0&hash=1");
        assert(j["renders"].type == JSONType.true_, "probe: cell 0 must be rendering");
        if (i > 0 && j["hash"].str == prev) return prev;
        prev = j["hash"].str;
        Thread.sleep(200.msecs);
    }
    assert(false, view ~ ": the frame digest never settled");
}

unittest { // One ortho drawer: on an empty scene Front's facing lattice is Top's
    // turned about X — same lines, same uncoloured origin lines, no fade — so
    // the two frames are byte-identical (capture K-GR GR_C / GR_F).
    if (!cellOn("frames")) return;
    immutable top = frameHash("Top"), front = frameHash("Front");
    writefln("frame digests: Top %s Front %s", top, front);
    assert(top == front,
        format("Front's frame %s differs from Top's %s: the ortho grid must not "
               ~ "depend on which world axes it lies along", front, top));
}

// ---------------------------------------------------------------------------
// The ortho grid's style (capture K-GR, fixture K-GR.json "ortho-style" and
// "ortho-fade-GR_F"): every pixel of a full row and a full column — edges
// included — is the background, a minor line, a major line or an origin line,
// each EXACTLY its captured colour: opaque, unfaded, origin lines black.
// ---------------------------------------------------------------------------
immutable int[3] kBg = [92, 102, 107], kMinor = [83, 92, 97],
                 kMajor = [65, 72, 75], kOrigin = [0, 0, 0];

void stylePalette(string view) {
    cmd(commandBody("scene.reset", `{"empty":true}`));
    cmd("viewport.view " ~ view);
    // Zoomed out to ~26 px cells, so the majors at +-10 steps are in view.
    auto cr = postJson("/api/camera?viewport=0", `{"focus":{"x":0,"y":0,"z":0},"distance":5}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    frameFence(null, 3);
    Viewport vp = viewportFromCameraMatrices();
    immutable int W = vp.width, H = vp.height;
    int[2][] row, col;
    foreach (x; 0 .. W) row ~= [x, H / 4];      // crosses the vertical origin line
    foreach (y; 0 .. H) col ~= [W / 4, y];      // crosses the horizontal one
    foreach (scanName, px; ["row": probe(row), "column": probe(col)]) {
        size_t[4] n;
        foreach (i, c; px) {
            if      (c == kBg)     ++n[0];
            else if (c == kMinor)  ++n[1];
            else if (c == kMajor)  ++n[2];
            else if (c == kOrigin) ++n[3];
            else assert(false, format("%s %s: pixel %d reads %s — not the background, "
                ~ "a minor, a major or a black origin line (faded or coloured grid)",
                view, scanName, i, c));
        }
        writefln("%s %s: bg %d minor %d major %d origin %d", view, scanName, n[0], n[1], n[2], n[3]);
        // Measured at the 650x544 test cell: row 22 minor / 2 major / 1 origin
        // pixel, column 18 / 2 / 1 (the origin line is ONE pixel wide).
        immutable size_t minor = scanName == "row" ? 22 : 18;
        assert(n[1] == minor && n[2] == 2 && n[3] == 1,
            format("%s %s: expected %d minor, 2 major and 1 origin-line pixel, got %s",
                   view, scanName, minor, n));
    }
}

unittest { if (cellOn("style")) stylePalette("Top"); }
unittest { if (cellOn("style")) stylePalette("Front"); }
unittest { if (cellOn("style")) stylePalette("Right"); }

// ---------------------------------------------------------------------------
// GR_D: the ortho grid is an UNDERLAY — geometry hides it whether it lies in
// front of the grid plane or behind it. The default cube's +Z face, seen in
// Front: at z = +0.5 (in front of the z = 0 grid plane) and moved to z = -0.5
// (behind it). A row across the face's interior must be one flat fill.
// ---------------------------------------------------------------------------
size_t faceRowRuns(double posZ) {
    cmd(commandBody("scene.reset", "{}"));
    cmd(format("layer.attr 0 pos.z %g", posZ));
    cmd("viewport.view Front");
    frameFence(null, 3);
    Viewport vp = viewportFromCameraMatrices();
    float x0, y0, x1, y1;
    assert(projectToWindow(Vec3(-0.4f, 0.27f, 0), vp, x0, y0)
        && projectToWindow(Vec3(0.4f, 0.27f, 0), vp, x1, y1), "rig: projection");
    int[2][] row;
    foreach (x; cast(int) x0 - vp.x .. cast(int) x1 - vp.x) row ~= [x, cast(int) y0 - vp.y];
    auto px = probe(row);
    assert(px.length >= 100 && px[0] != kBg, format("rig: the row must lie on the face, got %s", px[0]));
    size_t runs = lineRuns(px);
    writefln("face at z %+g: %d px, fill %s, %d grid runs", posZ + 0.5, px.length, px[0], runs);
    return runs;
}

unittest { // GR_D — in front of the plane (the control: depth hid it before too)
    if (!cellOn("underlay")) return;
    immutable r = faceRowRuns(0.0);
    assert(r == 0, format("GR_D: the grid must not show over a face in front of its plane, %d runs", r));
}

unittest { // GR_D — behind the plane
    if (!cellOn("underlay")) return;
    immutable r = faceRowRuns(-1.0);
    assert(r == 0, format("GR_D: the grid must not show over a face behind its plane "
                          ~ "(an underlay), %d runs", r));
}

// ---------------------------------------------------------------------------
// GR_P (task 9509): perspective draws a SECOND lattice beside the ground — the
// auto work plane through the focus rounded to ten grid steps (1 m at the
// 0.1 m step), uncoloured and lighter than the background, lines every 0.5 m,
// majors every 1 m, its world-axis lines brightest (fixture K-GR.json
// "persp-lattices-GR_P_z"). Rig: a Z-facing camera with the focus at z = 0.7,
// so the plane is z = 1 (rounded) — not 0.7 (the raw focus) nor 0 (origin);
// it looks slightly UP, so no probe ray above the eye meets the ground grid.
// ---------------------------------------------------------------------------
struct PerspRig { Viewport vp; double step; }

PerspRig perspRig() {
    cmd(commandBody("scene.reset", `{"empty":true}`));
    cmd("workplane.reset");
    cmd("viewport.view Perspective");
    auto cr = postJson("/api/camera?viewport=0", `{"azimuth":0.15,"elevation":-0.1,`
        ~ `"focus":{"x":0.07,"y":1.0,"z":0.7},"distance":3}`);
    assert(cr["status"].str == "ok", "camera: " ~ cr.toString);
    frameFence(null, 3);
    PerspRig r;
    r.vp = viewportFromCameraMatrices();
    auto g = getJson("/api/viewport/display")["cells"].array[0]["grid"]["size"];
    r.step = g.type == JSONType.integer ? g.integer : g.floating;
    import std.math : abs;
    assert(abs(r.step - 0.1) < 1e-6, format("rig: the grid step must be 0.1 m, got %s", r.step));
    immutable bz = abs(r.vp.view[10]);
    assert(bz > abs(r.vp.view[2]) && bz > abs(r.vp.view[6]), "rig: the camera must face Z");
    return r;
}

/// The brightest pixel (by channel sum) within 3 px of the projection of world
/// point `p`, along the row (or the column when `column`).
int[3] peakNear(Vec3 p, const ref Viewport vp, bool column = false) {
    float x, y;
    assert(projectToWindow(p, vp, x, y), "rig: projection");
    immutable int cx = cast(int) x - vp.x, cy = cast(int) y - vp.y;
    int[2][] pts;
    foreach (d; -3 .. 4) pts ~= column ? [cx, cy + d] : [cx + d, cy];
    int[3] best = [-1, -1, -1];
    foreach (c; probe(pts)) if (c[0] + c[1] + c[2] > best[0] + best[1] + best[2]) best = c;
    return best;
}

unittest { // GR_P — the work-plane lattice at the rounded focus, uncoloured and light
    if (!cellOn("persp")) return;
    import std.math : abs;
    auto r = perspRig();
    // The rig separates the three candidate planes on screen.
    float x1, y1, x7, y7, x0, y0;
    projectToWindow(Vec3(0, 1.25f, 1), r.vp, x1, y1);
    projectToWindow(Vec3(0, 1.25f, 0.7f), r.vp, x7, y7);
    projectToWindow(Vec3(0, 1.25f, 0), r.vp, x0, y0);
    writefln("x=0 line at y=1.25: z=1 -> %.1f, z=0.7 -> %.1f, z=0 -> %.1f", x1, x7, x0);
    assert(abs(x1 - x7) > 7 && abs(x1 - x0) > 7, "rig: the candidate planes must be 7+ px apart");
    // Four probes about (0.25, 1.25, 1), mid-screen and at one fade distance:
    // the x = 0 world-axis line, the y = 1 major, the y = 1.5 half-metre line,
    // and the empty point between them.
    immutable axis  = peakNear(Vec3(0,     1.25f, 1), r.vp);
    immutable major = peakNear(Vec3(0.25f, 1.0f,  1), r.vp, true);
    immutable mid   = peakNear(Vec3(0.25f, 1.5f,  1), r.vp, true);
    immutable off   = peakNear(Vec3(0.25f, 1.25f, 1), r.vp);
    writefln("GR_P: axis %s major %s mid %s off %s (background %s)", axis, major, mid, off, kBg);
    foreach (i; 0 .. 3)
        assert(abs(off[i] - kBg[i]) <= 2,
            format("GR_P: between the 0.5 m lines the plane must be background, got %s", off));
    int[3] lift(int[3] c) { return [c[0] - kBg[0], c[1] - kBg[1], c[2] - kBg[2]]; }
    foreach (name, c; ["axis": axis, "major": major, "mid": mid]) {
        immutable d = lift(c);
        assert(d[0] >= 2 && d[1] >= 2 && d[2] >= 2 && abs(d[0] - d[1]) <= 1,
            format("GR_P: the %s line at z = 1 must be uncoloured and lighter than the "
                 ~ "background, got %s (lift %s)", name, c, d));
    }
    immutable int sa = axis[0] + axis[1] + axis[2], sj = major[0] + major[1] + major[2],
                  sm = mid[0] + mid[1] + mid[2];
    assert(sa > sj && sj > sm,
        format("GR_P: the world-axis line must outshine the 1 m major, the major the "
             ~ "0.5 m line: axis %s major %s mid %s", axis, major, mid));
}
