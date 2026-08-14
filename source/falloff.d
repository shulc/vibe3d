module falloff;

import std.algorithm : max, min;
import std.json;
import std.math      : sqrt;

import math : Vec3, Viewport, projectToWindowFull, dot, cross,
              pointInPolygon2D, closestOnSegment2DSquared,
              AimViewport, aimSpace, ModelSpace;
import toolpipe.packets : FalloffPacket, FalloffType, FalloffShape, FalloffMix,
                          ElementConnect;

// ---------------------------------------------------------------------------
// Falloff math — Phase 7.5 of doc/phase7_plan.md / doc/falloff_plan.md.
//
// Pure functions; no GL / no ImGui. Tools that consume falloff (Move /
// Rotate / Scale) call `evaluateFalloff(packet, vertWorld, vertIdx, vp)`
// per moving vertex and multiply their per-vertex transform by the
// returned weight ∈ [0, 1].
//
// Returns 1.0 unconditionally when `!packet.enabled` so callers don't
// need to short-circuit — matches the snap.d / SnapPacket convention.
//
// 7.5b implements only `FalloffType.Linear`. Subsequent subphases
// extend the dispatch:
//   7.5c — Radial
//   7.5d — Screen
//   7.5e — Lasso
// ---------------------------------------------------------------------------

/// Per-vertex falloff weight at position `pos` — the vertex's CURRENT
/// coordinate as it is stored in `mesh.vertices[]`, i.e. LOCAL to its
/// layer. (Tools should pass the live position so a multi-frame drag
/// sees the falloff move with the vertex.) `vp` names the layer, so
/// this function can put that coordinate into whichever space each
/// falloff kind actually answers in.
///
/// **Task 0619 — the space, corrected.** This doc used to say `pos` was
/// the vertex's *world* coord. It never was: every production caller
/// passes `mesh.vertices[i]` or a snapshot of it, which is local. That
/// mattered for exactly two of the ten types — Screen and Lasso, the
/// only ones that answer in WINDOW PIXELS. They projected the local
/// coordinate through the plain world viewport, so on a layer with a
/// non-trivial `ItemXform` the disc/polygon selected the vertices that
/// would have been under the cursor at IDENTITY, not the ones drawn
/// there.
///
/// The fix is in the TYPE: the projection now arrives as an
/// `AimViewport`, which cannot be produced without naming a
/// `ModelSpace` (`aimSpace(vp, ms)`), so handing this function a world
/// viewport is a compile error rather than a silently misplaced disc.
/// Composing is exact — `proj·(view·M)·v == proj·view·(M·v)` — and is
/// paid ONCE per query by the caller, never per vertex: this function
/// is called inside every deform kernel's inner loop, so `aimSpace`
/// must be hoisted above it (see the callers).
///
/// **Task 0659 — the other eight, MEASURED.** 0619 went on to say the
/// remaining eight kinds "compare `pos` against packet fields that are
/// in the same (local) space, so they were self-consistent". Half of
/// that was true and half of it was wrong, and the wrong half is the
/// part that mattered:
///
///   * SELF-CONSISTENT they were not. `start` / `end` / `center` /
///     `pickedRadius` are written by handle drags and by ACEN, both of
///     which produce WORLD values, and `falloff_render.d` draws them
///     through the plain world viewport. Only `autoSize` wrote them
///     local. Two writers, two spaces, one field set — task 0646.
///   * The right space is WORLD, and that is no longer a preference.
///     It was captured over ten cells: the weight is computed on the
///     vertex lifted by the layer's FULL item matrix — translation,
///     rotation and scale alike — against handle values that are
///     themselves world coordinates. rms 2.4e-8 against that reading,
///     0.380 against the layer-local one. So a radius is in world
///     units: the region of influence stays a SPHERE in world and is
///     an ellipsoid in the layer's own coordinates, its axes the WORLD
///     axes. Three further facts came with it: the handles are read in
///     the same space as the vertex (both mixed readings die on an
///     off-origin centre); the whole matrix is used and not just its
///     scale part (a translation-only item moved NOTHING, where
///     layer-local predicted the identity weights); and the ellipsoid
///     is not carried around by the layer's rotation.
///
/// So `pos` is lifted ONCE here and the eight world-space kinds read
/// the lifted point. Screen and Lasso keep the LOCAL point, because
/// their answer is in pixels and `vp` has the layer already composed
/// into it — lifting for them would apply the item transform twice.
/// The frozen capture lives in the task evidence and is replayed by
/// `tests/fixtures/falloff_radius_space.json`.
///
/// `vertIdx` is reserved for types that key on the vertex index
/// (Element, Vertex Map).
///
/// **There is deliberately no "cursorless" overload.** Four callers looked
/// like they needed one — `mesh.jitter` / `mesh.quantize` / `mesh.smooth` and
/// `applyMagnet` each declared a default-constructed `Viewport` with a
/// comment saying it was unused. They were not cursorless: all four are also
/// `Operator`s whose `evaluate(vts)` injects the LIVE `FalloffPacket`, which
/// can be Screen or Lasso, and the same `evaluate` already holds the real
/// viewport on the `SubjectPacket`. The placeholders existed because nobody
/// plumbed it through, not because there was nothing to plumb. Each now
/// passes `aimSpace(subj.viewport, primaryModelSpace())`, so a pixel falloff
/// applied through one of those commands weights the geometry it is drawn
/// over instead of projecting through an all-zero matrix.
float evaluateFalloff(const ref FalloffPacket cfg,
                      Vec3 pos,
                      int  vertIdx,
                      const ref AimViewport vp)
{
    if (!cfg.enabled) return 1.0f;
    // One lift for the whole packet, Composite recursion included — the
    // eight world-space kinds all want the same point, and `toWorld` is
    // an affine apply we should not pay per contributor.
    return evaluateFalloffAt(cfg, pos, vp.toWorld(pos), vertIdx, vp);
}

