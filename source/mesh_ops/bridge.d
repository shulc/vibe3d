module mesh_ops.bridge;

// ---------------------------------------------------------------------------
// The Bridge kernel family: five entry points (`bridgeLoopsPaired`,
// `bridgeLoops`, `bridgeLoopsSpans`, `bridgeStripPaired`, `bridgeOpenRows`),
// one public read-only lookup (`facesBoundedByLoop`), the span cap
// (`maxBridgeSpans`) and the private pairing / twist / fan helpers they alone
// use (`pairBridgeLoop`, `bridgeTwistedVertex`, `orientOpenChainB`,
// `bridgeFanRows`, `ceilDivHalfDown`). Split out of mesh.d as
// `mixin template MeshBridgeOps` by the mesh.d decomposition campaign
// (0407 §B.V2, task 0417 — continuation of the task-0412 plane-cut pilot).
//
// Converted to module-level FREE FUNCTIONS by task 1903 Stage D3
// (`doc/mesh_edit_seam_plan.md` §4, §5.2 row D3). Function BODIES are
// unchanged — every edit is an `ed.` / `m.` prefix — and the three decisions
// Stage D2 recorded for the first mutating family hold here verbatim: the
// receiver is the batch, the mixin left `struct Mesh` in the SAME change, and
// the callers open an UNRECORDED batch at their own boundary. What D3 adds to
// that memo is below.
//
// TWO RECEIVERS IN ONE FAMILY, AND THE SPLIT IS THE `const` THE MEMBERS ALREADY
// CARRIED. §4.1's first two cells, side by side for the first time:
//
//   * `ref MeshEditBatch ed` — `bridgeLoopsPaired`, `bridgeLoops`,
//     `bridgeLoopsSpans`, `bridgeStripPaired`, `bridgeOpenRows` and the private
//     `bridgeFanRows`. Every one of them appends faces (and, on a multi-span
//     path, vertices) and stamps subpatch words.
//   * `ref const(Mesh) m` — `facesBoundedByLoop` and the three private helpers
//     that only READ positions to decide a pairing (`pairBridgeLoop`,
//     `bridgeTwistedVertex`, `orientOpenChainB`). All four were `const`
//     members; the const receiver is the same statement in the new shape, and
//     it is now ENFORCED at the seam rather than by a keyword the mixin could
//     have dropped at any time.
//
// The mutating kernels reach the read-only helpers by spelling `ed.mesh`
// explicitly at the call site (`pairBridgeLoop(ed.mesh, …)`), not by leaning on
// `alias mesh this`. Both compile; the explicit one is the one that SAYS the
// pairing step reads and does not write, which is the whole content of the two
// receivers being different inside one family.
//
// THE WIDENINGS D3 OWES (plan §2.6, §4.3 — "each widening lands in the stage
// converting its caller, with a census row naming that caller"). Three names in
// `source/mesh.d` were `private` and resolved here only because a mixin body is
// instantiated in the host's scope:
//
//   * `Mesh.orientFaceConsistent` and `Mesh.registerNewFaceEdges` — the
//     winding-consistency pair `bridgeStripPaired` / `bridgeFanRows` use (task
//     0395). This file is their ONLY caller outside mesh.d.
//   * `mesh.smoothstep01` — NOT a `Mesh` member at all but a module-private
//     free function of `mesh`, which is why §2.6 singled it out as "the one
//     that will not compile after conversion". `bridgeTwistedVertex` is its
//     only caller anywhere. It stays a free function of `mesh` (the
//     alternative §2.6 offers is a move to `math`; that would be a second
//     edit hiding inside a move, and `math` has no other ease-curve to sit
//     beside).
//
// `tests/unit/commit_seam_census_test.d` carries one row per name: the
// `private` spelling is gone from mesh.d AND this file still calls it. The
// second half is what keeps the widening honest — Stage A shipped ten of these
// with no caller and the review reverted them all (plan §2.6, review S3).
//
// THE TWO INTRA-`Mesh` CALLERS, and why they hold a TRANSITIONAL batch.
// Unlike C / D1 / D2, this family is called from inside `struct Mesh` itself:
// `Mesh.thickenSurface` (source/mesh.d, step 5 — the rim) and
// `revolveProfileEx` (source/mesh_ops/revolve.d, still a mixin until Stage E2)
// both call `bridgeLoopsPaired`. Neither has a batch, and neither is a command
// or a tool, so §4.1's "the caller opens the batch" has nowhere to land yet.
// Each site opens a narrow UNRECORDED batch around its bridging loop ONLY,
// labelled TRANSITIONAL and naming the stage that removes it. They are the
// first two sites in the tree where a KERNEL opens a batch, which §2.3 rule 2
// forbids in the finished design — recorded as a debt, not defended as a
// pattern.
//
// WHAT `maxBridgeSpans` BECAME. §2.7 lists it among the non-function members a
// mixin injects into `Mesh`; §11 decides it: "keep it an `enum` in the ops
// module after conversion". It is module scope here, so `Mesh.maxBridgeSpans`
// no longer resolves and the three sites that spelled it that way moved with
// this commit. Its DoS note is below.
// ---------------------------------------------------------------------------
import mesh;
import math;
import mesh_edit_delta : MeshEditScope;

