// test_view_grid_facing.d — task 9451: under the AUTO work plane an ortho view
// draws the grid in the most-facing world plane (capture K-D, cell D3: front
// ortho shows a full 0/90° lattice, not an edge-on XZ line; top is the control).
//
// The witness is pixels on an EMPTY scene: a scan line away from the horizon
// crosses the lattice many times when the grid faces the view and never when
// it is the edge-on XZ grid. The scan runs both ways (a row and a column), so
// a lattice drawn in only one direction cannot pass. Perspective is not
// covered here: its law (ground grid + a coarse facing lattice) is uncaptured;
// the pure plane choice is pinned in tests/unit/ui/grid_plane_test.d.
module test_view_grid_facing;

import http_client : getJson, postJson, frameFence;
import http_command_helpers : commandBody;
import drag_helpers : viewportFromCameraMatrices, Viewport;

import std.format : format;
import std.json;
import std.stdio : writefln;

void main() {}

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
    auto r = scan("Top");
    assert(r[0] >= 3 && r[1] >= 3,
        format("Top: the grid must be a lattice both ways, got row %d / column %d", r[0], r[1]));
}

unittest { // Front — D3: the facing (XY) lattice, not the edge-on ground grid
    auto r = scan("Front");
    assert(r[0] >= 3 && r[1] >= 3,
        format("Front: the grid must face the view (a lattice both ways), got "
               ~ "row %d / column %d", r[0], r[1]));
}

unittest { // Right — the same law on the third axis (the YZ plane)
    auto r = scan("Right");
    assert(r[0] >= 3 && r[1] >= 3,
        format("Right: the grid must face the view (a lattice both ways), got "
               ~ "row %d / column %d", r[0], r[1]));
}

unittest { // Front under a PINNED ground plane: the grid is the stage's (edge-on) —
    // the renderer reads the pinned stage, not only the view.
    auto r = scan("Front", "worldY");
    assert(r[0] == 0 && r[1] == 0,
        format("Front, ground plane pinned: the grid must be the pinned XZ plane "
               ~ "(edge-on, no lattice), got row %d / column %d", r[0], r[1]));
}

/// The settled whole-frame digest of cell 0 (two equal consecutive reads).
string frameHash(string view, string[] pin = null) {
    import core.thread : Thread;
    import core.time : msecs;
    cmd(commandBody("scene.reset", `{"empty":true}`));
    foreach (a; pin) cmd("tool.pipe.attr workplane " ~ a);
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

unittest { // The fade is radial IN the grid's plane: on an empty scene, Front's
    // facing lattice is Top's ground lattice turned about X — same lines, same
    // axis colours (local X red, local Z blue), same fade — so the two frames
    // are byte-identical. A fade read from world xz fades Front along x only
    // (measured: digests differ; the top-row scan differs by 1 level).
    immutable top = frameHash("Top"), front = frameHash("Front");
    writefln("frame digests: Top %s Front %s", top, front);
    assert(top == front,
        format("Front's frame %s differs from Top's %s: the facing grid must fade "
               ~ "radially in its own plane", front, top));
}

unittest { // ...and from the grid's own ORIGIN: a ground plane pinned 2 below the
    // origin draws, in Top ortho, the very frame of the auto ground grid. A fade
    // measured from the world origin would dim it by the 2-unit offset.
    immutable top = frameHash("Top"), low = frameHash("Top", ["mode worldY", "cenY -2"]);
    writefln("frame digests: Top %s Top pinned at y -2 %s", top, low);
    assert(top == low,
        format("Top with the ground plane pinned at y -2 drew %s, the auto ground grid %s: "
               ~ "the fade must be measured from the grid's own origin", low, top));
}
