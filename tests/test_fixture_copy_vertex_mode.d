// Task 1130 -- copy with a VERTEX selection. Frozen as a KNOWN DIVERGENCE,
// ledger row 19.
//
// Four vertices of an open plate selected; the reference's copy takes the
// vertices, and the paste puts four FREE VERTICES back (6 -> 10). Our copy
// refuses outright: its operand domain is polygons only.
//
// The paste is part of the case on purpose. A clipboard's contents are not
// observable directly -- what a copy took is only visible in what a paste puts
// back -- so a case that stopped at the copy would be measuring the error
// message rather than the behaviour.
//
// Related but separate: ledger row 18 (an EMPTY selection means the whole
// mesh) lives in test_fixture_empty_selection_whole_mesh.d. That one is about
// the empty case; this one is about the vertex case, and the two could be
// closed independently.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/copy_vertex_mode.json");
    runCommandDivergenceSuite(json);
}
