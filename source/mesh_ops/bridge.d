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
            auto p = edgeKeyOrdered(va, vb) in edgeFaces;
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
            auto p = edgeKeyOrdered(va, vb) in edgeFaces;
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
            auto p = edgeKeyOrdered(va, vb) in edgeFaces;
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

// ---------------------------------------------------------------------------
// Unit tests -- co-located with the family they exercise (moved verbatim
// from mesh.d alongside the kernels above).
// ---------------------------------------------------------------------------
unittest { // bridgeLoops: two parallel square rings → 4 quads, no new verts
    // Two coaxial unit squares: A at z=0, B at z=1, both CCW.
    // A: 0(0,0,0), 1(1,0,0), 2(1,1,0), 3(0,1,0)
    // B: 4(0,0,1), 5(1,0,1), 6(1,1,1), 7(0,1,1)
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));
    assert(m.vertices.length == 8);
    assert(m.faces.length == 0);

    size_t added = m.bridgeLoops([0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(added == 4, "expected 4 quads");
    assert(m.faces.length == 4, "face count");
    assert(m.vertices.length == 8, "no new verts");

    // All faces must be quads.
    foreach (f; m.faces) assert(f.length == 4, "all quads");

    // Every new face's vertices are within the original 8.
    foreach (f; m.faces)
        foreach (vi; f) assert(vi < 8, "vertex index in range");
}

unittest { // bridgeLoops: mismatch rejection + too-short rejection
    Mesh m;
    foreach (i; 0 .. 8) m.addVertex(Vec3(cast(float)i, 0, 0));

    // Unequal lengths → 0 faces added.
    size_t r1 = m.bridgeLoops([0u,1u,2u,3u], [4u,5u,6u]);
    assert(r1 == 0, "unequal length must be rejected");
    assert(m.faces.length == 0, "no faces added on mismatch");

    // Length 2 → too short → 0.
    size_t r2 = m.bridgeLoops([0u,1u], [4u,5u]);
    assert(r2 == 0, "length<3 must be rejected");
}

unittest { // bridgeLoopsSpans: spans=1 degenerates EXACTLY to bridgeLoops
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t added = m.bridgeLoopsSpans([0u,1u,2u,3u], [4u,5u,6u,7u], false, 1, 0.0f);
    assert(added == 4, "spans=1: expected 4 quads");
    assert(m.faces.length == 4, "spans=1: face count");
    assert(m.vertices.length == 8, "spans=1: no new verts");
    foreach (f; m.faces) assert(f.length == 4, "spans=1: all quads");
}

unittest { // bridgeLoopsSpans: segments law (twist=0) — closed-form, exact
    // Same two-coaxial-unit-squares fixture as bridgeLoops' own test.
    // Task 0357 Segments law: spans=3 -> 2 interior rings at t=1/3, 2/3,
    // linearly interpolated between the paired loop corners (identity
    // pairing here, verified by the bridgeLoops test just above using the
    // SAME fixture). Golden numbers hand-derived from that closed form,
    // not borrowed from any external capture.
    import std.math : abs;
    import std.format : format;
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t added = m.bridgeLoopsSpans([0u,1u,2u,3u], [4u,5u,6u,7u], false, 3, 0.0f);
    assert(added == 12, format("spans=3: expected 12 quads (3 spans * 4), got %d", added));
    assert(m.faces.length == 12, "spans=3: face count");
    assert(m.vertices.length == 16, "spans=3: 8 orig + 8 new (2 rings * 4)");
    foreach (f; m.faces) assert(f.length == 4, "spans=3: all quads");

    // New verts are indices 8..15: ring1 (t=1/3) then ring2 (t=2/3), each
    // in loop-corner order [corner0..corner3] matching loopA/loopB's own
    // vertex order (0,1,2,3 / 4,5,6,7).
    static immutable Vec3[8] expected = [
        Vec3(0.0f, 0.0f, 1.0f/3.0f), Vec3(1.0f, 0.0f, 1.0f/3.0f),
        Vec3(1.0f, 1.0f, 1.0f/3.0f), Vec3(0.0f, 1.0f, 1.0f/3.0f),
        Vec3(0.0f, 0.0f, 2.0f/3.0f), Vec3(1.0f, 0.0f, 2.0f/3.0f),
        Vec3(1.0f, 1.0f, 2.0f/3.0f), Vec3(0.0f, 1.0f, 2.0f/3.0f),
    ];
    foreach (i, e; expected) {
        Vec3 got = m.vertices[8 + i];
        assert(abs(got.x - e.x) < 1e-5f && abs(got.y - e.y) < 1e-5f && abs(got.z - e.z) < 1e-5f,
            format("spans=3 vert %d: expected (%.6f,%.6f,%.6f), got (%.6f,%.6f,%.6f)",
                   8+i, e.x, e.y, e.z, got.x, got.y, got.z));
    }
}

unittest { // bridgeLoopsSpans: twist law, |twist|=1 — VERIFIED EXACT regime
    // Task 0357's dense reference re-capture: twist in {-1,0,1} is exact at
    // every interior ring (two independent loop shapes, max err ~3e-8).
    // Golden numbers here are computed from the SAME verified closed form
    // (f(t) = smoothstep(t) = 3t^2-2t^3, slide toward the next corner) on
    // the two-coaxial-unit-squares fixture — cross-checked by hand against
    // the reference capture's own f(1/3)=7/27, f(2/3)=20/27 values (private
    // doc) before being reproduced here.
    import std.math : abs;
    import std.format : format;
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t added = m.bridgeLoopsSpans([0u,1u,2u,3u], [4u,5u,6u,7u], false, 3, 1.0f);
    assert(added == 12, "twist=1: expected 12 quads");
    assert(m.vertices.length == 16, "twist=1: 8 orig + 8 new");

    enum float f1 = 7.0f/27.0f;   // smoothstep(1/3)
    enum float f2 = 20.0f/27.0f;  // smoothstep(2/3)
    static immutable Vec3[8] expected = [
        // Ring 1 (t=1/3): slide toward the NEXT corner (k+1) by f1.
        Vec3(f1, 0.0f, 1.0f/3.0f), Vec3(1.0f, f1, 1.0f/3.0f),
        Vec3(1.0f - f1, 1.0f, 1.0f/3.0f), Vec3(0.0f, 1.0f - f1, 1.0f/3.0f),
        // Ring 2 (t=2/3): slide by f2.
        Vec3(f2, 0.0f, 2.0f/3.0f), Vec3(1.0f, f2, 2.0f/3.0f),
        Vec3(1.0f - f2, 1.0f, 2.0f/3.0f), Vec3(0.0f, 1.0f - f2, 2.0f/3.0f),
    ];
    foreach (i, e; expected) {
        Vec3 got = m.vertices[8 + i];
        assert(abs(got.x - e.x) < 1e-5f && abs(got.y - e.y) < 1e-5f && abs(got.z - e.z) < 1e-5f,
            format("twist=1 vert %d: expected (%.6f,%.6f,%.6f), got (%.6f,%.6f,%.6f)",
                   8+i, e.x, e.y, e.z, got.x, got.y, got.z));
    }
}

unittest { // bridgeLoopsSpans: DoS defense — huge spans clamps to maxBridgeSpans
    import std.format : format;
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t added = m.bridgeLoopsSpans([0u,1u,2u,3u], [4u,5u,6u,7u], false,
                                      100_000_000u, 0.0f);
    assert(added == Mesh.maxBridgeSpans * 4,
        format("huge spans must clamp to maxBridgeSpans, got %d (expected %d)",
               added, Mesh.maxBridgeSpans * 4));
    assert(m.faces.length == Mesh.maxBridgeSpans * 4, "clamped face count");
}

unittest { // bridgeOpenRows: equal-length spans=1 strip, spans=2 midpoint
           // ring, and proximity-based orientation (not chain-walk order)
    import std.conv : to;
    import std.math : abs;

    // (1) spans=1: two disjoint 3-vertex rows → 2 quads, no new verts.
    {
        Mesh m;
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
        m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(2,1,0));
        size_t vertsBefore = m.vertices.length;

        size_t added = m.bridgeOpenRows([0u,1u,2u], [3u,4u,5u], false, 1u, 0.0f);
        assert(added == 2, "spans=1: expected 2 quads (N-1), got " ~ added.to!string);
        assert(m.faces.length == 2, "spans=1: expected 2 faces total");
        assert(m.vertices.length == vertsBefore, "spans=1: no new verts on existing-vert strip");
    }

    // (2) spans=2: one interior ring lerped at t=0.5.
    {
        Mesh m;
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
        m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(2,1,0));
        size_t vertsBefore = m.vertices.length;

        size_t added = m.bridgeOpenRows([0u,1u,2u], [3u,4u,5u], false, 2u, 0.0f);
        assert(added == 4, "spans=2: expected 4 quads (2 spans * (N-1)), got " ~ added.to!string);
        assert(m.vertices.length == vertsBefore + 3,
            "spans=2: expected exactly 3 new interior-ring verts, got "
            ~ (m.vertices.length - vertsBefore).to!string);
        // Every new vertex must sit at y=0.5 (lerp midpoint between y=0 and y=1 rows).
        foreach (vi; vertsBefore .. m.vertices.length)
            assert(abs(m.vertices[vi].y - 0.5f) < 1e-5f,
                "spans=2: interior vertex not at the t=0.5 lerp y-coordinate");
    }

    // (3) Proximity orientation: chain B built/walked in SPATIALLY REVERSED
    // order relative to chain A must still pair by nearest endpoint, not
    // raw index — mirrors the fixture's pairing_proximity_not_selection_order
    // discriminating case. A naive index-pair rule collapses all 3 interior
    // verts onto x=1; proximity pairing keeps them at x=0,1,2.
    {
        Mesh m;
        // Row A: x=0,1,2 (natural order).
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0)); m.addVertex(Vec3(2,0,0));
        // Row B: SAME x positions but walked in reverse (b0 at x=2, b2 at x=0).
        m.addVertex(Vec3(2,1,0)); m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
        size_t vertsBefore = m.vertices.length;

        size_t added = m.bridgeOpenRows([0u,1u,2u], [3u,4u,5u], false, 2u, 0.0f);
        assert(added == 4, "proximity case: expected 4 quads, got " ~ added.to!string);
        assert(m.vertices.length == vertsBefore + 3, "proximity case: expected 3 new interior verts");

        bool[3] sawX;   // x=0,1,2
        foreach (vi; vertsBefore .. m.vertices.length) {
            float x = m.vertices[vi].x;
            assert(abs(m.vertices[vi].y - 0.5f) < 1e-5f, "proximity case: interior verts at y=0.5");
            foreach (xi; 0 .. 3)
                if (abs(x - cast(float)xi) < 1e-5f) sawX[xi] = true;
        }
        assert(sawX[0] && sawX[1] && sawX[2],
            "proximity case: interior ring must land on 3 DISTINCT x positions (0,1,2), "
            ~ "not collapse onto x=1 — a raw index-pair rule would fail this");
    }

    // (4) Rejections: either chain shorter than 2 verts.
    {
        Mesh m;
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
        assert(m.bridgeOpenRows([0u], [1u], false, 1u, 0.0f) == 0,
            "single-vertex chain must be rejected");
    }
}

