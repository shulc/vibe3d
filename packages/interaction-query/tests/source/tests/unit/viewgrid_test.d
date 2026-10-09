// Module unittests for `viewgrid`, moved verbatim out of source/viewgrid.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.viewgrid_test;

import std.math : log10, floor, pow, fabs, isFinite, sqrt, isNaN;
import math : Vec3, Viewport;
import math : lookAt, perspectiveMatrix, orthographicMatrix;
import std.math : PI, sin, cos, tan;
import viewgrid;

unittest {
    // ---- The mask really is a 3-bit set --------------------------------
    //
    // Asserted as the RULE (bit 0 admits 2, bit 1 admits 2.5, bit 2 admits 5,
    // and 1 and 10 are always in) against the table, rather than restating the
    // eight rows the table already contains. A transcription slip in the table
    // fails this; restating the rows would not.
    foreach (mask; kGridMaskMin .. kGridMaskMax + 1) {
        const r = gridRungs(mask);
        assert(r.length >= 2);
        assert(r[0] == 1.0,             "every ladder starts at 1");
        assert(r[$ - 1] == 10.0,        "every ladder ends at 10");
        bool has(double m) { foreach (v; r) if (v == m) return true; return false; }
        assert(has(2.0)   == ((mask & GridRung.two) != 0),
               "bit 0 must be exactly the admission of mantissa 2");
        assert(has(2.5)   == ((mask & GridRung.twoAndAHalf) != 0),
               "bit 1 must be exactly the admission of mantissa 2.5");
        assert(has(5.0)   == ((mask & GridRung.five) != 0),
               "bit 2 must be exactly the admission of mantissa 5");
        // Ascending, no duplicates.
        foreach (i; 1 .. r.length) assert(r[i] > r[i - 1]);
        // Length is 2 + popcount(mask).
        int pc = ((mask & 1) != 0) + ((mask & 2) != 0) + ((mask & 4) != 0);
        assert(r.length == 2 + pc);
    }
    assert(kGridMaskDefault == 5);
    assert(gridRungs(kGridMaskDefault) == [1.0, 2.0, 5.0, 10.0]);
}

unittest {
    // ---- niceCeil is a CEILING on the ladder ---------------------------
    enum int m5 = kGridMaskDefault;
    // Exact rungs are fixed points, in several decades and both signs of the
    // exponent — as doubles AND as the floats the product actually passes in.
    // The float half is the one that caught `kLogTol` being ten orders too
    // tight: `cast(double)0.002f` is above the double 0.002, so a bare
    // comparison ceils it to the next rung.
    foreach (double v; [0.001, 0.002, 0.005, 0.01, 0.02, 0.05,
                        0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 100.0]) {
        assert(fabs(niceCeil(m5, v) - v) <= 1e-9 * v,
               "an exact rung must be its own ceiling");
        immutable double vf = cast(double)cast(float)v;
        assert(fabs(niceCeil(m5, vf) - v) <= 1e-6 * v,
               "a rung that arrived as a float must still be its own ceiling");
    }
    // Strictly above a rung goes to the NEXT rung. The probes sit 5e-4 above
    // rather than 1e-7 above, because the log tolerance deliberately absorbs
    // a float ulp — see `kLogTol`. 5e-4 is still three orders inside the
    // smallest ladder gap, so this is a real discrimination, not slack.
    assert(fabs(niceCeil(m5, 2.001) - 5.0) < 1e-9);
    assert(fabs(niceCeil(m5, 5.001) - 10.0) < 1e-9);
    assert(fabs(niceCeil(m5, 1.001) - 2.0) < 1e-9);
    assert(fabs(niceCeil(m5, 0.0300000) - 0.05) < 1e-9);
    assert(fabs(niceCeil(m5, 0.1176000) - 0.2) < 1e-9);
    assert(fabs(niceCeil(m5, 11.0) - 20.0) < 1e-9);
    // Never below its argument, and never more than the ladder's worst gap
    // above it (for {1,2,5,10} that is 5/2 = 2.5x, from just above 2).
    foreach (i; 0 .. 400) {
        immutable double x = 0.0007 * pow(1.03, cast(double)i);
        immutable double g = niceCeil(m5, x);
        assert(g >= x * (1 - 1e-9), "the ceiling must not fall below its input");
        assert(g <= x * 2.5000001,  "the ceiling must not exceed the worst gap");
        assert(gridStepIsRung(m5, g), "the ceiling must land ON a rung");
    }
    // The mask really changes the answer: with {1,10} only, 0.03 ceils to 0.1.
    assert(fabs(niceCeil(0, 0.03) - 0.1) < 1e-9);
    assert(fabs(niceCeil(4, 0.03) - 0.05) < 1e-9);   // {1,5,10}
    assert(fabs(niceCeil(2, 0.03) - 0.1) < 1e-9);    // {1,2.5,10}
    assert(fabs(niceCeil(6, 0.021) - 0.025) < 1e-9); // {1,2.5,5,10}
    // Zero / non-finite are the disabled value, not a crash.
    assert(niceCeil(m5, 0.0) == 0.0);
    assert(niceCeil(m5, double.nan) == 0.0);
    assert(niceCeil(m5, double.infinity) == 0.0);
    // Sign is carried, magnitude ceiled.
    assert(fabs(niceCeil(m5, -0.03) + 0.05) < 1e-9);
}

