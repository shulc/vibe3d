// Reference-parity suite: translation captured from a REAL gizmo move-arrow
// handle drag (grabbed by hand via --manual). Every selected vertex shifts by
// the same delta; replayed with vibe3d's move tool ({translate}). Complements
// translate_no_acen (headless move-tool matrix) by exercising the real drag
// path across selection patterns (single face, adjacent, islands) on plain +
// segmented cubes. No drag / no recovery at runtime — the delta is frozen.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/move_drag.json");
    runParitySuite(json);
}
