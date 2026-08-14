// Module unittests for `drag`, moved verbatim out of source/drag.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.drag_test;

import std.math : sqrt, isNaN, abs;
import math;
import handler : MoveHandler, gizmoSize, getGizmoPixels;
import toolpipe.packets : GesturePacket, GestureTrack;
import coord_rounding : CoordinateRounding, kFixedIncrementDefault;
import std.math : PI, sin, cos, tan;
import drag;

unittest {
    // No packet at all → the caller's own pair, untouched.
    int px, py;
    gesturePrevPixel(null, 40, 30, 12, 34, px, py);
    assert(px == 12 && py == 34);

    // Default-constructed (every non-mouse dispatch) → same.
    GesturePacket idle;
    gesturePrevPixel(&idle, 40, 30, 12, 34, px, py);
    assert(px == 12 && py == 34);

    // A valid packet for THIS event → the packet's previous pixel, which the
    // assert has just proven equal to the caller's.
    GestureTrack tr;
    tr.event(GesturePacket.Phase.Down, 12, 34);
    auto mv = tr.event(GesturePacket.Phase.Move, 40, 30);
    gesturePrevPixel(&mv, 40, 30, 12, 34, px, py);
    assert(px == 12 && py == 34);
    assert(40 - px == mv.incrementX() && 30 - py == mv.incrementY());

    // A packet for a DIFFERENT event is not this event's reference.
    gesturePrevPixel(&mv, 41, 30, 12, 34, px, py);
    assert(px == 12 && py == 34);
}

unittest {  // LAW A ported: orthographic views carry NO 4/5.
    import std.math : PI, tan, abs;

    // The editor's own axis-view preset recipe (view.d): halfH = d*tan(PI/8).
    const float d = 3.0f, halfH = d * tan(cast(float)(PI / 8.0));
    Viewport vp;
    vp.view   = lookAt(Vec3(0, d, 0), Vec3(0, 0, 0), Vec3(0, 0, -1));
    vp.proj   = orthographicMatrix(halfH, 1098.0f / 832.0f, 0.001f, 100.0f);
    vp.width  = 1098; vp.height = 832;
    vp.eye    = Vec3(0, d, 0); vp.focus = Vec3(0, 0, 0);

    const float want = 2.0f * halfH / 832.0f;    // world units per pixel, exactly
    assert(abs(viewWorldPerPixel(vp) - want) < 1e-6f * want,
           "in an orthographic view the reference's reported pixel size IS "
           ~ "the projection's scale — the 4/5 is a perspective-only ratio "
           ~ "and applying it here would slow every axis-view drag by 20%");
}