/// The change classes one bridge actually commits, for the batch its callers
/// open. It lives HERE, beside the kernels, and not spelled out at each of the
/// call sites, for the reason Stage D2 gave for `kReduceEditScope`: N copies is
/// N chances to drift, and the one that drifts is the one that stops matching
/// the op-log's declared scope when track 2 turns this family's undo into a
/// delta (`MeshEditTracker.declare` is what ends up in `MeshEditDelta.scope_`).
///
/// `Polygons` : every entry point appends quads/tris through `addFace`.
/// `Points`   : the multi-span paths (`bridgeLoopsSpans`, `bridgeOpenRows`
///              with `spans > 1`) `addVertex` one interior ring per span.
///              Declared for the family, not per call — a single-span bridge
///              simply never publishes it.
/// `Marks`    : `setFaceSubpatch` stamps the inherited Subpatch bit on every
///              new face. That write publishes NOTHING on its own (it is the
///              raw, non-committing single-index writer), which is exactly why
///              the class has to be DECLARED: on a revert, `MeshEditDelta`
///              reads `scope_` back to decide what to bump and rebuild, and a
///              faceMarks plane that moved without the bit set is a stale
///              subpatch cache.
///
/// NOT `Position`: no bridge kernel moves an EXISTING vertex. Every coordinate
/// it produces belongs to a vertex it created in the same call, which is a
/// `Points` change and carries its position in the `AddVerts` entry. That is
/// also why this family adds no `setVertexPos` call and why its §5.7
/// position-write count is 0 rather than a retired allow-entry.
enum uint kBridgeEditScope = MeshEditScope.Geometry | MeshEditScope.Marks;

/// Hard internal cap on interior rings a single `bridgeLoopsSpans` /
/// `bridgeOpenRows` call may generate — defense-in-depth against a DoS via a
/// huge Segments value reaching these kernels through any path other than the
/// interactive tool's own `.enforceBounds()`-clamped Param (see params.d's DoS
/// note; task 0357 review convention).
///
/// This is the KERNEL layer of the two-layer clamp, and it is the layer that
/// survives the headless path: a Param's `.min()` / `.max()` are UI hints and
/// do NOT clamp `injectParamsInto`. `BridgeParams.segments` carries the other
/// layer. Task 1903 Stage D3 moved this constant from `struct Mesh` (where the
/// mixin injected it) to module scope; keep it an `enum` here, and if Segments
/// is ever re-exposed with a different Param, that Param needs
/// `.min(lo).max(hi).enforceBounds()` and this ceiling stays regardless
/// (plan §11).
enum size_t maxBridgeSpans = 512;

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
size_t bridgeLoopsPaired(ref MeshEditBatch ed, const(uint)[] loopA, const(uint)[] pairedB) {
    if (loopA.length != pairedB.length || loopA.length < 3) return 0;
    const N = loopA.length;
    auto edgeFaces = ed.buildEdgeFaces();
    bool edgeAdjSubpatch(uint va, uint vb) {
        auto p = edgeKey(va, vb) in edgeFaces;
        if (p is null) return false;
        return ((*p)[0] >= 0 && ed.isFaceSubpatch((*p)[0]))
            || ((*p)[1] >= 0 && ed.isFaceSubpatch((*p)[1]));
    }
    foreach (i; 0 .. N) {
        uint a0 = cast(uint)loopA[i],    a1 = cast(uint)loopA[(i + 1) % N];
        uint b0 = cast(uint)pairedB[i],  b1 = cast(uint)pairedB[(i + 1) % N];
        bool sub = edgeAdjSubpatch(a0, a1) || edgeAdjSubpatch(b0, b1);
        uint newFi = cast(uint)ed.faces.length;
        ed.addFace([a0, a1, b1, b0]);
        ed.resizeSubpatch();
        ed.setFaceSubpatch(newFi, sub);
    }
    // Task 0901: every quad above went through `addFace`, which grows the
    // PolyVertex map atomically per call — no other corner is touched.
    // Declared for the CROSS-CHECK (task 0830's `declareCornerAppend`),
    // not to apply anything: a future edit that swaps one of these
    // `addFace` calls for a bare `faces ~=` (the task-0690 shape) would
    // otherwise silently zero the whole map via the length insurance
    // instead of tripping the stated-total mismatch. `bridgeLoops` and
    // `bridgeLoopsSpans` both bottom out here, so this covers them too.
    ed.declareCornerAppend();
    return N;
}

