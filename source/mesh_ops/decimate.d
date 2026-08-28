module mesh_ops.decimate;

// ---------------------------------------------------------------------------
// The decimation family: one kernel, `reduceToTarget` — iterative edge-collapse
// via a lazy-deletion binary min-heap with per-vertex generation stamps, plus
// its nested edgeCost / HeapEntry / heapPush / heapPop helpers. Split out of
// mesh.d as `mixin template MeshDecimateOps` by the mesh.d decomposition
// campaign (0407 §B.V2, task 0417).
//
// Converted to a module-level FREE FUNCTION by task 1903 Stage D2
// (`doc/mesh_edit_seam_plan.md` §4, §5.2 row D2) — the FIRST MUTATING family to
// cross the seam, so the three decisions below are the ones D3…H copy.
//
// (1) THE RECEIVER IS `ref MeshEditBatch ed` (§4.1, first cell). This kernel
//     writes vertices, faces, edges and marks; a batch is what turns that pile
//     of writes into ONE version stamp, ONE hidden-geometry derive and ONE bus
//     delivery at `close()`. The receiver is also the enforcement: there is no
//     spelling of this call that does not hold a batch, which is exactly what
//     `mixin`-into-`Mesh` could never state ("принудить нечем", the card's
//     opening complaint). Contrast the other two cells Stage C and D1 set:
//     `ref const(Mesh) m` for a read-only op, and a plain `ref Mesh m` — no
//     batch — for a query that only touches a `mutationVersion`-keyed memo.
//
// (2) THE MIXIN LEFT `struct Mesh` IN THE SAME CHANGE. A member reachable on
//     the receiver BEATS a same-name UFCS free function, silently — no
//     ambiguity, no warning — so a surviving `mixin MeshDecimateOps;` would
//     keep answering every call site and this file would be dead code that
//     reads as the implementation (plan Revision 2 caveat 1; measured as Stage
//     C's M-C-MIX″). `tests/unit/commit_seam_census_test.d` holds that as a
//     text census; the `static assert` at the bottom of this file holds the
//     same fact at `dub build` time, and catches the spellings a regex cannot
//     (a hand-written method, `mixin ...!()`, a named mixin).
//
// (3) THE CALLERS OPEN AN *UNRECORDED* BATCH, NOT A RECORDING ONE, and that is
//     a deliberate track-1 boundary rather than an oversight. §5.1 splits this
//     migration into two axes and forbids mixing them in one commit: axis 1 is
//     the conversion (its gate is byte-identity of the forward result), axis 2
//     is the undo migration (its gate is delta↔snapshot parity). `mesh.reduce`
//     and `ReductionTool` still undo through a whole-mesh `MeshSnapshot`, so a
//     RECORDING batch here would build a full op-log per reduce — per DRAG
//     FRAME on the tool's preview path, which §9 forbids outright — that
//     nothing reads and `close()` throws away. Stage L10 is where this family's
//     undo moves.
//
//     AND L10 IS NOT A CONSTRUCTOR FLIP FOR THIS FAMILY — an earlier draft of
//     this comment said it was, and the measurement says otherwise (Stage D2
//     review, MAJOR-2). Open a RECORDING batch over `reduceToTarget` on a
//     `subdivideCube(2)`-triangulated stand (V=98, F=192, target F/2) and the
//     op-log comes back `[SetPos:1, Reindex:1, RemoveVerts:1]` with
//     `delta.scope_ == kReduceEditScope`; `revert()` then returns TRUE and
//     restores V=98 with **F=96 of the pre-reduce 192**. The vertex side is
//     complete and the FACE side is absent, because the faces this kernel
//     drops go out through `weldVerticesByMask` →
//     `Mesh.applyVertexRemapAndRebuild` → `mesh_planes.rewriteFaces`, whose
//     op-log publisher is gated on `MeshEditTracker.wantsFaceReindex`
//     (`source/mesh_planes.d:450`) — default false, and set by NO production
//     code (the only site that arms it is
//     `tests/unit/mesh_edit_delta_face_reindex_test.d`).
//
//     STAGE L10 ANSWERED IT, AND NOT IN THIS FILE (2026-08-28). The decision
//     was ARM rather than refuse, and the arm went where the rewrite is: one
//     `faceReindexScope()` around `Mesh.applyVertexRemapAndRebuild`'s single
//     `rewriteFaces`. This family inherited the face side through the weld it
//     already calls — `reduce` is a member of the WELD group, so its face half
//     was never this kernel's to publish. Re-measured on the same stand: the
//     op-log is `[SetPos, MeshMapDelta, FaceReindex, RemoveVerts, Reindex]`
//     and `revert()` restores **F=192 of 192**.
//
//     WHAT REMAINS THIS FILE'S: the batch here is still `unrecorded`, so the
//     op-log above exists only under a recording batch opened by a test. The
//     command `mesh.reduce` is migrated at its own site
//     (`source/commands/mesh/reduce.d`); the tool's preview path is why this
//     constructor is not simply switched (§9 forbids an op-log per drag
//     frame). `tests/unit/mesh_ops/decimate_test.d` now pins the COMPLETE
//     revert, and its two assertions have separate mutations: the recorded
//     finalise write below and the arm named above.
//
// The kernel BODY is otherwise unchanged: every edit is an `ed.` prefix, plus
// the one recorded write described at the finalize below.
// ---------------------------------------------------------------------------
import mesh;
import math;
import mesh_edit_delta : MeshEditScope;
// `sqrt` — the 1902 rule cashed out, and the plan's own §4.3 table got this
// file wrong ("decimate.d: nothing beyond what they already import"). A free
// name in a `mixin template` body binds in the INSTANTIATION scope, and
// source/mesh.d opens with `import std.math : sqrt, isIdentical;` — so the
// four Newell-normal `sqrt` calls below resolved through mesh.d and NOT
// through this file's `import math;`. Measured at Stage D2 by the compiler:
// four `Error: sqrt is not defined` the moment the template wrapper came off.
import std.math : sqrt;