/// The dispatch, with BOTH readings of the vertex in hand: `posLocal` as
/// stored, `posWorld` lifted by the layer's item matrix. Each kind takes
/// the one its fields are expressed in — see `evaluateFalloff`'s doc for
/// why that split is where it is, and which measurement fixed it.
private float evaluateFalloffAt(const ref FalloffPacket cfg,
                                Vec3 posLocal, Vec3 posWorld,
                                int  vertIdx,
                                const ref AimViewport vp)
{
    if (!cfg.enabled) return 1.0f;

    final switch (cfg.type) {
        case FalloffType.None:
            return 1.0f;
        case FalloffType.Linear:
            return linearWeight(cfg, posWorld);
        case FalloffType.Radial:
            return radialWeight(cfg, posWorld);
        // Screen / Lasso answer in WINDOW PIXELS and `vp` already has the
        // layer composed into it, so these two take the LOCAL point. Handing
        // them `posWorld` would apply the item transform twice.
        case FalloffType.Screen:
            return screenWeight(cfg, posLocal, vp);
        case FalloffType.Lasso:
            return lassoWeight(cfg, posLocal, vp);
        case FalloffType.Cylinder:
            return cylinderWeight(cfg, posWorld);
        case FalloffType.Element:
            return elementWeight(cfg, posWorld, vertIdx);
        case FalloffType.Selection:
            return selectionWeight(cfg, vertIdx);
        case FalloffType.Composite:
            return compositeWeight(cfg, posLocal, posWorld, vertIdx, vp);
        case FalloffType.VertexMap:
            return vertexMapWeight(cfg, vertIdx);
    }
}

/// Combine the Mix-Mode of two weights. `a` is the running accumulator,
/// `b` the next contributor's clamped weight. The first contributor's
/// `mix` is never consulted (it seeds `a`); only contributors i≥1 reach
/// here. Results are NOT clamped per-step — Add/Subtract can leave [0,1]
/// mid-accumulation and `compositeWeight` clamps once at the very end
/// (so e.g. (0.6 + 0.6) then *0.5 reads the true 1.2 sum, not a clamped
/// 1.0). Multiply/Max/Min already stay in-range for in-range inputs.
float applyMix(FalloffMix mix, float a, float b) {
    final switch (mix) {
        case FalloffMix.Multiply: return a * b;
        case FalloffMix.Add:      return a + b;
        case FalloffMix.Subtract: return a - b;
        case FalloffMix.Max:      return max(a, b);
        case FalloffMix.Min:      return min(a, b);
    }
}

/// Composite falloff: the multi-falloff combiner. Each contributor is a
/// stand-alone sub-packet (never itself Composite — the WGHT combiner
/// flattens on build). The first contributor SEEDS the accumulator with
/// its clamped weight; every later contributor folds its clamped weight
/// in via ITS OWN `mix`. The final accumulator is clamped to [0, 1]
/// (Add/Subtract can overshoot the range). An empty contributor set
/// degenerates to full influence (1.0) — matching the "no constraint"
/// contract every other falloff uses for its degenerate case.
private float compositeWeight(const ref FalloffPacket cfg,
                              Vec3 posLocal, Vec3 posWorld,
                              int vertIdx, const ref AimViewport vp)
{
    if (cfg.contributors.length == 0) return 1.0f;
    // Contributors are flat (never themselves Composite) and every one of
    // them lives on the SAME vertex, so both readings are passed straight
    // down rather than re-lifted per contributor.
    float accum = clamp01(
        evaluateFalloffAt(cfg.contributors[0], posLocal, posWorld, vertIdx, vp));
    foreach (i; 1 .. cfg.contributors.length) {
        float w = clamp01(
            evaluateFalloffAt(cfg.contributors[i], posLocal, posWorld, vertIdx, vp));
        accum = applyMix(cfg.contributors[i].mix, accum, w);
    }
    return clamp01(accum);
}

private float clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

/// Selection falloff (D.7) — `falloff.selection`. The
/// per-vert BFS over `mesh.edges` happens inside FalloffStage.evaluate;
/// it bakes the weight array onto `cfg.selectionWeights` and we just
/// look up `vertIdx` here. An empty / undersized array degenerates to
/// 1.0 ("no constraint" — matches the empty-selection contract every
/// other falloff uses).
private float selectionWeight(const ref FalloffPacket cfg, int vertIdx) {
    if (vertIdx < 0) return 1.0f;
    auto arr = cfg.selectionWeights;
    if (cast(size_t)vertIdx >= arr.length) return 1.0f;
    return arr[cast(size_t)vertIdx];
}