unittest { // bridgeOpenRows: unequal-length fan/triangulate — captured 3:1
           // EXACT face set (task 0395 phase 2, highest-risk piece), and
           // its 1:3 mirror produces the identical fan regardless of which
           // argument position holds the longer chain.
    import std.conv : to;

    Mesh makeFanMesh() {
        Mesh m;
        // Long row: x=0,1,2,3 at y=0 (indices 0..3). Short row: x=0,3 at y=1
        // (indices 4,5) — same total span as the reference capture.
        m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
        m.addVertex(Vec3(2,0,0)); m.addVertex(Vec3(3,0,0));
        m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(3,1,0));
        return m;
    }

    void assertCapturedFan(ref Mesh m, size_t vertsBefore, size_t added) {
        assert(added == 3,
            "3:1 fan: expected 3 faces (2 tri + 1 quad), got " ~ added.to!string);
        assert(m.faces.length == 3, "3:1 fan: expected exactly 3 faces total");
        assert(m.vertices.length == vertsBefore, "3:1 fan: zero new verts");
        assert(m.faces[0] == [0u,1u,4u], "3:1 fan: leading tri must be [a0,a1,b0]");
        assert(m.faces[1] == [1u,2u,5u,4u], "3:1 fan: middle quad must be [a1,a2,b1,b0]");
        assert(m.faces[2] == [2u,3u,5u], "3:1 fan: trailing tri must be [a2,a3,b1]");
    }

    // (1) 3:1 — long chain passed as chainA.
    {
        Mesh m = makeFanMesh();
        size_t vertsBefore = m.vertices.length;
        size_t added = m.bridgeOpenRows([0u,1u,2u,3u], [4u,5u], false, 1u, 0.0f);
        assertCapturedFan(m, vertsBefore, added);
    }

    // (2) 1:3 mirror — long chain passed as chainB; must produce the
    // IDENTICAL fan (dispatch normalizes by actual length, not argument
    // position).
    {
        Mesh m = makeFanMesh();
        size_t vertsBefore = m.vertices.length;
        size_t added = m.bridgeOpenRows([4u,5u], [0u,1u,2u,3u], false, 1u, 0.0f);
        assertCapturedFan(m, vertsBefore, added);
    }
}

