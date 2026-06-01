// test_mesh_map.d — round-trip + lifecycle test for the generic mesh-map
// registry (named, typed per-element float attribute channels on Mesh).
//
// Pure-D unit test (no HTTP, no running vibe3d): builds in-process meshes and
// exercises the MeshMap registry API + lifecycle directly. There is no HTTP
// surface for mesh maps, so the source-backed unittest path (run_test.d's
// `dmd -unittest -i`) is the right home — the same pattern as
// tests/test_xform_matrix_kernel.d. Unittests run before the empty main().
//
// Coverage:
//   - add a Point map (dim 1, "weight") + an Edge map (dim 2, "uv")
//   - set + read back values (element-major layout round-trip)
//   - a topology edit that changes element count → map data.length stays
//     consistent (no crash, correct length, no out-of-bounds reads)
//   - snapshot capture → mutate → restore → values come back
//   - missing-map lookup returns null / empty safely
//   - removeMeshMap works
//   - PolyVertex reserved-rejection (addMeshMap returns null)

import std.math : fabs;

import mesh : Mesh, MeshMap, MapDomain, makeCube;
import snapshot : MeshSnapshot;

void main() {}

private bool feq(float a, float b, float eps = 1e-6f) {
    return fabs(a - b) < eps;
}

// ---------------------------------------------------------------------------
// add + element-major round-trip (Point dim-1 + Edge dim-2)
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    const nv = m.vertices.length; // 8
    const ne = m.edges.length;    // 12 (deduplicated cube edges)

    // Point map, dim 1 (vertex weight).
    auto wm = m.addMeshMap("weight", 1, MapDomain.Point);
    assert(wm !is null, "addMeshMap(Point) should succeed");
    assert(wm.dim == 1);
    assert(wm.domain == MapDomain.Point);
    assert(wm.data.length == nv * 1, "Point map data sized to vertices*dim");
    // zero-initialised
    foreach (f; wm.data) assert(feq(f, 0.0f));

    // Edge map, dim 2 (UV-like).
    auto uv = m.addMeshMap("uv", 2, MapDomain.Edge);
    assert(uv !is null, "addMeshMap(Edge) should succeed");
    assert(uv.dim == 2);
    assert(uv.data.length == ne * 2, "Edge map data sized to edges*dim");

    // Set + read back — element-major layout: element i at data[i*dim .. +dim].
    assert(m.setMeshMapValue("weight", 3, [0.75f]));
    auto w3 = m.meshMapValue("weight", 3);
    assert(w3.length == 1 && feq(w3[0], 0.75f), "Point round-trip");
    // underlying storage check: element 3 dim 1 → data[3]
    assert(feq(m.meshMap("weight").data[3], 0.75f), "element-major Point layout");

    assert(m.setMeshMapValue("uv", 5, [0.1f, 0.9f]));
    auto uv5 = m.meshMapValue("uv", 5);
    assert(uv5.length == 2 && feq(uv5[0], 0.1f) && feq(uv5[1], 0.9f), "Edge dim-2 round-trip");
    // element 5 dim 2 → data[10], data[11]
    assert(feq(m.meshMap("uv").data[10], 0.1f) && feq(m.meshMap("uv").data[11], 0.9f),
        "element-major Edge layout");
}

