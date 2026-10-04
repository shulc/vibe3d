// Polygon pen facing, against the captured cells of tests/fixtures/pen_facing.json
// (top orthographic view, clicks on the plane y = 1 through the camera focus):
// the tool decides `flip` once, at the click that adds the 3rd point, from the
// triangle (p0, p1, new) against the eye ray at the new point, and never again;
// a user write sticks; every stroke's ring is ordered by one routine. Plus the
// stored rings of the placement cells B0 / B1 / B2 (pen_placement.json) and the
// Make-Quads decision cell. Rings and flags are compared exactly; positions are
// not scored here (our clicks are not quantised — wave plan §7).
//
// Cells that need the background constraint (A3c, A3c-rev) or the in-stroke
// undo (A4d-ctrlz) are not run here; the population floor counts the rest.

import drag_helpers : Vec3, buildDragLog, fetchCamera, playAndWait;
import http_client : getJson, postJson;
import pen_rig_helpers;
import std.algorithm : canFind;
import std.array : join;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;

void main() {}

private double num(JSONValue v) {
    return v.type == JSONType.integer ? cast(double)v.integer
         : v.type == JSONType.uinteger ? cast(double)v.uinteger
         : v.type == JSONType.float_ ? v.floating : double.nan;
}
private Vec3 onPlane(JSONValue a) {
    return Vec3(cast(float)num(a.array[0]), 1, cast(float)num(a.array[1]));
}

/// The pen's flip attr as 0 / 1 (-1 when the answer is not a boolean).
private int flipFlag() {
    auto r = postJson("/api/command", "tool.attr pen flip ?");
    assert(r["status"].str == "ok", "flip query failed: " ~ r.toString);
    auto v = r["value"];
    return v.type == JSONType.true_ ? 1 : v.type == JSONType.false_ ? 0
         : v.type == JSONType.integer ? cast(int)v.integer : -1;
}

/// Drop the tool (commits the stroke) and read the one stored face.
private long[] commitRing(string cell, size_t nverts, ref string[] fails) {
    penCommand("tool.set pen off");
    auto m = getJson("/api/model");
    if (m["vertices"].array.length != nverts || m["faces"].array.length != 1) {
        fails ~= format("%s: %s vertices / %s faces stored, expected %s / 1",
            cell, m["vertices"].array.length, m["faces"].array.length, nverts);
        return null;
    }
    long[] ring;
    foreach (e; m["faces"].array[0].array) ring ~= e.integer;
    return ring;
}

private long[] ints(JSONValue a) {
    long[] r;
    foreach (e; a.array) r ~= e.integer;
    return r;
}

private void expectFlag(string cell, string when, int want, ref string[] fails) {
    const got = flipFlag();
    if (got != want)
        fails ~= format("%s: flip %s = %s, expected %s", cell, when, got, want);
}

private void expectRing(string cell, long[] got, long[] want, ref string[] fails) {
    if (got !is null && got != want)
        fails ~= format("%s: ring %s, expected %s", cell, got, want);
}

/// Press on world point `from`, drag to `to`, release.
private void dragFromTo(Vec3 from, Vec3 to) {
    auto cam = fetchCamera();
    auto a = worldPixel(from), b = worldPixel(to);
    playAndWait(buildDragLog(cam.vpX, cam.vpY, cam.width, cam.height,
        a[0], a[1], b[0], b[1]));
}

private enum Vec3 kFocus = Vec3(0, 1, 0);

/// One fixture case of pen_facing.json; returns its failures.
private string[] runCase(JSONValue c) {
    const name = c["case"].str;
    Vec3[] pts;
    foreach (p; c["clicks_xz_on_plane_y1"].array) pts ~= onPlane(p);
    const nv = c["expected"]["vertices"].array.length;
    auto want = ints(c["expected"]["faces"].array[0]);
    string[] fails;
    penRigEmpty(kFocus);
    switch (name) {
    case "A4e-flip", "A4e-mirror":
        clickWorld(pts[0 .. 3]);
        expectFlag(name, "after point 3",
            cast(int)num(c["flip_attr_after_point3"]), fails);
        clickWorld(pts[3]);
        expectFlag(name, "after point 4",
            cast(int)num(c["flip_attr_after_point4"]), fails);
        break;
    case "A4a-retime":   // point 2 dragged from (0.75, 0.25) to (0.75, -0.75)
        clickWorld(pts);
        const fd = cast(int)num(c["flip_attr_before_and_after_drag"]);
        expectFlag(name, "before the drag", fd, fails);
        dragFromTo(pts[2], Vec3(0.75f, 1, -0.75f));
        expectFlag(name, "after the drag", fd, fails);
        break;
    case "A4c-typed":    // Position Z of point 2 typed to 0.75
        clickWorld(pts);
        const ft = cast(int)num(c["flip_attr_before_and_after_edit"]);
        expectFlag(name, "before the typed edit", ft, fails);
        penAttr("currentPoint", 2);
        penAttr("posZ", 0.75);
        expectFlag(name, "after the typed edit", ft, fails);
        break;
    case "A4b-override": // the user turns flip off after point 3
        clickWorld(pts[0 .. 3]);
        expectFlag(name, "after point 3 (tool decision)", 1, fails);
        penCommand("tool.attr pen flip false");
        expectFlag(name, "after the override",
            cast(int)num(c["flip_attr_after_override"]), fails);
        clickWorld(pts[3]);
        expectFlag(name, "after point 4",
            cast(int)num(c["flip_attr_after_point4"]), fails);
        break;
    default:
        clickWorld(pts);
        if (auto f = "flip_attr_after_stroke" in c.object)
            expectFlag(name, "after the stroke", cast(int)num(*f), fails);
        break;
    }
    expectRing(name, commitRing(name, nv, fails), want, fails);
    return fails;
}

