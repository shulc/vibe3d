// Task 1130 -- polygon split with THREE vertices selected. Frozen as a KNOWN
// DIVERGENCE, ledger row 20.
//
// The reference cuts exactly ONE chord -- between the first two SELECTED
// vertices -- leaving a triangle and a quad. We refuse the whole command.
//
// The base is a NON-CONVEX pentagon, and that is the point of the case: on a
// convex n-gon "the first two selected" and "the pair that yields a valid
// convex cut" would name the same chord, and the cell could not tell the
// reference's rule from a geometric one. The selection is an ORDERED
// coordinate list because the ORDER is what selects the chord.
//
// Green means the gap is exactly as measured. If we ever implement the
// first-chord rule this reddens on that case, which is the prompt to retire it
// into a parity fixture.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_split_first_chord.json");
    runCommandDivergenceSuite(json);
}