// ---------------------------------------------------------------------------
// Selection falloff RAW-weight kernel (D.7 / falloff-port Phase 2). A pure
// topology function — no Mesh, no Stage, no caching — so it can be driven
// directly on a synthetic adjacency by the tier-1 golden unittests below, as
// well as by `FalloffStage.recomputeSelectionWeights` (the live per-drag
// baker, which owns the mesh/selection→inSel/adjacency plumbing plus the
// post-kernel ease and the result cache).
//
// Two-stage law, `S = max(steps, 1)`:
//
//   1. Ring seed. `seed(v) = min(ring(v), S) / S`, where `ring(v)` is the
//      plain (unweighted) BFS hop distance from `v` to the nearest BOUNDARY
//      vertex — a selected vertex with ≥1 unselected neighbour (a
//      Dirichlet-0 pin) — walking only the in-selection subgraph. Boundary
//      vertices are ring 0 (seed 0); vertices deeper than `S` hops saturate
//      at seed 1.0. Valence-agnostic: a plain hop count over the adjacency,
//      not a flat-grid/degree-4 special case — real meshes have arbitrary
//      valence (CC poles, tri fans, non-manifold junctions).
//   2. Fixed-4-pass graph-Laplacian Jacobi blur, INDEPENDENT of `steps`.
//      Each interior selected vertex (no unselected neighbour) is replaced
//      by the uniform (1/valence) mean of its in-selection neighbours'
//      PREVIOUS-pass seed (snapshot-then-write — Jacobi, not Gauss-Seidel).
//      Boundary vertices stay pinned at 0 through all 4 passes.
//
// `inSel[v] == false` ⇒ output 0 unconditionally — the domain never expands
// past the raw selection. A disjoint fully-interior component (every
// neighbour selected, no boundary reachable by the in-selection BFS)
// saturates its ring at `S` and its weight at 1.0 by construction of the
// cap — the "no boundary → full move" degenerate every transform path
// relies on (see the M9 aliasing unittest in toolpipe.stages.falloff).
//
// Returns an `inSel.length`-long RAW weight array (pre-ease). The caller
// applies its own ease curve (FalloffStage's fixed smoothstep, or a test's
// own) — this kernel has no opinion on easing.
// ---------------------------------------------------------------------------
float[] bakeSelectionRingWeights(const(size_t)[] adjOffset,
                                  const(uint)[]   adjNeighbors,
                                  const(bool)[]   inSel,
                                  int steps)
{
    immutable size_t nV = inSel.length;
    float[] raw = new float[](nV);
    if (nV == 0) return raw;

    immutable int S = (steps > 1) ? steps : 1; // S = max(steps, 1)

    // Boundary set: selected vertex with ≥1 unselected neighbour.
    bool[] isB = new bool[](nV);
    foreach (vi; 0 .. nV) {
        if (!inSel[vi]) continue;
        foreach (n; adjNeighbors[adjOffset[vi] .. adjOffset[vi + 1]]) {
            if (!inSel[n]) { isB[vi] = true; break; }
        }
    }

    // --- Ring seed: multi-source BFS from the boundary set, confined to
    // the in-selection subgraph. ---
    enum int UNSEEN = int.max;
    int[]  ring  = new int[](nV);
    ring[] = UNSEEN;
    uint[] queue = new uint[](nV);
    size_t qHead = 0, qTail = 0;
    foreach (vi; 0 .. nV) {
        if (inSel[vi] && isB[vi]) {
            ring[vi] = 0;
            queue[qTail++] = cast(uint)vi;
        }
    }
    while (qHead < qTail) {
        uint v  = queue[qHead++];
        int  rv = ring[v];
        foreach (n; adjNeighbors[adjOffset[v] .. adjOffset[v + 1]]) {
            if (!inSel[n] || ring[n] != UNSEEN) continue;
            ring[n] = rv + 1;
            queue[qTail++] = n;
        }
    }

    foreach (vi; 0 .. nV) {
        if (!inSel[vi]) { raw[vi] = 0.0f; continue; }
        int r = ring[vi];
        int capped = (r == UNSEEN || r > S) ? S : r;
        raw[vi] = cast(float)capped / cast(float)S;
    }

    // --- Fixed-4-pass Jacobi blur (uniform 1/valence neighbour mean). ---
    float[] wA = raw;
    float[] wB = new float[](nV);
    foreach (pass; 0 .. 4) {
        foreach (vi; 0 .. nV) {
            if (!inSel[vi] || isB[vi]) { wB[vi] = 0.0f; continue; }
            float sum = 0.0f;
            int   cnt = 0;
            foreach (n; adjNeighbors[adjOffset[vi] .. adjOffset[vi + 1]]) {
                if (!inSel[n]) continue;
                sum += wA[n];
                cnt += 1;
            }
            wB[vi] = (cnt > 0) ? (sum / cast(float)cnt) : wA[vi];
        }
        auto tmp = wA; wA = wB; wB = tmp;
    }
    return wA;
}


/// VertexMap falloff: looks up the pre-baked `vertexMapWeights` slice at
/// `vertIdx`. Values are clamped to [0, 1] here (the buffer stores raw map
/// data). An empty / undersized / negative-index case degenerates to 1.0
/// (full influence — same degenerate contract as selectionWeight).
private float vertexMapWeight(const ref FalloffPacket cfg, int vertIdx) {
    if (vertIdx < 0) return 1.0f;
    auto arr = cfg.vertexMapWeights;
    if (cast(size_t)vertIdx >= arr.length) return 1.0f;
    return clamp01(arr[cast(size_t)vertIdx]);
}

