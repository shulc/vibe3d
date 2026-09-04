module mesh_ops.edge_bevel;

import mesh;
import std.math : sqrt;
import math;
import mesh_edit_delta : MeshEditScope;
import mesh_planes : rewriteFaces, FaceSource, kNoSource;
// Was a SCOPED import inside the template body: a `mixin template`'s body is
// looked up in the INSTANTIATION scope (struct Mesh, in mesh.d), so an import
// written at the top of this module did not reach the kernel — measured, task
// 0717. With the template gone the ordinary module-level import is what the
// kernel sees, and the dependency stays declared where it is used.
import mesh_ops.bevel_curves;

// ---------------------------------------------------------------------------
// The MANIFOLD EDGE BEVEL family — one kernel, `bevelEdgesByMask`, plus the
// family's declared edit class `kEdgeBevelEditScope`.
//
// MODULE-LEVEL FREE FUNCTIONS over the edit seam since task 1903 Stage G
// (was `mixin template MeshEdgeBevelOps`, mixed into `struct Mesh`). Split out
// of mesh.d before that by the mesh.d decomposition campaign (0407 §B.V2 —
// task 0412's doc records why a mixin template was chosen over a package move
// or free functions at the time; 1903 §4.1 is why that answer changed).
//
// ONE RECEIVER CLASS, because this file has one entry and it mutates:
// `ref MeshEditBatch ed`. The kernel appends chamfer-rail, miter and hub
// vertices, appends strip/cap faces, rewrites `faces` TWICE through
// `mesh_planes.rewriteFaces`, resizes the mark/material/part/set planes,
// compacts, and ends in `commitChange(Geometry | Marks)`. The batch is what
// turns that tail — plus every intermediate `addVertex` / `addFace` stamp —
// into ONE deferred stamp at `close()`.
//
// THE THREE PARITY FIELDS ARE STILL MEMBERS OF `Mesh`, AND THAT IS A DECISION,
// NOT AN OVERSIGHT (plan §2.7's rule for this family, taken at Stage G).
// `bevelPinnedOrphans_` / `bevelCapCoincidentPos_` / `bevelCapOrphanPos_` used
// to be injected into `struct Mesh` by this template; a free function cannot
// inject anything, so their DECLARATION moved into `struct Mesh` itself
// (source/mesh.d, beside the other per-op scratch state) and every spelling —
// the three resets and the three appends here, the three reads in
// `tests/unit/mesh_bevel_census_test.d`, the two in
// `tests/unit/mesh_ops/edge_bevel_test.d` — is unchanged. The alternative
// (return them beside the count in a result struct) was declined because it is
// a SECOND edit hiding inside a move: it rewrites three call sites in two
// modules that this conversion otherwise does not touch, and §2.7 already says
// cross-module output state stays on `Mesh`.
//
// Their VISIBILITY is unchanged too, and deliberately so: a mixin-injected
// member with no access specifier is PUBLIC, so these three have always been
// public members of `Mesh` and this stage neither widens nor narrows anything.
// What holds that is a TEXT CENSUS ROW naming the declaration site and both
// reader files, not the build — module- and struct-scope `private` in D
// restricts NAME LOOKUP and nothing else (plan §2.7 as corrected at the F1
// review), so a green build would be green whatever those readers did.
//
// THE FIN-BUNDLE HAND-OFF IS A PLAIN CALL AGAIN. Stage E4 converted
// `mesh_ops/bevel_fin.d` while this body was still a mixin, which forced each
// of the two early returns to open a TRANSITIONAL `unrecorded` batch (§4.4a's
// debt shape, with Stage G named as its removing stage). Stage G is this
// commit and both are gone: the caller's batch is the only one on the stack.
// ---------------------------------------------------------------------------

/// The edit class this kernel declares, in ONE place — the same shape D2's
/// `kReduceEditScope`, E4's `kBevelFinEditScope` and F2's `kPolyBevelEditScope`
/// carry. `Geometry` (= `Points | Polygons`): the kernel appends rail, miter,
/// hub and cap vertices and appends chamfer strips and cap faces. `Marks`:
/// it ORs the two host faces' subpatch/set words into each new strip's and
/// rewrites the face selection at the tail.
///
/// `Position` is ABSENT, and that is measurable rather than stylistic: this
/// kernel never moves an EXISTING vertex — every new coordinate is an
/// `ed.addVertex` argument — which is the same property that makes this
/// file's §5.7 raw-position-write row a clean `== 0`.
///
/// The kernel's own `commitChange` keeps its literal spelling, exactly as
/// cut.d, cleanup.d, bevel_vertex.d and poly_bevel.d do — and because the two
/// CAN drift (a caller declares this constant, the kernel stamps a literal),
/// a census row binds them (Stage F2 review, MINOR-2).
enum uint kEdgeBevelEditScope = MeshEditScope.Geometry | MeshEditScope.Marks;

