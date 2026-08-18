// Task 1130 / 1180 -- "what does a command leave selected?", measured as a
// divergence and then PORTED. Nightly dogfood ledger row 12: 43 measured
// cases, one law.
//
// The reference re-points the selection at the command's PRODUCT and clears
// the input -- the merged face after a merge, the new face after a
// make-polygon, the new diagonal after a spin, nothing at all after a vertex
// split (its two coincident copies are not addressable). We did not: we left
// the input where it was, and for merge and spin we cleared it instead.
// Task 1180 ported the law (source/selection_product.d), so every case here
// now declares an EMPTY gap -- and declares it per-dimension, by naming every
// measured dimension a CONTROL, which is asserted exactly as strictly as a
// full gap was.
//
// The consequence is not cosmetic, which is why this was a fixture and not a
// footnote. Any script that operates on "whatever the last op left selected"
// -- and that is how a modelling session is actually driven -- diverged at the
// NEXT step. `spin_twice_second_applies` is that consequence at its smallest,
// and is now the pin on its fix: spin one edge twice in a row. Before the port
// our second spin had nothing selected to spin and refused, and this case
// recorded `applied: [true, true, false]`. Delete the re-point in
// commands/mesh/spin_edge.d and that is exactly the assertion that fires.
//
// `spin_reselect_is_the_control` is the cell that made the fixture readable
// before the port: re-select the product by coordinate between the two spins
// and the arithmetic agreed EXACTLY, which is how the divergence was localised
// to the selection and nothing else. It is kept because it still carries a
// claim -- the automatic re-point must land where a hand coordinate re-select
// lands, so this case and the one above must agree, and they do.
//
// This is NOT a parity test. Green means: our output still matches its
// recorded prediction, the reference golden is still what it was measured to
// be, and the gap between them is EXACTLY the declared delta -- which is now
// empty. Move it in either direction and this reddens.
import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/cmd_selection_product.json");
    runCommandDivergenceSuite(json);
}
