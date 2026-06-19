// Reference-parity matrix: taper = linear-falloff Scale via the `xfrm.taper`
// preset. Each case scales one axis (SX/SY/SZ) of a segmented cube under a
// perpendicular linear falloff and asserts every vertex lands on the frozen
// reference — vibe3d reproduces each bit-for-bit. Coverage: all three scale
// axes crossed with a gradient axis, a shrink factor (<1), and gradient
// reversal. The op re-runs the actual xfrm.taper preset (tool.set xfrm.taper +
// tool.pipe.attr falloff + tool.attr S? + tool.doApply); empty reset so the
// welded cube is the only geometry. No external engine at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/taper.json");
    runParitySuite(json);
}
