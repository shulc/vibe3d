module vibe3d.mesh.ops.mesh_ops.face_alignment;
import vibe3d.mesh.core.mesh;
import vibe3d.util.math.math;

    /// For each connected island of selected faces, computes the island's
    /// area-weighted average plane (centroid + normal via raw Newell sum)
    /// and orthogonally projects every vertex touched by that island onto
    /// the plane.  Position-only; no topology change.
    ///
    /// Degenerate island (areaSum < 1e-12 or |normalSum| < 1e-6): skipped.
    ///
    /// **Shared-vertex semantic**: every vertex referenced by a selected face
    /// is projected, including verts also used by unselected faces.
    /// Adjacent unselected faces are therefore deformed.  Use topologically
    /// isolated test fixtures to get unambiguous residuals.
    ///
    /// **Compute-before-write with coordinate-scaled eps**: displacements are
    /// computed first; only verts whose |displacement| >= eps are written,
    /// where eps = 1e-6 * max(1, maxAbsCoord).  An already-planar (even
    /// tilted) selection returns 0 without a version bump — clean no-op.
    ///
    /// Returns: number of vertices moved; 0 means nothing changed.
    size_t alignFacesByMask(ref MeshEditBatch ed, in bool[] faceMaskIn) {
        auto m = &ed.mesh();
        with (*m) { 
        const faceMask = maskMinusHiddenFaces(faceMaskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        import std.math : sqrt, abs;

        if (faceMask.length != faces.length) return 0;

        bool anySelected = false;
        foreach (b; faceMask) if (b) { anySelected = true; break; }
        if (!anySelected) return 0;

        // Union-find over face indices: two selected faces sharing a vertex
        // belong to the same island (identical pattern to collapseFacesByMask).
        int[] parent;
        parent.length = faces.length;
        foreach (i; 0 .. faces.length) parent[i] = cast(int)i;

        int findRoot(int x) {
            while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
            return x;
        }
        void unite(int a, int b) {
            a = findRoot(a); b = findRoot(b);
            if (a != b) parent[b] = a;
        }

        // Map each vertex to the first selected face that contains it.
        // When a second selected face shares that vertex, unite the two faces.
        int[] vertToFace;
        vertToFace.length = vertices.length;
        vertToFace[] = -1;
        foreach (fi; 0 .. faces.length) {
            if (!faceMask[fi]) continue;
            foreach (v; faces[fi]) {
                if (v >= vertices.length) continue;
                if (vertToFace[v] == -1)
                    vertToFace[v] = cast(int)fi;
                else
                    unite(cast(int)fi, vertToFace[v]);
            }
        }

        // Collect all verts touched by selected faces.
        bool[] inSelection;
        inSelection.length = vertices.length;
        foreach (i; 0 .. vertices.length)
            if (vertToFace[i] >= 0) inSelection[i] = true;

        // Per-island: accumulate raw Newell sum (area-weighted normal) and
        // area-weighted centroid.  The raw Newell vector has magnitude 2*area,
        // so summing gives an area-weighted normal without a separate divide.
        Vec3[int]  normalSum;
        float[int] areaSum;
        Vec3[int]  centroidSum;

        foreach (fi; 0 .. faces.length) {
            if (!faceMask[fi]) continue;
            int root = findRoot(cast(int)fi);
            const uint[] face = faces[fi];

            // Raw Newell sum for this face (same loop as faceNormal, no divide).
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. face.length) {
                Vec3 a = vertices[face[i]];
                Vec3 b = vertices[face[(i + 1) % face.length]];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            float rawLen = sqrt(nx*nx + ny*ny + nz*nz);
            float area   = 0.5f * rawLen;            // area of this face
            Vec3  centF  = faceCentroid(cast(uint)fi);

            if (root in normalSum) {
                normalSum[root]   += Vec3(nx, ny, nz);
                areaSum[root]     += area;
                centroidSum[root] += centF * area;
            } else {
                normalSum[root]   = Vec3(nx, ny, nz);
                areaSum[root]     = area;
                centroidSum[root] = centF * area;
            }
        }

        // Build per-island plane (C, n) from the accumulators.
        struct IslandPlane { Vec3 C; Vec3 n; }
        IslandPlane[int] planes;
        foreach (root, ns; normalSum) {
            float as_ = areaSum[root];
            if (as_ < 1e-12f) continue;
            float nlen = sqrt(ns.x*ns.x + ns.y*ns.y + ns.z*ns.z);
            if (nlen < 1e-6f) continue;
            Vec3 n  = Vec3(ns.x / nlen, ns.y / nlen, ns.z / nlen);
            Vec3 cs = centroidSum[root];
            planes[root] = IslandPlane(Vec3(cs.x / as_, cs.y / as_, cs.z / as_), n);
        }

        // Compute-before-write: signed distance from each touched vertex to
        // its island's plane.  Explicitly zero-initialised (float.init = NaN).
        float[] dScalar;
        dScalar.length = vertices.length;
        foreach (ref f; dScalar) f = 0.0f;

        foreach (vi; 0 .. vertices.length) {
            if (!inSelection[vi]) continue;
            int root = findRoot(vertToFace[vi]);
            if (!(root in planes)) continue;
            auto pl = planes[root];
            Vec3 v = vertices[vi];
            dScalar[vi] = (v.x - pl.C.x) * pl.n.x
                        + (v.y - pl.C.y) * pl.n.y
                        + (v.z - pl.C.z) * pl.n.z;
        }

        // Coordinate-scaled epsilon: max absolute coordinate over touched verts.
        float maxAbsCoord = 1.0f;
        foreach (vi; 0 .. vertices.length) {
            if (!inSelection[vi]) continue;
            Vec3 v = vertices[vi];
            if (abs(v.x) > maxAbsCoord) maxAbsCoord = abs(v.x);
            if (abs(v.y) > maxAbsCoord) maxAbsCoord = abs(v.y);
            if (abs(v.z) > maxAbsCoord) maxAbsCoord = abs(v.z);
        }
        float eps = 1e-6f * maxAbsCoord;

        // --- TASK 1903 STAGE L2-h: THE PROJECTION GOES THROUGH THE DOOR ---
        //
        // These three lines were `vertices[vi].x -= d * pl.n.x;` and friends —
        // a raw position write reaching no hook, so `mesh.align` produced NO
        // `Kind.SetPos` at all and its delta-path undo left every projected
        // vertex on the plane. Plan §L2.0 row 3: `polygon_align` is a POSITION
        // command whose row in §5.5 names only the create kinds.
        //
        // COLLECT THEN WRITE ONCE, the L0-d shape (A): `setVertexPositions`
        // takes ONE op-log entry and ONE `commitChange` for the whole set,
        // where a per-vertex door would take one of each per vertex — the task
        // 1330 shape that makes a bulk kernel quadratic through the derived-hide
        // sweep. Buffers are pre-sized off a counting pass, never grown by `~=`
        // (task 2160).
        //
        // `moved` KEEPS ITS OLD MEANING — the number of vertices whose
        // displacement cleared `eps` — and is deliberately NOT taken from the
        // door's return. `setVertexPositions` additionally drops a write whose
        // result is BIT-IDENTICAL to what is already there, which is reachable
        // here (a displacement that clears `eps` but whose three products
        // underflow to zero), and a caller that reported the door's count would
        // change which meshes `mesh.align` REFUSES.
        size_t moved = 0;
        foreach (vi; 0 .. vertices.length) {
            if (!inSelection[vi]) continue;
            if (abs(dScalar[vi]) < eps) continue;
            ++moved;
        }
        if (moved == 0) return 0;

        {
            import std.array : uninitializedArray;
            auto idx = uninitializedArray!(uint[])(moved);
            auto to  = uninitializedArray!(Vec3[])(moved);
            size_t w = 0;
            foreach (vi; 0 .. vertices.length) {
                if (!inSelection[vi]) continue;
                immutable float d = dScalar[vi];
                if (abs(d) < eps) continue;
                auto pl = planes[findRoot(vertToFace[vi])];
                idx[w] = cast(uint) vi;
                to[w]  = Vec3(vertices[vi].x - d * pl.n.x,
                              vertices[vi].y - d * pl.n.y,
                              vertices[vi].z - d * pl.n.z);
                ++w;
            }
            assert(w == moved, "Mesh.alignFacesByMask: the counting pass and "
                             ~ "the write pass disagree");
            // The door publishes `MeshEditScope.Position` itself — the
            // `commitChange` this replaces is inside it, not dropped.
            setVertexPositions(idx, to);
        }
        return moved;
        }
    }