unittest {
    // ---- Every ladder is closed under x10 ------------------------------
    //
    // This is what makes `10 * gridSize` and `niceCeil(250 * pixelSize)` the
    // same number, which the relocate quantum relies on.
    foreach (mask; kGridMaskMin .. kGridMaskMax + 1) {
        foreach (i; 0 .. 300) {
            immutable double y = 0.0013 * pow(1.05, cast(double)i);
            immutable double a = 10.0 * niceCeil(mask, y);
            immutable double b = niceCeil(mask, 10.0 * y);
            assert(fabs(a - b) <= 1e-9 * b,
                   "the ladder must be closed under multiplication by ten");
        }
    }
}

unittest {
    // ---- The step MOVES IN RUNGS, and only in rungs --------------------
    //
    // Sweep pixelSize continuously across a whole decade and require that the
    // step (a) only ever takes ladder values, (b) never decreases, and (c)
    // takes exactly as many distinct values as the ladder has rungs in that
    // decade. (c) is the one that fails for a grid that glides: a continuous
    // law sweeps hundreds of distinct values across the same range.
    ViewGridPrefs p;                      // shipped defaults, mask 5
    double[] seen;
    double prev = 0;
    enum int N = 2000;
    foreach (i; 0 .. N + 1) {
        // pixelSize from 1e-3 to 1e-2, geometric so the sweep is uniform in
        // the log space the law works in.
        immutable float px = cast(float)(0.001 * pow(10.0, cast(double)i / N));
        immutable float g  = viewGridSize(px, p);
        assert(gridStepIsRung(p.rungMask, g), "the drawn step must be a rung");
        assert(g >= prev * (1 - 1e-6), "the step must not decrease as we zoom out");
        prev = g;
        bool known = false;
        foreach (s; seen) if (fabs(s - g) <= 1e-9 * g) known = true;
        if (!known) seen ~= g;
    }
    // A decade of pixelSize maps to a decade of 25*pixelSize, which covers
    // exactly the ladder's rung count worth of distinct steps (the endpoints
    // can add one more when the decade boundary falls inside the range).
    assert(seen.length >= 4 && seen.length <= 5,
           "a decade of zoom must produce a handful of steps, not a continuum");
}

unittest {
    // ---- A cell is between 25 and 25*gap pixels wide, always -----------
    //
    // The size law's actual claim, stated in the units it is about. For the
    // shipped ladder the worst gap is 2.5x, so a cell is 25..62.5 px.
    ViewGridPrefs p;
    double lo = double.max, hi = 0;
    foreach (i; 0 .. 500) {
        immutable float px = cast(float)(1e-5 * pow(1.05, cast(double)i));
        immutable float g  = viewGridSize(px, p);
        immutable double cellPx = cast(double)g / px;
        assert(cellPx >= 25.0 * (1 - 1e-4),
               "a grid cell can never be narrower than 25 screen pixels");
        assert(cellPx <= 25.0 * 2.5 * (1 + 1e-4),
               "a grid cell can never be wider than the ladder's worst gap");
        if (cellPx < lo) lo = cellPx;
        if (cellPx > hi) hi = cellPx;
    }
    // Both bounds are ATTAINED over a sweep this long, so they are the law's
    // numbers and not a slack box that a different constant would also fit —
    // 25 is written literally on purpose, so changing `kGridSizePixels`
    // fails HERE, where the claim is about screen pixels.
    assert(lo < 25.0 * 1.01, "the 25-pixel floor must be attained, not merely respected");
    assert(hi > 25.0 * 2.5 * 0.99, "the 62.5-pixel ceiling must be attained");
    // Degenerate views are refused rather than producing a step.
    assert(viewGridSize(0.0f, p) == 0.0f);
    assert(viewGridSize(-1.0f, p) == 0.0f);
    assert(viewGridSize(float.nan, p) == 0.0f);
}