/// Shared pairing step (factored out of `bridgeLoops`, task 0357 — also
/// used by `bridgeLoopsSpans`): anchor B at the vertex nearest A[0];
/// pick forward vs. reversed direction by minimum total paired
/// Euclidean distance; `flip` overrides the auto choice. Returns the
/// pairing array P (P[i] is the loopB vertex paired with loopA[i]).
///
/// `ref const(Mesh) m`, and the mutating kernels pass `ed.mesh`: this step
/// reads positions and decides an ORDER, it writes nothing (task 1903
/// Stage D3, plan §4.1 second cell).
private uint[] pairBridgeLoop(ref const(Mesh) m, const(uint)[] loopA,
                              const(uint)[] loopB, bool flip) {
    const size_t N = loopA.length;

    // Step 1 — anchor: B-vertex nearest A[0].
    Vec3   pa0    = m.vertices[loopA[0]];
    size_t k      = 0;
    float  bestSq = float.max;
    foreach (i; 0 .. N) {
        Vec3  d  = m.vertices[loopB[i]] - pa0;
        float sq = d.x*d.x + d.y*d.y + d.z*d.z;
        if (sq < bestSq) { bestSq = sq; k = i; }
    }

    // Step 2 — pick direction by minimum total paired distance.
    float fwdSum = 0.0f, revSum = 0.0f;
    foreach (i; 0 .. N) {
        Vec3 ai   = m.vertices[loopA[i]];
        Vec3 bFwd = m.vertices[loopB[(k + i)     % N]];
        Vec3 bRev = m.vertices[loopB[(k + N - i) % N]];
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
size_t bridgeLoops(ref MeshEditBatch ed, const(uint)[] loopA, const(uint)[] loopB,
                   bool flip = false) {
    if (loopA.length != loopB.length || loopA.length < 3) return 0;
    uint[] P = pairBridgeLoop(ed.mesh, loopA, loopB, flip);
    return bridgeLoopsPaired(ed, loopA, P);
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
///
/// `ref const(Mesh) m` (task 1903 Stage D3): a pure lookup, and the const
/// receiver keeps `mesh.facesBoundedByLoop(loop)` compiling verbatim at both
/// call sites — one of them (`facesMatchingLoop`) already holds a
/// `const ref Mesh`, which no batch receiver could accept.
uint[] facesBoundedByLoop(ref const(Mesh) m, const(uint)[] loop) {
    uint[] hits;
    const size_t N = loop.length;
    outer: foreach (fi; 0 .. m.faces.length) {
        auto fv = m.faces[fi];
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
size_t bridgeLoopsSpans(ref MeshEditBatch ed, const(uint)[] loopA, const(uint)[] loopB,
                        bool flip, uint spans, float twist) {
    if (loopA.length != loopB.length || loopA.length < 3) return 0;
    if (spans < 1) spans = 1;
    if (spans > maxBridgeSpans) spans = cast(uint)maxBridgeSpans;   // kernel-side DoS cap

    uint[] P = pairBridgeLoop(ed.mesh, loopA, loopB, flip);
    if (spans == 1) return bridgeLoopsPaired(ed, loopA, P);

    const size_t N = loopA.length;
    uint[][] rings = new uint[][](spans + 1);
    rings[0]     = loopA.dup;
    rings[spans] = P.dup;
    foreach (i; 1 .. spans) {
        float t = cast(float)i / cast(float)spans;
        uint[] ring = new uint[](N);
        foreach (k; 0 .. N)
            ring[k] = ed.addVertex(bridgeTwistedVertex(ed.mesh, loopA, P, k, t, twist));
        rings[i] = ring;
    }

    size_t added = 0;
    foreach (s; 0 .. spans)
        added += bridgeLoopsPaired(ed, rings[s], rings[s + 1]);
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
///
/// `smoothstep01` below is `mesh`'s own module-level helper, widened from
/// `private` by task 1903 Stage D3 because this call is the reason it exists
/// and a mixin body was the only thing that used to make it reachable
/// (plan §2.6 — "the one that will not compile after conversion").
private Vec3 bridgeTwistedVertex(ref const(Mesh) m, const(uint)[] loopA,
                                 const(uint)[] pairedB,
                                 size_t k, float t, float twist) {
    const size_t N = loopA.length;
    Vec3 base(long idx) {
        long mm = idx % cast(long)N;
        if (mm < 0) mm += cast(long)N;
        return vec3Lerp(m.vertices[loopA[cast(size_t)mm]],
                        m.vertices[pairedB[cast(size_t)mm]], t);
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
private uint[] orientOpenChainB(ref const(Mesh) m, const(uint)[] a,
                                const(uint)[] b, bool flip) {
    Vec3 a0 = m.vertices[a[0]], a1 = m.vertices[a[$ - 1]];
    Vec3 b0 = m.vertices[b[0]], b1 = m.vertices[b[$ - 1]];
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
size_t bridgeStripPaired(ref MeshEditBatch ed, const(uint)[] a, const(uint)[] b) {
    if (a.length != b.length || a.length < 2) return 0;
    const N = a.length;
    auto edgeFaces = ed.buildEdgeFaces();  // pre-existing snapshot — subpatch source ONLY, untouched
    auto liveEdgeFaces = edgeFaces.dup;    // grows with THIS strip's own faces — winding source
    bool edgeAdjSubpatch(uint va, uint vb) {
        auto p = edgeKey(va, vb) in edgeFaces;
        if (p is null) return false;
        return ((*p)[0] >= 0 && ed.isFaceSubpatch((*p)[0]))
            || ((*p)[1] >= 0 && ed.isFaceSubpatch((*p)[1]));
    }
    foreach (i; 0 .. N - 1) {
        uint a0 = cast(uint)a[i],   a1 = cast(uint)a[i + 1];
        uint b0 = cast(uint)b[i],   b1 = cast(uint)b[i + 1];
        bool sub = edgeAdjSubpatch(a0, a1) || edgeAdjSubpatch(b0, b1);
        uint[] idx = [a0, a1, b1, b0];
        ed.orientFaceConsistent(idx, liveEdgeFaces);
        uint newFi = cast(uint)ed.faces.length;
        ed.addFace(idx);
        ed.registerNewFaceEdges(liveEdgeFaces, newFi, idx);
        ed.resizeSubpatch();
        ed.setFaceSubpatch(newFi, sub);
    }
    // Task 0901: same append-only shape as `bridgeLoopsPaired` above —
    // see that call's comment. Covers `bridgeOpenRows`' equal-length
    // path (both single- and multi-span) too, since it bottoms out here.
    ed.declareCornerAppend();
    return N - 1;
}

/// Exact integer ceiling-division, ROUND-HALF-DOWN at the .5 boundary:
/// `ceilDivHalfDown(p, q) == ceil(p/q as real)` for `q > 0`, computed
/// without floats so there is no rounding risk near a `.5` boundary
/// (`bridgeFanRows`'s DDA below evaluates `ceil(i*M/N - 0.5)`, which is
/// exactly `ceilDivHalfDown(2*i*M - N, 2*N)`). D's built-in `/` on
/// integers truncates toward zero rather than flooring, which is wrong
/// for a negative numerator — this handles that case explicitly.
///
/// No receiver: it touches no mesh state at all (it was a `private static`
/// member for the same reason).
private long ceilDivHalfDown(long p, long q) pure nothrow @nogc @safe
in (q > 0)
{
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
private size_t bridgeFanRows(ref MeshEditBatch ed, const(uint)[] longC,
                             const(uint)[] shortC) {
    if (longC.length < 2 || shortC.length < 2) return 0;
    const long N = cast(long)longC.length - 1;
    const long M = cast(long)shortC.length - 1;
    if (M < 1 || N <= M) return 0;

    // r(i) = ceil(i*M/N - 0.5) = ceilDivHalfDown(2*i*M - N, 2*N), i = 0..N.
    long[] r = new long[](N + 1);
    foreach (i; 0 .. N + 1)
        r[i] = ceilDivHalfDown(2 * i * M - N, 2 * N);

    auto edgeFaces = ed.buildEdgeFaces();  // pre-existing snapshot — subpatch source ONLY, untouched
    auto liveEdgeFaces = edgeFaces.dup;    // grows with THIS fan's own faces — winding source
    bool edgeAdjSubpatch(uint va, uint vb) {
        auto p = edgeKey(va, vb) in edgeFaces;
        if (p is null) return false;
        return ((*p)[0] >= 0 && ed.isFaceSubpatch((*p)[0]))
            || ((*p)[1] >= 0 && ed.isFaceSubpatch((*p)[1]));
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
        ed.orientFaceConsistent(idx, liveEdgeFaces);
        uint newFi = cast(uint)ed.faces.length;
        ed.addFace(idx);
        ed.registerNewFaceEdges(liveEdgeFaces, newFi, idx);
        ed.resizeSubpatch();
        ed.setFaceSubpatch(newFi, sub);
        ++added;
    }
    // Task 0901: same append-only shape as `bridgeLoopsPaired` above —
    // see that call's comment. This is `bridgeOpenRows`' unequal-length
    // (fan/triangulate) path, private and reachable only from there.
    ed.declareCornerAppend();
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
size_t bridgeOpenRows(ref MeshEditBatch ed, const(uint)[] chainA, const(uint)[] chainB,
                      bool flip, uint spans, float twist) {
    if (chainA.length < 2 || chainB.length < 2) return 0;

    uint[] B = orientOpenChainB(ed.mesh, chainA, chainB, flip);

    if (chainA.length != B.length) {
        immutable bool aLonger = chainA.length > B.length;
        return bridgeFanRows(ed, aLonger ? chainA : B, aLonger ? B : chainA);
    }

    if (spans < 1) spans = 1;
    if (spans > maxBridgeSpans) spans = cast(uint)maxBridgeSpans;
    if (spans == 1) return bridgeStripPaired(ed, chainA, B);

    const size_t N = chainA.length;
    uint[][] rings = new uint[][](spans + 1);
    rings[0]     = chainA.dup;
    rings[spans] = B.dup;
    foreach (i; 1 .. spans) {
        float t = cast(float)i / cast(float)spans;
        uint[] ring = new uint[](N);
        foreach (k; 0 .. N)
            ring[k] = ed.addVertex(vec3Lerp(ed.vertices[chainA[k]], ed.vertices[B[k]], t));
        rings[i] = ring;
    }

    size_t added = 0;
    foreach (s; 0 .. spans)
        added += bridgeStripPaired(ed, rings[s], rings[s + 1]);
    return added;
}

// ===========================================================================
// Module unittests.
// ===========================================================================
// (None here — task 0706 moved this family's blocks to
// tests/unit/mesh_ops/bridge_test.d, and they stayed there through the D3
// conversion.)

// ---------------------------------------------------------------------------
// The gate that outlives the text census (task 1903 Stage C review, MAJOR-1 —
// compile-time, not a unittest). A member of `Mesh` BEATS a same-name UFCS free
// function silently — no ambiguity, no warning — so anything that puts one of
// these names back on the struct (`mixin MeshBridgeOps;`, `mixin ...!();`, a
// named mixin, a hand-written method with the old body) rebinds every call site
// to it and this module becomes dead code. The regex census in
// tests/unit/commit_seam_census_test.d sees only the literal `mixin Mesh*Ops;`
// spelling; this sees the fact, and at `dub build` time rather than only under
// --config=tests.
//
// It is ALSO the check that a mutating receiver did not quietly widen back: a
// `Mesh.bridgeLoops` member could only exist by taking the mesh directly, i.e.
// by dropping the batch this stage exists to require.
//
// EVERY family entry is named, including the private helpers and
// `maxBridgeSpans`: the mixin injected all of them into `Mesh` (plan §2.7), so
// a partial revert that reinstates only the pairing helper is exactly the
// silent half this list is here to catch.
// ---------------------------------------------------------------------------
static foreach (n; ["bridgeLoopsPaired", "bridgeLoops", "bridgeLoopsSpans",
                    "bridgeStripPaired", "bridgeOpenRows", "facesBoundedByLoop",
                    "pairBridgeLoop", "bridgeTwistedVertex", "orientOpenChainB",
                    "bridgeFanRows", "ceilDivHalfDown", "maxBridgeSpans"])
    static assert(!__traits(hasMember, Mesh, n),
        "`Mesh." ~ n ~ "` is a MEMBER again. A member BEATS a same-name UFCS free "
      ~ "function silently, so every call site binds back to it, the batch the "
      ~ "mutating kernels take as their receiver goes away with it, and task 1903 "
      ~ "Stage D3 means nothing. Whatever re-added it — `mixin MeshBridgeOps;`, "
      ~ "`mixin ...!();`, a named mixin, or a hand-written method — must go.");
