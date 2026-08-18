// Mirror / flip / triple parity on dirty geometry, frozen from the reference
// (task 1160). None of these three commands had a measured fixture before.
//
// `poly_flip_triple_dirty_parity`'s flip cells are the only place in this
// delivery where a direction-sensitive face ring is the ENTIRE assertion: a
// flip moves no vertex, changes no count, and rewrites nothing but winding
// order. If `expected_faces` were compared winding-blind, those cases would
// pass with the command removed.
//
// Triangulation is frozen only on the subset where the two engines picked the
// same diagonal. On reflex and non-planar rings they largely do not, and those
// cells belong to the divergence lane -- freezing "we happen to agree here"
// alongside "we are known to disagree there" is the distinction this file
// keeps.
//
// WHAT THE FIVE `tri_*` CELLS ACTUALLY PIN, corrected by task 1280. Task 1190
// read them as pinning a quad rule -- "the SHORTER of the two non-folding
// diagonals" -- and shipped that beside a separate largest-area rule for
// n-gons because the two could not be reconciled. They are one rule: the
// corner chooser scores every candidate ear by 2*Area / (longest side)^2, and
// a quad's longest side is usually its diagonal, which is why "shorter"
// fitted. Replacing that metric with largest-AREA reddens this file
// (measured), so these cells still separate the choice rule -- they just
// separate it in the other direction from what the comment used to say.
//
// AND THEY DO NOT PIN WHICH OF THE REFERENCE'S TWO TRIANGULATORS RAN, which is
// the more useful thing to know about them. The command's default is a
// convex-only zig-zag strip with the ear clip as its fallback, and eight of the
// faces in these cells are CONVEX quads — where the strip does run
// (branch-hit counters: strip=1, earclip=0). We emit the clip's answer there.
// The cells stay green anyway, because on four corners the two paths produce
// the same two triangles across the same diagonal and differ only in where each
// tuple starts, and this file's comparison — like every face comparison in
// `fixture_helpers.d` — matches rings up to ROTATION. The difference is real
// and is declared in `tests/fixtures/triangulate_convex_strip_divergence.json`,
// whose quad case exists precisely because it is invisible here.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/mirror_dirty_parity.json"));
}

unittest {
    runTopologyDiffSuite(import("fixtures/poly_flip_triple_dirty_parity.json"));
}
