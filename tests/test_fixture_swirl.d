// Reference-parity: swirl = a Rotate weighted by a RADIAL falloff
// (xfrm.swirl preset — wired identically to softRotate in vibe3d). A seg-2
// cube is rotated about Z under a radial linear falloff and every vertex is
// asserted against the frozen reference R(w·θ) (angle scaled by weight,
// radius preserved). Empty reset; replayed via falloff_transform (type=radial),
// no external engine at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/swirl.json");
    runParitySuite(json);
}
