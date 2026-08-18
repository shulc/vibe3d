// Task 1130 -- our edge-spin gate is strictly NARROWER than the reference's,
// frozen as a KNOWN DIVERGENCE. Ledger rows 9 + 16 (one gate law) and 17.
//
// The reference's gate is: the edge has two faces, and each has at least three
// sides. Ours adds two more conditions -- both faces must have the SAME
// valence, and that valence must be 3 or 4 -- and a fold-over guard that
// refuses when the new diagonal already belongs to a third face. Three cells
// where we refuse and the reference acts:
//
//   mixed_tri_and_quad       (row 9)  triangle + quad across a shared edge
//   two_pentagons            (row 16) equal valence, but neither 3 nor 4
//   foldover_makes_third_face (row 17) the new diagonal is already owned
//
// Row 17 is worth stating plainly: the reference spins anyway, its edge count
// falls 6 -> 5, and the resulting edge carries THREE incident faces -- a
// non-manifold mesh. Our guard buys manifoldness there, so closing that gap is
// a decision, not a bug fix, and this fixture is what will force the decision
// to be made deliberately.
//
// Every base here is OPEN, and none is a cube: on a closed solid the mixed and
// equal-valence cases are not separable at all.
//
// A green run means the gap is still exactly as measured. If it moves -- in
// either direction -- this reddens, and whoever moved it re-measures. Our own
// tests/test_spin_edge.d pins these refusals as CORRECT from our side; the two
// files are not in conflict, they record the two halves of a real
// disagreement.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/spin_gate_narrower.json");
    runCommandDivergenceSuite(json);
}
