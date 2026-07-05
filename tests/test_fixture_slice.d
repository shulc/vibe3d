// Slice tool (mesh.sliceTool, task 0266 S0) topology golden. Verifier:
// topology-diff (vert/face count deltas + per-vertex nearest-match against the
// frozen analytic golden + a reference-INDEPENDENT lerp check that every new
// vertex lands at the midpoint of a pre-op edge). The plane law is
// math.planeFromLineAndWorkplane (line perpendicular to the work plane), NOT
// the camera-eye plane mesh.screenSlice uses. Analytic self-golden — no
// external reference engine at test time (Mesh.cutByPlane is connectivity-
// correct by construction).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice.json");
    runTopologyDiffSuite(json);
}