unittest { // bridgeOpenRows: unequal-length fan — DDA formula (task 0395
           // rr-refinement, static-disassembly-verified bit-exact on 3:1,
           // 4:2, 5:2, 5:3, 6:3) beyond the captured 3:1 ratio: 5:2 (N=5
           // long edges, M=2 short edges). r(i)=ceil(i*M/N-0.5) round-half-
           // DOWN gives r=[0,0,1,1,2,2] for i=0..5, which the DDA (QUAD when
           // r steps up, else TRIANGLE apexed at shortC[r(i)]) turns into
           // tri,quad,tri,quad,tri — 3 triangles + 2 quads = N = 5 faces,
           // asserted here as an EXACT face set (index-for-index, not just
           // a count), the same rigor as the 3:1 case above.
    import std.conv : to;

    Mesh m;
    // Long row: x=0..5 at y=0 (indices 0..5, 5 edges). Short row: x=0,2.5,5
    // at y=1 (indices 6,7,8, 2 edges) — same total span.
    foreach (i; 0 .. 6) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addVertex(Vec3(0,1,0)); m.addVertex(Vec3(2.5,1,0)); m.addVertex(Vec3(5,1,0));

    size_t vertsBefore = m.vertices.length;
    size_t added = m.bridgeOpenRows([0u,1u,2u,3u,4u,5u], [6u,7u,8u], false, 1u, 0.0f);

    assert(added == 5, "5:2 fan: expected 5 faces (N), got " ~ added.to!string);
    assert(m.faces.length == 5, "5:2 fan: expected exactly 5 faces total");
    assert(m.vertices.length == vertsBefore, "5:2 fan: zero new verts");

    assert(m.faces[0] == [0u,1u,6u],    "5:2 fan: face 0 must be tri[a0,a1,b0], r=[0,0]");
    assert(m.faces[1] == [1u,2u,7u,6u], "5:2 fan: face 1 must be quad[a1,a2,b1,b0], r=[0,1]");
    assert(m.faces[2] == [2u,3u,7u],    "5:2 fan: face 2 must be tri[a2,a3,b1], r=[1,1]");
    assert(m.faces[3] == [3u,4u,8u,7u], "5:2 fan: face 3 must be quad[a3,a4,b2,b1], r=[1,2]");
    assert(m.faces[4] == [4u,5u,8u],    "5:2 fan: face 4 must be tri[a4,a5,b2], r=[2,2]");
}

