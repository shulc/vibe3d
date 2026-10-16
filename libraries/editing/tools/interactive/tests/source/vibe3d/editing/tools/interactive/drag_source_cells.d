module vibe3d.editing.tools.interactive.drag_source_cells;

version (unittest) {
    import std.math : PI, sin, cos, tan;
}

import std.math : sqrt, isNaN, abs;
import vibe3d.util.math.math;
import vibe3d.util.spatial.spatial : Orientation, Viewport, eyeVectorAt, lockedViewAxis, projectToWindowFull, screenPointToRay, viewPixelScale;
import vibe3d.editing.tools.interactive.handler : MoveHandler, gizmoSize, getGizmoPixels;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : GesturePacket, GestureTrack;
import vibe3d.editing.pipeline.contracts.toolpipe.packets : ComponentGuide;
import vibe3d.editing.tools.interactive.coord_rounding : CoordinateRounding, kFixedIncrementDefault, coordRounding,
                       coordRoundingFixedIncrement;
import vibe3d.editing.tools.interactive.drag;
version (unittest) import vibe3d.editing.tools.interactive.drag_source_helpers : corpusCams, corpusViewport, vlen, exactPlaneDelta;

version (unittest) {
    // The two reference cameras of the pixel-size read, verbatim: each row is
    // the eye distance and the pixel size the REFERENCE ITSELF reported for
    // that view. They come from two different lanes, two panes and two camera
    // orientations, and neither was taken for this port.
    private struct RefCam { string name; double distance, pixelSize; }
    private immutable RefCam[] refPixelCams = [
        RefCam("corpus drag camera",  1.4863233322541896, 0.001183431952662722),
        RefCam("ray lane camera",     1.6598368490151412, 0.0013215859030837  ),
    ];

    // The cross-engine pane pin, and the real number it rounds. The pin exists
    // so one of our pixels subtends one of the reference's; it is
    // `2·tan(fovY/2)·f_ref` with `f_ref = 400·10^0.4`, which is 832.36598 and
    // ships as the integer 832. Everything downstream of the pin scales with
    // 1/height, so that rounding is the ONLY residual the test below tolerates.
    private enum int    PINNED_PANE_W = 1098;
    private enum int    PINNED_PANE_H = 832;

    // The reference's OWN snap rows, verbatim: `t` read immediately before its
    // view rounding and immediately after, on the recording that first
    // executed the axis arms. Six distinct pre-snap values — three axes x two
    // drag lengths — and the six answers the engine gave.
    //
    // These are not derived from our step; the step was derived from THEM.
    // Row 2 and row 4 are the pair that matters most: 33.61 steps and
    // 33.40 steps, which round in opposite directions, so a floor or a ceiling
    // or a truncation reproduces at most one of the two.
    private struct RefSnap { double before, after; }
    private immutable RefSnap[] refSnapRows = [
        RefSnap(0.033611330530568473, 0.034),   // 16.8057 steps -> 17
        RefSnap(0.067222661061136946, 0.068),   // 33.6113 steps -> 34
        RefSnap(0.033404502316750892, 0.034),   // 16.7023 steps -> 17
        RefSnap(0.066809004633501784, 0.066),   // 33.4045 steps -> 33
        RefSnap(0.032694010160137447, 0.032),   // 16.3470 steps -> 16
        RefSnap(0.065655147863375493, 0.066),   // 32.8276 steps -> 33
    ];

    // The view scale that recording ran at, read off the view as a field on
    // all thirty evaluations, bit-identical every time. The step the six rows
    // above were rounded to is NOT written down here — it is DERIVED from
    // this number by the law under test, which is what turns those six rows
    // from a pin on a constant into a pin on the formula.
    private enum double REF_SNAP_SCALE = 601.66119999999989;

    // THE STAIRCASE, verbatim: 18 distinct zoom levels off a trace recorded
    // for an unrelated purpose, spanning 26.4 to 27040 pixels per world unit —
    // a factor of 1024. Each row is the view's scale and the rounding step the
    // view carried at that scale. `pixelSize` is `1 / scale`.
    //
    // These rows are the whole reason the step cannot be a constant, and they
    // are also why it cannot be a scaling: 298.75 and 422.50 differ by 1.414x
    // and share 0.005; 105.63 and 149.38 share 0.01; 2390, 3380 and 4780 all
    // share 0.0005. A law continuous in the zoom cannot produce a plateau.
    private struct RefStep { double scale, step; }
    private immutable RefStep[] refStepRows = [
        RefStep(   26.41, 0.05   ),
        RefStep(   52.81, 0.02   ),
        RefStep(  105.63, 0.01   ),
        RefStep(  149.38, 0.01   ),
        RefStep(  211.25, 0.005  ),
        RefStep(  298.75, 0.005  ),
        RefStep(  422.50, 0.005  ),
        RefStep(  597.51, 0.002  ),
        RefStep(  845.00, 0.002  ),
        RefStep( 1195.01, 0.001  ),
        RefStep( 1690.00, 0.001  ),
        RefStep( 2390.02, 0.0005 ),
        RefStep( 3380.00, 0.0005 ),
        RefStep( 4780.04, 0.0005 ),
        RefStep( 6760.00, 0.0002 ),
        RefStep( 9560.08, 0.0002 ),
        RefStep(13520.00, 0.0001 ),
        RefStep(19120.20, 0.0001 ),
        RefStep(27040.00, 0.00005),
    ];
}