/// Edge bevel (Candidate A — slide-along-adjacent-edge, generalized).
///
/// Replaces every qualifying selected edge with a chamfer strip (a flat
/// quad at `roundLevel==0`, or `2·roundLevel` rings at `roundLevel>0`.
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
///     `bevelMiterPoint` — the point in the PLANE OF THOSE TWO EDGES at
///     perpendicular distance `width` from both of their lines, with the
///     face's whole-ring normal deciding only which of the two such
///     points is the inward one (measured law, task 1170).
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
/// `roundLevel` subdivides every eligible cross-section into `2·L`
/// segments (L≥1; L==0 is the separate flat-chamfer path, one segment).
/// `2·L` equals `2^L` only at L≤2, which is why the old `1<<roundLevel`
/// looked right — see the note beside the junction law below.
/// A rail is owned by its two already-resolved L0 endpoint
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
size_t bevelEdgesByMask(ref MeshEditBatch ed, const bool[] maskIn, float width,
                        int roundLevel = 0, bool widthMode = false) {
    const mask = ed.maskMinusHiddenEdges(maskIn);  // §3.3 backstop (task 0613) — see maskMinusHidden* in mesh.d
    if (width < 1e-6f) return 0;
    if (mask.length != ed.edges.length) return 0;
    // Settled-mesh precondition (debug-only, stripped from release builds
    // — task 0724 / audit-4 M6). The open-fan rim arm resolves each
    // bordering edge's selection through edgeIndexMap (`selectedEdge`),
    // and it does so against the state the CALLER handed us: this kernel
    // mutates no topology before that point (verified — no addEdge /
    // addFace / rebuildEdges between here and there). A stale map indexes
    // `qualifies[]` — the mask the caller just passed — with the previous
    // topology's edge number, so the arm reads the WRONG edge's selection
    // bit and picks the wrong slide direction, with no error anywhere.
    ed.assertEdgeMapValid();

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
    immutable size_t savedVertCount = ed.vertices.length;

    // Reset the valence-4 free-end cap parity bookkeeping for this call
    // (see the field declarations). Populated only when a qualifying cap
    // is emitted below; empty otherwise, so this is a no-op for every
    // ordinary bevel.
    ed.bevelPinnedOrphans_.length     = 0;
    ed.bevelCapCoincidentPos_.length  = 0;
    ed.bevelCapOrphanPos_.length      = 0;

    // Edge→(≤2 faces) adjacency, one pass (same idiom as extrudeEdgesByMask).
    auto edgeFaces = ed.buildEdgeFaces();

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
        auto faceUse = ed.edgeFaceUseCounts();
        bool anyGE3 = false;
        foreach (i; 0 .. ed.edges.length)
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
            foreach (i; 0 .. ed.edges.length) {
                if (!mask[i]) continue;
                selEdges ~= cast(uint)i;
                if (i < faceUse.length && faceUse[i] >= 3) {
                    spine = cast(uint)i; ++spineCount;
                }
            }
            if (spineCount != 1) return 0;

            // TASK 1903 Stage G — THE TRANSITIONAL BATCHES ARE GONE.
            // Stage E4 converted the two fin-bundle kernels to free
            // functions over `ref MeshEditBatch` while THIS body was still
            // a mixin instantiated in `struct Mesh`, so each hand-off had
            // to open an `unrecorded` batch of its own — §4.4a's debt
            // shape, with Stage G named as the stage that removes it.
            // Stage G is this commit: `bevelEdgesByMask` takes the batch
            // now, so the hand-off is a plain call and the CALLER's batch
            // is the only one on the stack. Nothing else about these two
            // arms changed; the batch that used to open here is the batch
            // `mesh.bevel` / `EdgeBevelTool` open at their own boundary.
            //
            // What still watches this seam: the per-command
            // `changeBus.nestedBatchOpens` DELTA in
            // `tests/test_bevel_fin_bundle.d`, which loads a three-fin
            // bundle through `/api/load-mesh` because this branch is
            // UNREACHABLE from a cube. It read 0 with the transitional
            // opens (they were the OUTERMOST batch then) and reads 0 now
            // (there is no second open at all) — so it is not the row that
            // proves the removal; the census row that counts
            // `MeshEditBatch.unrecorded(` in this file at ZERO is.
            // `tests/test_edge_bevel_tool.d` carries the same delta on the
            // TOOL door, which E4's review left as MINOR-5 for whoever
            // reached this branch first.
            if (selEdges.length == 1)
                return ed.bevelIsolatedFinBundleSpine(spine, width);
            uint[] extras;
            foreach (e; selEdges) if (e != spine) extras ~= e;
            return ed.bevelFinBundleSpineMultiEdge(spine, extras, width);
        }
    }

    bool[] qualifies = new bool[](ed.edges.length);
    bool[] rimOnly   = new bool[](ed.edges.length);
    size_t nQual = 0;
    foreach (i; 0 .. ed.edges.length) {
        if (!mask[i]) continue;
        uint v0 = ed.edges[i][0], v1 = ed.edges[i][1];
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
        edgeFactor = new float[](ed.edges.length);
        edgeFactor[] = 1.0f;
        foreach (i; 0 .. ed.edges.length) {
            if (!qualifies[i] || rimOnly[i]) continue;
            auto fp = edgeKey(ed.edges[i][0], ed.edges[i][1]) in edgeFaces;
            if (fp is null || (*fp)[0] < 0 || (*fp)[1] < 0) continue;
            immutable Vec3 nA = ed.faceNormal(cast(uint)(*fp)[0]);
            immutable Vec3 nB = ed.faceNormal(cast(uint)(*fp)[1]);
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
    //
    // Task 0830: `rwB` is the obligation handle — the capture this kernel
    // used to take by hand, plus the arming that makes the DROP the default
    // outcome of saying nothing between here and the declaration.
    auto rwB = ed.beginCornerRewrite();
    const bool remapUvB = rwB.active();
    PolyVertexBlend[uint] vertBlendB;   // new vertex → blend of ORIGINALS
    uint[][size_t]        srcByNewFace; // index in `newFaces` → per-corner source

    // Step 2: affected vertices = endpoints of any qualifying edge.
    bool[] affected = new bool[](ed.vertices.length);
    foreach (i; 0 .. ed.edges.length) {
        if (!qualifies[i]) continue;
        affected[ed.edges[i][0]] = true;
        affected[ed.edges[i][1]] = true;
    }

    // Safety preflight. Two supported fan shapes reach the per-vertex pass
    // below: CLOSED (interior vertex, nE == d) and OPEN (boundary vertex,
    // nE == d + 1 — `VertexEdgeRange` anchors at the open start of the fan
    // and emits one extra rim edge). In both, face f_k is bordered by edge
    // slots k and k+1; only the closed fan wraps.
    foreach (V; 0 .. cast(uint)ed.vertices.length) {
        if (V >= affected.length || !affected[V]) continue;
        size_t d = 0;
        foreach (fi; ed.facesAroundVertex(V)) ++d;
        bool[] fanSelected;
        foreach (ei; ed.edgesAroundVertex(V))
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
        const float farLen = (ed.vertices[to] - ed.vertices[from]).length;
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
    Mesh.VertSub[][uint] faceSubs;

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
    alias pairKey = edgeKey;        // the tree's one (min,max) pack (task 4066)
    // The neighbor of `Vv` inside face `fi` that is NOT `farV` — i.e. the
    // "other" edge of `fi` at `Vv` besides the rail edge (Vv,farV). Its slide
    // point is the finding-(I) pivot the ADJACENT side contributes to this
    // rail (never the rail's own edge). Used to build `jvA`/`jvB`.
    uint otherFaceNeighbor(uint Vv, uint farV, uint fi) {
        auto ring = ed.faces[fi];
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
        foreach (fi; ed.facesAroundVertex(V)) ++nf;
        foreach (ei; ed.edgesAroundVertex(V)) ++ne;
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
            foreach (fi; ed.facesAroundVertex(centerVert))
                sn = sn + safeNormalize(ed.faceNormal(cast(uint)fi));
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
            immutable Vec3 P0 = ed.vertices[aV], P3 = ed.vertices[bV];
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
            immutable Vec3 EA = ed.vertices[lo];
            immutable Vec3 EB = ed.vertices[hi];
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
            foreach (t; 1 .. n) interior[t - 1] = ed.addVertex(pts[t]);
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

    foreach (V; 0 .. cast(uint)ed.vertices.length) {
        if (V >= affected.length || !affected[V]) continue;

        uint[] vFaces, vEdges, vNbrs;
        foreach (fi; ed.facesAroundVertex(V)) vFaces ~= fi;
        foreach (ei; ed.edgesAroundVertex(V)) vEdges ~= ei;
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
        if (openFan && d == 1 && ed.vertexFanOrdered(V)) {
            immutable uint fRim = vFaces[0];
            auto rimRing = ed.faces[fRim];
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
                auto p = edgeKey(a, b) in ed.edgeIndexMap;
                return p !is null && *p < qualifies.length && qualifies[*p];
            }
            immutable bool predSel = selectedEdge(V, predV);
            immutable bool succSel = selectedEdge(V, succV);
            // Exactly one bordering edge selected (K == 1) is the measured
            // shape. Anything else (both edges beveled, or a degenerate
            // ring) is unmeasured — fall through to the generic guard,
            // which declines it. No extrapolation.
            if (predSel != succSel) {
                immutable Vec3 vp = ed.vertices[V];
                if (succSel) {
                    // V = P0 (first, edge V->succ is the beveled one): a
                    // single slide along the UNSELECTED predecessor edge.
                    immutable Vec3 dir = safeNormalize(ed.vertices[predV] - vp);
                    immutable float w = clampedWidth(V, predV);
                    immutable uint nv = ed.addVertex(vp + dir * w);
                    cornerAtVF[vfKey(V, fRim)] = CornerInfo(
                        nv, CornerKind.Slide, w < width, 1u, false, dir);
                    faceSubs.require(fRim) ~= Mesh.VertSub(V, [nv]);
                } else {
                    // V = P1 (second, edge pred->V is the beveled one): two
                    // corners in the face's own traversal order — the
                    // beveled-edge slide toward the selected predecessor
                    // (NEVER clamped, measured), then the other-edge slide
                    // toward the unselected successor (clamped like any
                    // slide).
                    immutable Vec3 bdir = safeNormalize(ed.vertices[predV] - vp);
                    immutable uint nvBev = ed.addVertex(vp + bdir * width);
                    immutable Vec3 odir = safeNormalize(ed.vertices[succV] - vp);
                    immutable float ow = clampedWidth(V, succV);
                    immutable uint nvOth = ed.addVertex(vp + odir * ow);
                    cornerAtVF[vfKey(V, fRim)] = CornerInfo(
                        nvOth, CornerKind.Slide, ow < width, 1u, false, odir);
                    faceSubs.require(fRim) ~= Mesh.VertSub(V, [nvBev, nvOth]);
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
        if (!ed.vertexFanOrdered(V)) continue;
        vNbrs.length = nE;
        foreach (k; 0 .. nE) vNbrs[k] = ed.edgeOtherVertex(vEdges[k], V);

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
            immutable Vec3 n0f = ed.faceNormal(vFaces[0]);
            bool planarf = true;
            foreach (kf; 1 .. d)
                if (dot(n0f, ed.faceNormal(vFaces[kf])) < 0.999f) { planarf = false; break; }
            // Trigger #2 — the selected edge lands on a FULL HUB (every
            // incident edge there selected), forcing the same retained-
            // original cap even on non-planar geometry (F4's 90° crease).
            int sf = -1;
            foreach (kf; 0 .. nE) if (selE[kf]) { sf = kf; break; }
            immutable uint farVf = vNbrs[sf];
            int farDeg = 0, farK = 0;
            foreach (fef; ed.edgesAroundVertex(farVf)) {
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

        immutable Vec3 vpos = ed.vertices[V];
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
            Vec3 dir = safeNormalize(ed.vertices[vNbrs[k]] - vpos);
            immutable float effW = slideEffWidth(k);
            immutable float farLen = (ed.vertices[vNbrs[k]] - vpos).length;
            immutable float w = (farLen > 1e-9f && effW >= farLen) ? farLen : effW;
            uint nv = ed.addVertex(vpos + dir * w);
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
        Vec3 slideDir(int k) { return safeNormalize(ed.vertices[vNbrs[k]] - vpos); }

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
                Vec3 ePrev = safeNormalize(ed.vertices[vNbrs[kr]] - vpos);
                Vec3 eNext = safeNormalize(ed.vertices[vNbrs[k]]  - vpos);
                // Both bordering edges are beveled; each contributes its own
                // along-face offset. In width mode that is `width/sin(θ/2)`
                // per edge (its `edgeFactor`); in inset mode both stay the
                // raw `width` (empty array), so the meet is byte-identical.
                immutable float wPrev = (edgeFactor.length && vEdges[kr] < edgeFactor.length)
                    ? width * edgeFactor[vEdges[kr]] : width;
                immutable float wNext = (edgeFactor.length && vEdges[k] < edgeFactor.length)
                    ? width * edgeFactor[vEdges[k]] : width;
                // The mitre point is in the PLANE OF THE TWO BEVELLED
                // EDGES, at perpendicular distance w from each of their
                // lines — measured, task 1170 / ledger row 1. The face's
                // whole-ring Newell normal is passed for the BRANCH ONLY
                // (which of the two such points points into the face); it
                // does not decide the plane. See `math.bevelMiterPoint`.
                Vec3 m = bevelMiterPoint(vpos, ePrev, eNext, ed.faceNormal(fi), wPrev, wNext);
                uint nv = ed.addVertex(m);
                cornerAtVF[vfKey(V, fi)] = CornerInfo(
                    nv, CornerKind.Miter, false, cast(uint)K, isFullHub, Vec3(0,0,0));
                faceSubs.require(fi) ~= Mesh.VertSub(V, [nv]);
            } else if (selSucc != selPred) {
                // SLIDE: exactly one bordering edge selected — corner
                // slides along the OTHER (unselected) one.
                immutable int unselK = selSucc ? kr : k;
                uint nv = getSlide(unselK);
                cornerAtVF[vfKey(V, fi)] = CornerInfo(
                    nv, CornerKind.Slide, slideClamped[unselK], cast(uint)K, isFullHub, slideDir(unselK));
                faceSubs.require(fi) ~= Mesh.VertSub(V, [nv]);
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
                faceSubs.require(fi) ~= Mesh.VertSub(V, [sPred, sSucc]);
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
            // ...but only if those corners are d DISTINCT POINTS. Two of
            // them at the same position do not trace a K-gon, and every
            // consumer downstream assumes they do: the flat cap becomes a
            // ring with a repeated corner (a zero-area face and a
            // non-manifold edge once the identity pool merges the two), and
            // the L>=1 Gregory ring builds a patch side whose two ends are
            // one point.
            //
            // Reachable since task 1170 and by exactly one route. The
            // ported mitre reads only the two bevelled edge DIRECTIONS, so
            // two faces at one vertex whose ring-edge pairs span the same
            // directions get the same point — which needs two of the
            // vertex's edges to be exactly parallel. That is the
            // `parallel-edge K3 hub` fixture in the unittests, built that
            // way on purpose; the coincidence is what the measured law
            // says, and it is the CAP that has no meaning, not the mitres.
            //
            // Dropping the registration is what L0 already did downstream
            // (a ring with fewer than 3 distinct corners emits no face);
            // doing it here makes L0, L1 and L2 agree instead of leaving
            // the rounded paths to build on a ring the flat path rejects.
            // No reference capture covers a degenerate hub at any level
            // (task 0707), so this is not a parity claim — it is the
            // structural precondition that keeps the output a mesh.
            bool distinctCorners = true;
            scan: foreach (k; 0 .. d)
                foreach (j; k + 1 .. d)
                    if ((ed.vertices[ring[k]] - ed.vertices[ring[j]]).length <= 1e-9f) {
                        distinctCorners = false;
                        break scan;
                    }
            if (distinctCorners) {
                hubCapRing[V] = ring;
                hubCapSrc[V]  = vFaces[0];
            }
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
                    ed.bevelPinnedOrphans_    ~= orphanSlide;
                    ed.bevelCapCoincidentPos_ ~= vpos;
                    ed.bevelCapOrphanPos_     ~= ed.vertices[orphanSlide];
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
        ed.vertices.length = savedVertCount; // undo any addVertex from the per-vertex pass
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
    foreach (i; 0 .. ed.edges.length) {
        if (!qualifies[i]) continue;
        uint v0 = ed.edges[i][0], v1 = ed.edges[i][1];
        auto fp = edgeKey(v0, v1) in edgeFaces;
        if (rimOnly[i]) {
            immutable uint fOnly = cast(uint)(*fp)[0];
            if (vfKey(v0, fOnly) in cornerAtVF && vfKey(v1, fOnly) in cornerAtVF)
                ++rimProcessed;
            continue;
        }
        int fa = (*fp)[0], fb = (*fp)[1];
        uint fL = uint.max, fR = uint.max;
        foreach (k; 0 .. ed.faces[fa].length) {
            uint u = ed.faces[fa][k], w = ed.faces[fa][(k + 1) % ed.faces[fa].length];
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
        ed.vertices.length = savedVertCount; // undo any addVertex from the per-vertex pass
        return 0;
    }
    immutable size_t processed = spans.length + rimProcessed;

    // Resolve every original face to its L0 boundary before rounded
    // vertices exist.  This is also the authoritative support-consumer
    // inventory, rather than an optimistic post-materialization guess.
    uint[][] baseFaces;
    foreach (fi; 0 .. ed.faces.length) {
        auto orig = ed.faces[fi];
        baseFaces ~= Mesh.rebuildFaceWithVertexSubs(orig, cast(uint)fi in faceSubs);
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
            return ed.vertices[Vv] + safeNormalize(ed.vertices[o] - ed.vertices[Vv]) * width;
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
            registerRail(cV0L, cV0R, ed.vertices[sp.v0], sp.v0, ed.vertices[sp.v1],
                         neighPivot(sp.v0, sp.v1, sp.fL), neighPivot(sp.v0, sp.v1, sp.fR));
            registerRail(cV1L, cV1R, ed.vertices[sp.v1], sp.v1, ed.vertices[sp.v0],
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
            immutable Vec3 hp  = ed.vertices[Vn];
            immutable uint glo = min(plan.gapEndL, plan.gapEndR);
            immutable uint ghi = max(plan.gapEndL, plan.gapEndR);
            immutable Vec3 loP = ed.vertices[glo], hiP = ed.vertices[ghi];
            uint[] interior = new uint[](nn - 1);
            foreach (t; 1 .. nn)
                interior[t - 1] = ed.addVertex(slerpAbout(hp, loP, hiP, cast(float)t / cast(float)nn));
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
    uint[]   oldOfNew;   // newToOld correspondence — task 1902, mesh_planes.rewriteFaces
                          // carries faceMarks/faceMaterial/facePart/faceSelectionOrder/
                          // faceSetMask from this in one pass.
    // Two chamfer-strip faces below fold TWO source faces' faceMarks
    // into one word (combineFaceMarksWords) — a value no single
    // `oldOfNew` entry can express (kNoSource zeroes all five planes
    // uniformly). Recorded here (new-face index → folded word) and
    // patched onto `faceMarks` right after `rewriteFaces`, before the
    // tail `setFaceMarksFrom` masks Select out of everything (plan
    // §2.7a: "two edge_bevel.d sites of a shape the primitive cannot
    // express directly").
    uint[] chamferWordIdx;
    uint[] chamferWordVal;

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
        oldOfNew ~= cast(uint)fi;
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
        immutable uint word = Mesh.combineFaceMarksWords(Mesh.faceAttrOr(ed.faceMarks, sp.fL),
                                                     Mesh.faceAttrOr(ed.faceMarks, sp.fR));

        if (roundLevel == 0 || !roundedSpan[si]) {
            newFaces ~= [cV0L.vert, cV1L.vert, cV1R.vert, cV0R.vert];
            // THE per-corner case: each side of the strip reads the face it
            // slid out of (task 0697).
            if (remapUvB)
                noteSrc(newFaces.length - 1, [sp.fL, sp.fL, sp.fR, sp.fR]);
            oldOfNew ~= kNoSource;
            chamferWordIdx ~= cast(uint)(newFaces.length - 1);
            chamferWordVal ~= word;
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
            oldOfNew ~= kNoSource;
            chamferWordIdx ~= cast(uint)(newFaces.length - 1);
            chamferWordVal ~= word;
        }
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
            Vec3 a = ed.vertices[ring[k]];
            Vec3 b = ed.vertices[ring[(k + 1) % Ncap]];
            newellN.x += (a.y - b.y) * (a.z + b.z);
            newellN.y += (a.z - b.z) * (a.x + b.x);
            newellN.z += (a.x - b.x) * (a.y + b.y);
        }
        Vec3 avgFaceN = Vec3(0, 0, 0);
        foreach (fi; ed.facesAroundVertex(V)) {
            Vec3 fn = ed.faceNormal(cast(uint)fi);
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
                poleP[i] = ed.vertices[poleI[i]];
                // TRUE boundary-Bézier handles for side i, oriented to the ring
                // order pole_i→pole_{i+1} (bezP1/bezP2 are stored canonical
                // a→b) — the same orientation dance the N≥4 caller does.
                immutable bool fwd = poleI[i] < poleI[nx];
                p1s[i] = fwd ? railSpec.bezP1 : railSpec.bezP2;
                p2s[i] = fwd ? railSpec.bezP2 : railSpec.bezP1;
            }
            Vec3 hubPos; Vec3[] spokeP, interiorP;
            if (ok && junctionRing(poleP[], p1s[], p2s[], L, hubPos, spokeP, interiorP)) {
                immutable uint hubIdx = ed.addVertex(hubPos);
                uint[][3] spokeIdx, interiorIdx;
                foreach (i; 0 .. 3) {
                    spokeIdx[i].length = m;
                    foreach (k; 0 .. m) spokeIdx[i][k] = ed.addVertex(spokeP[i * m + k]);
                    interiorIdx[i].length = m * m;
                    foreach (k; 0 .. m * m) interiorIdx[i][k] = ed.addVertex(interiorP[i * m * m + k]);
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
                        oldOfNew ~= srcFi;
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
                poleP[i] = ed.vertices[poleI[i]];
                immutable bool fwd = poleI[i] < poleI[nx];
                // Orient the stored (canonical a→b) handles to pole_i→pole_{i+1}.
                p1s[i] = fwd ? railSpec.bezP1 : railSpec.bezP2;
                p2s[i] = fwd ? railSpec.bezP2 : railSpec.bezP1;
            }
            Vec3 hubPos; Vec3[] spokeP, interiorP;
            if (ok && junctionRingN(poleP, p1s, p2s, N, L, hubPos, spokeP, interiorP)) {
                immutable uint hubIdx = ed.addVertex(hubPos);
                uint[][] spokeIdx;    spokeIdx.length    = N;
                uint[][] interiorIdx; interiorIdx.length = N;
                foreach (i; 0 .. N) {
                    spokeIdx[i].length = m;
                    foreach (k; 0 .. m) spokeIdx[i][k] = ed.addVertex(spokeP[i * m + k]);
                    interiorIdx[i].length = m * m;
                    foreach (k; 0 .. m * m) interiorIdx[i][k] = ed.addVertex(interiorP[i * m * m + k]);
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
                        oldOfNew ~= srcFi;
                    }
                continue;
            }
        }

        newFaces ~= ring;
        oldOfNew ~= srcFi;
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
            immutable Vec3 apexP = ed.vertices[apex];
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
                immutable Vec3 aL = ed.vertices[arcL[i]], aR = ed.vertices[arcR[i]];
                foreach (j; 1 .. n)
                    Gint[i][j] = ed.addVertex(slerpAbout(apexP, aL, aR, cast(float)j / cast(float)n));
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
                    Vec3 a = ed.vertices[f[k]], b = ed.vertices[f[(k + 1) % f.length]];
                    gN.x += (a.y - b.y) * (a.z + b.z);
                    gN.y += (a.z - b.z) * (a.x + b.x);
                    gN.z += (a.x - b.x) * (a.y + b.y);
                }
            Vec3 avgN = Vec3(0, 0, 0);
            foreach (fi; ed.facesAroundVertex(V)) {
                Vec3 fn = ed.faceNormal(cast(uint)fi);
                avgN.x += fn.x; avgN.y += fn.y; avgN.z += fn.z;
            }
            immutable bool flip = dot(gN, avgN) < 0;
            immutable uint srcFiN = freeEndCapSrc[V];
            foreach (ref f; gridFaces) {
                if (flip) reverse(f);
                newFaces ~= f;
                oldOfNew ~= srcFiN;
            }
            continue;
        }

        uint[] ring = ring_.dup;
        immutable int Ncap = cast(int)ring.length;
        Vec3 newellN = Vec3(0, 0, 0);
        foreach (k; 0 .. Ncap) {
            Vec3 a = ed.vertices[ring[k]];
            Vec3 b = ed.vertices[ring[(k + 1) % Ncap]];
            newellN.x += (a.y - b.y) * (a.z + b.z);
            newellN.y += (a.z - b.z) * (a.x + b.x);
            newellN.z += (a.x - b.x) * (a.y + b.y);
        }
        Vec3 avgFaceN = Vec3(0, 0, 0);
        foreach (fi; ed.facesAroundVertex(V)) {
            Vec3 fn = ed.faceNormal(cast(uint)fi);
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
        oldOfNew ~= srcFi;
    }

    // Assign reconstructed arrays. `rw` is NOT passed here (`rw = null`):
    // `rwB` (opened at the top of this function) declares its own per-
    // corner correspondence through `.carried()` after the SECOND
    // rewrite below (the merge pass) — the shared-`rwB` constraint
    // (plan §2.6): this kernel opens ONE handle and rewrites `faces`
    // TWICE, declaring only once.
    // TASK 1903 STAGE L7-P1 MEASURED THIS ROW AND **DECLINES** THE ARMING
    // (2026-08-28, task 2320). Stage K left both rewrites disarmed on
    // 2026-08-27 and named the SECOND rewrite as the blocker; that is still
    // where the corner defect is, but it is no longer the reason the family
    // stays out. Three findings, all on a `makeTaggedGridFull(3)` stand:
    //
    //   * THE PLAN'S CANDIDATE (b) IS REJECTED — routing this rewrite through
    //     `Mesh.setFaceWindings`, which takes its own before-image, is
    //     impossible: that writer cannot change the face COUNT and this
    //     rewrite does. `faces` goes 9 -> 11 for one interior edge and
    //     9 -> 12 for two. Even the count-neutral rim-edge case (9 -> 9) moves
    //     the CORNER total, 36 -> 37, so the softened version dies too.
    //
    //   * THE PLAN'S CANDIDATE (a) IS BUILDABLE, AND ITS OBVIOUS SPELLING IS
    //     UNSOUND. Two handles, declaring once per rewrite, does work — but
    //     only if the second declaration is a RELOCATION. A `carriedPerFace`
    //     second handle is wrong: the merge pass below writes
    //     `resolvePool(vid0)`, so a merged corner can stand on a vertex its
    //     own source face does not contain, and a carry resolves a source
    //     corner by looking that VERTEX up in the old face. It measured "0 of
    //     72 UV floats differ" anyway — because the pooling fires ZERO times
    //     on these stands, so the cell cannot exhibit the defect it would
    //     have. Do not read that green as evidence. The sound form names each
    //     survivor's exact old loop index, `oldFaceLoop[fi] + ci`, which the
    //     merge pass (a pure corner SUBSET) always has.
    //
    //   * AND NEITHER MATTERS YET, because arming the family surfaces a loss
    //     the disarmed throw was hiding — see the second rewrite below for the
    //     measured residual. That loss is a Point-domain map VALUE, it needs a
    //     payload FIELD on `MeshOpEntry`, and sizing that field is owed to the
    //     stage that serves ALL its consumers, not to this kernel.
    //
    // So the arming is DECLINED here and now, not merely postponed, and
    // `tests/unit/face_reindex_arming_test.d`'s roster is CORRECT at nine
    // sites BECAUSE of this — do not add a tenth for this family.
    rewriteFaces(ed, newFaces, FaceSource(oldOfNew));
    // The two chamfer-strip faces above fold two source faces'
    // faceMarks into one word no single `oldOfNew` entry can express —
    // patch them onto the just-carried `faceMarks` before the tail
    // re-mask below strips Select from everything.
    foreach (i, idx; chamferWordIdx) ed.faceMarks[idx] = chamferWordVal[i];
    // faceSelectionOrder: every face from `chamferStart` on is CREATED
    // (chamfer strip, hub caps, free-end caps) and must start
    // UNSELECTED (order 0), never inheriting whatever stamp its source
    // face happened to carry (was `newOrd ~= 0;` at every one of those
    // emission points, unlike material/part/setmask/marks, which DO
    // inherit via `oldOfNew` above — plan §2.7a). The base range
    // (0 .. chamferStart) keeps its OWN order, already correct via
    // `oldOfNew`'s identity mapping there.
    //
    // Task 1902 Step 0 review finding: this override's effect is USUALLY
    // invisible from outside this function, because the tail below
    // (`faceSelectionOrderCounter = 0; foreach (fi; chamferStart ..
    // rebuiltFaceCount) { ... selectFace(newFi); }`) re-selects every
    // created face that is NOT hidden — not "unconditionally", `selectFace`
    // early-returns on `Marks.Hide` — and overwrites `faceSelectionOrder`
    // for each one it touches regardless of what this override left. The
    // override is observable only for a created face whose donor's
    // `Marks.Hide` bit rode through the `faceMarks` carry above (§2.7):
    // that face is skipped by the tail reselect, so this line — not the
    // reselect — is what leaves its order at 0. See the hub-cap witness
    // in `tests/unit/mesh_ops/edge_bevel_test.d` (K3 L0 hub-cap donor
    // hidden before bevel).
    foreach (i; chamferStart .. ed.faces.length) ed.faceSelectionOrder[i] = 0;

    // Re-mask the just-carried word in place — src here IS faceMarks
    // (self-aliasing; see Mesh.setFaceMarksFrom's own doc comment for
    // why that is safe).
    ed.setFaceMarksFrom(ed.faceMarks, ~Mesh.Marks.Select);

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
        Vec3 d = ed.vertices[a] - ed.vertices[b];
        return d.x * d.x + d.y * d.y + d.z * d.z < 1e-10;
    }
    immutable size_t rebuiltFaceCount = ed.faces.length;

    // Step 1: identity pooling, "lowest surviving index wins" — same
    // discipline as `computeWeldRemap`.
    int[] poolRemap = new int[](ed.vertices.length);
    foreach (i; 0 .. ed.vertices.length) poolRemap[i] = cast(int)i;
    uint resolvePool(uint i) {
        while (poolRemap[i] != cast(int)i) i = cast(uint)poolRemap[i];
        return i;
    }
    foreach (f; ed.faces)
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
    mergedFaces.reserve(ed.faces.length);
    int[] faceRemap = new int[](ed.faces.length);
    // The map's per-corner islands ride the same drops (task 0697): a corner
    // this pass discards takes its source with it, so the survivors stay
    // aligned. A face whose registered array does not match its corner count
    // (an emission path changed shape underneath) falls back to no source at
    // all rather than to a shifted one.
    uint[][] mergedSrc;
    // Task 0921 twin: `faceRemap` below is gathered in survivor order,
    // keyed by each face's OLD index `fi` — the SAME shape (and the
    // same defect, once) as the sibling collapse in
    // `Mesh.applyVertexRemap` (source/mesh.d). Without this, a face
    // collapsed below 3 corners anywhere but the array's tail (Case C)
    // would leave every survivor after it wearing a front-truncated
    // slice of the pre-collapse material/part/marks arrays instead of
    // its own values — `mesh_planes.rewriteFaces`'s
    // `FaceSource.fromOldToNew(faceRemap, ...)` below carries each
    // survivor from its OWN old index `fi`, same as the per-corner (UV)
    // relocate just below already does.
    foreach (fi, f; ed.faces) {
        uint[] kept;
        uint[] keptSrc;
        const uint[] faceSrc = srcByNewFace.get(fi, null);
        const bool   haveSrc = remapUvB && faceSrc.length == f.length;
        kept.reserve(f.length);
        foreach (ci, vid0; f) {
            immutable uint vid = resolvePool(vid0);
            if (kept.length > 0 && vid == kept[$ - 1]) {
                continue; // dup of LAST kept corner: drop, don't update last/first
            }
            if (kept.length > 0 && vid == kept[0]) {
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
    // `rw` is NOT passed here (`rw = null`): `rwB` declares its own
    // per-corner correspondence through `.carried()` right below, on a
    // shape `rewriteFaces`'s own per-NEW-FACE parameter does not match
    // — the shared-`rwB` constraint (plan §2.6): this kernel opens ONE
    // handle and rewrites `faces` twice (the rebuild pass above, this
    // merge pass here), declaring only once, after this second rewrite.
    // TASK 1903 STAGE K MEASURED THIS ROW AND LEFT IT DISARMED (2026-08-27).
    // STAGE L7-P1 RE-MEASURED IT ON 2026-08-28 (task 2320) AND THE ROW MOVED:
    // this call is NO LONGER the reason the family stays out. The corner
    // defect described below is real and is CLOSABLE — giving each rewrite its
    // own corner-provenance handle (a carry here, consumed by a `buildLoops`,
    // then a RELOCATE over the merge pass's exact corner subset) produced one
    // `MeshMapDelta` per `FaceReindex` and an armed revert with 0 of 72 UV
    // floats differing, against 71 of 72 under the single shared handle. (71,
    // not 72: the stand fills `uv` with `0, 1, 2, …`, so corner 0's U is
    // already 0 and zeroing it changes nothing. Quoting "all 72" would be one
    // float wider than the measurement.) That shape is deliberately NOT in the
    // tree: while the family is unarmed nothing records a `FaceReindex`, so no
    // lane can observe whether it is right.
    //
    // WHAT ACTUALLY BLOCKS THE ARMING is a different plane with a different
    // owner. Measured residual of the armed revert on `makeTaggedGridFull(3)`,
    // edge (1,5), both ways:
    //
    //     [edgeMarks, faceMarks, map:W, orderCounters, vertexMarks,
    //      vertexSelectionOrder]
    //
    // Five are Select-class and are what every armed family carries. `map:W`
    // is not: it is a Point-domain map VALUE. The kernel's tail
    // `compactUnreferenced` drops the two consumed endpoint vertices, and
    // `mesh_edit_delta.removeVertsReverse` re-inserts a dropped vertex with
    // its Point-map values ZEROED — its own documented limit — so `W` comes
    // back `0.5, 0, 2.5, …, 0, …` where the stand held
    // `0.5, 1.5, 2.5, …, 5.5, …`. A lost VALUE is exactly the line
    // `face_reindex_arming_test.d` block 2 draws, and its guard asserts
    // `map:W` equal outright, so the residual row is not even writable.
    // Closing it means a Point-domain payload on `Kind.RemoveVerts` — a FIELD
    // on `MeshOpEntry`, sized once for every family that compacts vertices,
    // which is not this kernel's to add.
    //
    // THE SHARED-`rwB` SHAPE AND THE STAGE J PAYLOAD ARE INCOMPATIBLE AS
    // WRITTEN. `Kind.FaceReindex` restores per-corner values from a
    // `Kind.MeshMapDelta` payload that `mesh_planes.rewriteFaces` records
    // IMMEDIATELY BEFORE the face entry — and that capture declines, silently,
    // when `Mesh.polyVertexMapsInStepWithFaces()` is false. It is false HERE:
    // this kernel opens ONE `rwB` handle, rewrites `faces` TWICE and issues
    // its corner relocation only AFTER this second rewrite (1902 §2.6), so
    // between the two rewrites the map still describes the PRE-op corner space
    // while `faces` already describes the post-first-rewrite one. Measured
    // 2026-08-27 with both scopes in place, on a `makeTaggedGridFull` stand
    // bevelling edge (5,6): the primitive reports `hasMap=true inStep=false`
    // at this call, the op-log comes out
    // `[AddVerts MeshMapDelta FaceReindex FaceReindex RemoveVerts Reindex]` —
    // ONE payload for TWO face entries — and the reverse, finding no payload
    // adjacent to the entry it plays first, declines the carry and ZEROES all
    // 72 floats of the UV map. `revert()` still answers `true`.
    //
    // So this is not the "arming is incomplete" residual the armed families
    // carry (Select bits and array lengths, owed to L0): it is a loss INSIDE
    // what `FaceReindex` is the publisher for, which is the line Stage K
    // draws. L7 owns the fix and it is a real choice — bring the map into step
    // before this rewrite, or relocate once per rewrite instead of once per
    // kernel, or capture the payload where the map IS in step. Arming before
    // one of those lands would zero UV on every edge-bevel undo.
    rewriteFaces(ed, mergedFaces, FaceSource.fromOldToNew(faceRemap, mergedFaces.length));
    // Select is about to be fully re-derived below (chamfer + hub-cap
    // faces via `selectFace`), so it is dropped here same as every
    // other compaction site; Subpatch/Hide are NOT re-derived below and
    // must ride the carry above. Self-aliasing (src is faceMarks) — see
    // Mesh.setFaceMarksFrom's own doc comment for why that is safe.
    ed.setFaceMarksFrom(ed.faceMarks, ~Mesh.Marks.Select);

    // Relocate the per-corner map now that `faces` is final and BEFORE the
    // tail `buildLoops`, which would otherwise see a length-wrong map and
    // zero the whole mesh's UV. Vertex indices are still the pre-compaction
    // ones the capture was taken against.
    if (remapUvB) {
        uint[] srcOfCorner;
        foreach (s; mergedSrc) srcOfCorner ~= s;
        ed.declareCornerProvenance(
            rwB.carried(ed.faces.range, srcOfCorner, vertBlendB));
    }

    // New selection = chamfer + hub-cap faces; clear vertex/edge
    // selections. Re-derived through `faceRemap` — a dropped, non-tail
    // face (Case C: the whole top-face quad can vanish) shifts every
    // surviving face after it, so re-selecting by the OLD index range
    // directly would silently select the wrong faces.
    ed.faceSelectionOrderCounter = 0;
    foreach (fi; chamferStart .. rebuiltFaceCount) {
        immutable int newFi = faceRemap[fi];
        if (newFi >= 0) ed.selectFace(newFi);
    }
    ed.resizeVertexSelection();
    ed.clearVertexSelection();
    ed.clearEdgeSelectionResize();

    // Tail: rebuild topology + compact orphaned original vertices, but
    // PIN the valence-4 full-hub free-end cap's intended orphan slides so
    // they survive as the reference keeps them (see bevelPinnedOrphans_).
    ed.rebuildEdges();
    ed.buildLoops();
    ed.compactUnreferenced(ed.bevelPinnedOrphans_);
    ed.buildLoops();
    ed.commitChange(MeshEditScope.Geometry | MeshEditScope.Marks);
    return processed;
}

// ---------------------------------------------------------------------------
// TRIPWIRE — `bevelEdgesByMask` may not be a MEMBER of `Mesh` again.
//
// A member BEATS a same-name UFCS free function, so re-adding one (by hand, by
// a reinstated `mixin MeshEdgeBevelOps;`, or by an in-struct `alias`) would
// silently rebind every call site to the member and leave this free function
// unreachable while every edge-bevel test, every frozen fixture and the whole
// refusal census stayed green — the failure plan Revision 2 caveat 1
// describes, and one `commit_seam_census_test.d` cannot see, because it reads
// mesh.d's text for `mixin Mesh*Ops` and a hand-written method is not one.
//
// An in-struct `alias bevelEdgesByMask = mesh_ops.edge_bevel.bevelEdgesByMask;`
// counts: MEASURED at E2 and repeated at E3/E4/F1/F2, an alias makes both
// `Mesh.X` resolve AND `__traits(hasMember, Mesh, "X")` answer `true`, so the
// alias and this assert cannot both stand. That is why plan §2.7 forbids the
// alias rather than merely preferring the move.
//
// THE THREE PARITY FIELDS ARE NOT IN THIS LIST, ON PURPOSE. They ARE members
// of `Mesh` — that is Stage G's recorded decision (see the banner) — so
// `hasMember` answers `true` for all three and always will. What holds THEM is
// the census row that names their declaration site in `source/mesh.d` and both
// reader files; a tripwire here would have to be inverted, and an inverted
// tripwire is satisfied by a field of any type in any place.
// ---------------------------------------------------------------------------
static foreach (n; ["bevelEdgesByMask"])
    static assert(!__traits(hasMember, Mesh, n),
        "`Mesh." ~ n ~ "` is a MEMBER again. Task 1903 Stage G moved this "
      ~ "family out of `struct Mesh` into a module-level free function over "
      ~ "`ref MeshEditBatch` in mesh_ops/edge_bevel.d. A member BEATS a "
      ~ "same-name UFCS free function, so every call site — the two commands, "
      ~ "the tool's commit and preview, the eleven refusal-census sites and "
      ~ "some 120 unittest sites — would silently bind back to the member and "
      ~ "the free function would go unreachable while all of them stayed "
      ~ "green. An in-struct `alias` counts: it makes `hasMember` answer true, "
      ~ "which is why plan §2.7 forbids it (task 1903 §2.7, §4.5).");
