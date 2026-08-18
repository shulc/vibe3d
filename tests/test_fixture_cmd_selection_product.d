// Task 1130 -- "what does a command leave selected?", frozen as a KNOWN
// DIVERGENCE. Nightly dogfood ledger row 12: 43 measured cases, one law.
//
// The reference re-points the selection at the command's PRODUCT and clears
// the input -- the merged face after a merge, the new face after a
// make-polygon, the new diagonal after a spin, the split-off vertex after a
// vertex split. We do not: we leave the input where it was, and for merge and
// spin we clear it instead.
//
// The consequence is not cosmetic, which is why this is a fixture and not a
// footnote. Any script that operates on "whatever the last op left selected"
// -- and that is how a modelling session is actually driven -- diverges at the
// NEXT step. `spin_twice_second_refused` is that consequence at its smallest:
// spin one edge twice in a row, and our second spin has nothing selected to
// spin, so it refuses.
//
// `spin_reselect_is_the_control` is the cell that makes the whole fixture
// readable, and it is declared a CONTROL over the GEOMETRY dimensions
// (applied/counts/vertices/edges/faces): re-select the product by coordinate
// between the two spins and the arithmetic agrees EXACTLY. So the divergence
// this file pins is the selection and nothing else -- if a geometry gap ever
// opens in that cell, the control reddens and says so in those words.
//
// This is NOT a parity test. Green means: our output still matches its
// recorded prediction, the reference golden is still what it was measured to
// be, and the gap between them is EXACTLY the declared delta. Narrow the gap
// -- including by FIXING it -- and this reddens; that is the prompt to
// re-measure, and to retire a case into a parity fixture once it closes.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/cmd_selection_product.json");
    runCommandDivergenceSuite(json);
}
