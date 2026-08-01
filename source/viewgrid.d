module viewgrid;

// ---------------------------------------------------------------------------
// The view grid: its step is a length in SCREEN pixels, not in world units.
//
// The whole point, in one sentence: the grid step is the world length of 25
// screen pixels, pushed UP to the next rung of a mantissa ladder. The grid is
// therefore anchored to the SCREEN, not to the world — which is why it moves
// as you zoom, and why a fixed world step (what vibe3d shipped before this
// module) can never behave like it at more than one zoom level.
//
//     gridSize     = niceCeil(mask, 25 * pixelSize)
//     gridSubStep  = niceCeil(mask,  1 * pixelSize)        [snapMode == 2]
//     niceStep(x)  = sign(x) * m * 10^floor(log10|x|)
//
// `m` comes from an eight-entry ladder of mantissa SETS selected by a 3-bit
// mask — bit 0 admits 2, bit 1 admits 2.5, bit 2 admits 5; 1 and 10 are always
// in. The shipped default is mask 5, i.e. the rung set {1, 2, 5, 10}.
//
// TWO CONSEQUENCES THAT ARE LOAD-BEARING ELSEWHERE, both asserted below:
//
//  1. The output is a RUNG, never an interpolation between rungs. A grid whose
//     step glided smoothly with zoom would look similar and be a different
//     thing; `gridStepIsRung` is the property that separates them, and the
//     renderer is tested against it.
//
//  2. Every ladder contains both 1 and 10, so every ladder is closed under
//     multiplication by ten:  10 * niceCeil(mask, y) == niceCeil(mask, 10*y).
//     That is what lets the click-relocate quantum be written either as
//     `10 * gridSize` (how it is read) or as `niceCeil(250 * pixelSize)`
//     (how it computes) with no case analysis.
//
// WHAT IS MEASURED AND WHAT IS CHOSEN. The ladder table, the mask decoding,
// the 25, the log-space comparison, the floor-of-log10 decade and the
// round-half-away-from-zero sub-step are all read, not fitted. The one thing
// the read does not pin is the LOG-SPACE TIE in `niceStep`'s round-to-nearest
// arm (`roundUp == false`), which no shipped configuration reaches — the
// default sub-step mode is the ceiling arm. It is written "the lower rung
// wins", and that choice is marked at its site rather than hidden.
//
// This module is pure arithmetic on a pixel size. It deliberately does not
// know what a camera is; see `viewWorldPerPixel` at the bottom, which is the
// only function here that touches a `Viewport`, and which exists here because
// the grid needs it and it is a property of the VIEW rather than of a drag.
// ---------------------------------------------------------------------------

import std.math : log10, floor, pow, fabs, isFinite, sqrt, isNaN;

import math : Vec3, Viewport;

// ---------------------------------------------------------------------------
// The mantissa ladder
// ---------------------------------------------------------------------------

/// The rung mask is a 3-bit set. Named so the bits are readable at call sites
/// and so a UI can offer them without re-deriving the meaning.
enum GridRung : int {
    two       = 1,   /// bit 0 — admits mantissa 2
    twoAndAHalf = 2, /// bit 1 — admits mantissa 2.5
    five      = 4,   /// bit 2 — admits mantissa 5
}

/// Lowest / highest legal mask. Every value in between is legal: the mask is
/// a set, not an enumeration of blessed combinations.
enum int kGridMaskMin = 0;
enum int kGridMaskMax = 7;

/// The shipped default: {1, 2, 5, 10}.
enum int kGridMaskDefault = GridRung.two | GridRung.five;   // == 5

/// The grid step is the world length of this many screen pixels, nice-ceiled.
enum double kGridSizePixels = 25.0;

/// The click-relocate quantum is this many grid steps. Read at its own site;
/// kept here because it is the ladder's `x10` closure that makes it exact.
enum double kRelocateQuantumSteps = 10.0;

