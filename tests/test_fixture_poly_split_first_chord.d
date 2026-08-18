// Task 1130 measured it, task 1200 CLOSED it — polygon split with THREE
// vertices selected. Ledger row 20.
//
// The reference cuts exactly ONE chord — between the first two SELECTED
// vertices — leaving a triangle and a quad. We refused the whole command
// whenever the selected count was not exactly two. The cell now declares an
// EMPTY gap, with every measured dimension a CONTROL.
//
// The base is a NON-CONVEX pentagon, and that is the point of the case: on a
// convex n-gon "the first two selected" and "the pair that yields a valid
// convex cut" would name the same chord, and the cell could not tell the
// reference's rule from a geometric one.
//
// What this cell still cannot tell you, stated so nobody reads more into a
// green run than is there: verts 0, 2 and 4 are picked in THAT order, so
// selection order and ascending index order coincide. The cell pins that one
// chord is cut and which one; it does not discriminate "first two selected"
// from "two lowest indices". The implementation follows selection order — the
// law the ledger records — and separating the two needs a cell whose click
// order runs against its index order, which nobody has captured.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_split_first_chord.json");
    runCommandDivergenceSuite(json);
}
