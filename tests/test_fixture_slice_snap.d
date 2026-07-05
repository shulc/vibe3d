// Slice tool (mesh.sliceTool, task 0271 S5) Angle Snap golden. Verifier:
// topology-diff (vert/face count deltas + per-vertex nearest-match against the
// frozen analytic golden + reference-INDEPENDENT lerp checks). Each case draws
// an OFF-multiple line (~19deg / ~81deg in the XZ work plane) with snap ON +
// snapAngle 45, so the line's angle is quantized to the nearest 45-degree
// multiple (0deg / 90deg) BEFORE the plane is built -> a clean axis-aligned
// mid-cut. If snap were NOT applied the raw tilted line would land its crossing
// verts OFF the axis plane, so a passing nearest-match proves the snap fired.
// The plane law is math.planeForSlice; the angle quantization is the pure
// math.snapLineEndpointToAngle helper (unit-tested in math.d). Analytic
// self-golden (Mesh.cutByPlane is connectivity-correct by construction).
//
// snap OFF (the factory default) reproduces the raw drawn line — covered by
// tests/fixtures/slice.json (tests/test_fixture_slice.d) and the whole S0-S8
// golden family, which all run with snap off and stay green.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_snap.json");
    runTopologyDiffSuite(json);
}
