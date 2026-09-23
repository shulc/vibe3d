// Edge Extend — the scale-tool key (R) during and after an arm drag
// (item 15; fixture cells `switch_key_while_button_held`,
// `switch_key_after_release` of tests/fixtures/edge_extend_gesture_laws.json).
//
// The measured law has two halves:
//   * with the button HELD, R is ignored: the drag runs to its end and Edge
//     Extend stays the active tool;
//   * after the RELEASE, R switches to the scale transform and the extension
//     is kept; no message is shown (so none is asserted either way).
//
// Order: (C0) the same X-arm drag with no key, which gives the offset the
// held-key drag must reach; (H) the held-key cell — RED on HEAD at "scale key
// interrupted the extend drag", because HEAD switches tools mid-drag; (S) the
// after-release cell, below the red line (HEAD already switches there).
//
// Every H assert carries the same message prefix, the population floor
// included: the floor ("all ten increments were accepted by the extend") is
// what keeps the offset comparison from being vacuous, and on HEAD it is the
// first thing the interrupted drag breaks.

import edge_extend_gesture_helpers;
import http_client : getJson;
import std.conv : to;
import std.format : format;
import std.json;
import std.math : abs;

void main() {}

enum int[2][] kPlusRidge = [[6, 7], [7, 8]];
enum string kHeld = "scale key interrupted the extend drag";

__gshared double ctl10;

unittest { // C0: the X-arm drag, no key
    armRig(kPlusRidge, 1.0);
    engage();
    Px p = pressArm(kArmPressPx, 0, 0, "tool switch control: x arm press did not grab the arm");
    Px end;
    auto tr = increments(p, kIncrementPx, kIncrementPx, 10, end);
    release(end);
    assert(tr.length == 10 && tr[9].x > 0, "tool switch control: read " ~ tr.to!string);
    ctl10 = offset().x;
    assert(abs(ctl10 - tr[9].x) <= 1e-9, "tool switch control: release moved the offset");
    cmd("tool.set edge.extend off");
}

/// offsetX when Edge Extend is still the active tool, else NaN.
double extendOffsetXOrNaN() {
    auto s = toolState();
    if (s["tool"].str != "edgeExtend") return double.nan;
    return num(s["offsetX"]);
}

unittest { // H: R with the button held is ignored
    armRig(kPlusRidge, 1.0);
    engage();
    Px p = pressArm(kArmPressPx, 0, 0, kHeld ~ ": x arm press did not grab the arm");
    size_t accepted = 0;
    double prev = offset().x;
    foreach (i; 0 .. 10) {
        if (i == 5) tapKey(kScaleKey);
        p = Px(p.x + kIncrementPx, p.y + kIncrementPx);
        motion(p, kIncrementPx, kIncrementPx);
        immutable double x = extendOffsetXOrNaN();
        if (x == x && x > prev) { ++accepted; prev = x; }
    }
    release(p);
    auto s = toolState();
    assert(accepted == 10, format("%s: the extend accepted %d of 10 increments (tool now %s)",
                                  kHeld, accepted, s["tool"].str));
    assert(s["tool"].str == "edgeExtend", kHeld ~ ": active tool after release is " ~ s.toString);
    assert(abs(num(s["offsetX"]) - ctl10) <= 1e-5,
        format("%s: offsetX %s, the same drag without the key reached %s", kHeld, num(s["offsetX"]), ctl10));
    cmd("tool.set edge.extend off");
}

unittest { // S: R after the release switches to scale, extension kept
    armRig(kPlusRidge, 1.0);
    engage();
    Px p = pressArm(kArmPressPx, 0, 0, "scale did not arm after extend move: x arm press did not grab the arm");
    Px end;
    increments(p, kIncrementPx, kIncrementPx, 10, end);
    release(end);
    immutable long h0 = undoLen();
    assert(h0 < 40, "tool switch: no history headroom");
    tapKey(kScaleKey);
    settle(250);
    auto s = toolState();
    assert(s["tool"].str == "xfrm" && s["enabled"]["s"].type == JSONType.true_
        && s["enabled"]["t"].type == JSONType.false_ && s["enabled"]["r"].type == JSONType.false_,
        "scale did not arm after extend move: " ~ s.toString);
    assert(vertexCount() == 12, "scale did not arm after extend move: extension lost, "
        ~ vertexCount().to!string ~ " vertices");
    // Measured on HEAD: TWO records — the extend's commit and the tool
    // activation, in that order. (The reference also undoes in two steps:
    // the first brings the extend tool back, the second removes the ring.)
    auto undo = getJson("/api/history")["undo"].array;
    assert(undo.length == h0 + 2
        && undo[h0]["label"].str == "Edge Extend" && undo[h0 + 1]["label"].str == "Activate Tool",
        "scale did not arm after extend move: history " ~ undo.to!string);
}
