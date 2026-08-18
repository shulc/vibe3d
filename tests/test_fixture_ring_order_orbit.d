// Task 1150 -- the RING-ORDER class, frozen as ORBITS.
//
// Sixteen geometries, each emitted once per starting index of its own vertex
// ring and run through one operation at every rotation -- 81 runs. The vertex
// array is byte-identical across an orbit; the only thing that moves is which
// corner the ring starts at. What the fixture freezes is the orbit's PATTERN
// -- which rotations produced the same answer -- on our side and on the
// reference's, in three channels, plus every rotation's own output and
// whether it matched the reference at all.
//
// This file holds BOTH kinds of case, and the difference is per case, not per
// file. Where a case still records a gap, a green run means the gap is still
// exactly the shape it was measured to be, and it reddens when the gap moves
// in EITHER direction, including when someone closes it. Where a case has been
// CONVERTED — the eight offset-family orbits, task 1230 — the two patterns are
// equal, every rotation declares `matches_reference`, and the same six
// assertions now hold a PARITY in place: it reddens the moment either side
// moves. Nothing was deleted to make that happen; converting the pattern IS
// the assertion (see runRingOrbitSuite's header for what each assertion means).
//
// WHY AN ORBIT AND NOT A BASE. Every one of these findings is invisible on a
// single mesh. In the run they came from, sixteen apparent parities turned out
// to be an orbit whose FIRST member agreed while a later one did not -- so
// pinning one rotation would have frozen the false parity and lost the
// finding. Three cases here exist to say the opposite thing just as loudly:
// `vertex_bevel_dart` and `loop_slice_pentagon_quad` came back INVARIANT on
// both sides, so they were CAPABILITY gaps -- our op did not run at all -- and
// not ring-order laws; and the two `loop_slice_annulus_*` cases are a control
// pair showing that what differs there is the placement law, not the ring.
// Without the orbit none of the three is distinguishable in a diff from the
// ones that are ring-order laws.
//
// WHAT TASK 1240 CHANGED. The two capability gaps above are CLOSED, by
// implementing the ops rather than by adjusting anything here:
//
//   * `vertex_bevel_dart` (ledger row 52) -- the vertex bevel's acceptance
//     test demanded an interior-manifold vertex of valence >= 3, so the dart's
//     valence-2 boundary corner was declined. It is chamfered now, and lands
//     on the reference's five vertices and its pentagon ring at every
//     rotation.
//   * `loop_slice_pentagon_quad` (row 53) -- the ring walk refused any seed
//     with a non-quad on either side. It now starts from the quad side and
//     the pentagon absorbs the terminating midpoint, giving the reference's
//     9 verts / 11 edges / 3 faces at every rotation.
//
// Both reclassified `capability_gap` -> `neither_reads_the_ring`, which the
// runner RE-DERIVES from the applied flags and the two orbit patterns rather
// than reading off the fixture -- so the reclassification is the data's, not
// an edit. The cases are kept and converted: the orbit still asserts that
// neither engine reads the ring on these shapes, and the per-rotation
// `matches_reference` flags -- which flipped from false to true -- now assert
// the parity where they used to assert the gap.
//
// STILL OPEN, and deliberately not touched by 1240: the
// `loop_slice_annulus_*` pair. The midpoint cut agrees; the off-centre one
// does not, because the two engines measure `position` from OPPOSITE ends of
// the seed rail (we take the seed edge's direction in its first incident
// face's winding; the reference lands at 1-t relative to that). It is a
// placement law rather than a capability, and the whole frozen corpus has
// exactly ONE shape that can see it -- every other reference-measured ring cut
// is either at 0.5 or on a palindromic position set. One cell is not enough to
// choose between the rules that fit it, so the pair stays declared. See the
// task 1240 card for the candidates and what would separate them.
//
// WHAT TASK 1190 CHANGED, AND WHAT IT DELIBERATELY DID NOT. 1190 ported the
// two laws in this file that were OURS:
//
//   * TRIANGULATION no longer fans from ring index 0. All four `triangulate_*`
//     orbits were `0101` / `01234` / `012345` / `0123` and are now INVARIANT
//     in every channel. Three of them reclassified `we_read_the_ring` ->
//     `neither_reads_the_ring`; `triangulate_five_point_star` went
//     `both_read_the_ring` -> `reference_reads_the_ring`, because the
//     reference still answers `0011` there and we no longer answer at all.
//   * INSET's corner DIRECTION is the bisector, not the face centroid (ledger
//     row 48, its own fixture). Our orbit patterns did not move -- the law was
//     already ring-invariant, it was pointing the wrong way -- but the
//     cross-engine `matches_reference` flags did: we now land on the
//     reference's answer at every rotation where the reference does not read
//     the ring.
//
// WHAT TASK 1230 CHANGED, AND WHY IT IS THE OPPOSITE DIRECTION FROM 1190.
// The owner decided to MATCH the reference in the offset family, so we now
// deliberately READ where the ring starts there -- an ordinary polygon
// rotated in its own ring now gives a different answer, on purpose. Say it
// plainly: this is a decision to follow the reference, not an improvement to
// the geometry. It is the exact opposite of what 1190 did to triangulation,
// where the reference is the ring-INVARIANT side and we were the ones
// reading the start; getting the two backwards would undo that work.
//
//   * the SIGN law (rows 41/47/49) is ported into all three offset kernels:
//     `Mesh.insetFacesByMask`, `Mesh.bevelFacesByMask`, and the SMOOTH branch
//     of `Mesh.extrudeFacesByMask` (`math.ringStartCornerSign` is the one
//     home of the predicate). All eight `inset_*` / `outset_*` /
//     `poly_bevel_*` / `smooth_shift_*` orbits now reproduce the reference's
//     pattern in all three channels and match it at EVERY rotation, so they
//     reclassify `reference_reads_the_ring` -> `both_read_the_ring`.
//   * the REFUSAL on a collinear ring start (row 42) is ported too, and only
//     into inset: `mesh.poly_inset` answers `status:error, "did not apply"`
//     on that rotation and leaves the mesh alone, which is the same 5-vertex
//     1-face mesh the reference leaves. The other two families answer that
//     same input differently on purpose (row 49) -- poly.bevel builds its ring
//     with a ZERO offset, smooth shift does not notice the collinear start at
//     all -- so they are three separate call sites, not one helper with flags.
//
// NOT ported, on purpose:
//
//   * THICKEN, although divergence-ledger row 41 names it alongside the other
//     three. It has no orbit case in this fixture, so nothing here could
//     assert it; and the ring capture shows the gap that matters there is not
//     the ring one -- `thicken/np_saddle` and `thicken/triquad_np` are
//     invariant on BOTH sides and still diverge at 0/4 rotations, and even
//     `thicken/reflex_first` r0 only reaches AGREE_WINDING_DIFFERS. Porting a
//     ring term into it would move an unmeasured law under an unmeasured gap.
//   * TRIANGULATION. The predicate is violated there on 11 of 25 measured
//     orbits and the fixture keeps the counterexample declared `violated`
//     (`triangulate_five_point_star`). It is not a universal rule and must not
//     be extended to a family that does not answer to it.
//   * the reference's triangulation WINDING (row 51). Its triangle SET does
//     not follow the ring start but its winding DOES: `faces` = `0100` against
//     `faces_any_winding` = `0000` on the dart. Ours is invariant in both, so
//     the two channels are kept apart and row 51 stays declared -- making our
//     SET invariant must not be read as parity in the winding channel, and the
//     `faces` patterns in this fixture are what says so.
//   * the tie-break. Two orbits still disagree with the reference and both are
//     exact ties, where the metric has nothing to say:
//     `triangulate_reflex_and_flat_hex` (four congruent ears) and
//     `triangulate_five_point_star` (five congruent tips, then a regular inner
//     pentagon). The star proves the reference's own tie-break is not
//     geometric -- same geometry, different ring start, different answer -- so
//     no ring-invariant rule can follow it through a tie, and fitting one to a
//     tied cell would be fitting noise.
//
// Two findings the shape buys are worth naming:
//
//   * Rows 41/47/49 -- the inset / outset / bevel / smooth-shift DIRECTION is
//     decided by the corner the ring happens to start at. On the hexagon
//     carrying both a collinear AND a reflex corner the orbit splits into
//     THREE classes (`010020`), which a ring with one special corner cannot
//     show. The suite recomputes the measured predicate --
//     `sign(cross(r1-r0, r[n-1]-r0) . Newell(ring))`, "is the corner at ring
//     index 0 convex with respect to the ring's OWN normal" -- from the
//     fixture's own base rings and asserts it still predicts that split, on
//     eight orbits. Smooth shift answers to the COARSER reading that folds
//     the collinear class into the convex one (`000010`), which is how three
//     families that look like one mechanism come apart. Since task 1230 our
//     side answers the same way, so these patterns are read TWICE per case --
//     ours and the reference's -- and a port that drifted on either side is
//     the same red as a port that never happened.
//
//   * Row 42 -- at the rotation that starts the ring on the collinear corner
//     the inset does NOTHING: that corner's triangle is exactly degenerate and
//     there is no fallback. The fixture carries that as an `applied` flag per
//     rotation, which the runner RE-DERIVES from the mesh rather than taking
//     on trust, and as an `expectStatus`/`expectMessageContains` pair on the
//     op step, because a refused command and a deleted op step leave exactly
//     the same mesh behind and only the answer tells them apart.
//
// The predicate is NOT universal, and the fixture says so rather than quietly
// dropping the counterexample: `triangulate_five_point_star` declares the
// relation `violated` -- the predicate calls two rotations equal that the
// reference separates. Triangulation does not answer to it; the offset
// families do.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/ring_order_orbit_divergence.json");
    runRingOrbitSuite(json);
}
