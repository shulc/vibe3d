// Reference-parity suite: per-vertex WEIGHTED single-axis scale under a linear
// falloff, captured numerically. The op re-runs the tool + falloff + recovered
// base factor in vibe3d via the falloff_transform step (tool.set +
// tool.pipe.attr falloff + tool.attr + tool.doApply). The falloff gradient was
// recovered from the captured weighting and re-expressed as vibe3d-native
// start/end handles, so vibe3d's weighted output must land on the frozen
// reference verts — independent of the reference engine's internal falloff-axis
// convention. No drag / no recovery at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/falloff_drag.json");
    runParitySuite(json);
}
