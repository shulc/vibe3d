// Slice tool (mesh.sliceTool, task 0269 S3) axis/vector-constraint golden.
// Verifier: topology-diff (vert/face count deltas + per-vertex nearest-match
// against the frozen analytic golden + reference-INDEPENDENT lerp checks). Each
// case draws a SLANTED line whose default (Free) plane would be tilted, then
// locks the cut-plane normal to a world axis (x/y/z) or a custom vector — the
// lock makes the cut IGNORE the drawn line orientation and pass through Start
// with the constrained normal. axis=x + start.x=0 => the S0 midX X=0 cut;
// axis=z + start.z=0 => the S0 midZ Z=0 cut; custom (2,0,0) => normalize to
// world-X => X=0 cut (proves the custom vector is normalized). The plane law is
// math.planeForSlice; analytic self-golden (Mesh.cutByPlane is connectivity-
// correct by construction).
//
// The DEFAULT (Free, no axis change) path is covered by tests/fixtures/slice.json
// (tests/test_fixture_slice.d) and stays green — Free reproduces the drawn-line
// perpendicular-to-work-plane plane exactly as in S0.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_axis.json");
    runTopologyDiffSuite(json);
}
