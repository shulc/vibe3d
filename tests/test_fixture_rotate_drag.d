// Reference-parity suite: rigid rotations captured from a REAL gizmo
// rotate-ring handle drag (grabbed by hand via --manual). Recovered by a
// single Kabsch SVD on the index-aligned selected before/after pairs (no
// permutation search — the index-ordered dump gives exact correspondence),
// replayed via rotate_about (axis/angle/pivot). Complements rotate_none
// (auto-captured) with a reliable manual single-ring set across selection
// patterns on plain + segmented cubes. No drag / no recovery at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/rotate_drag.json");
    runParitySuite(json);
}
