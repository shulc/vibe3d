module mesh_ops.connected_mask;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshConnectedMaskOps — connected-component vertex mask + element-centroid
// helpers, mixed into struct Mesh (source/mesh.d) via
// `mixin MeshConnectedMaskOps;`. Extracted from
// source/tools/transform/xfrm_transform.d (xfrm Phase B, task: move the pure
// mesh algorithms out of XfrmTransformTool — the BFS body of
// `updateConnectMask` and the edge-midpoint anchor of `takeEdge`; the stage
// writes / ACEN notifies stay in the tool). Method bodies below are verbatim
// cut/paste from xfrm_transform.d (only the extraction boundary is new), same
// architectural decision as the mesh.d decomposition campaign (0407 §B.V2,
// task 0412: mixin template over a package move or UFCS free-functions).
// ---------------------------------------------------------------------------
mixin template MeshConnectedMaskOps() {
    // Connected-component BFS seeded at `seedVi`, over the CSR vert→vert
    // adjacency (relation D, edge-based) — same provider as smooth.d /
    // smoothSubdivide. Returns an order-independent visited set (`true` for
    // every vertex reachable from the seed), so (unlike the two smooth
    // kernels) the CSR neighbor order carries no bit-stability requirement
    // here.
    //
    // An out-of-range `seedVi` returns the NULL mask. The seed bounds used to
    // be the caller's job — true while this was a private helper with exactly
    // one caller (XfrmTransformTool.updateConnectMask, which still guards) —
    // but the extraction made it a public `Mesh` method, so the guard belongs
    // here where every caller gets it. `null` is the same value that caller
    // already writes to FalloffStage.connectMask for an out-of-range seed, so
    // the contract downstream is unchanged.
    bool[] connectedComponentMask(size_t seedVi) {
        size_t n = vertices.length;
        if (seedVi >= n) return null;
        const(size_t)[] adjOff;
        const(uint)[]   adjNbrs;
        vertexAdjacencyCSR(adjOff, adjNbrs);
        bool[] visited = new bool[](n);
        size_t[] queue;
        queue ~= seedVi;
        visited[seedVi] = true;
        while (queue.length > 0) {
            size_t v = queue[$ - 1];
            queue.length -= 1;
            foreach (nb; adjNbrs[adjOff[v] .. adjOff[v + 1]])
                if (!visited[nb]) { visited[nb] = true; queue ~= nb; }
        }
        return visited;
    }

    // Edge midpoint (centroid of the two endpoints) — the click-independent
    // element-falloff edge anchor, formerly computed inline in
    // xfrm_transform.d:takeEdge.
    Vec3 edgeCentroid(uint ei) const {
        auto edge = edges[ei];
        Vec3 a = vertices[edge[0]];
        Vec3 b = vertices[edge[1]];
        return (a + b) * 0.5f;
    }
}

// ===========================================================================
// Module unittests.
// ===========================================================================

unittest { // connectedComponentMask: an out-of-range seed returns the NULL
           // mask instead of writing past the end of `visited`. The bounds
           // check used to live in the single (private) caller; making this a
           // public Mesh method made an unguarded second caller possible, so
           // the guard moved into the kernel. `null` matches what
           // XfrmTransformTool.updateConnectMask already writes for an
           // out-of-range seed, so no consumer sees a new value.
    Mesh m = makeCube();
    assert(m.vertices.length == 8, "setup: cube has 8 verts");

    assert(m.connectedComponentMask(m.vertices.length) is null,
           "seed == vertices.length must return the null mask");
    assert(m.connectedComponentMask(m.vertices.length + 100) is null,
           "a seed past the end must return the null mask");
    assert(m.connectedComponentMask(size_t.max) is null,
           "size_t.max (a negative int cast to size_t) must return null");

    // The in-range path is untouched: a cube is one connected component.
    bool[] all = m.connectedComponentMask(0);
    assert(all !is null, "an in-range seed must still return a mask");
    assert(all.length == m.vertices.length, "mask is one entry per vertex");
    foreach (vi, reached; all)
        assert(reached, "a cube is a single connected component");
}

unittest { // connectedComponentMask: an empty mesh has no valid seed at all —
           // seed 0 is already out of range, so the guard (not the BFS) answers.
    Mesh empty;
    assert(empty.vertices.length == 0, "setup: no vertices");
    assert(empty.connectedComponentMask(0) is null,
           "seed 0 on an empty mesh is out of range → null mask");
}

unittest { // connectedComponentMask: two disjoint components — the mask
           // covers exactly the seed's own component, both ways round.
    Mesh m;
    // Component A: a quad at z = 0.  Component B: a quad at z = 5.
    foreach (q; 0 .. 2) {
        const float z = q * 5.0f;
        uint a = m.addVertex(Vec3(0, 0, z));
        uint b = m.addVertex(Vec3(1, 0, z));
        uint c = m.addVertex(Vec3(1, 1, z));
        uint d = m.addVertex(Vec3(0, 1, z));
        m.addFace([a, b, c, d]);
    }
    m.buildLoops();
    assert(m.vertices.length == 8, "setup: 4 verts per disjoint quad");

    bool[] fromA = m.connectedComponentMask(0);
    foreach (vi; 0 .. 4) assert(fromA[vi],  "seed 0 reaches its own quad");
    foreach (vi; 4 .. 8) assert(!fromA[vi], "seed 0 must not reach the far quad");

    bool[] fromB = m.connectedComponentMask(4);
    foreach (vi; 0 .. 4) assert(!fromB[vi], "seed 4 must not reach the near quad");
    foreach (vi; 4 .. 8) assert(fromB[vi],  "seed 4 reaches its own quad");
}

unittest { // edgeCentroid is the midpoint of the edge's two endpoints.
    import std.math : abs;
    Mesh m = makeCube();
    foreach (ei; 0 .. m.edges.length) {
        auto e = m.edges[ei];
        Vec3 want = (m.vertices[e[0]] + m.vertices[e[1]]) * 0.5f;
        Vec3 got  = m.edgeCentroid(cast(uint)ei);
        assert(abs(got.x - want.x) < 1e-6f
            && abs(got.y - want.y) < 1e-6f
            && abs(got.z - want.z) < 1e-6f,
               "edgeCentroid must be the endpoint midpoint");
    }
}
