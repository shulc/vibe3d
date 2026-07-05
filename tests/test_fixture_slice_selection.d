// Slice tool (mesh.sliceTool, task 0279) SELECTION RESTRICTION golden. The
// reference Slice cuts ONLY the selected polygons (the whole layer when nothing
// is selected) — captured headless on the reference (command-port + axis-locked
// X plane): 2 of 6 faces selected -> only those 2 split (12v/8f); 1 face -> only
// it splits (10v/7f); nothing selected -> whole span (12v/10f). vibe3d restricts
// via Mesh.cutByPlaneRestricted (per-face split mask + edge-scoped crossing-
// vertex insertion), keyed on the polygon selection like Loop Slice's Slice
// Selected. Analytic self-golden (connectivity-correct by construction); the
// reference capture confirms the counts. Verifier: topology-diff (vert/face
// deltas + bidirectional nearest-match against the frozen golden + midpoint
// lerp checks).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_selection.json");
    runTopologyDiffSuite(json);
}
