// Pilot for the golden-fixture harness (tests/fixtures/*.json +
// tests/fixture_helpers.d). Drives one frozen-state case end to end:
// reset → select edge 0 → mesh.split_edge → assert /api/model verts
// against the embedded golden.
//
// This case doubles as the first regression test for mesh.split_edge,
// which previously had no unit-test coverage. The fixture is embedded at
// compile time via dmd's `-J=tests` string-import path (added by
// run_test.d), so the test carries no runtime file dependency.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/split_edge_cube_edge0.json");
    runFixture(json);
}
