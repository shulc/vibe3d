// Retired: `edgeCent` was a separate ElementMode variant that anchored at the
// edge midpoint. Since all element picks now anchor at the element centroid
// (edge midpoint, face centroid) the edgeCent/edge distinction is gone —
// both tokens accept the same behaviour. The centroid-anchor property is
// now covered by test_element_pick_edge_clickpoint.d (flipped to assert
// midpoint, click-independent).
//
// This file is kept as a compile-only placeholder so the test runner does
// not report a missing file.

void main() {}
