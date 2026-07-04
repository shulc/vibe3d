// Loop Slice "Slice N-gon" option (task 0250). By default the quad ring stops
// at any non-quad face. When ON, the ring is allowed to CONTINUE THROUGH a face
// with more than four sides (N >= 5): it enters via its current edge, exits via
// the opposite edge, and the n-gon is sliced by the chord between the two edge
// midpoints — so the cut spans the n-gon and reaches the faces beyond.
// Analytic self-golden on a custom planar strip (two quads, a hexagon, a quad):
// OFF the ring terminates at the hexagon (15 verts / 22 edges / 6 faces, the
// two rails past the hexagon never reached, a T-junction against the uncut
// hexagon); ON the ring crosses the hexagon and reaches the far quad (17 verts
// / 24 edges / 8 faces, watertight). Every new vertex sits at the 0.5 midpoint
// of a pre-op vertical edge. Triangles never traverse (documented). Composes
// with `quad`/`select` (all flow through the same per-face split machinery).

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/loop_slice_ngon.json");
    runTopologyDiffSuite(json);
}
