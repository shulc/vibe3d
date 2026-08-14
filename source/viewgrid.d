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

/// Half-extent of the drawn lattice, in CELLS. The grid mesh is built once as
/// a unit lattice spanning [-kGridHalfCells, +kGridHalfCells] and scaled by
/// the step at draw time, so its world extent is `kGridHalfCells * gridSize`
/// and its SCREEN extent is a constant 50 * 25..62.5 pixels — the grid always
/// covers the same fraction of the viewport at every zoom, which is the point
/// of a screen-anchored grid.
enum int kGridHalfCells = 50;

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
    // 2.3e-7 in value.
    //
    // WHY 1e-7 AND NOT SOMETHING TINY. The inputs are `float`s: a pixel size,
    // a step. The `float` nearest to 0.002 is 0.0020000000949949, which is
    // ABOVE the double 0.002 — so with a 1e-12 tolerance the ceiling of a
    // value that is a rung in the precision it arrived in jumps a whole rung.
    // The tolerance has to cover a float's ~6e-8 relative spacing, and 2.3e-7
    // does with room to spare while staying six orders of magnitude tighter
    // than the smallest gap on any ladder (2 -> 2.5, i.e. 25%). It cannot
    // merge two rungs; it can only stop one from being missed by an ulp.
    enum double kLogTol = 1e-7;

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

/// The world radius at which the drawn grid has faded to nothing: its OWN
/// half-extent, so the lattice always ends where it becomes invisible.
///
/// This used to be a multiple of the camera distance, which is a different
/// quantity that merely happened to sit inside a fixed 50-unit lattice at
/// ordinary zooms. Once the lattice's extent follows the step, the two come
/// apart and the grid's square boundary becomes visible — captured at a
/// zoom whose step sits at the bottom of a rung.
///
/// A function rather than an expression at the draw site because the display
/// endpoint reports it: a re-derivation in the reporter is exactly how a dump
/// starts lying about what was drawn.
float viewGridFadeRadius(float gridStep) @safe pure nothrow @nogc {
    return kGridHalfCells * gridStep;
}

// ===========================================================================
// Tests
// ===========================================================================










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
