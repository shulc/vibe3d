// Reference-parity: the radial-falloff distance metric across parameters.
// A seg-4 cube is scaled along Y under a radial linear falloff with a shrink
// factor (<1), an off-centre falloff (center.x=0.3), an anisotropic ellipsoid
// (sizeY=1.5), and a larger sphere (size=2); every vertex is asserted against
// the frozen reference. Confirms vibe3d's ellipsoid metric
// t=sqrt(sum((d_i/size_i)^2)) matches the reference. Empty reset; no external
// engine at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/radial_params.json");
    runParitySuite(json);
}
