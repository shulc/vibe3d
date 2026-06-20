// Reference-parity: twist = a Rotate weighted by a LINEAR falloff
// (xfrm.twist preset). The reference applies R(w·θ) — the rotation angle
// scaled by the per-vertex weight, so radius is preserved (NOT a matrix-lerp
// toward identity). Cases cross two angles (30/90); every vertex is asserted
// against the frozen reference. Rotation about Z and the linear-falloff axis
// Z are an INFERRED convention, NOT stored in the capture. Replayed via
// falloff_transform (type=linear); no external reference engine at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/twist.json");
    runParitySuite(json);
}
