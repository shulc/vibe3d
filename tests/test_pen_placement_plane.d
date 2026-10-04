// Polygon pen click plane, against the captured cells of
// tests/fixtures/pen_placement.json (A0, E, B0, B1, B2): point 0 lands on the
// plane through the camera focus; a later click lands on the plane parallel to
// it through the CURRENT point and is inserted right after it; a dragged point
// moves on the plane through its own position. Positions are world (the
// automatic work plane is the identity frame), so a typed posY 0.5 IS y 0.5.
//
// The focus sits at y = 1 so every rival height (focus plane 1.0, typed value
// read relative to the focus 1.5, first / next / previous point) differs from
// the captured one by >= 0.2. All cells run and report together; the
// must-stay-green cell (A0) is checked first. Two cells of OUR behaviour
// follow: the pinned plane (unchanged by this law) and the idle hover.

import drag_helpers : Vec3, fetchSnapLast;
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

/// Compare the committed vertices with the cell's expected list (one line per
/// failing cell and coordinate kind); `skipXZ` names the point whose x/z is
/// not scored (the dragged point).
private string[] compare(string cell, Vec3[] got, JSONValue expected,
                         int skipXZ = -1) {
    auto want = expected.array;
    if (got.length != want.length)
        return [format("%s: %d vertices committed, expected %d", cell,
                       got.length, want.length)];
    double[] gotY, wantY;
    bool badY, badXZ;
    foreach (i, w; want) {
        auto e = w.array;
        gotY ~= got[i].y; wantY ~= num(e[1]);
        badY |= abs(got[i].y - num(e[1])) > kTolY;
        badXZ |= cast(int)i != skipXZ && (abs(got[i].x - num(e[0])) > kTolXZ ||
                                          abs(got[i].z - num(e[2])) > kTolXZ);
    }
    string[] fails;
    if (badY)
        fails ~= format("%s: y = %(%.4f %), expected %(%.4f %)", cell, gotY, wantY);
    if (badXZ)
        fails ~= format("%s: x/z off by more than %s (got %s)", cell, kTolXZ, got);
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
        penCommand("tool.set pen off");
        auto got = readVerts();
        fails ~= compare("B2", got, c["expected"]["vertices"],
            cast(int)num(c["expected"]["dragged_point_index"]));
        // Ours: the drag did happen (40 px is > 0.1 m at this zoom).
        if (got.length == 3 && got[1].x - xz(k["p1"]).x < 0.1)
            fails ~= format("B2: the dragged point did not move (x %.3f)", got[1].x);
    }

    // Ours, not captured — a pinned plane keeps today's law until its own
    // capture: every click on the plane through the pinned centre (y 0.3),
    // not through the focus (1.0).
    {
        penRigEmpty(focus);
        penCommand("tool.set pen off");
        penCommand("workplane.edit cenX:0 cenY:0.3 cenZ:0 rotX:0 rotY:0 rotZ:0");
        penCommand("tool.set pen on");
        auto k = cells["A0"]["clicks_xz"].array;
        clickWorld(xz(k[0]), xz(k[1]), xz(k[2]));
        penCommand("tool.set pen off");
        auto got = readVerts();
        if (got.length != 3 || abs(got[0].y - 0.3) > kTolY ||
            abs(got[1].y - 0.3) > kTolY || abs(got[2].y - 0.3) > kTolY)
            fails ~= format("pinned plane: %s, expected 3 points at y 0.3", got);
        penCommand("workplane.reset");
    }
    // An idle hover in a FRONT view resolves on the plane the first click
    // would lock (z through the focus): the published hover point is the
    // cursor's point on that plane, not a cleared result.
    {
        penRigEmpty(focus, "Front");
        penCommand("tool.pipe.attr snap enabled true");
        penCommand("tool.pipe.attr snap types grid");
        hoverWorld(Vec3(0.5, 1.5, 0));
        auto p = fetchSnapLast()["worldPos"].array;
        penCommand("tool.pipe.attr snap enabled false");
        if (abs(num(p[0]) - 0.5) > kTolXZ || abs(num(p[1]) - 1.5) > kTolXZ ||
            abs(num(p[2])) > kTolY)
            fails ~= format("idle hover, front view: hover point (%s, %s, %s), "
                ~ "expected (0.5, 1.5, 0)", num(p[0]), num(p[1]), num(p[2]));
    }

    assert(fails.length == 0, "pen placement cells:\n" ~ fails.join("\n"));
}