unittest {  // LAW A ported: the OTHER arms of the setting.
    import std.math : abs;
    import std.format : format;

    // `Normal` — the grid's own tenth, nice-rounded. Confirmed live by one
    // row: a view carrying scale 100 with grid 0.5 and step 0.05, and
    // stepLadderNearest(0.5 / 10) is 0.05.
    assert(abs(majorGridStep(1.0 / 100.0) - 0.5) < 1e-12,
           "the grid size at scale 100 must be 0.5 — stepLadderCeil(25/100)");
    assert(abs(axisDragRoundingStep(CoordinateRounding.Normal, 1.0 / 100.0,
                               kFixedIncrementDefault) - 0.05) < 1e-12,
           "the Normal arm must reproduce the one live row it has");

    // `ForcedFixed` — the increment, and nothing else, at ANY zoom. That is
    // the arm's whole content, so the test is that it does not move.
    foreach (px; [1e-5, 1e-3, 1e-1, 1.0]) {
        assert(axisDragRoundingStep(CoordinateRounding.ForcedFixed, px, 0.01) == 0.01,
               "ForcedFixed must ignore the zoom entirely");
        assert(axisDragRoundingStep(CoordinateRounding.ForcedFixed, px, 0.25) == 0.25);
    }
    // ...and a non-positive increment leaves nothing to round to, which the
    // one gate turns into the identity rather than into a default.
    assert(axisDragRoundingStep(CoordinateRounding.ForcedFixed, 1e-3, 0.0)  == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.ForcedFixed, 1e-3, -1.0) == 0.0);

    // `Fixed` — the floor property, which holds in all three of the arm's
    // exits and survived the arm being read (task 0580).
    foreach (px; [1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1]) {
        const double d = 0.01;
        const double s = axisDragRoundingStep(CoordinateRounding.Fixed, px, d);
        assert(s >= d - 1e-12,
               format("the Fixed arm's whole purpose is that the increment is "
                    ~ "a floor: pixelSize %.9g with increment %.9g gave %.9g",
                    px, d, s));
    }

    // Value assertions are now available, because the arm was read rather than
    // inferred. At pixelSize 1e-3 the grid size is 0.05 and the sub-step 0.005,
    // which is enough to hit all three exits with hand-checkable numbers.
    assert(majorGridStep(1e-3) == 0.05);
    {
        const double px = 1e-3;
        // above the grid size — the increment wins outright
        assert(axisDragRoundingStep(CoordinateRounding.Fixed, px, 0.06) == 0.06);
        // a whole small multiple of the increment spans the sub-step
        assert(abs(axisDragRoundingStep(CoordinateRounding.Fixed, px, 0.001)
                   - 0.005) < 1e-15);
        // twelve or more increments across it: the sub-step stands
        assert(abs(axisDragRoundingStep(CoordinateRounding.Fixed, px, 0.0001)
                   - 0.005) < 1e-15);
    }

    // THE BAND, pinned. `g/10 < d <= g` is where correcting the floor's operand
    // from the sub-step to the grid size (task 0586) moved which branch runs.
    // The result must not move with it: the multiple clause returns `1*d` there
    // because the rounded ratio cannot exceed 1. Measured, not assumed — this
    // is the assertion that would have caught the operand error had the ladder
    // NOT made the two spellings agree.
    foreach (px; [1e-6, 1e-4, 1e-3, 1e-2, 1.0]) {
        const double g = majorGridStep(px);
        // The ladder is closed under x10, so the sub-step IS the grid's tenth
        // — but only to within representation, NOT bit-for-bit. At pixelSize
        // 1e-6 the log-space reconstruction lands one ulp BELOW `g / 10.0`
        // (4.9999999999999996e-6 against 5.0000000000000004e-6). A sweep over
        // one staircase of scales can miss that and report exactness; it is
        // not exact, and asserting `==` here fails on the first row.
        assert(abs(stepLadderNearest(g / 10.0) - g / 10.0) <= 4e-16 * g,
               "the sub-step must be the grid's tenth to within a few ulps");
        // Nothing below needs the stronger claim: the band returns `d` as long
        // as the rounded ratio cannot exceed 1, i.e. as long as `s/d < 1.5`,
        // and in the band `s/d` is at most about 1. An ulp of slack in `s` is
        // nowhere near that margin.
        foreach (frac; [0.11, 0.25, 0.5, 0.9, 1.0]) {
            const double d = g * frac;              // inside (g/10, g]
            assert(axisDragRoundingStep(CoordinateRounding.Fixed, px, d) == d,
                   format("in the band g/10 < d <= g the arm must return the "
                        ~ "increment: pixelSize %.9g, g %.9g, d %.9g gave %.9g",
                        px, g, d, axisDragRoundingStep(
                            CoordinateRounding.Fixed, px, d)));
        }
    }

    // A NON-POSITIVE increment switches rounding OFF, and this assertion is the
    // inverse of what stood here before. It was not edited to make anything
    // pass: task 0580 read the arm and the reading refutes the claim the old
    // line made. At `d <= 0` the increment cannot exceed the grid size, so the
    // multiple clause runs, and its rounded ratio is never above zero — at
    // `d == 0` because `s/0` is +inf and the int32 truncation returns INT_MIN,
    // and at `d < 0` because the ratio is simply negative. Either way `< 12`
    // holds, `max(n,1)` gives 1, and the sub-step becomes `1*d` — zero or
    // negative. The `step <= 0` gate then makes that the identity. The old line
    // asserted the arm degraded to `Normal` here, i.e. that rounding stayed ON;
    // it does not.
    // (`ForcedFixed` above IS `max(d, 0)` and does degrade to nothing, which is
    // where the confusion came from — the two arms differ exactly here.)
    assert(axisDragRoundingStep(CoordinateRounding.Fixed, 1e-3, 0.0)  == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fixed, 1e-3, -0.0) == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fixed, 1e-3, -1.0) <  0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fixed, 1e-3, -1e-3) < 0.0);
    // ...and `snapAxisScalar`'s single gate is what turns that into the
    // identity, so the end-to-end claim is "rounding off", not "step zero".
    foreach (d; [0.0, -1e-3, -1.0]) {
        const float step = cast(float)axisDragRoundingStep(
            CoordinateRounding.Fixed, 1e-3, d);
        assert(snapAxisScalar(0.037f, step) == 0.037f,
               "a non-positive increment must leave the scalar untouched");
    }
}