// One flat table of 28 mantissas, indexed by (offset, count) per mask — the
// same shape the reference stores it in, kept because the offsets are what
// make the 3-bit decoding checkable rather than asserted.
private immutable double[28] kLadderMantissas = [
    /* mask 0, off  0, n 2 */  1,           10,
    /* mask 1, off  2, n 3 */  1, 2,        10,
    /* mask 2, off  5, n 3 */  1,    2.5,   10,
    /* mask 3, off  8, n 4 */  1, 2, 2.5,   10,
    /* mask 4, off 12, n 3 */  1,         5, 10,
    /* mask 5, off 15, n 4 */  1, 2,      5, 10,
    /* mask 6, off 19, n 4 */  1,    2.5, 5, 10,
    /* mask 7, off 23, n 5 */  1, 2, 2.5, 5, 10,
];
private immutable int[8] kLadderOffset = [0, 2, 5, 8, 12, 15, 19, 23];
private immutable int[8] kLadderCount = [2, 3, 3, 4,  3,  4,  4,  5];

/// The mantissa set a mask selects, ascending, always beginning at 1 and
/// ending at 10.
const(double)[] gridRungs(int mask) @safe pure nothrow @nogc {
    if (mask < kGridMaskMin || mask > kGridMaskMax) mask = kGridMaskDefault;
    return kLadderMantissas[kLadderOffset[mask] .. kLadderOffset[mask] + kLadderCount[mask]];
}

/// `sign(x) * m * 10^floor(log10|x|)`, with `m` chosen from the mask's ladder:
/// the CEILING of `|x|` on the ladder when `roundUp`, the log-nearest when not.
///
/// The comparison is done in LOG space — against `log10(m)` and the fractional
/// part of `log10|x|` — because that is how it is read. It carries one
/// implementation term the read does not: a log-space tolerance, without which
/// an exact rung is not a fixed point of its own ceiling. See its site.
///
/// Non-finite input returns 0, which is this module's "no step" value and is
/// what every consumer already treats as disabled. `x == 0` likewise.
double niceStep(int mask, bool roundUp, double x) @safe pure nothrow @nogc {
    if (!isFinite(x) || x == 0.0) return 0.0;

    immutable double sgn = x < 0 ? -1.0 : 1.0;
    immutable double ax  = fabs(x);
    immutable double L   = log10(ax);
    immutable double e   = floor(L);
    immutable double frac = L - e;         // in [0, 1) up to rounding

    const rungs = gridRungs(mask);

    // The round-DOWN candidate is the last rung at or below `frac`; the
    // round-UP candidate is the first at or above. Both always exist for a
    // `frac` in [0,1]: every ladder starts at log10(1) == 0 and ends at
    // log10(10) == 1. The `-1` sentinels below are a guard against a `frac`
    // pushed outside that range by the floor's own rounding, not a real arm.
    // THE TOLERANCE IS NOT DECORATION AND IS NOT A DEVIATION FROM THE READ.
    // `frac` is `log10|x| - floor(log10|x|)`, and for an `x` that IS a rung
    // that recovers `log10(m)` only to within a unit in the last place — so a
    // bare `>=` makes `niceCeil(2.0)` return 5.0 about half the time,
    // depending on which side of `log10(2)` the reconstruction lands. The
    // reference computes in the same doubles and has the same sensitivity;
    // what it does not have is our requirement that an exact rung be a fixed
    // point, which is what the ladder's `x10` closure and the relocate
    // quantum's two spellings both rest on. 1e-12 in log space is a relative
    // 2.3e-12 in value — twelve orders of magnitude tighter than the smallest
    // gap on any ladder (2 -> 2.5), so it cannot merge two rungs.
    enum double kLogTol = 1e-12;

    int down = -1, up = -1;
    foreach (i, m; rungs) {
        immutable double lm = log10(m);
        if (lm <= frac + kLogTol) down = cast(int)i;
        if (up < 0 && lm >= frac - kLogTol) up = cast(int)i;
    }

    int j;
    if (roundUp) {
        j = up >= 0 ? up : cast(int)rungs.length - 1;
    } else if (down < 0) {
        j = up >= 0 ? up : 0;
    } else if (up < 0) {
        j = down;
    } else {
        // NOT PINNED BY ANY READ: the tie. No shipped configuration reaches
        // this arm (the default sub-step mode is the ceiling), so a tie has
        // never been observed. The lower rung wins here; if a capture ever
        // settles it, this `<=` is the one character to change.
        j = (frac - log10(rungs[down]) <= log10(rungs[up]) - frac) ? down : up;
    }

    return sgn * pow(10.0, e) * rungs[j];
}

