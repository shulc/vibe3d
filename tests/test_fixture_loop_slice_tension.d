// Loop Slice "Tension" option (task 0255) — the strength control for "Preserve
// Curvature" (task 0254). With Preserve Curvature ON, each new loop vertex is
// placed at lerp + tension*(catmullRom - lerp): the linear chord midpoint (y=1.0
// on the 0254 arc strip) and the full Catmull-Rom spline point (y=1.125) bracket
// the bulge, and Tension scales between them. Analytic self-golden on the same
// curved open strip (3 quads, column heights h=[0,1,1,0]), seed = the middle
// quad's top long edge: tension=1.0 (100%, default) → full bulge y=1.125 (matches
// 0254); tension=0.5 (50%) → half bulge y=1.0625; tension=0.0 (0%) → flat chord
// y=1.0 (byte-for-byte the linear curvature-off placement, even with curvature ON).
// Topology is identical in every case (10 verts / 13 edges / 4 faces) — Tension
// only relocates the two new verts. The exact tension-scaling law also lives in
// the source/mesh.d kernel unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_tension.json");
    runTopologyDiffSuite(json);
}
