// Polygon pen wall mode (wave plan S9) against the captured cells of
// tests/fixtures/pen_wall.json. With `wall` on, the stroke becomes a strip of
// quads in the stroke plane: per point a LEFT / RIGHT pair, left =
// normalize(cross(n_cam, d)) with n_cam the plane normal toward the camera;
// inner L = p + w·m, R = p; outer L = p, R = p − w·m; both ±w·m. Interior
// points mitre without a limit, open ends take the end segment's
// perpendicular; quads [L_i, R_i, R_i+1, L_i+1]; `close` adds the closing quad
// on the first pair. Offset is clamped at 0 and 0 builds nothing (no history
// row); the facing flag is not decided (reads 0 after the stroke); the mirror
// strip is the reflection of the built wall listed [m(R_i), m(L_i)].
//
// Rig: top (or bottom) ortho, focus on y = 1, 300 px/m (the captured 440
// cannot fit the D3 strip, x −0.9 .. 0.9, in our viewport; 300 keeps the
// 0.005 m placement quantum — asserted per cell from our pixel size — so every
// clicked fixture position is a lattice value and positions compare to 1e-4).
// Counts and rings are exact. The D5 inset / segments cells sit under
// `evidence` and are not asserted (deferred). Ours-only cells
// `switch-D1_open_inner_ccw` / `switch-D6c_offset_zero` end the stroke by a
// switch to another tool (the prepared deactivate door) instead of the drop
// (the tool's own commit): the same mesh and rows, since both call the one
// builder with the latched plane normal. `VIBE3D_CELL=<id>` runs one
// cell alone (the population floor holds for the full run only).

import drag_helpers : Vec3;
import http_client : getJson, postJson;
import pen_rig_helpers;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;
import std.process : environment;

void main() {}

private enum double kTol = 1e-4;
private enum double kPpm = 300;

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating
         : v.type == JSONType.true_ ? 1 : v.type == JSONType.false_ ? 0 : double.nan;
}
private Vec3 p(double x, double z, double y = 1) {
    return Vec3(cast(float)x, cast(float)y, cast(float)z);
}
private Vec3[] verts(JSONValue a) {
    Vec3[] r;
    foreach (v; a.array)
        r ~= Vec3(cast(float)num(v[0]), cast(float)num(v[1]), cast(float)num(v[2]));
    return r;
}
private long[][] rings(JSONValue a) {
    long[][] r;
    foreach (f; a.array) {
        long[] ring;
        foreach (e; f.array) ring ~= e.integer;
        r ~= ring;
    }
    return r;
}

/// A cell's settings, written before the first click (the fixture's script).
private struct Cell {
    string id, wall;
    double[] offsets;           // written in order; the last one stands
    bool close, mergeOff, symX, bottom, flip1;
}

private immutable Cell[] kCells = [
    // ===== must stay green: wall off ========================================
    Cell("control_open_no_wall", "off", [0]),
    Cell("control_open_no_wall_bottom_view", "off", [0], false, false, false, true),
    // ===== must turn ========================================================
    Cell("D1_open_inner_ccw", "inner", [0.1]),
    Cell("D1_open_inner_cw", "inner", [0.1]),
    Cell("D1_open_outer_ccw", "outer", [0.1]),
    Cell("D1_open_outer_cw", "outer", [0.1]),
    Cell("D1_open_both_ccw", "both", [0.1]),
    Cell("D1_open_both_cw", "both", [0.1]),
    Cell("D1x_open_inner_first_corner_reflex", "inner", [0.1]),
    Cell("D2_closed_inner_cw", "inner", [0.1], true),
    Cell("D2_closed_inner_ccw", "inner", [0.1], true),
    Cell("D2_closed_outer_cw", "outer", [0.1], true),
    Cell("D2_closed_both_cw", "both", [0.1], true),
    Cell("D3_open_inner_symmetry_x", "inner", [0.1], false, false, true),
    Cell("D4_closed_inner_merge_off", "inner", [0.1], true, true),
    Cell("D6_offset_negative", "inner", [-0.1]),
    Cell("D6b_offset_negative_after_positive", "inner", [0.1, -0.1]),
    Cell("D6c_offset_zero", "inner", [0]),
    Cell("D7_facing_flag_set_before_stroke", "inner", [0.1], false, false, false, false, true),
    Cell("D8_open_inner_bottom_view", "inner", [0.1], false, false, false, true),
];

/// The fixture cell's clicks: its `click (x,z) …` line, or under the bottom
/// view the bottom control's stroke points (the same pane pixels).
private Vec3[] clicks(JSONValue cells, in Cell c) {
    if (c.bottom)
        return verts(cells["control_open_no_wall_bottom_view"]["expected"]["vertices"]);
    import std.algorithm : startsWith;
    import std.conv : to;
    import std.regex : matchAll, regex;
    Vec3[] r;
    foreach (line; cells[c.id]["script"].array)
        if (line.str.startsWith("click "))
            foreach (m; matchAll(line.str, regex(`\((-?[0-9.]+),(-?[0-9.]+)\)`)))
                r ~= p(m[1].to!double, m[2].to!double);
    return r;
}

private size_t depth() { return getJson("/api/history")["undo"].array.length; }
/// The stroke rows recorded at or after history depth `from` (a tool switch
/// records its own rows beside them).
private size_t strokeRows(size_t from) {
    import std.algorithm : canFind;
    size_t n;
    foreach (e; getJson("/api/history")["undo"].array[from .. $])
        n += e["label"].str.canFind("Pen Polygon");
    return n;
}
private double attr(string name) {
    auto r = postJson("/api/command", "tool.attr pen " ~ name ~ " ?");
    assert(r["status"].str == "ok", "attr query " ~ name ~ " failed: " ~ r.toString);
    return num(r["value"]);
}

