// Merge / spin / join / make-polygon parity, GEOMETRY CHANNEL ONLY, frozen
// from the reference (task 1160).
//
// Four of the nine thin-test tools, none of which had a reference-captured
// oracle before. All four agreed on geometry and differed on the post-command
// selection, so none of these fixtures carries an `expected_selection`.
//
// Two of them would pass vacuously without the frozen FACE RINGS:
//   spin  moves no vertex and changes no count -- it re-wires two faces onto
//         the other diagonal, and a position set cannot see that at all.
//   make  builds a face over vertices that already exist, so only the new ring
//         is evidence the polygon was built.
//
// The make-polygon cells are frozen for a second reason: five of the six
// divergences that family DID show were hand-written refusals the reference
// does not perform. The agreements are therefore the only measured statement
// about which rings are legal -- a ring in reverse order, a non-coplanar ring,
// a non-convex ring, and a ring naming one vertex twice.

import fixture_helpers;

void main() {}

unittest {
    runTopologyDiffSuite(import("fixtures/merge_faces_geometry_parity.json"));
}

unittest {
    runTopologyDiffSuite(import("fixtures/spin_quads_geometry_parity.json"));
}

unittest {
    runTopologyDiffSuite(import("fixtures/join_vertices_geometry_parity.json"));
}

unittest {
    runTopologyDiffSuite(import("fixtures/make_polygon_geometry_parity.json"));
}