unittest { // bridgeStripPaired / bridgeOpenRows: INTRA-STRIP mixed-pinning
           // winding propagation (task 0395 winding-consistency follow-up,
           // review gap). Chain A's FIRST edge (0,1) borders a pre-existing
           // face F0 — orientFaceConsistent must flip the FIRST bridge quad
           // to stay consistent with F0. Chain A's SECOND edge (1,4) is a
           // free wire with no neighbor of its own — before this fix,
           // orientFaceConsistent for the SECOND quad voted only against a
           // STATIC pre-existing snapshot (blind to the first quad, added
           // moments earlier in the SAME loop), saw a 0-0 tie, and kept its
           // default winding — which then shared the rung edge {1,6} with
           // the FIRST (flipped) quad in the SAME direction: a corrupt
           // half-edge fan. The live-registration fix (`registerNewFaceEdges`
           // feeding a mutable `liveEdgeFaces` that grows within the loop)
           // makes the second quad's vote see its already-placed sibling
           // and propagate the flip.
    import std.conv : to;

    Mesh m;
    // Pre-existing face F0 = [0,1,2,3] (index 0); chain A starts on its
    // edge (0,1) and continues past vertex 1 to a brand-new vertex 4 — edge
    // (1,4) borders nothing pre-existing (the "free wire" half of the row).
    m.addVertex(Vec3(0,0,0));  m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0));  m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(2,0,0));
    // Chain B: entirely disconnected row — no pre-existing neighbor anywhere.
    m.addVertex(Vec3(0,-1,0)); m.addVertex(Vec3(1,-1,0)); m.addVertex(Vec3(2,-1,0));
    m.addFace([0u,1u,2u,3u]);   // F0 — face index 0
    m.buildLoops();

    size_t facesBefore = m.faces.length;   // 1 (F0 only)
    size_t added = m.bridgeOpenRows([0u,1u,4u], [5u,6u,7u], false, 1u, 0.0f);
    assert(added == 2, "mixed-pinning strip: expected 2 bridge quads, got " ~ added.to!string);
    assert(m.faces.length == facesBefore + 2, "mixed-pinning strip: expected 3 faces total");

    // Global winding-consistency check across the WHOLE mesh (same style as
    // the owner-repro assert in tools/bridge_tool.d): no two faces may
    // traverse a shared edge in the same direction.
    bool sharesEdgeSameDirection(const(uint)[] a, const(uint)[] b) {
        foreach (i; 0 .. a.length) {
            uint u = a[i], v = a[(i + 1) % a.length];
            foreach (k; 0 .. b.length) {
                uint p = b[k], q = b[(k + 1) % b.length];
                if (u == p && v == q) return true;
            }
        }
        return false;
    }
    foreach (fi; 0 .. m.faces.length)
        foreach (fj; fi + 1 .. m.faces.length)
            assert(!sharesEdgeSameDirection(m.faces[fi], m.faces[fj]),
                "mixed-pinning strip: face " ~ fi.to!string ~ " and face " ~ fj.to!string
                ~ " traverse a shared edge in the SAME direction (half-edge corruption)");

    // Precise propagation check: quad 0 (bordering F0) must flip, AND quad 1
    // (bordering nothing of its own) must flip IN SYNC with it — proving the
    // live sibling vote actually fired, not merely that no corruption
    // happened to occur.
    assert(m.faces[facesBefore]     == [5u,6u,1u,0u],
        "mixed-pinning strip: quad 0 must flip against F0's (0,1) edge");
    assert(m.faces[facesBefore + 1] == [6u,7u,4u,1u],
        "mixed-pinning strip: quad 1 must flip in sync with quad 0 via the shared rung "
        ~ "(sibling propagation) — this is the exact assertion that fails without the "
        ~ "live-edgeFaces fix");
}