unittest {  // LAW A ported: the gain IS the reference's own reported pixel size.
    import std.math : PI, tan, abs;

    // Our pinned pane, our hard-coded 45-degree vertical fov.
    Viewport vp;
    vp.proj   = perspectiveMatrix(45.0f * PI / 180.0f,
                                  cast(float)PINNED_PANE_W / PINNED_PANE_H,
                                  0.001f, 100.0f);
    vp.width  = PINNED_PANE_W;
    vp.height = PINNED_PANE_H;

    const double exactPin = 2.0 * tan(22.5 * PI / 180.0) * 400.0 * (10.0 ^^ 0.4);
    const double pinRound = exactPin / PINNED_PANE_H;   // 1.000439833...

    double[] ratios;
    foreach (c; refPixelCams) {
        // Only the eye DISTANCE goes in; the reference's pixel size is what
        // comes out and is never handed to the function.
        vp.eye   = Vec3(0, 0, cast(float)c.distance);
        vp.focus = Vec3(0, 0, 0);
        const double got = viewWorldPerPixel(vp);
        assert(got > 0);
        ratios ~= got / c.pixelSize;
    }

    // Each camera on its own: the port reproduces the number the reference
    // reported, up to the integer pane pin and nothing else.
    foreach (i, r; ratios)
        assert(abs(r - pinRound) < 1e-5 * pinRound,
               "viewWorldPerPixel must reproduce the reference's OWN reported "
               ~ "pixel size for " ~ refPixelCams[i].name
               ~ " up to the pane pin's integer rounding — the 4/5 is the "
               ~ "engine's ratio between the pixel size it reports and the "
               ~ "one its perspective projection uses, not a fitted constant");

    // And the two cameras agree with each other. Two distances, two panes,
    // two lanes, one ratio: the quantity carries no camera, which is exactly
    // why it can be expressed as `(4/5)·distance/focal` at all.
    // (1e-6 is float32's own headroom on a single multiply-divide, not slack:
    // the two ratios agree to 15 digits when the arithmetic is done in double.)
    assert(abs(ratios[0] - ratios[1]) < 1e-6 * ratios[0],
           "two independent reference cameras must give the SAME ratio — a "
           ~ "difference means the gain has picked up a camera term it does "
           ~ "not have");
}

