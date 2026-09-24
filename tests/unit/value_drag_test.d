// The shared no-handle value drag (`source/value_drag.d`, task 7122): the two
// captured laws driven through the PRODUCTION factories, the stepped rule's
// cells no live rig can reach, and a source census that the two tools reach
// the driver (and the driver the capped per-event loop) — so a tool that grows
// its own loop, or a driver that skips the cap, reddens here.
module tests.unit.value_drag_test;

import std.algorithm : count;
import std.exception : enforce;
import std.file      : readText;
import std.format    : format;
import std.json;
import std.math      : abs;
import std.path      : buildPath, dirName;
import std.string    : indexOf;

import tests.unit.census_symbols : blankNonCode;
import value_drag;

private enum repoRoot = dirName(dirName(dirName(__FILE_FULL_PATH__)));

private JSONValue fixture() {
    return parseJSON(readText(buildPath(repoRoot, "tests", "fixtures",
        "editor_attrs_acen_laws_w17.json")))["value_drag"];
}

private double num(JSONValue v) {
    return v.type == JSONType.float_ ? v.floating
         : v.type == JSONType.integer ? cast(double) v.integer
         : cast(double) v.uinteger;
}

/// Play fixture legs `[["+x", count, px], …]` through one `ValueDrag` as
/// multi-pixel events (the live rig's shape) and compare every value.
private size_t playLegs(ref ValueDrag d, JSONValue legs, JSONValue want,
                        double tol, string what) {
    int x = 1000;
    size_t k;
    foreach (leg; legs.array) {
        const string dir = leg.array[0].str;
        const int n  = cast(int) num(leg.array[1]);
        const int px = cast(int) num(leg.array[2]);
        const int dx = dir == "+x" ? px : dir == "-x" ? -px : 0;
        foreach (i; 0 .. n) {
            x += dx;
            const double v = d.motion(x);
            const double w = num(want.array[k]);
            assert(abs(v - w) <= tol, format("%s differs at increment %d (%s): %.12g vs %.12g",
                what, k + 1, dir, v, w));
            ++k;
        }
    }
    return k;
}

unittest { // Linear (Merge Points, §26): press-relative, signed, max(0, last) kept
    auto m = fixture()["merge_points"];
    size_t total;
    foreach (key; ["horizontal", "horizontal_long_zoomed"]) {
        auto c = m[key];
        ValueDrag d;
        d.press(1000, num(c["value_at_press"]),
                mergeValueDragLaw(num(c["pixel_size_m"]), 1.0));
        total += playLegs(d, c["legs_px"], c["values_per_increment"], 1e-9,
                          "merge " ~ key);
        assert(d.value < 0, "rig: the merge cell must end below zero");
        assert(d.release() == num(c["stored_after_release"]),
            "merge release does not keep max(0, last)");
    }
    assert(total == 35 + 82, format("floor: %d merge values", total));
}

unittest { // Stepped (Inset, §27): the live legs, multi-pixel events, kept signed
    auto ins = fixture()["inset"];
    size_t total;
    foreach (key; ["horizontal", "horizontal_long_zoomed"]) {
        auto c = ins[key];
        ValueDrag d;
        d.press(1000, num(c["value_at_press"]),
                insetValueDragLaw(num(c["pixel_size_m"]), 1.0));
        total += playLegs(d, c["legs_px"], c["values_per_increment"], 1e-12,
                          "inset " ~ key);
        assert(abs(d.release() - num(c["stored_after_release"])) <= 1e-12,
            "inset release does not keep the last value signed");
    }
    assert(total == 35 + 82, format("floor: %d inset values", total));
}

