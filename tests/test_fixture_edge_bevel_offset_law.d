// Task 1150 measured it, task 1170 ported it -- divergence-ledger row 1:
// where an edge bevel puts the vertices it creates. Settled by measurement
// on 53 cells / 520 created vertices, to a residual of 1.53e-5 x inset
// (worst absolute 1.2e-7, the reference engine's own single-precision
// vertex-storage floor).
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
// WHAT THIS SUITE IS TODAY. All 53 cells declare an EMPTY gap, and every one
// of them also matches the reference's vertex / edge / polygon COUNTS. That
// is parity across the whole matrix, and it is asserted rather than merely
// stated: runKnownDivergenceSuite recomputes the gap from the two frozen
// sides on every run and fails unless it is exactly what the case declares,
// so an empty declaration is checked exactly as strictly as a full one. A
// vertex we stop producing, a vertex we invent, or a mitre that drifts back
// off the two-edge plane all fail here.
//
//   slide_only/*        22 cells, 0 mitred corners.
//   slide_and_miter/*   31 cells, 117 mitred corners between them.
//
// THE CASES WERE CONVERTED, NOT DELETED, and the names keep the measured
// split, because which cells exercise the mitre is a property of the CELLS
// and not of our current state. A mitre regression reddens in the first
// group and is invisible in the second; the names are what say so, and 22
// cells that cannot see the mitre at all would otherwise read as 22 more
// cells that checked it.
//
// WHAT IT USED TO SAY, and what closed it (task 1170). The 31 mitre cells
// carried a frozen gap: our kernel intersected the two offset LINES by
// projecting along the face's whole-ring normal, so on a non-planar face its
// point lay in no plane at all -- 1.70e-3 at inset 0.02 on the original
// 9-vertex patch, 8.5 % of the bevel width and 4.86 degrees of direction.
// `math.bevelMiterPoint` replaced that intersection with the closed form and
// kept the whole-ring normal for the BRANCH SIGN alone. The 22 slide-only
// cells did not move: on a planar face the closed form and the old line
// intersection are the same point by construction, which is also why the
// planar mitres inside the 31 did not move either.
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
