// Subdivision parity on dirty geometry, frozen from the reference (task 1160).
//
// Faceted, smooth and Catmull-Clark, applied to OPEN surfaces: saddles,
// twists, reflex rings, collinear corners, holes, T-junctions, slivers,
// spirals and a six-point star. The boundary rule of a subdivision scheme is
// unreachable on a closed solid -- there is no boundary there -- so a cube can
// neither confirm nor refute it, and every base here has one.
//
// One cell subdivides TWICE, which catches a scheme that is right on a clean
// cage and wrong on its own output.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/subdivide_dirty_parity.json"));
}
