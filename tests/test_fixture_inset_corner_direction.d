// Ledger row 48 — polygon inset moves every corner of the new ring by exactly
// the inset distance in BOTH engines, and the two used to disagree only about
// the DIRECTION. Measured by task 1150; PORTED by task 1190, so what this
// suite now freezes is a closed gap plus the law behind it.
//
// The reference follows the corner's angle bisector: at a right angle its
// offset is (0.084853, 0, 0.084853), which is 0.12/sqrt(2) and nothing else.
// We used to head for the face CENTROID. On a convex ring that was a modest
// error — 16.927 degrees at the rectangle's corners. On a NON-CONVEX ring it
// was not modest: the dart's reflex corner went -0.12 where the reference
// sends it +0.12, exactly 180 degrees the wrong way, so our inset ring bulged
// OUT of the polygon at that corner instead of into it.
//
// `mesh_ops/poly_bevel.d:insetCornerBisector` now builds the bisector as the
// normalized sum of the two adjacent edges' inward in-plane normals, which is
// the same direction as the naive `unit(prev-v)+unit(next-v)` wherever that
// exists, picks the inward side by itself at a reflex corner, and survives an
// exactly collinear corner where the naive sum is the zero vector. Measured
// residual against the frozen reference: 0.000 at every corner of both cells.
//
// WHAT KEEPS THIS SUITE SHARP NOW THAT THE SETS MATCH. Two things, and the
// second is why the case was written this way in the first place:
//   * the declared `divergence` is EMPTY and the runner recomputes it live, so
//     it asserts parity rather than merely recording it;
//   * the `offset_law` block still carries each engine's per-corner
//     displacement VECTOR. A vertex-set diff would say "the sets match" and
//     lose the law itself; this asserts the magnitudes still agree and each
//     corner's direction gap is still 0.000 degrees. Reintroduce the centroid
//     direction and the rectangle reddens at 16.927 and the dart at 180.000.
//
// NOT closed by this: the reference's inset also REFUSES on some ring
// rotations and flips sign on others (ledger rows 42/47). That is its reading
// of the ring start, not our defect, and it stays declared in
// `ring_order_orbit_divergence.json`.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/inset_corner_direction_divergence.json");
    runKnownDivergenceSuite(json);
}