unittest {  // LAW A ported: NO foreshortening compensation. The headline.
    import std.math : PI, cos, abs;

    auto vp = corpusViewport(corpusCams[0]);
    // Base at the view focus, so it projects to the pane centre and a world
    // step along the view's own `right` projects to EXACTLY +screen-x — which
    // makes the screen direction of every axis below the same direction, and
    // the only thing that varies the axis's foreshortening.
    Vec3 base = vp.focus;
    const ref float[16] v = vp.view;
    Vec3 right = Vec3(v[0], v[4], v[8]);
    Vec3 back  = Vec3(v[2], v[6], v[10]);

    const float ps    = viewWorldPerPixel(vp);
    const int   pxRun = 100;
    const float wantT = ps * pxRun;

    float flat0 = 0, flatDeep = 0;
    foreach (deg; [0.0f, 30.0f, 60.0f, 75.0f]) {
        const float phi = deg * PI / 180.0f;
        Vec3 axis = right * cos(phi) + back * sin(phi);   // unit, tilts into depth

        // The PRE-SNAP scalar, deliberately. The quantum is 0.002 and this
        // run delivers ~0.24, so a half-quantum is 0.4 % — four times the
        // tolerance the gain is worth pinning to, and it varies per axis
        // because it depends on where each `t` falls between steps. Reading
        // the snapped value here would measure the grid and call it the gain,
        // which is exactly the mistake the reference's own three legs invite:
        // their GEOMETRY differed by 3 % between axes while `t` was
        // bit-constant. `axisArmDelta` is pinned against this body separately.
        bool skip;
        float t = axisArmDeltaUnsnapped(600 + pxRun, 400, 600, 400,
                                        base, axis, vp, skip);
        assert(!skip);
        assert(abs(t - wantT) < 1e-3f * wantT,
               "the ported gain is a FLAT pixel scale: the same pixel run "
               ~ "along an axis's screen direction must give the same world "
               ~ "length however foreshortened that axis is. A 1/cos here "
               ~ "means the foreshortening compensation crept back in.");

        // The editor's own conversion on the same input, for contrast: its
        // gain is `axisLen/|s|`, and `|s|` shrinks with the foreshortening.
        // Straight into the core, in the handler entry's shape (unit
        // direction + an arrow length), so the comparison is against the law
        // and not against one entry point's non-unit-axis convention.
        const float armLen = 0.01f * corpusCams[0].dist;
        bool skipB;
        Vec3 d = screenAxisWorldDelta(600 + pxRun, 400, 600, 400,
                                      base, base + axis * armLen,
                                      axis, armLen, vp, skipB);
        assert(!skipB);
        float dl = vlen(d);
        if (deg == 0.0f)  flat0    = dl;
        if (deg == 75.0f) flatDeep = dl;
    }

    // The two laws are not the same law, and the amount they differ by is the
    // foreshortening. 1/cos(75deg) = 3.86.
    assert(flatDeep > 3.5f * flat0,
           "the editor's own axis conversion must still be the compensated "
           ~ "one — if it stopped growing with the foreshortening, the port "
           ~ "has leaked out of its scope into every other axis handle");

    // Broadside, at the pivot's own depth, the two differ by exactly the 5/4
    // the pixel-size read names: a perspective axis drag moves 0.8x as far as
    // a cursor-locked one. This is the user-visible half of the port.
    assert(abs(flat0 / wantT - 1.25f) < 0.01f * 1.25f,
           "broadside, the ported conversion must be exactly 4/5 of the "
           ~ "cursor-locked one");
}

unittest {  // LAW A ported: measured from the press, and linear in the offset.
    auto vp = corpusViewport(corpusCams[0]);
    Vec3 base = Vec3(0.1f, 0.4f, -0.2f);
    Vec3 axis = Vec3(1, 0, 0);
    bool skip;

    // At the press pixel the conversion is exactly zero, so a gesture that
    // returns to where it started has delivered nothing. That is what the
    // cumulative form buys over the incremental one, and it holds for any
    // path in between because the answer depends only on the current pixel.
    // True of the SHIPPED (rounded) entry point as well as the raw one — the
    // rounding must not turn "back where I pressed" into half a step of
    // drift — and true under EVERY arm of the setting, because zero rounds to
    // zero on any step and `None` does not round at all.
    assert(axisArmDeltaUnsnapped(731, 402, 731, 402, base, axis, vp, skip) == 0.0f);
    assert(!skip);
    foreach (m; [CoordinateRounding.None,  CoordinateRounding.Normal,
                 CoordinateRounding.Fine,  CoordinateRounding.Fixed,
                 CoordinateRounding.ForcedFixed]) {
        assert(axisArmDelta(731, 402, 731, 402, base, axis, vp, skip,
                            m, kFixedIncrementDefault) == 0.0f);
        assert(!skip);
    }

    // Linearity is a property of the GAIN, so it is measured pre-snap. The
    // shipped scalar is a staircase on top of this line and cannot be linear
    // by construction; asserting linearity on it would only be asserting that
    // the rounding is absent.
    const float one = axisArmDeltaUnsnapped(731 + 120, 402 - 60, 731, 402,
                                            base, axis, vp, skip);
    assert(!skip && one != 0.0f);

    // LINEAR in the pixel offset, in BOTH components. That is what makes the
    // cumulative form safe to deliver as a difference of running totals: the
    // increments a call site emits sum to the one-shot total whatever the
    // event count, because there is no per-event term to accumulate.
    import std.math : abs;
    foreach (f; [0.5f, 2.0f, -1.0f]) {
        const float scaled = axisArmDeltaUnsnapped(731 + cast(int)(120 * f),
                                                   402 + cast(int)(-60 * f),
                                                   731, 402, base, axis, vp, skip);
        assert(!skip);
        assert(abs(scaled - f * one) <= 1e-4f * abs(one),
               "the conversion must be linear in the pixel offset from the "
               ~ "press — a non-linear term makes a delivered increment "
               ~ "depend on how the drag was cut into events");
    }

    // Separately in y, which the flat-gain test above cannot see: it drives a
    // purely horizontal run.
    const float vert  = axisArmDeltaUnsnapped(731, 402 - 60,  731, 402,
                                              base, axis, vp, skip);
    const float vert2 = axisArmDeltaUnsnapped(731, 402 - 120, 731, 402,
                                              base, axis, vp, skip);
    assert(!skip);
    assert(abs(vert2 - 2.0f * vert) <= 1e-4f * abs(vert2),
           "the vertical pixel component must enter linearly too");
}