unittest {  // LAW A ported: the ladder helper, including the negative half.
    import std.math : abs;

    // Exact powers of ten are the inputs where `log10` can land on either
    // side of a decade boundary. The ladder contains both 1 and 10 precisely
    // so both spellings agree; this is that property, asserted.
    foreach (n; -8 .. 4) {
        const double p = 10.0 ^^ cast(double)n;
        assert(abs(stepLadderCeil(p) - p) <= 1e-12 * p,
               "an exact power of ten must be its own ceiling on the ladder");
    }
    assert(abs(stepLadderCeil(0.0011) - 0.002) < 1e-15);
    assert(abs(stepLadderCeil(0.0021) - 0.005) < 1e-15);
    assert(abs(stepLadderCeil(0.0051) - 0.01 ) < 1e-15);

    // Nearest is measured in LOG space: 3 is nearer 2 than 5 there
    // (log10 3 = 0.477, which is 0.176 above log10 2 and 0.222 below log10 5)
    // even though 3 is equidistant from 2 and 5 linearly.
    assert(abs(stepLadderNearest(3.0) - 2.0) < 1e-12,
           "nearest must be measured in log space, not linearly");
    assert(abs(stepLadderNearest(4.0) - 5.0) < 1e-12);

    // Odd in the sign, like the rounding it feeds.
    assert(stepLadderCeil(-0.0011) == -stepLadderCeil(0.0011));
    assert(stepLadderCeil(0.0) == 0.0);
}

unittest {  // LAW B: degenerate views skip instead of exploding.
    // Edge-on: the camera looks along the plane, the 2x2 collapses, and the
    // caller must be told to leave its bookkeeping alone rather than handed a
    // huge or NaN delta. The old law failed the same case on a parallel ray.
    Viewport vp;
    Vec3 eye = Vec3(0, 0, 6), focus = Vec3(0, 0, 0);
    vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f, 1.0f, 0.001f, 100.0f);
    vp.width  = 800; vp.height = 800;
    vp.eye    = eye; vp.focus = focus;

    bool skip;
    // Force the XZ plane (normal Y) — the camera lies in it.
    Vec3 d = planeDragDelta(500, 400, 400, 400, 6, Vec3(0,0,0), vp, skip);
    assert(skip, "an edge-on plane must skip");
    assert(d == Vec3(0, 0, 0));

    // A zero normal is a caller bug, not a crash.
    Vec3 z = planeDragDelta(500, 400, 400, 400, 3, Vec3(0,0,0), vp, skip,
                            Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1),
                            Vec3(0, 0, 0));
    assert(skip && z == Vec3(0, 0, 0));
}
