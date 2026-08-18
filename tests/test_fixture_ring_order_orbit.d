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
// nine that are ring-order laws.
//
// The cases, and the divergence-ledger rows each carries:
//
//   the reference reads the ring, we do not
//     inset_dart                        rows 41, 47, 48
//     inset_flat_corner_pentagon        rows 42, 49
//     inset_reflex_and_flat_hex         rows 47, 49
//     inset_notched_octagon             row  47
//     outset_dart                       rows 47, 48
//     poly_bevel_reflex_and_flat_hex    rows 23, 41, 49
//     poly_bevel_two_flat_corners_hex   rows 47, 49
//     smooth_shift_reflex_and_flat_hex  rows 23, 41, 49
//   WE read the ring
//     triangulate_dart                  rows 43, 50, 51
//     triangulate_reflex_pentagon       rows 43, 50, 51
//     triangulate_reflex_and_flat_hex   rows 43, 50
//   both read it
//     triangulate_five_point_star       rows 43, 50
//   not a ring-order law at all
//     vertex_bevel_dart                 row  52   (capability gap)
//     loop_slice_pentagon_quad          row  53   (capability gap)
//     loop_slice_annulus_midpoint       row  53   (control: both agree)
//     loop_slice_annulus_offcentre      row  53   (placement, not ring order)
//
// Four findings are worth naming, because they are what the shape buys:
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
//   * Rows 50/51 -- our triangulation always fans from ring index 0, so its
//     orbit has a PERIOD: 2 on a quad (`0101`), n on an n-gon (`012345`). The
//     reference's triangle SET is invariant (`faces_any_winding` = `0000`),
//     but its WINDING is not (`faces` = `0100`) -- which is why the runner
//     keeps the two channels apart, using task 1140's names: `faces` compares
//     rings up to ROTATION only, `faces_any_winding` also accepts the
//     reversed ring. On the dart at rotation 0 our fan builds a triangle that
//     lies OUTSIDE the polygon.
//
//   * The predicate is NOT universal, and the fixture says so rather than
//     quietly dropping the counterexample: `triangulate_five_point_star`
//     declares the relation `violated` -- the predicate calls two rotations
//     equal that the reference separates. Triangulation does not answer to
//     it; the offset families do.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/ring_order_orbit_divergence.json");
    runRingOrbitSuite(json);
}