unittest {  // LAW A ported: THE STAIRCASE, scored on 19 reference rows.
    import std.math : abs;
    import std.conv : to;
    import std.format : format;

    // 1. The law, row by row, over a 1024x zoom range, with no free
    //    parameter: the step is the nice-number ceiling of ONE pixel's worth
    //    of world. `scale` is the reference's own, `step` is what its view
    //    carried at that scale, and only `1/scale` is handed to the function.
    foreach (i, row; refStepRows) {
        const double got = axisDragRoundingStep(CoordinateRounding.Fine,
                                           1.0 / row.scale,
                                           kFixedIncrementDefault);
        assert(abs(got - row.step) <= 1e-12 * row.step,
               format("the rounding step must be stepLadderCeil(pixelSize) at "
                    ~ "every zoom: row %d, scale %.2f (pixelSize %.9g) wants "
                    ~ "%.9g, got %.9g. A constant reproduces at most one of "
                    ~ "these nineteen rows.",
                    i, row.scale, 1.0 / row.scale, row.step, got));
    }

    // 2. It is a STAIRCASE — flat over a band, then a jump. This is the
    //    property a test that samples ONE zoom cannot see, and the reason a
    //    constant survived here as long as it did. Both halves are asserted
    //    because either alone is satisfiable by the wrong law: a constant
    //    passes "flat" and a scaling passes "jumps".
    size_t plateaus = 0, jumps = 0;
    foreach (i; 1 .. refStepRows.length) {
        const double a = axisDragRoundingStep(CoordinateRounding.Fine,
                                         1.0 / refStepRows[i - 1].scale,
                                         kFixedIncrementDefault);
        const double b = axisDragRoundingStep(CoordinateRounding.Fine,
                                         1.0 / refStepRows[i].scale,
                                         kFixedIncrementDefault);
        if (a == b) plateaus++; else jumps++;
    }
    assert(plateaus >= 6,
           "the law must be FLAT over bands — adjacent zoom levels sharing a "
           ~ "step. Got only " ~ plateaus.to!string ~ " plateaus across these "
           ~ "19 rows, which is what a law continuous in the zoom looks like");
    assert(jumps >= 8,
           "and it must JUMP between bands. Got only " ~ jumps.to!string
           ~ " jumps, which is what a constant looks like");

    // 3. Every value the law can produce is on the ladder, over a zoom range
    //    far wider than the rows — a mantissa of 1, 2 or 5 times a power of
    //    ten, and nothing else.
    import std.math : log10, floor, pow;
    for (double px = 1e-7; px < 1e2; px *= 1.07) {
        const double s = axisDragRoundingStep(CoordinateRounding.Fine, px,
                                         kFixedIncrementDefault);
        assert(s >= px && s < 10.0 * px,
               "the step is a CEILING of one pixel, within one decade of it");
        const double e = floor(log10(s) + 1e-9);
        const double m = s / (10.0 ^^ e);
        assert(abs(m - 1) < 1e-6 || abs(m - 2) < 1e-6 || abs(m - 5) < 1e-6
            || abs(m - 10) < 1e-6,
               format("every step must sit on the 1-2-5 ladder; pixelSize "
                    ~ "%.9g gave %.12g (mantissa %.9g)", px, s, m));
    }
}

