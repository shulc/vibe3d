// Loop Slice "Cap Sections" option (task 0252, depends on Split/0251). With
// Split on, the cut opens the surface into two coincident boundary edge-loops
// (a lo loop + a hi loop). Cap Sections closes each opened section by bridging
// the lo loop to its hi twin with a strip of cap quads — one quad per lo cut
// edge, [v,u,hi(u),hi(v)] wound to oppose the owning face. Around the closed
// cube belt the strip's side seams pair up between adjacent caps, so both
// boundary loops vanish and the two split shells re-join into one closed
// manifold. Analytic self-golden on the 0251 unit cube, seed = a vertical edge,
// ring = a horizontal belt of 4 side quads (4 rails): Split ON + caps OFF =
// 16 verts / 24 edges / 10 faces (open boundaries, 0251's split-on result);
// Split ON + caps ON = 16 verts / 28 edges / 14 faces (the 4 cap quads + 4
// seam-side edges close the sections). Cap Sections adds NO new vertices (caps
// only reference the existing lo/hi verts), so the golden vertex set is
// identical to the OFF case. The caps are zero-area while lo/hi coincide; Gap
// (0253) later separates them. The stronger topological proof (boundary-edge
// count 8→0, component count 2→1) lives in the source/mesh.d kernel unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_caps.json");
    runTopologyDiffSuite(json);
}