/// Linear falloff: weight is 1.0 at `start`, 0.0 at `end`, attenuated
/// across the line segment by `shape`. Past either endpoint along the
/// line direction the weight saturates (1.0 before start, 0.0 after
/// end). Off-line distance is ignored — Linear falloff is
/// "infinite plane-style", attenuating only along the line direction.
private float linearWeight(const ref FalloffPacket cfg, Vec3 pos) {
    Vec3  axis = cfg.end - cfg.start;
    float ax2  = dot(axis, axis);
    if (ax2 < 1e-12f) return 1.0f;   // degenerate line — full influence
    Vec3  rel  = pos - cfg.start;
    float t    = dot(rel, axis) / ax2;
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, cfg.shape, cfg.in_, cfg.out_);
}

/// Radial (ellipsoid) falloff: weight is 1.0 at `center`, 0.0 on or
/// outside the ellipsoid surface defined by `center ± size` per axis,
/// attenuated across the volume by `shape`. `size` components ≤ 0
/// degenerate that axis to "no extent" — the corresponding factor is
/// dropped from the distance (so a flat `size = (1, 0, 1)` ellipsoid
/// becomes a 2D disc on the XZ plane that ignores Y).
private float radialWeight(const ref FalloffPacket cfg, Vec3 pos) {
    Vec3 d = pos - cfg.center;
    float sum = 0.0f;
    bool any = false;
    if (cfg.size.x > 1e-9f) {
        float u = d.x / cfg.size.x;
        sum += u * u;
        any = true;
    }
    if (cfg.size.y > 1e-9f) {
        float u = d.y / cfg.size.y;
        sum += u * u;
        any = true;
    }
    if (cfg.size.z > 1e-9f) {
        float u = d.z / cfg.size.z;
        sum += u * u;
        any = true;
    }
    if (!any) return 1.0f;       // degenerate ellipsoid — full influence everywhere
    float t = sqrt(sum);
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, cfg.shape, cfg.in_, cfg.out_);
}

/// Cylinder falloff: same as Radial but with one axis collapsed —
/// the weight depends only on the perpendicular distance from the
/// `center` point along the cylinder axis. Used by xfrm.vortex (a
/// twist that rotates uniformly along its axis but attenuates with
/// radial distance from it). Falls back to Radial behaviour for a
/// degenerate axis (zero-length); cylinder size is taken from the
/// bigger of the two perpendicular `size` components (most setups
/// have an isotropic radial cross-section).
private float cylinderWeight(const ref FalloffPacket cfg, Vec3 pos) {
    Vec3 axis = cfg.normal;
    float al2 = dot(axis, axis);
    if (al2 < 1e-12f) return radialWeight(cfg, pos);  // degenerate → fall back
    Vec3 invAxis = axis * (1.0f / sqrt(al2));
    Vec3 d = pos - cfg.center;
    float along = dot(d, invAxis);
    Vec3 perp = d - invAxis * along;
    // Cylinder radius from `size`: the two non-aligned axes' size
    // components average to the radius in the simple isotropic case.
    // For now use the max of size.x/y/z (the cross-section is a disc
    // around the axis; a more sophisticated implementation could
    // pick the two non-axis components by axis index).
    float sx = cfg.size.x, sy = cfg.size.y, sz = cfg.size.z;
    float r  = sx;
    if (sy > r) r = sy;
    if (sz > r) r = sz;
    if (r <= 1e-9f) return 1.0f;
    float plen = sqrt(dot(perp, perp));
    float t = plen / r;
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, cfg.shape, cfg.in_, cfg.out_);
}

