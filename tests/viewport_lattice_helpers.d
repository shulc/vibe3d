// Shared sampling lattice for viewport pixel probes.
//
// Extracted from `test_viewport_display.d` by task 1090, which needed the same
// lattice for a second suite. The extraction is not a convenience: the two
// tests must never disagree about WHERE they sample, and a ten-line copy is
// exactly how they would. `kFillStride` moving in one file and not the other
// would leave both green while they measured different pixels.
//
// NAMED `*_helpers.d` BECAUSE THAT IS THE HARNESS'S ONLY SHARED-CODE HOOK.
// `run_test.d` compiles `tests/*_helpers.d` into every test binary and nothing
// else from `tests/`; `-I=tests` alone supplies declarations without bodies,
// so a plain HTTP-driver test importing any other filename would fail to LINK.
// (Source-backed tests get `-i` and would have been fine — which is precisely
// the kind of difference that makes "it works in my test" not transfer.)
//
// WHAT THIS MODULE DELIBERATELY DOES NOT KNOW: what a pixel is. Each test
// keeps its own `Px` type and its own equality; `erodedFillIndices` takes the
// already-computed `isFill` mask. That keeps the lattice arithmetic — the part
// that must be identical — here, and the probe plumbing — the part that may
// differ — there.
module viewport_lattice_helpers;

import std.exception : enforce;
import std.format    : format;

// --------------------------------------------------------------------------
// Locating the model's FILL without knowing where the model is (task 0589).
//
// The construction, in the words of the test this came from: faces are drawn
// LAST and OPAQUE, so a pixel a face covered is a pixel that DIFFERS between
// the shaded image and the lines-only image, and a pixel a face did not cover
// is byte-identical between them. That single criterion is self-locating, and
// it excludes wireframe-overlay lines, grid and background for free — they are
// drawn identically under both styles.
//
// Then an EROSION on the lattice (keep a sample only if its four lattice
// neighbours are also fill) puts every surviving sample at least one stride
// away from a silhouette, where float congruence between two camera positions
// is only approximate.
// --------------------------------------------------------------------------

enum int kFillNX = 60, kFillNY = 50, kFillStride = 6;

/// The regular lattice, centred on the cell. REGULAR is load-bearing: the
/// erosion below is index arithmetic over it, and `latticePoint` is its
/// inverse.
string fillLattice(int W, int H) {
    immutable int x0 = W / 2 - kFillNX * kFillStride / 2;
    immutable int y0 = H / 2 - kFillNY * kFillStride / 2;
    string pts;
    foreach (j; 0 .. kFillNY)
        foreach (i; 0 .. kFillNX)
            pts ~= format("%d,%d;", x0 + i * kFillStride, y0 + j * kFillStride);
    return pts;
}

/// The pixel coordinate of lattice index `k` — the exact inverse of
/// `fillLattice`'s index arithmetic, so a caller that located a sample through
/// the lattice can go back to the pixel it sat on.
///
/// Needed because the lattice is a poor instrument for anything with a
/// per-pixel PATTERN in it: every sample shares one parity (the step is even),
/// so a 25 %-coverage stipple reads as 0 % or 50 % over the lattice and never
/// as 25 %. The fix is to let the lattice LOCATE the fill and then probe a
/// contiguous block around one of its samples; this function is what turns a
/// lattice index back into that block's origin.
int[2] latticePoint(int W, int H, size_t k) {
    immutable int x0 = W / 2 - kFillNX * kFillStride / 2;
    immutable int y0 = H / 2 - kFillNY * kFillStride / 2;
    enforce(k < kFillNX * kFillNY,
        format("lattice index %d is outside the %dx%d grid",
               k, kFillNX, kFillNY));
    immutable int i = cast(int)(k % kFillNX);
    immutable int j = cast(int)(k / kFillNX);
    return [x0 + i * kFillStride, y0 + j * kFillStride];
}

/// Indices into a `fillLattice` probe that a face covered, eroded by one
/// lattice step.
///
/// `isFill[k]` is the caller's own answer to "did a face cover lattice sample
/// k" — usually "the shaded and lines-only probes differ here".
size_t[] erodedFillIndices(in bool[] isFill) {
    enforce(isFill.length == kFillNX * kFillNY,
        format("the probe returned %d points for a %d-point lattice — the "
               ~ "index arithmetic below is only valid on the full grid",
               isFill.length, kFillNX * kFillNY));

    size_t[] keep;
    foreach (j; 1 .. kFillNY - 1)
        foreach (i; 1 .. kFillNX - 1) {
            immutable size_t k = j * kFillNX + i;
            if (isFill[k] && isFill[k - 1] && isFill[k + 1]
                && isFill[k - kFillNX] && isFill[k + kFillNX])
                keep ~= k;
        }
    return keep;
}

// ---------------------------------------------------------------------------
// NO `unittest` BLOCK MAY EVER LIVE IN THIS FILE, OR IN ANY `tests/*_helpers.d`
//
// MEASURED HERE, task 1090, and it silently disarmed a whole suite for one
// build. `run_test.d` compiles EVERY `tests/*_helpers.d` into EVERY test
// binary, with `-unittest` and without `-main`; the tests themselves supply an
// `int main()`. Druntime's default unittest runner, when any unittest block
// RAN, reports "N modules passed unittests" and DOES NOT RUN MAIN. So a single
// unittest block in a shared helper turns every HTTP driver in `tests/` into a
// binary that prints a pass and executes not one test case — the exact
// "trivial fake PASS" this project has been bitten by before, but suite-wide
// instead of one file.
//
// Observed directly: with two unittest blocks here, `test_viewport_display`
// printed "1 modules passed unittests" and none of its fourteen flows; with
// them removed it printed all fourteen again. None of the six pre-existing
// `*_helpers.d` files contains a unittest block, and that is not a
// coincidence to be tidied up.
//
// WHERE THE CHECKS WENT INSTEAD. `fillLattice` and `latticePoint` are two
// copies of the same origin arithmetic and must be checked against each other
// — that check is Flow L0 of `tests/test_weightmap_display.d`, which runs
// inside a real `main` and, better, runs it at the cell's ACTUAL dimensions
// rather than at invented ones. `tests/unit/` was not an option: its dub
// configuration's source paths are `[source, tests/unit]`, so nothing there
// can import this module at all.
// ---------------------------------------------------------------------------
