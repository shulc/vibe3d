// Task 1054 review follow-up -- band mode at count > 1 (NEW COVERAGE).
//
// The Phase-3 review found that every case in the 54-case corpus, both new
// fixtures (loop_slice_band.json / loop_slice_band_divergence.json) and both
// interactive tests (test_loop_slice_band_interactive.d) use exactly ONE cut
// position. So the multi-position code paths in band mode -- the middle-quad
// loop and the multi-mid absorb splice -- were entirely unexercised. THAT
// PART is fixed here: both paths now run under a real reference-sourced
// assertion for the first time.
//
// The review also hypothesised that this is *why* a one-site inversion of
// the entry/exit convention (R1) was silently absorbed everywhere ("the real
// precondition was positions.length == 1"). That hypothesis was tested
// against this fixture by mutation -- twice: a one-site swap (only the
// entry-population loop's `e.entryJ`/`e.exitJ` assignment,
// source/mesh_ops/loop_slice.d) and a full swap (that assignment AND the
// rail pre-pass's mirrored one) -- and NEITHER reddens this fixture. The
// reason is unrelated to position count: the five-cell L selection used here
// (same selection as tests/fixtures/loop_slice_corner.json, row-first click
// order) is symmetric under a GLOBAL reversal of every cell's entry/exit
// sides -- that is equivalent to walking the same band from its other end,
// which produces the identical cut, regardless of how many positions are
// cut along it. `loop_slice_band.json`'s own `L_p3_cornerfirst` case (a
// DIFFERENTLY-ordered selection, at count 1) is what actually discriminates
// a full swap (see that fixture's own doc comment in loop_slice.d) -- no
// differently-ordered selection exists in the captured corpus at count > 1
// to test whether a one-site inversion would show up THERE. So: real
// coverage gained for the multi-position code paths; the R1-discriminating
// claim specifically is NOT confirmed by this data, and is corrected here
// rather than asserted on the strength of the hypothesis alone.
//
// Same 3x1x3 grid and same five-cell L selection as
// tests/fixtures/loop_slice_corner.json, uniform mode, count 2 and count 3.
// Every expected number is reference-sourced from
// tools/local/fixture_gen/loop_slice_band/count_gt1/bandcount.json (a
// live capture, never read off vibe3d's own output).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_band_count.json");
    runTopologyDiffSuite(json);
}