/// Element falloff: spherical attenuation around `pickedCenter`,
/// radius `pickedRadius`. weight = 1 at the centre, 0 at the sphere
/// boundary, shape-mapped in between. This is `falloff.element`
/// (the centre is normally the centroid of the user-clicked
/// component; `pickedRadius` is the `dist`/Range attr).
///
/// Connected-Elements gate (`cfg.connect`):
///   * Ignore          → no gate; pure geometric-distance falloff.
///   * UseConnectivity → verts outside the picked component (per
///                       `connectMask`) get weight 0; verts inside still
///                       attenuate by distance.
///   * Rigid           → verts inside the component get weight 1 (rigid,
///                       no attenuation); verts outside get 0.
///   * EdgeLoops       → anchorRing is the ordered quad edge-loop ring;
///                       non-ring verts attenuate by distance to the
///                       closed loop POLYLINE (no component zeroing gate).
/// With an empty `connectMask` (no anchor / Ignore) the gate is a no-op
/// and the unrestricted sphere applies.
private float elementWeight(const ref FalloffPacket cfg, Vec3 pos, int vi) {
    // Anchor ring (click-picked element's vert ring) short-circuits
    // to full weight regardless of the sphere math — drag the picked
    // element as a rigid unit with the cursor. Without this, clicks
    // on a typical face produce no motion because the corners sit at
    // distance > sphere radius from the centroid (e.g. cube face:
    // √2·0.5 ≈ 0.707 vs autoSized dist=0.5). `falloff.element`
    // does the same internally — see doc/unified_transform_plan.md
    // commit notes for the analysis. Checked BEFORE connectMask:
    // picked verts are by definition in the same component.
    if (cfg.anchorRing.length > 0 && vi >= 0) {
        foreach (av; cfg.anchorRing)
            if (cast(uint)vi == av) return 1.0f;
    }
    // Connected-Elements gate. `Ignore` skips the gate entirely (pure
    // geometric-distance falloff). The other modes consult `connectMask`
    // (BFS component of the picked element); an empty mask (no anchor /
    // headless without a ring) degrades to "unrestricted" so non-pick
    // scripted use still works. EdgeLoops is a documented stub that
    // currently behaves as UseConnectivity.
    // EdgeLoops is no longer a UseConnectivity stub: its anchorRing is the
    // ORDERED quad edge-loop ring (resolved upstream in FalloffStage /
    // transform.d), and non-ring verts attenuate by distance to the loop
    // POLYLINE (see distPointClosedPolyline below). So EdgeLoops must NOT
    // run the component zeroing gate — every vert attenuates by polyline
    // distance, with the ring verts pinned to weight 1 above.
    if (cfg.connect != ElementConnect.Ignore
     && cfg.connect != ElementConnect.EdgeLoops
     && cfg.connectMask.length > 0) {
        bool inComponent = vi >= 0
                        && vi < cast(int)cfg.connectMask.length
                        && cfg.connectMask[vi];
        if (!inComponent) return 0.0f;
        // Rigid Connections: the whole connected component moves rigidly
        // the full distance — no distance attenuation inside it.
        if (cfg.connect == ElementConnect.Rigid) return 1.0f;
        // UseConnectivity / EdgeLoops(stub): in-component verts fall
        // through to the geometric-distance attenuation below.
    }
    // pickedCenter drives the falloff sphere; pickedRadius (the
    // `dist` attr) is the radius. Non-anchor verts attenuate from
    // weight = 1 at the centre to 0 at the boundary, shape-mapped.
    if (cfg.pickedRadius <= 1e-9f) return 1.0f;  // degenerate radius → full
    // Distance is measured to the picked element's GEOMETRY (defined
    // by `anchorPos`, the world positions of the picked verts), not to
    // the single centroid `pickedCenter`. A vertex pick (1 anchor) ==
    // the point distance, so it stays bit-identical to the old centroid
    // path; an edge / polygon pick attenuates by distance to the
    // SEGMENT / FACE, matching the reference editor.
    float r;
    if (cfg.anchorPos.length == 0) {
        // No picked geometry (scripted / non-pick use) → fall back to
        // the centroid-point distance, preserving the prior behaviour.
        Vec3 d = pos - cfg.pickedCenter;
        r = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
    } else if (cfg.connect == ElementConnect.EdgeLoops && cfg.anchorPos.length >= 2) {
        // Edge Loops: the anchor positions are the ORDERED ring of the
        // detected quad edge-loop (closed band). Attenuate by distance to
        // the closed POLYLINE through the ring — NOT the filled-polygon
        // distance (distPointPolygon would treat the ring's interior as
        // distance-0, which is wrong for a loop band). The ring verts are
        // already weight-1 via the anchorRing short-circuit above.
        r = distPointClosedPolyline(pos, cfg.anchorPos);
    } else if (cfg.anchorPos.length == 1) {
        Vec3 d = pos - cfg.anchorPos[0];
        r = sqrt(d.x*d.x + d.y*d.y + d.z*d.z);
    } else if (cfg.anchorPos.length == 2) {
        r = distPointSegment(pos, cfg.anchorPos[0], cfg.anchorPos[1]);
    } else {
        r = distPointPolygon(pos, cfg.anchorPos);
    }
    float t = r / cfg.pickedRadius;
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, cfg.shape, cfg.in_, cfg.out_);
}

/// Distance from `p` to the segment [a, b] (clamped orthogonal
/// projection). Degenerate (a == b) reduces to the point distance.
private float distPointSegment(Vec3 p, Vec3 a, Vec3 b) {
    Vec3  ab  = b - a;
    float ab2 = dot(ab, ab);
    Vec3  ap  = p - a;
    float t   = (ab2 > 1e-12f) ? dot(ap, ab) / ab2 : 0.0f;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    Vec3 d = ap - ab * t;
    return sqrt(dot(d, d));
}

/// Distance from `p` to the CLOSED polyline through `pts` (the minimum
/// distance to any segment pts[i] → pts[(i+1) % n]). Unlike
/// `distPointPolygon`, the polyline's interior is NOT distance-0 — this is
/// the loop-band distance used by Edge-Loops element falloff, where the
/// ring is a closed band of edges and points "inside" the band must still
/// attenuate by their distance to the nearest ring segment. A 1-point
/// input degenerates to the point distance; empty → +inf.
float distPointClosedPolyline(Vec3 p, const(Vec3)[] pts) {
    if (pts.length == 0) return float.infinity;
    if (pts.length == 1) {
        Vec3 d = p - pts[0];
        return sqrt(dot(d, d));
    }
    float best = float.infinity;
    foreach (i; 0 .. pts.length) {
        size_t j = (i + 1) % pts.length;
        float d = distPointSegment(p, pts[i], pts[j]);
        if (d < best) best = d;
    }
    return best;
}

