// Merge Points: the VALUE of the no-handle drag, increment by increment
// (task 7121, R witness for 7122; law `doc/measured_laws.md` §26, gap row 200;
// fixture `tests/fixtures/editor_attrs_acen_laws_w17.json` →
// `value_drag.merge_points`).
//
// THE LAW. `dist = dist_press + 0.05 · P · Δx`, Δx the screen-x offset from the
// PRESS pixel (right +), P the view's pixel size. Signed while the button is
// held; `max(0, last)` kept after release; vertical travel changes nothing.
//
// Why these cells discriminate. Block H goes below zero mid-drag (the clamp
// rival reddens at the leg's first negative increment), crosses back (a
// last-step or previous-event rival diverges at increment 2) and is read at
// every increment. Block Z repeats it at twice the pixel size, which is what
// separates a view-scalar gain from a constant. Block V is the axis cell.
import std.format : format;
import std.json;
import std.math   : abs;
import core.thread : Thread;
import core.time   : dur;

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import value_drag_helpers;

void main() {}

enum string TOOL = "vert.merge";

void rig(double pixelSize) {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"vertices","indices":[2,3,6,7]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    orthoAtPixelSize("Top", pixelSize);
    vdCmd("tool.set " ~ TOOL ~ " on");
    vdCmd("tool.attr " ~ TOOL ~ " dist 0.001");
    Thread.sleep(dur!"msecs"(200));
    assert(abs(vdAttr(TOOL, "dist") - 0.001) < 1e-9, "rig: dist did not start at 0.001");
}

/// Drive `legs` from a press at the pane's (fx, fy) fraction and compare
/// `dist` after every increment with `expected`. Returns the value read after
/// release.
double driveLegs(JSONValue legs, JSONValue expected, double fx, string label) {
    auto cam = getJson("/api/camera");
    const int x0 = cast(int)(cam["vpX"].integer + fx * cam["width"].integer);
    const int y0 = cast(int)(cam["vpY"].integer + 60);
    auto inc = expandLegs(legs);
    assert(inc.length == expected.array.length,
        format("fixture: %d increments vs %d values", inc.length, expected.array.length));
    auto h = HeldDrag.press(x0, y0);
    size_t read;
    foreach (k, s; inc) {
        h.move(s.dx, s.dy);
        const double got  = vdAttr(TOOL, "dist");
        const double want = vdNum(expected.array[k]);
        assert(abs(got - want) <= 1e-6, format(
            "merge distance differs from the reference at increment %d (%s)%s: "
            ~ "got %.9g, want %.9g", k + 1, s.leg, label, got, want));
        ++read;
    }
    assert(read == expected.array.length && read > 0,
        format("floor: read %d values", read));
    h.release();
    Thread.sleep(dur!"msecs"(80));
    return vdAttr(TOOL, "dist");
}

unittest { // H — horizontal legs, then the release, then V — vertical legs
    auto fx = valueDragFixture()["merge_points"];
    auto hz = fx["horizontal"];
    assert(hz["values_per_increment"].array.length == 35, "fixture floor: 35 values");

    rig(vdNum(hz["pixel_size_m"]));
    const double kept = driveLegs(hz["legs_px"], hz["values_per_increment"], 0.12, "");
    assert(abs(kept - vdNum(hz["stored_after_release"])) <= 1e-9, format(
        "merge distance kept after release is not max(0, last): got %.9g", kept));
    vdCmd("tool.set " ~ TOOL ~ " off");

    // V — the axis cell: a vertical drag leaves the value where it was.
    auto vt = fx["vertical"];
    assert(vt["values_per_increment"].array.length == 35, "fixture floor: 35 values (V)");
    rig(vdNum(hz["pixel_size_m"]));
    auto cam = getJson("/api/camera");
    auto h = HeldDrag.press(cast(int)(cam["vpX"].integer + 0.12 * cam["width"].integer),
                            cast(int)(cam["vpY"].integer + cam["height"].integer / 2));
    size_t read;
    foreach (k, s; expandLegs(vt["legs_px"])) {
        h.move(s.dx, s.dy);
        const double got = vdAttr(TOOL, "dist");
        assert(abs(got - vdNum(vt["values_per_increment"].array[k])) <= 1e-9, format(
            "vertical drag changed the merge distance at increment %d (%s): %.9g",
            k + 1, s.leg, got));
        ++read;
    }
    assert(read == 35, format("floor: read %d vertical values", read));
    h.release();
    vdCmd("tool.set " ~ TOOL ~ " off");
}

unittest { // Z — the long leg at twice the pixel size
    auto zz = valueDragFixture()["merge_points"]["horizontal_long_zoomed"];
    assert(zz["values_per_increment"].array.length == 82, "fixture floor: 82 values");
    rig(vdNum(zz["pixel_size_m"]));
    const double kept = driveLegs(zz["legs_px"], zz["values_per_increment"], 0.9,
                                  " (zoomed)");
    assert(abs(kept - vdNum(zz["stored_after_release"])) <= 1e-9, format(
        "merge distance kept after release is not max(0, last) (zoomed): got %.9g", kept));
    vdCmd("tool.set " ~ TOOL ~ " off");
}