unittest {  // LAW A ported: the ROUNDING, against the reference's own six rows.
    import std.math : abs, floor;
    import std.conv : to;
    import std.format : format;

    // The step those six rows were rounded to is DERIVED from the scale the
    // recording carried, not written down. If the law is wrong this is the
    // wrong step and every one of the six rows fails — which is what makes
    // this a pin on the formula rather than on a number.
    const double step = axisDragRoundingStep(CoordinateRounding.Fine,
                                        1.0 / REF_SNAP_SCALE,
                                        kFixedIncrementDefault);
    assert(abs(step - 0.002) < 1e-12,
           format("the law must derive that recording's own step from its own "
                ~ "scale: %.9g -> %.12g, wanted 0.002", REF_SNAP_SCALE, step));

    // 1. The rounding law itself, scored on reference data and nothing else.
    //    Six pre-snap scalars in, six post-snap scalars out, the engine's own.
    foreach (i, row; refSnapRows) {
        const float got = snapAxisScalar(cast(float)row.before,
                                         cast(float)step);
        assert(abs(got - row.after) < 1e-6,
               "snapAxisScalar must reproduce the engine's own rounding on row "
               ~ i.to!string
               ~ " — round to the NEAREST step. Rows 2 and 4 round in "
               ~ "opposite directions from nearly the same step count, so a "
               ~ "floor, a ceiling or a truncation fails one of them");
    }

    // 2. It is a step, not a coincidence that fits six numbers: every answer
    //    is an exact multiple, over a range far wider than the rows.
    foreach (n; -500 .. 501) {
        const float t   = 0.0001f * n;            // -0.05 .. +0.05
        const float got = snapAxisScalar(t, cast(float)step);
        const double steps = cast(double)got / step;
        assert(abs(steps - floor(steps + 0.5)) < 1e-3,
               "every rounded scalar must land exactly on a multiple of the "
               ~ "step — a residual here means the rounding is being done "
               ~ "against something other than the step");
        assert(abs(cast(double)got - t) <= 0.5 * step + 1e-6,
               "and it must be the NEAREST multiple: no answer may be more "
               ~ "than half a step from its input");
    }

    // 3. ROUND HALF AWAY FROM ZERO, and the negative half is the point. `t`
    //    is negative on every arm dragged backwards, and `floor(x + 0.5)` —
    //    the spelling a port reaches for first — disagrees there and only
    //    there. Exact half-steps are precisely the inputs on which the two
    //    differ, so those are what this drives.
    //
    //    The step here is a NEGATIVE POWER OF TWO, not the view's own 0.002,
    //    and that is deliberate: `(n + 0.5) * 0.002` is not representable in
    //    float32 and lands on either side of the tie depending on `n`, so
    //    driving the tie rule with it measures the float format instead of
    //    the rule. With a dyadic step every value below is exact and the
    //    assertion is about the rounding and nothing else. The rule is a
    //    property of `snapAxisScalar`, independent of where the step
    //    came from.
    foreach (dyadic; [0.25f, 0.5f, 0.03125f]) {
        foreach (n; 0 .. 9) {
            const float halfUp = (cast(float)n + 0.5f) * dyadic;
            const float wantAway = (cast(float)n + 1.0f) * dyadic;
            assert(snapAxisScalar(halfUp, dyadic) == wantAway,
                   format("a positive half-step must round AWAY from zero: "
                        ~ "%.9g at step %.9g wanted %.9g, got %.9g",
                        halfUp, dyadic, wantAway,
                        snapAxisScalar(halfUp, dyadic)));
            assert(snapAxisScalar(-halfUp, dyadic) == -wantAway,
                   format("a NEGATIVE half-step must round away from zero "
                        ~ "too: %.9g at step %.9g wanted %.9g, got %.9g. "
                        ~ "`floor(x + 0.5)` gives %.9g here — that is the "
                        ~ "whole difference between the two spellings, and an "
                        ~ "axis drag produces a negative `t` every time an "
                        ~ "arm is dragged backwards.",
                        -halfUp, dyadic, -wantAway,
                        snapAxisScalar(-halfUp, dyadic),
                        -(cast(float)n * dyadic)));
        }
    }

    // 4. Symmetric about zero, which is what stops a drag and its reverse
    //    from delivering different lengths — an out-and-back gesture that
    //    ratchets is what an even rounding rule feels like.
    foreach (n; 1 .. 200) {
        const float t = 0.00013f * n;
        assert(snapAxisScalar(-t, cast(float)step)
               == -snapAxisScalar(t, cast(float)step),
               "the rounding must be odd: a gesture dragged out and back must "
               ~ "cancel exactly, and it cannot if +t and -t round differently");
    }

    // 5. The shipped entry point IS the gain with this rounding on top — the
    //    two halves are pinned separately above and composed here, so neither
    //    can drift away from the other unnoticed.
    auto vp = corpusViewport(corpusCams[0]);
    Vec3 base = Vec3(0.1f, 0.4f, -0.2f);
    Vec3 axis = Vec3(1, 0, 0);
    const float vpStep = cast(float)axisDragRoundingStep(
        CoordinateRounding.Fine, viewWorldPerPixel(vp), kFixedIncrementDefault);
    assert(vpStep > 0);
    bool skipRaw, skipSnapped;
    bool sawAnySnap = false;
    foreach (px; [3, 17, 40, 91, 137, -22, -75, -160]) {
        const float raw  = axisArmDeltaUnsnapped(731 + px, 402, 731, 402,
                                                 base, axis, vp, skipRaw);
        const float snap = axisArmDelta(731 + px, 402, 731, 402,
                                        base, axis, vp, skipSnapped,
                                        CoordinateRounding.Fine,
                                        kFixedIncrementDefault);
        assert(!skipRaw && !skipSnapped);
        assert(snap == snapAxisScalar(raw, vpStep),
               "axisArmDelta must be exactly snapAxisScalar(axisArmDeltaUnsnapped) "
               ~ "at the view's own step — if the shipped path stops going "
               ~ "through the rounding, the half-step staircase offset is back "
               ~ "on every axis drag");
        if (snap != raw) sawAnySnap = true;
    }
    assert(sawAnySnap,
           "at least one of these runs must actually be moved by the rounding, "
           ~ "or this test is passing on a step of zero and pins nothing");
}