/// Distance from `p` to the (convex-ish) polygon whose vertices are
/// `poly` (length ≥ 3). The face plane normal comes from the first
/// three verts; `p` is projected onto that plane. If the projection
/// falls inside the polygon (point-in-polygon in the plane's 2D
/// basis) the perpendicular plane distance is returned, otherwise the
/// minimum distance to any edge segment. A degenerate (collinear)
/// triangle falls back to the edge-segment minimum so the result is
/// always well-defined.
private float distPointPolygon(Vec3 p, const(Vec3)[] poly) {
    // Plane normal from the first three verts.
    Vec3 n = cross(poly[1] - poly[0], poly[2] - poly[0]);
    float nlen = sqrt(dot(n, n));
    if (nlen > 1e-9f) {
        n = n * (1.0f / nlen);
        // Signed perpendicular distance + projection onto the plane.
        float sd   = dot(p - poly[0], n);
        Vec3  proj = p - n * sd;
        // Build an in-plane 2D basis (u, v) to test containment.
        Vec3 u = poly[1] - poly[0];
        float ulen = sqrt(dot(u, u));
        if (ulen > 1e-9f) {
            u = u * (1.0f / ulen);
            Vec3 v = cross(n, u);   // already unit (n, u orthonormal)
            // Project polygon + the candidate point to (u, v) coords.
            float px = dot(proj - poly[0], u);
            float py = dot(proj - poly[0], v);
            bool inside = false;
            size_t j = poly.length - 1;
            foreach (i; 0 .. poly.length) {
                float xi = dot(poly[i] - poly[0], u);
                float yi = dot(poly[i] - poly[0], v);
                float xj = dot(poly[j] - poly[0], u);
                float yj = dot(poly[j] - poly[0], v);
                if (((yi > py) != (yj > py))
                 && (px < (xj - xi) * (py - yi) / (yj - yi) + xi))
                    inside = !inside;
                j = i;
            }
            if (inside) {
                float ad = sd < 0.0f ? -sd : sd;
                return ad;
            }
        }
    }
    // Outside the polygon (or degenerate plane) → min edge-segment dist.
    float best = float.infinity;
    size_t k = poly.length - 1;
    foreach (i; 0 .. poly.length) {
        float d = distPointSegment(p, poly[k], poly[i]);
        if (d < best) best = d;
        k = i;
    }
    return best;
}

/// Screen falloff: window-pixel disc at (screenCx, screenCy) radius
/// `screenSize`, projected as an infinite cylinder along the camera-
/// back axis. Weight = 1.0 at the disc centre, 0.0 at radius. When
/// `transparent == false`, verts behind the camera (projection failed)
/// get weight = 0 — facing-only semantics.
///
/// The radial attenuation is a FIXED LINEAR ramp (w = 1 - t), NOT the
/// `shape` preset: the reference editor's screen falloff has no shape
/// control — its disc profile is a fixed linear curve, confirmed by a
/// headless per-vertex weight capture (two independent drags both fit
/// 1 - t at RMS ~0.02; smooth/easeIn fit far worse). So screen ignores
/// `cfg.shape` and the Shape Preset row is hidden for the screen type
/// (FalloffStage.params()).
/// Aiming kind **Pixel** (task 0619 §1.1): `pos` is a LOCAL vertex
/// coordinate and `vp` is the AIM space, so the projected pixel is where
/// the vertex is DRAWN — which is what `screenCx/Cy` (a cursor pixel
/// pushed by the click gesture) is measured against.
private float screenWeight(const ref FalloffPacket cfg, Vec3 pos,
                           const ref AimViewport vp)
{
    float sx, sy, ndcZ;
    if (!projectToWindowFull(pos, vp.vp, sx, sy, ndcZ))
        return cfg.transparent ? 1.0f : 0.0f;
    float dx = sx - cfg.screenCx;
    float dy = sy - cfg.screenCy;
    float dist = sqrt(dx * dx + dy * dy);
    if (cfg.screenSize < 1e-6f) return 1.0f;     // degenerate disc
    float t = dist / cfg.screenSize;
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    return applyShape(t, FalloffShape.Linear, cfg.in_, cfg.out_);
}