unittest { // Stepped: round_step, 5 pixel sizes x 130 px, exact, with the hold
    auto cells = fixture()["inset"]["round_step"]["cells"].array;
    assert(cells.length == 5, "fixture floor: 5 round_step cells");
    size_t values;
    foreach (c; cells) {
        const double P = num(c["pixel_size_m"]);
        const law = insetValueDragLaw(P, 1.0);
        assert(abs(law.step - num(c["step_per_px_m"])) <= 1e-12 * law.step
            && abs(law.detent - num(c["detent_m"])) <= 1e-12 * law.detent,
            format("inset step/detent at P=%s: %.12g / %.12g", P, law.step, law.detent));
        ValueDrag d;
        d.press(0, 0.0, law);
        auto want = c["values_per_increment"].array;
        size_t reps;
        foreach (k; 0 .. want.length) {
            const double v = d.motion(cast(int) k + 1);
            assert(abs(v - num(want[k])) <= 1e-12, format(
                "inset step/detent differs at P=%s increment %d: %.12g vs %.12g",
                P, k + 1, v, num(want[k])));
            if (abs(v - num(c["first_detent_value_m"])) <= 1e-12) ++reps;
            ++values;
        }
        assert(reps == 1 + kValueDragDetentHoldPx && kValueDragDetentHoldPx == 36,
            format("inset detent hold at P=%s: %d repeats", P, reps));
    }
    assert(values == 650, format("floor: %d round_step values", values));
}

unittest { // the snap: a press value off the step grid is snapped, not offset
    int hold, lastDir;
    const double v = steppedDragPixel(0.0013, +1, 0.0005, 0.05, 36, hold, lastDir);
    assert(abs(v - 0.002) <= 1e-15,
        format("first pixel from 0.0013 at step 0.0005 is %.12g, want 0.002 "
             ~ "(the unsnapped rival gives 0.0018)", v));
}

unittest { // a direction change inside a hold clears it
    int hold, lastDir;
    double v = 0.0;
    foreach (i; 0 .. 100) v = steppedDragPixel(v, +1, 0.0005, 0.05, 36, hold, lastDir);
    assert(abs(v - 0.05) <= 1e-15 && hold == 36, "rig: 100 px must land on the 0.05 detent");
    foreach (i; 0 .. 10) v = steppedDragPixel(v, +1, 0.0005, 0.05, 36, hold, lastDir);
    assert(abs(v - 0.05) <= 1e-15, "rig: the 10 px after landing must be held");
    v = steppedDragPixel(v, -1, 0.0005, 0.05, 36, hold, lastDir);
    assert(abs(v - 0.0495) <= 1e-15,
        format("direction change did not clear the detent hold: %.12g", v));
}

unittest { // every press starts a fresh detent state (a hold never leaks into the next drag)
    const law = ValueDragLaw.stepped(0.0005, 0.05);
    ValueDrag d;
    d.press(0, 0.0, law);
    const double landed = d.motion(100);
    assert(abs(landed - 0.05) <= 1e-15 && d.hold == 36,
        "rig: 100 px must land on the 0.05 detent and arm the hold");
    d.release();
    d.press(500, landed, law);
    const double next = d.motion(501);
    assert(abs(next - 0.0505) <= 1e-15,
        format("a new press inherited the previous drag's detent hold: %.12g", next));
}

unittest { // the layer-unit conversion divides the world law (task 0645)
    const double P = 0.0021959837925048056;
    const m1 = mergeValueDragLaw(P, 1.0), m2 = mergeValueDragLaw(P, 2.0);
    assert(abs(m2.gain * 2.0 - m1.gain) <= 1e-18 && m1.gain > 0,
        "merge gain is not converted into layer units");
    const i1 = insetValueDragLaw(P, 1.0), i2 = insetValueDragLaw(P, 2.0);
    assert(abs(i2.step * 2.0 - i1.step) <= 1e-18 && abs(i2.detent * 2.0 - i1.detent) <= 1e-18
        && i1.step > 0 && i1.detent > 0,
        "inset step/detent are not converted into layer units");
}

unittest { // the detent test is EXACT double equality, not a tolerance
    // Provenance: static read of measured_laws §27, C5-i-round — "a pixel that
    // lands EXACTLY (double ==) on a detent multiple". No live cell separates
    // it; this does: from 0 at step 0.0002, the 150th step is
    // 0.030000000000000002, which != round(v/0.01)*0.01 == 0.03, so it must
    // NOT hold, while 0.01 and 0.02 (the 50th/100th steps) land exactly and do.
    int hold, lastDir;
    double v = 0.0;
    int landed01, landed02, steps;
    bool reached03;
    while (steps < 400 && !reached03) {
        v = steppedDragPixel(v, +1, 0.0002, 0.01, 36, hold, lastDir);
        ++steps;
        if (hold == 36 && v == 0.01) ++landed01;
        if (hold == 36 && v == 0.02) ++landed02;
        if (abs(v - 0.03) < 1e-9 && hold == 0 && lastDir == 1) reached03 = true;
        else if (abs(v - 0.03) < 1e-9) {
            assert(false, format("the inexact 0.03 (%.17g) armed a detent hold of %d: "
                ~ "the detent test must be double ==, not a tolerance", v, hold));
        }
    }
    assert(landed01 == 1 && landed02 == 1,
        format("rig: 0.01 / 0.02 did not land exactly with a 36-px hold (%d, %d)",
               landed01, landed02));
    assert(reached03 && v != 0.03 && steps == 150 + 2 * 36,
        format("rig: reached 0.03 after %d pixels (want %d), v %.17g",
               steps, 150 + 2 * 36, v));
}

