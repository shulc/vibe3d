// Polygon Inset: the VALUE of the no-handle drag, increment by increment
// (task 7121, R witness for 7122; laws `doc/measured_laws.md` §26 and §27,
// gap rows 201 and 208; fixture `tests/fixtures/editor_attrs_acen_laws_w17.json`
// → `value_drag.inset`).
//
// THE LAW. Per pixel of HORIZONTAL travel with direction dir = ±1:
// `v = (round(v / step) + dir) · step`, step = the smallest {1,2,5}·10^k at or
// above 0.2·P (P the view's pixel size). Landing EXACTLY on a multiple of the
// detent D — the {1,2,5}·10^k nearest (in log10) to 20·P — makes the next 36
// pixels in the same direction do nothing; a direction change clears that.
// Signed throughout, and the last value is kept after release.
//
// Why these cells discriminate. H and Z hold at 0 and at a detent multiple, so a
// linear rival leaves them at the first hold; Z is at twice the pixel size, so
// a constant step leaves it at increment 1. RS sweeps five pixel sizes across
// the ladder's rungs, 1 px at a time: the first cell (P = 0.0007) is the one
// where a NEAREST step (0.0001) and the CEILING step (0.0002) differ, and every
// cell lands on its first detent, so the 36-px hold is observed five times.
import std.format : format;
import std.json;
import std.math   : abs;
import core.thread : Thread;
import core.time   : dur;

import http_client : getJson, postJson;
import http_command_helpers : commandBody;
import value_drag_helpers;

void main() {}

enum string TOOL = "mesh.polyInsetTool";

void rig(string view, double pixelSize) {
    auto r = postJson("/api/command", commandBody("scene.reset"));
    assert(r["status"].str == "ok", "reset failed: " ~ r.toString);
    r = postJson("/api/command", commandBody("mesh.select",
        `{"mode":"polygons","indices":[4]}`));
    assert(r["status"].str == "ok", "select failed: " ~ r.toString);
    orthoAtPixelSize(view, pixelSize);
    vdCmd("tool.set " ~ TOOL ~ " on");
    Thread.sleep(dur!"msecs"(200));
    assert(abs(vdAttr(TOOL, "inset")) < 1e-12, "rig: inset did not start at 0");
}

/// Press at the pane's `fx` width fraction, play `inc`, compare after every
/// increment within `tol` (plus the float32 rounding of the attribute).
/// Returns the values read; the release is left to the caller.
double[] drive(Increment[] inc, JSONValue expected, double fx, double tol,
               string delegate(size_t k, string leg) message, out HeldDrag h) {
    auto cam = getJson("/api/camera");
    assert(inc.length == expected.array.length,
        format("fixture: %d increments vs %d values", inc.length, expected.array.length));
    h = HeldDrag.press(cast(int)(cam["vpX"].integer + fx * cam["width"].integer),
                       cast(int)(cam["vpY"].integer + 60));
    double[] got;
    foreach (k, s; inc) {
        h.move(s.dx, s.dy);
        const double v    = vdAttr(TOOL, "inset");
        const double want = vdNum(expected.array[k]);
        assert(abs(v - want) <= tol + 1.2e-7 * abs(want),
            message(k, s.leg) ~ format(": got %.10g, want %.10g", v, want));
        got ~= v;
    }
    return got;
}

void horizontalBlock(string key, double fx, string label) {
    auto c = valueDragFixture()["inset"][key];
    rig("Top", vdNum(c["pixel_size_m"]));
    HeldDrag h;
    auto got = drive(expandLegs(c["legs_px"]), c["values_per_increment"], fx, 1e-6,
        (k, leg) => format("inset value differs from the reference at increment %d (%s)%s",
                           k + 1, leg, label), h);
    assert(got.length == c["values_per_increment"].array.length && got.length > 0,
        format("floor: read %d values", got.length));
    h.release();
    Thread.sleep(dur!"msecs"(80));
    const double kept = vdAttr(TOOL, "inset");
    const double want = vdNum(c["stored_after_release"]);
    assert(abs(kept - want) <= 1e-6, format(
        "inset kept after release differs (reference keeps it signed)%s: got %.9g, want %.9g",
        label, kept, want));
    vdCmd("tool.set " ~ TOOL ~ " off");
}

unittest { // H — the capture's first zoom
    auto c = valueDragFixture()["inset"]["horizontal"];
    assert(c["values_per_increment"].array.length == 35, "fixture floor: 35 values");
    horizontalBlock("horizontal", 0.12, "");
}

unittest { // Z — the long leg at twice the pixel size; kept NEGATIVE after release
    auto c = valueDragFixture()["inset"]["horizontal_long_zoomed"];
    assert(c["values_per_increment"].array.length == 82, "fixture floor: 82 values");
    horizontalBlock("horizontal_long_zoomed", 0.9, " (zoomed)");
}

unittest { // RS — step and detent across five pixel sizes, 1 px at a time
    auto rs = valueDragFixture()["inset"]["round_step"];
    assert(rs["cells"].array.length == 5, "fixture floor: 5 round_step cells");
    size_t cells, values;
    foreach (cell; rs["cells"].array) {
        const double P = vdNum(cell["pixel_size_m"]);
        const int n  = cast(int) vdNum(cell["increments_px"].array[1]);
        const int px = cast(int) vdNum(cell["increments_px"].array[0]);
        Increment[] inc;
        foreach (k; 0 .. n) inc ~= Increment(px, 0, "+x");
        rig("Front", P);
        HeldDrag h;
        auto got = drive(inc, cell["values_per_increment"], 0.1, 1e-9,
            (k, leg) => format("inset step/detent differs at P=%s increment %d", P, k + 1), h);
        h.release();
        vdCmd("tool.set " ~ TOOL ~ " off");
        assert(got.length == 130, format("floor: P=%s read %d values", P, got.length));

        // The hold is OBSERVABLE on this rig: the first detent value repeats
        // for the landing pixel plus the 36 held ones.
        const double det = vdNum(cell["first_detent_value_m"]);
        size_t reps;
        foreach (v; got) if (abs(v - det) <= 1e-9 + 1.2e-7 * det) ++reps;
        assert(reps == 1 + 36, format(
            "inset detent hold at P=%s: value %s seen %d times, want 37", P, det, reps));
        ++cells; values += got.length;
    }
    assert(cells == 5 && values == 650, format("floor: %d cells, %d values", cells, values));
}
