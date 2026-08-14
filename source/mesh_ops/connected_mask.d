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