/// Lasso falloff: project the vert to window pixels; weight = 1.0 if
/// the projected point is inside the lasso polygon; otherwise the
/// pixel distance to the nearest polygon edge is mapped to weight via
/// `softBorderPx`. softBorderPx == 0 ⇒ binary inside/outside (1 / 0).
///
/// 7.5e ships only the Freehand style (polygon points in lassoPolyX/Y).
/// Rectangle / Circle / Ellipse styles fall through to "polygon
/// vertices only" — typical caller draws the rect/circle into the
/// polygon arrays during the lasso input gesture. Verts behind the
/// camera get weight = 0 unless `transparent` is set, mirroring the
/// Screen falloff convention.
/// Aiming kind **Pixel** (task 0619 §1.1) — same law as `screenWeight`:
/// the lasso polygon is in window pixels, so the vertex must be
/// projected through the AIM space to be compared against it.
private float lassoWeight(const ref FalloffPacket cfg, Vec3 pos,
                          const ref AimViewport vp)
{
    if (cfg.lassoPolyX.length < 3
     || cfg.lassoPolyX.length != cfg.lassoPolyY.length)
        return 1.0f;     // unset / malformed lasso → no falloff
    float sx, sy, ndcZ;
    if (!projectToWindowFull(pos, vp.vp, sx, sy, ndcZ))
        return cfg.transparent ? 1.0f : 0.0f;

    bool inside = pointInPolygon2D(sx, sy,
                                   cast(float[])cfg.lassoPolyX,
                                   cast(float[])cfg.lassoPolyY);
    if (inside) return 1.0f;
    if (cfg.softBorderPx <= 1e-6f) return 0.0f;

    // Closest screen-pixel distance to any polygon edge segment.
    float bestD2 = float.infinity;
    auto xs = cfg.lassoPolyX;
    auto ys = cfg.lassoPolyY;
    foreach (i; 0 .. xs.length) {
        size_t j = (i + 1) % xs.length;
        float t;
        float d2 = closestOnSegment2DSquared(sx, sy,
            xs[i], ys[i], xs[j], ys[j], t);
        if (d2 < bestD2) bestD2 = d2;
    }
    float d = sqrt(bestD2);
    float tt = d / cfg.softBorderPx;
    if (tt <= 0.0f) return 1.0f;
    if (tt >= 1.0f) return 0.0f;
    return applyShape(tt, cfg.shape, cfg.in_, cfg.out_);
}

/// Map a normalised distance `t ∈ [0, 1]` (0 = full influence, 1 = no
/// influence) to a weight `w ∈ [0, 1]` per the shape preset:
///
///   Linear  → 1 - t                  even attenuation (default)
///   EaseIn  → 1 - t²                 stronger near full-influence
///   EaseOut → (1 - t)²               stronger near zero-influence
///   Smooth  → 1 - smoothstep(t)      S-curve
///   Custom  → cubic Bezier from (0,1) to (1,0) with control points
///             P1 = (1/3, (2-out_)/3), P2 = (2/3, (1+in_)/3) — at
///             in_=out_=0 both control points lie on the linear
///             baseline so the curve degenerates to y=1-t. This is the
///             `falloff.linear` Custom shape.
float applyShape(float t, FalloffShape shape, float in_, float out_) {
    if (t <= 0.0f) return 1.0f;
    if (t >= 1.0f) return 0.0f;
    final switch (shape) {
        case FalloffShape.Linear:
            return 1.0f - t;
        case FalloffShape.EaseIn:
            return 1.0f - t * t;
        case FalloffShape.EaseOut: {
            float u = 1.0f - t;
            return u * u;
        }
        case FalloffShape.Smooth: {
            // smoothstep(t) = 3t² - 2t³; we want the falling
            // complement so the curve starts at 1 and ends at 0.
            float s = t * t * (3.0f - 2.0f * t);
            return 1.0f - s;
        }
        case FalloffShape.Custom: {
            // Cubic Bezier from (0,1) to (1,0), control y-coords
            // (2-out_)/3 (P1) and (1+in_)/3 (P2). At in_=out_=0 both
            // control points sit on y=1-t and the curve collapses to
            // the linear baseline. Compact algebraic form:
            //   w(t) = (1-t) + in_·t²·(1-t) - out_·t·(1-t)²
            // in_  raises the curve in the second half (P2 above line)
            // out_ lowers the curve in the first half (P1 below line)
            float u = 1.0f - t;
            float w = u + in_ * t * t * u - out_ * t * u * u;
            // Clamp — extreme p0/p1 can still drive w outside [0, 1]
            // (the Bezier hull doesn't bound y when control points
            // stray above 1 or below 0).
            if (w < 0.0f) w = 0.0f;
            if (w > 1.0f) w = 1.0f;
            return w;
        }
    }
}


















// ---------------------------------------------------------------------------
// falloffPacketsEqual — live-change equality check used by CommandWrapperTool
// and the transform tools to detect live falloff changes (panel slider
// edits, type swap, endpoint drag) so the preview can re-apply on the next
// frame.
//
// Task 0179 / audit-2 F1: this used to be a hand-maintained field-by-field
// list that had DRIFTED — it silently omitted `normal` (cylinder axis),
// `pickedRadius` (Element dist), `connect`, `elementMode`, and `anchorRing`,
// so idle-session edits of those attrs did not refresh the preview, and
// `steps` / `mapName` had no packet field to compare AT ALL. Now the whole
// CONFIG field-set lives in one `FalloffConfig` sub-struct embedded in both
// `FalloffStage` and `FalloffPacket` (see toolpipe/packets.d), so `a.config
// == b.config` is the compiler-generated element-wise comparison of the
// COMPLETE set — it cannot drift again the way the hand-written list did.
// `enabled` and the Composite `contributors` recursion stay explicit scalar
// / recursive checks (not part of `config` — see FalloffConfig's doc for
// what's deliberately excluded, e.g. `pickedCenter` / `compoundPasses`).
// ---------------------------------------------------------------------------
bool falloffPacketsEqual(const ref FalloffPacket a, const ref FalloffPacket b) {
    if (a.enabled != b.enabled) return false;
    if (a.config  != b.config)  return false;
    // Composite contributors — refire correctness: a multi-falloff edit
    // (a contributor's config / mix changed, or one added/removed) must
    // be detected so the preview re-applies. Recurse field-wise; the
    // contributors are flat (never themselves Composite) so this bottoms
    // out in one level.
    if (a.contributors.length != b.contributors.length) return false;
    foreach (i; 0 .. a.contributors.length)
        if (!falloffPacketsEqual(a.contributors[i], b.contributors[i]))
            return false;
    return true;
}