unittest {  // LAW A ported: the GATE — `None` is the exact identity.
    import std.math : abs;
    import std.format : format;

    // The whole path has one gate and it is `step > 0`. There is no fallback
    // constant behind it: with the setting off, `axisArmDelta` returns the
    // gain untouched, bit for bit.
    assert(axisDragRoundingStep(CoordinateRounding.None, 0.0017,
                           kFixedIncrementDefault) == 0.0,
           "the `None` arm must return a step of exactly zero — anything "
           ~ "positive, however small, is still a grid and still lands the "
           ~ "drag on it");

    auto vp = corpusViewport(corpusCams[0]);
    Vec3 base = Vec3(0.1f, 0.4f, -0.2f);
    Vec3 axis = Vec3(1, 0, 0);
    bool skipRaw, skipOff, skipOn;
    bool sawDifference = false;
    foreach (px; [3, 17, 40, 91, 137, -22, -75, -160]) {
        const float raw = axisArmDeltaUnsnapped(731 + px, 402, 731, 402,
                                                base, axis, vp, skipRaw);
        const float off = axisArmDelta(731 + px, 402, 731, 402,
                                       base, axis, vp, skipOff,
                                       CoordinateRounding.None,
                                       kFixedIncrementDefault);
        const float on  = axisArmDelta(731 + px, 402, 731, 402,
                                       base, axis, vp, skipOn,
                                       CoordinateRounding.Fine,
                                       kFixedIncrementDefault);
        assert(!skipRaw && !skipOff && !skipOn);
        assert(off == raw,
               format("`None` must be the EXACT identity, not a fine step: "
                    ~ "%d px gave %.9g against a raw %.9g", px, off, raw));
        if (on != off) sawDifference = true;
    }
    assert(sawDifference,
           "and `Fine` must actually differ from `None` on this camera — "
           ~ "otherwise this test would pass with the whole term deleted");

    // A non-positive or non-finite step is the identity too, by the same
    // gate: no arm may fall back to a constant when its own step is unset.
    foreach (bad; [0.0f, -0.002f, float.nan]) {
        assert(snapAxisScalar(0.0331f, bad) == 0.0331f,
               "a non-positive or NaN step must leave the scalar alone");
    }
    assert(axisDragRoundingStep(CoordinateRounding.Fine, 0.0, 0.01) == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fine, -1.0, 0.01) == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fine, double.nan, 0.01) == 0.0);
    assert(axisDragRoundingStep(CoordinateRounding.Fine, double.infinity, 0.01) == 0.0);
}

