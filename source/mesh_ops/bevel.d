module mesh_ops.bevel;

import mesh;
import math;

// ---------------------------------------------------------------------------
// MeshBevelOps — edge/vertex bevel kernel family (bevelEdgesByMask,
// bevelVerticesByMask, the non-manifold fin-bundle spine kernels
// bevelIsolatedFinBundleSpine / bevelFinBundleSpineMultiEdge, the
// centerNormalProject helper, and the edge.bevel valence-4 free-end cap
// parity fields bevelPinnedOrphans_ / bevelCapCoincidentPos_ /
// bevelCapOrphanPos_), mixed into struct Mesh (source/mesh.d) via
// `mixin MeshBevelOps;`. Split out of mesh.d as part of the mesh.d
// decomposition campaign (0407 §B.V2 — see task 0412's doc for the
// architectural decision: mixin template over a package move or UFCS
// free-functions). Method bodies below are verbatim cut/paste from mesh.d
// (only the extraction boundary is new).
// ---------------------------------------------------------------------------
mixin template MeshBevelOps() {
    // --- edge.bevel valence-4 planar free-end cap parity ------------------
    // At a valence-4 / planar / K==1 free-end whose single selected edge
    // terminates on a valence-4 full-hub junction, the reference cap keeps
    // TWO coincident referenced verts at the free-end position (one anchors
    // the reduced side faces, one the chamfer strips) PLUS one ORPHAN slide
    // along the edge opposite the selected one (derived from measured
    // reference dumps only). These are the intended artefacts of that exact
    // cap and are recorded per-bevel so (a) the intended orphan survives the
    // tail compaction (pinned), and (b) the soundness census can exempt
    // exactly these coincident/orphan verts while still flagging any others.
    // All three are reset at the top of every bevelEdgesByMask call and
    // consumed only within that call (+ read by the census immediately after).
    uint[] bevelPinnedOrphans_;      // vertex indices to keep through compaction
    Vec3[] bevelCapCoincidentPos_;   // free-end positions holding the coincident pair
    Vec3[] bevelCapOrphanPos_;       // opposite-edge-slide positions (intended orphan)

    /// Edge bevel (Candidate A — slide-along-adjacent-edge, generalized).
    ///
    /// Replaces every qualifying selected edge with a chamfer strip (a flat
    /// quad at `roundLevel==0`, or `2^roundLevel` rings at `roundLevel>0`.
    /// The isolated K1 SLIDE profile and the K2 shared-vertex miter rails are
    /// both capture-verified (bit-exact convex round-over / hub arc); a K3+
    /// junction's per-pair rails use the same verified law, but its central
    /// hub vertex + fan topology is an unresolved reference gap). Unlike the v1
    /// kernel, selected edges may share endpoints: the per-VERTEX cap
    /// topology (bare end / loop-turn miter / N-way junction hub-fill) is
    /// derived generically from the half-edge ring around each touched
    /// vertex, not hardcoded per case. See doc/bevel_full_plan.md Phases 1-3
    /// and the private algorithm-grounding reference distilled there
    /// (clean-room design, NOT ported GPL code — see the bevel clean-room
    /// rewrite history for provenance).
    ///
    /// **Algorithm** (per affected vertex V, walking `facesAroundVertex(V)` /
    /// `edgesAroundVertex(V)` in their proven-lockstep half-edge ring order —
    /// face `f_k` borders edge `e_k` (V's SUCCESSOR side within `f_k`) and
    /// edge `e_(k+1)` (V's PREDECESSOR side within `f_k`)):
    ///   - `f_k` bordered by 2 SELECTED edges → MITER: one new vertex via
    ///     `offsetMeet` (both-bevel meet, matches `insetCorner`'s convention).
    ///     If ALL of V's edges are selected (K == valence), the per-face
    ///     miters trace a closed K-gon boundary (each selected edge's own
    ///     chamfer quad already threads a rail between 2 consecutive miters)
    ///     that needs exactly ONE new cap face to fill — the "hub" cap.
    ///   - `f_k` bordered by exactly 1 selected edge → SLIDE: one new vertex
    ///     = V + width·dir(the OTHER, unselected edge) — identical formula
    ///     to the original v1 kernel's per-endpoint corner, so a lone
    ///     selected edge (K==1 at both ends) reproduces v1's output exactly.
    ///   - `f_k` bordered by 2 UNSELECTED edges → SPLIT into the 2 already-
    ///     computed slide vertices. The source vertex V is now ALWAYS fully
    ///     cut (task 0439): the former "active/inactive" distinction (an
    ///     unselected edge needed a selected NEIGHBOUR edge, via its OTHER
    ///     incident face, to earn its own slide point) had no reference
    ///     counterpart and is gone — every unselected edge gets a slide
    ///     point, full stop (doc/edge_bevel_freeend_cap_plan.md,
    ///     capture-verified at Round Level 0 for valence 3-6, K∈{1,2}).
    ///
    ///   A vertex with `0 < K < nE` on a CLOSED fan (`nE == d`; see below)
    ///   additionally gets ONE flat cap face: walk the fan in ring order,
    ///   threading one slide vertex per unselected slot and one miter vertex
    ///   per face whose two bordering edges are BOTH selected (a K≥2 run of
    ///   adjacent selected edges), and emit the cap once that ring has ≥3
    ///   corners. This is the free-end / partial-fan cap that fills the hole
    ///   the old `keep V` branch used to leave. `K < nE` keeps this path
    ///   DISJOINT from the K==d hub cap below (on a closed fan the two
    ///   conditions are mutually exclusive) — a vertex is never both.
    ///   `roundLevel` rounds this cap's own ring (task 0449): the ring is
    ///   registered as a rail-support consumer exactly like the hub cap's
    ///   ring, since it IS the missing second consumer for its bordering
    ///   rails (the reference's own cap plugging the hole the free end
    ///   cuts — capture-verified). A rail that also clears the chamfer-
    ///   strip side of the two-consumer fixed point rounds via the ONE
    ///   reference-captured fillet law every rail uses; the cap's own
    ///   interior tessellation at K >= 2 remains unclosed (see the Round
    ///   Level inventory comment further below). The same cap on an OPEN
    ///   (boundary) fan has no reference dump and is refused before any
    ///   mutation (see the preflight below).
    /// A selected edge's own chamfer strip always bridges the per-(vertex,
    /// face) corner already resolved above for its 2 bordering faces at
    /// each endpoint — so the strip is well-defined for EVERY case (bare
    /// end, loop turn, junction) without per-case branching at the edge
    /// level.
    ///
    /// v1's guards this generalizes away (task 0391 Phase 1/2): the blanket
    /// endpoint-disjoint guard and the valence-3-both-endpoints guard are
    /// GONE — a vertex may have any number of selected edges (K) at any
    /// valence. A selected edge with exactly ONE incident face (a rim edge)
    /// is handled too (its lone border insets by `width`, no bridge quad —
    /// see Step 1 below); one with THREE OR MORE is refused (task 0438).
    /// STILL required: a free-end/partial-fan cap (above) on a BOUNDARY
    /// (open-fan) vertex has no reference dump and is refused before any
    /// mutation (task 0439, preflight below) — the same shape on an
    /// interior (closed-fan) vertex gets the cap.
    ///
    /// `roundLevel` subdivides every eligible cross-section into `2^L`
    /// segments.  A rail is owned by its two already-resolved L0 endpoint
    /// vertices, not by an individual strip: the same interior indices are
    /// threaded through both of its consumers (support face, neighbouring
    /// strip, or hub cap).  ALL rails — clean slide, bare-end, and miter —
    /// use the ONE reference-captured law documented beside `railInterior`:
    /// a TRUE circular fillet tangent to the two adjacent faces, whose radius
    /// (`width·tan(φ/2)`) AND sweep (`180°−φ`) are set by the ACTUAL dihedral φ
    /// — reconstructed from the reference's two-tangent-line-intersection +
    /// angular-SLERP builders, verified bit-exact across dihedrals 45°–150° and
    /// on the 90° cube (K1 / bare end / K2 miter).  The 90° cube is a special
    /// case (a coincidental quarter-turn about `E_A+E_B−V`), not the whole law.
    /// A 3-way junction reproduces the reference's rounded corner bit-exact at
    /// EVERY Round Level: one general L×L rational-Gregory ring (Gregory 1974 /
    /// Chiyokura–Kimura) per sub-quad — HUB + R→HUB spoke points + rational
    /// interior points — whose u=0/v=0 boundary reuses the true-arc pairwise
    /// rail interiors. The pairwise arcs are geodesics on the corner-rounding
    /// sphere (centre `V−width·Σn̂`, not the per-vertex fillet — that degenerates
    /// for near-antipodal hub poles), and the whole junction (rails + ring) is
    /// subdivided into `2·roundLevel` equal-angle segments (the isolated K1
    /// convention is the same law; `2·L` only equals `2^L` at L≤2, which is why
    /// the old `1<<roundLevel` matched there but over-subdivided at L≥3).
    /// N≥4 junctions (a different reference N-sided path — `junctionRingN`) now
    /// ALSO round (task 0454/0456) to reference parity at EVERY level, both N
    /// parities: even N was already exact; odd N's L≥2 ring residual (the
    /// odd-N corner-move / center-normal newC_i gap) is CLOSED (task 0453,
    /// finding J) — `newC_i`'s true final value is the plain hub-law value,
    /// planar-projected by the center-normal step (every N), then — odd N only —
    /// magnitude-corrected by the odd-N corner-move sin-angle recurrence. An over-cap
    /// full hub (`> MAX_JUNCTION_VALENCE`) still keeps the flat N-gon cap
    /// (DoS backstop).
    /// `roundLevel==0` takes the old flat path without a registry.
    ///
    /// A DIFFERENT cap — the free-end / partial-fan cap for `0 < K < nE`
    /// (task 0439, described above) — is a disjoint code path guarded by
    /// `K < nE`. Since task 0449 its own boundary rails round through the
    /// same fixed point as any other rail (its ring is the missing second
    /// support-consumer those rails needed); the cap's own interior
    /// tessellation at K >= 2 (a notch spanning 2+ selected slots) is not
    /// decoded and stays a flat fill between the rounded boundary arcs (see
    /// the Round Level inventory comment further below). It is not a
    /// special case of this hub-cap N-gon.
    ///
    /// Two-layer DoS clamp (`doc/param_bounds_plan.md` convention):
    /// `roundLevel` is hard-capped to `MAX_ROUND_LEVEL` HERE (kernel-side,
    /// authoritative for any caller including a direct/scripted one) since
    /// it scales allocation exponentially (`2^L` quad rings per rounded
    /// endpoint); the command/tool Param's `.min(0).max(MAX_ROUND_LEVEL)
    /// .enforceBounds()` hint is a shallower, UI/HTTP-only second line of
    /// defense.
    ///
    /// `widthMode` (parity task — the D1 fuzz divergence): selects how the
    /// tool value maps to the along-face corner slide.
    ///   • `false` (default, "inset"): the value IS the along-face slide — the
    ///     distance each corner travels along its neighbouring non-bevel edge.
    ///     Every offset below is byte-identical to the pre-`widthMode` path.
    ///   • `true` ("width"): the value is the true PERPENDICULAR bevel width —
    ///     the distance across the new chamfer strip, held CONSTANT for every
    ///     selected edge regardless of its dihedral. On a crease whose two
    ///     incident faces meet at surface-opening angle θ, the along-face slide
    ///     it produces is `value / sin(θ/2)` — so a sharper crease slides
    ///     further to keep the same perpendicular width. θ is the per-edge
    ///     dihedral (it varies across a non-uniform selection); a boundary/rim
    ///     edge (no second face) has no dihedral and keeps the raw value.
    /// Returns the count of edges actually processed (0 ⇒ no-op, all skipped).
    size_t bevelEdgesByMask(const bool[] maskIn, float width, int roundLevel = 0,
                            bool widthMode = false) {
        const mask = maskMinusHiddenEdges(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (width < 1e-6f) return 0;
        if (mask.length != edges.length) return 0;

        if (roundLevel < 0) roundLevel = 0;
        if (roundLevel > MAX_ROUND_LEVEL) roundLevel = MAX_ROUND_LEVEL;

        // A "return 0 ⇒ no-op" contract callers rely on (they discard their
        // pre-op snapshot on failure WITHOUT restoring it into the mesh —
        // see commands/mesh/bevel.d's evaluate()). The per-vertex corner
        // pass below can call addVertex for a vertex whose chamfer span is
        // later discarded (e.g. a boundary-adjacent asymmetric endpoint,
        // see the regression unittest above) — truncate back to this
        // snapshot on every post-corner-pass 0-return so a "no-op" never
        // leaks orphaned vertices into the mesh.
        immutable size_t savedVertCount = vertices.length;

        // Reset the valence-4 free-end cap parity bookkeeping for this call
        // (see the field declarations). Populated only when a qualifying cap
        // is emitted below; empty otherwise, so this is a no-op for every
        // ordinary bevel.
        bevelPinnedOrphans_.length     = 0;
        bevelCapCoincidentPos_.length  = 0;
        bevelCapOrphanPos_.length      = 0;

        // Edge→(≤2 faces) adjacency, one pass (same idiom as extrudeEdgesByMask).
        auto edgeFaces = buildEdgeFaces();

        // Step 1: qualifying selected edges. An edge with TWO incident faces
        // gets the ordinary chamfer (two rails plus a bridge quad between
        // them). An edge with exactly ONE incident face is a RIM edge, and
        // the reference bevels it too — but differently: the lone face's
        // border simply insets by `width` and NO bridge quad is created
        // (reference captures `edge_bevel_open_{rimedge,bothends}_w015`; the
        // cap rule is "+1 bridge quad iff 2 incident faces, 0 new faces iff
        // 1", orthogonal to whether the endpoints are on a rim). Both kinds
        // count as "selected" for the per-vertex fan logic below; only the
        // 2-face kind becomes a ChamferSpan.
        // A selected edge shared by THREE OR MORE faces is a separate family:
        // `buildEdgeFaces`'s `int[2]` slots cannot even witness the third face,
        // so the ordinary two-face path below would silently emit WRONG
        // geometry. The reference's real law IS captured for ONE measured
        // topology — an ISOLATED fin bundle (a "book"/propeller: one spine edge
        // shared by N≥3 fins whose two endpoints touch NOTHING but those fins),
        // task 0438, `edge_bevel_0438_{A3face,B4face}_*`: every incident fin is
        // inset in place by `width` along its own in-plane perpendicular (the
        // same per-face formula two-face edges use) and exactly ONE new N-gon
        // fan cap is inserted at EACH END of the spine, fanning that end's N rail
        // points in incident-face order (triangle at N=3, quad at N=4). No fin is
        // split, N is only a fan size, and neither `sharp` (not a kernel param)
        // nor Round Level affects the result — both measured inert. A 3-face
        // edge embedded in a LARGER mesh (endpoints carrying faces not incident
        // to the spine) is NOT measured, so it stays refused (no extrapolation).
        {
            auto faceUse = edgeFaceUseCounts();
            bool anyGE3 = false;
            foreach (i; 0 .. edges.length)
                if (mask[i] && i < faceUse.length && faceUse[i] >= 3) { anyGE3 = true; break; }
            if (anyGE3) {
                // Collect the selected edges. Exactly ONE must be the ≥3-face
                // spine; a lone spine keeps the single-edge builder byte-for-
                // byte. When the selection ALSO carries "extra" edges (each a
                // fin's outer boundary edge incident to a spine endpoint), route
                // to the multi-edge builder — the measured law for a triangle /
                // multi-edge selection through the isolated fin bundle. Two or
                // more ≥3-face edges, or any other richer selection, is
                // unmeasured → refuse before any mutation.
                uint[] selEdges; uint spine = ~0u; size_t spineCount = 0;
                foreach (i; 0 .. edges.length) {
                    if (!mask[i]) continue;
                    selEdges ~= cast(uint)i;
                    if (i < faceUse.length && faceUse[i] >= 3) {
                        spine = cast(uint)i; ++spineCount;
                    }
                }
                if (spineCount != 1) return 0;
                if (selEdges.length == 1)
                    return bevelIsolatedFinBundleSpine(spine, width);
                uint[] extras;
                foreach (e; selEdges) if (e != spine) extras ~= e;
                return bevelFinBundleSpineMultiEdge(spine, extras, width);
            }
        }

        bool[] qualifies = new bool[](edges.length);
        bool[] rimOnly   = new bool[](edges.length);
        size_t nQual = 0;
        foreach (i; 0 .. edges.length) {
            if (!mask[i]) continue;
            uint v0 = edges[i][0], v1 = edges[i][1];
            auto fp = edgeKey(v0, v1) in edgeFaces;
            if (fp is null) continue;
            if ((*fp)[0] < 0) continue;          // no incident face at all
            qualifies[i] = true;
            rimOnly[i]   = ((*fp)[1] < 0);       // exactly one incident face
            ++nQual;
        }
        if (nQual == 0) return 0;

        // Width-mode dihedral conversion (parity task, fuzz divergence D1).
        // In "width" mode the tool value is the true PERPENDICULAR bevel width
        // (the distance across the new chamfer strip), so the along-face corner
        // slide it produces on a crease of surface-opening angle θ is
        // `width / sin(θ/2)`, NOT the raw value. `edgeFactor[e] = 1/sin(θ/2)`
        // per selected edge; every along-face offset below multiplies the raw
        // `width` by this factor. In "inset" mode the array stays empty and
        // every offset is byte-identical to the pre-change path.
        //   θ = the surface-opening dihedral between the beveled edge's two
        //   incident faces (π ⇒ flat ⇒ factor 1; π/2 ⇒ cube corner ⇒ factor
        //   √2). With `c = clamp(n̂_A · n̂_B, -1, 1)` the OUTWARD face-normal
        //   cosine (`= −cos θ` for consistently wound faces),
        //   `sin(θ/2) = sqrt((1 + c)/2)`, so `factor = sqrt(2/(1 + c))`.
        //   Near-flat (c→1) ⇒ factor→1 (a flat crease's width IS its slide);
        //   a near-closed crease (c→−1, θ→0) is clamped so the slide stays
        //   finite. A boundary/rim edge (one incident face) has no dihedral and
        //   keeps factor 1.
        float[] edgeFactor;
        if (widthMode) {
            edgeFactor = new float[](edges.length);
            edgeFactor[] = 1.0f;
            foreach (i; 0 .. edges.length) {
                if (!qualifies[i] || rimOnly[i]) continue;
                auto fp = edgeKey(edges[i][0], edges[i][1]) in edgeFaces;
                if (fp is null || (*fp)[0] < 0 || (*fp)[1] < 0) continue;
                immutable Vec3 nA = faceNormal(cast(uint)(*fp)[0]);
                immutable Vec3 nB = faceNormal(cast(uint)(*fp)[1]);
                float c = dot(nA, nB);
                if (c >  1.0f) c =  1.0f;
                if (c < -1.0f) c = -1.0f;
                immutable float sinHalf2 = (1.0f + c) * 0.5f;   // sin²(θ/2)
                // Clamp a near-closed crease (sinHalf2 → 0) so the factor
                // stays finite (≤ 1000); near-flat needs no clamp (→ 1).
                immutable float s = sinHalf2 > 1e-6f ? sqrt(sinHalf2) : 1e-3f;
                edgeFactor[i] = 1.0f / s;
            }
        }

        // --- Per-corner map carry (task 0697) ------------------------------
        // The chamfer strip is WHY mechanism (c) grew a per-CORNER source: its
        // two sides come from the two faces the beveled edge separated, so one
        // source face per new FACE cannot describe it — resolving the whole
        // strip against one side would put the other side's corners in the wrong
        // island (silent on a mesh with no seam, wrong on one with).
        //
        // What resolves, and what deliberately does not:
        //   * every SLIDE corner is a point ON an original edge ⇒ the ordinary
        //     two-source blend, in the island of the face reading it (frozen:
        //     `edge_bevel_offset02/04`, `edge_bevel_nonuniform`);
        //   * a MITER corner (both bordering edges beveled) is inside the face,
        //     not on any edge, and no capture measures it ⇒ left at zero rather
        //     than guessed;
        //   * a rounded profile's arc points and the junction/Gregory patches
        //     are likewise off every original edge ⇒ zero. `srcByNewFace` is
        //     consulted by index and DEFAULTS to "no source", so a face emitted
        //     by a path that does not register one drops to that honest zero
        //     instead of inheriting a neighbour's island.
        const bool remapUvB = hasPolyVertexMap();
        uint[][] oldFacesB;
        if (remapUvB) {
            oldFacesB.reserve(faces.length);
            foreach (ref f; faces) oldFacesB ~= f.dup;
        }
        const uint[] oldFaceLoopB = remapUvB ? captureFaceLoop() : null;
        PolyVertexBlend[uint] vertBlendB;   // new vertex → blend of ORIGINALS
        uint[][size_t]        srcByNewFace; // index in `newFaces` → per-corner source

        // Step 2: affected vertices = endpoints of any qualifying edge.
        bool[] affected = new bool[](vertices.length);
        foreach (i; 0 .. edges.length) {
            if (!qualifies[i]) continue;
            affected[edges[i][0]] = true;
            affected[edges[i][1]] = true;
        }

        // Safety preflight. Two supported fan shapes reach the per-vertex pass
        // below: CLOSED (interior vertex, nE == d) and OPEN (boundary vertex,
        // nE == d + 1 — `VertexEdgeRange` anchors at the open start of the fan
        // and emits one extra rim edge). In both, face f_k is bordered by edge
        // slots k and k+1; only the closed fan wraps.
        foreach (V; 0 .. cast(uint)vertices.length) {
            if (V >= affected.length || !affected[V]) continue;
            size_t d = 0;
            foreach (fi; facesAroundVertex(V)) ++d;
            bool[] fanSelected;
            foreach (ei; edgesAroundVertex(V))
                fanSelected ~= (ei < qualifies.length && qualifies[ei]);
            immutable bool openFan = (fanSelected.length == d + 1);
            // Malformed fan stays on the existing per-span silent-skip path
            // below; the tests here need a well-formed closed or open fan.
            if (!openFan && fanSelected.length != d) continue;
            size_t K = 0;
            foreach (s; fanSelected) if (s) ++K;
            if (K == 0 || (!openFan && K == d)) continue; // untouched, or a full hub

            // The partial-notch `keep V` guard that used to live here is
            // GONE (task 0439, Decision A/C, doc/edge_bevel_freeend_cap_plan.md):
            // every both-unselected face now gets an unconditional two-slide
            // cut, and the resulting ring of corners is capped (Decision B,
            // per-vertex pass below). The one shape that STAYS refused is a
            // cap on a BOUNDARY (open-fan) vertex: its corner chain
            // terminates on the two rim edges instead of closing into a
            // ring, and no reference dump exists for capping it anyway
            // (§A-5). `ringLen` mirrors the per-vertex ring-collection rule
            // (Decision B) but is computed here from `fanSelected` alone,
            // before `cornerAtVF` exists: one entry per unselected slot,
            // plus one per face whose two bordering edges are both selected
            // (a miter).
            if (openFan) {
                immutable size_t nSlots = fanSelected.length;
                size_t ringLen = 0;
                foreach (k; 0 .. nSlots) if (!fanSelected[k]) ++ringLen;
                foreach (k; 0 .. d) {
                    immutable size_t kr = k + 1; // linear on an open fan, no wrap
                    if (fanSelected[k] && fanSelected[kr]) ++ringLen;
                }
                if (ringLen >= 3) return 0;
            }
        }

        // Overshoot guard: a SLIDE corner cannot travel past the far end of
        // its non-bevel neighbor edge, so `width` is capped PER-DIRECTION —
        // per `(vertex, unselected-neighbour-edge)` pair, never globally —
        // to that edge's own length. Reference-measured, bit-exact (task
        // 0436, `toolcards/edge.bevel/clamp_findings.md`): Case B's `v6` has
        // two directions in different clamp states within a single op at a
        // single width, which directly refutes a global-minimum clamp.
        //
        // Landing exactly on the far vertex makes the new corner coincide
        // with an EXISTING mesh vertex — the reference does NOT weld that
        // pair. It leaves two separate vertex records at the same position
        // (Case A, width == farLen: 10v stays 10v, not 9v; the resulting
        // zero-area chamfer-strip face is left in place, not dropped). A
        // narrower, independently-measured rule DOES merge two *new*
        // corners with each other — regardless of whether either was
        // clamp-saturated — when they become corners of the SAME rebuilt
        // face; see the pass after the topology rebuild below.
        float clampedWidth(uint from, uint to) {
            const float farLen = (vertices[to] - vertices[from]).length;
            if (farLen > 1e-9f && width >= farLen) return farLen;
            return width;
        }

        pragma(inline, true) static ulong vfKey(uint v, uint f) {
            return (cast(ulong)v << 32) | cast(ulong)f;
        }

        // Per-(vertex,face) corner resolution.  Keep the construction
        // provenance with the L0 vertex: round-profile selection must not
        // rediscover it from a floating-point radius heuristic.
        enum CornerKind : ubyte { Slide, Miter }
        struct CornerInfo {
            uint vert;
            CornerKind kind;
            bool clamped;
            uint selectedDegree; // K at this source vertex, before rebuilding
            // Whether this corner sits at a GENUINE closed full-ring hub
            // (`!openFan && K == d`). Load-bearing for task 0454's N≥4 rail
            // gate: `selectedDegree` (== K) is NOT tied to full-hub-ness — a
            // valence-5 vertex with a partial K=4 selection carries
            // `selectedDegree==4` yet is a free-end/partial fan, NOT a hub, and
            // must keep the shipped slerp rail (no boundary-Bézier ground truth
            // there). Only `isFullHub && selectedDegree>=4` switches to the
            // finding-(F) Bézier rail.
            bool isFullHub;
            Vec3 dir;
        }
        CornerInfo[ulong] cornerAtVF;

        // face_index → (old_vert → new_verts[]), same substitution-table
        // idiom as bevelVerticesByMask / extrudeFacesByMask. A face can now
        // legitimately receive substitution entries for MULTIPLE distinct
        // vertices (e.g. a loop's shared "inside" face gets one per corner).
        VertSub[][uint] faceSubs;

        // Full-ring ("hub cap") bookkeeping: vertex → ordered miter-corner
        // ring (only populated when K == valence, i.e. every incident edge
        // of V is selected — Phase 2's N-way junction).
        uint[][uint] hubCapRing;
        uint[uint]   hubCapSrc;

        // Free-end / partial-fan cap bookkeeping (task 0439): vertex → ring
        // of unselected-slot slide corners + both-selected-neighbours miter
        // corners, in fan order (only populated for `0 < K < nE` on a CLOSED
        // fan with a ring of ≥3 corners — Decision B). Since task 0449 this
        // ring IS fed into `addRailSupportConsumer` below, exactly like
        // `hubCapRing`: it is the ring's own "back face" that a bordering
        // rail was missing as its SECOND consumer (the reference's own cap
        // plugging the hole the free end cuts — capture-verified,
        // doc/edge_bevel_freeend_cap_roundlevel_plan.md Decision A). A rail
        // that clears the two-consumer fixed point rounds via `railInterior`
        // (the same reference-captured fillet law every other rail uses);
        // one that doesn't still degrades that span run to Round Level 0,
        // same as before. The cap's own INTERIOR tessellation at K >= 2
        // (a notch spanning 2+ selected slots) remains unclosed — only the
        // boundary arcs round — see Decision B in the same plan.
        uint[][uint] freeEndCapRing;
        uint[uint]   freeEndCapSrc;
        // Per-CORNER source face of that ring, parallel to it (task 0697) —
        // populated only when a per-corner map exists.
        uint[][uint] freeEndCapCornerSrc;

        // Round-Level ≥ 1 K==2 "narrow notch" cap interior tessellation
        // (parity task). A closed-fan vertex with exactly two selected edges
        // whose two gaps have widths {1, 2} produces a TRIANGLE free-end cap:
        // the width-1 gap's single slide is the APEX where the two selected
        // edges' hub arcs meet, and the width-2 gap's two slides are the base
        // edge. At L ≥ 1 the reference subdivides that triangle into a
        // (2·L)×(2·L) grid (4·L² faces) whose boundary reuses the two hub arcs
        // + a base arc about the source vertex, and whose interior follows a
        // recursive circular-fillet law (pivot = the apex, sweep between the
        // two hub-arc samples) — decoded and verified BIT-EXACT against the
        // reference dumps at L1–L3. Populated per qualifying vertex, consumed
        // once in the emission tail; empty for every other bevel (including
        // any WIDER notch — a gap ≥ 3 routes the interior through a different
        // reference builder whose control mapping is not yet decoded, so those
        // caps intentionally stay flat).
        struct NotchCapPlan {
            bool valid;
            uint apex;              // shared corner slide (width-1 gap) — hub-arc meet
            uint gapEndL, gapEndR;  // the two ends of the width-2 base gap
        }
        NotchCapPlan[uint] notchCapPlans;

        // Round Level rail registry.  Identity is the unordered pair of L0
        // endpoints; callers receive the stored chain in their own winding.
        // A RailSpec still records its corner-construction class (below), but
        // that is now used only for the shared-endpoint provenance assert in
        // `registerRail` — NOT to pick a profile: every rail materializes
        // through the ONE reference-captured law in `railInterior` (K1 / bare
        // end / K2 miter all verified bit-exact; a K3+ junction's central hub
        // vertex + fan remains the sole unresolved reference gap).
        enum RailProfile : ubyte { VerifiedK1Arc, LocalAnalyticUnverified }
        struct RailSpec {
            uint a, b; // canonical a < b
            Vec3 center;
            CornerKind aKind, bKind;
            bool aClamped, bClamped;
            uint aSelectedDegree, bSelectedDegree;
            RailProfile profile;
            uint supportConsumers;
            uint stripConsumers;
            bool approved;
            Vec3 arcCenter;      // explicit fillet centre for a junction rail
            bool hasArcCenter;   // ↑ valid (else use the per-vertex fillet centre)
            bool rimRail;        // centre vertex sits on an open (boundary) fan
            // Task 0454/0456, widened to K3 by the K3-true-boundary-curve task.
            // Both fields below are computed for EVERY closed full-ring hub side
            // — `registerRail`'s gate is `isFullHub && selectedDegree >= 3` at
            // both corners, NOT `>= 4` (an earlier draft's N≥4-only wording
            // survived here for a while and was simply false; read the gate, not
            // this comment, if they ever disagree again). Two distinct
            // constructions live here (they were conflated in the dormant port):
            //   • RING internal net (finding F): `bezP1`/`bezP2` are the
            //     kappa-cubic-Bézier handles of side (a→b)'s boundary curve,
            //     pivoted at the OWN selected edge's slide point. Fed to
            //     `junctionRing` (N=3) and `junctionRingN` (N≥4) for HUB + the
            //     L≥2 Gregory ring SURFACE. This is still exactly correct —
            //     finding (F) verified it against the reference's internal
            //     control net.
            //   • Emitted RAIL vertex (finding I): the mesh rail vertex the
            //     reference actually writes is NOT the boundary-Bézier — it is
            //     the rail-position SLERP-plus-correction law
            //     pivoted on the TWO NEIGHBORING sides' slide points `jvA`/`jvB`
            //     (never the side's own). When `hubRail` is set, `railInterior`
            //     samples that law instead of the slerp arc, at K3 as well as
            //     N≥4 (`hasArcCenter`/slerp stays byte-identical for every
            //     non-hub rail, incl. partial-K≥4 free-end rails).
            Vec3 bezP1, bezP2;   // ring internal-net handles (finding F)
            Vec3 jvA, jvB;       // rail neighbor pivots, a→b (finding I)
            // `hubRail` = the hub gate AND both finding-(I) pivots are usable:
            // `(P0−P3).length > 1e-9 && (jA−jB).length > 1e-9`. `hasBez` = the
            // hub gate alone. So `hubRail` implies `hasBez`, never the reverse,
            // and the two differ ONLY on a degenerate hub. Read sites (grep them
            // before changing either — they are not interchangeable):
            //   • `hasBez`  — the N=3 ring branch's per-side gate.
            //   • `hubRail` — `railInterior`'s roundPos routing (`jvA`/`jvB` are
            //     read NOWHERE else), AND the N≥4 ring branch's per-side gate.
            // That last pairing is why the two ring branches admit different
            // rails: N≥4 rejects a hub whose ring inputs (poles + handles) are
            // fine but whose RAIL pivots coincide. Measured, unresolved, owned
            // by task 0707 — do not "harmonise" the two gates before it lands.
            bool hubRail;
            bool hasBez;         // bezP1/bezP2 computed (full hub, K≥3)
        }
        RailSpec[ulong] railSpecs;
        uint[][ulong] railInteriorMemo; // canonical pairKey(a,b), a<b → interiors in a→b order
        static ulong pairKey(uint a, uint b) {
            return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
        }
        // finding (F) boundary-Bézier handles for one N-way hub side: the
        // kappa-cubic-Bézier circular-arc approximation from corner `P0` to
        // corner `P3`, pivoted around `jv` (the shared selected edge's slide
        // point, NOT the junction vertex). Direct port of
        // `nway_hub_ring_ref.py::boundary_bezier`. `ok=false` on any
        // degeneracy (parallel radii, zero sweep) so the caller falls back to
        // the slerp rail + flat cap (compute-then-commit, no partial mutation).
        static void boundaryBezier(Vec3 P0, Vec3 P3, Vec3 jv,
                                   out Vec3 outP1, out Vec3 outP2, out bool ok) {
            import std.math : acos, tan, abs;
            ok = false;
            Vec3 uA = P0 - jv, uB = P3 - jv;
            immutable float lA0 = uA.length, lB0 = uB.length;
            if (lA0 < 1e-9f || lB0 < 1e-9f) return;
            uA = uA / lA0; uB = uB / lB0;
            Vec3 nrm = cross(uA, uB);
            immutable float nlen = nrm.length;
            if (nlen < 1e-9f) return;              // uA ∥ uB (collinear pivot)
            nrm = nrm / nlen;
            immutable Vec3 d1 = cross(uA, nrm);
            immutable Vec3 d2 = cross(nrm, uB);
            immutable float denom = dot(cross(d1, d2), nrm);
            if (abs(denom) < 1e-12f) return;
            immutable float t = dot(cross(P3 - P0, d2), nrm) / denom;
            immutable Vec3 C = P0 + d1 * t;
            immutable Vec3 rA = P0 - C, rB = P3 - C;
            immutable float lenA = rA.length, lenB = rB.length;
            if (lenA < 1e-9f || lenB < 1e-9f) return;
            float cosO = dot(rA, rB) / (lenA * lenB);
            if (cosO >  1.0f) cosO =  1.0f;
            if (cosO < -1.0f) cosO = -1.0f;
            immutable float Omega = acos(cosO);
            if (Omega < 1e-6f) return;
            immutable float kappa = (4.0f / 3.0f) * tan(Omega / 4.0f);
            immutable Vec3 uAc = rA / lenA, uBc = rB / lenB;
            Vec3 t0 = uBc - uAc * dot(uBc, uAc);
            immutable float t0l = t0.length;
            if (t0l < 1e-9f) return;
            t0 = t0 / t0l;
            Vec3 t3 = uAc - uBc * dot(uAc, uBc);
            immutable float t3l = t3.length;
            if (t3l < 1e-9f) return;
            t3 = t3 / t3l;
            outP1 = P0 + t0 * (kappa * lenA);
            outP2 = P3 + t3 * (kappa * lenB);
            ok = true;
        }
        // finding (I) emitted-rail law — the actual mesh rail vertex a Round
        // Level≥1 N-way junction writes, distinct from the internal Gregory net's
        // boundary Bézier above (which misses it by ~0.01–0.03). Direct port of
        // `nway_hub_ring_ref.py::_round_center`/`_round_pos0`/`_round_pos`,
        // recovered via rr/gdb tracing of the reference's own fillet-center /
        // rail-position builders. `roundCenter` = the ALREADY-SHIPPED K1/K2 two-tangent-line
        // fillet centre reused verbatim (valid because |jv−V|==width for both
        // pivots).
        static Vec3 roundCenter(Vec3 p0, Vec3 p1, Vec3 V) {
            import std.math : abs;
            immutable Vec3 dA = V - p0, dB = V - p1;
            immutable float w2 = dot(dA, dA);
            immutable float denom = w2 + dot(dA, dB);
            immutable float k = (abs(denom) > 1e-12f) ? (w2 / denom) : 1.0f;
            return V - (dA + dB) * k;
        }
        // One-sided rail sample: forward from `a1` towards `a2` by `t`, with the
        // `deltaA`/`deltaB` correction blended by sin(rotAngle) (NOT linear-t —
        // the L1-only formula's coincidence at t=0.5 does not generalize, see
        // finding (I) follow-up).
        static Vec3 roundPos0(Vec3 a1, Vec3 a2, Vec3 a3, Vec3 a4, Vec3 V, float t) {
            import std.math : acos, sin;
            immutable Vec3 axisR = cross(V - a2, V - a1);
            immutable float la1 = (V - a1).length, la2 = (V - a2).length;
            // Degenerate frame: the two neighbor pivots are (near-)collinear with
            // V — the arc plane is undefined (sin(angle) < 1e-3). This happens at
            // a hub with two antipodal rays (e.g. an interior cube edge running
            // straight through the junction): the two rails PERPENDICULAR to that
            // edge take the antipodal pivots. The reference falls back to LINEAR
            // interpolation between the corners here — the same degenerate
            // fallback the K1 free-end fillet takes at a planar valence-4 ring
            // (`mixed_junction_freeend_findings.md` §e) and the slerp path takes
            // at a 180° sweep. Endpoints stay bit-exact (t=0→a3, t=1→a4).
            if (la1 < 1e-12f || la2 < 1e-12f || axisR.length < 1e-3f * la1 * la2)
                return a3 * (1.0f - t) + a4 * t;
            immutable Vec3 C = roundCenter(a1, a2, V);
            immutable Vec3 axis = axisR;
            immutable Vec3 rA = a1 - C, rB = a2 - C;
            immutable float lA = rA.length, lB = rB.length;
            float cosO = (lA > 1e-12f && lB > 1e-12f) ? dot(rA, rB) / (lA * lB) : 1.0f;
            if (cosO >  1.0f) cosO =  1.0f;
            if (cosO < -1.0f) cosO = -1.0f;
            immutable float Omega = acos(cosO);
            immutable float rotAngle = t * Omega;
            // `axis` here is the raw cross product — `safeNormalize` at the call
            // boundary is what math.rotateAboutAxis's unit contract requires
            // (the guard at :611 already rejected the near-zero case).
            immutable Vec3 virtMid = C + rotateAboutAxis(rA, safeNormalize(axis), rotAngle);
            immutable Vec3 deltaA = a3 - a1, deltaB = a4 - a2;
            immutable float sinR = sin(rotAngle);
            return virtMid + deltaA * (1.0f - sinR) + deltaB * sinR;
        }
        // Full rail-interior sample at parameter `t` (t=j/(2L)): blends the
        // forward call (from `jvPrev`/`cornerK` at t) with the backward call
        // (from `jvNext`/`cornerK1` at 1−t, all four swapped) by (1−t, t).
        // `roundPos` is symmetric under the full endpoint swap with t→1−t, so
        // canonical a→b sampling is orientation-independent (matches the slerp
        // path's a<b reversal contract in `railInterior`).
        static Vec3 roundPos(Vec3 jvPrev, Vec3 jvNext, Vec3 cornerK, Vec3 cornerK1,
                             Vec3 V, float t) {
            immutable Vec3 f1 = roundPos0(jvPrev, jvNext, cornerK, cornerK1, V, t);
            immutable Vec3 f2 = roundPos0(jvNext, jvPrev, cornerK1, cornerK, V, 1.0f - t);
            return f1 * (1.0f - t) + f2 * t;
        }
        // The neighbor of `Vv` inside face `fi` that is NOT `farV` — i.e. the
        // "other" edge of `fi` at `Vv` besides the rail edge (Vv,farV). Its slide
        // point is the finding-(I) pivot the ADJACENT side contributes to this
        // rail (never the rail's own edge). Used to build `jvA`/`jvB`.
        uint otherFaceNeighbor(uint Vv, uint farV, uint fi) {
            auto ring = faces[fi];
            immutable size_t n = ring.length;
            foreach (j; 0 .. n) {
                if (ring[j] != Vv) continue;
                immutable uint pr = ring[(j + n - 1) % n];
                immutable uint nx = ring[(j + 1) % n];
                return (pr == farV) ? nx : pr;
            }
            return farV;
        }
        // A rail whose centre vertex is on a rim is bounded by the chamfer
        // strip on one side and by the OPEN boundary on the other, so it has
        // one consumer where an interior rail has two (strip + back face).
        bool isOpenFanVertex(uint V) {
            size_t nf = 0, ne = 0;
            foreach (fi; facesAroundVertex(V)) ++nf;
            foreach (ei; edgesAroundVertex(V)) ++ne;
            return ne == nf + 1;
        }
        void registerRail(CornerInfo left, CornerInfo right, Vec3 center,
                          uint centerVert, Vec3 farEnd, Vec3 jvLeft, Vec3 jvRight) {
            immutable ulong key = pairKey(left.vert, right.vert);
            immutable bool forward = left.vert < right.vert;
            // Junction pairwise rail (both corners MITER at a K==valence
            // junction, selectedDegree≥3): the boundary arc between two hub
            // poles is NOT the per-vertex fillet — that degenerates (the two
            // poles are ~antipodal about the fillet centre, so Ω→180° collapses
            // to a straight chord, e.g. the (0.45,…) linear midpoint instead of
            // the reference (0.4707,…) bisector). The reference arc is a geodesic
            // on the corner-rounding sphere centred at V − width·Σn̂ (Σ of the
            // junction's unit face normals) — verified bit-exact on the cube
            // (task 0435). Bare-end / K1 / K2 rails keep the per-vertex fillet.
            immutable bool useHub =
                left.kind == CornerKind.Miter && right.kind == CornerKind.Miter &&
                left.selectedDegree >= 3 && right.selectedDegree >= 3;
            Vec3 hubC = Vec3(0, 0, 0);
            if (useHub) {
                Vec3 sn = Vec3(0, 0, 0);
                foreach (fi; facesAroundVertex(centerVert))
                    sn = sn + safeNormalize(faceNormal(cast(uint)fi));
                hubC = center - sn * width;
            }
            // Full-ring hub rail. Two constructions, both fed by raw geometry:
            //   • RING net (finding F): boundary-Bézier handles pivoted at THIS
            //     rail's OWN selected-edge slide point `ownJv` (= slide of the
            //     shared edge (V,farEnd) this rail runs along). This is the TRUE
            //     boundary curve of the ring side — the internal Gregory net's own
            //     P0/P1/P2. Computed for EVERY full hub, K3 (`junctionRing`) as
            //     well as N≥4 (`junctionRingN`): both builders take these handles
            //     as their boundary-curve input. (The K3 path formerly re-fit each
            //     side's boundary Bézier from a circumcircle through
            //     pole/rail-mid/pole — correct only at the 90° cube corner, where
            //     the emitted rail-mid happens to coincide with the true boundary
            //     midpoint; wrong for any non-cube K3 hub, task 0435 follow-up.)
            //   • Emitted RAIL (finding I): `roundPos`, pivoted on the TWO
            //     NEIGHBORING sides' slide points `jvA`/`jvB` (the other edge of
            //     each flanking face — passed in as `jvLeft`/`jvRight`, never
            //     this rail's own edge). This is the vertex that lands in the
            //     mesh; sampled in `railInterior`. It is what the reference emits
            //     at EVERY full hub, K3 included — the emitted rail-mid is NOT the
            //     corner-rounding-sphere slerp (that only coincides with `roundPos`
            //     at the 90° cube corner; for a non-cube K3 the slerp diverges by
            //     ~0.03 while `roundPos` matches to the float32-mesh floor).
            //
            // Both constructions (`bez1`/`bez2`+`hasBez` and `jvA`/`jvB`+`hubRail`)
            // are computed for EVERY full ring hub, `isFullHub && selectedDegree≥3`
            // at BOTH corners. A partial K≥4 at a higher-valence vertex (free-end
            // path, isFullHub false) is EXCLUDED and keeps the plain slerp rail.
            // Both corners of a rail are at the same source vertex, so these flags
            // are identical across left/right; checking both is belt-and-
            // suspenders. NOTE: `hubRail` does not pick the RING EVALUATOR — that
            // is `ring_.length`, so K3 always takes its own N=3 fast path
            // (`junctionRing`) and never the N≥4 sibling's odd-N center-normal /
            // corner-move corrections (`junctionRingN`). What `hubRail` does gate
            // is (a) `railInterior`'s roundPos routing, at K3 as well as N≥4, and
            // (b) whether the N≥4 ring branch accepts the side at all. The N=3
            // ring branch accepts on `hasBez` instead — a REAL difference on a
            // degenerate hub, see the RailSpec field comment and task 0707.
            Vec3 bez1 = Vec3(0, 0, 0), bez2 = Vec3(0, 0, 0);
            Vec3 jA = Vec3(0, 0, 0), jB = Vec3(0, 0, 0);
            bool hubRail = false;
            bool hasBez = false;
            if (left.isFullHub && right.isFullHub &&
                left.selectedDegree >= 3 && right.selectedDegree >= 3) {
                immutable uint aV = forward ? left.vert : right.vert;
                immutable uint bV = forward ? right.vert : left.vert;
                immutable Vec3 P0 = vertices[aV], P3 = vertices[bV];
                immutable Vec3 ownJv = center + safeNormalize(farEnd - center) * width;
                bool bezOk = false;
                boundaryBezier(P0, P3, ownJv, bez1, bez2, bezOk);
                if (!bezOk) {
                    // Flat / degenerate ring side — e.g. a straight internal
                    // split edge whose two flanking faces are COPLANAR (180°
                    // dihedral, no rounding). boundaryBezier refuses the zero-
                    // sweep arc; the boundary curve is then just the straight
                    // chord, so use its LINEAR Bézier handles. The ring builders
                    // then treat the side as flat (R_i = midpoint) with no seam.
                    // Real at the mixed-K4 junction (2 of its 4 rays are flat
                    // internal cube-face split edges).
                    bez1 = P0 + (P3 - P0) * (1.0f / 3.0f);
                    bez2 = P0 + (P3 - P0) * (2.0f / 3.0f);
                }
                hasBez = true;
                // Orient the neighbor pivots to the canonical a→b endpoints so
                // `jA` pairs with corner `a` (=vertices[aV]) in `roundPos`.
                jA = forward ? jvLeft : jvRight;
                jB = forward ? jvRight : jvLeft;
                // hubRail gates the finding-(I) rail law (compute-then-commit).
                // Distinct corners and distinct neighbor pivots are all that is
                // required — a flat side (linear handles) or an ANTIPODAL pivot
                // pair (jA≠jB but collinear through V) are both handled above, NOT
                // refused; only a truly coincident pair is rejected here, which
                // ALSO drops an N≥4 hub to the flat N-gon (that branch reuses this
                // flag as its ring gate). A K3 hub does not drop — its ring branch
                // gates on `hasBez`. Both outcomes are reachable and neither is
                // pinned by a reference capture; task 0707 owns the choice.
                hubRail = (P0 - P3).length > 1e-9f && (jA - jB).length > 1e-9f;
            }
            RailSpec spec = RailSpec(
                forward ? left.vert : right.vert, forward ? right.vert : left.vert,
                center,
                forward ? left.kind : right.kind, forward ? right.kind : left.kind,
                forward ? left.clamped : right.clamped, forward ? right.clamped : left.clamped,
                forward ? left.selectedDegree : right.selectedDegree,
                forward ? right.selectedDegree : left.selectedDegree,
                (left.kind == CornerKind.Slide && right.kind == CornerKind.Slide &&
                 !left.clamped && !right.clamped &&
                 left.selectedDegree == 1 && right.selectedDegree == 1)
                    ? RailProfile.VerifiedK1Arc : RailProfile.LocalAnalyticUnverified,
                0, 0, false,
                hubC, useHub,
                isOpenFanVertex(centerVert),
                bez1, bez2, jA, jB, hubRail, hasBez);
            if (auto prior = key in railSpecs) {
                assert((prior.center - center).length < 1e-5f &&
                    prior.profile == spec.profile &&
                    prior.aKind == spec.aKind && prior.bKind == spec.bKind &&
                    prior.aClamped == spec.aClamped && prior.bClamped == spec.bClamped &&
                    prior.aSelectedDegree == spec.aSelectedDegree &&
                    prior.bSelectedDegree == spec.bSelectedDegree,
                    "edge bevel rail endpoint pair has incompatible provenance");
            } else {
                railSpecs[key] = spec;
            }
        }
        void addRailSupportConsumer(uint a, uint b) {
            immutable ulong key = pairKey(a, b);
            if (auto spec = key in railSpecs) ++spec.supportConsumers;
        }
        uint[] railInterior(uint a, uint b) {
            import std.algorithm : reverse;
            import std.math : sin, acos, abs;
            immutable ulong key = pairKey(a, b);
            uint[] stored;
            if (auto p = key in railInteriorMemo) {
                stored = *p;
            } else {
                auto specP = key in railSpecs;
                assert(specP !is null && specP.approved,
                    "rounded edge bevel rail must be approved before materialization");
                immutable RailSpec spec = *specP;
                // Reference subdivides a rounded arc into 2·roundLevel equal-
                // angle segments (verified: isolated K1 at Round Level 3 has 5
                // interior points, not 7 — task 0435). 2·L equals 2^L only at
                // L≤2, which is why the old 1<<roundLevel matched there but
                // over-subdivided at L≥3.
                immutable int n = 2 * roundLevel;
                immutable uint lo = a < b ? a : b;
                immutable uint hi = a < b ? b : a;
                // Reference-captured round-rail law (task 0435, edge.bevel spec
                // behavior.miter_rail_law + generalization_findings). The rounded
                // cross-section is a TRUE circular fillet tangent to the two
                // adjacent faces, whose radius AND sweep are set by the ACTUAL
                // dihedral — not a fixed 90° quarter-turn (that was a cube-only
                // degeneracy). Reconstructed from the reference's own builders
                // (fillet-center = two-tangent-line intersection; rail-position =
                // angular SLERP):
                //   dA = V - E_A,  dB = V - E_B
                //   k  = width² / (width² + dA·dB)      // = 1 at a 90° corner
                //   C  = V - k·(dA + dB)                // fillet center
                //   Ω  = angle(E_A - C, E_B - C) = 180° - dihedral
                //   Q(f) = C + slerp(E_A - C, E_B - C, f),  f = t/n
                // f=0 → E_A and f=1 → E_B exactly (endpoints bit-exact, manifold
                // safe). At a 90° dihedral (dA·dB=0 ⇒ k=1, Ω=90°) this reduces
                // EXACTLY to the earlier V - dA(1-sinθ) - dB(1-cosθ) form, so the
                // axis-aligned cube stays bit-exact while non-90° edges now round
                // correctly. Swapping lo/hi mirrors the sweep, which the a<b
                // reversal below undoes, so the emitted point set is orientation-
                // independent. (K3+ junction hub magnitude / Gregory-patch ring
                // remain a separate reference gap — see the doc comment above.)
                immutable Vec3 EA = vertices[lo];
                immutable Vec3 EB = vertices[hi];
                immutable Vec3 dA = spec.center - EA;   // V - E_A
                immutable Vec3 dB = spec.center - EB;   // V - E_B
                immutable float w2    = width * width;
                immutable float denom = w2 + dot(dA, dB);
                immutable float k     = (abs(denom) > 1e-12f) ? (w2 / denom) : 1.0f;
                // Junction pairwise rail: geodesic on the corner-rounding sphere
                // (centre V − width·Σn̂, set at registerRail) — the per-vertex
                // fillet centre degenerates for near-antipodal hub poles.
                immutable Vec3  C     = spec.hasArcCenter
                    ? spec.arcCenter : (spec.center - (dA + dB) * k);
                immutable Vec3  sA    = EA - C;         // spoke to E_A
                immutable Vec3  sB    = EB - C;         // spoke to E_B
                immutable float lenA  = sA.length, lenB = sB.length;
                float cosO = (lenA > 1e-12f && lenB > 1e-12f)
                    ? dot(sA, sB) / (lenA * lenB) : 1.0f;
                if (cosO >  1.0f) cosO =  1.0f;
                if (cosO < -1.0f) cosO = -1.0f;
                immutable float Omega = acos(cosO);
                immutable float sinO  = sin(Omega);
                // Overshoot-clamp rail. When a bare-end K1 slide overshoots its
                // neighbour edge (width > farLen), the emitted corner stops AT the
                // far vertex (clamped), but the reference still shapes the rounded
                // rail from the UNCLAMPED offset: the arc centre & sweep come from
                // the raw-width pivots (V + width·dir), while the endpoints stay the
                // clamped slides. That is exactly the finding-(I) rail law the hub
                // path uses — raw pivots + clamped corners through `roundPos`, whose
                // delta term shifts the raw arc onto the clamped endpoints.
                //
                // Byte-identity for every currently-passing rail comes from the GATE,
                // not from a reduction: `clampRail` requires `aClamped || bClamped`, so
                // a non-clamped K1 slide-slide rail fails the gate and takes the
                // unchanged slerp branch below verbatim. (On equal pivots `roundPos`
                // and that slerp trace the same arc but via different float ops —
                // Rodrigues rotation vs sin-weighted spoke blend — so they agree only
                // to a few ULP, NOT bit-for-bit; do not rely on a bit-exact reduction.
                // It is moot because the gate never routes a non-clamped rail here.)
                // Verified against the reference on symmetric and asymmetric-dihedral
                // BOTH-clamped bare ends; a one-side-only clamp is a documented
                // best-effort approximation (no reference test covers it).
                immutable bool clampRail =
                    spec.aKind == CornerKind.Slide && spec.bKind == CornerKind.Slide &&
                    spec.aSelectedDegree == 1 && spec.bSelectedDegree == 1 &&
                    !spec.hasArcCenter && (spec.aClamped || spec.bClamped);
                immutable Vec3 pivA = clampRail
                    ? spec.center + safeNormalize(EA - spec.center) * width : EA;
                immutable Vec3 pivB = clampRail
                    ? spec.center + safeNormalize(EB - spec.center) * width : EB;
                Vec3[] pts = new Vec3[](n + 1);
                foreach (t; 0 .. n + 1) {
                    immutable float f = cast(float)t / cast(float)n;
                    if (spec.hubRail) {
                        // Task 0456 — genuine N≥4 hub rail: the finding-(I)
                        // emitted-rail law `roundPos`, sampled at t = j/(2L).
                        // Pivots `jvA`/`jvB` (the two NEIGHBORING sides' slides,
                        // stored a→b at registerRail) and the corner endpoints
                        // EA/EB about V = spec.center. f=0→EA, f=1→EB exactly
                        // (endpoints bit-exact, manifold safe). The Gregory ring
                        // REUSES these very rail vertices for its u=0/v=0 border
                        // (gv), so rail and ring share the boundary — no seam.
                        // Reached only by a closed full hub; every other rail
                        // keeps the slerp path below byte-identical.
                        pts[t] = roundPos(spec.jvA, spec.jvB, EA, EB, spec.center, f);
                    } else if (clampRail) {
                        // Overshoot-clamped bare-end rail: raw-width pivots +
                        // clamped corners (see the block above). f=0→EA, f=1→EB
                        // exactly, so the arc stays welded to the emitted corners.
                        pts[t] = roundPos(pivA, pivB, EA, EB, spec.center, f);
                    } else if (sinO < 1e-6f) {
                        // Degenerate (collinear / 180° sweep): straight chord.
                        pts[t] = EA * (1.0f - f) + EB * f;
                    } else {
                        immutable float wa = sin((1.0f - f) * Omega) / sinO;
                        immutable float wb = sin(f * Omega) / sinO;
                        pts[t] = C + sA * wa + sB * wb;
                    }
                }
                uint[] interior = new uint[](n - 1);
                foreach (t; 1 .. n) interior[t - 1] = addVertex(pts[t]);
                railInteriorMemo[key] = interior;
                stored = interior;
            }
            if (a < b) return stored;
            auto rev = stored.dup;
            reverse(rev);
            return rev;
        }

        // Sin-weighted circular slerp about a centre `C`, sweeping the short
        // way from `PA` to `PB` at parameter `f` — the SAME arc law
        // `railInterior` samples for a rounded rail (radius is interpolated
        // when |PA-C| != |PB-C|). Reused for the narrow-notch cap's base-gap
        // arc (centre = the source vertex) and its recursive interior fillet
        // (centre = the apex corner). Parity task.
        Vec3 slerpAbout(Vec3 C, Vec3 PA, Vec3 PB, float f) {
            import std.math : sin, acos;
            immutable Vec3 rA = PA - C, rB = PB - C;
            immutable float lA = rA.length, lB = rB.length;
            float co = (lA > 1e-12f && lB > 1e-12f) ? dot(rA, rB) / (lA * lB) : 1.0f;
            if (co >  1.0f) co =  1.0f;
            if (co < -1.0f) co = -1.0f;
            immutable float Om = acos(co), sO = sin(Om);
            if (sO < 1e-6f) return C + rA * (1.0f - f) + rB * f;
            immutable float wa = sin((1.0f - f) * Om) / sO, wb = sin(f * Om) / sO;
            return C + rA * wa + rB * wb;
        }

        foreach (V; 0 .. cast(uint)vertices.length) {
            if (V >= affected.length || !affected[V]) continue;

            uint[] vFaces, vEdges, vNbrs;
            foreach (fi; facesAroundVertex(V)) vFaces ~= fi;
            foreach (ei; edgesAroundVertex(V)) vEdges ~= ei;
            immutable int d  = cast(int)vFaces.length;
            immutable int nE = cast(int)vEdges.length;
            // Two supported fan shapes, both walked by the SAME convention:
            // face f_k is bordered by edge slots k and k+1.
            //   CLOSED (interior vertex): nE == d, slot d wraps to slot 0.
            //   OPEN   (boundary vertex): nE == d + 1 — `VertexEdgeRange`
            //     anchors at the open start of the fan and emits one extra
            //     edge at the end, so the slots run e_0 .. e_d with NO wrap
            //     (e_0 and e_d are the two rim edges).
            // Anything else is a malformed / non-manifold fan and is skipped.
            immutable bool openFan = (nE == d + 1);

            // ---- Single-incident-face rim corner (open-mesh boundary edge) ----
            // A vertex with exactly ONE incident face (d == 1) is a pure open-
            // mesh boundary corner. The generic fan pass below refuses it
            // (d < 2 guard), yet the reference DOES bevel a boundary edge
            // terminating there: a lone selected edge at a 1-face vertex is
            // necessarily a RIM edge (an edge of a 1-face vertex can belong to
            // no other face), and no bridge quad is created (0 new faces). The
            // reference splits the beveled edge's two endpoints ASYMMETRICALLY:
            // within the bordering face's OWN winding the edge runs P0 -> P1;
            // the SECOND endpoint P1 gains two new corners — a slide along the
            // beveled edge toward P0, then a slide along its other boundary
            // edge — while the FIRST endpoint P0 gains only its other-boundary-
            // edge slide (net +1 vertex per rim-edge bevel, vs. +2 for a closed
            // isolated edge). Measured bit-exact on two independent open
            // layouts (a single open quad and a 2x1 open grid) and on the
            // cross-component clamp cases: only the "other-edge" slide takes the
            // per-direction overshoot clamp; the beveled-edge slide is never
            // clamped. Closed and d>=2 (boundary-with-2-faces) fans are
            // untouched — they still flow through the generic pass below.
            if (openFan && d == 1 && vertexFanOrdered(V)) {
                immutable uint fRim = vFaces[0];
                auto rimRing = faces[fRim];
                immutable size_t rimN = rimRing.length;
                size_t jRim = size_t.max;
                foreach (t; 0 .. rimN) if (rimRing[t] == V) { jRim = t; break; }
                if (jRim == size_t.max) continue; // V absent from its own face (malformed)
                immutable uint predV = rimRing[(jRim + rimN - 1) % rimN];
                immutable uint succV = rimRing[(jRim + 1) % rimN];
                // Resolve each bordering edge's selection through edgeIndexMap
                // (order-independent key) rather than the fan-walk, so a
                // malformed fan that yields a foreign edge can never reach
                // edgeOtherVertex here.
                bool selectedEdge(uint a, uint b) {
                    auto p = edgeKey(a, b) in edgeIndexMap;
                    return p !is null && *p < qualifies.length && qualifies[*p];
                }
                immutable bool predSel = selectedEdge(V, predV);
                immutable bool succSel = selectedEdge(V, succV);
                // Exactly one bordering edge selected (K == 1) is the measured
                // shape. Anything else (both edges beveled, or a degenerate
                // ring) is unmeasured — fall through to the generic guard,
                // which declines it. No extrapolation.
                if (predSel != succSel) {
                    immutable Vec3 vp = vertices[V];
                    if (succSel) {
                        // V = P0 (first, edge V->succ is the beveled one): a
                        // single slide along the UNSELECTED predecessor edge.
                        immutable Vec3 dir = safeNormalize(vertices[predV] - vp);
                        immutable float w = clampedWidth(V, predV);
                        immutable uint nv = addVertex(vp + dir * w);
                        cornerAtVF[vfKey(V, fRim)] = CornerInfo(
                            nv, CornerKind.Slide, w < width, 1u, false, dir);
                        faceSubs.require(fRim) ~= VertSub(V, [nv]);
                    } else {
                        // V = P1 (second, edge pred->V is the beveled one): two
                        // corners in the face's own traversal order — the
                        // beveled-edge slide toward the selected predecessor
                        // (NEVER clamped, measured), then the other-edge slide
                        // toward the unselected successor (clamped like any
                        // slide).
                        immutable Vec3 bdir = safeNormalize(vertices[predV] - vp);
                        immutable uint nvBev = addVertex(vp + bdir * width);
                        immutable Vec3 odir = safeNormalize(vertices[succV] - vp);
                        immutable float ow = clampedWidth(V, succV);
                        immutable uint nvOth = addVertex(vp + odir * ow);
                        cornerAtVF[vfKey(V, fRim)] = CornerInfo(
                            nvOth, CornerKind.Slide, ow < width, 1u, false, odir);
                        faceSubs.require(fRim) ~= VertSub(V, [nvBev, nvOth]);
                    }
                    continue;
                }
            }

            if (d < 2 || (nE != d && !openFan)) continue;
            // Task 0447: the fan of an inconsistently-wound vertex is now
            // enumerated COMPLETELY (by the CSR fallback) with only incident
            // elements, so neither the count gate above nor the old foreign-
            // edge scan can catch it — the counts look healthy and no edge is
            // foreign. But the slot arithmetic below (face f_k bordered by edge
            // slots k and k+1) needs a meaningfully ORDERED fan, which the CSR
            // does not promise. Decline on !vertexFanOrdered rather than build
            // from a garbage slot assignment. This replaced the earlier
            // defensive foreign-edge scan (`walkSane`), which the root fix made
            // redundant — see doc/vertex_fan_walk_foreign_edge_plan.md §Phase 3.
            if (!vertexFanOrdered(V)) continue;
            vNbrs.length = nE;
            foreach (k; 0 .. nE) vNbrs[k] = edgeOtherVertex(vEdges[k], V);

            bool[] selE = new bool[](nE);
            int K = 0;
            foreach (k; 0 .. nE) {
                selE[k] = (vEdges[k] < qualifies.length) && qualifies[vEdges[k]];
                if (selE[k]) ++K;
            }
            if (K == 0) continue;

            // Valence-4 / K==1 free-end cap at Round Level >= 1 whose reference
            // keeps a cap topology vibe3d's sound-by-default construction does
            // not ("Decision C"): the two reduced side faces + the ring's
            // opposite-edge corner stay anchored at the RETAINED ORIGINAL
            // free-end vertex (coincident with the chamfer-strip pinch wherever
            // the rounded rail degenerates onto the free-end position → a
            // pinched cap quad), and the slide along the edge OPPOSITE the
            // selected one is emitted but left as an ORPHAN.
            //
            // FOUR measured shapes pin down EXACTLY when this fires — a fully
            // populated 2×2 over {planar, non-planar} × {far a free end, far a
            // full hub}:
            //   planar     + far free end (F2, bare disk)   → Decision C
            //   planar     + far full hub (k4fe mixed junc) → Decision C
            //   non-planar + far full hub (F4, 90° crease)  → Decision C
            //   non-planar + far free end (F1c, 3D tent)    → NO  (plain slide)
            // i.e. Decision C ⇔ (the free end's fan is PLANAR) OR (its single
            // selected edge lands on a FULL HUB). A non-planar free end whose
            // far vertex is another free end (F1c) or a PARTIAL-K junction (the
            // K2 valence-4 octahedron, far = two-of-four selected) keeps the
            // plain slide, so both stay byte-identical.
            bool k4feCap = false;
            int k4feOppSlot = -1;
            // Only at Round Level >= 1: the reference's flat (L0) cap has NO
            // such divergence (measured: L0 dumps are byte-clean), because there
            // is no rounded chamfer rail to pinch against. Gate on roundLevel so
            // every L0 free-end cap stays byte-identical; d==4 / K==1 / !openFan
            // keep valence-3 free ends, the valence-4 rounded hub (K==d), and
            // boundary/open free ends byte-identical too.
            if (roundLevel > 0 && !openFan && d == 4 && K == 1) {
                // Trigger #1 — PLANAR fan: the selected slot's two ring
                // neighbours are ~antipodal, so the rounded rail degenerates
                // onto the free-end position (F2 / k4fe).
                immutable Vec3 n0f = faceNormal(vFaces[0]);
                bool planarf = true;
                foreach (kf; 1 .. d)
                    if (dot(n0f, faceNormal(vFaces[kf])) < 0.999f) { planarf = false; break; }
                // Trigger #2 — the selected edge lands on a FULL HUB (every
                // incident edge there selected), forcing the same retained-
                // original cap even on non-planar geometry (F4's 90° crease).
                int sf = -1;
                foreach (kf; 0 .. nE) if (selE[kf]) { sf = kf; break; }
                immutable uint farVf = vNbrs[sf];
                int farDeg = 0, farK = 0;
                foreach (fef; edgesAroundVertex(farVf)) {
                    ++farDeg;
                    if (fef < qualifies.length && qualifies[fef]) ++farK;
                }
                immutable bool farFullHub = (farDeg > 0 && farK == farDeg);
                if (planarf || farFullHub) {
                    k4feCap = true;
                    k4feOppSlot = (sf + 2) % nE;   // valence-4 ⇒ edge opposite the selected one
                }
            }

            // A GENUINE closed full-ring hub: every incident edge selected on a
            // NON-boundary fan (`K == d`, `!openFan`). This is the ONLY shape
            // whose pairwise rails take task 0454's finding-(F) boundary-Bézier
            // law; a partial K (free-end / notch) or a boundary fan is NOT a
            // hub even when `K` reaches 4+, so it is excluded here (R6). Threaded
            // into every CornerInfo below so `registerRail` gates on it.
            immutable bool isFullHub = !openFan && (K == d);

            immutable Vec3 vpos = vertices[V];
            uint[int] slideVert;    // local edge-slot k → new vertex (memoized per V)
            bool[int] slideClamped; // local edge-slot k → did the overshoot guard clamp it?
            // Width-mode along-face slide magnitude for the OTHER-edge slide on
            // slot `k` (an UNSELECTED edge). The slide is induced by the beveled
            // (selected) edge that shares a face with slot k — slot k-1 (face
            // f_{k-1}) or slot k+1 (face f_k). In width mode that edge's
            // `edgeFactor` scales the raw value (`width / sin(θ/2)`); in inset
            // mode `edgeFactor` is empty ⇒ the raw value. A free slide with no
            // adjacent beveled edge keeps the raw value. Computed here (not at
            // the call sites) so the memoized slide is one consistent, order-
            // independent value shared watertightly across its two faces.
            float slideEffWidth(int k) {
                if (edgeFactor.length == 0) return width;   // inset mode
                int prev = openFan ? (k >= 1 ? k - 1 : -1)
                                   : cast(int)((k + nE - 1) % nE);
                int next = openFan ? (k + 1 < nE ? k + 1 : -1)
                                   : cast(int)((k + 1) % nE);
                foreach (s; [prev, next]) {
                    if (s < 0) continue;
                    if (selE[s] && vEdges[s] < edgeFactor.length)
                        return width * edgeFactor[vEdges[s]];
                }
                return width;
            }
            uint getSlide(int k) {
                if (auto p = k in slideVert) return *p;
                Vec3 dir = safeNormalize(vertices[vNbrs[k]] - vpos);
                immutable float effW = slideEffWidth(k);
                immutable float farLen = (vertices[vNbrs[k]] - vpos).length;
                immutable float w = (farLen > 1e-9f && effW >= farLen) ? farLen : effW;
                uint nv = addVertex(vpos + dir * w);
                slideVert[k]    = nv;
                slideClamped[k] = (w < effW);
                // The slide lands ON the edge V→vNbrs[k] at fraction w/farLen —
                // an ordinary edge-split blend of two ORIGINAL vertices, which
                // is the whole measured law for this family (task 0697).
                if (remapUvB && farLen > 1e-9f) {
                    immutable float t = w / farLen;
                    PolyVertexBlend b;
                    b.add(V, 1.0f - t);
                    b.add(vNbrs[k], t);
                    vertBlendB[nv] = b;
                }
                return nv;
            }
            Vec3 slideDir(int k) { return safeNormalize(vertices[vNbrs[k]] - vpos); }

            foreach (k; 0 .. d) {
                // face f_k's PRED-side edge slot. On an open fan k+1 never
                // exceeds d < nE, so the modulus is a no-op there and only
                // the closed fan actually wraps.
                immutable int kr = (k + 1) % nE;
                immutable uint fi = vFaces[k];
                immutable bool selSucc = selE[k];   // edge k: V's succ-side in f_k
                immutable bool selPred = selE[kr];  // edge kr: V's pred-side in f_k

                if (selSucc && selPred) {
                    // MITER: both bordering edges selected (loop turn, or one
                    // face of an N-way junction). ePrev/eNext match
                    // insetCorner's own prev/next-in-face convention.
                    Vec3 ePrev = safeNormalize(vertices[vNbrs[kr]] - vpos);
                    Vec3 eNext = safeNormalize(vertices[vNbrs[k]]  - vpos);
                    // Both bordering edges are beveled; each contributes its own
                    // along-face offset. In width mode that is `width/sin(θ/2)`
                    // per edge (its `edgeFactor`); in inset mode both stay the
                    // raw `width` (empty array), so the meet is byte-identical.
                    immutable float wPrev = (edgeFactor.length && vEdges[kr] < edgeFactor.length)
                        ? width * edgeFactor[vEdges[kr]] : width;
                    immutable float wNext = (edgeFactor.length && vEdges[k] < edgeFactor.length)
                        ? width * edgeFactor[vEdges[k]] : width;
                    Vec3 m = offsetMeet(vpos, ePrev, eNext, faceNormal(fi), wPrev, wNext);
                    uint nv = addVertex(m);
                    cornerAtVF[vfKey(V, fi)] = CornerInfo(
                        nv, CornerKind.Miter, false, cast(uint)K, isFullHub, Vec3(0,0,0));
                    faceSubs.require(fi) ~= VertSub(V, [nv]);
                } else if (selSucc != selPred) {
                    // SLIDE: exactly one bordering edge selected — corner
                    // slides along the OTHER (unselected) one.
                    immutable int unselK = selSucc ? kr : k;
                    uint nv = getSlide(unselK);
                    cornerAtVF[vfKey(V, fi)] = CornerInfo(
                        nv, CornerKind.Slide, slideClamped[unselK], cast(uint)K, isFullHub, slideDir(unselK));
                    faceSubs.require(fi) ~= VertSub(V, [nv]);
                } else {
                    // Neither bordering edge selected: the source vertex is
                    // now ALWAYS fully cut (task 0439) — the old `keep V`
                    // partial-notch branch had no reference counterpart and
                    // is gone (capture-verified, Decision C in
                    // doc/edge_bevel_freeend_cap_plan.md). Both sides get
                    // their own slide point; order is [pred, succ], matching
                    // f_k's own ring-traversal direction at V. This is the
                    // L0 chord — `threadRails` below swaps it for the
                    // materialized rail chain wherever Round Level approved it.
                    //
                    // EXCEPTION — the valence-4 full-hub free-end cap: the
                    // corner on the edge OPPOSITE the single selected edge
                    // routes to the RETAINED original free-end vertex V
                    // (side_pinch) instead of a slide, so the two reduced
                    // side faces share one anchor at the free-end position
                    // (reference parity). V is an ORIGINAL vertex
                    // (< savedVertCount), so it never enters the new-vertex
                    // identity pool below — the coincident pinch stays two
                    // distinct records with no pooling change needed.
                    immutable uint sPred = (k4feCap && kr == k4feOppSlot) ? V : getSlide(kr);
                    immutable uint sSucc = (k4feCap && k  == k4feOppSlot) ? V : getSlide(k);
                    faceSubs.require(fi) ~= VertSub(V, [sPred, sSucc]);
                }
            }

            if (!openFan && K == d && d >= 3) {
                // Full ring: every face at V is a MITER — its per-face
                // corners trace a closed K-gon needing exactly one cap face.
                // An OPEN fan can never form one: its corner chain terminates
                // on the two rim edges instead of closing, so it takes the
                // ordinary per-face SLIDE/MITER path with no hub cap.
                // Covered (task 0456): d==3 rounds via `junctionRing`; d>=4
                // rounds via `junctionRingN` — even/odd fixtures (K4/K5/mixed)
                // in mesh.d + the full-hub Round-Level census lane
                // (mesh_bevel_census.d). d0/L0 here is the flat threaded N-gon
                // that the rounded ring replaces at L>=1.
                uint[] ring = new uint[](d);
                foreach (k; 0 .. d) ring[k] = cornerAtVF[vfKey(V, vFaces[k])].vert;
                hubCapRing[V] = ring;
                hubCapSrc[V]  = vFaces[0];
            }

            // Free-end / partial-fan cap (task 0439, Decision B): a CLOSED
            // fan (`nE == d`, so `K < nE` is exactly `K < d` and disjoint
            // from the hub-cap `K == d` case above — a vertex is never both)
            // with `0 < K < nE` gets one flat cap threading the ring of
            // unselected-slot slides and both-selected-neighbours miters.
            // The `K < nE` guard here is load-bearing, not decorative:
            // removing it lets a vertex emit BOTH this cap and the hub cap.
            if (!openFan && K > 0 && K < nE) {
                uint[] cap;
                // Per-corner island for the cap (task 0697). A slide on edge
                // slot k borders BOTH f_{k-1} and f_k, so a corner cap standing
                // on it has two equally adjacent islands and the reference's own
                // answer (measured, `edge_bevel_uv_seam`) matches NEITHER — it
                // writes a value from a construction nothing here reproduces.
                // We take f_k, one deterministic side, which is exact wherever
                // the two agree (every mesh without a seam through this vertex,
                // and every frozen non-seam case) and continuous with one island
                // where they do not.
                uint[] capSrc;
                foreach (k; 0 .. nE) {
                    if (!selE[k]) {
                        if (remapUvB) capSrc ~= (k < d) ? vFaces[k] : ~0u;
                        // On the valence-4 full-hub free-end cap, the
                        // opposite-edge corner of the ring is the retained
                        // free-end vertex V (matching the side faces above),
                        // which — once `threadRails` inserts the chamfer-strip
                        // pinch on the wrap edge — yields the reference's
                        // PINCHED cap quad [side_pinch(V), slide, chamfer_pinch,
                        // slide]. The opposite-edge SLIDE is still created just
                        // below and deliberately left orphaned.
                        cap ~= (k4feCap && k == k4feOppSlot) ? V : getSlide(k);
                    }
                    immutable int kNext = (k + 1) % nE;
                    if (k < d && selE[k] && selE[kNext]) {
                        cap ~= cornerAtVF[vfKey(V, vFaces[k])].vert;   // miter of face f_k
                        if (remapUvB) capSrc ~= vFaces[k];
                    }
                }
                if (cap.length >= 3) {
                    freeEndCapRing[V] = cap;
                    freeEndCapSrc[V]  = vFaces[0];
                    if (remapUvB) freeEndCapCornerSrc[V] = capSrc;

                    if (k4feCap) {
                        // Materialize the opposite-edge slide the reference
                        // keeps as an ORPHAN (unreferenced) cap vertex, and
                        // record it so the tail compaction pins it and the
                        // soundness census exempts it (along with the
                        // coincident pair at the free-end position V).
                        immutable uint orphanSlide = getSlide(k4feOppSlot);
                        bevelPinnedOrphans_    ~= orphanSlide;
                        bevelCapCoincidentPos_ ~= vpos;
                        bevelCapOrphanPos_     ~= vertices[orphanSlide];
                    }

                    // Narrow-notch interior tessellation plan (parity task): a
                    // closed-fan K==2 cap whose two gaps are widths {1,2}. The
                    // width-1 gap's lone slide is the apex where the two hub
                    // arcs meet; the width-2 gap's two slides are the base
                    // ends. Recorded here (full fan context in hand) and acted
                    // on in the emission tail. Wider notches (any gap ≥ 3) are
                    // deliberately NOT recorded — their interior routes through
                    // an undecoded reference builder, so they keep the flat cap.
                    if (roundLevel > 0 && !k4feCap && K == 2) {
                        int s0 = -1, s1 = -1;
                        foreach (kk; 0 .. nE)
                            if (selE[kk]) { if (s0 < 0) s0 = kk; else s1 = kk; }
                        int prv(int kk) { return (kk + nE - 1) % nE; }
                        int nxt(int kk) { return (kk + 1) % nE; }
                        immutable int gapFwd = s1 - s0 - 1;       // unselected slots s0→s1
                        immutable int gapBwd = nE - 2 - gapFwd;   // the wrap-around gap
                        if (gapFwd == 1 && gapBwd == 2) {
                            // shared slot s0+1 == s1-1 is the apex; base gap is
                            // the wrap side (slots s1+1, s0-1).
                            notchCapPlans[V] = NotchCapPlan(true,
                                getSlide(nxt(s0)), getSlide(prv(s0)), getSlide(nxt(s1)));
                        } else if (gapBwd == 1 && gapFwd == 2) {
                            // shared slot s0-1 == s1+1 is the apex; base gap is
                            // the forward side (slots s0+1, s1-1).
                            notchCapPlans[V] = NotchCapPlan(true,
                                getSlide(prv(s0)), getSlide(nxt(s0)), getSlide(prv(s1)));
                        }
                    }
                }
            }
        }

        if (cornerAtVF.length == 0) {
            vertices.length = savedVertCount; // undo any addVertex from the per-vertex pass
            return 0;
        }

        // Pre-rebuild pass: for each qualifying selected edge, resolve its
        // fL (traverses v1→v0)/fR (traverses v0→v1) faces from the ORIGINAL
        // (pre-substitution) face array, and its 4 chamfer/arc-rail corners.
        struct ChamferSpan { uint v0, v1, fL, fR; }
        ChamferSpan[] spans;
        // RIM edges (one incident face) never become spans: there is no second
        // rail to bridge to, so the reference adds no face for them. Their
        // whole effect — the lone face's border insetting by `width`, and the
        // neighbouring faces absorbing the corner cut — is already produced by
        // the per-vertex substitution pass. They still count as processed.
        size_t rimProcessed = 0;
        foreach (i; 0 .. edges.length) {
            if (!qualifies[i]) continue;
            uint v0 = edges[i][0], v1 = edges[i][1];
            auto fp = edgeKey(v0, v1) in edgeFaces;
            if (rimOnly[i]) {
                immutable uint fOnly = cast(uint)(*fp)[0];
                if (vfKey(v0, fOnly) in cornerAtVF && vfKey(v1, fOnly) in cornerAtVF)
                    ++rimProcessed;
                continue;
            }
            int fa = (*fp)[0], fb = (*fp)[1];
            uint fL = uint.max, fR = uint.max;
            foreach (k; 0 .. faces[fa].length) {
                uint u = faces[fa][k], w = faces[fa][(k + 1) % faces[fa].length];
                if (u == v1 && w == v0) { fL = fa; fR = fb; break; }
                if (u == v0 && w == v1) { fR = fa; fL = fb; break; }
            }
            if (fL == uint.max) continue;
            // Defensive: both endpoints must have a resolved corner at BOTH
            // fL and fR. A BOUNDARY endpoint no longer lands here — the
            // per-vertex pass above now walks the OPEN fan (nE == d + 1) and
            // populates its `cornerAtVF` entries, so a chain whose ends sit
            // on a rim bevels instead of being dropped. What remains
            // unresolved is a genuinely malformed / non-manifold fan, which
            // still fails the shape check above. Rather than crash on a
            // missing-key AA lookup, skip just this span — the same
            // "silently skipped" contract as v1's guards.
            if (vfKey(v0, fL) !in cornerAtVF || vfKey(v1, fL) !in cornerAtVF ||
                vfKey(v0, fR) !in cornerAtVF || vfKey(v1, fR) !in cornerAtVF)
                continue;
            spans ~= ChamferSpan(v0, v1, fL, fR);
        }
        if (spans.length == 0 && rimProcessed == 0) {
            vertices.length = savedVertCount; // undo any addVertex from the per-vertex pass
            return 0;
        }
        immutable size_t processed = spans.length + rimProcessed;

        // Resolve every original face to its L0 boundary before rounded
        // vertices exist.  This is also the authoritative support-consumer
        // inventory, rather than an optimistic post-materialization guess.
        uint[][] baseFaces;
        foreach (fi; 0 .. faces.length) {
            auto orig = faces[fi];
            baseFaces ~= rebuildFaceWithVertexSubs(orig, cast(uint)fi in faceSubs);
        }

        // Inventory rail consumers symbolically before allocating a single
        // interior vertex.  A strip can round only when BOTH of its endpoint
        // rails have exactly two consumers.  Prune that relation to a fixed
        // point: disabling one strip removes its consumer from both rails,
        // which can disable a neighbouring strip too.  Any rail that cannot
        // meet the invariant stays locally L0; the base bevel still commits.
        // K2/K3 external profile parity remains XFAIL, not inferred here.
        bool[] roundedSpan;
        if (roundLevel > 0) {
            // The finding-(I) rail pivot for a corner is the slide of the OTHER
            // selected edge of its flanking face (never the rail's own edge).
            // neighPivot resolves it from raw topology; passed per corner so
            // registerRail pairs jvLeft↔fL corner, jvRight↔fR corner.
            Vec3 neighPivot(uint Vv, uint farV, uint fi) {
                immutable uint o = otherFaceNeighbor(Vv, farV, fi);
                return vertices[Vv] + safeNormalize(vertices[o] - vertices[Vv]) * width;
            }
            foreach (ref sp; spans) {
                auto cV0L = cornerAtVF[vfKey(sp.v0, sp.fL)];
                auto cV0R = cornerAtVF[vfKey(sp.v0, sp.fR)];
                auto cV1L = cornerAtVF[vfKey(sp.v1, sp.fL)];
                auto cV1R = cornerAtVF[vfKey(sp.v1, sp.fR)];
                // farEnd = the span's OTHER endpoint: the finding-(F) RING-net
                // pivot is the slide of the shared selected edge (V,farEnd). The
                // last two args are the finding-(I) RAIL pivots (the neighboring
                // sides' slides) for the fL/fR corner respectively.
                registerRail(cV0L, cV0R, vertices[sp.v0], sp.v0, vertices[sp.v1],
                             neighPivot(sp.v0, sp.v1, sp.fL), neighPivot(sp.v0, sp.v1, sp.fR));
                registerRail(cV1L, cV1R, vertices[sp.v1], sp.v1, vertices[sp.v0],
                             neighPivot(sp.v1, sp.v0, sp.fL), neighPivot(sp.v1, sp.v0, sp.fR));
            }
            foreach (ring; baseFaces)
                foreach (k; 0 .. ring.length)
                    addRailSupportConsumer(ring[k], ring[(k + 1) % ring.length]);
            foreach (V, ring; hubCapRing)
                foreach (k; 0 .. ring.length)
                    addRailSupportConsumer(ring[k], ring[(k + 1) % ring.length]);
            // The free-end / partial-fan cap ring is this task's (0449) second
            // support-consumer registration, exactly mirroring hubCapRing above:
            // the cap ring IS the "back face" a bordering rail was missing (see
            // the updated declaration comment below). See Decision A in
            // doc/edge_bevel_freeend_cap_roundlevel_plan.md for why a third
            // consumer is structurally impossible and this cannot over-approve.
            foreach (V, ring; freeEndCapRing)
                foreach (k; 0 .. ring.length)
                    addRailSupportConsumer(ring[k], ring[(k + 1) % ring.length]);

            roundedSpan.length = spans.length;
            roundedSpan[] = true;
            bool changed;
            do {
                foreach (ref spec; railSpecs) {
                    spec.stripConsumers = 0;
                    spec.approved = false;
                }
                foreach (si, ref sp; spans) if (roundedSpan[si]) {
                    auto cV0L = cornerAtVF[vfKey(sp.v0, sp.fL)];
                    auto cV0R = cornerAtVF[vfKey(sp.v0, sp.fR)];
                    auto cV1L = cornerAtVF[vfKey(sp.v1, sp.fL)];
                    auto cV1R = cornerAtVF[vfKey(sp.v1, sp.fR)];
                    ++railSpecs[pairKey(cV0L.vert, cV0R.vert)].stripConsumers;
                    ++railSpecs[pairKey(cV1L.vert, cV1R.vert)].stripConsumers;
                }
                foreach (ref spec; railSpecs) {
                    // An interior rail needs exactly two consumers: the chamfer
                    // strip and the "back" face the source vertex belonged to.
                    // A RIM rail has no back face — the open boundary takes its
                    // place — so the strip alone is a complete support there.
                    immutable uint total = spec.supportConsumers + spec.stripConsumers;
                    spec.approved = spec.stripConsumers > 0 &&
                        (total == 2 || (spec.rimRail && total == 1));
                }

                changed = false;
                foreach (si, ref sp; spans) if (roundedSpan[si]) {
                    auto cV0L = cornerAtVF[vfKey(sp.v0, sp.fL)];
                    auto cV0R = cornerAtVF[vfKey(sp.v0, sp.fR)];
                    auto cV1L = cornerAtVF[vfKey(sp.v1, sp.fL)];
                    auto cV1R = cornerAtVF[vfKey(sp.v1, sp.fR)];
                    if (!railSpecs[pairKey(cV0L.vert, cV0R.vert)].approved ||
                        !railSpecs[pairKey(cV1L.vert, cV1R.vert)].approved) {
                        roundedSpan[si] = false;
                        changed = true;
                    }
                }
            } while (changed);

            // Materialize only the fixed-point-approved rails.  No later
            // rollback can strand them because all remaining consumers are
            // already known symbolically.
            foreach (key, spec; railSpecs)
                if (spec.approved) railInterior(spec.a, spec.b);

            // Narrow-notch base-gap arc (parity task): materialize the width-2
            // gap's own edge as a circular arc about the SOURCE vertex and
            // register it in `railInteriorMemo` so `threadRails` inserts the
            // SAME subdivision points into the neighbouring reduced face that
            // the cap grid uses — otherwise the cap would carry the arc while
            // its neighbour kept the straight chord, a T-junction. Only for
            // plans whose BOTH hub arcs actually materialized; any un-approved
            // hub arc leaves the plan on the flat path (emission checks the
            // same condition). Stored canonical (lo→hi), like every rail.
            import std.algorithm : reverse, min, max;
            foreach (Vn, plan; notchCapPlans) {
                if (!plan.valid) continue;
                if (!(pairKey(plan.gapEndL, plan.apex) in railInteriorMemo)) continue;
                if (!(pairKey(plan.gapEndR, plan.apex) in railInteriorMemo)) continue;
                immutable ulong gkey = pairKey(plan.gapEndL, plan.gapEndR);
                if (gkey in railInteriorMemo) continue;
                immutable int nn = 2 * roundLevel;
                immutable Vec3 hp  = vertices[Vn];
                immutable uint glo = min(plan.gapEndL, plan.gapEndR);
                immutable uint ghi = max(plan.gapEndL, plan.gapEndR);
                immutable Vec3 loP = vertices[glo], hiP = vertices[ghi];
                uint[] interior = new uint[](nn - 1);
                foreach (t; 1 .. nn)
                    interior[t - 1] = addVertex(slerpAbout(hp, loP, hiP, cast(float)t / cast(float)nn));
                railInteriorMemo[gkey] = interior;
            }
        }

        // Thread only L0 boundaries.  Rounded strip faces are emitted below
        // directly from the same registry and therefore cannot be threaded a
        // second time.
        uint[] threadRails(const uint[] ring) {
            import std.algorithm : reverse;
            if (roundLevel == 0 || ring.length < 2) return ring.dup;
            uint[] threaded;
            foreach (k; 0 .. ring.length) {
                uint a = ring[k], b = ring[(k + 1) % ring.length];
                threaded ~= a;
                immutable ulong key = pairKey(a, b);
                if (auto p = key in railInteriorMemo) {
                    uint[] interior = *p;
                    if (a > b) {
                        interior = interior.dup;
                        reverse(interior);
                    }
                    threaded ~= interior;
                }
            }
            return threaded;
        }

        // Thread the pre-resolved support boundaries through the materialized
        // rails.  Rounded strip faces are emitted directly below and are not
        // threaded a second time.
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        uint[]   newWord;   // whole faceMarks word per new face (task 0613 §4.2)

        // Per-corner island of the face `newFaces[i]` reads, for the paths that
        // have one (task 0697). Registered by index, never in lockstep, so an
        // emission path that registers nothing keeps the honest zero.
        void noteSrc(size_t nfi, uint[] perCorner) {
            if (remapUvB) srcByNewFace[nfi] = perCorner;
        }
        uint[] uniformSrc(size_t n, uint src) {
            uint[] s = new uint[](n);
            s[] = src;
            return s;
        }

        foreach (fi; 0 .. baseFaces.length) {
            newFaces ~= threadRails(baseFaces[fi]);
            // A rebuilt original face keeps reading its own island; its slide
            // corners blend inside it, and any rail interior threaded in has no
            // source of its own and falls to zero.
            if (remapUvB)
                noteSrc(newFaces.length - 1,
                        uniformSrc(newFaces[$ - 1].length, cast(uint)fi));
            newMat  ~=faceAttrOr(faceMaterial, fi);
            newPart ~=faceAttrOr(facePart, fi);
            newOrd  ~=faceAttrOr(faceSelectionOrder, fi);
            newWord ~= faceAttrOr(faceMarks, fi);
        }

        // Emit the chamfer strip per qualifying edge.  At L>0 every endpoint
        // draws from the pre-materialized rail registry; all support
        // consumers use those exact same indices.
        size_t chamferStart = newFaces.length;
        foreach (si, ref sp; spans) {
            auto cV0L = cornerAtVF[vfKey(sp.v0, sp.fL)];
            auto cV1L = cornerAtVF[vfKey(sp.v1, sp.fL)];
            auto cV1R = cornerAtVF[vfKey(sp.v1, sp.fR)];
            auto cV0R = cornerAtVF[vfKey(sp.v0, sp.fR)];
            // Two-source combine (task 0613 §4.2, code review S5 — was
            // OR-only via isFaceSubpatch(fL) || isFaceSubpatch(fR)): the
            // chamfer strip has TWO source faces. Subpatch still ORs (any
            // source contributes the bit); Hide now ANDs instead of ORing —
            // a chamfer strip between a hidden face and a visible one is
            // VISIBLE, matching the vertex-hidden derivation law in §1.2
            // rather than making newly-created geometry disappear. See
            // Mesh.combineFaceMarksWords.
            immutable uint word = combineFaceMarksWords(faceAttrOr(faceMarks, sp.fL),
                                                         faceAttrOr(faceMarks, sp.fR));

            if (roundLevel == 0 || !roundedSpan[si]) {
                newFaces ~= [cV0L.vert, cV1L.vert, cV1R.vert, cV0R.vert];
                // THE per-corner case: each side of the strip reads the face it
                // slid out of (task 0697).
                if (remapUvB)
                    noteSrc(newFaces.length - 1, [sp.fL, sp.fL, sp.fR, sp.fR]);
                newMat ~= 0u; newPart ~= 0u; newOrd ~= 0; newWord ~= word;
                continue;
            }

            immutable int n = 2 * roundLevel;   // 2·L segments (matches railInterior)
            // r0/r1 both walk fL→fR, using the stored orientation of their
            // source-centred rail chains.
            uint[] r0Interior = railInterior(cV0L.vert, cV0R.vert);
            uint[] r1Interior = railInterior(cV1L.vert, cV1R.vert);

            uint[] r0 = new uint[](n + 1), r1 = new uint[](n + 1);
            r0[0] = cV0L.vert; r0[n] = cV0R.vert;
            r1[0] = cV1L.vert; r1[n] = cV1R.vert;
            foreach (t; 1 .. n) r0[t] = r0Interior[t - 1];
            foreach (t; 1 .. n) r1[t] = r1Interior[t - 1];

            foreach (t; 0 .. n) {
                newFaces ~= [r0[t], r1[t], r1[t + 1], r0[t + 1]];
                // Only the two END rings of a rounded strip stand on original
                // edges; every interior arc point is off them and has no
                // measured value, so it stays zero.
                uint srcAt(int tt) {
                    return (tt == 0) ? sp.fL : ((tt == n) ? sp.fR : ~0u);
                }
                if (remapUvB)
                    noteSrc(newFaces.length - 1,
                            [srcAt(t), srcAt(t), srcAt(t + 1), srcAt(t + 1)]);
                newMat ~= 0u; newPart ~= 0u; newOrd ~= 0; newWord ~= word;
            }
        }

        // Full N=3 junction Gregory ring, GENERAL Round Level (task 0435,
        // gregory_evaluator_findings + twist_reduction_findings). Each side is a
        // standard rational bicubic Gregory patch (Gregory 1974 / Chiyokura–
        // Kimura) whose entire 20-cell control net — the 12 boundary/spoke cells
        // AND the 4 rational twist cells — is closed-form in the boundary Béziers
        // + the R/Q/newC/HUB laws (all from the 3 poles). Samples it on the
        // level-L grid ((u,v) ∈ {0,1/L,…,1}², the ref subdivides an arc into 2·L
        // equal segments so the sub-quad boundary reuses the true-arc rail
        // interiors 1:1). Outputs:
        //   spokePts[i*(L-1)+(k-1)]              = R_i→HUB spoke point at t=k/L
        //     (patch boundary, plain cubic Bézier — shared with the neighbour);
        //   interiorPts[i*(L-1)^2+(b-1)*(L-1)+(a-1)] = rational eval at (a/L,b/L).
        // Validated bit-exact vs the reference from raw geometry
        // (k3_ring_raw_geometry_ref.py). N=3 only.
        static bool junctionRing(const(Vec3)[] poles, const(Vec3)[] p1s,
                                 const(Vec3)[] p2s, int L,
                                 out Vec3 hub, out Vec3[] spokePts, out Vec3[] interiorPts) {
            if (poles.length != 3 || p1s.length != 3 || p2s.length != 3 || L < 1)
                return false;
            // TRUE boundary curve per side (finding F): the caller supplies each
            // side's boundary-Bézier control points P0/P1/P2 (P3_i == P0_{i+1}),
            // built in `registerRail` from the shared-edge slide-point pivot — the
            // SAME construction the general N≥4 builder (`junctionRingN`) consumes.
            // R_i is the boundary Bézier at t=0.5 = (P0+3P1+3P2+P3)/8. This
            // REPLACES the former circumcircle re-fit through pole_i/rail-mid/
            // pole_{i+1}, which matched the reference only at the 90° cube corner
            // (where the emitted rail-mid coincides with the true boundary mid) and
            // bulged the hub for any non-cube K3 hub — task 0435 follow-up. The
            // emitted mesh rail stays K3's own slerp arc (threaded by the caller,
            // sampled via `hasArcCenter`); R_i here feeds ONLY the hub + interior/
            // spoke solve below. Twist cells + evaluator are UNCHANGED (the N=3
            // fast path — no odd-N center-normal / corner-move corrections).
            Vec3[3] P1, P2, R, Q, newC;
            foreach (i; 0 .. 3) {
                P1[i] = p1s[i];
                P2[i] = p2s[i];
                R[i]  = (poles[i] + p1s[i] * 3.0f + p2s[i] * 3.0f + poles[(i + 1) % 3]) * 0.125f;
            }
            Vec3 hsum = Vec3(0, 0, 0);
            foreach (i; 0 .. 3) {
                Q[i] = R[i] + ((P2[(i + 2) % 3] - poles[i])
                             + (P1[(i + 1) % 3] - poles[(i + 1) % 3])) * 0.25f;
                hsum = hsum + (Q[i] * 1.5f - R[i] * 0.5f);
            }
            hub = hsum / 3.0f;
            foreach (i; 0 .. 3) newC[i] = (Q[i] * 1.5f - R[i] * 0.5f) * (2.0f / 3.0f) + hub / 3.0f;
            // Per-side twist cells (closed-form) + the 12 fixed cells.
            Vec3[3] p10, p20, p01, p02, F16, F17, F5, F9, F6, F18, F10;
            foreach (i; 0 .. 3) {
                immutable int pv = (i + 2) % 3, nx = (i + 1) % 3;
                immutable Vec3 P0i = poles[i];
                immutable Vec3 DA = P2[pv] - P0i,             DB  = P1[nx] - poles[nx];
                immutable Vec3 DAp = P2[(pv + 2) % 3] - poles[pv], DBp = P1[i] - P0i;
                immutable Vec3 DT  = DA * (2.0f / 3.0f) + DB * (1.0f / 3.0f);
                immutable Vec3 DU  = DA * (1.0f / 3.0f) + DB * (2.0f / 3.0f);
                immutable Vec3 DTp = DAp * (2.0f / 3.0f) + DBp * (1.0f / 3.0f);
                immutable Vec3 DUp = DAp * (1.0f / 3.0f) + DBp * (2.0f / 3.0f);
                p10[i] = (P0i + P1[i]) * 0.5f;
                p20[i] = (P0i + P1[i] * 2.0f + P2[i]) * 0.25f;
                p01[i] = (P2[pv] + P0i) * 0.5f;
                p02[i] = (P1[pv] + P2[pv] * 2.0f + P0i) * 0.25f;
                F16[i] = p10[i] + (DA + DT) * 0.25f;
                F17[i] = p20[i] + (DA + DU) * 0.125f + DT * 0.25f;
                F5[i]  = p01[i] + (DBp + DUp) * 0.25f;
                F9[i]  = p02[i] + (DTp + DBp) * 0.125f + DUp * 0.25f;
                F6[i]  = F17[i] + (Q[i]  - R[i])  * (1.0f / 6.0f);
                F18[i] = F9[i]  + (Q[pv] - R[pv]) * (1.0f / 6.0f);
                F10[i] = (newC[i] + newC[pv] - newC[nx]) * 4.0f / 3.0f
                       + (Q[nx] - Q[i] - Q[pv]) / 3.0f;
            }
            static float[4] bern(float t) {
                immutable float s = 1.0f - t;
                return [s*s*s, 3.0f*t*s*s, 3.0f*t*t*s, t*t*t];
            }
            // Rational bicubic Gregory eval of sub-quad i at (u,v).
            Vec3 evalSub(int i, float u, float v) {
                immutable int pv = (i + 2) % 3;
                Vec3 blend(Vec3 a, Vec3 b, float wa, float wb) {
                    immutable float den = wa + wb;
                    return den > 1e-9f ? (a * wa + b * wb) / den : (a + b) * 0.5f;
                }
                immutable Vec3 p11 = blend(F16[i], F5[i],  u, v);
                immutable Vec3 p12 = blend(F18[i], F9[i],  u, 1.0f - v);
                immutable Vec3 p21 = blend(F17[i], F6[i],  1.0f - u, v);
                // g[a][b] = grid[(a,b)], a=u-index, b=v-index.  v=0 edge (b=0) is
                // pole→R_i; u=0 edge (a=0) is pole→R_prev; u=1 (a=3) is the
                // R_i→HUB spoke; v=1 (b=3) is the R_prev→HUB spoke.
                immutable Vec3[4][4] g = [
                    [poles[i], p01[i],  p02[i],   R[pv]   ],
                    [p10[i],   p11,     p12,      Q[pv]   ],
                    [p20[i],   p21,     F10[i],   newC[pv]],
                    [R[i],     Q[i],    newC[i],  hub     ],
                ];
                immutable float[4] Bu = bern(u), Bv = bern(v);
                Vec3 acc = Vec3(0, 0, 0);
                foreach (a; 0 .. 4) foreach (b; 0 .. 4) acc = acc + g[a][b] * (Bu[a] * Bv[b]);
                return acc;
            }
            immutable int m = L - 1;                    // interior samples per axis
            spokePts.length    = 3 * m;
            interiorPts.length = 3 * m * m;
            immutable float inv = 1.0f / cast(float) L;
            foreach (i; 0 .. 3) {
                foreach (k; 1 .. L)                     // R_i→HUB spoke at u=1
                    spokePts[i * m + (k - 1)] = evalSub(i, 1.0f, k * inv);
                foreach (b; 1 .. L) foreach (a; 1 .. L)
                    interiorPts[i * m * m + (b - 1) * m + (a - 1)] = evalSub(i, a * inv, b * inv);
            }
            return true;
        }

        // GENERAL N-sided junction Gregory ring (N≥4, task 0454). The N-sided
        // reference path (the reference's N-sided patch solve) is a DIFFERENT
        // evaluator than N=3's fast path, recovered capture-free
        // (toolcards/edge.bevel/nway_hub_ring_ref.py, findings A/B/E/F/H). Unlike
        // `junctionRing` (which re-fits each boundary Bézier from a circumcircle
        // through pole_i/R_i/pole_{i+1} — the N=3 reconstruction), this builder
        // takes the TRUE boundary-Bézier control points P0/P1/P2 per side
        // (finding F, from `boundaryBezier`, the same curve the rail samples).
        //   R_i    = boundary Bézier at t=0.5 = (P0+3P1+3P2+P0_next)/8
        //   Q/C/HUB/newC + F16/F17/F5/F9      = SAME closed forms as N=3, mod N
        //   F6/F10/F18/F19 (twist)            = closed-form affine for EVEN N;
        //     for ODD N the finding-(H) closed-form recurrence W0=½·Σ(−1)^j·c_j
        //     (exact decomposition of the reference's sparse (4N)×(4N) system —
        //     NO dense solver, dodges the O(N³)/allocation DoS).
        //   newC_i's TRUE final value (task 0453, finding J) = the plain hub-law
        //     value above, THEN the center-normal planar projection (EVERY
        //     N), THEN — odd N only — the odd-N corner-move sin-angle magnitude
        //     recurrence. Both ported below; odd N is now reference-parity at
        //     every Round Level, not just L1.
        //   evaluator: identical to N=3 EXCEPT the p22 grid cell is
        //     avg(F10_i, F19_i) (finding D — for N=3 F10==F19 so it was moot).
        static bool junctionRingN(const(Vec3)[] poles, const(Vec3)[] p1s,
                                  const(Vec3)[] p2s, int N, int L,
                                  out Vec3 hub, out Vec3[] spokePts, out Vec3[] interiorPts) {
            import std.math : abs, sqrt;
            if (cast(int)poles.length != N || cast(int)p1s.length != N ||
                cast(int)p2s.length != N || N < 4 || L < 1) return false;
            int nxt(int i) { return (i + 1) % N; }
            int prv(int i) { return (i + N - 1) % N; }

            Vec3[] R = new Vec3[](N);
            foreach (i; 0 .. N)
                R[i] = (poles[i] + p1s[i] * 3.0f + p2s[i] * 3.0f + poles[nxt(i)]) * 0.125f;
            Vec3 DA(int i) { return p2s[prv(i)] - poles[i]; }
            Vec3 DB(int i) { return p1s[nxt(i)] - poles[nxt(i)]; }
            Vec3[] Qv = new Vec3[](N);
            foreach (i; 0 .. N) Qv[i] = R[i] + (DA(i) + DB(i)) * 0.25f;
            Vec3 hsum = Vec3(0, 0, 0);
            Vec3[] Cv = new Vec3[](N);
            foreach (i; 0 .. N) { Cv[i] = Qv[i] * 1.5f - R[i] * 0.5f; hsum = hsum + Cv[i]; }
            hub = hsum / cast(float)N;
            Vec3[] newCv = new Vec3[](N);
            foreach (i; 0 .. N) newCv[i] = (Cv[i] * 2.0f + hub) / 3.0f;

            // --- task 0453, finding (J): newC_i's TRUE final value is a
            // TWO-STAGE correction of the plain hub-law value just computed,
            // ported bit-for-bit from `center_normal_project`/`move_points_odd_N`
            // in toolcards/edge.bevel/nway_hub_ring_ref.py (private reference,
            // recovered from the reference's center-normal + odd-N corner-move steps).
            //
            // Stage 1 — center-normal projection: planar-projects the WHOLE newC
            // ring onto ONE common plane through hub. Runs UNCONDITIONALLY for
            // every N (even AND odd) — NOT gated on parity, unlike Stage 2
            // below. A near-no-op (~1e-17) on the near-planar rings every
            // existing K4/K5/K6 fixture happens to have (so those stay
            // byte-identical); a REAL correction (0.0018-0.0072 absolute in the
            // reference's own units) once the ring is genuinely non-planar
            // (the K5-asymmetric parity fixtures below exercise this).
            // crossN_i must read every side's ORIGINAL (pre-projection) newC —
            // both at i and i-1 — so snapshot first: this pass's own writes
            // (below) must never be read back by a later i in the SAME pass.
            // Factored into the sibling `centerNormalProject` method (below
            // `bevelEdgesByMask`) so the geometric invariant it establishes —
            // every projected point satisfies dot(p-hub, Navg)~=0 — can be
            // unit-tested directly on a hand-built ring (see the property
            // unittest near the K5-asymmetric parity fixtures).
            centerNormalProject(N, hub, newCv);
            // Stage 2 — odd-N corner-move: ODD N ONLY. Takes Stage 1's OUTPUT
            // and replaces every newC_i's hub-relative MAGNITUDE (keeping its
            // DIRECTION exactly) via a multiplicative sin-of-turning-angle
            // recurrence around the full N-cycle: forward-ADJACENT (i,i+1)
            // pairing, stepping +2 mod N (visits every index exactly once
            // since gcd(2,N)=1 for odd N — this monodromy IS why the branch is
            // odd-N-only, the same structure as the twist-solve's own
            // W_{i+1}=-W_i+c_i recurrence above). The (i,i+1)-forward pairing
            // was PINNED — not just consistent — by a fresh K5-ASYMMETRIC
            // reference capture (gate A4): 4 wrong-pairing variants
            // (backward-neighbour, skip-one, reversed recurrence, combined)
            // all measured 1.4e-5-2.6e-5 off on that capture; this one hits
            // 1.4e-17-2.0e-17 (machine epsilon). See
            // toolcards/edge.bevel/nway_hub_law_findings.md finding (J).
            if (N % 2 != 0) {
                Vec3[] D = new Vec3[](N);
                float[] S = new float[](N);
                Vec3[] u = new Vec3[](N);
                foreach (i; 0 .. N) {
                    D[i] = newCv[i] - hub;
                    S[i] = sqrt(2.0f * (abs(D[i].x) + abs(D[i].y) + abs(D[i].z)));
                    u[i] = (S[i] > 1e-9f) ? D[i] / S[i] : D[i];
                }
                float[] sinAdj = new float[](N);
                foreach (i; 0 .. N) {
                    immutable float dp = dot(u[i], u[nxt(i)]);
                    sinAdj[i] = sqrt(abs(1.0f - dp * dp));
                }
                float[] w = new float[](N);
                w[0] = 1.0f;
                {
                    int idx = 0;
                    foreach (k; 0 .. N) {
                        immutable int p = nxt(idx);
                        immutable int q = (idx + 2) % N;
                        w[q] = w[idx] * sinAdj[idx] / sinAdj[p];
                        idx = q;
                    }
                }
                float meanW = 0.0f, meanS = 0.0f;
                foreach (i; 0 .. N) { meanW += w[i]; meanS += S[i]; }
                meanW /= cast(float)N;
                meanS /= cast(float)N;
                immutable float scale = (abs(meanW) > 1e-9f) ? meanS / meanW : 1.0f;
                foreach (i; 0 .. N) w[i] *= scale;
                foreach (i; 0 .. N) newCv[i] = hub + u[i] * w[i];
            }

            Vec3 DT(int i) { return DA(i) * (2.0f / 3.0f) + DB(i) * (1.0f / 3.0f); }
            Vec3 DU(int i) { return DA(i) * (1.0f / 3.0f) + DB(i) * (2.0f / 3.0f); }
            Vec3[] p10v = new Vec3[](N), p20v = new Vec3[](N),
                   p01v = new Vec3[](N), p02v = new Vec3[](N);
            foreach (i; 0 .. N) {
                immutable int pv = prv(i);
                p10v[i] = (poles[i] + p1s[i]) * 0.5f;
                p20v[i] = (poles[i] + p1s[i] * 2.0f + p2s[i]) * 0.25f;
                p01v[i] = (p2s[pv] + poles[i]) * 0.5f;
                p02v[i] = (p1s[pv] + p2s[pv] * 2.0f + poles[i]) * 0.25f;
            }
            Vec3[] F16v = new Vec3[](N), F17v = new Vec3[](N),
                   F5v = new Vec3[](N), F9v = new Vec3[](N);
            foreach (i; 0 .. N) {
                immutable int pv = prv(i);
                F16v[i] = p10v[i] + (DA(i) + DT(i)) * 0.25f;
                F17v[i] = p20v[i] + (DA(i) + DU(i)) * 0.125f + DT(i) * 0.25f;
                F5v[i]  = p01v[i] + (DB(pv) + DU(pv)) * 0.25f;
                F9v[i]  = p02v[i] + (DT(pv) + DB(pv)) * 0.125f + DU(pv) * 0.25f;
            }
            Vec3[] F13v = new Vec3[](N);
            foreach (i; 0 .. N) F13v[i] = Qv[prv(i)];

            Vec3[] F6v = new Vec3[](N), F10v = new Vec3[](N),
                   F18v = new Vec3[](N), F19v = new Vec3[](N);
            if (N % 2 == 0) {
                // twist_fields_even_N — pure closed-form affine (the reference
                // statically branches AROUND the solve on `N&1`; there is no
                // linear system to reconstruct for even N).
                foreach (i; 0 .. N) {
                    immutable int pv = prv(i);
                    immutable Vec3 baseI = (newCv[i] - hub) * 0.5f + (Qv[i] - R[i]) * 0.5f;
                    F10v[i] = baseI + newCv[pv] * (2.0f / 3.0f) + p20v[i] * (1.0f / 3.0f);
                    F6v[i]  = baseI + newCv[pv] * (1.0f / 3.0f) + p20v[i] * (2.0f / 3.0f);
                    immutable Vec3 baseP = (newCv[pv] - hub) * 0.5f + (Qv[pv] - R[pv]) * 0.5f;
                    F18v[i] = baseP + p02v[i] * (2.0f / 3.0f) + newCv[i] * (1.0f / 3.0f);
                    F19v[i] = baseP + p02v[i] * (1.0f / 3.0f) + newCv[i] * (2.0f / 3.0f);
                }
            } else {
                // twist_fields_odd_N via the finding-(H) closed-form recurrence
                // (D3). The reference's (4N)×(4N) system is 2 nonzeros/row (all
                // ±1): rows 4i+0/4i+2 solve LOCALLY (a 2×2 block per side); rows
                // 4i+1/4i+3 link all N sides in one circular chain
                // W_{i+1}=−W_i+c_i whose odd-N monodromy (−1)^N=−1 gives the
                // unique W_0=½·Σ(−1)^j·c_j. O(N), allocation-bounded, exact — no
                // np.linalg.solve, no math.d solver surface.
                Vec3[] rhs0 = new Vec3[](N), rhs1 = new Vec3[](N),
                       rhs2 = new Vec3[](N), rhs3 = new Vec3[](N);
                foreach (i; 0 .. N) {
                    immutable Vec3 a = newCv[i] - hub;
                    immutable float numer = dot(a, (newCv[nxt(i)] - hub) + (newCv[prv(i)] - hub));
                    immutable float den = 3.0f * dot(a, a);
                    immutable float lam = (abs(den) > 1e-20f) ? numer / den : 0.0f;
                    rhs0[i] = F9v[nxt(i)] - F17v[i];
                    rhs1[i] = (Qv[i] - newCv[i]) * (2.0f * lam);
                    rhs2[i] = (R[i] - Qv[i]) * lam;
                    rhs3[i] = newCv[nxt(i)] - newCv[i];
                }
                Vec3[] X0 = new Vec3[](N), X1 = new Vec3[](N),
                       X2 = new Vec3[](N), X3 = new Vec3[](N);
                foreach (i; 0 .. N) {
                    X0[i] = (rhs0[i] - rhs2[i]) * 0.5f;
                    X2[i] = (rhs0[i] + rhs2[i]) * 0.5f;
                }
                Vec3 wsum = Vec3(0, 0, 0);
                foreach (j; 0 .. N) {
                    immutable Vec3 cj = rhs3[j] - rhs1[j];
                    wsum = (j % 2 == 0) ? wsum + cj : wsum - cj;
                }
                X1[0] = wsum * 0.5f;
                foreach (i; 0 .. N - 1) X1[i + 1] = -X1[i] + (rhs3[i] - rhs1[i]);
                foreach (i; 0 .. N) X3[i] = X1[i] + rhs1[i];
                foreach (i; 0 .. N) {
                    immutable int pv = prv(i);
                    F6v[i]  = Qv[i]    - X0[i];
                    F10v[i] = newCv[i] - X1[i];
                    F18v[i] = X2[pv] + F13v[i];
                    F19v[i] = X3[pv] + newCv[pv];
                }
            }

            static float[4] bern(float t) {
                immutable float s = 1.0f - t;
                return [s*s*s, 3.0f*t*s*s, 3.0f*t*t*s, t*t*t];
            }
            Vec3 evalSub(int i, float u, float v) {
                immutable int pv = prv(i);
                Vec3 blend(Vec3 a, Vec3 b, float wa, float wb) {
                    immutable float den = wa + wb;
                    return den > 1e-9f ? (a * wa + b * wb) / den : (a + b) * 0.5f;
                }
                immutable Vec3 p11 = blend(F16v[i], F5v[i], u, v);
                immutable Vec3 p12 = blend(F18v[i], F9v[i], u, 1.0f - v);
                immutable Vec3 p21 = blend(F17v[i], F6v[i], 1.0f - u, v);
                immutable Vec3 p22 = (F10v[i] + F19v[i]) * 0.5f;   // finding D
                immutable Vec3[4][4] g = [
                    [poles[i], p01v[i], p02v[i], R[pv]  ],
                    [p10v[i],  p11,     p12,     Qv[pv] ],
                    [p20v[i],  p21,     p22,     newCv[pv]],
                    [R[i],     Qv[i],   newCv[i], hub    ],
                ];
                immutable float[4] Bu = bern(u), Bv = bern(v);
                Vec3 acc = Vec3(0, 0, 0);
                foreach (a; 0 .. 4) foreach (b; 0 .. 4) acc = acc + g[a][b] * (Bu[a] * Bv[b]);
                return acc;
            }
            immutable int m = L - 1;
            spokePts.length    = N * m;
            interiorPts.length = N * m * m;
            immutable float inv = 1.0f / cast(float) L;
            foreach (i; 0 .. N) {
                foreach (k; 1 .. L)
                    spokePts[i * m + (k - 1)] = evalSub(i, 1.0f, k * inv);
                foreach (b; 1 .. L) foreach (a; 1 .. L)
                    interiorPts[i * m * m + (b - 1) * m + (a - 1)] = evalSub(i, a * inv, b * inv);
            }
            return true;
        }

        // Emit one hub cap per full-ring (K==valence) vertex — Phase 2.
        // Outward-winding check via Newell's formula vs the averaged
        // ORIGINAL incident-face normal, same idiom as bevelVerticesByMask.
        size_t capStart = newFaces.length;
        foreach (V, ring_; hubCapRing) {
            uint[] ring = threadRails(ring_);
            immutable int Ncap = cast(int)ring.length;
            Vec3 newellN = Vec3(0, 0, 0);
            foreach (k; 0 .. Ncap) {
                Vec3 a = vertices[ring[k]];
                Vec3 b = vertices[ring[(k + 1) % Ncap]];
                newellN.x += (a.y - b.y) * (a.z + b.z);
                newellN.y += (a.z - b.z) * (a.x + b.x);
                newellN.z += (a.x - b.x) * (a.y + b.y);
            }
            Vec3 avgFaceN = Vec3(0, 0, 0);
            foreach (fi; facesAroundVertex(V)) {
                Vec3 fn = faceNormal(cast(uint)fi);
                avgFaceN.x += fn.x; avgFaceN.y += fn.y; avgFaceN.z += fn.z;
            }
            if (dot(newellN, avgFaceN) < 0) {
                for (int lo = 0, hi = Ncap - 1; lo < hi; ++lo, --hi) {
                    uint tmp = ring[lo]; ring[lo] = ring[hi]; ring[hi] = tmp;
                }
            }
            immutable uint srcFi = hubCapSrc[V];

            // 3-way junction Gregory ring, GENERAL Round Level (task 0435).
            // Unifies the L1 fan (1×1 grid → [pole,R,HUB,R]) and the L≥2 interior
            // ring (L×L grid): HUB + R→HUB spoke points + rational interior points
            // woven into an L×L quad grid per sub-quad whose u=0/v=0 boundary
            // REUSES the true-arc pairwise rail interiors (the reference rail is
            // the arc, not the patch's internal Bézier). Bit-exact vs the
            // reference at L1/L2/L3 (20v/15f, 38v/30f, 62v/51f). N>=4 junctions
            // take the sibling N-sided path (`junctionRingN`, the `else if`
            // branch below) — task 0454/0456.
            if (ring_.length == 3 && roundLevel >= 1) {
                immutable int L = roundLevel;
                immutable int m = L - 1;
                uint[3] poleI; int np = 0;
                foreach (v; ring) {
                    bool isP = false; foreach (p; ring_) if (v == p) { isP = true; break; }
                    if (isP && np < 3) poleI[np++] = v;
                }
                bool ok = (np == 3);
                uint[][3] railI;
                Vec3[3] poleP, p1s, p2s;
                if (ok) foreach (i; 0 .. 3) {
                    // A pairwise rail here is NOT guaranteed approved. The
                    // fixed point can un-round a rail for any of several
                    // reasons — a rail-starved span elsewhere in the same
                    // connected run, a malformed/rejected neighbouring fan,
                    // or (before task 0449) a free-end cap that withheld a
                    // rail's second consumer — and this node has no business
                    // assuming which one applies. `railInterior` asserts on
                    // an unapproved rail, so check first and fall back to
                    // the flat cap, exactly as the strip emission does.
                    // Known-unreached as of task 0449 (0 hits over 5652
                    // rounded census trials, generateTrialMasks × 7 meshes ×
                    // L1-L3, mesh_bevel_census.d): a K3 junction whose far
                    // endpoints are valence-4 free ends now rounds cleanly
                    // (that cap ring is a rail's second consumer too, same
                    // as this junction's own ring), and the one other
                    // construction found that reaches `railSpec is null`
                    // here depends on the fan-walk winding defect task 0447
                    // is removing — see doc/edge_bevel_freeend_cap_
                    // roundlevel_plan.md, Decision D2. "Not hit yet" is not
                    // "unreachable": this guard is a structural backstop
                    // with no freezable trigger, and removing it needs a
                    // proof of unreachability, not an absence of failures.
                    immutable int nx = (i + 1) % 3;
                    auto railSpec = pairKey(poleI[i], poleI[nx]) in railSpecs;
                    // `hasBez` gates the true-boundary-curve hub build: every full
                    // K3 hub rail carries the boundary handles (registerRail's
                    // isFullHub && selectedDegree≥3 gate; hubCapRing entries are
                    // always full hubs, so this holds), and an unapproved rail (the
                    // fixed point withheld consent) drops the ring to the flat cap.
                    //
                    // This is NOT the same predicate the N≥4 branch below uses.
                    // `hasBez` carries no non-degeneracy test, so a DEGENERATE hub
                    // — one whose side has coincident poles or coincident finding-(I)
                    // pivots — rounds here while the N≥4 rule (`hubRail`) would drop
                    // it to the flat cap. Reachable and measured: see the
                    // `parallel-edge K3 hub` unittest below. Which rule the reference
                    // uses is NOT captured for a degenerate hub; task 0707 owns it.
                    // Do not silently swap this flag for `hubRail` — that is the
                    // behaviour change 0707 has to earn with a capture.
                    if (railSpec is null || !railSpec.approved || !railSpec.hasBez) {
                        ok = false; break;
                    }
                    railI[i] = railInterior(poleI[i], poleI[nx]);
                    if (railI[i].length != 2 * L - 1) { ok = false; break; }
                    poleP[i] = vertices[poleI[i]];
                    // TRUE boundary-Bézier handles for side i, oriented to the ring
                    // order pole_i→pole_{i+1} (bezP1/bezP2 are stored canonical
                    // a→b) — the same orientation dance the N≥4 caller does.
                    immutable bool fwd = poleI[i] < poleI[nx];
                    p1s[i] = fwd ? railSpec.bezP1 : railSpec.bezP2;
                    p2s[i] = fwd ? railSpec.bezP2 : railSpec.bezP1;
                }
                Vec3 hubPos; Vec3[] spokeP, interiorP;
                if (ok && junctionRing(poleP[], p1s[], p2s[], L, hubPos, spokeP, interiorP)) {
                    immutable uint hubIdx = addVertex(hubPos);
                    uint[][3] spokeIdx, interiorIdx;
                    foreach (i; 0 .. 3) {
                        spokeIdx[i].length = m;
                        foreach (k; 0 .. m) spokeIdx[i][k] = addVertex(spokeP[i * m + k]);
                        interiorIdx[i].length = m * m;
                        foreach (k; 0 .. m * m) interiorIdx[i][k] = addVertex(interiorP[i * m * m + k]);
                    }
                    // Grid vertex of sub-quad i at (a,b), a,b ∈ 0..L. u=0/v=0 edges
                    // reuse the rail interiors; u=1/v=1 edges are the R→HUB spokes
                    // (shared with the neighbour sub-quad); interior = Gregory eval.
                    uint gv(int i, int a, int b) {
                        immutable int pv = (i + 2) % 3;
                        if (a == 0 && b == 0) return poleI[i];
                        if (a == L && b == 0) return railI[i][L - 1];        // R_i
                        if (a == 0 && b == L) return railI[pv][L - 1];       // R_prev
                        if (a == L && b == L) return hubIdx;
                        if (b == 0)           return railI[i][a - 1];        // pole_i→R_i
                        if (a == 0)           return railI[pv][2 * L - 1 - b]; // pole_i→R_prev
                        if (a == L)           return spokeIdx[i][b - 1];     // R_i→HUB
                        if (b == L)           return spokeIdx[pv][a - 1];    // R_prev→HUB
                        return interiorIdx[i][(b - 1) * m + (a - 1)];
                    }
                    foreach (i; 0 .. 3)
                        foreach (b; 0 .. L) foreach (a; 0 .. L) {
                            newFaces ~= [gv(i, a, b), gv(i, a + 1, b),
                                         gv(i, a + 1, b + 1), gv(i, a, b + 1)];
                            newMat  ~=faceAttrOr(faceMaterial, srcFi);
                            newPart ~=faceAttrOr(facePart, srcFi);
                            newOrd  ~= 0;
                            newWord ~= faceAttrOr(faceMarks, srcFi);
                        }
                    continue;
                }
            }
            // GENERAL N-way junction ring (N≥4, task 0454). Same L×L grid weave
            // per sub-quad as the N=3 branch — u=0/v=0 REUSE the boundary-Bézier
            // rail interiors, u=1/v=1 are the R→HUB spokes, the interior is the
            // N-sided Gregory eval (`junctionRingN`, even + odd via the finding
            // (H) closed forms). The `MAX_JUNCTION_VALENCE` cap is the DoS
            // backstop: an over-cap full hub falls through to the flat N-gon.
            // Compute-then-commit (R5): every position is computed before any
            // `addVertex`, and any unapproved / non-Bézier rail (a degenerate
            // corner the finding-(F) build refused) drops the whole ring to the
            // flat cap — no partial mutation.
            else if (ring_.length >= 4 && roundLevel >= 1 &&
                     ring_.length <= MAX_JUNCTION_VALENCE) {
                immutable int N = cast(int)ring_.length;
                immutable int L = roundLevel;
                immutable int m = L - 1;
                uint[] poleI;
                foreach (v; ring) {
                    bool isP = false; foreach (p; ring_) if (v == p) { isP = true; break; }
                    if (isP && cast(int)poleI.length < N) poleI ~= v;
                }
                bool ok = (cast(int)poleI.length == N);
                uint[][] railI; railI.length = N;
                Vec3[] poleP; poleP.length = N;
                Vec3[] p1s;   p1s.length   = N;
                Vec3[] p2s;   p2s.length   = N;
                if (ok) foreach (i; 0 .. N) {
                    immutable int nx = (i + 1) % N;
                    auto railSpec = pairKey(poleI[i], poleI[nx]) in railSpecs;
                    // A genuine hub rail carries `hubRail`: registerRail's gate
                    // (`isFullHub && selectedDegree >= 3` at both corners — `>= 3`,
                    // not the `>= 4` an earlier draft of this comment claimed; the
                    // K3-true-boundary-curve task widened it) AND both corners
                    // distinct AND both finding-(I) pivots distinct. Any rail that
                    // is unapproved (the fixed point withheld consent) OR not a hub
                    // rail drops the ring to the flat cap.
                    //
                    // Note this rejects MORE than the ring itself needs. The ring
                    // reads only `poles` + `bezP1/bezP2`; `jvA`/`jvB` are read
                    // nowhere but `railInterior`. So a hub with usable poles and
                    // handles but coincident rail pivots is flat-capped here purely
                    // on a RAIL-law precondition — the mirror image of the N=3
                    // branch's `hasBez`, which rejects less than the ring needs.
                    // Neither is the ring's own predicate; task 0707 owns the fix,
                    // and until it lands the asymmetry is deliberate-by-record, not
                    // an invitation to align the two by taste.
                    if (railSpec is null || !railSpec.approved || !railSpec.hubRail) {
                        ok = false; break;
                    }
                    railI[i] = railInterior(poleI[i], poleI[nx]);
                    if (cast(int)railI[i].length != 2 * L - 1) { ok = false; break; }
                    poleP[i] = vertices[poleI[i]];
                    immutable bool fwd = poleI[i] < poleI[nx];
                    // Orient the stored (canonical a→b) handles to pole_i→pole_{i+1}.
                    p1s[i] = fwd ? railSpec.bezP1 : railSpec.bezP2;
                    p2s[i] = fwd ? railSpec.bezP2 : railSpec.bezP1;
                }
                Vec3 hubPos; Vec3[] spokeP, interiorP;
                if (ok && junctionRingN(poleP, p1s, p2s, N, L, hubPos, spokeP, interiorP)) {
                    immutable uint hubIdx = addVertex(hubPos);
                    uint[][] spokeIdx;    spokeIdx.length    = N;
                    uint[][] interiorIdx; interiorIdx.length = N;
                    foreach (i; 0 .. N) {
                        spokeIdx[i].length = m;
                        foreach (k; 0 .. m) spokeIdx[i][k] = addVertex(spokeP[i * m + k]);
                        interiorIdx[i].length = m * m;
                        foreach (k; 0 .. m * m) interiorIdx[i][k] = addVertex(interiorP[i * m * m + k]);
                    }
                    uint gv(int i, int a, int b) {
                        immutable int pv = (i + N - 1) % N;
                        if (a == 0 && b == 0) return poleI[i];
                        if (a == L && b == 0) return railI[i][L - 1];        // R_i
                        if (a == 0 && b == L) return railI[pv][L - 1];       // R_prev
                        if (a == L && b == L) return hubIdx;
                        if (b == 0)           return railI[i][a - 1];        // pole_i→R_i
                        if (a == 0)           return railI[pv][2 * L - 1 - b]; // pole_i→R_prev
                        if (a == L)           return spokeIdx[i][b - 1];     // R_i→HUB
                        if (b == L)           return spokeIdx[pv][a - 1];    // R_prev→HUB
                        return interiorIdx[i][(b - 1) * m + (a - 1)];
                    }
                    foreach (i; 0 .. N)
                        foreach (b; 0 .. L) foreach (a; 0 .. L) {
                            newFaces ~= [gv(i, a, b), gv(i, a + 1, b),
                                         gv(i, a + 1, b + 1), gv(i, a, b + 1)];
                            newMat  ~=faceAttrOr(faceMaterial, srcFi);
                            newPart ~=faceAttrOr(facePart, srcFi);
                            newOrd  ~= 0;
                            newWord ~= faceAttrOr(faceMarks, srcFi);
                        }
                    continue;
                }
            }

            newFaces ~= ring;
            newMat  ~=faceAttrOr(faceMaterial, srcFi);
            newPart ~=faceAttrOr(facePart, srcFi);
            newOrd  ~= 0;
            newWord ~= faceAttrOr(faceMarks, srcFi);
        }

        // Emit one free-end / partial-fan cap per `freeEndCapRing` vertex
        // (task 0439, Decision B; rounded at Round Level > 0 since task
        // 0449). Same Newell-winding idiom as the hub cap above, and — as
        // of 0449 — the same `threadRails` call: this ring is now the
        // SECOND support-consumer for its bordering rails (registered
        // above, alongside `hubCapRing`), so a rail whose chamfer-strip
        // side is also approved reaches the two-consumer fixed point and
        // materializes; `threadRails` swaps the L0 chord for the
        // materialized arc chain exactly as it does for any other ring.
        // K >= 2 (a notch spanning 2+ selected slots) still only closes the
        // boundary arcs, not the cap's own interior tessellation — see
        // doc/edge_bevel_freeend_cap_roundlevel_plan.md, Decision B — and a
        // vertex whose whole span run fails to reach approval (for any of
        // the OTHER reasons the fixed point can withhold consent) still
        // commits this cap flat, same as before.
        foreach (V, ring_; freeEndCapRing) {
            // Round-Level narrow-notch cap interior tessellation (parity task).
            // A recorded plan + BOTH hub-arc rails + the base-gap arc all
            // materialized ⇒ emit the (2·L)×(2·L) triangle-cap grid instead of
            // the flat fill. The two hub arcs are the selected edges' own
            // chamfer rails; the base edge is the gap arc registered during
            // materialization (SHARED with the neighbouring reduced face, so no
            // T-junction); the interior is a recursive fillet pivoted at the
            // apex. Any un-materialized rail (a degraded span) falls through to
            // the flat path below, byte-identical to before.
            auto planP = V in notchCapPlans;
            immutable ulong baseKeyN = (planP !is null)
                ? pairKey(planP.gapEndL, planP.gapEndR) : 0UL;
            if (planP !is null && planP.valid && roundLevel > 0 &&
                (pairKey(planP.gapEndL, planP.apex) in railInteriorMemo) &&
                (pairKey(planP.gapEndR, planP.apex) in railInteriorMemo) &&
                (baseKeyN in railInteriorMemo)) {
                import std.algorithm : reverse;
                immutable int n = 2 * roundLevel;
                immutable uint apex = planP.apex;
                immutable Vec3 apexP = vertices[apex];
                // Full hub-arc rails: [gapEnd, interior…, apex], n+1 entries.
                // `railInterior(a,b)` yields the interior in a→b order.
                uint[] arcL; arcL ~= planP.gapEndL; arcL ~= railInterior(planP.gapEndL, apex); arcL ~= apex;
                uint[] arcR; arcR ~= planP.gapEndR; arcR ~= railInterior(planP.gapEndR, apex); arcR ~= apex;
                // Base gap arc: [gapEndL, interior…, gapEndR]. Reuse the SAME
                // memoized vertices `threadRails` inserted into the neighbour
                // (stored canonical lo→hi; orient to gapEndL→gapEndR here).
                uint[] gInt = railInteriorMemo[baseKeyN].dup;
                if (planP.gapEndL > planP.gapEndR) reverse(gInt);
                uint[] baseE = planP.gapEndL ~ gInt ~ planP.gapEndR;
                // Interior grid G[i][j], i,j ∈ 1..n-1: recursive fillet pivoted
                // at the apex, sweeping between the two hub-arc samples of row i.
                uint[][] Gint;
                Gint.length = n;
                foreach (i; 1 .. n) {
                    Gint[i].length = n;
                    immutable Vec3 aL = vertices[arcL[i]], aR = vertices[arcR[i]];
                    foreach (j; 1 .. n)
                        Gint[i][j] = addVertex(slerpAbout(apexP, aL, aR, cast(float)j / cast(float)n));
                }
                uint gv(int i, int j) {
                    if (i == n) return apex;      // apex row collapses to one point
                    if (j == 0) return arcL[i];
                    if (j == n) return arcR[i];
                    if (i == 0) return baseE[j];
                    return Gint[i][j];
                }
                // Build the grid faces, then align their winding to the fan's
                // average face normal (same convention as the flat cap).
                uint[][] gridFaces;
                foreach (i; 0 .. n) foreach (j; 0 .. n) {
                    if (i + 1 == n)
                        gridFaces ~= [gv(i, j + 1), gv(i, j), apex];   // triangle at apex
                    else
                        gridFaces ~= [gv(i, j + 1), gv(i, j), gv(i + 1, j), gv(i + 1, j + 1)];
                }
                Vec3 gN = Vec3(0, 0, 0);
                foreach (f; gridFaces)
                    foreach (k; 0 .. f.length) {
                        Vec3 a = vertices[f[k]], b = vertices[f[(k + 1) % f.length]];
                        gN.x += (a.y - b.y) * (a.z + b.z);
                        gN.y += (a.z - b.z) * (a.x + b.x);
                        gN.z += (a.x - b.x) * (a.y + b.y);
                    }
                Vec3 avgN = Vec3(0, 0, 0);
                foreach (fi; facesAroundVertex(V)) {
                    Vec3 fn = faceNormal(cast(uint)fi);
                    avgN.x += fn.x; avgN.y += fn.y; avgN.z += fn.z;
                }
                immutable bool flip = dot(gN, avgN) < 0;
                immutable uint srcFiN = freeEndCapSrc[V];
                foreach (ref f; gridFaces) {
                    if (flip) reverse(f);
                    newFaces ~= f;
                    newMat  ~=faceAttrOr(faceMaterial, srcFiN);
                    newPart ~=faceAttrOr(facePart, srcFiN);
                    newOrd  ~= 0;
                    newWord ~= faceAttrOr(faceMarks, srcFiN);
                }
                continue;
            }

            uint[] ring = ring_.dup;
            immutable int Ncap = cast(int)ring.length;
            Vec3 newellN = Vec3(0, 0, 0);
            foreach (k; 0 .. Ncap) {
                Vec3 a = vertices[ring[k]];
                Vec3 b = vertices[ring[(k + 1) % Ncap]];
                newellN.x += (a.y - b.y) * (a.z + b.z);
                newellN.y += (a.z - b.z) * (a.x + b.x);
                newellN.z += (a.x - b.x) * (a.y + b.y);
            }
            Vec3 avgFaceN = Vec3(0, 0, 0);
            foreach (fi; facesAroundVertex(V)) {
                Vec3 fn = faceNormal(cast(uint)fi);
                avgFaceN.x += fn.x; avgFaceN.y += fn.y; avgFaceN.z += fn.z;
            }
            // The per-corner islands travel with the ring through the winding
            // flip and the rail threading (task 0697); a threaded-in rail
            // interior gets no source and stays zero. Built defensively — a
            // length that does not match the emitted face is dropped whole at
            // the carry rather than shifting every island by one corner.
            uint[] ringSrc;
            if (remapUvB)
                if (auto cs = V in freeEndCapCornerSrc)
                    ringSrc = (*cs).length == ring.length ? (*cs).dup : null;
            if (dot(newellN, avgFaceN) < 0) {
                for (int lo = 0, hi = Ncap - 1; lo < hi; ++lo, --hi) {
                    uint tmp = ring[lo]; ring[lo] = ring[hi]; ring[hi] = tmp;
                    if (ringSrc.length == cast(size_t)Ncap) {
                        uint ts = ringSrc[lo]; ringSrc[lo] = ringSrc[hi]; ringSrc[hi] = ts;
                    }
                }
            }
            immutable uint srcFi = freeEndCapSrc[V];
            newFaces ~= threadRails(ring);
            if (ringSrc.length == cast(size_t)Ncap) {
                uint[] threadedSrc;
                foreach (k; 0 .. ring.length) {
                    threadedSrc ~= ringSrc[k];
                    immutable ulong rk = pairKey(ring[k], ring[(k + 1) % ring.length]);
                    if (roundLevel > 0 && ring.length >= 2)
                        if (auto p = rk in railInteriorMemo)
                            foreach (_; *p) threadedSrc ~= ~0u;
                }
                noteSrc(newFaces.length - 1, threadedSrc);
            }
            newMat  ~=faceAttrOr(faceMaterial, srcFi);
            newPart ~=faceAttrOr(facePart, srcFi);
            newOrd  ~= 0;
            newWord ~= faceAttrOr(faceMarks, srcFi);
        }

        // Assign reconstructed arrays.
        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;

        // Rebuild faceMarks: zero all, then restore the whole word (task 0613
        // §4.2 — was Subpatch-only).
        setFaceMarksFrom(newWord, ~Marks.Select);

        // task 0436: new-vertex merge. `toolcards/edge.bevel/
        // clamp_findings.md` — geometry-only pass ("Follow-up pass —
        // positional vs. constructive new-vertex merge") plus a live
        // rr/gdb trace of the reference's own polygon-assembly routine
        // ("rr/gdb mechanism trace — task 0436 follow-up 2") that reads and
        // watches the reference's own face-corner append routine execute. Two steps, matching two
        // DIFFERENT parts of the reference the trace distinguishes:
        //
        // STEP 1 — IDENTITY POOLING (the trace's own open sub-question,
        // "what pools two independently-computed slide positions into one
        // shared object" — not traced; the reference's new-vertex allocator is a plausible
        // carrier, inspected but not confirmed). Two NEW corners (both
        // >= savedVertCount) pool into one shared representative iff they
        // coincide AND are corners of the SAME rebuilt face — this is the
        // positional proxy the trace explicitly endorses ("keep our
        // positional comparison — it reproduces every captured case") for
        // that untraced step. Confirmed necessary by Case C's own capture:
        // the merged corner there is referenced by THREE different faces
        // (a reduced side face plus both chamfer strips) as a SINGLE
        // shared vertex record, not by three separately-computed,
        // merely-coincident ones — that sharing has to happen somewhere
        // before any one face's own corner list is assembled, since the
        // two slides being pooled are computed from different SOURCE
        // vertices entirely (different `getSlide` closures), not the same
        // one memoized twice. Scoping the pool to same-FACE pairs (rather
        // than any two coincident new vertices mesh-wide) is what keeps
        // Case D's cross-component pair — never a corner of any shared
        // face — un-pooled and therefore un-merged.
        //
        // STEP 2 — PER-FACE CONSTRUCTION (this IS the directly traced
        // mechanism). The reference's face-corner append routine appends each candidate corner
        // to the rebuilt face's own list unless it equals — by pointer
        // identity, checked on every candidate, not just the closing one —
        // the LAST corner already accepted into THIS face's list, or the
        // FIRST. After Step 1's pooling, "equal by identity" is exact index
        // equality (two pooled duplicates now share one index), matching
        // the reference's own pointer test far more literally than a
        // second positional check would. This is what lets a middle
        // candidate that coincides with the face's own first corner still
        // get dropped (Case C's traced 4-candidate top-face run: 2
        // accepted, 2 skipped, one dup-of-last and one dup-of-first) and is
        // why Case B's two colliding pairs — non-adjacent in the pre-pool
        // corner order, a miter corner sits between them — still collapse
        // their host faces to CLEAN triangles rather than a corner-
        // repeating "bowtie" face: post-pooling they share one index, and
        // that shared index equals the face's own first-accepted entry.
        //
        // "Both new" holds throughout — a pre-existing (< savedVertCount)
        // vertex is never eligible for Step 1's pool (measured Case D, pair
        // (P3, clamped-P0): same rebuilt face, bit-exact position, never
        // pooled — the overshoot guard's own "no weld against the
        // original" law above, unconditional). Clamp state never enters
        // either step (measured Case C: neither slide is anywhere near its
        // neighbour's farLen). Both steps are single passes — Step 1 scans
        // the just-assigned `faces` once building pool pairs; Step 2 walks
        // each (already-pooled) face once — no rescanning, no fixpoint
        // iteration (a merge could in principle create new co-membership
        // that no captured case exhibits — see doc/behavior_gap_registry.md).
        //
        // Both steps are local to this function, not the shared
        // `applyVertexRemap` (whose own dedup only compares a candidate to
        // the immediately preceding kept corner, plus a separate final-vs-
        // first wrap check — not "compare to first on every candidate";
        // extending it would risk changing the other 7
        // `weldCoincidentVertices` call sites, which Phase 2 promised zero
        // behavior change for). A corner never kept by ANY face becomes
        // unreferenced and is swept by this function's own existing
        // `compactUnreferenced()` in its tail.
        bool coincide(uint a, uint b) {
            Vec3 d = vertices[a] - vertices[b];
            return d.x * d.x + d.y * d.y + d.z * d.z < 1e-10;
        }
        immutable size_t rebuiltFaceCount = faces.length;

        // Step 1: identity pooling, "lowest surviving index wins" — same
        // discipline as `computeWeldRemap`.
        int[] poolRemap = new int[](vertices.length);
        foreach (i; 0 .. vertices.length) poolRemap[i] = cast(int)i;
        uint resolvePool(uint i) {
            while (poolRemap[i] != cast(int)i) i = cast(uint)poolRemap[i];
            return i;
        }
        foreach (f; faces)
            foreach (a; 0 .. f.length)
                foreach (b; a + 1 .. f.length) {
                    if (f[a] < savedVertCount || f[b] < savedVertCount) continue;
                    immutable uint ra = resolvePool(f[a]), rb = resolvePool(f[b]);
                    if (ra == rb || !coincide(ra, rb)) continue;
                    immutable uint lo = ra < rb ? ra : rb, hi = ra < rb ? rb : ra;
                    poolRemap[hi] = cast(int)lo;
                }

        // Step 2: per-face live construction over the pooled identities.
        uint[][] mergedFaces;
        mergedFaces.reserve(faces.length);
        int[] faceRemap = new int[](faces.length);
        bool anyMerge = false;
        // The map's per-corner islands ride the same drops (task 0697): a corner
        // this pass discards takes its source with it, so the survivors stay
        // aligned. A face whose registered array does not match its corner count
        // (an emission path changed shape underneath) falls back to no source at
        // all rather than to a shifted one.
        uint[][] mergedSrc;
        foreach (fi, f; faces) {
            uint[] kept;
            uint[] keptSrc;
            const uint[] faceSrc = srcByNewFace.get(fi, null);
            const bool   haveSrc = remapUvB && faceSrc.length == f.length;
            kept.reserve(f.length);
            foreach (ci, vid0; f) {
                immutable uint vid = resolvePool(vid0);
                if (kept.length > 0 && vid == kept[$ - 1]) {
                    anyMerge = true;
                    continue; // dup of LAST kept corner: drop, don't update last/first
                }
                if (kept.length > 0 && vid == kept[0]) {
                    anyMerge = true;
                    continue; // dup of FIRST kept corner (incl. loop closure): drop
                }
                kept ~= vid;
                if (remapUvB) keptSrc ~= haveSrc ? faceSrc[ci] : ~0u;
            }
            if (kept.length >= 3) {
                faceRemap[fi] = cast(int)mergedFaces.length;
                mergedFaces ~= kept;
                if (remapUvB) mergedSrc ~= keptSrc;
            } else {
                faceRemap[fi] = -1; // whole face collapsed below 3 corners (Case C)
            }
        }
        faces = mergedFaces;

        // Relocate the per-corner map now that `faces` is final and BEFORE the
        // tail `buildLoops`, which would otherwise see a length-wrong map and
        // zero the whole mesh's UV. Vertex indices are still the pre-compaction
        // ones the capture was taken against.
        if (remapUvB) {
            uint[] srcOfCorner;
            foreach (s; mergedSrc) srcOfCorner ~= s;
            carryPolyVertexMapsByCorner(faces.range, srcOfCorner, oldFacesB,
                                        oldFaceLoopB, vertBlendB);
        }
        if (anyMerge) {
            if (selectedFaces.length > faces.length) resizeFaceSelection();
            if (faceSelectionOrder.length > faces.length) faceSelectionOrder.length = faces.length;
            if (isSubpatch.length > faces.length) resizeSubpatch();
            if (faceMaterial.length > faces.length) faceMaterial.length = faces.length;
            if (facePart.length     > faces.length) facePart.length     = faces.length;
        }

        // New selection = chamfer + hub-cap faces; clear vertex/edge
        // selections. Re-derived through `faceRemap` — a dropped, non-tail
        // face (Case C: the whole top-face quad can vanish) shifts every
        // surviving face after it, so re-selecting by the OLD index range
        // directly would silently select the wrong faces.
        faceSelectionOrderCounter = 0;
        foreach (fi; chamferStart .. rebuiltFaceCount) {
            immutable int newFi = faceRemap[fi];
            if (newFi >= 0) selectFace(newFi);
        }
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        // Tail: rebuild topology + compact orphaned original vertices, but
        // PIN the valence-4 full-hub free-end cap's intended orphan slides so
        // they survive as the reference keeps them (see bevelPinnedOrphans_).
        rebuildEdges();
        buildLoops();
        compactUnreferenced(bevelPinnedOrphans_);
        buildLoops();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }

    /// Bevel ONE non-manifold "spine" edge shared by N≥3 incident faces, for the
    /// single measured topology: an ISOLATED fin bundle (task 0438). Both spine
    /// endpoints must touch NOTHING but the N incident fins — a spine embedded in
    /// a larger mesh (an endpoint carrying any other face) is refused. Reference
    /// law, captured bit-exact for N=3 and N=4 (`edge_bevel_0438_{A3face,B4face}_*`):
    ///   * each fin is inset in place — its two spine corners (a, b) are each
    ///     replaced by a rail point `p + width·û_perp`, where û_perp is the
    ///     in-plane direction at that corner perpendicular to the spine, toward
    ///     the fin's interior (the identical per-face formula ordinary two-face
    ///     edges use); the fin keeps its arity and its winding.
    ///   * exactly one new N-gon cap is added at EACH spine end, fanning that
    ///     end's N rail points in incident-face order. BOTH caps use the same
    ///     order, so their winding is emergent-consistent with the reference's.
    /// `sharp` is not a parameter here and Round Level does not round this cap —
    /// both measured inert, so this takes neither. Returns 1 on success, or 0
    /// (leaving the mesh byte-identical) when the isolated-bundle precondition
    /// fails — honoring `bevelEdgesByMask`'s "return 0 ⇒ no-op" contract, so all
    /// precondition checks run BEFORE the first mutation.
    size_t bevelIsolatedFinBundleSpine(uint spineEdge, float width) {
        if (spineEdge >= edges.length) return 0;
        immutable uint a = edges[spineEdge][0];
        immutable uint b = edges[spineEdge][1];
        if (a == b) return 0;

        // Incident fins in FACE-INDEX order (reproduces the reference's incident-
        // polygon fan order; the winding check is rotation-invariant so the
        // starting offset is immaterial). Scanning faces directly is non-
        // manifold-safe, unlike a fan walk around a non-manifold vertex.
        uint[] fins;
        foreach (fi; 0 .. cast(uint)faces.length) {
            auto f = faces[fi];
            immutable L = f.length;
            foreach (k; 0 .. L) {
                immutable uint u = f[k], w = f[(k + 1) % L];
                if ((u == a && w == b) || (u == b && w == a)) { fins ~= fi; break; }
            }
        }
        immutable size_t N = fins.length;
        if (N < 3) return 0;

        // Isolated-bundle precondition: neither endpoint may touch any face that
        // is NOT one of the N fins. Every fin already contains both a and b, so
        // "incident-face count == N" at each endpoint is exactly that condition.
        size_t facesWith(uint v) {
            size_t c = 0;
            foreach (f; faces) foreach (vv; f) if (vv == v) { ++c; break; }
            return c;
        }
        if (facesWith(a) != N || facesWith(b) != N) return 0;

        // --- Phase A: compute everything, mutate nothing (no-op contract). ---
        Vec3 railPos(uint p, uint q, uint nbr, out bool ok) {
            immutable Vec3 P = vertices[p];
            Vec3 uu = vertices[q] - P;
            immutable float ul = uu.length;
            if (ul > 1e-12f) uu = uu / ul;
            immutable Vec3 e = vertices[nbr] - P;
            immutable Vec3 perp = e - uu * dot(e, uu);
            immutable float pl = perp.length;
            if (pl < 1e-9f) { ok = false; return P; }
            ok = true;
            return P + perp / pl * width;
        }
        Vec3[] railAPos; railAPos.reserve(N);
        Vec3[] railBPos; railBPos.reserve(N);
        auto finPa = new int[](N);
        auto finPb = new int[](N);
        foreach (idx, fi; fins) {
            auto f = faces[fi];
            immutable L = f.length;
            int pa = -1, pb = -1;
            foreach (k; 0 .. L) { if (f[k] == a) pa = cast(int)k; if (f[k] == b) pb = cast(int)k; }
            if (pa < 0 || pb < 0) return 0;
            immutable uint aOther = (f[(pa + 1) % L] == b) ? f[(pa + L - 1) % L] : f[(pa + 1) % L];
            immutable uint bOther = (f[(pb + 1) % L] == a) ? f[(pb + L - 1) % L] : f[(pb + 1) % L];
            bool okA, okB;
            immutable Vec3 ra = railPos(a, b, aOther, okA);
            immutable Vec3 rb = railPos(b, a, bOther, okB);
            if (!okA || !okB) return 0;
            railAPos ~= ra; railBPos ~= rb;
            finPa[idx] = pa; finPb[idx] = pb;
        }

        // --- Phase B: mutate. Add rails, rewrite each fin in place, add caps. ---
        uint[] railA; railA.reserve(N);
        uint[] railB; railB.reserve(N);
        foreach (idx, fi; fins) {
            immutable uint ia = addVertex(railAPos[idx]);
            immutable uint ib = addVertex(railBPos[idx]);
            railA ~= ia; railB ~= ib;
            uint[] nf = faces[fi].dup;
            nf[finPa[idx]] = ia;
            nf[finPb[idx]] = ib;
            faces[fi] = nf;
        }
        // One N-gon fan cap per spine end, both in incident-face order.
        immutable uint capA = cast(uint)faces.length; addFace(railA);
        immutable uint capB = cast(uint)faces.length; addFace(railB);

        // The original spine verts a, b are now unreferenced; the tail
        // compaction drops them (net: −2 spine verts, +2N rails; +2 cap faces).
        syncSelection();
        clearFaceSelection();
        foreach (fi; fins) selectFace(cast(int)fi);
        selectFace(cast(int)capA);
        selectFace(cast(int)capB);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();
        finalizeTopologyEdit();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return 1;
    }

    /// Bevel an isolated fin-bundle spine (edge shared by N≥3 fins whose two
    /// endpoints touch NOTHING but those fins) together with a set of "extra"
    /// selected edges — the measured law for a multi-edge selection *through* the
    /// non-manifold spine (parity task, fuzz divergence D2). Generalizes the
    /// single-spine `bevelIsolatedFinBundleSpine`; each extra edge must be a
    /// fin's OUTER boundary edge (a rim edge, one incident face = a fin) that is
    /// incident to a spine endpoint. Captured bit-exact for N=3 across a
    /// rectangular AND a skewed fin (the skew disambiguates the corner law from
    /// the rectangle's 90° degeneracy).
    ///
    /// Per fin, at each spine endpoint p (outer neighbour W = p's fin neighbour
    /// that is not the other spine endpoint):
    ///   * If the outer edge (p, W) is NOT selected: p's spine corner insets to
    ///     the spine rail `p + width·û_perp` exactly as the single-spine case.
    ///     The cap at that end fans this rail.
    ///   * If (p, W) IS selected: p's corner becomes a MITER — the intersection
    ///     of the spine-chamfer inset line and the (p, W)-chamfer inset line
    ///     (both in the fin plane, each offset `width` from its edge). The cap
    ///     fans this miter. The far endpoint W is corner-cut into TWO vertices:
    ///     a perpendicular inset of the fin's NEXT edge (W, Wnext) at W, and a
    ///     slide along (W, Wnext) by `width`; so the fin gains one ring vertex
    ///     per extra edge.
    /// One N-gon fan cap is added at EACH spine end (incident-face order, same
    /// winding convention as the single-spine sibling).
    ///
    /// Returns the number of selected edges consumed (spine + extras) on success,
    /// or 0 (mesh byte-identical) when any precondition fails — every check runs
    /// BEFORE the first mutation, honouring `bevelEdgesByMask`'s no-op contract.
    /// Anything past the measured shape refuses: >1 spine, an extra that is not a
    /// fin's rim edge at a spine endpoint, an extra whose far vertex is the other
    /// spine endpoint, a fin carrying extras at BOTH ends (their corner-cuts can
    /// collide on a quad), or a degenerate miter / perpendicular.
    size_t bevelFinBundleSpineMultiEdge(uint spineEdge, const uint[] extraEdges, float width) {
        if (spineEdge >= edges.length) return 0;
        immutable uint a = edges[spineEdge][0];
        immutable uint b = edges[spineEdge][1];
        if (a == b) return 0;

        // Incident fins in FACE-INDEX order (scan faces directly — non-manifold-
        // safe, unlike a fan walk around a non-manifold vertex; see the single-
        // spine sibling).
        uint[] fins;
        foreach (fi; 0 .. cast(uint)faces.length) {
            auto f = faces[fi];
            immutable L = f.length;
            foreach (k; 0 .. L) {
                immutable uint u = f[k], w = f[(k + 1) % L];
                if ((u == a && w == b) || (u == b && w == a)) { fins ~= fi; break; }
            }
        }
        immutable size_t N = fins.length;
        if (N < 3) return 0;

        // Isolated-bundle precondition (identical to the single-spine sibling):
        // neither endpoint may touch any face that is not one of the N fins.
        size_t facesWith(uint v) {
            size_t c = 0;
            foreach (f; faces) foreach (vv; f) if (vv == v) { ++c; break; }
            return c;
        }
        if (facesWith(a) != N || facesWith(b) != N) return 0;

        int finPos(uint fi) { foreach (idx, ff; fins) if (ff == fi) return cast(int)idx; return -1; }

        // Classify each extra edge → (fin, spine endpoint slot, far vertex W).
        // extraFar[finIdx][0] = W for an extra at `a`, [1] = W for an extra at
        // `b`; ~0u = none. Reject anything outside the measured shape here,
        // before any mutation.
        auto extraFar = new uint[2][](N);
        foreach (ref e; extraFar) { e[0] = ~0u; e[1] = ~0u; }
        foreach (ee; extraEdges) {
            if (ee >= edges.length) return 0;
            immutable uint u = edges[ee][0], v = edges[ee][1];
            uint incFace = ~0u; size_t incCount = 0;
            foreach (fi; 0 .. cast(uint)faces.length) {
                auto f = faces[fi]; immutable L = f.length;
                foreach (k; 0 .. L) {
                    immutable uint x = f[k], y = f[(k + 1) % L];
                    if ((x == u && y == v) || (x == v && y == u)) { incFace = fi; ++incCount; break; }
                }
            }
            if (incCount != 1) return 0;             // not a rim edge
            immutable int fp = finPos(incFace);
            if (fp < 0) return 0;                     // rim edge not on a fin
            uint p, W;
            if (u == a || u == b) { p = u; W = v; }
            else if (v == a || v == b) { p = v; W = u; }
            else return 0;                            // extra not at a spine endpoint
            if (W == a || W == b) return 0;           // far vertex is the other spine endpoint
            immutable int slot = (p == a) ? 0 : 1;
            if (extraFar[fp][slot] != ~0u) return 0;  // two extras same fin+endpoint
            extraFar[fp][slot] = W;
        }
        foreach (fp; 0 .. N)
            if (extraFar[fp][0] != ~0u && extraFar[fp][1] != ~0u) return 0; // extras both ends

        // --- Phase A: compute everything, mutate nothing (no-op contract). ---
        // p slid `width` along the in-plane perpendicular to edge (p→q), toward
        // `nbr` (the identical rail idiom the single-spine path and two-face
        // edges use).
        Vec3 railFrom(uint p, uint q, uint nbr, out bool ok) {
            immutable Vec3 P = vertices[p];
            Vec3 uu = vertices[q] - P;
            immutable float ul = uu.length;
            if (ul > 1e-12f) uu = uu / ul;
            immutable Vec3 e = vertices[nbr] - P;
            immutable Vec3 perp = e - uu * dot(e, uu);
            immutable float pl = perp.length;
            if (pl < 1e-9f) { ok = false; return P; }
            ok = true;
            return P + perp / pl * width;
        }
        // Miter at spine endpoint p (outer neighbour W): intersection of the
        // spine-chamfer inset line (through the spine rail, along the spine) and
        // the (p,W)-chamfer inset line (through (p,W)'s inset rail, along (p,W)).
        Vec3 miterAt(uint p, uint other, uint W, out bool ok) {
            bool o1, o2;
            immutable Vec3 R  = railFrom(p, other, W, o1);   // on the spine inset line
            immutable Vec3 Rp = railFrom(p, W, other, o2);   // on the (p,W) inset line
            if (!o1 || !o2) { ok = false; return vertices[p]; }
            immutable Vec3 dS = safeNormalize(vertices[other] - vertices[p]);
            immutable Vec3 dO = safeNormalize(vertices[W] - vertices[p]);
            immutable Vec3 nrm = cross(dS, dO);
            immutable float nn = dot(nrm, nrm);
            if (nn < 1e-12f) { ok = false; return vertices[p]; }  // parallel ⇒ degenerate
            immutable Vec3 r = Rp - R;
            immutable float s = dot(cross(r, dO), nrm) / nn;
            ok = true;
            return R + dS * s;
        }

        // Per-fin plan: new-vertex positions + a ring template (≥0 ⇒ existing
        // vertex index, <0 ⇒ −(local+1) into `np`), plus which local slot is the
        // a-end / b-end cap point.
        struct FinPlan { Vec3[] np; int[] ring; int aCapL; int bCapL; }
        FinPlan[] plans; plans.reserve(N);

        foreach (fp, fi; fins) {
            auto f = faces[fi]; immutable L = f.length;
            int ia = -1, ib = -1;
            foreach (k; 0 .. L) { if (f[k] == a) ia = cast(int)k; if (f[k] == b) ib = cast(int)k; }
            if (ia < 0 || ib < 0) return 0;
            immutable uint aN = (f[(ia + 1) % L] == b) ? f[(ia + L - 1) % L] : f[(ia + 1) % L];
            immutable uint bN = (f[(ib + 1) % L] == a) ? f[(ib + L - 1) % L] : f[(ib + 1) % L];
            immutable uint aFar = extraFar[fp][0];
            immutable uint bFar = extraFar[fp][1];

            bool ok;
            Vec3 aCornerPos = (aFar != ~0u) ? miterAt(a, b, aN, ok) : railFrom(a, b, aN, ok);
            if (!ok) return 0;
            Vec3 bCornerPos = (bFar != ~0u) ? miterAt(b, a, bN, ok) : railFrom(b, a, bN, ok);
            if (!ok) return 0;

            FinPlan pl; pl.aCapL = -1; pl.bCapL = -1;
            foreach (k; 0 .. L) {
                immutable uint v = f[k];
                if (v == a) {
                    pl.np ~= aCornerPos; pl.aCapL = cast(int)(pl.np.length - 1);
                    pl.ring ~= -(cast(int)pl.np.length);
                } else if (v == b) {
                    pl.np ~= bCornerPos; pl.bCapL = cast(int)(pl.np.length - 1);
                    pl.ring ~= -(cast(int)pl.np.length);
                } else if (aFar != ~0u && v == aN) {
                    // Corner-cut aN (far end of the extra edge at `a`).
                    immutable bool fwd = (f[(k + 1) % L] != a);   // walk goes a → aN → Wnext
                    immutable uint Wnext = fwd ? f[(k + 1) % L] : f[(k + L - 1) % L];
                    if (Wnext == a || Wnext == b) return 0;
                    bool okp;
                    immutable Vec3 Vperp = railFrom(aN, Wnext, a, okp);        // perp inset of (aN,Wnext)
                    if (!okp) return 0;
                    immutable Vec3 Valong = vertices[aN] + safeNormalize(vertices[Wnext] - vertices[aN]) * width;
                    if (fwd) { pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length);
                               pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length); }
                    else     { pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length);
                               pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length); }
                } else if (bFar != ~0u && v == bN) {
                    immutable bool fwd = (f[(k + 1) % L] != b);   // walk goes b → bN → Wnext
                    immutable uint Wnext = fwd ? f[(k + 1) % L] : f[(k + L - 1) % L];
                    if (Wnext == a || Wnext == b) return 0;
                    bool okp;
                    immutable Vec3 Vperp = railFrom(bN, Wnext, b, okp);
                    if (!okp) return 0;
                    immutable Vec3 Valong = vertices[bN] + safeNormalize(vertices[Wnext] - vertices[bN]) * width;
                    if (fwd) { pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length);
                               pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length); }
                    else     { pl.np ~= Valong; pl.ring ~= -(cast(int)pl.np.length);
                               pl.np ~= Vperp; pl.ring ~= -(cast(int)pl.np.length); }
                } else {
                    pl.ring ~= cast(int)v;
                }
            }
            if (pl.aCapL < 0 || pl.bCapL < 0) return 0;
            plans ~= pl;
        }

        // --- Phase B: mutate. Add rails/miters/cuts, rewrite fins, add caps. ---
        uint[] aCapG; aCapG.reserve(N);
        uint[] bCapG; bCapG.reserve(N);
        foreach (fp, fi; fins) {
            auto pl = plans[fp];
            uint[] gnew; gnew.reserve(pl.np.length);
            foreach (p; pl.np) gnew ~= addVertex(p);
            uint[] nf; nf.reserve(pl.ring.length);
            foreach (r; pl.ring) nf ~= (r >= 0) ? cast(uint)r : gnew[-(r) - 1];
            faces[fi] = nf;
            aCapG ~= gnew[pl.aCapL];
            bCapG ~= gnew[pl.bCapL];
        }
        // One N-gon fan cap per spine end, both in incident-face order (matching
        // the single-spine sibling's emergent-consistent winding).
        immutable uint capA = cast(uint)faces.length; addFace(aCapG);
        immutable uint capB = cast(uint)faces.length; addFace(bCapG);

        // The original spine verts a, b (and any corner-cut'd outer verts) are
        // now unreferenced; the tail compaction drops them.
        syncSelection();
        clearFaceSelection();
        foreach (fi; fins) selectFace(cast(int)fi);
        selectFace(cast(int)capA);
        selectFace(cast(int)capB);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();
        finalizeTopologyEdit();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return 1 + extraEdges.length;
    }

    /// The center-normal projection step (task 0453, finding J, Stage 1 of newC_i's
    /// TRUE final value — see `junctionRingN`'s own call site for the full
    /// derivation). Planar-projects the WHOLE `newCv` ring onto ONE common
    /// plane through `hub`, mutating `newCv` in place. Runs UNCONDITIONALLY
    /// for every N (even AND odd) — ported bit-for-bit from
    /// `center_normal_project` in the private reference
    /// (toolcards/edge.bevel/nway_hub_ring_ref.py), recovered from
    /// full static disassembly of the reference's center-normal step. `crossN_i` must read
    /// every side's ORIGINAL (pre-projection) `newCv` — both at `i` and
    /// `i-1` — so this snapshots first: this pass's own writes must never be
    /// read back by a later `i` in the SAME pass. Factored out of
    /// `junctionRingN` (its sole caller) so the geometric invariant it
    /// establishes — every projected point satisfies
    /// `dot(p-hub, Navg)~=0` — can be unit-tested directly on a hand-built
    /// ring (see the property unittest near the K5-asymmetric parity
    /// fixtures) without needing a full bevel + reference dump.
    static void centerNormalProject(int N, Vec3 hub, Vec3[] newCv) {
        if (N < 1 || cast(int)newCv.length != N) return;
        int prv(int i) { return (i + N - 1) % N; }
        Vec3[] newCv0 = newCv.dup;
        Vec3 crossSum = Vec3(0, 0, 0);
        foreach (i; 0 .. N) {
            immutable Vec3 a = newCv0[prv(i)] - hub;
            immutable Vec3 b = newCv0[i] - hub;
            immutable Vec3 cr = cross(a, b);
            immutable float crLen = cr.length;
            if (crLen > 1e-12f) crossSum = crossSum + cr / crLen;
        }
        immutable float sumLen = crossSum.length;
        if (sumLen > 1e-12f) {
            immutable Vec3 Navg = crossSum / sumLen;
            foreach (j; 0 .. N) {
                immutable float t = dot(hub - newCv[j], Navg);
                newCv[j] = newCv[j] + Navg * t;
            }
        }
        // else: Navg degenerate (near-zero average ring normal) — leave
        // newCv unchanged, mirroring the reference's implicit non-degenerate
        // assumption (never hit on real, non-self-intersecting junction
        // geometry).
    }

    /// Vertex bevel: for each selected interior-manifold vertex v, split each
    /// incident edge at v + amount*normalize(other−v) (one new vertex per edge,
    /// shared by the two adjacent faces), rewrite every incident face to replace
    /// v with its two split points in face-ring order, and append an
    /// outward-wound cap N-gon through those split points.
    ///
    /// Interior-manifold guard: every incident edge of v must be shared by
    /// exactly 2 faces and valence must be ≥ 3. Boundary and wire-edge vertices
    /// are silently skipped. Adjacent selected vertices are handled via a greedy
    /// vertex-disjoint selection so no two accepted vertices share an edge.
    ///
    /// Cap material/subpatch are carried from one incident face of v — NOT the
    /// chamfer-literal 0u. Rewritten-face attributes are 1:1 from the original
    /// slot.
    ///
    /// Returns the count of vertices actually processed (0 ⇒ no-op, caller
    /// should discard snapshot).
    size_t bevelVerticesByMask(const bool[] maskIn, float amount) {
        const mask = maskMinusHiddenVertices(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
        if (mask.length != vertices.length) return 0;
        if (amount < 1e-6f) return 0;

        // local helpers
        uint succInFace_(uint fi, uint v) const {
            auto f = faces[fi];
            foreach (k; 0 .. f.length)
                if (f[k] == v) return f[(k+1)%f.length];
            return uint.max;
        }
        uint predInFace_(uint fi, uint v) const {
            auto f = faces[fi];
            foreach (k; 0 .. f.length)
                if (f[k] == v) return f[(k + f.length - 1)%f.length];
            return uint.max;
        }

        // edge→(≤2 faces) adjacency, one pass
        auto edgeFacesMap = buildEdgeFaces();

        // greedy vertex-disjoint acceptance
        bool[] accepted           = new bool[](vertices.length);
        bool[] neighborOfAccepted = new bool[](vertices.length);
        size_t processed          = 0;

        foreach (vi; 0 .. cast(uint)vertices.length) {
            if (vi >= mask.length || !mask[vi]) continue;
            if (neighborOfAccepted[vi]) continue;

            // incident edges in half-edge ring order
            uint[] incEdges;
            foreach (ei; edgesAroundVertex(vi)) incEdges ~= ei;
            if (incEdges.length < 3) continue;

            // interior-manifold: every incident edge shared by exactly 2 faces
            bool manifold = true;
            foreach (ei; incEdges) {
                ulong key = edgeKey(edges[ei][0], edges[ei][1]);
                auto fp = key in edgeFacesMap;
                if (fp is null || (*fp)[0] < 0 || (*fp)[1] < 0) {
                    manifold = false; break;
                }
            }
            if (!manifold) continue;

            accepted[vi] = true;
            ++processed;
            foreach (ei; incEdges) {
                uint other = edgeOtherVertex(cast(uint)ei, vi);
                if (other < neighborOfAccepted.length)
                    neighborOfAccepted[other] = true;
            }
        }
        if (processed == 0) return 0;

        // Freeze original count before addVertex grows the array.
        const uint origVertCount = cast(uint)vertices.length;

        // one split vertex per incident edge of each accepted v
        uint[ulong]  splitByKey;  // edgeKey(a,b) → new vertex index
        uint[][uint] capRings;    // vi → ordered split-vert indices for cap
        uint[uint]   capSrc;      // vi → one incident fi (attr carry)

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;

            uint[] ring;
            foreach (ei; edgesAroundVertex(vi)) {
                ulong key = edgeKey(edges[ei][0], edges[ei][1]);
                if (key !in splitByKey) {
                    uint other = edgeOtherVertex(cast(uint)ei, vi);
                    Vec3 sp = vertices[vi] +
                              amount * safeNormalize(vertices[other] - vertices[vi]);
                    splitByKey[key] = addVertex(sp);
                }
                ring ~= splitByKey[key];
            }
            capRings[vi] = ring;

            foreach (fi; facesAroundVertex(vi)) { capSrc[vi] = cast(uint)fi; break; }
        }

        // per-face substitution map: accepted vi → [sp_pred, sp_succ]
        VertSub[][uint] faceSubs;

        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;
            foreach (fi; facesAroundVertex(vi)) {
                uint p    = predInFace_(cast(uint)fi, vi);
                uint s    = succInFace_(cast(uint)fi, vi);
                uint spPV = splitByKey[edgeKey(p, vi)];
                uint spVS = splitByKey[edgeKey(vi, s)];
                faceSubs.require(cast(uint)fi) ~= VertSub(vi, [spPV, spVS]);
            }
        }

        // single rebuild pass: rewritten faces then cap faces
        uint[][] newFaces;
        uint[]   newMat;
        uint[]   newPart;
        int[]    newOrd;
        uint[]   newWord;   // whole faceMarks word per new face (task 0613 §4.2)

        // (a) surviving / substituted faces
        foreach (fi; 0 .. faces.length) {
            auto orig  = faces[fi];
            newFaces ~= rebuildFaceWithVertexSubs(orig, cast(uint)fi in faceSubs);
            newMat  ~=faceAttrOr(faceMaterial, fi);
            newPart ~=faceAttrOr(facePart, fi);
            newOrd  ~=faceAttrOr(faceSelectionOrder, fi);
            newWord ~= faceAttrOr(faceMarks, fi);
        }

        // (b) cap faces — attrs carried from capSrc, not the chamfer 0u literal
        size_t capStart = newFaces.length;
        foreach (vi; 0 .. origVertCount) {
            if (!accepted[vi]) continue;

            uint[] capRing = capRings[vi].dup;
            int    Ncap    = cast(int)capRing.length;

            // outward-winding check: Newell normal vs averaged incident-face normal
            Vec3 newellN = Vec3(0, 0, 0);
            foreach (k; 0 .. Ncap) {
                Vec3 a = vertices[capRing[k]];
                Vec3 b = vertices[capRing[(k+1)%Ncap]];
                newellN.x += (a.y - b.y) * (a.z + b.z);
                newellN.y += (a.z - b.z) * (a.x + b.x);
                newellN.z += (a.x - b.x) * (a.y + b.y);
            }
            Vec3 avgFaceN = Vec3(0, 0, 0);
            foreach (fi; facesAroundVertex(vi)) {
                Vec3 fn = faceNormal(cast(uint)fi);
                avgFaceN.x += fn.x; avgFaceN.y += fn.y; avgFaceN.z += fn.z;
            }
            float dot = newellN.x*avgFaceN.x +
                        newellN.y*avgFaceN.y +
                        newellN.z*avgFaceN.z;
            if (dot < 0) {
                for (int lo = 0, hi = Ncap - 1; lo < hi; ++lo, --hi) {
                    uint tmp = capRing[lo]; capRing[lo] = capRing[hi]; capRing[hi] = tmp;
                }
            }

            uint srcFi = capSrc[vi];
            newFaces ~= capRing;
            newMat   ~=faceAttrOr(faceMaterial, srcFi);
            newPart  ~=faceAttrOr(facePart, srcFi);
            newOrd   ~= 0;
            newWord  ~= faceAttrOr(faceMarks, srcFi);
        }

        // (c) commit arrays
        faces              = newFaces;
        faceMaterial       = newMat;
        facePart           = newPart;
        faceSelectionOrder = newOrd;

        // Rebuild faceMarks: zero all, then restore the whole word (task 0613
        // §4.2 — was Subpatch-only).
        setFaceMarksFrom(newWord, ~Marks.Select);

        faceSelectionOrderCounter = 0;
        foreach (fi; capStart .. faces.length)
            selectFace(cast(int)fi);
        resizeVertexSelection();
        clearVertexSelection();
        clearEdgeSelectionResize();

        finalizeTopologyEdit();
        commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
        return processed;
    }
}
