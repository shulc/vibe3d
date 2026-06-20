// Reference-parity: vortex = a Rotate weighted by a CYLINDER falloff
// (xfrm.vortex preset). The reference applies R(w·θ) — the rotation angle
// scaled by the per-vertex weight, so radius is preserved (NOT a matrix-lerp
// toward identity). Cases cross two angles (30/90); every vertex is asserted
// against the frozen reference. Rotation about Z and the cylinder axis Z are
// an INFERRED convention, NOT stored in the capture. The cylinder size is
// isotropic [1,1,1] so vibe3d's r=max(size) metric agrees with the reference's
// per-axis metric. Replayed via falloff_transform (type=cylinder); no external
// reference engine at runtime.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/vortex.json");
    runParitySuite(json);
}
