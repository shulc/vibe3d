module mesh_ops.select_loop;

// ---------------------------------------------------------------------------
// MeshSelectLoopOps — the select.loop family: the border predicates, the
// recovered edge-loop walk (selectLoopEdges and its three branch helpers), the
// vertex walk (selectLoopVertices) and the face band walk (selectLoopFaces),
// plus the frozen head-restart oracles the differential test measures the
// forward-only scans against. Mixed into struct Mesh (source/mesh.d) via
// `mixin MeshSelectLoopOps;`.
//
// Split out of mesh.d (task 0717, audit 0678 §2B-M3 item 2). Every method
// body is a verbatim cut/paste; nothing is dedented, because a mixin
// template's members sit at the same indent as the struct members they
// become. Of the 18 members moved, four are called from outside the family
// (isEdgeBorder, isVertexBorder, selectLoopEdges/Vertices/Faces) and they
// stay Mesh members, so no call site anywhere changes; the other fourteen
// have no caller outside this file.
// ---------------------------------------------------------------------------
import mesh;
import math;

mixin template MeshSelectLoopOps() {
    // -----------------------------------------------------------------------
    // select.loop (edge) — recovered-algorithm helper (task 0457)
    // -----------------------------------------------------------------------
    // The bare "select.loop" edge command reproduces the reference tool's
    // recovered behavior, which is a strictly richer superset of the plain
    // quad edge-strip walk above (`walkEdgeLoop`): for a REGULAR seed edge
    // (both incident faces are quads, and neither hop lands on a valence
    // irregularity or a boundary-adjacent vertex) it degenerates to exactly
    // that walk run from each incident face and combined — so the two are
    // deliberately layered rather than merged: `walkEdgeLoop` stays untouched
    // for its other ordered-walk consumers (`select.more`, `select.between`,
    // support-loop candidate generation), and `selectLoopEdges` composes it
    // with the extra branches below. Provenance/validation:
    // `toolcards/select.loop/findings.md` (private).

    /// True if edge `ei` sits on an open boundary of the CURRENT face set —
    /// exactly one incident face. Purely topological (face-count), matching
    /// the recovered border predicate; deliberately NOT a material/UV-seam
    /// classifier (a distinct, unrelated family ruled out during recovery).
    bool isEdgeBorder(uint ei) const {
        uint n = 0;
        foreach (fi; facesAroundEdge(ei)) { ++n; if (n > 1) break; }
        return n == 1;
    }

    /// True if vertex `vi` touches at least one border edge (`isEdgeBorder`).
    bool isVertexBorder(uint vi) const {
        foreach (ei; edgesAroundVertex(vi))
            if (isEdgeBorder(ei)) return true;
        return false;
    }

    /// Count of border edges (`isEdgeBorder`) incident to vertex `vi`.
    uint borderEdgeCountAtVertex(uint vi) const {
        uint n = 0;
        foreach (ei; edgesAroundVertex(vi))
            if (isEdgeBorder(ei)) ++n;
        return n;
    }

    /// Return the OTHER edge of triangle `tri` that touches vertex `pivot`,
    /// excluding the edge with key `excludeKey` (the one just arrived on /
    /// the seed) — a triangle vertex touches exactly 2 of the triangle's 3
    /// edges, so this is unambiguous. Returns `~0u` if not found (defensive;
    /// shouldn't happen for a well-formed triangle touching `pivot`).
    private uint triangleOtherEdgeAt(const(uint)[] tri, uint pivot, ulong excludeKey) const {
        foreach (j; 0 .. 3) {
            uint va = tri[j], vb = tri[(j + 1) % 3];
            if (va != pivot && vb != pivot) continue;
            ulong k = edgeKey(va, vb);
            if (k == excludeKey) continue;
            uint ei = edgeIndexByKey(k);
            if (ei != ~0u) return ei;
        }
        return ~0u;
    }

    /// One direction of the recovered edge-loop walk: `seedEdge` combined
    /// with one of its (up to two) incident faces, `startFace`. Returns the
    /// ADDITIONAL edges this direction contributes (never includes the seed
    /// itself; empty means "this direction dead-ends at the seed").
    ///
    /// Gates mirror the recovered per-hop dispatch (findings.md
    /// the reference's loop next-edge dispatch), evaluated once using the seed's own hop pivot:
    ///   1. ANY odd valence at the pivot vertex while the seed is an
    ///      interior edge (2 incident faces) dead-ends this direction
    ///      outright — no floor. This fires just as readily on a plain
    ///      valence-3 vertex (every corner of an ordinary closed cube/box
    ///      is one) as on a valence-5 pole centre: a stock cube's edge-loop
    ///      is genuinely the 4-edge fallback face below, not a 7-edge union
    ///      of two adjacent perimeters — confirmed by a dedicated closed-
    ///      mesh capture (`cube_corner_edge0`) plus an rr/gdb trace of
    ///      the reference's loop next-edge dispatch reaching this exact bail with vcount=3,
    ///      incident-face-count==2 (see findings.md's Gate-1 section; an
    ///      earlier `>=5`-floor calibration here was an un-traced
    ///      hypothesis, since ruled out).
    ///   2. an even (>=4) valence pivot touching more than 2 border edges
    ///      also dead-ends (spec-complete; not exercised by the 11 cases).
    ///   3. a non-border seed whose pivot vertex is itself boundary-adjacent
    ///      dead-ends too — the rim-vertex direction of the same pole case.
    /// Past the gates, this steps quad-to-quad exactly like `walkEdgeLoop`
    /// (kept as a separate stepper, not a shared call, precisely so that
    /// helper stays byte-identical for its other ordered-walk consumers) —
    /// but reacts differently at a crossing that lands on an irregular face,
    /// wherever along the chain it occurs (rule 5 is not always the very
    /// first face touching the seed — a triangle can sit several quads in):
    ///   * a triangle succeeds exactly that ONE hop (the triangle's other
    ///     edge touching the current pivot) and stops — no further chaining,
    ///     no fallback.
    ///   * an n-gon (>=5 sides) fails outright from that point — whatever
    ///     was accumulated before it stands as this direction's result.
    int[] selectLoopDirectionEdges(uint seedEdge, uint startFace) const {
        if (startFace >= faces.length) return [];
        const sfv0 = faces[startFace];
        if (sfv0.length < 3) return [];
        int si = findEdgeInFace(startFace, edgeKeyOf(seedEdge));
        if (si < 0) return [];
        uint pivot0 = sfv0[(cast(uint)si + 1) % sfv0.length];

        uint vcount = vertexValence(pivot0);
        if ((vcount & 1) != 0) return [];                                // gate 1
        if (vcount >= 4 && borderEdgeCountAtVertex(pivot0) > 2) return [];// gate 2
        if (isVertexBorder(pivot0)) return [];                          // gate 3

        if (sfv0.length == 3) {
            uint ei = triangleOtherEdgeAt(sfv0, pivot0, edgeKeyOf(seedEdge));
            return ei != ~0u ? [cast(int)ei] : [];
        }
        if (sfv0.length != 4) return []; // n-gon immediately across the seed

        uint a = sfv0[si], b = pivot0;
        int curFace = cast(int)startFace;
        int[] res;
        bool[ulong] vis; vis[edgeKeyOf(seedEdge)] = true;
        while (true) {
            const face = faces[curFace];
            if (face.length != 4) break; // reached via `nf` below; already a quad here
            int jb = -1;
            foreach (j; 0 .. 4) if (face[j] == b) { jb = j; break; }
            if (jb < 0) break;
            uint prev = face[(jb - 1 + 4) % 4], next = face[(jb + 1) % 4], c;
            if      (prev == a) c = next;
            else if (next == a) c = prev;
            else break;
            uint sei = edgeIndex(b, c);
            if (sei == ~0u) break;
            int nf = adjacentFaceThrough(sei, cast(uint)curFace);
            if (nf < 0) break; // open boundary — natural terminating chain
            const nface = faces[nf];
            if (nface.length == 3) {
                uint ei = triangleOtherEdgeAt(nface, b, edgeKey(b, c));
                if (ei != ~0u) res ~= cast(int)ei;
                break;
            }
            if (nface.length != 4) break; // n-gon: fails outright from here
            int jb2 = -1;
            foreach (j; 0 .. 4) if (nface[j] == b) { jb2 = j; break; }
            if (jb2 < 0) break;
            uint p2 = nface[(jb2 - 1 + 4) % 4], n2 = nface[(jb2 + 1) % 4], d;
            if      (p2 == c) d = n2;
            else if (n2 == c) d = p2;
            else break;
            uint bd_ei = edgeIndex(b, d);
            if (bd_ei == ~0u) break;
            ulong ck = edgeKey(b, d);
            if (ck in vis) break; // closure
            vis[ck] = true;
            res ~= cast(int)bd_ei;
            a = b; b = d; curFace = nf;
        }
        return res;
    }

    /// Fallback shared by the two "both directions dead-ended at the seed"
    /// rules (an n-gon or a valence pole immediately across the seed): select
    /// every edge of the seed's own largest-vertex-count incident face, ties
    /// broken by whichever face is found first (i.e. `incFaces`' own order).
    int[] selectLoopFallbackFace(const(uint)[] incFaces) const {
        uint best = incFaces[0];
        foreach (fi; incFaces[1 .. $])
            if (faces[fi].length > faces[best].length) best = fi;
        const fv = faces[best];
        int[] result;
        bool[ulong] seen;
        foreach (j; 0 .. fv.length) {
            ulong k = edgeKey(fv[j], fv[(j + 1) % fv.length]);
            uint ei = edgeIndexByKey(k);
            if (ei == ~0u || (k in seen)) continue;
            seen[k] = true;
            result ~= cast(int)ei;
        }
        return result;
    }

    /// Rule 7: `seedEdge` is itself on an open boundary — chain along the
    /// boundary loop instead of the regular quad-opposite walk. From each
    /// endpoint in turn, repeatedly hop to another border edge at the far
    /// vertex (excluding the edge just arrived on) until either a dead end
    /// (no other border edge there) or closure (the far vertex lands back on
    /// one of the seed's own two endpoints — the boundary loop is closed).
    /// Closure stops the walk immediately and skips the second endpoint
    /// entirely, matching the recovered algorithm's "combine, don't restart"
    /// closure behavior (also used by the plain quad walk above).
    int[] selectLoopBorderChain(uint seedEdge) const {
        uint u = edges[seedEdge][0], v = edges[seedEdge][1];

        struct ChainResult { int[] edges; bool closed; }
        ChainResult chainFrom(uint from) {
            int[] res;
            bool[ulong] vis; vis[edgeKeyOf(seedEdge)] = true;
            uint cur = from;
            uint lastEdge = seedEdge;
            while (true) {
                int next = -1;
                foreach (ei; edgesAroundVertex(cur)) {
                    if (ei == lastEdge) continue;
                    ulong k = edgeKeyOf(ei);
                    if (k in vis) continue;
                    if (!isEdgeBorder(ei)) continue;
                    next = cast(int)ei;
                    break;
                }
                if (next < 0) return ChainResult(res, false);
                vis[edgeKeyOf(cast(uint)next)] = true;
                res ~= next;
                uint a = edges[next][0], b = edges[next][1];
                uint far = (a == cur) ? b : a;
                if (far == u || far == v) return ChainResult(res, true);
                cur = far;
                lastEdge = cast(uint)next;
            }
        }

        auto dirV = chainFrom(v);
        int[] result = [cast(int)seedEdge] ~ dirV.edges;
        if (dirV.closed) return result;

        auto dirU = chainFrom(u);
        bool[ulong] seen;
        foreach (ei; result) seen[edgeKeyOf(cast(uint)ei)] = true;
        foreach (ei; dirU.edges) {
            ulong k = edgeKeyOf(cast(uint)ei);
            if (k in seen) continue;
            seen[k] = true;
            result ~= ei;
        }
        return result;
    }

    /// Recovered `select.loop` (edge) algorithm — the single entry point
    /// `commands/select/loop.d`'s edge branch calls per initially-selected
    /// seed edge. See findings.md (private) for the full per-rule provenance
    /// and the 11-case validation this reproduces bit-exact.
    int[] selectLoopEdges(uint seedEdge) const {
        if (seedEdge >= edges.length) return [];

        uint[] incFaces;
        foreach (fi; facesAroundEdge(seedEdge)) incFaces ~= fi;

        if (incFaces.length == 0) return [cast(int)seedEdge]; // stray/degenerate edge
        if (incFaces.length == 1) return selectLoopBorderChain(seedEdge); // rule 7

        bool anyHops = false;
        int[][] dirResults = new int[][](incFaces.length);
        foreach (i, fi; incFaces) {
            dirResults[i] = selectLoopDirectionEdges(seedEdge, fi);
            if (dirResults[i].length > 0) anyHops = true;
        }

        if (!anyHops) return selectLoopFallbackFace(incFaces); // rules 4 & 6

        bool[ulong] seen;
        int[] result;
        void add(int ei) {
            ulong k = edgeKeyOf(cast(uint)ei);
            if (k in seen) return;
            seen[k] = true;
            result ~= ei;
        }
        add(cast(int)seedEdge);
        foreach (dr; dirResults) foreach (ei; dr) add(ei);
        return result;
    }

    // -----------------------------------------------------------------------
    // select.loop (vertex) — recovered-algorithm helper (task 0390)
    // -----------------------------------------------------------------------
    // The bare "select.loop" vertex command reproduces the reference's
    // recovered behavior (toolcards/select.loop/findings_fv.md, private —
    // rr/gdb live-validated). It shares edge mode's per-hop
    // dispatch (odd-valence gate, quad fan step, triangle special case,
    // n-gon failure) but with the two context flags the vertex path zeroes:
    // there is NO boundary-adjacent-vertex early-exit (boundary endpoints
    // are INCLUDED in the loop), and a hop whose current edge is a border
    // edge routes into a border-chain continuation instead of the regular
    // fan walk. The seed must be an adjacent selected vertex PAIR; a lone
    // selected vertex (or none, or no adjacent pair) yields an empty
    // result — the command REPLACES the selection wholesale (the reference
    // purges unconditionally, then commits), which is exactly how "single
    // vertex clears the selection" falls out. There is no fallback face in
    // vertex mode (unlike edge mode). Hidden/locked elements are
    // unmodelled (Marks.Hide/Lock are reserved/unused). Layered next to —
    // not merged into — `walkVertexLoop`, which stays untouched for its
    // ordered-walk consumers.

    /// Full per-edge / per-vertex incidence for the select.loop recovered
    /// algorithms (reference incidence-list semantics). Deliberately NOT
    /// the half-edge
    /// fan-walk helpers (`facesAroundVertex`/`edgesAroundVertex`/
    /// `facesAroundEdge`): those truncate at non-manifold ("bowtie")
    /// vertices and non-manifold edges, while the reference's incidence
    /// cache always returns the complete star. Fuzz repro
    /// fz_sloop_v_pole_tri2_hole2_0021 (a bowtie seed vertex) pinned this.
    /// `wantVertexStars = false` builds ONLY `edgeFaces` and leaves the two
    /// per-vertex stars null — the polygon walk reads neither, and they are
    /// the larger two thirds of the build (one appended slice per vertex of
    /// every face, plus one per edge endpoint). Use `buildLoopEdgeFaces`.
    private void buildLoopIncidence(out uint[][] vertEdges, out uint[][] edgeFaces,
                                    out uint[][] vertFaces,
                                    bool wantVertexStars = true) const {
        if (wantVertexStars) {
            vertEdges = new uint[][](vertices.length);
            foreach (ei; 0 .. edges.length) {
                vertEdges[edges[ei][0]] ~= cast(uint)ei;
                vertEdges[edges[ei][1]] ~= cast(uint)ei;
            }
            vertFaces = new uint[][](vertices.length);
        }
        edgeFaces = new uint[][](edges.length);
        foreach (fi; 0 .. faces.length) {
            const f = faces[fi];
            if (wantVertexStars)
                foreach (fv; f)
                    if (fv < vertices.length) vertFaces[fv] ~= cast(uint)fi;
            foreach (j; 0 .. f.length) {
                uint ei = edgeIndex(f[j], f[(j + 1) % f.length]);
                if (ei == ~0u) continue;
                if (edgeFaces[ei].length == 0 || edgeFaces[ei][$ - 1] != fi)
                    edgeFaces[ei] ~= cast(uint)fi;
            }
        }
    }

    /// The edge→faces half of `buildLoopIncidence` — all the polygon
    /// select.loop walk consumes.
    private void buildLoopEdgeFaces(out uint[][] edgeFaces) const {
        uint[][] ve, vf;
        buildLoopIncidence(ve, edgeFaces, vf, /*wantVertexStars*/ false);
    }

    /// Return a face from `edgeFaces[ei]` whose winding contains the
    /// directed edge `a`→`b` consecutively, or -1. Used to re-derive the
    /// walking face after a border-chain/trivial hop (the reference
    /// re-picks the face per hop from (edge, side) by winding).
    private int windingFaceFor(const(uint)[] incFaces, uint a, uint b) const {
        foreach (fi; incFaces) {
            const f = faces[fi];
            foreach (j; 0 .. f.length)
                if (f[j] == a && f[(j + 1) % f.length] == b) return cast(int)fi;
        }
        return -1;
    }

    /// Fan walk around pivot `b` starting in `startFace`: each step takes
    /// the spoke to the next (fwd) / previous vert of `b` in the current
    /// face's winding, then crosses to the candidate's other flanking face.
    /// An open fan (no face across) stops early keeping the last candidate.
    /// Returns false (cand = ~0u) when the walk breaks structurally — pivot
    /// missing from the face or no such edge; the reference fails the whole
    /// hop in that case. (The reference picks the cross face by directed
    /// winding — into the pivot when walking forward, out of it backward;
    /// for consistently wound meshes that is simply the other flanking
    /// face.)
    private bool loopFanWalk(uint b, int startFace, bool fwd, uint iters,
                             const(uint[][]) edgeFaces, out uint cand) const {
        cand = ~0u;
        int face = startFace;
        foreach (_; 0 .. iters) {
            const f = faces[face];
            uint x = ~0u;
            foreach (j; 0 .. f.length) {
                if (f[j] != b) continue;
                x = fwd ? f[(j + 1) % f.length]
                        : f[(j + f.length - 1) % f.length];
                break;
            }
            const ce = x == ~0u ? ~0u : edgeIndex(b, x);
            if (ce == ~0u) { cand = ~0u; return false; }
            cand = ce;
            int nf = -1;
            foreach (fi; edgeFaces[ce])
                if (fi != face) { nf = cast(int)fi; break; }
            if (nf < 0) return true; // open fan — keep the last candidate
            face = nf;
        }
        return true;
    }

    /// One direction of the recovered vertex-loop walk: directed current
    /// edge `a0`→`b0` (pivot `b0`). The hop is stateless — everything is
    /// re-derived per step from (directed edge, pivot).
    /// `eMark` is the invocation-shared visited-edge set: a candidate
    /// already marked terminates the walk (this is ring closure; the seed
    /// edge is pre-marked, and marks are shared across both directions and
    /// all seed pairs). Accepted edges are marked and their endpoints added
    /// to `resultV`. `vertEdges`/`edgeFaces` are the full incidence star
    /// (see buildLoopIncidence).
    private void selectLoopVertexWalk(uint a0, uint b0,
                                      bool[] eMark, bool[] resultV,
                                      const(uint[][]) vertEdges,
                                      const(uint[][]) edgeFaces) const {
        uint a = a0, b = b0;
        while (true) {
            uint curE = edgeIndex(a, b);
            if (curE == ~0u) break;
            const nPolys = edgeFaces[curE].length;
            const vcount = cast(uint)vertEdges[b].length;
            // gate: an odd-valence pivot is passable only along a border edge
            if ((vcount & 1) != 0 && nPolys > 1) break;
            // gate: more than two border edges at the pivot is a dead end
            if (vcount > 3) {
                uint nb = 0;
                foreach (ei; vertEdges[b])
                    if (edgeFaces[ei].length <= 1) ++nb;
                if (nb > 2) break;
            }
            if (vcount < 2) break;

            uint cand = ~0u;
            bool angleGate = false;
            if (vcount == 2) {
                // trivial path: the OTHER edge at the pivot
                cand = vertEdges[b][0] != curE ? vertEdges[b][0] : vertEdges[b][1];
            } else {
                if (nPolys <= 1) {
                    // border-chain: the first OTHER border edge at the pivot
                    foreach (ei; vertEdges[b]) {
                        if (ei == curE) continue;
                        if (edgeFaces[ei].length > 1) continue;
                        cand = ei;
                        break;
                    }
                }
                if (cand == ~0u) {
                    // winding faces of the directed current edge: F winds
                    // INTO the pivot (contains a→b), G winds OUT (b→a)
                    const int inF = windingFaceFor(edgeFaces[curE], a, b);
                    const int outG = windingFaceFor(edgeFaces[curE], b, a);
                    if (inF >= 0 && outG >= 0) {
                        // regular fan: the spoke floor(V/2) steps away;
                        // forward from F when G is not larger than F,
                        // backward from G otherwise
                        const bool fwd = faces[outG].length <= faces[inF].length;
                        if (!loopFanWalk(b, fwd ? inF : outG, fwd, vcount / 2,
                                         edgeFaces, cand)) break;
                    } else if (inF >= 0) {
                        // no out-face (border edge / inconsistent winding):
                        // forward fan from F of V-1 steps + the angle gate
                        if (!loopFanWalk(b, inF, true, vcount - 1,
                                         edgeFaces, cand)) break;
                        angleGate = true;
                    } else if (outG >= 0) {
                        // no in-face: a single backward step from G + gate
                        const f = faces[outG];
                        uint x = ~0u;
                        foreach (j; 0 .. f.length) {
                            if (f[j] != b) continue;
                            x = f[(j + f.length - 1) % f.length];
                            break;
                        }
                        cand = x == ~0u ? ~0u : edgeIndex(b, x);
                        if (cand == ~0u) break;
                        angleGate = true;
                    } else break;
                }
            }

            // Angle gate (paths without both winding faces): the
            // candidate must bend away from the incoming direction by more
            // than 90° at the pivot
            if (angleGate) {
                import std.math : acos, PI_2;
                const d0 = edges[cand][0] == b ? edges[cand][1] : edges[cand][0];
                const va = vertices[a] - vertices[b];
                const vc = vertices[d0] - vertices[b];
                const la = va.length, lc = vc.length;
                if (la <= 0 || lc <= 0) break;
                float cosA = dot(va, vc) / (la * lc);
                cosA = cosA < -1 ? -1 : cosA > 1 ? 1 : cosA;
                if (acos(cosA) <= PI_2) break;
            }

            // final validation: closure / revisit stops the walk
            if (eMark[cand]) break;
            eMark[cand] = true;
            const d = edges[cand][0] == b ? edges[cand][1] : edges[cand][0];
            resultV[b] = true;
            resultV[d] = true;
            a = b; b = d;
        }
    }

    /// Recovered `select.loop` (vertex) algorithm — returns the NEW vertex
    /// selection (purge-then-commit semantics: the reference clears the
    /// previous vertex selection unconditionally and commits only the loop
    /// result, so a lone selected vertex clears the selection). See
    //  findings_fv.md (private) for per-rule provenance and validation.
    bool[] selectLoopVertices() const {
        bool[] resultV = new bool[](vertices.length);
        bool[] vMark   = new bool[](vertices.length); // consumed as seed/in a loop
        bool[] eMark   = new bool[](edges.length);    // walked/consumed edges

        // Selected vertices in selection-history order (0/absent order
        // falls back to index order among themselves).
        uint[] selVerts;
        foreach (i; 0 .. vertices.length)
            if (i < vertexMarks.length && (vertexMarks[i] & Marks.Select) != 0)
                selVerts ~= cast(uint)i;
        static int vOrderOf(const int[] ord, size_t i) {
            return (i < ord.length && ord[i] > 0) ? ord[i] : int.max;
        }
        import std.algorithm.sorting : sort;
        selVerts.sort!((x, y) {
            int ox = vOrderOf(vertexSelectionOrder, x), oy = vOrderOf(vertexSelectionOrder, y);
            return ox != oy ? ox < oy : x < y;
        });

        // Full incidence star (reference semantics — complete star,
        // not the truncated half-edge fan walk).
        uint[][] vertEdges, edgeFaces, vertFaces;
        buildLoopIncidence(vertEdges, edgeFaces, vertFaces);

        // Multi-pair seed scan (the reference re-scans from the head after
        // each consumed pair; marks make that monotone). Two devices keep the
        // pass sequence from being O(passes x selected) — which is O(V^2) once
        // the mesh has many small components, one pass each:
        //
        //  * `sCur`, a forward-only cursor over the LEADING run of consumed
        //    vertices. `vMark` is only ever set, never cleared, so a vertex
        //    the scan once skipped for that reason can never seed later.
        //
        //  * `burns`, a memo of the pass prefix past that cursor. A pass that
        //    reaches an already-consumed EDGE drops its `vA` and resumes after
        //    the partner (`vA = vB = ~0u` below) — a "burn". Replaying a
        //    recorded burn is exact while BOTH its endpoints are still
        //    unconsumed: everything the scan skipped between them was either
        //    already `vMark`ed (monotone) or rejected on topology (fixed), and
        //    the blocking edge's `eMark` is monotone too, so the pass would
        //    make the identical decisions again. So the next pass starts right
        //    after the last replayable burn instead of at the head. Marking a
        //    burn endpoint (only the seed pair and the extra-seed block do
        //    that) invalidates that burn and every burn after it, and the scan
        //    falls back to the cursor for the rest — `markVert` records the
        //    earliest such index.
        size_t sCur = 0;
        static struct SeedBurn { uint t, u; size_t uPos; }
        SeedBurn[] burns;
        size_t[] burnOf = new size_t[](vertices.length); // vertex → burn index
        burnOf[] = size_t.max;
        size_t minInvalid = size_t.max;

        void markVert(uint v) {
            vMark[v] = true;
            const b = burnOf[v];
            if (b < minInvalid) minInvalid = b;
        }

        while (true) {
            if (minInvalid < burns.length) {
                foreach (ref b; burns[minInvalid .. $]) {
                    burnOf[b.t] = size_t.max;
                    burnOf[b.u] = size_t.max;
                }
                burns.length = minInvalid;
            }
            minInvalid = size_t.max;

            while (sCur < selVerts.length && vMark[selVerts[sCur]]) ++sCur;
            uint vA = ~0u, vB = ~0u, seedE = ~0u;
            for (size_t k = burns.length ? burns[$ - 1].uPos + 1 : sCur;
                 k < selVerts.length; ++k) {
                version (unittest) ++gSelectLoopSeedScanSteps;
                const v = selVerts[k];
                if (vMark[v]) continue;
                if (vA == ~0u) { vA = v; continue; }
                vB = v;
                bool adj = false;
                foreach (fi; vertFaces[vA]) {
                    const f = faces[fi];
                    foreach (fv; f) if (fv == vB) { adj = true; break; }
                    if (adj) break;
                }
                if (!adj) { vB = ~0u; continue; }
                uint e = edgeIndex(vA, vB);
                if (e == ~0u) { vB = ~0u; continue; }
                if (eMark[e]) {                                // consumed edge: reset pair
                    burnOf[vA] = burnOf[vB] = burns.length;
                    burns ~= SeedBurn(vA, vB, k);
                    vA = ~0u; vB = ~0u; continue;
                }
                seedE = e;
                break;
            }
            if (seedE == ~0u) break;

            markVert(vA); markVert(vB);
            eMark[seedE] = true;
            resultV[vA] = resultV[vB] = true;

            // "Extra seed vertices" block: with >2 vertices selected and an
            // interior (2-face) seed edge, any further selected vertex
            // sitting next to a seed endpoint in one of the seed's faces
            // pulls in that WHOLE face's vertices.
            if (selVerts.length > 2 && edgeFaces[seedE].length == 2) {
                foreach (w; selVerts) {
                    if (w == vA || w == vB || vMark[w]) continue;
                    bool pulled = false;
                    foreach (fi; edgeFaces[seedE]) {
                        const f = faces[fi];
                        foreach (j; 0 .. f.length) {
                            if (f[j] != w) continue;
                            uint pv = f[(j + f.length - 1) % f.length];
                            uint nx = f[(j + 1) % f.length];
                            if (pv == vA || pv == vB || nx == vA || nx == vB) {
                                foreach (fv; f) { markVert(fv); resultV[fv] = true; }
                                pulled = true;
                            }
                            break;
                        }
                        if (pulled) break;
                    }
                }
            }

            // Two-direction walk: one chain per seed endpoint (the reference
            // calls the hop with side=0/1 on the seed edge; every hop then
            // re-derives its winding faces from the directed current edge,
            // so no per-face routing is needed at the seed either).
            selectLoopVertexWalk(edges[seedE][0], edges[seedE][1], eMark, resultV,
                                 vertEdges, edgeFaces);
            selectLoopVertexWalk(edges[seedE][1], edges[seedE][0], eMark, resultV,
                                 vertEdges, edgeFaces);
        }
        return resultV;
    }

    // -----------------------------------------------------------------------
    // select.loop (polygon/face) — recovered-algorithm helper (task 0390)
    // -----------------------------------------------------------------------
    // The bare "select.loop" polygon command reproduces the reference's
    // recovered band algorithm (findings_fv.md, private —
    // rr/gdb live-validated): pure topology, no geometry anywhere.
    //   * seeds are consumed in selection-history order, possibly several
    //     disjoint groups per invocation (multi-group rescan);
    //   * a seed A pairs with the first selected, unvisited, EVEN-sided
    //     polygon sharing a directed (winding-reversed) edge with A; the
    //     band axis is then perpendicular to the shared edge — each seed
    //     exits through the edge nverts/2 away from it. Without a partner,
    //     A walks alone across its own edges 0 and floor(nverts/2), the
    //     axis dictated purely by the polygon's vertex order. A itself may
    //     be odd-sided (only nverts>2 is required of it);
    //   * each hop crosses the current directed exit edge into the polygon
    //     on the other side, provided that polygon is even-sided, not
    //     degenerate (nverts>2), and contains the exit edge's endpoints
    //     consecutively in the reversed winding (covers open boundaries,
    //     T-junctions where the neighbour's edge is subdivided, and
    //     non-manifold gaps); an odd-sided neighbour is SKIPPED (never
    //     entered, never selected); landing on an already-visited polygon
    //     STOPS the walk (ring closure — seeds are pre-marked);
    //   * visited marks are shared across both directions and all groups.
    // The command REPLACES the face selection (purge-then-commit, same as
    // vertex mode). Hidden/locked unmodelled (reserved/unused marks).
    // `walkFaceLoop` stays untouched for its ordered-walk consumers.

    /// Seed-scan step counter for the select.loop seed loops (both modes) —
    /// the gate that keeps those scans linear in the selected-element count.
    /// Unittest-only: the scans are hot and this must not cost a thing in a
    /// release build. Reset it, run the walk, read it; see the scaling
    /// unittest next to `selectLoopVerticesHeadRestart`.
    version (unittest) static size_t gSelectLoopSeedScanSteps;

    /// One band-trace loop: repeatedly cross the directed exit edge
    /// (`vA`→`vB` in the current polygon's winding, i.e. the reversed
    /// winding `vB`,`vA` is what the candidate must contain) into the
    /// even-sided polygon on the far side; stop on boundary, T-junction,
    /// odd-only neighbours, or a visited polygon (closure). Accepted
    /// polygons are marked and added to `resultF`.
    private void selectBandTrace(uint vB0, uint vA0, ubyte[] mark, bool[] resultF,
                                 const(uint[][]) edgeFaces) const {
        uint vB = vB0, vA = vA0;
        while (true) {
            uint ei = edgeIndex(vA, vB);
            if (ei == ~0u) break;
            bool advanced = false, stop = false;
            foreach (q; edgeFaces[ei]) {
                const qf = faces[q];
                immutable m = qf.length;
                if (m <= 2 || (m & 1) != 0) continue;     // degenerate / odd-sided skip
                uint j = ~0u;
                foreach (jj; 0 .. m)
                    if (qf[jj] == vB && qf[(jj + 1) % m] == vA) { j = cast(uint)jj; break; }
                if (j == ~0u) continue;                    // directed-consecutive miss
                if ((mark[q] & 1) != 0) { stop = true; break; } // visited → closure stop
                mark[q] |= 1;
                resultF[q] = true;
                uint nvA = qf[(j + m / 2) % m];
                uint nvB = qf[(j + m / 2 + 1) % m];
                vA = nvA; vB = nvB;
                advanced = true;
                break;
            }
            if (stop || !advanced) break;
        }
    }

    /// The band partner for seed polygon `A`: among the selected, unvisited,
    /// even-sided polygons that contain one of A's edges in the REVERSED
    /// winding, the one that comes first in `partnerRank` order (= selection
    /// order restricted to the static partner filter). Returns -1 when there
    /// is none, else the polygon index with `pi` = the index of A's edge and
    /// `pj` = the partner's matching corner.
    ///
    /// Equivalent to scanning the whole selection in order and taking the
    /// first entry that shares such an edge, but bounded by A's own valence:
    /// only a face incident to one of A's edges can ever match, and a strict
    /// `rank < best` keeps the FIRST (i, j) found for the winner, which is
    /// what the selection-order-outer / A's-edges-inner scan produced. The
    /// `mark & 1` test also covers `q == A` (the caller seeds `mark[A] = 3`
    /// before calling).
    private int findLoopPartner(uint A, const(ubyte[]) mark,
                                const(uint[][]) edgeFaces,
                                const(size_t[]) partnerRank,
                                out size_t pi, out size_t pj) const {
        const af = faces[A];
        immutable n = af.length;
        int P = -1;
        size_t best = size_t.max;
        pi = 0; pj = 0;
        foreach (i; 0 .. n) {
            uint va = af[i], vb = af[(i + 1) % n];
            uint ei = edgeIndex(va, vb);
            if (ei == ~0u) continue;
            foreach (q; edgeFaces[ei]) {
                version (unittest) ++gSelectLoopSeedScanSteps;
                const rank = partnerRank[q];
                if (rank >= best) continue;      // not a candidate, or already beaten
                if ((mark[q] & 1) != 0) continue; // visited (covers q == A)
                const qf = faces[q];
                foreach (j; 0 .. qf.length) {
                    if (qf[j] == vb && qf[(j + 1) % qf.length] == va) {
                        P = cast(int)q; best = rank; pi = i; pj = j;
                        break;
                    }
                }
            }
        }
        return P;
    }

    /// Recovered `select.loop` (polygon) algorithm — returns the NEW face
    /// selection (purge-then-commit semantics). See findings_fv.md
    /// (private) for per-rule provenance and validation.
    bool[] selectLoopFaces() const {
        bool[] resultF = new bool[](faces.length);
        // bit0 = visited (in a band result this invocation, commit filter);
        // bit1 = seeded (consumed as a group seed).
        ubyte[] mark = new ubyte[](faces.length);

        // Selected faces in selection-history order (0/absent order falls
        // back to index order among themselves).
        uint[] selFaces;
        foreach (i; 0 .. faces.length)
            if (i < faceMarks.length && (faceMarks[i] & Marks.Select) != 0)
                selFaces ~= cast(uint)i;
        static int fOrderOf(const int[] ord, size_t i) {
            return (i < ord.length && ord[i] > 0) ? ord[i] : int.max;
        }
        import std.algorithm.sorting : sort;
        selFaces.sort!((x, y) {
            int ox = fOrderOf(faceSelectionOrder, x), oy = fOrderOf(faceSelectionOrder, y);
            return ox != oy ? ox < oy : x < y;
        });

        // Only the edge→faces incidence is read below (the partner scan and
        // every band hop cross an EDGE); the two per-vertex stars used to be
        // built here and never read.
        uint[][] edgeFaces;
        buildLoopEdgeFaces(edgeFaces);

        // Rank of each polygon in the partner-candidate order: the selection
        // order restricted to the STATIC half of the partner filter
        // (even-sided, nverts>2). `size_t.max` = not a candidate. Lifting
        // that filter out of the group loop is what lets the scan below run
        // outward from A's edges instead of over the whole selection.
        size_t[] partnerRank = new size_t[](faces.length);
        partnerRank[] = size_t.max;
        {
            size_t rank = 0;
            foreach (fi; selFaces) {
                immutable L = faces[fi].length;
                if (L <= 2 || (L & 1) != 0) continue;
                partnerRank[fi] = rank++;
            }
        }

        // Multi-group loop: each pass consumes one seed group; visited and
        // seeded marks are shared across groups and make this monotone.
        // `gCur` is a forward-only cursor into `selFaces`: BOTH reasons the
        // scan below skips an entry are permanent — a polygon's vertex count
        // never changes here, and marks are only ever set, never cleared — so
        // an entry the scan once walked past can never become a seed later.
        // Restarting from the head instead made the pass sequence O(groups x
        // selected), and the group count equals the selected count on a
        // triangulated mesh (selectBandTrace skips odd-sided neighbours, so a
        // triangle never advances and is always a group of one).
        size_t gCur = 0;
        while (true) {
            // NEXT_GROUP: first selected, unconsumed polygon with nverts>2.
            int A = -1;
            for (; gCur < selFaces.length; ++gCur) {
                version (unittest) ++gSelectLoopSeedScanSteps;
                const fi = selFaces[gCur];
                if (faces[fi].length <= 2) continue;
                if ((mark[fi] & 3) != 0) continue;
                A = cast(int)fi;
                break;
            }
            if (A < 0) break;
            mark[A] = 3;
            resultF[A] = true;
            const af = faces[A];
            immutable n = af.length;

            // Partner: the selected, unvisited, EVEN-sided polygon sharing a
            // winding-reversed edge with A that comes FIRST in selection
            // order. Only a face incident to one of A's edges can qualify, so
            // this walks A's edges and ranks the hits instead of walking the
            // whole selection per group — same winner, same `pi`/`pj`.
            size_t pi, pj;
            const int P = findLoopPartner(A, mark, edgeFaces, partnerRank, pi, pj);

            uint vB0, vA0, vB1, vA1; // B-side exit, A-side exit
            if (P >= 0) {
                mark[P] |= 1;
                resultF[P] = true;
                const pf = faces[P];
                immutable half  = n / 2, halfP = pf.length / 2;
                vB0 = pf[(pj + halfP + 1) % pf.length]; vA0 = pf[(pj + halfP) % pf.length];
                vB1 = af[(pi + half + 1) % n];          vA1 = af[(pi + half) % n];
                selectBandTrace(vB0, vA0, mark, resultF, edgeFaces); // B-side from P
                selectBandTrace(vB1, vA1, mark, resultF, edgeFaces); // A-side from A
            } else {
                immutable half = n / 2;
                vB0 = af[1];                vA0 = af[0];         // edge 0, reversed
                vB1 = af[(half + 1) % n];   vA1 = af[half % n];  // edge n/2, reversed
                selectBandTrace(vB0, vA0, mark, resultF, edgeFaces);
                selectBandTrace(vB1, vA1, mark, resultF, edgeFaces);
            }
        }
        return resultF;
    }

    // -----------------------------------------------------------------------
    // Head-restart ORACLES for the select.loop seed scans (unittest only)
    // -----------------------------------------------------------------------
    // Frozen copies of the seed-scan shape the two walks above had before the
    // scans were made forward-only: every pass re-scans the selected list from
    // the HEAD, and the polygon partner is found by walking the whole
    // selection in order (outer) against A's edges (inner). They are the
    // oracle the differential unittest directly below measures the fast
    // paths against — the claim being that skipping provably-dead
    // work and ranking the partner candidates from A's edges outward changes
    // only the cost, never the answer.
    //
    // DO NOT "fix" these to track the fast paths. If a future change to
    // select.loop makes the differential test fail, either the fast path
    // diverged (a bug) or the semantics changed deliberately — in which case
    // update BOTH, and the golden capture fixtures with them.
    version (unittest) {
        bool[] selectLoopFacesHeadRestart() const {
            bool[] resultF = new bool[](faces.length);
            ubyte[] mark   = new ubyte[](faces.length);

            uint[] selFaces;
            foreach (i; 0 .. faces.length)
                if (i < faceMarks.length && (faceMarks[i] & Marks.Select) != 0)
                    selFaces ~= cast(uint)i;
            static int fOrderOf(const int[] ord, size_t i) {
                return (i < ord.length && ord[i] > 0) ? ord[i] : int.max;
            }
            import std.algorithm.sorting : sort;
            selFaces.sort!((x, y) {
                int ox = fOrderOf(faceSelectionOrder, x), oy = fOrderOf(faceSelectionOrder, y);
                return ox != oy ? ox < oy : x < y;
            });

            uint[][] vertEdges, edgeFaces, vertFaces;
            buildLoopIncidence(vertEdges, edgeFaces, vertFaces);

            while (true) {
                int A = -1;
                foreach (fi; selFaces) {                  // <- restarts at the head
                    if (faces[fi].length <= 2) continue;
                    if ((mark[fi] & 3) != 0) continue;
                    A = cast(int)fi;
                    break;
                }
                if (A < 0) break;
                mark[A] = 3;
                resultF[A] = true;
                const af = faces[A];
                immutable n = af.length;

                int P = -1;
                size_t pi, pj;
            partnerScan:
                foreach (pfi; selFaces) {                 // <- and so does this
                    if (pfi == A) continue;
                    if ((mark[pfi] & 1) != 0) continue;
                    const pf = faces[pfi];
                    if (pf.length <= 2 || (pf.length & 1) != 0) continue;
                    foreach (i; 0 .. n) {
                        uint va = af[i], vb = af[(i + 1) % n];
                        uint ei = edgeIndex(va, vb);
                        if (ei == ~0u) continue;
                        foreach (q; edgeFaces[ei]) {
                            if (q != pfi) continue;
                            foreach (j; 0 .. pf.length) {
                                if (pf[j] == vb && pf[(j + 1) % pf.length] == va) {
                                    P = cast(int)pfi; pi = i; pj = j;
                                    break partnerScan;
                                }
                            }
                        }
                    }
                }

                uint vB0, vA0, vB1, vA1;
                if (P >= 0) {
                    mark[P] |= 1;
                    resultF[P] = true;
                    const pf = faces[P];
                    immutable half  = n / 2, halfP = pf.length / 2;
                    vB0 = pf[(pj + halfP + 1) % pf.length]; vA0 = pf[(pj + halfP) % pf.length];
                    vB1 = af[(pi + half + 1) % n];          vA1 = af[(pi + half) % n];
                    selectBandTrace(vB0, vA0, mark, resultF, edgeFaces);
                    selectBandTrace(vB1, vA1, mark, resultF, edgeFaces);
                } else {
                    immutable half = n / 2;
                    vB0 = af[1];                vA0 = af[0];
                    vB1 = af[(half + 1) % n];   vA1 = af[half % n];
                    selectBandTrace(vB0, vA0, mark, resultF, edgeFaces);
                    selectBandTrace(vB1, vA1, mark, resultF, edgeFaces);
                }
            }
            return resultF;
        }

        bool[] selectLoopVerticesHeadRestart() const {
            bool[] resultV = new bool[](vertices.length);
            bool[] vMark   = new bool[](vertices.length);
            bool[] eMark   = new bool[](edges.length);

            uint[] selVerts;
            foreach (i; 0 .. vertices.length)
                if (i < vertexMarks.length && (vertexMarks[i] & Marks.Select) != 0)
                    selVerts ~= cast(uint)i;
            static int vOrderOf(const int[] ord, size_t i) {
                return (i < ord.length && ord[i] > 0) ? ord[i] : int.max;
            }
            import std.algorithm.sorting : sort;
            selVerts.sort!((x, y) {
                int ox = vOrderOf(vertexSelectionOrder, x), oy = vOrderOf(vertexSelectionOrder, y);
                return ox != oy ? ox < oy : x < y;
            });

            uint[][] vertEdges, edgeFaces, vertFaces;
            buildLoopIncidence(vertEdges, edgeFaces, vertFaces);

            while (true) {
                uint vA = ~0u, vB = ~0u, seedE = ~0u;
                foreach (v; selVerts) {                   // <- restarts at the head
                    if (vMark[v]) continue;
                    if (vA == ~0u) { vA = v; continue; }
                    vB = v;
                    bool adj = false;
                    foreach (fi; vertFaces[vA]) {
                        const f = faces[fi];
                        foreach (fv; f) if (fv == vB) { adj = true; break; }
                        if (adj) break;
                    }
                    if (!adj) { vB = ~0u; continue; }
                    uint e = edgeIndex(vA, vB);
                    if (e == ~0u) { vB = ~0u; continue; }
                    if (eMark[e]) { vA = ~0u; vB = ~0u; continue; }
                    seedE = e;
                    break;
                }
                if (seedE == ~0u) break;

                vMark[vA] = vMark[vB] = true;
                eMark[seedE] = true;
                resultV[vA] = resultV[vB] = true;

                if (selVerts.length > 2 && edgeFaces[seedE].length == 2) {
                    foreach (w; selVerts) {
                        if (w == vA || w == vB || vMark[w]) continue;
                        bool pulled = false;
                        foreach (fi; edgeFaces[seedE]) {
                            const f = faces[fi];
                            foreach (j; 0 .. f.length) {
                                if (f[j] != w) continue;
                                uint pv = f[(j + f.length - 1) % f.length];
                                uint nx = f[(j + 1) % f.length];
                                if (pv == vA || pv == vB || nx == vA || nx == vB) {
                                    foreach (fv; f) { vMark[fv] = true; resultV[fv] = true; }
                                    pulled = true;
                                }
                                break;
                            }
                            if (pulled) break;
                        }
                    }
                }

                selectLoopVertexWalk(edges[seedE][0], edges[seedE][1], eMark, resultV,
                                     vertEdges, edgeFaces);
                selectLoopVertexWalk(edges[seedE][1], edges[seedE][0], eMark, resultV,
                                     vertEdges, edgeFaces);
            }
            return resultV;
        }
    }
}