unittest {
    auto fx = parseJSON(import("fixtures/pen_facing.json"));
    auto placement = parseJSON(import("fixtures/pen_placement.json"))["cells"];
    string[] fails;
    size_t ran;

    // Must stay green on the unmodified tool: a stroke whose stored ring is
    // [0..n-1] for a reason other than the decision (a collinear prefix; a
    // dart whose ring starts at 0 by the disagreement rule).
    string[] green;
    foreach (c; fx["cases"].array)
        if (["A1x-n4-collinear", "A2-dart"].canFind(c["case"].str)) {
            green ~= runCase(c); ++ran;
        }
    assert(ran == 2, format("must-stay-green cells ran %s, expected 2", ran));
    assert(green.length == 0, "pen facing (must stay green): " ~ green.join(" | "));

    // Every other top-view case of the fixture.
    size_t skipped;
    foreach (c; fx["cases"].array) {
        const name = c["case"].str;
        if (["A1x-n4-collinear", "A2-dart"].canFind(name)) continue;
        if (["A3c-persp-clicked", "A3c-rev", "A4d-ctrlz"].canFind(name)) {
            ++skipped; continue;
        }
        fails ~= runCase(c); ++ran;
    }
    assert(skipped == 3, format("skipped %s fixture cases, expected 3", skipped));

    // Placement cells B0 / B1 / B2: the same scripts as test_pen_placement_plane,
    // scored on the stored ring. The decision is taken at click 3, before any
    // height is typed.
    auto rings = fx["placement_rings"]["cells"];
    {
        auto k = placement["B0_append"]["clicks_xz"];
        penRigEmpty(kFocus);
        clickWorld(onPlane(k["p0"]), onPlane(k["p1"]), onPlane(k["p2"]));
        foreach (pt; [[2, 8], [0, 2], [1, 5]]) {
            penAttr("currentPoint", pt[0]); penAttr("posY", pt[1] / 10.0);
        }
        penAttr("currentPoint", 2);
        clickWorld(onPlane(k["extra"]));
        expectRing("B0_append", commitRing("B0_append", 4, fails),
            ints(rings["B0_append"]), fails);
        ++ran;
    }
    {
        auto k = placement["B1_insert"]["clicks_xz"];
        penRigEmpty(kFocus);
        clickWorld(onPlane(k["p0"]), onPlane(k["p1"]), onPlane(k["p2"]));
        foreach (pt; [[1, 5], [2, 8], [0, 2]]) {
            penAttr("currentPoint", pt[0]); penAttr("posY", pt[1] / 10.0);
        }
        penAttr("currentPoint", 0);
        clickWorld(onPlane(k["extra"]));
        expectRing("B1_insert", commitRing("B1_insert", 4, fails),
            ints(rings["B1_insert"]), fails);
        ++ran;
    }
    {
        auto c = placement["B2_drag"];
        auto k = c["clicks_xz"];
        penRigEmpty(kFocus);
        clickWorld(onPlane(k["p0"])); penAttr("posY", 0.2);
        clickWorld(onPlane(k["p1"])); penAttr("posY", 0.5);
        clickWorld(onPlane(k["p2"])); penAttr("posY", 0.8);
        dragWorld(onPlane(k["p1"]), cast(int)num(c["drag_px"]));
        expectRing("B2_drag", commitRing("B2_drag", 3, fails),
            ints(rings["B2_drag"]), fails);
        ++ran;
    }

    // Make Quads: the decision runs at the 3rd click in this mode too.
    {
        auto q = fx["quads_decision"];
        Vec3[] pts;
        foreach (p; q["clicks_xz_on_plane_y1"].array) pts ~= onPlane(p);
        penRigEmpty(kFocus);
        penCommand("tool.attr pen makeQuads true");
        clickWorld(pts);
        expectFlag(q["case"].str, "after the 3rd click (Make Quads)",
            cast(int)num(q["flip_attr_after_stroke"]), fails);
        penCommand("tool.set pen off");
        penCommand("tool.set pen on");      // leave the param as found
        penCommand("tool.attr pen makeQuads false");
        penCommand("tool.set pen off");
        ++ran;
    }

    // FLOOR: 14 top-view fixture cases + B0/B1/B2 + the quads cell.
    assert(ran == 18, format("ran %s facing cells, expected 18", ran));
    assert(fails.length == 0, "pen facing cells: " ~ fails.join(" | "));
}