/// `niceStep` with the ceiling arm — the one the grid uses.
double niceCeil(int mask, double x) @safe pure nothrow @nogc {
    return niceStep(mask, true, x);
}

/// `niceStep` with the round-to-nearest arm.
double niceNearest(int mask, double x) @safe pure nothrow @nogc {
    return niceStep(mask, false, x);
}

/// True when `v` is `m * 10^n` for some `m` in the mask's ladder — i.e. when
/// `v` is a RUNG and not a value between rungs.
///
/// This is the predicate that distinguishes a stepped grid from a smoothly
/// scaled one, so it is a function rather than a test-local helper: the
/// renderer's own assertion and the HTTP test both name it.
bool gridStepIsRung(int mask, double v, double relTol = 1e-5) @safe pure nothrow @nogc {
    if (!isFinite(v) || v <= 0) return false;
    immutable double e = floor(log10(v));
    immutable double m = v / pow(10.0, e);
    foreach (r; gridRungs(mask)) {
        if (fabs(m - r) <= relTol * r) return true;
        // A `v` whose decade the floor put one below (10.0 read as 9.9999…e0
        // vs 1.0e1) still has to match; compare against the neighbouring
        // decade's rungs too rather than widening the tolerance.
        if (fabs(m * 10.0 - r) <= relTol * r) return true;
        if (fabs(m * 0.1  - r) <= relTol * r) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The five parameters, and the shipped defaults
// ---------------------------------------------------------------------------

/// How the grid's SUB-step (the snap step, distinct from the drawn size) is
/// derived. The names are what each arm computes; the numeric values are the
/// read's, so a persisted preference round-trips.
enum GridSnapMode : int {
    off        = 0,  /// no vector snap at all
    tenthOfSize= 1,  /// niceNearest(gridSize / 10)
    onePixel   = 2,  /// niceCeil(pixelSize) — the shipped default
    fromFixed  = 3,  /// a whole number of `snapFixed` per grid cell, capped
    fixed      = 4,  /// `snapFixed` itself
}

/// The grid's five parameters. Every default here is the value the shipped
/// configuration carries, so a default-constructed `ViewGridPrefs` IS the
/// shipped grid.
struct ViewGridPrefs {
    /// The mantissa ladder, as a 3-bit set. THE SETTING — see `viewport.gridSteps`.
    int   rungMask  = kGridMaskDefault;
    /// Which sub-step arm runs.
    GridSnapMode snapMode = GridSnapMode.onePixel;
    /// The "use a fixed grid size instead of the zoom-derived one" arm. OFF by
    /// default. When on, `sizeFixed` replaces the computed size unless it is
    /// more than 2*PI times finer — see `viewGridSize`.
    bool  fixedSize = false;
    float sizeFixed = 0.1f;
    float snapFixed = 0.01f;
}

/// The live grid settings. One per application: the grid is a global
/// preference, not per-cell — a cell's grid differs from its neighbour's only
/// through its own zoom, which is the whole law.
///
/// `prefs.d` persists `rungMask` and seeds it here at startup; the command
/// `viewport.gridSteps` writes both. Mirrored from here rather than read from
/// `g_prefs` at draw time so the renderer has exactly one source.
__gshared ViewGridPrefs g_viewGrid;

// ---------------------------------------------------------------------------
// The law
// ---------------------------------------------------------------------------

/// The drawn grid step, in world units, for a view whose one screen pixel
/// spans `pixelSize` world units.
///
/// `pixelSize <= 0` (or non-finite) means "this view has no usable scale" and
/// returns 0, which every caller reads as "leave the grid alone".
float viewGridSize(float pixelSize, const ref ViewGridPrefs p) @safe pure nothrow @nogc {
    if (!(pixelSize > 0) || !isFinite(pixelSize)) return 0.0f;

    immutable double g = niceCeil(p.rungMask, kGridSizePixels * cast(double)pixelSize);

    // The fixed-size arm, and its guard: the user's fixed size is honoured
    // unless it is more than 2*PI times FINER than the automatic one, at which
    // point the automatic one wins so a zoomed-out view is not asked to draw a
    // ten-thousand-line lattice.
    if (p.fixedSize && p.sizeFixed > 0) {
        enum double twoPi = 6.283185307179586;
        if (twoPi * cast(double)p.sizeFixed <= g) return p.sizeFixed;
    }
    return cast(float)g;
}

/// The grid's sub-step: the step `vectorSnap` rounds a world vector to. This
/// is a SEPARATE number from the drawn size and is not derived from it in the
/// default mode — it is the world length of ONE screen pixel, nice-ceiled.
float viewGridSubStep(float pixelSize, float gridSize,
                      const ref ViewGridPrefs p) @safe pure nothrow @nogc {
    if (!(pixelSize > 0) || !isFinite(pixelSize)) return 0.0f;

    final switch (p.snapMode) {
        case GridSnapMode.off:
            return 0.0f;

        case GridSnapMode.tenthOfSize:
            return cast(float)niceNearest(p.rungMask, cast(double)gridSize / 10.0);

        case GridSnapMode.onePixel:
            return cast(float)niceCeil(p.rungMask, cast(double)pixelSize);

        case GridSnapMode.fromFixed: {
            // As `tenthOfSize`, then re-expressed as a whole number of
            // `snapFixed` per cell — but only while that count stays small.
            immutable double d0 = cast(double)p.snapFixed;
            if (!(d0 > 0)) return 0.0f;
            if (d0 > cast(double)gridSize) return p.snapFixed;
            immutable double n = roundHalfAwayFromZero(cast(double)gridSize / d0);
            if (n < 12.0) return cast(float)((n < 1.0 ? 1.0 : n) * d0);
            return cast(float)niceNearest(p.rungMask, cast(double)gridSize / 10.0);
        }

        case GridSnapMode.fixed:
            return p.snapFixed > 0 ? p.snapFixed : 0.0f;
    }
}

/// The click-relocate out-of-plane quantum: ten grid steps.
///
/// Written as `10 * viewGridSize` because that is how it is read. It is
/// exactly `niceCeil(mask, 250 * pixelSize)` — see the `x10` closure at the
/// top of this file, and the unittest that pins the identity.
float relocateQuantum(float pixelSize, const ref ViewGridPrefs p) @safe pure nothrow @nogc {
    immutable float g = viewGridSize(pixelSize, p);
    return g > 0 ? cast(float)(kRelocateQuantumSteps * cast(double)g) : 0.0f;
}

/// Round half AWAY from zero. Local to this module's `fromFixed` arm; the
/// relocate port has its own float-typed copy at its own site, deliberately
/// (that one is part of a law being restated there and is tested there).
private double roundHalfAwayFromZero(double x) @safe pure nothrow @nogc {
    import std.math : ceil;
    return x >= 0 ? floor(x + 0.5) : ceil(x - 0.5);
}

// ---------------------------------------------------------------------------
// The view's pixel size
// ---------------------------------------------------------------------------

/// World units spanned by one screen pixel, as a property of the VIEW alone —
/// no anchor, no axis, no drag.
///
/// The relation is read, not fitted, from the reference's own perspective
/// initialiser: it derives the eye distance as `500*Z / scale` and the focal
/// length in pixels as `400*Z` for the same `Z`. Eliminating `Z` and `scale`,
/// with `pixelSize == 1/scale`:
///
///     pixelSize = (400/500) * eyeDistance / focalPx      [perspective]
///     pixelSize =              1          / focalPx      [orthographic]
///
/// The 4/5 is not a correction of ours: it is the reference's own ratio
/// between the pixel size it reports and the pixel size its perspective
/// projection actually uses, and it is exactly 1 under an orthographic
/// projection because there the same field IS the projection's scale.
///
/// NOTE FOR WHOEVER MERGES SECOND. The sibling branch `task/lawa-axis-drag`
/// introduces this same function, same name, same body, in `source/drag.d`,
/// where it is the gain of an axis drag. They are one law. When both land,
/// delete one definition and import the other; do not keep two, and do not
/// rename either into a second vocabulary for the same quantity.
///
/// Distinct from `drag.haulWorldPerPixel`, which is also a world length per
/// pixel but is ANCHORED — it varies with the depth of the point being
/// hauled. This one carries no anchor at all.
float viewWorldPerPixel(const ref Viewport vp) @safe pure nothrow @nogc {
    // Pixels per world unit at unit depth: proj[5] is 1/tan(fovY/2) for a
    // perspective projection and 2/(top-bottom) for an orthographic one, and
    // half the pane height converts the NDC half-extent into pixels.
    immutable float focalPx = 0.5f * vp.height * vp.proj[5];
    if (!(focalPx > 1e-9f) || isNaN(focalPx)) return 0.0f;

    // proj[15] is the projection discriminator: 0 = perspective, 1 = ortho.
    if (vp.proj[15] != 0.0f) return 1.0f / focalPx;

    Vec3 d = vp.eye - vp.focus;
    immutable float dist = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    if (!(dist > 1e-9f) || isNaN(dist)) return 0.0f;
    return 0.8f * dist / focalPx;
}

/// The grid step for a view, end to end. The renderer's one call.
float viewGridSizeFor(const ref Viewport vp, const ref ViewGridPrefs p)
        @safe pure nothrow @nogc {
    return viewGridSize(viewWorldPerPixel(vp), p);
}

// ===========================================================================
// Tests
// ===========================================================================

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
    // exponent. This is the property a tolerance-based implementation loses.
    foreach (double v; [0.001, 0.002, 0.005, 0.01, 0.02, 0.05,
                        0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 100.0]) {
        assert(fabs(niceCeil(m5, v) - v) <= 1e-9 * v,
               "an exact rung must be its own ceiling");
    }
    // Strictly above a rung goes to the NEXT rung.
    assert(fabs(niceCeil(m5, 2.0000001) - 5.0) < 1e-9);
    assert(fabs(niceCeil(m5, 5.0000001) - 10.0) < 1e-9);
    assert(fabs(niceCeil(m5, 1.0000001) - 2.0) < 1e-9);
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

version (unittest) {
    import math : lookAt, perspectiveMatrix, orthographicMatrix;
    import std.math : PI, sin, cos, tan;

    private Viewport testViewport(float az, float el, float dist,
                                  int w, int h, float fovY = 45.0f * PI / 180.0f) {
        Vec3 back = Vec3(cos(el) * sin(az), sin(el), cos(el) * cos(az));
        Vec3 focus = Vec3(0, 0, 0);
        Vec3 eye = focus + back * dist;
        Viewport vp;
        vp.view = lookAt(eye, focus, Vec3(0, 1, 0));
        vp.proj = perspectiveMatrix(fovY, cast(float)w / h, 0.001f, 100.0f);
        vp.width = w; vp.height = h; vp.eye = eye; vp.focus = focus;
        return vp;
    }
}

unittest {
    // ---- viewWorldPerPixel is the two algebraic forms, and nothing else --
    enum int w = 1426, h = 966;
    enum float fovY = 45.0f * PI / 180.0f;
    immutable float focalPx = 0.5f * h / tan(fovY / 2);

    foreach (double dist; [0.5, 1.560178, 3.86, 12.559432]) {
        auto vp = testViewport(-0.159244f, 0.265694f, cast(float)dist, w, h, fovY);
        immutable float want = cast(float)(0.8 * dist) / focalPx;
        assert(fabs(viewWorldPerPixel(vp) - want) <= 1e-6f * want,
               "perspective pixel size must be (4/5)*eyeDistance/focalPx");
    }

    // It is a property of the VIEW, so it must not depend on where the camera
    // is pointing — only on how far away it is.
    auto a = testViewport(0.0f,  0.3f, 2.0f, w, h, fovY);
    auto b = testViewport(2.7f, -0.9f, 2.0f, w, h, fovY);
    assert(fabs(viewWorldPerPixel(a) - viewWorldPerPixel(b)) < 1e-7f,
           "pixel size must not depend on azimuth or elevation");

    // Orthographic: exactly 1/focalPx, with NO 4/5 and no distance term.
    Viewport o;
    o.view = lookAt(Vec3(0, 5, 0), Vec3(0, 0, 0), Vec3(0, 0, -1));
    o.proj = orthographicMatrix(1.5f, 800.0f / 600.0f, 0.001f, 100.0f);
    o.width = 800; o.height = 600;
    o.eye = Vec3(0, 5, 0); o.focus = Vec3(0, 0, 0);
    immutable float oFocal = 0.5f * o.height * o.proj[5];
    assert(fabs(viewWorldPerPixel(o) - 1.0f / oFocal) <= 1e-7f,
           "orthographic pixel size is 1/focalPx with no distance term");
    // Moving an orthographic camera further away must NOT change the step.
    auto o2 = o;
    o2.eye = Vec3(0, 50, 0);
    o2.view = lookAt(o2.eye, Vec3(0, 0, 0), Vec3(0, 0, -1));
    assert(viewWorldPerPixel(o2) == viewWorldPerPixel(o));

    // Degenerate views return the disabled value rather than a garbage step.
    Viewport z;
    assert(viewWorldPerPixel(z) == 0.0f);
}

unittest {
    // ---- The grid step doubles when the camera doubles its distance -----
    //
    // ...up to the ladder. This is the user-visible claim: zooming out by a
    // factor of ten multiplies the step by exactly ten (the ladder is closed
    // under x10), and zooming out by a factor that stays inside a rung leaves
    // the step ALONE. Both halves matter; the second is what "stepped" means.
    ViewGridPrefs p;
    auto v1 = testViewport(0.3f, 0.4f, 1.0f, 1426, 966);
    auto v10 = testViewport(0.3f, 0.4f, 10.0f, 1426, 966);
    immutable float g1  = viewGridSizeFor(v1, p);
    immutable float g10 = viewGridSizeFor(v10, p);
    assert(fabs(g10 - 10.0f * g1) <= 1e-5f * g10,
           "ten times the distance is exactly ten times the step");

    // A distance change small enough to stay inside one rung must not move
    // the step at all. 1.0 -> 1.01 cannot cross a rung boundary unless it
    // starts within 1% of one; assert on the pair we can compute.
    immutable float px1 = viewWorldPerPixel(v1);
    immutable float raw = cast(float)(kGridSizePixels * px1);
    // Pick a distance scale that provably keeps 25*px inside (prev, g1].
    immutable float head = g1 / raw;      // > 1 by construction
    if (head > 1.02f) {
        auto vNear = testViewport(0.3f, 0.4f, 1.01f, 1426, 966);
        assert(viewGridSizeFor(vNear, p) == g1,
               "a zoom that does not cross a rung must not move the step");
    }
}
