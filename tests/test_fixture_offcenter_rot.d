// Reference-parity: soft Rotate (xfrm.softRotate) about Z with the radial
// falloff CENTRE off the rotation axis (center.x=0.5). The rotation changes
// each vertex's distance to the falloff centre, so this pins the weight
// timing: the reference takes the weight at the ORIGINAL (pre-rotation)
// position, then applies R(w·θ) about the pivot (origin) — confirming the
// falloff centre and the rotation pivot are independent. Rotation about Z and
// the falloff centre are inferred conventions (not stored in the capture).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/offcenter_rot.json");
    runParitySuite(json);
}
