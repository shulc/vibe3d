module mesh_ops.bridge;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshBridgeOps — Bridge kernel family (bridgeLoopsPaired / bridgeLoops /
// bridgeLoopsSpans / bridgeStripPaired / bridgeOpenRows, plus the private
// pairing/twist/fan helpers they alone use: pairBridgeLoop, bridgeTwistedVertex,
// orientOpenChainB, bridgeFanRows, ceilDivHalfDown), mixed into struct Mesh
// (source/mesh.d) via `mixin MeshBridgeOps;`. Split out of mesh.d as part of
// the mesh.d decomposition campaign (0407 §B.V2, task 0417 — continuation of
// the task-0412 plane-cut pilot; see that task's doc for the architectural
// decision: mixin template over a package move or UFCS free-functions).
// Method bodies below are verbatim cut/paste from mesh.d (only the extraction
// boundary is new).
// ---------------------------------------------------------------------------
mixin template MeshBridgeOps() {
    /// Emit N quads [A[i], A[(i+1)%N], B[(i+1)%N], B[i]] where B is already
    /// paired 1:1 with A (no heuristic — exact correspondence assumed).
    /// Returns N on success, 0 if lengths differ or loop is too short.
    /// Does NOT call buildLoops — the caller must do so after all mutations.
    ///
    /// Task 0389: each bridge quad inherits Subpatch via OR from the
    /// PRE-EXISTING adjacent face(s) of its two bridged edges (A[i]-A[i+1]
    /// and pairedB[i]-pairedB[i+1]), looked up BEFORE any of this call's own
    /// `addFace`s run. A boundary-loop edge (the common case — bridging two
    /// open holes) has exactly one adjacent face; a freshly interpolated
    /// edge (bridgeLoopsSpans' interior twist rings, which reference brand
    /// new verts with no pre-existing edge at all) has none in a standalone
    /// call, so it contributes `false`. NOTE: bridgeLoopsSpans calls this once
    /// per span and each call rebuilds buildEdgeFaces(), so a later span's
    /// edges can see an earlier span's just-added bridge quads as adjacent and
    /// inherit transitively — a subdiv boundary therefore yields an all-subdiv
    /// multi-span bridge, which is the intended behavior.
    size_t bridgeLoopsPaired(const(uint)[] loopA, const(uint)[] pairedB) {
        if (loopA.length != pairedB.length || loopA.length < 3) return 0;
        const N = loopA.length;
        auto edgeFaces = buildEdgeFaces();
        bool edgeAdjSubpatch(uint va, uint vb) {
            auto p = edgeKey(va, vb) in edgeFaces;
            if (p is null) return false;
            return ((*p)[0] >= 0 && isFaceSubpatch((*p)[0]))
                || ((*p)[1] >= 0 && isFaceSubpatch((*p)[1]));
        }
        foreach (i; 0 .. N) {
            uint a0 = cast(uint)loopA[i],    a1 = cast(uint)loopA[(i + 1) % N];
            uint b0 = cast(uint)pairedB[i],  b1 = cast(uint)pairedB[(i + 1) % N];
            bool sub = edgeAdjSubpatch(a0, a1) || edgeAdjSubpatch(b0, b1);
            uint newFi = cast(uint)faces.length;
            addFace([a0, a1, b1, b0]);
            resizeSubpatch();
            setFaceSubpatch(newFi, sub);
        }
        return N;
    }

    /// Shared pairing step (factored out of `bridgeLoops`, task 0357 — also
    /// used by `bridgeLoopsSpans`): anchor B at the vertex nearest A[0];
    /// pick forward vs. reversed direction by minimum total paired
    /// Euclidean distance; `flip` overrides the auto choice. Returns the
    /// pairing array P (P[i] is the loopB vertex paired with loopA[i]).
    private uint[] pairBridgeLoop(const(uint)[] loopA, const(uint)[] loopB, bool flip) const {
        const size_t N = loopA.length;

        // Step 1 — anchor: B-vertex nearest A[0].
        Vec3   pa0    = vertices[loopA[0]];
        size_t k      = 0;
        float  bestSq = float.max;
        foreach (i; 0 .. N) {
            Vec3  d  = vertices[loopB[i]] - pa0;
            float sq = d.x*d.x + d.y*d.y + d.z*d.z;
            if (sq < bestSq) { bestSq = sq; k = i; }
        }

        // Step 2 — pick direction by minimum total paired distance.
        float fwdSum = 0.0f, revSum = 0.0f;
        foreach (i; 0 .. N) {
            Vec3 ai   = vertices[loopA[i]];
            Vec3 bFwd = vertices[loopB[(k + i)     % N]];
            Vec3 bRev = vertices[loopB[(k + N - i) % N]];
            fwdSum += (bFwd - ai).length;
            revSum += (bRev - ai).length;
        }
        immutable bool useForward = (fwdSum <= revSum) != flip;

        // Step 3 — build pairing array P[0..N).
        uint[] P = new uint[](N);
        foreach (i; 0 .. N)
            P[i] = useForward ? cast(uint)loopB[(k + i)     % N]
                              : cast(uint)loopB[(k + N - i) % N];
        return P;
    }

    /// Stitch two equal-length closed vertex loops into a ring of N quad faces.
    /// Returns N (faces added) on success, 0 if loops are unequal or too short.
    ///
    /// Pairing rule: anchor B at the vertex nearest A[0]; pick forward vs.
    /// reversed direction by minimum total paired Euclidean distance; `flip`
    /// overrides the auto choice.  Quads wound [A[i], A[(i+1)%N], P[(i+1)%N], P[i]].
    ///
    /// Does NOT call buildLoops() — the caller must do so after all mutations.
    ///
    /// No empty-selection fallback: bridge requires exactly two loops.
    /// Do NOT add a whole-mesh fallback here.
    size_t bridgeLoops(const(uint)[] loopA, const(uint)[] loopB, bool flip = false) {
        if (loopA.length != loopB.length || loopA.length < 3) return 0;
        uint[] P = pairBridgeLoop(loopA, loopB, flip);
        return bridgeLoopsPaired(loopA, P);
    }

    /// Face indices whose vertex ring is a cyclic rotation (either winding
    /// direction) of `loop` — i.e. the existing polygon(s) EXACTLY bounded by
    /// `loop`. This is the "cap" lookup a bridge uses to decide which faces
    /// become interior (and must be removed) once the two loops are stitched:
    /// captured reference behaviour (task 0467) is to delete precisely the
    /// polygons whose full ring equals a bridged loop — a loop that bounds no
    /// single face (an open hole, or a rim shared piecewise by several faces)
    /// removes nothing. Empty result is the common, safe no-op.
    ///
    /// O(faces * loop-length^2); fine for edit-sized meshes. Single source of
    /// truth — `tools/edit/bridge_tool.d`'s `facesMatchingLoop` delegates here.
    uint[] facesBoundedByLoop(const(uint)[] loop) const {
        uint[] hits;
        const size_t N = loop.length;
        outer: foreach (fi; 0 .. faces.length) {
            auto fv = faces[fi];
            if (fv.length != N) continue;
            foreach (start; 0 .. N) {
                bool fwd = true, rev = true;
                foreach (i; 0 .. N) {
                    if (fwd && fv[i] != loop[(start + i) % N]) fwd = false;
                    if (rev && fv[i] != loop[(start + N - i) % N]) rev = false;
                    if (!fwd && !rev) break;
                }
                if (fwd || rev) { hits ~= cast(uint)fi; continue outer; }
            }
        }
        return hits;
    }

    /// Hard internal cap on interior rings a single `bridgeLoopsSpans` call
    /// may generate — defense-in-depth against a DoS via a huge Segments
    /// value reaching this kernel through any path other than the
    /// interactive tool's own `.enforceBounds()`-clamped Param (see
    /// params.d's DoS note; task 0357 review convention).
    enum size_t maxBridgeSpans = 512;

    /// Multi-span, twisted bridge (task 0357) — generalizes `bridgeLoops`
    /// with `spans-1` interior vertex rings, linearly interpolated at
    /// t=i/spans (i=1..spans-1) between the two boundary loops, with an
    /// optional per-ring `twist` (see `bridgeTwistedVertex`).
    ///
    /// `spans<=1` degenerates EXACTLY to `bridgeLoops` (same pairing, no
    /// new verts) — the existing `mesh.bridge` command's behaviour is
    /// preserved byte-for-byte through this path.
    ///
    /// Returns the number of faces added (0 on rejection — mismatched loop
    /// lengths or too-short loops, same guard as `bridgeLoops`). Does NOT
    /// call buildLoops() — the caller must do so after all mutations.
    size_t bridgeLoopsSpans(const(uint)[] loopA, const(uint)[] loopB, bool flip,
                            uint spans, float twist) {
        if (loopA.length != loopB.length || loopA.length < 3) return 0;
        if (spans < 1) spans = 1;
        if (spans > maxBridgeSpans) spans = cast(uint)maxBridgeSpans;   // kernel-side DoS cap

        uint[] P = pairBridgeLoop(loopA, loopB, flip);
        if (spans == 1) return bridgeLoopsPaired(loopA, P);

        const size_t N = loopA.length;
        uint[][] rings = new uint[][](spans + 1);
        rings[0]     = loopA.dup;
        rings[spans] = P.dup;
        foreach (i; 1 .. spans) {
            float t = cast(float)i / cast(float)spans;
            uint[] ring = new uint[](N);
            foreach (k; 0 .. N)
                ring[k] = addVertex(bridgeTwistedVertex(loopA, P, k, t, twist));
            rings[i] = ring;
        }

        size_t added = 0;
        foreach (s; 0 .. spans)
            added += bridgeLoopsPaired(rings[s], rings[s + 1]);
        return added;
    }

    /// Bridge Twist (task 0357) — per-ring corner-slide law.
    ///
    /// VERIFIED EXACT for `twist` in {-1, 0, 1} at every interior ring
    /// t=i/spans (dense reference re-capture, two independent loop shapes —
    /// octagon/spans=12 and 12-gon/spans=7 — max error ~3e-8; see task
    /// 0357's Лог for the capture provenance): the vertex is a continuous
    /// slide from its own
    /// untwisted position `base_k(t)` toward the ADJACENT ring corner
    /// (`base_{k+1}(t)` for twist>0, `base_{k-1}(t)` for twist<0) by a
    /// fraction `f(t) = smoothstep(t) = 3t²-2t³`, reaching the adjacent
    /// corner exactly at t=1 — never actually reached by an interior ring,
    /// since interior t is always strictly in (0,1); the two boundary
    /// loops (t=0, t=1) are never touched by twist, matching the reference
    /// exactly.
    ///
    /// APPROXIMATION for fractional twist (non-integer) or |twist|>1
    /// (multi-wrap): the SAME dense re-capture proved this formula's naive
    /// extension — walk s(t)=twist*smoothstep(t) as a (possibly
    /// multi-corner) distance, split into an integer corner-step `n` and a
    /// fractional remainder `f` — does NOT match the reference numerically
    /// in this regime (measured error up to ~1.7 at extreme multi-wrap).
    /// The true reference law appears to be a quantized per-ring corner
    /// re-index rather than a continuous slide, but the exact re-index
    /// rule was NOT solved from the available samples (open item, see
    /// task 0357's Лог). This function still extends the verified formula
    /// this way — rather than snapping to the nearest corner — because it
    /// degrades continuously (no popping) and is exact by construction at
    /// every verified twist value. Any output outside `twist` in {-1,0,1}
    /// is therefore a DOCUMENTED APPROXIMATION, not reference parity —
    /// do not treat it as a verified law pending an exact fit.
    private Vec3 bridgeTwistedVertex(const(uint)[] loopA, const(uint)[] pairedB,
                                     size_t k, float t, float twist) const {
        const size_t N = loopA.length;
        Vec3 base(long idx) {
            long m = idx % cast(long)N;
            if (m < 0) m += cast(long)N;
            return vec3Lerp(vertices[loopA[cast(size_t)m]], vertices[pairedB[cast(size_t)m]], t);
        }
        if (twist == 0.0f) return base(cast(long)k);

        int   sign = (twist > 0.0f) ? 1 : -1;
        float mag  = (twist > 0.0f) ? twist : -twist;
        float s    = mag * smoothstep01(t);
        long  n    = cast(long)s;             // floor (s is always >= 0)
        float f    = s - cast(float)n;

        Vec3 p0 = base(cast(long)k + cast(long)sign * n);
        Vec3 p1 = base(cast(long)k + cast(long)sign * (n + 1));
        return vec3Lerp(p0, p1, f);
    }

    // ------------------------------------------------------------------
    // Bridge, OPEN rows (task 0395) — Bridge's edge-mode generalization
    // from "exactly 2 closed cycles" to also accept 2 OPEN edge chains.
    // Open analog of pairBridgeLoop / bridgeLoopsPaired / bridgeLoopsSpans
    // above: no wraparound (an open row has no closing edge between its
    // two ends), and pairing is by nearest-ENDPOINT proximity rather than
    // nearest-vertex-then-rotate (a row has only two candidate endpoints
    // to test, not N candidate rotations).
    // ------------------------------------------------------------------

    /// Open-row analog of `pairBridgeLoop`'s auto-orient step: decide
    /// whether chain `b` should be walked forward or reversed to align
    /// with chain `a`, by comparing the summed endpoint-to-endpoint
    /// distance of the two possible alignments — `straight` (a's start
    /// near b's start, a's end near b's end) vs. `crossed` (a's start near
    /// b's end, a's end near b's start). `flip` inverts the auto choice
    /// (mirrors bridgeLoops' own `flip` semantics). `a` is never
    /// reordered — only `b` is potentially reversed, matching
    /// pairBridgeLoop's convention of treating loop/chain A as the anchor.
    ///
    /// Task 0395 decisive capture (`pairing_proximity_not_selection_order`
    /// fixture case): pairing is by geometric proximity of the chain
    /// ENDPOINTS, not by which order the two chains were built/selected in
    /// — this is the auto-detection that makes that guarantee hold, since
    /// it only ever looks at `a`/`b`'s actual endpoint positions.
    private uint[] orientOpenChainB(const(uint)[] a, const(uint)[] b, bool flip) const {
        Vec3 a0 = vertices[a[0]], a1 = vertices[a[$ - 1]];
        Vec3 b0 = vertices[b[0]], b1 = vertices[b[$ - 1]];
        float straight = (b0 - a0).length + (b1 - a1).length;
        float crossed  = (b1 - a0).length + (b0 - a1).length;
        immutable bool reverse = (crossed < straight) != flip;
        if (!reverse) return b.dup;
        uint[] r = new uint[](b.length);
        foreach (i; 0 .. b.length) r[i] = b[$ - 1 - i];
        return r;
    }

    /// Open-row twin of `bridgeLoopsPaired`: emit `a.length-1` quads
    /// [a[i], a[i+1], b[i+1], b[i]] for a chain PRE-PAIRED 1:1 with `b`
    /// (NO wraparound — unlike a closed loop, an open row has no edge
    /// connecting its last vertex back to its first). Guards
    /// `a.length == b.length && a.length >= 2`.
    ///
    /// Task 0389 subpatch inheritance carries over identically to
    /// `bridgeLoopsPaired`: each new quad inherits Subpatch via OR from the
    /// pre-existing adjacent face(s) of its two bridged edges, looked up
    /// BEFORE this call's own `addFace`s run.
    ///
    /// Task 0395 rr-refinement: each new quad's winding is auto-oriented to
    /// be consistent with any PRE-EXISTING adjacent face, via the same
    /// `orientFaceConsistent` invariant `makePolygonFromVerts` uses (task
    /// 0394) — not a fixed `[a0,a1,b1,b0]` convention. On a fully
    /// disconnected island (no pre-existing neighbor on either bridged
    /// edge) that vote is a 0-0 tie, so `[a0,a1,b1,b0]` is exactly what
    /// comes out — the fixed convention survives as the disconnected
    /// fallback.
    ///
    /// Does NOT call buildLoops() — the caller must do so after all
    /// mutations.
    size_t bridgeStripPaired(const(uint)[] a, const(uint)[] b) {
        if (a.length != b.length || a.length < 2) return 0;
        const N = a.length;
        auto edgeFaces = buildEdgeFaces();     // pre-existing snapshot — subpatch source ONLY, untouched
        auto liveEdgeFaces = edgeFaces.dup;    // grows with THIS strip's own faces — winding source
        bool edgeAdjSubpatch(uint va, uint vb) {
            auto p = edgeKey(va, vb) in edgeFaces;
            if (p is null) return false;
            return ((*p)[0] >= 0 && isFaceSubpatch((*p)[0]))
                || ((*p)[1] >= 0 && isFaceSubpatch((*p)[1]));
        }
        foreach (i; 0 .. N - 1) {
            uint a0 = cast(uint)a[i],   a1 = cast(uint)a[i + 1];
            uint b0 = cast(uint)b[i],   b1 = cast(uint)b[i + 1];
            bool sub = edgeAdjSubpatch(a0, a1) || edgeAdjSubpatch(b0, b1);
            uint[] idx = [a0, a1, b1, b0];
            orientFaceConsistent(idx, liveEdgeFaces);
            uint newFi = cast(uint)faces.length;
            addFace(idx);
            registerNewFaceEdges(liveEdgeFaces, newFi, idx);
            resizeSubpatch();
            setFaceSubpatch(newFi, sub);
        }
        return N - 1;
    }

    /// Exact integer ceiling-division, ROUND-HALF-DOWN at the .5 boundary:
    /// `ceilDivHalfDown(p, q) == ceil(p/q as real)` for `q > 0`, computed
    /// without floats so there is no rounding risk near a `.5` boundary
    /// (`bridgeFanRows`'s DDA below evaluates `ceil(i*M/N - 0.5)`, which is
    /// exactly `ceilDivHalfDown(2*i*M - N, 2*N)`). D's built-in `/` on
    /// integers truncates toward zero rather than flooring, which is wrong
    /// for a negative numerator — this handles that case explicitly.
    private static long ceilDivHalfDown(long p, long q) pure nothrow @nogc @safe
    in (q > 0) {
        return (p >= 0) ? (p + q - 1) / q : -((-p) / q);
    }

    /// Fan/triangulate two UNEQUAL-length open rows (task 0395 phase 2).
    /// Reference-editor rr-capture (static disassembly of the builder,
    /// bit-exact on 3:1, 4:2, 5:2, 5:3, 6:3): for long chain edges
    /// `i = 0..N-1` (`N = longC.length-1`) against short chain `M =
    /// shortC.length-1` edges, define the DDA index
    /// `r(i) = ceil(i*M/N - 0.5)` (ROUND-HALF-DOWN) for `i = 0..N`. Segment
    /// `i` (edge `longC[i]-longC[i+1]`) becomes a QUAD against
    /// `shortC[r(i)]-shortC[r(i)+1]` whenever `r(i+1) > r(i)` (the DDA just
    /// stepped onto a new short edge), otherwise a TRIANGLE apexed at
    /// `shortC[r(i)]`. This always emits exactly `N` new faces (`M` quads +
    /// `N-M` triangles) — the captured 3:1 case (`tri[a0,a1,b0],
    /// quad[a1,a2,b1,b0], tri[a2,a3,b1]`) is this formula's `N=3,M=1`
    /// instance, not a special case.
    ///
    /// `longC`/`shortC` must already be oriented so `longC[0]`↔`shortC[0]`
    /// and `longC[$-1]`↔`shortC[$-1]` are the correct endpoint pairing
    /// (`orientOpenChainB`'s job, done by the caller) — this function does
    /// not re-derive direction.
    ///
    /// Winding: each new face is auto-oriented via `orientFaceConsistent`
    /// (task 0395 rr-refinement, same invariant as `bridgeStripPaired`/
    /// `makePolygonFromVerts`) rather than a fixed convention; the
    /// `[a[i],a[i+1],b[r+1],b[r]]` / `[a[i],a[i+1],b[r]]` orders below are
    /// exactly what survives on a disconnected island (0-0 vote tie).
    ///
    /// Requires `N > M >= 1` (i.e. genuinely unequal, both chains have at
    /// least one edge); returns 0 otherwise. Subpatch inheritance mirrors
    /// `bridgeStripPaired` (OR of the pre-existing adjacent face(s) of each
    /// new face's real mesh edge(s)). Does NOT call buildLoops().
    private size_t bridgeFanRows(const(uint)[] longC, const(uint)[] shortC) {
        if (longC.length < 2 || shortC.length < 2) return 0;
        const long N = cast(long)longC.length - 1;
        const long M = cast(long)shortC.length - 1;
        if (M < 1 || N <= M) return 0;

        // r(i) = ceil(i*M/N - 0.5) = ceilDivHalfDown(2*i*M - N, 2*N), i = 0..N.
        long[] r = new long[](N + 1);
        foreach (i; 0 .. N + 1)
            r[i] = ceilDivHalfDown(2 * i * M - N, 2 * N);

        auto edgeFaces = buildEdgeFaces();     // pre-existing snapshot — subpatch source ONLY, untouched
        auto liveEdgeFaces = edgeFaces.dup;    // grows with THIS fan's own faces — winding source
        bool edgeAdjSubpatch(uint va, uint vb) {
            auto p = edgeKey(va, vb) in edgeFaces;
            if (p is null) return false;
            return ((*p)[0] >= 0 && isFaceSubpatch((*p)[0]))
                || ((*p)[1] >= 0 && isFaceSubpatch((*p)[1]));
        }

        size_t added = 0;
        foreach (i; 0 .. N) {
            uint a0 = cast(uint)longC[i], a1 = cast(uint)longC[i + 1];
            size_t ri  = cast(size_t)r[i];
            size_t ri1 = cast(size_t)r[i + 1];
            bool sub;
            uint[] idx;
            if (ri1 > ri) {
                uint b0 = cast(uint)shortC[ri], b1 = cast(uint)shortC[ri + 1];
                sub = edgeAdjSubpatch(a0, a1) || edgeAdjSubpatch(b0, b1);
                idx = [a0, a1, b1, b0];
            } else {
                sub = edgeAdjSubpatch(a0, a1);
                idx = [a0, a1, cast(uint)shortC[ri]];
            }
            orientFaceConsistent(idx, liveEdgeFaces);
            uint newFi = cast(uint)faces.length;
            addFace(idx);
            registerNewFaceEdges(liveEdgeFaces, newFi, idx);
            resizeSubpatch();
            setFaceSubpatch(newFi, sub);
            ++added;
        }
        return added;
    }

    /// Multi-span open-row Bridge (task 0395) — the edge-mode-open-row
    /// analog of `bridgeLoopsSpans`. Equal-length chains: `spans-1`
    /// interior rings, linearly interpolated at t=i/spans (i=1..spans-1),
    /// same Segments law as the closed-loop kernel — verified bit-exact by
    /// the `two_open_rows_segments2` / `pairing_proximity_not_selection_order`
    /// fixture cases. Unequal-length chains: dispatches to `bridgeFanRows`
    /// (task 0395 phase 2); `spans`/`twist` are IGNORED in that case — a
    /// fan has no single interior-ring interpolation law across a triangle,
    /// and the captured reference shows Segments has no effect on unequal
    /// rows in the verified 3:1 case.
    ///
    /// Pairing is by nearest-ENDPOINT proximity (`orientOpenChainB`), NOT
    /// chain-walk/selection order.
    ///
    /// Interior rings on EQUAL-length rows do NOT wrap (open chains have no
    /// closing edge) — `twist` is accepted for signature symmetry with
    /// `bridgeLoopsSpans` but IGNORED for open rows in this version
    /// (documented v1 limitation, task 0395 plan: "twist on open rows").
    ///
    /// `spans<1` clamps to 1; `spans>maxBridgeSpans` clamps to the cap
    /// (same kernel-side DoS guard as `bridgeLoopsSpans`) — only meaningful
    /// on the equal-length path.
    ///
    /// Returns faces added (0 on rejection: either chain has <2 verts).
    /// Does NOT call buildLoops() — caller's responsibility.
    size_t bridgeOpenRows(const(uint)[] chainA, const(uint)[] chainB, bool flip,
                          uint spans, float twist) {
        if (chainA.length < 2 || chainB.length < 2) return 0;

        uint[] B = orientOpenChainB(chainA, chainB, flip);

        if (chainA.length != B.length) {
            immutable bool aLonger = chainA.length > B.length;
            return bridgeFanRows(aLonger ? chainA : B, aLonger ? B : chainA);
        }

        if (spans < 1) spans = 1;
        if (spans > maxBridgeSpans) spans = cast(uint)maxBridgeSpans;
        if (spans == 1) return bridgeStripPaired(chainA, B);

        const size_t N = chainA.length;
        uint[][] rings = new uint[][](spans + 1);
        rings[0]     = chainA.dup;
        rings[spans] = B.dup;
        foreach (i; 1 .. spans) {
            float t = cast(float)i / cast(float)spans;
            uint[] ring = new uint[](N);
            foreach (k; 0 .. N)
                ring[k] = addVertex(vec3Lerp(vertices[chainA[k]], vertices[B[k]], t));
            rings[i] = ring;
        }

        size_t added = 0;
        foreach (s; 0 .. spans)
            added += bridgeStripPaired(rings[s], rings[s + 1]);
        return added;
    }
}
