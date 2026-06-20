// Reference-parity: the radial-falloff SHAPE curves (linear / easeIn /
// easeOut / smooth / custom). Each case scales a seg-4 cube along Y under a
// radial falloff of that shape and asserts every vertex against the frozen
// reference. The dense vertex set samples the attenuation curve across
// t∈[0.5,0.87]; the custom case verifies the in_/out_ tangent convention.
// Confirms vibe3d's applyShape matches the reference's radial falloff per
// profile. Empty reset; no external engine at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/radial_shapes.json");
    runParitySuite(json);
}