// ---------------------------------------------------------------------------
// lifecycle: a topology edit that changes element count keeps map data.length
// consistent (no crash, no out-of-bounds). Drives the resize through the same
// funnel the selection/marks arrays use.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap("weight", 1, MapDomain.Point);
    m.addMeshMap("uv", 2, MapDomain.Edge);

    // Grow vertices, then drive the documented resize funnel. The map must
    // follow vertex count in lock-step.
    import math : Vec3;
    m.vertices ~= Vec3(2, 2, 2);
    m.resizeVertexSelection(); // funnel that resizeMeshMaps(Point) hooks into
    assert(m.meshMap("weight").data.length == m.vertices.length * 1,
        "Point map follows vertex count after growth via resize funnel");

    // A genuine destructive topology op: collapse two cube verts onto one
    // point and weld. This shrinks vertices + edges; maps must stay
    // length-consistent (resized, not value-preserved) with no crash.
    auto m2 = makeCube();
    m2.addMeshMap("weight", 1, MapDomain.Point);
    m2.addMeshMap("uv", 2, MapDomain.Edge);
    // mark every vert so weldCoincidentVertices has nothing yet; instead move
    // vert 1 onto vert 0 then weld coincident.
    m2.vertices[1] = m2.vertices[0];
    m2.weldCoincidentVertices();
    // After weld + compact, lengths must agree with current geometry.
    assert(m2.meshMap("weight").data.length == m2.vertices.length * 1,
        "Point map length consistent after destructive weld");
    assert(m2.meshMap("uv").data.length == m2.edges.length * 2,
        "Edge map length consistent after destructive weld");
    // Reading any in-range element must not crash / must return dim-sized.
    if (m2.vertices.length > 0) {
        auto v0 = m2.meshMapValue("weight", m2.vertices.length - 1);
        assert(v0.length == 1);
    }
}

// ---------------------------------------------------------------------------
// snapshot capture → mutate → restore → values come back
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    m.addMeshMap("weight", 1, MapDomain.Point);
    m.addMeshMap("uv", 2, MapDomain.Edge);
    m.setMeshMapValue("weight", 2, [0.5f]);
    m.setMeshMapValue("uv", 0, [0.25f, 0.75f]);

    auto snap = MeshSnapshot.capture(m);
    assert(snap.filled);

    // Mutate the live maps after capture — snapshot must NOT alias.
    m.setMeshMapValue("weight", 2, [9.0f]);
    m.setMeshMapValue("uv", 0, [0.0f, 0.0f]);
    m.removeMeshMap("weight"); // also drop a whole map to prove restore re-adds
    assert(m.meshMap("weight") is null);

    snap.restore(m);

    // Values + registry come back.
    auto w2 = m.meshMapValue("weight", 2);
    assert(w2.length == 1 && feq(w2[0], 0.5f), "snapshot restored Point value");
    auto uv0 = m.meshMapValue("uv", 0);
    assert(uv0.length == 2 && feq(uv0[0], 0.25f) && feq(uv0[1], 0.75f),
        "snapshot restored Edge value");
    // lengths still consistent with restored geometry
    assert(m.meshMap("weight").data.length == m.vertices.length * 1);
    assert(m.meshMap("uv").data.length == m.edges.length * 2);
}

// ---------------------------------------------------------------------------
// missing-map lookup is safe; removeMeshMap works; defensive bounds checks
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();

    // Missing map: lookup → null, value-read → empty, value-write → false.
    assert(m.meshMap("nope") is null);
    assert(m.meshMapValue("nope", 0).length == 0);
    assert(!m.setMeshMapValue("nope", 0, [1.0f]));

    auto wm = m.addMeshMap("weight", 1, MapDomain.Point);
    assert(wm !is null);

    // Duplicate name rejected.
    assert(m.addMeshMap("weight", 1, MapDomain.Point) is null,
        "duplicate map name must be rejected");

    // dim mismatch on write rejected.
    assert(!m.setMeshMapValue("weight", 0, [1.0f, 2.0f]),
        "dim mismatch write must be rejected");

    // out-of-range element index → empty read / false write, no crash.
    assert(m.meshMapValue("weight", 9999).length == 0);
    assert(!m.setMeshMapValue("weight", 9999, [1.0f]));

    // zero-dim and empty-name rejected.
    assert(m.addMeshMap("zerodim", 0, MapDomain.Point) is null);
    assert(m.addMeshMap("", 1, MapDomain.Point) is null);

    // removeMeshMap works + is idempotent on the second call.
    assert(m.removeMeshMap("weight"));
    assert(m.meshMap("weight") is null);
    assert(!m.removeMeshMap("weight"), "removing an absent map returns false");
}

// ---------------------------------------------------------------------------
// PolyVertex domain is RESERVED in v1 → addMeshMap rejects it.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    assert(m.addMeshMap("corner_uv", 2, MapDomain.PolyVertex) is null,
        "PolyVertex domain is reserved and must be rejected in v1");
    assert(m.meshMap("corner_uv") is null);
}
