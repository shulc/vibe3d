// Slice tool "Gap" + "Offset Side" options (mesh.sliceTool, task 0275 S9 — the
// final option of the Slice program). With Split on, `gap` pushes the two split
// boundary loops APART by exactly that width along the CUT-PLANE NORMAL n, and
// `gapSide` (Offset Side: center/positive/negative) biases which shell moves.
// This is the flat-cut analogue of the Loop Slice gap (which displaces along the
// on-surface rail); a flat plane cut has no rail, so the shells separate along n.
//
// Analytic self-golden on a cube, line along Z through the origin -> n = -X
// (through X=0, == the S0 slice.json midX cut). Split ON + Cap Sections ON gives
// 16v / 24e / 12f in every case (gap is POSITIONS ONLY — no topology change);
// the caps gain real area as the band opens. lo (originals 8-11) is the +n shell,
// hi (dups 12-15) the -n shell. For gap = 0.2:
//   gap=0            -> every pair coincident at x=0 (byte-for-byte S7/S8).
//   center           -> lo x=-0.1, hi x=+0.1  (symmetric, separation 0.2).
//   positive         -> lo x=-0.2, hi x=0     (+n shell takes the full gap).
//   negative         -> lo x=0,    hi x=+0.2  (-n shell takes the full gap).
// y/z are untouched (displacement is purely along the plane normal). The
// kernel-level topology + exact-separation proof lives in the source/mesh.d
// cutByPlaneEx S9 unittest.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/slice_gap.json");
    runTopologyDiffSuite(json);
}
