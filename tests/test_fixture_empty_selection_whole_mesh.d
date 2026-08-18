// Tasks 1130 (measured) + 1210 (ported) -- "an empty selection means THE WHOLE
// MESH". Ledger rows 13 + 18: one law, two independent witnesses.
//
// With nothing selected, set-material paints every face and copy followed by
// paste duplicates the entire mesh (2 faces -> 4). Both were flat no-ops here,
// and tests/test_set_material.d pinned the no-op as CORRECT -- which is why
// that test is part of the change that closed this gap, not a bystander.
//
// Two witnesses, not one, because a single command could plausibly be a quirk
// of that command; two unrelated commands answering the same way is a
// selection-semantics law. It is also not a new idea in this codebase: ~40
// commands (delete, remove, bevel, extrude, mirror, smooth, jitter, the align
// family) already went through `Mesh.operand{Vertex,Edge,Face}Mask`, whose
// fallback branch IS this law. The port was to route these two through the
// same funnel rather than to invent a rule for them.
//
// The material witness is frozen as a COUNT OF RETAGGED FACES rather than as
// material identity: the two engines do not share a naming scheme for
// materials (one names them, we number them), but "this command retagged N
// faces" is the same fact on both sides and travels across the boundary
// intact.
//
// BOTH CASES NOW DECLARE AN EMPTY GAP, and the cases were NOT deleted: every
// measured dimension is declared a CONTROL, so the runner asserts the agreement
// per dimension, exactly as strictly as it used to assert the disagreement --
// and, unlike `control: true`, it also asserts that each of those dimensions
// is still MEASURED on both sides. Red here means the law moved.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/empty_selection_whole_mesh.json");
    runCommandDivergenceSuite(json);
}
