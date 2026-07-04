// Tack (mesh.tack) headless-command parity against the golden fixture —
// task 0126. The scene is two disjoint unit cubes (loaded raw via
// /api/load-mesh, not the default cube), so this uses the plain
// setup/expected `runFixture` schema (tests/fixture_helpers.d) rather than
// the segmented-cube-oriented `runParitySuite` DSL. See
// tests/fixtures/tack.json for the full golden derivation note.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/tack.json");
    runFixture(json);
}
