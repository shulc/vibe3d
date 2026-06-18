// Reference-parity matrix: soft-shear = linear-falloff Move via the `xfrm.shear`
// preset. Each case shears a segmented cube under a linear falloff and asserts
// every vertex lands on the frozen reference `after` — vibe3d reproduces the
// reference bit-for-bit across all of them. Coverage: each translate axis
// (TX/TY/TZ) crossed with a perpendicular gradient (Y/Z/X), plus negative sign,
// double magnitude, and gradient reversal. The op re-runs the actual xfrm.shear
// preset (tool.set xfrm.shear + tool.pipe.attr falloff + tool.attr T? +
// tool.doApply). Scenes use an empty reset so the welded cube is the ONLY
// geometry — a plain reset leaves the default cube, which prim.cube appends to
// rather than replaces, and it would be sheared too. No external engine at
// runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/shear.json");
    runParitySuite(json);
}
