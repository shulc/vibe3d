// Slice tool (mesh.sliceTool, task 0270 S4) `infinite` topology golden.
// Verifier: topology-diff (vert/face count deltas + per-vertex bidirectional
// nearest-match against the frozen analytic golden + a reference-INDEPENDENT
// lerp check that every crossing vertex lands at the z-midpoint of a strip
// edge). The SAME drawn line is cut with infinite ON vs OFF on a mesh wider
// than the line, so the two visibly differ:
//   ON  (extend the line indefinitely) — the plane slices the WHOLE mesh: all
//       4 quads split, 12v/4f -> 18v/8f.
//   OFF (the reference factory default) — the cut is CLIPPED to the drawn
//       Start->End span: only the spanned (left) strip is cut, 12v/4f ->
//       15v/6f; the right strip is untouched.
// The cut law is Mesh.cutByPlane (infinite) / Mesh.cutByPlaneClipped (clipped);
// analytic self-golden — no external reference engine at test time (both are
// connectivity-correct by construction). The clip boundary rule is a
// documented vibe3d divergence: the reference default is authoritatively OFF
// (its attribute description states ON "slices the whole mesh, not just the
// drawn extent"), but the exact per-face boundary behavior is uncapturable on
// the cube capture kit (haul-flakiness — see toolcards findings). This fixture
// pins the countable ON/OFF difference, which the semantics guarantee.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_infinite.json");
    runTopologyDiffSuite(json);
}