unittest { // only a POSITIVE detent holds
    int hold, lastDir;
    double v = 0.0;
    foreach (i; 0 .. 100) v = steppedDragPixel(v, +1, 0.0005, -0.05, 36, hold, lastDir);
    assert(hold == 0 && abs(v - 0.05) <= 1e-15,
        format("a negative detent armed a hold (hold %d, v %.12g)", hold, v));
}

unittest { // the per-event kernel cap
    double v = 0;
    int hold, lastDir;
    const int n = steppedDragEvent(v, 1 << 20, 1.0, 0.0, 36, hold, lastDir);
    assert(n == MAX_VALUE_DRAG_PX_PER_EVENT && MAX_VALUE_DRAG_PX_PER_EVENT == (1 << 14)
        && v == (1 << 14),
        format("drag event is not clamped to MAX_VALUE_DRAG_PX_PER_EVENT: %d px, v %s", n, v));
    // A degenerate law steps nothing and stays finite.
    ValueDrag d;
    d.press(0, 0.25, ValueDragLaw.stepped(double.nan, 0.0));
    assert(d.motion(40) == 0.25, "a NaN step must not move the value");
    d.press(0, 0.25, ValueDragLaw.stepped(double.infinity, 0.0));
    assert(d.motion(40) == 0.25, "an infinite step must not move the value");
    d.press(0, 0.25, ValueDragLaw.stepped(-0.5, 0.0));
    assert(d.motion(40) == 0.25, "a negative step must not move the value");
    d.press(0, 0.25, ValueDragLaw.linear(double.infinity, false));
    assert(d.motion(40) == 0.25, "a non-finite gain must not move the value");
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    enforce(i < code.length, "no body after `" ~ marker ~ "`");
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    enforce(false, "unterminated body after `" ~ marker ~ "`");
    return null;
}

unittest { // census: both tools reach the shared driver; the driver reaches the cap
    size_t bodies;
    foreach (f; ["poly_inset_tool.d", "vert_merge_tool.d"]) {
        const code = blankNonCode(readText(buildPath(repoRoot, "source", "tools", "edit", f)));
        const motion = bodyAt(code, "override bool onMouseMotion(");
        assert(motion.length > 40, f ~ ": onMouseMotion body not found");
        assert(count(motion, "valueDrag_.motion(") == 1
            && count(motion, "steppedDrag") == 0
            && count(motion, "gesturePrevPixel(") == 0,
            f ~ ": motion does not go through the shared value drag (one "
            ~ "`valueDrag_.motion(`, no own stepping loop, no previous-pixel delta)");
        const press = bodyAt(code, "override bool onMouseButtonDown(");
        assert(count(press, "valueDrag_.press(") == 1 && count(press, "viewWorldPerPixel(") == 1
            && count(press, "haulWorldPerPixel(") == 0,
            f ~ ": the press does not arm the value drag at the VIEW's pixel size");
        const release = bodyAt(code, "override bool onMouseButtonUp(");
        assert(count(release, "valueDrag_.release()") == 1,
            f ~ ": the release does not take the law's kept value");
        ++bodies;
    }
    const vd = blankNonCode(readText(buildPath(repoRoot, "source", "value_drag.d")));
    const m = bodyAt(vd, "double motion(int x)");
    assert(m.length > 40, "ValueDrag.motion body not found");
    assert(count(m, "steppedDragEvent(") == 1 && count(m, "steppedDragPixel(") == 0,
        "the stepped motion does not go through the clamped per-event function");
    assert(bodies == 2, format("census floor: %d tool bodies", bodies));
}
