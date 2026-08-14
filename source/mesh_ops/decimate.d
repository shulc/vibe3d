module mesh_ops.decimate;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshDecimateOps — polygon decimation kernel (reduceToTarget: iterative
// edge-collapse via a lazy-deletion binary min-heap with per-vertex
// generation stamps, plus its local edgeCost/HeapEntry/heapPush/heapPop
// helpers), mixed into struct Mesh (source/mesh.d) via
// `mixin MeshDecimateOps;`. Split out of mesh.d as part of the mesh.d
// decomposition campaign (0407 §B.V2, task 0417 — continuation of the
// task-0412 plane-cut pilot and this same task's bridge/loop-slice
// extractions; see task 0412's doc for the architectural decision: mixin
// template over a package move or UFCS free-functions). Method body below
// is verbatim cut/paste from mesh.d (only the extraction boundary is new).
// ---------------------------------------------------------------------------
mixin template MeshDecimateOps() {
    // -----------------------------------------------------------------------
    // Polygon decimation kernel
    // -----------------------------------------------------------------------

    /// Iterative edge-collapse decimator. Collapses edges greedily in order of
    /// increasing cost = length * (1 + curvature) until `targetFaces` alive
    /// faces remain or no valid collapse is left. Uses a lazy-deletion binary
    /// min-heap with per-vertex generation stamps; guards reject non-manifold,
    /// inverting, degenerate, and (when preserveBoundary) boundary collapses.
    /// Finalizes via weldVerticesByMask with an all-true mask. Returns the
    /// number of collapses applied (0 = no-op, caller must not commit).
    size_t reduceToTarget(size_t targetFaces, bool preserveBoundary) {
        import std.algorithm : sort;

        if (faces.length == 0 || targetFaces >= faces.length) return 0;

        immutable V = vertices.length;
        immutable F = faces.length;

        // Working positions (indexed by original vertex index).
        Vec3[] pos  = vertices.dup;

        // Union-find: rep[vi] = representative of vi's cluster.
        int[] rep; rep.length = V;
        foreach (i; 0 .. V) rep[i] = cast(int)i;

        bool[] vAlive; vAlive.length = V; vAlive[] = true;
        bool[] fAlive; fAlive.length = F; fAlive[] = true;
        uint[] gen;   gen.length   = V;   // generation stamps (all 0)

        // vf[vi] = incident alive face indices for representative vi.
        uint[][] vf; vf.length = V;
        foreach (fi; 0 .. F)
            foreach (c; faces[fi])
                if (c < V) vf[c] ~= cast(uint)fi;

        // ---- Nested helpers ----

        // Path-halving find with compression.
        int find(int x) {
            while (rep[x] != x) { rep[x] = rep[rep[x]]; x = rep[x]; }
            return x;
        }

        // Newell normal of alive face fi using working positions mapped via find().
        Vec3 faceNW(uint fi) {
            const uint[] f = faces[fi];
            if (f.length < 3) return Vec3(0, 1, 0);
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. f.length) {
                Vec3 a = pos[find(cast(int)f[i])];
                Vec3 b = pos[find(cast(int)f[(i + 1) % f.length])];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            float len = sqrt(nx*nx + ny*ny + nz*nz);
            return len > 1e-6f ? Vec3(nx/len, ny/len, nz/len) : Vec3(0, 1, 0);
        }

        // Newell normal from an explicit mapped corner list (indices into pos[]).
        Vec3 newellNW(const uint[] corners) {
            if (corners.length < 3) return Vec3(0, 1, 0);
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. corners.length) {
                Vec3 a = pos[corners[i]];
                Vec3 b = pos[corners[(i + 1) % corners.length]];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            float len = sqrt(nx*nx + ny*ny + nz*nz);
            return len > 1e-6f ? Vec3(nx/len, ny/len, nz/len) : Vec3(0, 1, 0);
        }

        // Newell area magnitude from a mapped corner list.
        float newellArea(const uint[] corners) {
            if (corners.length < 3) return 0;
            float nx = 0, ny = 0, nz = 0;
            foreach (i; 0 .. corners.length) {
                Vec3 a = pos[corners[i]];
                Vec3 b = pos[corners[(i + 1) % corners.length]];
                nx += (a.y - b.y) * (a.z + b.z);
                ny += (a.z - b.z) * (a.x + b.x);
                nz += (a.x - b.x) * (a.y + b.y);
            }
            return sqrt(nx*nx + ny*ny + nz*nz);
        }

        // mappedCorners: apply find() + v→u substitution + consecutive+wraparound dedup.
        // Mirrors `Mesh.weldVerticesByMask`'s face-rewrite logic.
        uint[] mappedCorners(const uint[] faceCorners, uint u, uint v) {
            uint[] f;
            foreach (c; faceCorners) {
                uint r = cast(uint)find(cast(int)c);
                uint mapped = (r == v) ? u : r;
                if (f.length == 0 || f[$ - 1] != mapped) f ~= mapped;
            }
            if (f.length > 1 && f[$ - 1] == f[0]) f = f[0 .. $ - 1];
            return f;
        }

        // Count alive faces incident to both representative a and b,
        // excluding any face with fStamp[fi] == excludeStamp.
        // Used for edge-boundary and post-collapse manifold counting.
        int sharedFaceCount(uint a, uint b, bool[] excluded) {
            int cnt = 0;
            foreach (fi; vf[a]) {
                if (!fAlive[fi] || excluded[fi]) continue;
                foreach (c; faces[fi]) {
                    if (cast(uint)find(cast(int)c) == b) { ++cnt; break; }
                }
            }
            return cnt;
        }

        // Edge cost: length * (1 + curvature).  Boundary edge → curvature=0.
        float edgeCost(uint u, uint v) {
            Vec3 du = pos[u], dv = pos[v];
            float dx = du.x - dv.x, dy = du.y - dv.y, dz = du.z - dv.z;
            float length = sqrt(dx*dx + dy*dy + dz*dz);
            if (length < 1e-9f) return 0;

            // Find the (up to 2) alive faces shared by u and v.
            uint[2] sf; int nSf = 0;
            foreach (fi; vf[u]) {
                if (!fAlive[fi] || nSf >= 2) continue;
                foreach (c; faces[fi]) {
                    if (cast(uint)find(cast(int)c) == v) { sf[nSf++] = fi; break; }
                }
            }
            float curvature = 0;
            if (nSf == 2) {
                Vec3 nA = faceNW(sf[0]), nB = faceNW(sf[1]);
                float d = nA.x*nB.x + nA.y*nB.y + nA.z*nB.z;
                curvature = (1.0f - d) * 0.5f;
            }
            return length * (1.0f + curvature);
        }

        // Is edge (u,v) a boundary edge (fewer than 2 alive incident faces)?
        bool isEdgeBoundary(uint u, uint v) {
            int cnt = 0;
            foreach (fi; vf[u]) {
                if (!fAlive[fi]) continue;
                foreach (c; faces[fi]) {
                    if (cast(uint)find(cast(int)c) == v) { if (++cnt >= 2) return false; break; }
                }
            }
            return cnt < 2;
        }

        // Is vertex u a boundary vertex (any incident alive edge is boundary)?
        bool isVertexBoundary(uint u) {
            bool[uint] seen;
            foreach (fi; vf[u]) {
                if (!fAlive[fi]) continue;
                foreach (c; faces[fi]) {
                    uint w = cast(uint)find(cast(int)c);
                    if (w != u && !(w in seen)) {
                        seen[w] = true;
                        if (isEdgeBoundary(u, w)) return true;
                    }
                }
            }
            return false;
        }

        // ---- Min-heap ----
        struct HeapEntry { float cost; uint u, v, genU, genV; }
        HeapEntry[] heap;

        void heapPush(HeapEntry e) {
            heap ~= e;
            size_t i = heap.length - 1;
            while (i > 0) {
                size_t p = (i - 1) / 2;
                if (heap[i].cost < heap[p].cost) {
                    auto t = heap[i]; heap[i] = heap[p]; heap[p] = t; i = p;
                } else break;
            }
        }

        HeapEntry heapPop() {
            auto top = heap[0];
            heap[0] = heap[$ - 1];
            heap.length--;
            size_t i = 0, n = heap.length;
            while (true) {
                size_t l = 2*i+1, r = 2*i+2, s = i;
                if (l < n && heap[l].cost < heap[s].cost) s = l;
                if (r < n && heap[r].cost < heap[s].cost) s = r;
                if (s == i) break;
                auto t = heap[i]; heap[i] = heap[s]; heap[s] = t; i = s;
            }
            return top;
        }

        // ---- Build initial heap from mesh edges ----
        heap.reserve(edges.length);
        foreach (ei; 0 .. edges.length) {
            uint u = edges[ei][0], v = edges[ei][1];
            if (u >= V || v >= V) continue;
            heapPush(HeapEntry(edgeCost(u, v), u, v, gen[u], gen[v]));
        }

        // Per-face exclusion scratch buffer (avoids O(F) allocation per candidate).
        bool[] excluded; excluded.length = F;

        // ---- Main collapse loop ----
        size_t aliveFaces = F;
        size_t collapses  = 0;

        while (aliveFaces > targetFaces && heap.length > 0) {
            auto e = heapPop();
            uint u = e.u, v = e.v;

            // Validate gen stamps and alive status.
            if (e.genU != gen[u] || e.genV != gen[v]) continue;
            if (!vAlive[u] || !vAlive[v]) continue;
            if (cast(uint)find(cast(int)u) != u) continue;
            if (cast(uint)find(cast(int)v) != v) continue;

            // Verify edge still exists (at least one alive shared face).
            {
                bool ok = false;
                foreach (fi; vf[u]) {
                    if (!fAlive[fi]) continue;
                    foreach (c; faces[fi]) {
                        if (cast(uint)find(cast(int)c) == v) { ok = true; break; }
                    }
                    if (ok) break;
                }
                if (!ok) continue;
            }

            // ---- Guard 1: boundary ----
            if (preserveBoundary) {
                if (isEdgeBoundary(u, v)) continue;
                if (isVertexBoundary(u) || isVertexBoundary(v)) continue;
            }

            // ---- Collect affected face set (alive faces touching u or v) ----
            // Mark affected faces using the excluded[] scratch (reused, zeroed below).
            uint[] affFaces;
            foreach (fi; vf[u]) if (fAlive[fi]) { excluded[fi] = true; affFaces ~= fi; }
            foreach (fi; vf[v]) if (fAlive[fi] && !excluded[fi]) { excluded[fi] = true; affFaces ~= fi; }

            // Compute mappedCorners for each affected face; classify DROP vs SURVIVE.
            struct FaceSim { uint fi; uint[] mc; }
            FaceSim[] surv;
            size_t dropCnt = 0;
            bool rejected  = false;

            foreach (fi; affFaces) {
                auto mc = mappedCorners(faces[fi], u, v);
                if (mc.length < 3) {
                    ++dropCnt;
                } else {
                    // Guard 2a: no non-consecutive repeated vertex in mappedCorners.
                    bool[uint] seen2a;
                    foreach (vi; mc) {
                        if (vi in seen2a) { rejected = true; break; }
                        seen2a[vi] = true;
                    }
                    if (rejected) break;
                    surv ~= FaceSim(fi, mc);
                }
            }

            // Reset excluded[] for affected faces before any continue.
            scope(exit) { foreach (fi; affFaces) excluded[fi] = false; affFaces.length = 0; }

            if (rejected) continue;

            // Guard 2b: surviving mapped edges must not land on >2 alive faces.
            // Also detect duplicate surviving mapped corner sets (link violation).
            uint[][] canonSurv;
            foreach (ref fs; surv) {
                uint[] ca = fs.mc.dup; sort(ca);
                // Check for duplicate surviving corner set.
                foreach (ref cb; canonSurv) {
                    if (ca == cb) { rejected = true; break; }
                }
                if (rejected) break;
                canonSurv ~= ca;

                foreach (j; 0 .. fs.mc.length) {
                    uint a = fs.mc[j], b = fs.mc[(j + 1) % fs.mc.length];
                    // Count from surviving affected faces.
                    int fromSurv = 0;
                    foreach (ref fs2; surv) {
                        foreach (k; 0 .. fs2.mc.length) {
                            uint x = fs2.mc[k], y = fs2.mc[(k + 1) % fs2.mc.length];
                            if ((x==a && y==b) || (x==b && y==a)) { ++fromSurv; break; }
                        }
                    }
                    // Count from unaffected alive faces.
                    // If a==u or b==u: all faces with that vert are in affected → fromUnaffected=0.
                    int fromUnaffected = 0;
                    if (a != u && b != u) {
                        foreach (fi2; vf[a]) {
                            if (!fAlive[fi2] || excluded[fi2]) continue;
                            foreach (c; faces[fi2]) {
                                if (cast(uint)find(cast(int)c) == b) { ++fromUnaffected; break; }
                            }
                        }
                    }
                    if (fromSurv + fromUnaffected > 2) { rejected = true; break; }
                }
                if (rejected) break;
            }
            if (rejected) continue;

            // Guards 3 + 4: inversion + area, evaluated at the ACTUAL midpoint.
            // 1. Capture 'before' normals at current positions.
            // 2. Move u and v to midpoint (the real post-collapse location).
            // 3. Test 'after' normals and area against the midpoint geometry.
            // 4. Restore pos[u]/pos[v] on any rejection; keep midpoint on success.
            {
                Vec3 savedU = pos[u], savedV = pos[v];
                Vec3 midpt  = Vec3((savedU.x + savedV.x) * 0.5f,
                                   (savedU.y + savedV.y) * 0.5f,
                                   (savedU.z + savedV.z) * 0.5f);

                Vec3[] beforeNW;
                beforeNW.length = surv.length;
                foreach (i, ref fs; surv) beforeNW[i] = faceNW(fs.fi);

                pos[u] = midpt;
                pos[v] = midpt;  // v→u already mapped in fs.mc; coincide for weld

                foreach (i, ref fs; surv) {
                    Vec3 after = newellNW(fs.mc);
                    float dot = beforeNW[i].x*after.x + beforeNW[i].y*after.y + beforeNW[i].z*after.z;
                    if (dot < 0) { rejected = true; break; }
                    if (newellArea(fs.mc) < 1e-6f) { rejected = true; break; }
                }

                if (rejected) {
                    pos[u] = savedU;
                    pos[v] = savedV;
                    continue;
                }
                // pos[u] == pos[v] == midpt; fall through to apply.
            }

            // ---- Apply collapse: u = survivor, v = dead ----
            // pos[u] and pos[v] are already the midpoint (set in the guard block).

            rep[v]    = u;
            vAlive[v] = false;
            gen[u]++;          // invalidate stale heap entries for u

            // Mark DROP faces dead; count face reduction.
            foreach (fi; affFaces) {
                if (!fAlive[fi]) continue;
                auto mc = mappedCorners(faces[fi], u, v);
                if (mc.length < 3) { fAlive[fi] = false; }
            }
            aliveFaces -= dropCnt;

            // Merge v's face list into u's, deduplicate, remove dead faces.
            vf[u] ~= vf[v];
            vf[v].length = 0;
            {
                bool[uint] seen3;
                uint[] fresh;
                fresh.reserve(vf[u].length);
                foreach (fi; vf[u]) {
                    if (fi in seen3 || !fAlive[fi]) continue;
                    seen3[fi] = true;
                    fresh ~= fi;
                }
                vf[u] = fresh;
            }

            // Push fresh cost entries for u's new 1-ring.
            {
                bool[uint] neighbors;
                foreach (fi; vf[u]) {
                    if (!fAlive[fi]) continue;
                    foreach (c; faces[fi]) {
                        uint w = cast(uint)find(cast(int)c);
                        if (w != u && vAlive[w] && !(w in neighbors)) {
                            neighbors[w] = true;
                        }
                    }
                }
                foreach (w, _; neighbors)
                    heapPush(HeapEntry(edgeCost(u, w), u, w, gen[u], gen[w]));
            }

            ++collapses;
        }

        if (collapses == 0) return 0;

        // ---- Finalize: coincide all cluster members then weld ----
        foreach (i; 0 .. V) vertices[i] = pos[find(cast(int)i)];
        auto mask = new bool[](vertices.length);
        mask[] = true;
        weldVerticesByMask(mask, 1e-12);

        return collapses;
    }
}

// ---------------------------------------------------------------------------
// Unit tests — co-located with the family they exercise (moved verbatim
// from mesh.d alongside the kernel above).
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// reduceToTarget kernel unittests (dub test --config=tests gate)
// ---------------------------------------------------------------------------
