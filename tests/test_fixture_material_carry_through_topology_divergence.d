// Task 1140 -- KNOWN DIVERGENCE: material carry through a topology change.
// Ledger row 35.
//
// A DIFFERENT CHANNEL FROM GEOMETRY, and the reason this fixture needs one:
// in both cells the geometry is identical on the two sides -- same vertices,
// same counts, same face rings, same winding, an empty gap in every geometric
// channel. The disagreement is entirely about which faces inherit a tag.
//
//   subdivide_one_tagged_face  reference 1 + 4   ours 5      (tag lost)
//   bevel_one_tagged_face      reference 5 + 7   ours 1 + 11 (tag not spread)
//
// Tag VALUES never enter the comparison: the reference's material names and
// our material ids are two private namespaces. Only the PARTITION of faces
// they induce is a shared fact, and it is written here as groups of face
// centroids so it keys on coordinates like everything else.
//
// The runner additionally requires the two partitions to still DIFFER, so a
// carry that starts working reddens here rather than passing quietly.
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
    enum string json = import("fixtures/material_carry_through_topology_divergence.json");
    runKnownDivergenceSuite(json);
}
