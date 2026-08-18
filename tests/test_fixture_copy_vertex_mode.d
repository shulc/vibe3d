// Task 1130 measured it, task 1200 CLOSED it — copy with a VERTEX selection.
// Ledger row 19.
//
// Four vertices of an open plate selected; the reference's copy takes the
// vertices, and the paste puts four FREE VERTICES back (6 -> 10). Our copy
// refused outright: its operand domain was polygons only, on the reasoning that
// a vertex selection "produces no standalone topology in vibe3d's face-derived
// edge model". It produces standalone POINTS. The cell now declares an EMPTY
// gap, with every measured dimension a CONTROL.
//
// The paste is part of the case on purpose. A clipboard's contents are not
// observable directly — what a copy took is only visible in what a paste puts
// back — so a case that stopped at the copy would be measuring the error
// message rather than the behaviour.
//
// EDGES mode still refuses, and that is an absence of measurement rather than a
// decision: the reference was never driven with an edge selection here.
//
// Related but separate: ledger row 18 (an EMPTY selection means the whole
// mesh) lives in test_fixture_empty_selection_whole_mesh.d. That one is about
// the empty case; this one is about the vertex case, and they closed
// independently — row 18 is still open.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/copy_vertex_mode.json");
    runCommandDivergenceSuite(json);
}
