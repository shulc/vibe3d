// Reference-parity suite: single-axis scale captured from real gizmo-handle
// drags with the action center on the selection (acen=select), so the pivot is
// the SELECTION-DERIVED centre — not the world origin as in scale_axis /
// scale_origin. Per-axis factors + pivot are recovered from the reference
// before/after and replayed via scale_about (no drag, no recovery at runtime).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/scale_drag.json");
    runParitySuite(json);
}