// ---------------------------------------------------------------------------
// IFalloffAware — Phase 4 of doc/operator_refactor_plan.md. Marker
// interface that lets the /api/command dispatcher push a FalloffPacket
// into a Command without the cast-chain (MeshSmooth/MeshJitter/MeshQuantize).
// Any future convolve Command that wants HTTP-injected falloff just
// implements this interface — single cast at the dispatcher.
//
// Long-term plan: when Phase 6 cleanup removes Command.apply() and
// switches the dispatcher to Operator.evaluate(vts), this interface
// goes away — commands pull falloff from vts directly.
// ---------------------------------------------------------------------------
interface IFalloffAware {
    void setFalloff(FalloffPacket fp);
}

// ---------------------------------------------------------------------------
// JSON → FalloffPacket parser. Used by the HTTP /api/command dispatch to
// hand a falloff config to commands that opt in (mesh.smooth / mesh.jitter
// / mesh.quantize). Schema:
//
//   { "type": "linear" | "radial" | "cylinder",
//     "shape": "linear" | "easeIn" | "easeOut" | "smooth" | "custom",
//     "start": [x,y,z], "end": [x,y,z],          // linear
//     "center": [x,y,z], "size": [x,y,z],        // radial / cylinder
//     "axis": [x,y,z],                            // cylinder (defaults +Y)
//     "in": 0.5, "out": 0.5                       // custom shape tangents
//   }
//
// Element / Screen / Lasso / Selection falloff are not parsed here —
// those need viewport / pick state that's outside the HTTP envelope.
// ---------------------------------------------------------------------------
FalloffPacket parseFalloffJson(ref std.json.JSONValue j) {
    import std.json : JSONType;

    FalloffPacket fp;
    fp.enabled = true;
    fp.shape   = FalloffShape.Linear;

    string typeStr = "linear";
    if (auto pt = "type" in j.object) {
        if (pt.type == JSONType.string) typeStr = pt.str;
    }
    switch (typeStr) {
        case "none":     fp.type = FalloffType.None;     fp.enabled = false; break;
        case "linear":   fp.type = FalloffType.Linear;   break;
        case "radial":   fp.type = FalloffType.Radial;   break;
        case "cylinder": fp.type = FalloffType.Cylinder; break;
        case "screen":
        case "lasso":
            // These types require live viewport context (camera matrices
            // + window pixels). The /api/command path runs headlessly
            // and passes a default-initialised Viewport; using Screen
            // or Lasso falloff here would silently return wrong weights.
            // Use the toolpipe (`tool.pipe.attr falloff type screen ...`)
            // for those instead.
            throw new Exception(
                "falloff.type '" ~ typeStr ~ "' requires viewport context — "
                ~ "use the live toolpipe via tool.pipe.attr, not /api/command");
        default:
            throw new Exception(
                "falloff.type '" ~ typeStr ~ "' unsupported via HTTP");
    }

    if (auto ps = "shape" in j.object) {
        if (ps.type == JSONType.string) {
            switch (ps.str) {
                case "linear":  fp.shape = FalloffShape.Linear;  break;
                case "easeIn":  fp.shape = FalloffShape.EaseIn;  break;
                case "easeOut": fp.shape = FalloffShape.EaseOut; break;
                case "smooth":  fp.shape = FalloffShape.Smooth;  break;
                case "custom":  fp.shape = FalloffShape.Custom;  break;
                default:
                    throw new Exception(
                        "falloff.shape '" ~ ps.str ~ "' unknown");
            }
        }
    }

    Vec3 readVec3(string key, Vec3 fallback) {
        auto pv = key in j.object;
        if (pv is null || pv.type != JSONType.array || pv.array.length != 3)
            return fallback;
        float r(std.json.JSONValue v) {
            if (v.type == JSONType.float_)    return cast(float)v.floating;
            if (v.type == JSONType.integer)   return cast(float)v.integer;
            if (v.type == JSONType.uinteger)  return cast(float)v.uinteger;
            return 0.0f;
        }
        return Vec3(r(pv.array[0]), r(pv.array[1]), r(pv.array[2]));
    }
    float readFloat(string key, float fallback) {
        auto pv = key in j.object;
        if (pv is null) return fallback;
        if (pv.type == JSONType.float_)    return cast(float)pv.floating;
        if (pv.type == JSONType.integer)   return cast(float)pv.integer;
        if (pv.type == JSONType.uinteger)  return cast(float)pv.uinteger;
        return fallback;
    }

    fp.start  = readVec3("start",  fp.start);
    fp.end    = readVec3("end",    fp.end);
    fp.center = readVec3("center", fp.center);
    fp.size   = readVec3("size",   fp.size);
    fp.normal = readVec3("axis",   fp.normal);
    fp.in_    = readFloat("in",  fp.in_);
    fp.out_   = readFloat("out", fp.out_);
    return fp;
}