/// The change classes one `reduceToTarget` actually commits, for the batch its
/// callers open. It lives HERE, beside the kernel, and not spelled out at each
/// of the three call sites, because it is a property of what the kernel does —
/// three copies is three chances to drift, and the one that drifts is the one
/// that stops matching the op-log's declared scope when Stage L10 turns this
/// family's undo into a delta (`MeshEditTracker.declare` is what ends up in
/// `MeshEditDelta.scope_`).
///
/// `Geometry` = Points|Polygons: the collapse drops faces and the finalising
/// weld drops vertices. `Marks` : the weld rewrites selection / subpatch /
/// hide words. `Position` : the recorded finalise write below moves every
/// cluster member onto its representative.
enum uint kReduceEditScope =
    MeshEditScope.Geometry | MeshEditScope.Marks | MeshEditScope.Position;

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
size_t reduceToTarget(ref MeshEditBatch ed, size_t targetFaces, bool preserveBoundary) {
    import std.algorithm : sort;

    if (ed.faces.length == 0 || targetFaces >= ed.faces.length) return 0;

    immutable V = ed.vertices.length;
    immutable F = ed.faces.length;

    // Working positions (indexed by original vertex index).
    Vec3[] pos  = ed.vertices.dup;

    // Union-find: rep[vi] = representative of vi's cluster.
    int[] rep; rep.length = V;
    foreach (i; 0 .. V) rep[i] = cast(int)i;

    bool[] vAlive; vAlive.length = V; vAlive[] = true;
    bool[] fAlive; fAlive.length = F; fAlive[] = true;
    uint[] gen;   gen.length   = V;   // generation stamps (all 0)

    // vf[vi] = incident alive face indices for representative vi.
    uint[][] vf; vf.length = V;
    foreach (fi; 0 .. F)
        foreach (c; ed.faces[fi])
            if (c < V) vf[c] ~= cast(uint)fi;

    // ---- Nested helpers ----

    // Path-halving find with compression.
    int find(int x) {
        while (rep[x] != x) { rep[x] = rep[rep[x]]; x = rep[x]; }
        return x;
    }

    // Newell normal of alive face fi using working positions mapped via find().
    Vec3 faceNW(uint fi) {
        const uint[] f = ed.faces[fi];
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
            foreach (c; ed.faces[fi]) {
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
            foreach (c; ed.faces[fi]) {
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
            foreach (c; ed.faces[fi]) {
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
            foreach (c; ed.faces[fi]) {
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
    // EXPLICIT LENGTH POINTER — the backing slice is NEVER shrunk (task
    // 2130/2240). `heap.length--` in the old heapPop() breaks the GC's
    // in-place-append invariant the same way `stack = stack[0 .. $-1]` does:
    // `~=` extends a block in place only while `ptr + length` equals the
    // used-length recorded in that block, so the first heapPush() after
    // EVERY heapPop() reallocated and copied the whole heap. `hlen` is the
    // live heap size; `heap` only ever grows, at the top (index `hlen`), and
    // is reused across the whole collapse loop rather than reallocated per
    // pop/push pair.
    //
    // POSITIONS ARE UNCHANGED, which is what makes this safe for a HEAP and
    // not just a stack: heapPush/heapPop are pure index-and-comparison
    // routines over `heap[0 .. hlen]` — every read/write below only ever
    // touches an index strictly less than the CURRENT `hlen` (or `i`/`n`
    // derived from it), so replacing `heap.length` (the shrinking property)
    // with `hlen` (a plain counter) changes nothing about which entry sits
    // at which index, when, or which comparisons fire. The heap's pop order
    // — the greedy edge-collapse sequence downstream depends on — is
    // therefore bit-identical to before.
    struct HeapEntry { float cost; uint u, v, genU, genV; }
    HeapEntry[] heap;
    size_t hlen = 0;

    void heapPush(HeapEntry e) {
        if (hlen == heap.length) heap ~= e; else heap[hlen] = e;
        size_t i = hlen;
        ++hlen;
        while (i > 0) {
            size_t p = (i - 1) / 2;
            if (heap[i].cost < heap[p].cost) {
                auto t = heap[i]; heap[i] = heap[p]; heap[p] = t; i = p;
            } else break;
        }
    }

    HeapEntry heapPop() {
        auto top = heap[0];
        heap[0] = heap[hlen - 1];
        --hlen;
        size_t i = 0, n = hlen;
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
    heap.reserve(ed.edges.length);
    foreach (ei; 0 .. ed.edges.length) {
        uint u = ed.edges[ei][0], v = ed.edges[ei][1];
        if (u >= V || v >= V) continue;
        heapPush(HeapEntry(edgeCost(u, v), u, v, gen[u], gen[v]));
    }

    // Per-face exclusion scratch buffer (avoids O(F) allocation per candidate).
    bool[] excluded; excluded.length = F;

    // ---- Main collapse loop ----
    size_t aliveFaces = F;
    size_t collapses  = 0;

    while (aliveFaces > targetFaces && hlen > 0) {
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
                foreach (c; ed.faces[fi]) {
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
            auto mc = mappedCorners(ed.faces[fi], u, v);
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
                        foreach (c; ed.faces[fi2]) {
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
            auto mc = mappedCorners(ed.faces[fi], u, v);
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
                foreach (c; ed.faces[fi]) {
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
    //
    // TASK 1903 §2.5 — THE RECORDED WRITE, and the reason this family is the
    // one that consumes `setVertexPositions`. This used to read
    // `foreach (i; 0 .. V) vertices[i] = pos[find(cast(int)i)];` — a raw
    // coordinate write, the single class of mutation none of `Mesh`'s tracker
    // hooks can see. Under an open RECORDING batch it produced no op-log entry
    // at all, so a delta undo would restore the topology and leave every
    // coordinate at its post-collapse value. `setVertexPositions` captures the
    // before-values, emits ONE `Kind.SetPos` entry for the whole set and ONE
    // (deferred) `commitChange(Position)`, instead of V silent writes.
    //
    // WHAT THIS COMMIT CANNOT PROVE, stated rather than glossed (plan §5.7,
    // M-D2): `mesh.reduce` still undoes through a whole-mesh `MeshSnapshot`,
    // and `Kind.SetPos` still has no READER — the first one arrives at Stage
    // L10. A raw write and this call produce byte-identical forward positions,
    // so no behavioural test in the tree can tell them apart TODAY; reverting
    // this line reddens the position-write census (§5.7) and, only after L10,
    // `tests/fixtures/undo_parity/weld_merge.json`. What D2 does establish is
    // that the call is REACHED on the production `mesh.reduce` path, so L10
    // inherits a live producer rather than a dead branch.
    //
    // THE SUBSTITUTION IS BIT-EXACT, and it took a fix to become so (Stage D2
    // review, MAJOR-1). The bulk setter skips a write whose new value equals
    // the old one; spelled `==` that skip was NOT a no-op detector, because
    // `-0.0 == +0.0`: a cluster member sitting at `-0.0` whose collapse target
    // is `+0.0` kept its `-0.0` where the raw loop wrote `+0.0`. Measured, not
    // reasoned about: a 6×6 triangulated grid carrying one zero-length edge
    // whose endpoints differ only in the sign of x diverged in 9 of 320
    // (edge × target × preserveBoundary) cells, `80000000` against `00000000`.
    //
    // The comment this replaces claimed the following `weldVerticesByMask`
    // made the sign unobservable. IT DOES NOT: with `average=false` the
    // survivor of a cluster is its LOWEST-INDEXED member and it keeps its own
    // bits, and `meshPlanesJson` prints coordinates with `%.9g`, i.e. `-0` —
    // so a plane fixture sees it. `MeshEditBatch.sameBits` (source/mesh.d)
    // now compares bit patterns, which makes every position this kernel
    // produces identical to the pre-conversion loop's, and it removes the
    // excuse rather than relying on it — Stage H's `extrude.d:2341` has no
    // trailing weld at all and inherits the same primitive.
    uint[] setIdx; setIdx.reserve(V);
    Vec3[] setTo;  setTo.reserve(V);
    foreach (i; 0 .. V) { setIdx ~= cast(uint)i; setTo ~= pos[find(cast(int)i)]; }
    ed.setVertexPositions(setIdx, setTo);
    auto mask = new bool[](ed.vertices.length);
    mask[] = true;
    ed.weldVerticesByMask(mask, 1e-12);

    return collapses;
}

// ---------------------------------------------------------------------------
// Unit tests — co-located with the family they exercise (moved verbatim
// from mesh.d alongside the kernel above).
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// reduceToTarget kernel unittests (dub test --config=tests gate)
// ---------------------------------------------------------------------------
// (None here — task 0706 moved this family's blocks to
// tests/unit/mesh_ops/decimate_test.d, and they stayed there through the D2
// conversion.)

// ---------------------------------------------------------------------------
// The gate that outlives the text census (task 1903 Stage C review, MAJOR-1 —
// compile-time, not a unittest). A member of `Mesh` BEATS a same-name UFCS free
// function silently, so anything that puts this name back on the struct
// (`mixin MeshDecimateOps;`, `mixin ...!();`, a named mixin, a hand-written
// method with the old body) rebinds every call site to it and this module
// becomes dead code. The regex census in
// tests/unit/commit_seam_census_test.d sees only the literal `mixin Mesh*Ops;`
// spelling; this sees the fact, and at `dub build` time rather than only under
// --config=tests.
//
// It is ALSO the check that the receiver did not quietly widen back: a
// `Mesh.reduceToTarget` member could only exist by taking the mesh directly,
// i.e. by dropping the batch this stage exists to require.
// ---------------------------------------------------------------------------
static foreach (n; ["reduceToTarget"])
    static assert(!__traits(hasMember, Mesh, n),
        "`Mesh." ~ n ~ "` is a MEMBER again. A member BEATS a same-name UFCS free "
      ~ "function silently, so every call site binds back to it, the batch this "
      ~ "kernel takes as its receiver goes away with it, and task 1903 Stage D2 "
      ~ "means nothing. Whatever re-added it — `mixin MeshDecimateOps;`, "
      ~ "`mixin ...!();`, a named mixin, or a hand-written method — must go.");
