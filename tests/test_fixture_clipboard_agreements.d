// Copy / cut / paste parity, frozen from the reference (task 1160).
//
// The measured question in this family is vertex SHARING. A pole hub belongs
// to every face of its fan, two plate quads share an edge, and an annulus
// shares sixteen vertices around its hole -- so "duplicate once per selection"
// and "duplicate once per face" give different vertex counts, and only a
// non-cube base separates them. Cutting half a fan asks the mirror question:
// the hub must SURVIVE the cut because the other half still uses it.
//
// The counts in expected_before/after are load-bearing here beyond their usual
// role: a paste lands its copy exactly on top of the original, so the position
// set is unchanged and only the counts (and the doubled face rings) can see it.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/clipboard_parity.json"));
}

unittest {
    runTopologyDiffSuite(import("fixtures/clipboard_dirty_parity.json"));
}
