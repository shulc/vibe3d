// Task 1130 measured it, task 1200 CLOSED it — our edge-spin gate was strictly
// NARROWER than the reference's. Ledger rows 9 + 16 (one gate law) and 17.
//
// The reference's gate is: the edge has two faces, and each has at least three
// sides. Ours added two more conditions — both faces must have the SAME
// valence, and that valence must be 3 or 4 — and a fold-over guard that refused
// when the new diagonal already belonged to a third face. Three cells where we
// refused and the reference acted:
//
//   mixed_tri_and_quad        (row 9)  triangle + quad across a shared edge
//   two_pentagons             (row 16) equal valence, but neither 3 nor 4
//   foldover_makes_third_face (row 17) the new diagonal is already owned
//
// All three now declare an EMPTY gap, with every measured dimension a CONTROL.
//
// Row 17 is worth stating plainly, because it is the one the owner had to
// decide: the reference spins anyway, the edge count falls 6 -> 5, and the
// resulting edge carries THREE incident faces — a non-manifold mesh with two
// faces on the same ring. Our guard bought manifoldness there. The call
// (2026-08-18) was to match the reference. `Mesh.buildLoops` already survives a
// 3-face edge — Treatment A leaves all three darts twinless, and LWO import and
// Edge Extend have been producing such meshes for a long time — so what the
// spin produces here is degraded, not corrupt. Which downstream readers are
// degraded by it, and how, is written up in doc/tasks/work/1200-ref-refusals.md.
//
// Every base here is OPEN, and none is a cube: on a closed solid the mixed and
// equal-valence cases are not separable at all.
//
// tests/test_spin_edge.d holds the same three shapes from our own side and was
// rewritten by the same task; the two files agree now, and neither is the
// other's copy — this one asserts against the frozen reference, that one
// against the rings and counts the kernel is expected to emit.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/spin_gate_narrower.json");
    runCommandDivergenceSuite(json);
}