unittest {  // LAW B: the finite-difference step is a STEP, not a gain.
    // The matrix divides by the same step it differenced with, so the step
    // cancels to first order and a four-decade sweep of it must move the answer
    // by percent, not by decades. This is the assert that catches a port which
    // has started treating a view pixel scale as the GAIN — the single most
    // likely way to mis-read this law, and the shape of every fitted "1.53x"
    // that circulated before it was read.
    //
    // What is left over is the forward difference's own O(step) bias, which the
    // reference carries too (it differences forward at ten pixels' worth of
    // world, and so do we).
    foreach (c; corpusCams[0 .. 1] ~ corpusCams[2 .. 4]) {
        auto vp = corpusViewport(c);
        Vec3 anchor = Vec3(0.1f, 0.5f, -0.2f);

        auto def = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp);
        assert(def.valid);
        Vec3 want = def.apply(100.0f, 40.0f);
        assert(vlen(want) > 1e-6f);

        foreach (step; [1e-5f, 1e-4f, 1e-3f, 1e-2f, 1e-1f]) {
            auto j = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp, step);
            assert(j.valid);
            float err = vlen(j.apply(100.0f, 40.0f) - want) / vlen(want);
            assert(err < 2.5e-2f,
                   "a 10000x change of finite-difference step must not change "
                   ~ "the conversion by more than a couple of percent");
        }

        // …and as the step shrinks the difference quotient must SETTLE on the
        // derivative. It only settles if the projection difference is taken at
        // more than float precision: two pixel values that differ in their last
        // few bits carry no derivative at all, and the quotient then grows like
        // 1/step instead of converging. This is the assert that holds the
        // double-precision finite difference in place.
        auto tiny  = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp, 1e-6f);
        auto small = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp, 1e-5f);
        assert(tiny.valid && small.valid);
        Vec3 a = tiny.apply(100.0f, 40.0f), b = small.apply(100.0f, 40.0f);
        assert(vlen(a - b) <= 5e-3f * vlen(b),
               "the difference quotient must converge as the step shrinks");
    }
}

unittest {  // LAW B: linear in the pixel offset => invariant in the event count.
    // The harness asserts this across the process boundary (same total
    // displacement at N = 1, 5, 20 must give the same world result). It holds
    // here for the same reason it holds there: the matrix does not depend on
    // the pixels, so summing increments through a frozen matrix equals one
    // multiply of the summed offset.
    auto vp = corpusViewport(corpusCams[0]);
    Vec3 anchor = Vec3(0, 0.5f, 0);
    auto j = planeJacobian(anchor, Vec3(1,0,0), Vec3(0,1,0), vp);
    assert(j.valid);

    Vec3 one = j.apply(100.0f, -60.0f);
    foreach (n; [1, 5, 20]) {
        Vec3 acc = Vec3(0, 0, 0);
        foreach (i; 0 .. n)
            acc = acc + j.apply(100.0f / n, -60.0f / n);
        assert(vlen(acc - one) <= 1e-5f * vlen(one),
               "N events of D/N must equal one event of D");
    }
}

