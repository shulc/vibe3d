// Reference-parity: bulge = a Scale weighted by a RADIAL falloff
// (xfrm.bulge preset — wired identically to softScale in vibe3d). A seg-2
// cube is scaled along Y under a radial linear falloff and every vertex is
// asserted against the frozen reference (per-axis 1+(s-1)·w). Empty reset;
// replayed via falloff_transform (type=radial), no external engine at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/bulge.json");
    runParitySuite(json);
}
