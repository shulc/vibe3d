// Slice tool "Cap Sections" option (mesh.sliceTool, task 0274 S8). With Split
// on, each split section's boundary loop is sealed by ONE cap polygon in the
// loop plane — the SAME geometry as Loop Slice Cap Sections (both paths share
// Mesh.capShellCycles). Analytic self-golden on a cube, line along Z through the
// origin (plane normal ||X, X=0, == S0 slice.json midX): Split on + Caps OFF is
// the S7 split_on result (16 verts / 24 edges / 10 faces, two OPEN boundary
// loops); Split on + Caps ON seals each shell's 4-edge boundary loop with one
// cap quad (16 verts / 24 edges / 12 faces) — the caps add NO new verts and NO
// new edges (each cap edge reuses an existing shell boundary edge), so the
// vertices are identical to the OFF case; the two shells stay DISCONNECTED (each
// cap seals its own shell). Mirrors the loop_slice_caps golden. The stronger
// topological proof (boundary-edge count, component count) lives in the
// source/mesh.d cutByPlaneEx kernel unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_caps.json");
    runTopologyDiffSuite(json);
}
