// Slice tool (mesh.sliceTool, task 0269 S3; owner-revised 0284 EXTRUSION-DIRECTION
// model) axis/vector golden. Verifier: topology-diff (vert/face count deltas +
// per-vertex nearest-match against the frozen analytic golden + reference-
// INDEPENDENT lerp checks). The `axis` is an EXTRUSION DIRECTION, not the cut
// normal: the plane is the drawn line EXTRUDED along the axis, so it ALWAYS
// CONTAINS BOTH endpoints. Every case draws the SAME Y-line through the origin and
// only changes the axis: axis=x extrudes along X => the Z=0 cut; axis=z extrudes
// along Z => the X=0 cut; custom (0,0,2) => normalize(Z) => the X=0 cut (proves the
// custom vector is normalized). The Y-line lies in EVERY resulting plane (the
// owner-bug invariant). infinite=true forces the clean 12v/10f full-mesh mid-cut.
// The plane law is math.planeForSlice; analytic self-golden (Mesh.cutByPlane is
// connectivity-correct by construction).
//
// The DEFAULT (no axis override) path is covered by tests/fixtures/slice.json
// (tests/test_fixture_slice.d) and stays green — omitting `axis` reproduces the
// drawn-line perpendicular-to-work-plane (drag) plane exactly as in S0.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_axis.json");
    runTopologyDiffSuite(json);
}
