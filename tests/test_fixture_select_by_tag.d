// select.byTag region parity (task 1051).
//
// The claim is the REGION, not the command: the reference has no command that
// turns a tag into a polygon selection (see the fixture's provenance note and
// source/commands/select/by_tag.d), so what is frozen here is which polygons
// carry a tag after it is assigned — measured on the reference — and that our
// select.byTag hands exactly that set back.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/select_by_tag.json");
    runSelectionSuite(json);
}
