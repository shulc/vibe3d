// Task 1140 -- frozen as a KNOWN DIVERGENCE; CLOSED BY IMPLEMENTATION in
// task 1240. Ledger rows 26 and 52.
//
// WHAT IT USED TO SAY. Vertex bevel was a NO-OP on our side: the command
// reported `did not apply` and the mesh came back unchanged, in 46 of the 57
// vertex-bevel cells the dirty-geometry sweep drove and in 181 of 181 of the
// ring-rotation sweep's. It was a CAPABILITY GAP, not a law we implemented
// differently -- the kernel's acceptance test demanded an INTERIOR-MANIFOLD
// vertex of valence >= 3, so a boundary corner (the smallest case in the
// family: one corner of one quad) never reached the geometry at all. The
// fixture pinned (a) that we did nothing, and (b) precisely what the reference
// does instead, so that whoever implemented it had a measured target:
//
//   each edge at the beveled vertex contributes a point at `inset` along it
//   from the vertex; the vertex is removed; incident faces are re-rung
//   through those points; at valence >= 3 a new face closes the corner.
//
// WHAT IT SAYS NOW. That rule is implemented (source/mesh_ops/bevel_vertex.d):
// the umbrella is read off the FACE CORNERS instead of the edge-face table,
// which accepts an open fan and hands back the cap ring already in the order
// and winding the surrounding faces dictate. Both cases declare an EMPTY gap
// in the vertex AND face channels. An empty gap is not a weaker assertion --
// `runKnownDivergenceSuite` recomputes the difference between our live output
// and the frozen reference and requires it to equal the declaration, so an
// empty one demands our counts, our vertex set and our face rings WITH WINDING
// all equal the reference's, and reddens the moment any of them drifts.
//
// The cases were converted, not deleted. The reference measurement is the
// valuable half of the record and it has not changed; what changed is our side
// of it.
//
// Coverage is honest about its size: TWO cells of the 181 are frozen here (the
// valence-2 boundary corner and the valence-3 boundary corner) plus the dart
// in tests/fixtures/ring_order_orbit_divergence.json. The other 178 were
// measured in the sweep and are not in the repository, so this suite does not
// claim the family -- it claims these three.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/vertex_bevel_noop_divergence.json");
    runKnownDivergenceSuite(json);
}
