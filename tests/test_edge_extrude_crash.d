// Regression test for task 0311 — fuzzer-found process crash in
// Mesh.extrudeEdgesByMask.
//
// Pure-D unit test (no HTTP, no running vibe3d instance): builds an in-process
// cube and calls extrudeEdgesByMask directly, the same pattern as
// tests/test_mesh_map.d / tests/test_xform_matrix_kernel.d. A RangeError
// thrown deep inside the kernel takes the WHOLE `vibe3d --test` process down
// under the HTTP-driven suite (it cannot be caught from the client side, only
// observed as a dropped connection) — the source-backed unittest path is the
// only way to catch it directly and assert it does not happen.
//
// Root cause (confirmed via instrumented repro before the fix): on a cube,
// selecting two DISJOINT interior edges that happen to share a common
// NEIGHBOUR face at one endpoint each (e.g. edges (0,3) and (4,5) — both
// touch face [0,4,7,3], vertex 0 as a neighbour corner of the first edge,
// vertex 4 as a "back" corner of the second) triggers a face-corner-rewrite
// ordering hazard:
//   1. The neighbour-face rewrite pass (which runs BEFORE the along-edge
//      "needsAlong" scan) replaces corner 0 in face [0,4,7,3] with a freshly
//      minted inset vertex.
//   2. A sufficiently large overshoot `width` clamps that inset (via the
//      existing far-vertex clamp) all the way to vertex 4's own position —
//      i.e. the new inset vertex lands EXACTLY where vertex 4 already sits.
//   3. The needsAlong scan then reads that same face's corners to classify
//      vertex 4's "back face" boundary edges, but the adjacency snapshot
//      (`edgeFaces`) it consults predates the rewrite, so it doesn't
//      recognise the brand-new inset vertex id — it conservatively (and here,
//      wrongly) concludes vertex 4 needs an along-edge inset.
//   4. Materialising that along-edge inset then measures a near-zero tangent
//      (the "far" vertex it would offset along coincides with vertex 4 by
//      construction) and bails out via `continue` WITHOUT writing
//      `freeEndAlongVert[4]`.
//   5. The later read `freeEndAlongVert[c]` (mesh.d, side-face rewrite pass)
//      then misses that key → `core.exception.RangeError`.
//
// Fix: `needsAlongAt(v)` (mesh.d) now checks membership in the MATERIALIZED
// `freeEndAlongVert` map instead of the pre-materialization `needsAlong`
// intent map, so "no along-vert was actually built" always degrades
// gracefully to the plain (valence-3-style) fallback — never a crash. This is
// a read-side guard, not a forced write: it deliberately does NOT synthesize
// a coincident along-vert in the degenerate case (that would trade the crash
// for a zero-length-edge/degenerate-face defect instead, which is the
// contents of the separate task 0313 — same underlying overshoot-clamp
// mechanism, different symptom, intentionally not addressed here).

import std.math : abs;
import mesh : Mesh, makeCube;

void main() {}

// Basic structural sanity: every face has ≥3 corners, every corner index is
// in range, and no face repeats a vertex id (a dangling/degenerate index
// would show up as either an out-of-range index — caught directly by D's
// array bounds check as we iterate — or a repeated corner).
void assertMeshValid(ref Mesh m) {
    assert(m.vertices.length > 0, "mesh has no vertices");
    assert(m.faces.length > 0, "mesh has no faces");
    foreach (fi, f; m.faces) {
        assert(f.length >= 3, "degenerate face arity < 3");
        foreach (c; f)
            assert(c < m.vertices.length,
                "dangling face-corner index out of vertex range");
        foreach (k; 0 .. f.length) {
            uint a = f[k];
            uint b = f[(k + 1) % f.length];
            assert(a != b, "face has a zero-length edge (repeated corner)");
        }
    }
    foreach (e; m.edges) {
        assert(e[0] < m.vertices.length && e[1] < m.vertices.length,
            "dangling edge endpoint out of vertex range");
        assert(e[0] != e[1], "degenerate zero-length edge");
    }
}

// --- Exact crash repro (task 0311): two disjoint interior edges, extrude=-5,
//     overshoot width=100. Must complete without throwing and leave a valid
//     mesh (never a crash, never silent corruption).
unittest {
    auto m = makeCube();
    auto mask = new bool[](m.edges.length);
    mask[0] = true; // edge (0,3)
    mask[4] = true; // edge (4,5) — disjoint from edge 0, shares a neighbour
                    // face with it at one endpoint each (see header)
    size_t n = m.extrudeEdgesByMask(mask, -5.0f, 100.0f);
    assert(n == 2, "both selected edges should extrude");
    assertMeshValid(m);
}

// --- Same shape, positive extrude — confirms the crash isn't tied to the
//     sign of `extrude`, only to the overshoot `width`.
unittest {
    auto m = makeCube();
    auto mask = new bool[](m.edges.length);
    mask[0] = true;
    mask[4] = true;
    size_t n = m.extrudeEdgesByMask(mask, 5.0f, 100.0f);
    assert(n == 2, "both selected edges should extrude");
    assertMeshValid(m);
}

// --- Sanity control: the ORIGINAL non-crashing width (0.3) on the same
//     selection stays a well-formed no-along-vert cube-corner extrude — the
//     fix must not perturb the well-behaved case.
unittest {
    auto m = makeCube();
    auto mask = new bool[](m.edges.length);
    mask[0] = true;
    mask[4] = true;
    size_t n = m.extrudeEdgesByMask(mask, -5.0f, 0.3f);
    assert(n == 2, "both selected edges should extrude");
    assertMeshValid(m);
}