unittest {
    // ---- The fixed-size arm, and its 2*PI guard ------------------------
    ViewGridPrefs p;
    p.fixedSize = true;
    p.sizeFixed = 0.1f;
    // pixelSize such that the automatic size is 1.0: 25*px in (0.5, 1.0].
    immutable float pxCoarse = 0.03f;                  // 25*px = 0.75 -> 1.0
    assert(fabs(viewGridSize(pxCoarse, p) - 0.1f) < 1e-6f,
           "the fixed size wins when it is not too fine (2*PI*0.1 <= 1.0)");
    // pixelSize such that the automatic size is 0.5: 2*PI*0.1 = 0.628 > 0.5,
    // so the guard rejects the fixed size and the automatic one stands.
    immutable float pxFine = 0.012f;                   // 25*px = 0.3 -> 0.5
    assert(fabs(viewGridSize(pxFine, p) - 0.5f) < 1e-6f,
           "the fixed size is refused once it is more than 2*PI times finer");
    // Off by default, and then the arm cannot fire at all.
    ViewGridPrefs q;
    assert(!q.fixedSize);
    assert(fabs(viewGridSize(pxCoarse, q) - 1.0f) < 1e-6f);
}

unittest {
    // ---- The sub-step is ONE pixel, not a tenth of the size -------------
    //
    // These are different numbers and the difference is the point: a tenth of
    // the drawn size would be 2.5 screen pixels, and the default arm is one.
    ViewGridPrefs p;
    assert(p.snapMode == GridSnapMode.onePixel);
    foreach (i; 0 .. 200) {
        immutable float px = cast(float)(1e-4 * pow(1.06, cast(double)i));
        immutable float g  = viewGridSize(px, p);
        immutable float s  = viewGridSubStep(px, g, p);
        assert(fabs(s - cast(float)niceCeil(p.rungMask, px)) <= 1e-9f * s);
        assert(s >= px * (1 - 1e-5), "the sub-step is at least one pixel");
        assert(s <= g, "the sub-step is never coarser than the drawn step");
    }
    // The other arms exist and are distinguishable.
    ViewGridPrefs off; off.snapMode = GridSnapMode.off;
    assert(viewGridSubStep(0.004f, 0.2f, off) == 0.0f);
    ViewGridPrefs tenth; tenth.snapMode = GridSnapMode.tenthOfSize;
    assert(fabs(viewGridSubStep(0.004f, 0.2f, tenth) - 0.02f) < 1e-6f);
    ViewGridPrefs fx; fx.snapMode = GridSnapMode.fixed; fx.snapFixed = 0.01f;
    assert(fabs(viewGridSubStep(0.004f, 0.2f, fx) - 0.01f) < 1e-6f);
    ViewGridPrefs ff; ff.snapMode = GridSnapMode.fromFixed; ff.snapFixed = 0.05f;
    // gridSize 0.2, d0 0.05 -> n = 4 < 12 -> 4*0.05 = 0.2
    assert(fabs(viewGridSubStep(0.004f, 0.2f, ff) - 0.2f) < 1e-6f);
    // d0 > gridSize -> d0 itself
    ff.snapFixed = 0.5f;
    assert(fabs(viewGridSubStep(0.004f, 0.2f, ff) - 0.5f) < 1e-6f);
}

unittest {
    // ---- The relocate quantum is ten steps, exactly ---------------------
    ViewGridPrefs p;
    foreach (i; 0 .. 300) {
        immutable float px = cast(float)(1e-4 * pow(1.04, cast(double)i));
        immutable float q  = relocateQuantum(px, p);
        assert(fabs(q - 10.0f * viewGridSize(px, p)) <= 1e-6f * q);
        // ...and equivalently the ceiling of 250 pixels, via the x10 closure.
        assert(fabs(q - cast(float)niceCeil(p.rungMask, 250.0 * px)) <= 1e-5f * q);
        assert(gridStepIsRung(p.rungMask, q));
    }
    assert(relocateQuantum(0.0f, p) == 0.0f);
}

unittest {
    // ---- gridStepIsRung rejects a value BETWEEN rungs -------------------
    //
    // Without this the sweep assertions above would pass for a grid that
    // glides, which is the whole distinction this module exists to make.
    enum int m5 = kGridMaskDefault;
    assert( gridStepIsRung(m5, 0.2));
    assert( gridStepIsRung(m5, 1.0));
    assert( gridStepIsRung(m5, 10.0));
    assert( gridStepIsRung(m5, 0.005));
    assert(!gridStepIsRung(m5, 0.3),  "0.3 is not on the {1,2,5,10} ladder");
    assert(!gridStepIsRung(m5, 0.25), "0.25 is not on the {1,2,5,10} ladder");
    assert(!gridStepIsRung(m5, 1.37));
    assert(!gridStepIsRung(m5, 0.0));
    assert(!gridStepIsRung(m5, -1.0));
    assert(!gridStepIsRung(m5, double.nan));
    // ...and accepts 0.25 once the mask admits 2.5.
    assert( gridStepIsRung(6, 0.25));
}
