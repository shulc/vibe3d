// Reference-parity suite: single-axis scale captured from a REAL gizmo
// single-axis handle drag (acen=none → world-axis pivot). Complements
// scale_axis (same origin-pivot single-axis scale applied headless) by
// exercising the real drag path across selection patterns (single face,
// adjacent, islands) on plain + segmented cubes. Per-axis factor + pivot are
// recovered from the reference before/after and replayed via scale_about (no
// drag, no recovery at runtime).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/scale_drag.json");
    runParitySuite(json);
}
