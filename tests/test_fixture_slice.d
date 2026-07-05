// Slice tool (mesh.sliceTool, task 0266 S0) topology golden. Verifier:
// topology-diff (vert/face count deltas + per-vertex nearest-match against the
// frozen analytic golden + a reference-INDEPENDENT lerp check that every new
// vertex lands at the midpoint of a pre-op edge). The plane law is
// math.planeFromLineAndWorkplane (line perpendicular to the work plane), NOT
// the camera-eye plane mesh.screenSlice uses. Analytic self-golden — no
// external reference engine at test time (Mesh.cutByPlane is connectivity-
// correct by construction).
//
// The committed geometry is unchanged by the task-0278 lifecycle revision
// (baseline-on-activate + bake-on-deactivate): the headless doApply path this
// harness drives is a single cut committed as one history entry per session.
// The interactive "two endpoint drags = one slice, undo count == 1" invariant
// is covered by tests/test_slice_session.d.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice.json");
    runTopologyDiffSuite(json);
}
