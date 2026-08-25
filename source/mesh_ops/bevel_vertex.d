module mesh_ops.bevel_vertex;

// ---------------------------------------------------------------------------
// MeshBevelVertexOps — `bevelVerticesByMask` (vertex bevel / vertex chamfer),
// mixed into struct Mesh (source/mesh.d) via `mixin MeshBevelVertexOps;`.
//
// Split out of source/mesh_ops/edge_bevel.d (task 0717, audit 0678 §2B-M2 step C).
// It shared a file with the edge bevel because both are called "bevel"; it
// shares no code with it — a different acceptance test, a different topology
// (split ring + cap N-gon) and a different caller
// (commands/mesh/vertex_bevel.d).
//
// Task 1240 (ledger rows 26/52) replaced the ACCEPTANCE TEST and the CAP-RING
// construction. Before it the kernel required an interior-manifold vertex of
// valence >= 3, which is why the reference chamfered 181 of 181 measured cells
// and we chamfered 21: a boundary corner — including the smallest case there
// is, one corner of one quad — was declined outright. The umbrella is now read
// off the FACE CORNERS rather than off the edge-face table, which answers both
// questions at once: it accepts an open fan, and it yields the cap ring in the
// order and winding the surrounding faces dictate (see `umbrellaOf`).
// ---------------------------------------------------------------------------
mixin template MeshBevelVertexOps() {
    /// One occurrence of a vertex in a face ring: the face, and the ring
    /// PREDECESSOR / SUCCESSOR of the vertex in it. The whole umbrella walk
    /// below is built out of these and nothing else.
    private static struct VertexBevelCorner { uint fi, pred, succ; }

    /// Vertex bevel: for each accepted vertex v, split each incident edge at
    /// v + amount*normalize(other−v) (one new vertex per edge, shared by the
    /// faces on both sides), rewrite every incident face to replace v with its
    /// two split points in face-ring order, and — at valence >= 3 — append a
    /// cap N-gon through those split points.
    ///
    /// ACCEPTANCE (task 1240). v is chamfered when its incident faces form ONE
    /// fan, open or closed:
    ///   * every face uses v at most once (no self-touching ring);
    ///   * no two of them LEAVE v along the same edge, and no two ENTER along
    ///     the same edge (that is the manifold condition, stated per corner);
    ///   * every edge at v is used by at least one face (a wire edge would be
    ///     left dangling on a vertex the op removes);
    ///   * the per-face links `succ -> pred` chain into a SINGLE run covering
    ///     every neighbour — two fans meeting at a point are declined.
    /// A BOUNDARY corner therefore qualifies, and valence 2 qualifies: the
    /// measured reference chamfers both. What is still declined, and is NOT
    /// measured anywhere, is the bow-tie vertex and the wire edge.
    ///
    /// CAP. Emitted only at valence >= 3 — at valence 2 the "cap" would be a
    /// two-point polygon, and the reference emits none there (the frozen
    /// boundary-corner cell keeps its single face and turns a quad into a
    /// pentagon). Its ring order and its WINDING both come out of the umbrella
    /// chain rather than a normal comparison: face f re-rings as
    /// `[.., pred, P(pred), P(succ), succ, ..]`, so the cap — sharing that new
    /// edge — must traverse `P(succ) -> P(pred)`, which is exactly the chain.
    ///
    /// Adjacent selected vertices are handled via a greedy vertex-disjoint
    /// selection so no two accepted vertices share an edge.
    ///
    /// Cap material/subpatch are carried from one incident face of v — NOT the
    /// chamfer-literal 0u. Rewritten-face attributes are 1:1 from the original
    /// slot.
    ///
    /// Returns the count of vertices actually processed (0 ⇒ no-op, caller
    /// should discard snapshot).
    size_t bevelVerticesByMask(const bool[] maskIn, float amount) {
        import std.math : isFinite;
        const mask = maskMinusHiddenVertices(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != vertices.length) return 0;
        // `!(amount >= 1e-6f)` and not `amount < 1e-6f`: the second lets a NaN
        // through (every comparison with NaN is false) and NaN*direction would
        // poison every split point of the chamfer.
        if (!isFinite(amount) || !(amount >= 1e-6f)) return 0;

        // Freeze original count before addVertex grows the array.
        const uint origVertCount = cast(uint)vertices.length;

        // ---- corner incidence, read from `faces` alone --------------------
        // Built once for the whole mesh (the empty-selection operand IS the
        // whole mesh), so the per-vertex walk below is O(valence), not O(F).
        VertexBevelCorner[][] corners = new VertexBevelCorner[][](origVertCount);
        foreach (fi; 0 .. faces.length) {
            auto f = faces[fi];
            immutable n = f.length;
            if (n < 3) continue;             // a 2-point polygon has no corner to cut
            foreach (k; 0 .. n) {
                uint v = f[k];
                if (v >= origVertCount) continue;
                corners[v] ~= VertexBevelCorner(cast(uint)fi,
                                                f[(k + n - 1) % n], f[(k + 1) % n]);
            }
        }
        // Incident-edge count straight off `edges`, so a vertex carrying an
        // edge NO face uses is declined rather than left with a stub pointing
        // at a corner this op is about to remove.
        auto edgeValence = new uint[](origVertCount);
        foreach (ei; 0 .. edges.length)
            foreach (v; edges[ei])
                if (v < origVertCount) ++edgeValence[v];

        // ---- the umbrella of one vertex, in CAP order ---------------------
        // Returns the neighbours of `vi` ordered so that consecutive entries
        // are the `succ`/`pred` pair of one incident face — i.e. exactly the
        // order the cap polygon runs in. Empty ⇒ `vi` is not chamferable.
        // Valences are small, so the working sets are linear-scanned arrays
        // rather than hash maps (this runs once per candidate vertex, and the
        // candidate set can be the entire mesh).
        uint[] umbrellaOf(uint vi) {
            auto cs = corners[vi];
            if (cs.length == 0) return null;
            uint[] succOf, predOf;   // parallel: succOf[i] -> predOf[i] is one face's link
            uint[] nb;
            foreach (c; cs) {
                if (c.pred == vi || c.succ == vi) return null;   // self-touching ring
                foreach (s; succOf) if (s == c.succ) return null; // two faces leave alike
                foreach (p; predOf) if (p == c.pred) return null; // two faces enter alike
                succOf ~= c.succ;
                predOf ~= c.pred;
                bool haveP = false, haveS = false;
                foreach (x; nb) { if (x == c.pred) haveP = true; if (x == c.succ) haveS = true; }
                if (!haveP) nb ~= c.pred;
                if (!haveS) nb ~= c.succ;
            }
            if (nb.length < 2) return null;
            if (nb.length != edgeValence[vi]) return null;   // wire edge at vi
            // The fan's open end, when it has one: a neighbour no face enters
            // by. Two such ⇒ two fans meeting at this point, which this kernel
            // declines (nothing measured says what the reference does there).
            uint start = uint.max;
            foreach (x; nb) {
                bool isPred = false;
                foreach (p; predOf) if (p == x) { isPred = true; break; }
                if (isPred) continue;
                if (start != uint.max) return null;
                start = x;
            }
            if (start == uint.max) start = nb[0];   // closed umbrella — any node
            uint[] ring;
            uint cur = start;
            for (size_t guard = 0; guard <= nb.length; ++guard) {
                bool seen = false;
                foreach (r; ring) if (r == cur) { seen = true; break; }
                if (seen) break;
                ring ~= cur;
                long nx = -1;
                foreach (i, s; succOf) if (s == cur) { nx = cast(long)predOf[i]; break; }
                if (nx < 0) break;
                cur = cast(uint)nx;
            }
            if (ring.length != nb.length) return null;   // broken / multiple fans
            return ring;
        }

        // ---- greedy vertex-disjoint acceptance ----------------------------
        bool[]   accepted           = new bool[](origVertCount);
        bool[]   neighborOfAccepted = new bool[](origVertCount);
        uint[][] umbrella           = new uint[][](origVertCount);
        size_t   processed          = 0;

        foreach (vi; 0 .. origVertCount) {
            if (vi >= mask.length || !mask[vi]) continue;
            if (neighborOfAccepted[vi]) continue;
            auto ring = umbrellaOf(cast(uint)vi);
            if (ring.length == 0) continue;
            accepted[vi]  = true;
            umbrella[vi]  = ring;
            ++processed;
            foreach (x; ring)
                if (x < neighborOfAccepted.length) neighborOfAccepted[x] = true;
        }
        if (processed == 0) return 0;

        // one split vertex per incident edge of each accepted v
        uint[ulong]  splitByKey;  // edgeKey(a,b) → new vertex index
        uint[][uint] capRings;    // vi → ordered split-vert indices for cap
        uint[uint]   capSrc;      // vi → one incident fi (attr carry)

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;

            uint[] ring;
            foreach (other; umbrella[vi]) {
                ulong key = edgeKey(cast(uint)vi, other);
                if (key !in splitByKey) {
                    Vec3 sp = vertices[vi] +
                              amount * safeNormalize(vertices[other] - vertices[vi]);
                    splitByKey[key] = addVertex(sp);
                }
                ring ~= splitByKey[key];
            }
            capRings[cast(uint)vi] = ring;
            // Attr donor for the cap: the first face of `vi`'s fan walk, the
            // same one this kernel has always used. Deliberately NOT
            // `corners[vi][0].fi` (the lowest-index incident face) — the two
            // pick different faces on a cube corner, and which one donates the
            // material/subpatch is pinned by a unittest.
            uint donor = corners[vi][0].fi;
            foreach (fi; facesAroundVertex(cast(uint)vi)) { donor = cast(uint)fi; break; }
            capSrc[cast(uint)vi] = donor;
        }

        // per-face substitution map: accepted vi → [sp_pred, sp_succ]
        VertSub[][uint] faceSubs;

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;
            foreach (c; corners[vi]) {
                uint spPV = splitByKey[edgeKey(c.pred, cast(uint)vi)];
                uint spVS = splitByKey[edgeKey(cast(uint)vi, c.succ)];
                faceSubs.require(c.fi) ~= VertSub(cast(uint)vi, [spPV, spVS]);
            }
        }

        // single rebuild pass: rewritten faces then cap faces. `oldOfNew` is
        // the newToOld correspondence mesh_planes.rewriteFaces wants —
        // identity for (a) (every survivor keeps its OWN old index, so its
        // own material/part/setmask/order/marks ride through unchanged),
        // capSrc[vi] for (b) (a cap face's attrs are donor-carried, task
        // 1240's `capSrc`, not the chamfer 0u literal).
        uint[][] newFaces;
        uint[]   oldOfNew;

        // (a) surviving / substituted faces
        foreach (fi; 0 .. faces.length) {
            auto orig = faces[fi];
            newFaces ~= rebuildFaceWithVertexSubs(orig, cast(uint)fi in faceSubs);
            oldOfNew ~= cast(uint)fi;
        }

        // (b) cap faces — attrs carried from capSrc, not the chamfer 0u literal.
        //     Ring order AND winding come from the umbrella chain (see the
        //     header): no normal is consulted, because on the open fans this
        //     kernel now accepts there is no "average incident normal" that
        //     answers the question the chain already answers exactly.
        size_t capStart = newFaces.length;
        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;
            uint[] capRing = capRings[cast(uint)vi];
            if (capRing.length < 3) continue;   // valence 2 ⇒ no cap (measured)

            newFaces ~= capRing.dup;
            oldOfNew ~= capSrc[cast(uint)vi];
        }

        // (c) commit arrays. `rewriteFaces` carries faceMaterial/facePart/
        // faceSetMask/faceMarks/faceSelectionOrder through `oldOfNew`, but a
        // cap face must start UNSELECTED (order 0), never inheriting its
        // donor's stamp the other four planes DO inherit (plan §2.7a) — the
        // hand-rolled code always zeroed the cap range's order (`newOrd ~=
        // 0;`), never the survived range's (inherited by identity), which
        // the carry already reproduces via oldOfNew[i] == i.
        rewriteFaces(this, newFaces, FaceSource(oldOfNew));
        foreach (i; capStart .. faces.length) faceSelectionOrder[i] = 0;

        // Re-mask the just-carried word in place — src here IS faceMarks
        // (self-aliasing; see Mesh.setFaceMarksFrom's own doc comment for
        // why that is safe) — was Subpatch-only; now carries the whole word
        // (task 0613 §4.2).
        setFaceMarksFrom(faceMarks, ~Marks.Select);

        faceSelectionOrderCounter = 0;
        foreach (fi; capStart .. faces.length)
            selectFace(cast(int)fi);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        // Stated loss (task 0830). The edge and face bevels left the drop set
        // in task 0697 against frozen cases; this one has no frozen case at all,
        // so there is nothing to port it against and a guess would be worse than
        // the zero.
        dropCornerProvenance(CornerDrop.VertexBevelNoCase);
        finalizeTopologyEdit();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }
}
