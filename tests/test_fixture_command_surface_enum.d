// Task 1130 -- the COMMAND SURFACE rather than the geometry: which argument
// values each engine accepts. Frozen as a KNOWN DIVERGENCE, ledger rows 4+14.
//
//   lowercase_axis_rejected_here  (row 4) the reference accepts a LOWER-CASE
//     axis name; our parser rejects it ("unknown enum value") and demands
//     upper case. Not geometry -- but the same script does not run on both,
//     which is the finding.
//
//     This case freezes ONE dimension, acceptance, and no reference geometry
//     at all. The acceptance was measured on a different mesh, so a golden for
//     THIS base would be invented rather than measured, and an invented golden
//     in a fixture is worse than a missing one. What the case does assert on
//     our side is the rejection TEXT, because a parse refusal and a kernel
//     refusal are both "it did not apply" to a count, and here the difference
//     between them is the whole content of the row.
//
//   axis_all_is_a_silent_noop_there  (row 14) both engines report SUCCESS for
//     an axis value of "all" -- and only ours moves the vertex. The reference
//     accepts exactly x/y/z and treats anything else as a silent no-op that
//     still reports OK. So this is not "a different law": it is an extension
//     on our side meeting a silent no-op on theirs, and the case is worth
//     freezing precisely because the status code hides it.
//
// NOT a parity test. Green means the gap is unchanged; if we start accepting
// the lower-case axis name, the first case reddens and should then be retired
// into a parity fixture.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/command_surface_enum.json");
    runCommandDivergenceSuite(json);
}
