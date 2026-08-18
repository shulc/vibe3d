// THIS FILE ASSERTS REFUSALS, NOT PARITY OF AN OPERATION (task 1160).
//
// Every case in the fixture is a measured cell where BOTH engines left the
// mesh untouched: a chord between two vertices that are already an edge, a
// paste with nothing on the clipboard, a vertex with one incident face, two
// disjoint faces asked to merge, a boundary edge asked to spin. The generator
// verified the "untouched" by comparing the before and after dumps on
// coordinates (and on the material partition, and direction-sensitively on the
// face rings), not on counts.
//
// It is kept apart from the parity fixtures on purpose, and its own mutation
// runs the other way round. Deleting the command under test leaves this file
// GREEN -- that is inherent to what a refusal is, and it is exactly why
// folding these cells into a parity suite would put vacuously-passing cases
// inside it. The mutation that reddens this file is removing the GUARD: make
// the command accept the input it is supposed to decline, and every case here
// fails on the counts.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/shared_refusal_parity.json"));
}
