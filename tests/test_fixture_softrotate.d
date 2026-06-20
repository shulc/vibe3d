// Reference-parity: softRotate = a Rotate weighted by a RADIAL falloff
// (xfrm.softRotate preset). The reference applies R(w·θ) — the angle scaled
// by the per-vertex weight, so radius is preserved (NOT a position-lerp).
// Cases cross multiple angles (30/45/90) and a smooth falloff shape; every
// vertex is asserted against the frozen reference. Rotation about Z, empty
// reset. Replayed via falloff_transform (type=radial); no external engine at
// runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/softrotate.json");
    runParitySuite(json);
}
