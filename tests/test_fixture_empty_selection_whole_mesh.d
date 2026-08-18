// Task 1130 -- "an empty selection means THE WHOLE MESH", frozen as a KNOWN
// DIVERGENCE. Ledger rows 13 + 18: one law, two independent witnesses.
//
// For the reference, a command fired with nothing selected operates on
// everything. Set-material paints every face; copy followed by paste
// duplicates the entire mesh (2 faces -> 4). For us both are no-ops, and our
// own tests/test_set_material.d pins the no-op as correct -- which is exactly
// why the disagreement has to be written down somewhere that reddens.
//
// Two witnesses, not one, because a single command could plausibly be a quirk
// of that command; two unrelated commands answering the same way is a
// selection-semantics law.
//
// The material witness is frozen as a COUNT OF RETAGGED FACES rather than as
// material identity: the two engines do not share a naming scheme for
// materials (one names them, we number them), but "this command retagged N
// faces" is the same fact on both sides and travels across the boundary
// intact.
//
// This is NOT a parity test -- see runCommandDivergenceSuite. Green means the
// gap is unchanged; red means it moved and someone must re-measure.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/empty_selection_whole_mesh.json");
    runCommandDivergenceSuite(json);
}
