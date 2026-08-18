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
// This is NOT a parity test. A green run means the divergence is still
// exactly the shape it was measured to be; it reddens when the gap moves in
// either direction, including when someone closes it (see runRingOrbitSuite's
// header for what each of the six assertions means).
//
// WHY AN ORBIT AND NOT A BASE. Every one of these findings is invisible on a
// single mesh. In the run they came from, sixteen apparent parities turned out
// to be an orbit whose FIRST member agreed while a later one did not -- so
// pinning one rotation would have frozen the false parity and lost the
// finding. Three cases here exist to say the opposite thing just as loudly:
// `vertex_bevel_dart` and `loop_slice_pentagon_quad` came back INVARIANT on
// both sides, so they are CAPABILITY gaps -- our op does not run at all -- and
// not ring-order laws; and the two `loop_slice_annulus_*` cases are a control
// pair showing that what differs there is the placement law, not the ring.
// Without the orbit none of the three is distinguishable in a diff from the
// ones that are ring-order laws.
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
// NOT ported, on purpose:
//
//   * the reference's SIGN law (rows 41/47/49) and its REFUSAL on a collinear
//     ring start (row 42). Those are its reading of the ring, not our defect.
//     `inset_*` / `poly_bevel_*` / `smooth_shift_*` therefore stay
//     `reference_reads_the_ring`, with the mismatching rotations being exactly
//     the ones the sign predicate names.
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
//   * Rows 41/47/49 -- the reference's inset / outset / bevel / smooth-shift
//     DIRECTION is decided by the corner the ring happens to start at. On the
//     hexagon carrying both a collinear AND a reflex corner the orbit splits
//     into THREE classes (`010020`), which a ring with one special corner
//     cannot show. The suite recomputes the measured predicate --
//     `sign(cross(r1-r0, r[n-1]-r0) . Newell(ring))`, "is the corner at ring
//     index 0 convex with respect to the ring's OWN normal" -- from the
//     fixture's own base rings and asserts it still predicts that split, on
//     eight orbits. Smooth shift answers to the COARSER reading that folds
//     the collinear class into the convex one (`000010`), which is how three
//     families that look like one mechanism come apart. We have no ring term
//     at all: `000000` everywhere.
//
//   * Row 42 -- at the rotation that starts the ring on the collinear corner
//     the reference's inset does NOTHING: that corner's triangle is exactly
//     degenerate and it has no fallback. We inset identically at all five.
//     The fixture carries that as an `applied` flag per rotation, which the
//     runner RE-DERIVES from the mesh rather than taking on trust.
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