/// Empty top / bottom view at 300 px/m, focus on the stroke's centre, snapping
/// off, symmetry X (or off), the pen armed with the cell's settings.
private void rig(in Cell c, Vec3[] pts) {
    penSceneEmpty(c.bottom ? "Bottom" : "Top");
    double fx = 0, fz = 0;
    foreach (q; pts) { fx += q.x; fz += q.z; }
    penCameraAt(c.symX ? p(0, fz / pts.length) : p(fx / pts.length, fz / pts.length), kPpm);
    const px = num(getJson("/api/viewport/display")["cells"].array[0]["grid"]["pixelSize"]);
    assert(px > 0.002 && px <= 0.005, format("%s rig: our pixel size %.9g is outside "
        ~ "the bracket (0.002, 0.005] of the 0.005 quantum", c.id, px));
    penCommand("tool.pipe.attr snap enabled false");
    penCommand("tool.pipe.attr symmetry enabled " ~ (c.symX ? "true" : "false"));
    penCommand("tool.pipe.attr symmetry axis x");
    penCommand("tool.pipe.attr symmetry offset 0");
    penCommand("tool.pipe.attr symmetry useWorkplane false");
    penCommand("tool.set pen on");
    penCommand("tool.attr pen type polygons");
    penCommand("tool.attr pen makeQuads false");
    penCommand("tool.attr pen wall " ~ c.wall);
    foreach (o; c.offsets) penAttr("offset", o);
    if (c.wall != "off") penCommand("tool.attr pen close " ~ (c.close ? "true" : "false"));
    penCommand("tool.attr pen merge " ~ (c.mergeOff ? "false" : "true"));
    penCommand("tool.attr pen flip " ~ (c.flip1 ? "true" : "false"));
}
private void drop() { penCommand("tool.set pen off"); }

/// The mesh against the cell's `expected` (counts and rings exactly, positions
/// to 1e-4); null when it matches.
private string[] compare(string cell, JSONValue exp) {
    auto j = getJson("/api/model");
    auto got = verts(j["vertices"]);
    auto gotF = rings(j["faces"]);
    auto want = verts(exp["vertices"]);
    auto wantF = rings(exp["polygons"]);
    if (got.length != want.length || gotF != wantF)
        return [format("%s: %s vertices, faces %s; expected %s, faces %s", cell,
                       got.length, gotF, want.length, wantF)];
    string[] bad;
    foreach (i, w; want) {
        const g = got[i];
        if (!(abs(g.x - w.x) <= kTol && abs(g.y - w.y) <= kTol && abs(g.z - w.z) <= kTol))
            bad ~= format("v%s (%.6f, %.6f, %.6f) vs (%.6f, %.6f, %.6f)", i,
                          g.x, g.y, g.z, w.x, w.y, w.z);
    }
    return bad.length ? [format("%s: %-(%s; %)", cell, bad)] : null;
}
// A float attribute reads back as its float value (0.1 as 0.100000001…).
private string[] expect(string cell, string what, double got, double want) {
    return abs(got - want) <= 1e-6 ? null
         : [format("%s: %s %s, expected %s", cell, what, got, want)];
}

/// Run one cell, ending the stroke by the tool drop (the tool's own commit)
/// or by a switch to another tool (the prepared deactivate door); the mesh,
/// readbacks and history rows against the fixture.
private string[] run(JSONValue cells, in Cell c, bool bySwitch) {
    const id = (bySwitch ? "switch-" : "") ~ c.id;
    auto cell = cells[c.id];
    auto pts = clicks(cells, c);
    assert(pts.length == (c.close ? 4 : 5), id ~ ": fixture premise: click count");
    rig(c, pts);
    string[] fails = expect(id, "offset read back", attr("offset"),
                            num(cell["readback"]["offset"]));
    const before = depth();
    clickWorld(pts);
    fails ~= expect(id, "facing flag after the stroke", attr("flip"),
                    num(cell["readback"]["facing_flag"]));
    if (bySwitch) {
        penCommand("tool.set move on");
        penCommand("tool.set move off");
    } else drop();
    fails ~= compare(id, cell["expected"]);
    // One history row per built stroke; an empty build records none.
    fails ~= expect(id, "stroke rows", strokeRows(before),
                    cell["expected"]["vertices"].array.length ? 1 : 0);
    return fails;
}

unittest {
    auto cells = parseJSON(import("fixtures/pen_wall.json"))["cells"];
    const only = environment.get("VIBE3D_CELL", "");
    string[] fails;
    int ran;
    assert(cells.object.length == kCells.length, format("fixture premise: %s scored "
        ~ "cells, the table lists %s", cells.object.length, kCells.length));
    foreach (c; kCells) {
        if (only.length && only != c.id) continue;
        fails ~= run(cells, c, false);
        ++ran;
    }
    // Ours-only: a tool switch ends the stroke through the prepared door, the
    // drop through the tool's own commit; both call the one builder, so a
    // built and an empty wall land alike.
    foreach (c; kCells) {
        if (c.id != "D1_open_inner_ccw" && c.id != "D6c_offset_zero") continue;
        if (only.length && only != "switch-" ~ c.id) continue;
        fails ~= run(cells, c, true);
        ++ran;
    }

    // Leave the remembered values as found.
    penCommand("tool.set pen on");
    penCommand("tool.attr pen wall off");
    penAttr("offset", 0);
    penCommand("tool.attr pen flip false");
    drop();
    assert(ran == (only.length ? 1 : 22), format("ran %s cells, pinned 22 (1 under %s)",
                                                 ran, only));
    assert(fails.length == 0, format("%s failure(s): %-(%s | %)", fails.length, fails));
}
