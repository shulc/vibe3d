// Slice tool "Gap" WITHOUT the Split option (mesh.sliceTool, task 0288).
//
// The owner observed that the reference Slice's Gap applies even when Split is
// OFF, and it is NOT split-gated in vibe3d any more. Captured headless (a cube,
// axis-aligned cut, gapSide center): gap>0 with split=off opens the single cut
// into TWO PARALLEL cuts `gap` apart and keeps the coplanar strip between them
// as band faces, so the mesh stays a single CONNECTED solid (a channel), 8v/6f
// -> 16v/14f with the loops at +/-gap/2. This is DISTINCT from Split (which
// separates into two disconnected shells + caps, 16v/12f) and from doing
// nothing (12v/10f). vibe3d reproduces it as two sequential parallel plane cuts.
//
// Analytic self-golden matching the captured reference (task 0288, Gap without
// Split): gap=0 -> single cut (12v/10f); center -> loops x=-0.1/+0.1;
// positive -> x=-0.2/0; negative -> x=0/+0.2. gapSide sign policy mirrors the
// Split gap kernel. The kernel-level per-cut topology lives in the source/mesh.d
// cutByPlane unittests.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_gap_nosplit.json");
    runTopologyDiffSuite(json);
}
