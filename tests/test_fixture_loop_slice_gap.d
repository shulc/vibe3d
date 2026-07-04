// Loop Slice "Gap" option (task 0253, depends on Split/0251 + Cap Sections/0252).
// With Split ON each rail midpoint is duplicated into a coincident lo/hi pair and
// Cap Sections bridges them with zero-area cap quads. Gap opens a width between
// the two split boundary loops by pushing each seam pair apart by `gap` (±gap/2,
// symmetric about the split line) along the rail/cut direction, so the cap quads
// gain real area. Analytic self-golden on a unit cube, seed = a vertical edge,
// ring = a horizontal belt of 4 side quads (4 vertical rails): gap=0 keeps the 8
// loop verts coincident at 4 midpoints (byte-for-byte with 0251/0252); gap=0.4
// separates them into 8 distinct positions ({[±1,±0.2,±1]} — one shell at y=+0.2,
// the other at y=-0.2). Topology is UNCHANGED either way (16 verts / 28 edges /
// 14 faces, one closed manifold) — Gap only relocates the duplicated verts. The
// exact per-seam separation + non-degenerate cap-quad area lives in the
// source/mesh.d kernel unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_gap.json");
    runTopologyDiffSuite(json);
}
