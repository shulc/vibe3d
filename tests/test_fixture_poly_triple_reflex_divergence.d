// Ledger row 25 — which diagonals a triangulation cuts on a ring with a REFLEX
// corner. Measured by task 1140 as a KNOWN DIVERGENCE; CLOSED by task 1190,
// and kept here with an EMPTY declared gap.
//
// BOTH CELLS HAVE IDENTICAL VERTEX SETS AND IDENTICAL COUNTS. Nothing moves,
// nothing is created; the whole subject is which vertices make a triangle. A
// check that compared vertices alone would report parity here whatever the
// answer, which is why this fixture carries the face channel — and the face
// channel compares rings up to ROTATION but never reflection, so winding is
// part of what is asserted.
//
// WHAT WAS WRONG. Our fan started at ring vertex 0, so on the pentagon it
// emitted (0,0,0)-(4,0,0)-(4,0,4) — a triangle CONTAINING the reflex corner
// (2,0,1) — and on the hexagon (0,0,0)-(3,0,0)-(3,0,3), containing it too.
// The triangulation overlapped itself. `mesh.triangulateFacesByMask` now
// chooses its diagonals geometrically — see `earClipRingCorners` — and the two
// engines agree on every triangle in both cells, ring rotation and winding
// included.
//
// WHY THIS CASE IS WORTH KEEPING NOW THAT IT IS GREEN-BY-PARITY, and what it
// pins AFTER TASK 1280. 1190 read this cell as pinning the n-gon rule to
// LARGEST AREA. That was a fit, and 1270 read the actual procedure: the corner
// chooser scores each candidate ear by 2*Area / (longest side)^2 and takes the
// best. Area and quality agree on THIS hexagon, which is why the fit looked
// sound; over the 19 cells the reference was later measured on, largest-area
// scores 4 and the quality metric scores 19.
//
// What the cell still separates is real and was re-measured, not assumed:
// swapping the quality metric for largest-AREA reddens this suite (measured by
// mutation, task 1280). On the hexagon the reference cuts E-A before D-F, so
// it is not fanning from the reflex corner and it is not minimising total
// diagonal length (the fan from (2,0,1) is 6.478 against 7.004 and is not what
// either engine emits) — those two readings are still excluded here.
//
// An EMPTY divergence is the strict reading of this schema, not the weak one:
// the runner recomputes `extra_*` / `missing_*` from the live output against
// the frozen reference and asserts they are empty, so a drift on either side
// fails here.

import fixture_helpers;

void main() {}

unittest {
    enum string json = import("fixtures/poly_triple_reflex_divergence.json");
    runKnownDivergenceSuite(json);
}
