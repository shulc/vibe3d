// Task 1140 -- KNOWN DIVERGENCE: vertex bevel is a NO-OP on our side.
// Ledger row 26.
//
// This is a CAPABILITY GAP, not a law we implement differently: our command
// reports `did not apply` and the mesh is returned unchanged, in 46 of the
// 57 vertex-bevel cells the sweep drove. What the fixture pins is (a) that
// we do nothing, and (b) precisely what the reference does instead, so the
// day someone implements this there is a measured target to hit:
//
//   each edge at the beveled vertex contributes a point at `inset` along it
//   from the vertex; the vertex is removed; incident faces are re-rung
//   through those points; at valence >= 3 a new face closes the corner.
//
// Verified against the frozen numbers: at inset 0.12 on the folded quad the
// two new points are (0.12,0,0) -- 0.12 along the edge to (1,0,0) -- and
// (0,0.01194,0.119404), which is 0.12 along the unit direction of the edge
// to (0,0.1,1).
//
// CLOSING THIS ONE MEANS IMPLEMENTING THE TOOL. It cannot be closed by
// adjusting a constant, and until it is implemented this suite is green.
//
// This is NOT a parity test. A green run means three things at once: our
// output still matches its recorded output, the reference golden is still
// what it was measured to be, and the gap between them is EXACTLY the
// declared delta. If the gap narrows OR widens this suite goes red -- and
// closing it entirely is a red run too, which is the point: whoever closes
// it deletes the case and adds a parity one in its place.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/vertex_bevel_noop_divergence.json");
    runKnownDivergenceSuite(json);
}
