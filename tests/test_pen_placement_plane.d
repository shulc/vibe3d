// Polygon pen click plane, against the captured cells of
// tests/fixtures/pen_placement.json (A0, E, B0, B1, B2): point 0 lands on the
// plane through the camera focus; a later click lands on the plane parallel to
// it through the CURRENT point and is inserted right after it; a dragged point
// moves on the plane through its own position. Positions are world (the
// automatic work plane is the identity frame), so a typed posY 0.5 IS y 0.5.
//
// The focus sits at y = 1 so every rival height (focus plane 1.0, typed value
// read relative to the focus 1.5, first / next / previous point) differs from
// the captured one by >= 0.2. All five cells run and report together; the
// must-stay-green cell (A0) is checked first.

import drag_helpers : Vec3;
import pen_rig_helpers;
import std.array : join;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : abs;

void main() {}

private enum double kTolY = 1e-3;   // heights are typed or anchored exactly
private enum double kTolXZ = 0.02;  // clicked x/z round to whole pixels

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger : v.floating;
}
private Vec3 xz(JSONValue a) {
    return Vec3(cast(float)num(a.array[0]), 0, cast(float)num(a.array[1]));
}

/// Compare the committed vertices with the cell's expected list; `skipXZ`
/// names the point whose x/z is not scored (the dragged point).
private string[] compare(string cell, Vec3[] got, JSONValue expected,
                         int skipXZ = -1) {
    auto want = expected.array;
    if (got.length != want.length)
        return [format("%s: %d vertices committed, expected %d", cell,
                       got.length, want.length)];
    string[] fails;
    foreach (i, w; want) {
        auto e = w.array;
        if (abs(got[i].y - num(e[1])) > kTolY)
            fails ~= format("%s: p%d.y = %.4f, expected %.4f", cell, i,
                            got[i].y, num(e[1]));
        if (cast(int)i != skipXZ && (abs(got[i].x - num(e[0])) > kTolXZ ||
                                     abs(got[i].z - num(e[2])) > kTolXZ))
            fails ~= format("%s: p%d.xz = (%.3f, %.3f), expected (%.3f, %.3f)",
                            cell, i, got[i].x, got[i].z, num(e[0]), num(e[2]));
    }
    return fails;
}

private string[] currentAfter(string cell, JSONValue expected) {
    const cur = penAttrValue("currentPoint");
    const want = num(expected["current_after"]);
    return cur == want ? null
        : [format("%s: currentPoint after the gesture = %s, expected %s",
                  cell, cur, want)];
}

private string[] commitAndCompare(string cell, JSONValue expected, int skipXZ = -1) {
    penCommand("tool.set pen off");
    return compare(cell, readVerts(), expected["vertices"], skipXZ);
}

private void typeHeight(int point, double y) {
    penAttr("currentPoint", point);
    penAttr("posY", y);
}

unittest {
    auto fx = parseJSON(import("fixtures/pen_placement.json"));
    auto cells = fx["cells"];
    const focus = Vec3(0, cast(float)num(fx["rig"]["focus_plane_y"]), 0);
    assert(focus.y == 1.0f, "rig premise: the focus plane must sit at y 1");
    string[] fails;

    // A0 (must stay green): three clicks on the focus plane.
    {
        auto c = cells["A0"];
        penRigEmpty(focus);
        Vec3[] pts;
        foreach (p; c["clicks_xz"].array) pts ~= xz(p);
        clickWorld(pts);
        fails ~= commitAndCompare("A0", c["expected"]);
    }
    // E: point 0 typed to y 0.5; the next two clicks land through it.
    {
        auto c = cells["E"];
        auto k = c["clicks_xz"].array;
        penRigEmpty(focus);
        clickWorld(xz(k[0]));
        penAttr("posY", 0.5);
        clickWorld(xz(k[1]), xz(k[2]));
        fails ~= commitAndCompare("E", c["expected"]);
    }
    // B0: heights 0.2 / 0.5 / 0.8, the last-edited point is p1, current 2.
    {
        auto c = cells["B0_append"];
        auto k = c["clicks_xz"];
        penRigEmpty(focus);
        clickWorld(xz(k["p0"]), xz(k["p1"]), xz(k["p2"]));
        typeHeight(2, 0.8); typeHeight(0, 0.2); typeHeight(1, 0.5);
        penAttr("currentPoint", 2);
        clickWorld(xz(k["extra"]));
        fails ~= currentAfter("B0", c["expected"]);
        fails ~= commitAndCompare("B0", c["expected"]);
    }
    // B1: same heights, current 0: the click is inserted at index 1.
    {
        auto c = cells["B1_insert"];
        auto k = c["clicks_xz"];
        penRigEmpty(focus);
        clickWorld(xz(k["p0"]), xz(k["p1"]), xz(k["p2"]));
        typeHeight(1, 0.5); typeHeight(2, 0.8); typeHeight(0, 0.2);
        penAttr("currentPoint", 0);
        clickWorld(xz(k["extra"]));
        fails ~= currentAfter("B1", c["expected"]);
        fails ~= commitAndCompare("B1", c["expected"]);
    }
    // B2: p1 (y 0.5) dragged while the last / current point is p2 (y 0.8).
    {
        auto c = cells["B2_drag"];
        auto k = c["clicks_xz"];
        penRigEmpty(focus);
        clickWorld(xz(k["p0"])); penAttr("posY", 0.2);
        clickWorld(xz(k["p1"])); penAttr("posY", 0.5);
        clickWorld(xz(k["p2"])); penAttr("posY", 0.8);
        dragWorld(xz(k["p1"]), cast(int)num(c["drag_px"]));
        fails ~= currentAfter("B2", c["expected"]);
        fails ~= commitAndCompare("B2", c["expected"],
            cast(int)num(c["expected"]["dragged_point_index"]));
    }

    assert(fails.length == 0, "pen placement cells:\n" ~ fails.join("\n"));
}