unittest {  // LAW B: under an affine projection the port IS the exact solve.
    // Orthographic projection has no perspective divide, so the screen map is
    // affine and its first-order linearisation is exact. Agreement here is what
    // says the change is a LINEARISATION and not a change of gain: no scalar
    // was introduced anywhere.
    Viewport vp;
    Vec3 eye = Vec3(3, 4, 9), focus = Vec3(0, 0, 0);
    vp.view   = lookAt(eye, focus, Vec3(0, 1, 0));
    vp.proj   = orthographicMatrix(2.0f, 1426.0f / 966.0f, 0.001f, 100.0f);
    vp.width  = 1426; vp.height = 966;
    vp.eye    = eye;  vp.focus  = focus;

    Vec3 center = Vec3(0.1f, 0.2f, -0.3f);
    bool skipNew, skipOld;
    Vec3 got  = planeDragDelta(760, 500, 660, 560, 3, center, vp, skipNew);
    Vec3 want = exactPlaneDelta(760, 500, 660, 560, center,
                                Vec3(0, 0, 1), vp, skipOld);   // Z-dominant view
    assert(!skipNew && !skipOld);
    assert(vlen(got - want) <= 1e-4f * vlen(want),
           "under an affine projection the frozen linearisation must reproduce "
           ~ "the exact ray/plane difference");
}

unittest {  // LAW B: how far the frozen linearisation is from the exact solve.
    // The behaviour a user can feel, stated as a number rather than as "it
    // drifts". Same camera, same anchor, one press, drags of growing length:
    // the frozen matrix is exact at the press and falls behind the exact solve
    // as the cursor leaves the anchor's neighbourhood, because a perspective
    // screen map is not affine.
    auto vp = corpusViewport(corpusCams[2]);       // the corpus far camera
    Vec3 center = Vec3(0, 0.5f, 0);
    Vec3 n = Vec3(0, 0, 1);
    float ax, ay, az;
    assert(projectToWindowFull(center, vp, ax, ay, az));
    int px = cast(int)ax, py = cast(int)ay;        // press ON the anchor

    // Measured on this camera, frozen against exact, dragging horizontally
    // from the anchor's own pixel:
    //     10 px   0.007 %      100 px   1.27 %
    //     50 px   0.56  %      300 px   4.10 %      500 px  6.92 %
    // The frozen matrix is always the SHORTER of the two: the plane recedes as
    // the cursor leaves the anchor, so the exact solve keeps buying more world
    // per pixel while the linearisation keeps the press-time rate.
    struct Row { int dpx; float lo, hi; }
    immutable Row[] rows = [ Row( 10, 0.0f,    0.001f),
                             Row( 50, 0.002f,  0.010f),
                             Row(100, 0.006f,  0.020f),
                             Row(300, 0.025f,  0.060f) ];
    foreach (r; rows) {
        bool s1, s2;
        Vec3 frozen = planeDragDelta(px + r.dpx, py, px, py, 3, center, vp, s1);
        Vec3 exact  = exactPlaneDelta(px + r.dpx, py, px, py, center, n, vp, s2);
        assert(!s1 && !s2);
        float rel = vlen(frozen - exact) / vlen(exact);
        assert(rel >= r.lo && rel <= r.hi,
               "frozen-vs-exact divergence must stay first-order in drag length");
        assert(vlen(frozen) <= vlen(exact) * 1.0005f,
               "the frozen linearisation is the shorter of the two");
    }
}

unittest {  // LAW B: the result stays in the plane, whatever the in-plane basis.
    auto vp = corpusViewport(corpusCams[3]);   // side camera, X-dominant
    Vec3 center = Vec3(0.2f, -0.1f, 0.4f);
    bool skip;
    Vec3 d = planeDragDelta(700, 380, 600, 500, 3, center, vp, skip);
    assert(!skip);
    assert(abs(d.x) <= 1e-6f * (vlen(d) + 1e-6f),
           "an X-normal plane drag must have no X component");

    // An arbitrary (non-basis) plane normal handed in by a caller: the result
    // must still lie in that plane, which is what the orthonormal completion
    // in `inPlaneAxes` is for.
    Vec3 oblique = normalize(Vec3(0.3f, 0.6f, 0.74f));
    Vec3 od = planeDragDelta(700, 380, 600, 500, 3, center, vp, skip,
                             Vec3(1,0,0), Vec3(0,1,0), Vec3(0,0,1), oblique);
    assert(!skip);
    assert(abs(dot(od, oblique)) <= 1e-5f * (vlen(od) + 1e-6f),
           "an oblique plane drag must have no component along its normal");
}