unittest { // bridgeLoopsPaired: exact-correspondence quad emission
    Mesh m;
    m.addVertex(Vec3(0,0,0)); m.addVertex(Vec3(1,0,0));
    m.addVertex(Vec3(1,1,0)); m.addVertex(Vec3(0,1,0));
    m.addVertex(Vec3(0,0,1)); m.addVertex(Vec3(1,0,1));
    m.addVertex(Vec3(1,1,1)); m.addVertex(Vec3(0,1,1));

    size_t n = m.bridgeLoopsPaired([0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(n == 4, "bridgeLoopsPaired: expected 4 quads");
    assert(m.faces.length == 4, "bridgeLoopsPaired: face count");
    foreach (f; m.faces) assert(f.length == 4, "bridgeLoopsPaired: all quads");

    // bridgeLoops still produces the same count (its tail now calls bridgeLoopsPaired).
    Mesh m2;
    m2.addVertex(Vec3(0,0,0)); m2.addVertex(Vec3(1,0,0));
    m2.addVertex(Vec3(1,1,0)); m2.addVertex(Vec3(0,1,0));
    m2.addVertex(Vec3(0,0,1)); m2.addVertex(Vec3(1,0,1));
    m2.addVertex(Vec3(1,1,1)); m2.addVertex(Vec3(0,1,1));
    size_t n2 = m2.bridgeLoops([0u,1u,2u,3u], [4u,5u,6u,7u]);
    assert(n2 == 4, "bridgeLoops via bridgeLoopsPaired: expected 4 quads");
    assert(m2.faces.length == 4, "bridgeLoops: face count unchanged after refactor");
}
