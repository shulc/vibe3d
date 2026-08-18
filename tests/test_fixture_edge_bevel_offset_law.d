// Task 1150 -- divergence-ledger row 1: where an edge bevel puts the vertices
// it creates. Settled by measurement on 53 cells / 520 created vertices, to a
// residual of 1.53e-5 x inset (worst absolute 1.2e-7, the reference engine's
// own single-precision vertex-storage floor).
//
// TWO RULES, AND NO FACE NORMAL DECIDES EITHER PLANE:
//
//   SLIDE  every edge at a touched vertex that is NOT itself bevelled yields
//          one new vertex at  v + inset * unit(e).  403 of the 520.
//   MITER  every face corner whose BOTH ring edges are bevelled yields
//          v + sign * inset * (a + b) / sin(theta) with a, b the two unit
//          edge directions -- i.e. the point in the PLANE OF THOSE TWO EDGES
//          at perpendicular distance `inset` from both of their lines. 117
//          such corners in this matrix.
//
// The one place a whole-ring normal appears is `sign`, the branch: (a+b) and
// -(a+b) are both at distance `inset` from both lines, and the engine takes
// the one pointing into the face. A whole-ring (Newell) orientation picks it
// 117/117, and 16/16 on the reflex corners built to separate the candidates.
// The rule that owns the PLANE is the worst rule for the BRANCH, which is the
// sharpest evidence that plane and branch are two questions and must be
// ported as two.
//
// WHAT KILLED THE RIVAL. A static read of the reference's shipped binaries
// said every normal its bevel code touches is the corner triangle at the
// ring's FIRST vertex. The behaviour then refuted that read: rotating a
// face's vertex ring changes that normal by up to 18 degrees and the measured
// output does not move by 1e-7. That refutation is why this file belongs to
// the ring-order lane at all -- the offset law is ring-order INVARIANT, and
// the R / M / X / S families here are the rotations that prove it.
//
// WHAT THIS SUITE IS TODAY. Not a parity claim over all 53 cells, and not a
// blanket divergence either -- the cells split, and the split is measured
// rather than chosen: every cell with at least one mitred corner has a
// non-empty gap, every cell with none has an empty one.
//
//   slide_only/*        22 cells -- gap declared EMPTY. That is parity with
//                       the reference, and runKnownDivergenceSuite asserts it
//                       exactly as strictly as it asserts a non-empty gap.
//   slide_and_miter/*   31 cells -- gap declared and frozen. Our kernel
//                       intersects the two offset LINES by projecting along
//                       the face's whole-ring normal, so on a non-planar face
//                       its point lies in no such plane at all. On the
//                       original 9-vertex patch that is 1.70e-3 at inset
//                       0.02 -- 8.5 % of the bevel width, and 4.86 degrees of
//                       direction.
//
// When the mitre is ported, all 31 gaps empty at once and this suite reddens
// on every one of them -- which is the prompt to delete the divergence blocks
// and let the whole file stand as a parity fixture.
//
// NO CELL HERE IS A CUBE, deliberately. On a closed solid every quad is
// planar and every dihedral is 90 or 180 degrees, which is exactly where all
// seven candidate rules coincide; a matrix built on one would have decided
// nothing. Neither is a lone bevelled edge evidence: it is a pure slide and
// poses no in-face question, which is why `Y_through` (two bevelled edges
// meeting at a vertex that NO single face carries both of) predicts seven
// slides and zero mitres, and measures exactly that.
//
// Not covered here, and deliberately so: width mode, round level >= 1,
// mitering != 0, and the overshoot clamp. Every cell ran the plain inset
// bevel at level 0.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/edge_bevel_offset_law.json");
    runKnownDivergenceSuite(json);
}
