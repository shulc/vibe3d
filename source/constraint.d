module constraint;

import std.math : sqrt;

import math : Vec3, Viewport, ModelSpace, dot, cross, normalize,
              projectToWindowFull, closestOnSegment2D;
import mesh : Mesh, edgeKey;
import toolpipe.packets : ConstrainPacket, ConstrainGeom, ConstrainHitPacket,
                          HoverTarget, HoverTargetKind, SnapPacket;

// ---------------------------------------------------------------------------
// World-space geometry constraint math — Stage 3 of doc/cons_constraint_plan.md.
//
// All functions operate in world space; screen-space projection is handled
// by snap.d (screen-space cursor candidates). This module is purely
// computational — no toolpipe state, no global reads — so it is fully
// unit-testable under `dub test --config=tests`.
//
// Working assumptions (unverified, revisit on Stage-0 captures):
//   * `point` mode uses nearest-foot (perpendicular closest-point) not
//     camera-ray (§6.5 of the plan).
//   * Application is per-vertex post-fold (§6.6 — per-delta is an
//     alternative that would move the hook to move.d:applySnapToDelta).
// Both assumptions are documented as non-verified in the plan's DoD.
//
// `vector` projects each vertex along the normalised per-vertex edit delta
// (motionDelta = finalPos − basePos); zero or near-zero delta returns the
// vertex unchanged (keep-on-miss). `screen` projects along the camera-forward
// axis extracted from the view matrix; a degenerate or uninitialised view
// matrix also returns unchanged. Both modes keep the position on a forward
// miss (no geometry hit in the projection direction).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// closestPointOnTriangle
//
// Standard Ericson barycentric closest-point (Real-Time Collision Detection
// §5.1.5). Pure, @nogc — safe to call from inside a per-vertex loop.
// ---------------------------------------------------------------------------
Vec3 closestPointOnTriangle(Vec3 p, Vec3 a, Vec3 b, Vec3 c)
    pure nothrow @nogc @safe
{
    Vec3 ab = b - a;
    Vec3 ac = c - a;
    Vec3 ap = p - a;

    float d1 = dot(ab, ap);
    float d2 = dot(ac, ap);
    if (d1 <= 0.0f && d2 <= 0.0f) return a;  // vertex region A

    Vec3 bp = p - b;
    float d3 = dot(ab, bp);
    float d4 = dot(ac, bp);
    if (d3 >= 0.0f && d4 <= d3) return b;    // vertex region B

    float vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0f && d1 >= 0.0f && d3 <= 0.0f) {
        float v = d1 / (d1 - d3);
        return a + ab * v;                    // edge region AB
    }

    Vec3 cp_ = p - c;
    float d5 = dot(ab, cp_);
    float d6 = dot(ac, cp_);
    if (d6 >= 0.0f && d5 <= d6) return c;    // vertex region C

    float vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0f && d2 >= 0.0f && d6 <= 0.0f) {
        float w = d2 / (d2 - d6);
        return a + ac * w;                    // edge region AC
    }

    float va = d3 * d6 - d5 * d4;
    if (va <= 0.0f && (d4 - d3) >= 0.0f && (d5 - d6) >= 0.0f) {
        float ww = (d4 - d3) / ((d4 - d3) + (d5 - d6));
        return b + (c - b) * ww;             // edge region BC
    }

    // Interior of triangle
    float denom = 1.0f / (va + vb + vc);
    float vv = vb * denom;
    float wv = vc * denom;
    return a + ab * vv + ac * wv;
}

// ---------------------------------------------------------------------------
// BackgroundSource — a background mesh paired with the ModelSpace of the
// layer it came from (task 0617 Stage 4 review fix). Every function below
// that walks MULTIPLE background sources (closestPointOnMeshes,
// projectAlongDirection) needs each source's OWN transform: a background
// layer's `mesh.vertices[]` are LOCAL, but `p`/`pos`/`dir` below are WORLD
// (the moving vertex's live position, or a world camera-ray seed), so a
// metric search (nearest-point, ray-triangle) run against raw local
// vertices silently drags the result onto the layer's IDENTITY pose — see
// doc/picking_item_transform_plan.md §3 and the CONS stage's
// `bgSurfaceRayHit` for the sibling fix. `layerIndex` is opaque to both
// functions (they never read it) — it exists so a caller that also needs
// the Document-layer index (the CONS stage's `hit.layer` fill) can take
// ONE combined snapshot instead of a separate lock+allocation per field;
// -1 means "not supplied" (mirrors snap.backgroundSourceLayerIndices()'s
// existing "caller falls back to the source-array index" contract).
//
// Defined here, not in snap.d, so this module keeps its documented shape —
// "no toolpipe state, no global reads" — snap.d imports this TYPE (a plain
// data shape, not a global or a behavior) rather than the other way round.
struct BackgroundSource {
    const(Mesh)* mesh;
    ModelSpace   space;
    int          layerIndex = -1;
}

// ---------------------------------------------------------------------------
// closestPointOnMeshes
//
// Walk every triangulated face of every source mesh; return the globally
// nearest foot, in WORLD space. Fan-triangulates polygons (vertex 0 as the
// fan pivot). `dblSided` is reserved for the capture-gated back-face rule —
// for now all faces are considered regardless.
//
// Each source's vertices are folded through ITS OWN `space` before the
// metric search (`toWorld`, identity-gated so the common single-layer case
// pays a bool check, not a matmul) — a global nearest-point election across
// sources with DIFFERENT transforms is only meaningful in one common space,
// and a minimum-distance election is not affine-invariant under a
// non-uniform scale (so searching in each source's own local space and
// comparing the raw distances across sources would elect the wrong point).
//
// `srcIndex`/`face` (topology-pen P2, doc/topopen_p2_plan.md) identify the
// WINNING source (index into `sources`) and its winning face (index into
// that source mesh's `m.faces`) — additive over the original two-out-param
// shape, so the CONS stage's Point-mode branch can feed the same face into
// `nearestFaceVertex`/`nearestFaceEdge` the way the Screen-mode branch
// already does from its own `SurfaceHit.face`. Both are set to -1 when
// `!found` (empty `sources`, or every source has fewer than 3 verts per
// face).
//
// Returns false when sources is empty or has no faces (caller keeps
// movingPos unchanged).
// ---------------------------------------------------------------------------
bool closestPointOnMeshes(Vec3 p,
                          const(BackgroundSource)[] sources,
                          bool dblSided,
                          out Vec3 hit,
                          out Vec3 hitNormal,
                          out int srcIndex,
                          out int face,
                          out float dist2)
{
    bool found = false;
    float bestD2 = float.infinity;
    Vec3  bestPt = p;
    Vec3  bestN  = Vec3(0, 1, 0);
    int   bestSrcIndex = -1;
    int   bestFace     = -1;

    foreach (si, bg; sources) {
        if (bg.mesh is null) continue;
        const src   = bg.mesh;
        const verts = src.vertices;
        const bool ident = bg.space.isIdentity;
        Vec3 toWorld(Vec3 vLocal) { return ident ? vLocal : bg.space.toWorldPoint(vLocal); }
        // `poly` (REV-2 rename, doc/topopen_p2_plan.md): the polygon's own
        // vertex-index array — renamed from the original `face` so it does
        // not shadow this function's new `face`-INDEX out-param above.
        foreach (fi, poly; src.faces.range) {
            if (poly.length < 3) continue;
            // Fan triangulation: (0,i,i+1) for i in [1, n-2]
            Vec3 a = toWorld(verts[poly[0]]);
            for (size_t i = 1; i + 1 < poly.length; ++i) {
                Vec3 b = toWorld(verts[poly[i]]);
                Vec3 cc = toWorld(verts[poly[i + 1]]);
                Vec3 cpt = closestPointOnTriangle(p, a, b, cc);
                Vec3 d = cpt - p;
                float d2 = dot(d, d);
                if (d2 < bestD2) {
                    bestD2 = d2;
                    bestPt = cpt;
                    // Face normal (unnormalised is fine for the direction) —
                    // cross-product of WORLD edge vectors of an already-WORLD
                    // triangle, so this is the true world normal directly (no
                    // inverse-transpose normal rule needed, unlike
                    // transforming an ALREADY-LOCAL normal into world space).
                    Vec3 n = cross(b - a, cc - a);
                    float nlen = sqrt(dot(n, n));
                    bestN = (nlen > 1e-12f) ? n * (1.0f / nlen) : Vec3(0, 1, 0);
                    bestSrcIndex = cast(int)si;
                    bestFace     = cast(int)fi;
                    found = true;
                }
            }
        }
    }

    if (found) {
        hit       = bestPt;
        hitNormal = bestN;
        srcIndex  = bestSrcIndex;
        face      = bestFace;
        dist2     = bestD2;
    } else {
        srcIndex = -1;
        face     = -1;
    }
    return found;
}

// ---------------------------------------------------------------------------
// projectAlongDirection
//
// Möller-Trumbore ray-triangle intersection along `dir` (world space).
// Finds the nearest forward hit across all source faces, each folded
// through its OWN ModelSpace first (same reasoning as closestPointOnMeshes
// above — `pos`/`dir` are world, `src.vertices[]` are local). Backs the
// `vector` and `screen` modes in constrainPoint. Returns false when no
// forward hit is found (caller keeps movingPos unchanged).
// ---------------------------------------------------------------------------
bool projectAlongDirection(Vec3 pos,
                           Vec3 dir,
                           const(BackgroundSource)[] sources,
                           bool dblSided,
                           out Vec3 hit,
                           out Vec3 hitNormal)
{
    float eps  = 1e-7f;
    float bestT = float.infinity;
    Vec3  bestPt = pos;
    Vec3  bestN  = Vec3(0, 1, 0);
    bool  found  = false;

    foreach (bg; sources) {
        if (bg.mesh is null) continue;
        const src   = bg.mesh;
        const verts = src.vertices;
        const bool ident = bg.space.isIdentity;
        Vec3 toWorld(Vec3 vLocal) { return ident ? vLocal : bg.space.toWorldPoint(vLocal); }
        foreach (face; src.faces.range) {
            if (face.length < 3) continue;
            Vec3 a = toWorld(verts[face[0]]);
            for (size_t i = 1; i + 1 < face.length; ++i) {
                Vec3 b = toWorld(verts[face[i]]);
                Vec3 cc = toWorld(verts[face[i + 1]]);
                // Möller-Trumbore
                Vec3 e1 = b - a;
                Vec3 e2 = cc - a;
                Vec3 h  = cross(dir, e2);
                float a_ = dot(e1, h);
                if (!dblSided && a_ < eps) continue;  // back-face or parallel
                if (a_ > -eps && a_ < eps) continue;  // parallel
                float f  = 1.0f / a_;
                Vec3 s   = pos - a;
                float u  = f * dot(s, h);
                if (u < 0.0f || u > 1.0f) continue;
                Vec3 q  = cross(s, e1);
                float v = f * dot(dir, q);
                if (v < 0.0f || u + v > 1.0f) continue;
                float t = f * dot(e2, q);
                if (t < eps || t >= bestT) continue;
                bestT  = t;
                bestPt = pos + dir * t;
                Vec3 n = cross(e1, e2);
                float nl = sqrt(dot(n, n));
                bestN = (nl > 1e-12f) ? n * (1.0f / nl) : Vec3(0, 1, 0);
                found = true;
            }
        }
    }

    if (found) { hit = bestPt; hitNormal = bestN; }
    return found;
}

// ---------------------------------------------------------------------------
// applyOffset
//
// Standoff along the surface normal by `offset` world units.
// Sign/direction are capture-gated (Stage 5); Stage 4 always calls with
// offset == 0, so this is an identity at that stage.
// ---------------------------------------------------------------------------
Vec3 applyOffset(Vec3 hitPos, Vec3 normal, float offset)
    pure nothrow @nogc @safe
{
    return hitPos + normal * offset;
}

// ---------------------------------------------------------------------------
// nearestFaceVertex / nearestFaceEdge / resolveHoverTarget — topology-pen
// P0/P1 (doc topopen_p0_plan.md, doc topopen_p1_plan.md). Pure derivation
// over an ALREADY-RESOLVED background-surface hit (face index + world
// point), read by the CONS stage's raycast branch
// (source/toolpipe/stages/constrain.d) to fill the "nearest element"
// fields of the published ConstrainHitPacket. No BVH / raycast here — that
// lives in bvh_pick.d (BvhPick.pickSurfaceRay); this module stays the
// pure-math layer per its existing doc comment.
//
// P0 shipped a standalone `ConstrainHit` struct here mirroring
// `ConstrainHitPacket` field-for-field, intended as this module's own
// "resolved hit" value type. It went unused (every caller passes the
// packet's fields directly to `nearestFaceVertex`/`nearestFaceEdge`) and is
// retired as of P1 (review REV-A) — `resolveHoverTarget` below takes
// `ConstrainHitPacket` directly rather than reintroducing a second,
// parallel struct.
// ---------------------------------------------------------------------------

/// Closest point on segment [a, b] to `p`. Small private helper backing
/// `nearestFaceEdge` — not exposed elsewhere (math.d already has a 2D
/// screen-space variant, `closestOnSegment2D`, for a different caller).
private Vec3 closestPointOnSegment3D(Vec3 p, Vec3 a, Vec3 b)
    pure nothrow @nogc @safe
{
    Vec3 ab = b - a;
    float len2 = dot(ab, ab);
    if (len2 < 1e-12f) return a;
    float t = dot(p - a, ab) / len2;
    if (t < 0.0f) t = 0.0f;
    else if (t > 1.0f) t = 1.0f;
    return a + ab * t;
}

/// Nearest vertex of `face` (an index into `m.faces`) to WORLD point `p` —
/// argmin |p - toWorld(vert)|, where `ms` is the mesh's own layer ModelSpace
/// (`m.vertices[]` are LOCAL; `p` is world — a background layer with a
/// non-identity transform needs each candidate folded into world before the
/// distance compare, or the election silently drags onto the layer's
/// IDENTITY pose instead of where it is actually drawn). Pure, best-effort:
/// returns -1 when `face` is out of range or empty (never throws / asserts
/// — a raycast hit against a face that has since been mutated out from
/// under the caller degrades to "no nearest element" rather than
/// crashing).
int nearestFaceVertex(const ref Mesh m, ModelSpace ms, int face, Vec3 p)
    pure nothrow @safe
{
    if (face < 0 || face >= cast(int)m.faces.length) return -1;
    const f = m.faces[face];
    const bool ident = ms.isIdentity;
    int best = -1;
    float bestD2 = float.infinity;
    foreach (vi; f) {
        if (vi >= m.vertices.length) continue;
        Vec3 wv = ident ? m.vertices[vi] : ms.toWorldPoint(m.vertices[vi]);
        Vec3 d = wv - p;
        float d2 = dot(d, d);
        if (d2 < bestD2) { bestD2 = d2; best = cast(int)vi; }
    }
    return best;
}

/// Nearest edge of `face` (an index into `m.faces`) to WORLD point `p` —
/// argmin point-to-segment distance over the face's boundary edges (each
/// endpoint folded through `ms`, same reasoning as `nearestFaceVertex`
/// above), resolved to a `m.edges` index via `edgeKey`/`edgeIndexMap`.
/// Best-effort: returns -1 when `face` is out of range, has fewer than 2
/// vertices, or `m.edgeIndexMap` is not currently valid/built (P0 accepts
/// -1 here rather than forcing a rebuild from a `const` reference — see
/// doc/topopen_p0_plan.md risk R6). NOT `pure` — `Mesh.edgeMapUsable()`
/// isn't itself annotated pure.
int nearestFaceEdge(const ref Mesh m, ModelSpace ms, int face, Vec3 p) {
    if (face < 0 || face >= cast(int)m.faces.length) return -1;
    if (!m.edgeMapUsable()) return -1;
    const f = m.faces[face];
    if (f.length < 2) return -1;
    const bool ident = ms.isIdentity;

    int best = -1;
    float bestD2 = float.infinity;
    foreach (i; 0 .. f.length) {
        uint a = f[i];
        uint b = f[(i + 1) % f.length];
        if (a >= m.vertices.length || b >= m.vertices.length) continue;
        Vec3 wa = ident ? m.vertices[a] : ms.toWorldPoint(m.vertices[a]);
        Vec3 wb = ident ? m.vertices[b] : ms.toWorldPoint(m.vertices[b]);
        Vec3 cp = closestPointOnSegment3D(p, wa, wb);
        Vec3 d  = cp - p;
        float d2 = dot(d, d);
        if (d2 >= bestD2) continue;
        if (auto ep = edgeKey(a, b) in m.edgeIndexMap) {
            bestD2 = d2;
            best   = cast(int)*ep;
        }
    }
    return best;
}

/// Re-derives `idx` against a just-fetched array length, returning `idx`
/// unchanged when it is currently in range (`0 <= idx < len`) and -1
/// otherwise. Backs the CONS stage's `raycastBackground`
/// (source/toolpipe/stages/constrain.d), which computes
/// `nearestVert`/`nearestEdge` via `nearestFaceVertex`/`nearestFaceEdge`
/// above and then separately fills the candidate's world position a few
/// lines later. Both bound their result against the SAME source mesh
/// reference, so today the two stay consistent as an IMPLICIT consequence
/// of nothing mutating the mesh between those two reads — this helper
/// makes the invariant EXPLICIT at the fill site instead (review NIT-1):
/// a caller that re-derives its index through this function before filling
/// the position can never end up publishing a `>=0` index whose position
/// it left at the struct default (`Vec3(0,0,0)`) — the "phantom vertex at
/// world origin" hazard `resolveHoverTarget` below would otherwise trust
/// unconditionally (it only guards `>= 0`, not "position was actually
/// filled").
int consistentCandidateIndex(int idx, size_t len) pure nothrow @nogc @safe {
    return (idx >= 0 && idx < cast(int)len) ? idx : -1;
}

// ---------------------------------------------------------------------------
// The Topology Pen's TWO proximity radii (reference parity, task 0496)
//
// The pen runs TWO closest-element queries, not one, and they have DIFFERENT
// reaches. An earlier static reading FUSED them into a single 15px threshold;
// the live run took that reading apart, and neither query is 15px.
//
//   PRESS PICK — "what does this press grab", and (because they share
//     `resolveGrabTarget`) "what does the hover highlight name". One query,
//     every element type enumerated at once. The reference printed ONE shared
//     limit of 8.0 on every press it was watched on.
//
//     The reach it actually DELIVERED is a BRACKET, not a value, and this
//     comment says so rather than pretending to a precision nobody has:
//
//         vertex candidate : enumerated at 7.07px, NOT enumerated at 7.78px
//                            => the cut lies in (7.07, 7.78]
//         edge   candidate : enumerated at 7.00px, NOT enumerated at 8.85px
//                            => the cut lies in (7.00, 8.85]
//
//     The rig's own geometry and the reference's computed distance were seen
//     to differ by up to ~1.2px, which is wider than the gap between the two
//     brackets — so both are consistent with the ONE printed limit of 8.0, and
//     8.0 is the value taken here. Tests pin the bracket's ENDS (at/below
//     7.0px must resolve, at/above 8.9px must not); no test pins 8.0 as a
//     behavioural edge, because the measurement does not support one.
//
//   DRAG SNAP — "which existing element does a drag LAND on / weld to". A
//     different query with its own radii: acceptance 24.0px, candidate gather
//     40.0px. Neither number gates a press.
//
// TWO QUERIES, therefore, wired to two consumers — see `topoPenPressPickPx`
// and `topoPenSnapAcceptPx` below. One constant standing in for both was wrong
// in BOTH directions at once: too wide for a press (a vertex 14px away, or an
// edge 9px away, was ours to grab and the reference's to skip in favour of the
// polygon — a ~7px annulus of disagreement around every vertex and edge) and
// too narrow for the drag snap that decides whether a drag welds.
//
// ONE of the two queries keeps a constant here, and the other does NOT, and
// the asymmetry is the whole point:
//
//   * The PRESS PICK's 8px is the pen's own. Nothing configures it, no
//     snapping guide is registered for it, and no range is pushed into it —
//     it is a plain closest-element query the tool runs for itself. Its
//     constant stays right here, below.
//
//   * The DRAG SNAP's two radii are NOT the pen's. They are application-wide
//     snapping CONFIGURATION with a public setter, defaulting to 24 (the
//     acceptance) and 40 (the gather); the pen is one registered snapping
//     guide among nine, and the numbers are handed TO it at gesture start.
//     Our own SNAP stage has carried the same pair since the root commit,
//     which means the pen lane and the snap lane independently derived one
//     fact and then stored it twice, in two subsystems that cannot see each
//     other. So `topoPenSnapAcceptPx`/`topoPenSnapGatherPx` take the ranges
//     from a `SnapPacket` instead of owning constants: one pair of numbers
//     in the tree, published by the stage that owns the field.
//
// The 8 and the 24 are therefore NOT to be merged, however alike they look
// once written down as bare floats. They answer different questions, they
// come from different owners, and one of them is configurable while the
// other is not. Merging them is the exact confusion this arrangement exists
// to prevent.
//
// NOTE the packet is DATA, not a pipeline: `toolpipe.packets` imports only
// math/mesh/editmode (this module already depends on it for
// `ConstrainHitPacket`), so taking a `SnapPacket` parameter keeps every
// function here pure and unit-testable with no toolpipe running. Reading the
// LIVE packet is the caller's job, and lives in the tool.
//
// PIXEL CONSTANTS, not scale-derived — and this is the second correction the
// live run forced. A natural experiment settled it: a restart moved the
// reference's own world-units-per-pixel by -4.7%, and the acceptance radius
// stayed at EXACTLY 24.000 where a scale-derived law required 22.87. A
// `15 x scale` product and its exact double do exist in the same struct slots,
// but they are WORLD-space quantities; the gate is compared in pixels.
// `viewPixelScale` below therefore survives as OUR seam for a future
// device-pixel ratio, NOT as a port of anything the reference computes.
//
// TYPE-UNIFORM WITHIN each query, deliberately: the acceptance compare was
// measured at 24.0 under both a vertex latch and an edge latch (14 samples,
// one number), and the press pick's one printed limit is shared by vertex and
// edge alike. So each query has exactly ONE threshold function today.
//
// That uniformity is a statement about the CANDIDATE GATHER, and only about it
// (task 0507). The reference's press pick gathers every type in one pass at one
// radius -- the 8.0 above -- and then ARBITRATES between the surviving per-type
// candidates with a tolerance that is NOT type-uniform: the vertex leg's
// tolerance is twice the gather radius, the edge and polygon legs' is exactly
// it. We ship no arbitration at all (we short-circuit vertex -> edge -> face at
// the one radius) and every reference row measured so far agrees with our
// order, so the difference is latent rather than live. It is written down
// because the earlier wording here forbade a per-type threshold outright, and
// that would have blocked the correct port of the arbitration if anyone ever
// needs it. ONE GATHER RADIUS: still the law. One tolerance for all three
// types: never was.
//
// MODE-DEPENDENT, and this is the one exemption (task 0507). The reach above
// governs a press in every pen mode EXCEPT Fill. In Fill the reference drops
// the gather radius entirely: the press takes the nearest qualifying element in
// the whole mesh at ANY distance, which is how a press at the bare centre of a
// gap -- 32px from the nearest border edge, 86px from the nearest vertex, where
// an ordinary selection click resolves nothing -- still classifies as an edge
// press and caps the cell. Our Fill press matches: `fillSeedEdge`
// (`tools/edit/topology_pen/tool.d`) scans the WHOLE mesh with no radius at all. Do
// not "unify" it onto `topoPenPressPickPx` -- that would be a real regression,
// and the gap-centroid unittest in `tests/unit/tools/edit/topology_pen/gestures_test.d`
// is what catches
// it.
//
// UNBOUNDED IS NOT UNARBITRATED (task 0488). Dropping the radius does not make
// every press an edge press: whatever else is NEARER still wins the press, and
// only an EDGE press can fill. A recording caught this directly -- a press at
// the centre of a hole that had isolated vertices sitting inside it resolved a
// VERTEX, not the hole's border edge, and nothing happened. `fillSeedEdge`
// carries that arbitration (vertex wins ties, matching the pen's own
// vertex->edge->face precedence and the reference's own vertex-favouring
// tolerance).
//
// The reference's Fill HOVER highlight runs the IDENTICAL candidate search the
// press runs -- read statically and confirmed live (the draw path fires the
// search on every redraw, the build only on evaluate) -- so our hover now
// shares `fillSeedEdge` with the press rather than gating at
// `topoPenPressPickPx`. An earlier note here said the hover was bounded by the
// ordinary reach; that reading is superseded.
//
// A PREFERENCE DEFAULT, not a tool constant. The 8.0 is the reference's
// application-wide element-selection-size preference at its shipped default,
// handed to the pen's press pick as the gather radius; the "twice" two
// paragraphs up is a second preference (a point-selection scale, default 2.0).
// A third preference -- a "lazy selection" toggle -- removes the gather radius
// in EVERY mode when a user turns it on, exactly as Fill does unconditionally.
// vibe3d models none of the three: we hardcode the two defaults and the un-lazy
// behaviour. A deliberate, recorded simplification rather than an oversight,
// and the place a future preference would plug in.
// ---------------------------------------------------------------------------

/// Nominal PRESS-PICK reach in "reference pixels" — the limit the reference
/// printed on every press. Not to be used raw: call `topoPenPressPickPx(vp)`.
///
/// BRACKETED, not exact: the delivered reach was measured to lie in
/// (7.07, 7.78] for a vertex candidate and (7.00, 8.85] for an edge candidate,
/// both consistent with this one printed limit within the ~1.2px between the
/// rig's geometry and the reference's own computed distance. Move this number
/// only with a measurement that narrows those brackets.
///
/// THIS ONE STAYS A CONSTANT, and it is deliberately not the snap acceptance
/// even though `SnapPacket.init.innerRangePx` once also read 8.0f and made
/// them look interchangeable. The press pick is a different QUERY with a
/// different OWNER: no snapping guide is registered for it, no configured
/// range is pushed into it, and no user setting moves it — it is the tool's
/// own closest-element reach. The drag-snap radii below, by contrast, are
/// application-wide configuration the pen is HANDED, so they come off a
/// `SnapPacket` and there is no `kTopoPenSnapAcceptNominalPx` to pair with
/// this. Do not reintroduce one, and do not fold this into the packet: the
/// numeric coincidence that briefly made 8.0 the packet's acceptance default
/// is precisely the confusion being prevented here.
/// SCOPE (task 0507): every mode but Fill, and only while the reference's
/// "lazy selection" preference is off — see the MODE-DEPENDENT and PREFERENCE
/// DEFAULT paragraphs in the block comment above before wiring this into a new
/// call site.
enum float kTopoPenPressPickNominalPx = 8.0f;

/// Sentinel for the pen resolvers' `thresholdPx` parameter meaning "derive the
/// threshold from the view" (`topoPenPressPickPx`). Negative, so it can never
/// be confused with a real pixel distance, and distinct from `float.infinity`,
/// which those resolvers already use to mean "nearest at ANY distance".
enum float kTopoPenSnapAuto = -1.0f;

/// The view's pixel scale — the dimensionless factor between the nominal pixel
/// counts above and the pixel space this codebase actually picks in.
///
/// NOT a port. The reference's radii are pixel CONSTANTS (measured: a -4.7%
/// change in its own world-units-per-pixel left the acceptance at exactly
/// 24.000, where a scale-derived law required 22.87), so multiplying by 1.0
/// here reproduces them exactly. The seam exists for OUR benefit, and only for
/// the one thing the measurement leaves open:
///
/// vibe3d picks in WINDOW-space points — SDL mouse coordinates, `Viewport.x/y/
/// width/height` and `projectToWindowFull`'s output are all the same space,
/// and nothing on `Viewport` carries a device-pixel ratio. `app.d` does know
/// one (`SDL_GL_GetDrawableSize` vs `SDL_GetWindowSize`, used for `glViewport`
/// and the thick-line program) but it never reaches the pick path, so the
/// honest value here is 1.0 — a HiDPI window picks with the same numbers as a
/// 1x one today, and whether the reference's constants are in device pixels or
/// in points is UNMEASURED.
///
/// TODO (task 0496 follow-up): if a per-view device-pixel ratio is ever wanted
/// on the pick path, return it HERE and every Topology Pen radius follows.
/// Deliberately takes the viewport it scales, so that needs no signature churn.
float viewPixelScale(const ref Viewport vp) pure nothrow @nogc @safe {
    return 1.0f;
}

/// The Topology Pen's PRESS-PICK reach for this view, in the pixel space the
/// pick math uses: how far a press (and therefore the hover highlight) reaches
/// for a vertex or an edge before falling through to the face under the cursor.
///
/// Bracketed, not exact — see `kTopoPenPressPickNominalPx`.
float topoPenPressPickPx(const ref Viewport vp) pure nothrow @nogc @safe {
    return kTopoPenPressPickNominalPx * viewPixelScale(vp);
}

/// The Topology Pen's DRAG-SNAP acceptance radius for this view: how close a
/// drag must come to an existing element for the drag to LAND on it. Three
/// times the press-pick reach at the default configuration, and measured
/// separately from it — a press and a drag-landing at the same pixel
/// legitimately answer differently.
///
/// `snap` is the CONFIGURATION, not a constant: the acceptance is the snap
/// service's inner range, which every snapping client in the application
/// shares and which has a public setter. The pen holds a snapshot taken at
/// gesture start (`TopologyPenTool.dragSnap_`) and passes it here, which is
/// the same shape as the ranges being pushed into a registered guide when its
/// drag begins. Pass `SnapPacket.init` for the default pair.
float topoPenSnapAcceptPx(const ref Viewport vp, in SnapPacket snap)
    pure nothrow @nogc @safe
{
    return snap.innerRangePx * viewPixelScale(vp);
}

/// The Topology Pen's drag-snap candidate GATHER range for this view — the
/// snap service's outer range, same configuration source as the acceptance
/// above (see that function's note on `snap`).
///
/// It bounds nothing today, and that is a property of OUR shape rather than a
/// half-port: the snap-target resolver enumerates the whole primary mesh and
/// keeps the single closest candidate, so "closest within the gather" and
/// "closest within infinity" accept and reject exactly the same set once the
/// acceptance test runs. It is defined and pinned here because the law has two
/// radii on this query and any consumer that DOES need the wider one must read
/// it from here rather than re-deriving it from the acceptance.
float topoPenSnapGatherPx(const ref Viewport vp, in SnapPacket snap)
    pure nothrow @nogc @safe
{
    return snap.outerRangePx * viewPixelScale(vp);
}

unittest { // the THREE measured numbers, and the two refutations behind them
    auto vp = makeHoverTestViewport();
    // The default snap configuration — the pen's own drag snapshot is exactly
    // this whenever the user has not moved the ranges, so the measured values
    // are still pinned here, just through their real owner.
    const SnapPacket snap;

    assert(viewPixelScale(vp) == 1.0f,
        "the measured radii are pixel constants; the scale seam is ours, and it is 1.0 today");

    assert(topoPenPressPickPx(vp) == 8.0f,
        "the press pick reaches the one limit the reference printed on every press");
    assert(topoPenSnapAcceptPx(vp, snap) == 24.0f,
        "the drag-snap acceptance is its own, separately measured radius — and it "
        ~ "is the snap service's DEFAULT inner range, one fact stored once");
    assert(topoPenSnapGatherPx(vp, snap) == 40.0f,
        "the drag-snap gather is a second measured nominal, not a factor on the acceptance");

    // The two queries are DIFFERENT reaches. This is the whole correction: a
    // single constant cannot serve both, and the 15px that used to sit here
    // was neither of them.
    assert(topoPenPressPickPx(vp) < topoPenSnapAcceptPx(vp, snap),
        "press pick and drag snap are two queries with two reaches, not one shared gate");
    assert(topoPenPressPickPx(vp) != 15.0f && topoPenSnapAcceptPx(vp, snap) != 15.0f,
        "15px was the fusion of the two queries and is neither of them");

    // gather : acceptance is 5/3. A `2.0` factor here was refuted outright.
    assert(topoPenSnapGatherPx(vp, snap) / topoPenSnapAcceptPx(vp, snap) == 5.0f / 3.0f,
        "the gather:acceptance ratio is 5/3, not the 2.0 the static reading assumed");
    assert(topoPenSnapGatherPx(vp, snap) != 2.0f * topoPenSnapAcceptPx(vp, snap),
        "the refuted 2.0 factor must not creep back in");

    // Type-uniformity of the GATHER is structural, not a value check: each
    // query has exactly one threshold function, so a per-type gather radius
    // cannot be expressed without adding one. These assertions document the
    // invariant the measurement proved (one acceptance under both a vertex and
    // an edge latch; one printed press limit shared by vertex and edge) so a
    // future per-type "improvement" to the GATHER has to delete a stated law
    // first. It says nothing about the reference's cross-type ARBITRATION,
    // whose tolerance is per-type and which we do not implement -- see the
    // block comment above (task 0507).
    assert(topoPenPressPickPx(vp) == topoPenPressPickPx(vp),
        "one press-pick GATHER reach for vertex, edge and polygon candidates alike");
    assert(topoPenSnapAcceptPx(vp, snap) == topoPenSnapAcceptPx(vp, snap),
        "one drag-snap acceptance for every candidate type");

    // THE DE-DUPLICATION, asserted rather than merely commented: the pen has no
    // acceptance/gather constants of its own left, so these two functions can
    // only be reporting the snap service's configuration. Move the ranges and
    // both must move with them — a re-introduced private constant would pin
    // them at 24/40 here and fail.
    SnapPacket moved;
    moved.innerRangePx = 12.0f;
    moved.outerRangePx = 33.0f;
    assert(topoPenSnapAcceptPx(vp, moved) == 12.0f,
        "the acceptance is the packet's inner range, not a constant this module owns");
    assert(topoPenSnapGatherPx(vp, moved) == 33.0f,
        "the gather is the packet's outer range, not a constant this module owns");

    // The press pick does NOT follow it: different query, different owner,
    // nothing configures it. This is the merge that must never happen.
    assert(topoPenPressPickPx(vp) == 8.0f,
        "the press pick is the pen's own reach and no snap setting may move it");
}

/// PINNED shape AND pinned precedence: pure screen-space resolution of
/// the hover's place-target from an already-published `ConstrainHitPacket`
/// (the CONS stage's background-surface raycast result — see
/// `source/toolpipe/stages/constrain.d`'s `raycastBackground`). No mesh
/// access, no cursor input — every input is carried on `h` (world
/// positions of the raycast hit and its candidate nearest vert/edge) so
/// `/api/surface-raycast` and `TopologyPenTool` compute IDENTICALLY from
/// the same packet (REV-A: this lives in the constraint layer, mirroring
/// `nearestFaceVertex`/`nearestFaceEdge` above, NOT in the CONS stage or
/// the tool).
///
/// This is the PRESS-PICK query, so `thPx` is the press-pick reach (task 0496
/// — callers pass `topoPenPressPickPx(vp)`, NOT the wider drag-snap
/// acceptance), and it is type-uniform by construction: the same `thPx` gates
/// the vertex and the edge candidate, matching the reference's single printed
/// press limit.
///
/// The PRECEDENCE around it (Vertex > Edge > Face, short-circuited) is
/// MEASURED-POSITIVE, not a placeholder. The rival law — "take the one closest
/// candidate across all types, apply the radius afterwards" — was refuted
/// twice on the reference: a vertex at 5.83px beat an edge at 3.00px and a
/// polygon at 0.00px, and a vertex at 7.07px beat an edge at 7.00px. Porting
/// "one closest across types" would be a regression, and a test pins the
/// vertex-beats-nearer-edge case so it cannot be "fixed" back.
///
/// MEASURING POINT, recorded not fixed: this resolver measures from the
/// projected surface HIT (`h.point`), while the pen's own primary-mesh
/// resolvers measure from the RAW CURSOR pixel — two different origins behind
/// one shared radius. On the reference's DRAG-SNAP query the compare distance
/// was measured to track the re-projected drag position (press + drag offset)
/// to better than 1.3px over a 32px sweep; that is a positive measurement of
/// what it uses, but it does NOT isolate that origin from the cursor, because
/// on the fronto-parallel rig the two track each other. So no divergence is
/// claimed here and none may be coded on that evidence. Both of our origins are
/// pinned by tests so they cannot drift silently; unifying them is task 0496
/// `## Открыто`.
///
/// `h.hit == false` (no surface hit at all) resolves to
/// `HoverTargetKind.None`; a hit that is behind the camera when projected
/// (should not normally happen — the hit itself came from a ray through
/// the same viewport) also degrades to `None` rather than asserting.
HoverTarget resolveHoverTarget(const ref ConstrainHitPacket h,
                               const ref Viewport vp, float thPx)
{
    HoverTarget r;                      // {None, -1, -1}
    if (!h.hit) return r;               // no surface hit -> no target

    r.kind = HoverTargetKind.Face;      // hit, but unsnapped default
    float ax, ay, az;
    if (!projectToWindowFull(h.point, vp, ax, ay, az)) return r;

    // Vertex candidate — priority 1.
    if (h.nearestVert >= 0) {
        float vx, vy, vz;
        if (projectToWindowFull(h.nearestVertPos, vp, vx, vy, vz)) {
            float dx = vx - ax, dy = vy - ay;
            if (dx * dx + dy * dy <= thPx * thPx) {
                r.kind = HoverTargetKind.Vertex;
                r.vert = h.nearestVert;
                return r;
            }
        }
    }

    // Edge candidate — priority 2.
    if (h.nearestEdge >= 0) {
        float ea0, ea1, ea2, eb0, eb1, eb2;
        if (projectToWindowFull(h.nearestEdgeA, vp, ea0, ea1, ea2)
         && projectToWindowFull(h.nearestEdgeB, vp, eb0, eb1, eb2)) {
            float t;
            if (closestOnSegment2D(ax, ay, ea0, ea1, eb0, eb1, t) <= thPx) {
                r.kind = HoverTargetKind.Edge;
                r.edge = h.nearestEdge;
                return r;
            }
        }
    }

    return r;                           // Face
}

// ---------------------------------------------------------------------------
// constrainPoint
//
// Top-level dispatch called from xfrm_transform.d::applyTRS for each
// moved vertex's final position. Returns `movingPos` unchanged when:
//   * cfg.enabled == false,
//   * cfg.geom == Off,
//   * no background sources are present,
//   * vector mode: motionDelta is zero or near-zero (no meaningful direction),
//   * screen mode: the view matrix is degenerate or uninitialised,
//   * any mode: projectAlongDirection finds no forward hit (keep-on-miss).
//
// Parameters:
//   movingPos   — the vertex's final world-space position after applyFold.
//   motionDelta — per-vertex edit delta (finalPos − basePos); consumed by
//                 `vector` mode as the projection direction; unused by `point`.
//   vp          — active viewport; consumed by `screen` mode to extract the
//                 camera-forward axis; unused by `point`.
//   sources     — background-mesh sources (mesh + that layer's ModelSpace)
//                 from snap.backgroundSourcesFull().
//   cfg         — live ConstrainPacket published by ConstrainStage.
// ---------------------------------------------------------------------------
Vec3 constrainPoint(Vec3 movingPos,
                    Vec3 motionDelta,
                    Viewport vp,
                    const(BackgroundSource)[] sources,
                    const ref ConstrainPacket cfg)
{
    if (!cfg.enabled) return movingPos;
    if (sources.length == 0) return movingPos;

    final switch (cfg.geom) {
        case ConstrainGeom.Off:
            return movingPos;

        case ConstrainGeom.Point: {
            Vec3 hit, hitN;
            float d2;
            int _si, _fi;   // winning source/face — unused by this caller
            if (!closestPointOnMeshes(movingPos, sources, cfg.dblSided,
                                      hit, hitN, _si, _fi, d2))
                return movingPos;
            return applyOffset(hit, hitN, cfg.offset);
        }

        case ConstrainGeom.Vector: {
            // Project along the normalized per-vertex edit direction.
            Vec3 dir = motionDelta;
            float lenSq = dot(dir, dir);
            if (!(lenSq > 1e-12f)) return movingPos;  // zero / near-zero delta → identity
            dir = normalize(dir);
            Vec3 hit, hitN;
            if (!projectAlongDirection(movingPos, dir, sources, cfg.dblSided, hit, hitN))
                return movingPos;                      // forward miss → keep position
            return applyOffset(hit, hitN, cfg.offset);
        }

        case ConstrainGeom.Screen: {
            // Project along the camera view axis (into the scene).
            if (vp.width == 0 || vp.height == 0) return movingPos;  // headless / uninitialised
            // Extract camFwd from view matrix column-major layout: -f at m[2], m[6], m[10].
            // (axis.d:336 reads the same indices, though the guard there covers the right-vector
            // magnitude rather than the forward-vector magnitude checked below.)
            Vec3 fwdVec = Vec3(-vp.view[2], -vp.view[6], -vp.view[10]);
            float lenSq = dot(fwdVec, fwdVec);
            if (!(lenSq > 1e-6f)) return movingPos;   // degenerate / NaN view matrix
            Vec3 camFwd = normalize(fwdVec);
            Vec3 hit, hitN;
            if (!projectAlongDirection(movingPos, camFwd, sources, cfg.dblSided, hit, hitN))
                return movingPos;                      // forward miss → keep position
            return applyOffset(hit, hitN, cfg.offset);
        }
    }
}

// ---------------------------------------------------------------------------
// Unit tests — run under `dub test --config=tests`.
// (MANDATORY for core math modules: the HTTP test suite silently skips
// unittest blocks in modules not imported by the test binary.)
// ---------------------------------------------------------------------------

















// ---------------------------------------------------------------------------
// P0 (topology-pen) unit tests: nearestFaceVertex / nearestFaceEdge.
// ---------------------------------------------------------------------------







// ---------------------------------------------------------------------------
// resolveHoverTarget — topology-pen P1 (doc/topopen_p1_plan.md). GL-free
// pure unittests: a synthetic Viewport (identity-ish lookAt at Z=5, 90°
// symmetric perspective, 800x800) makes the projected-pixel math a plain
// scale by a hand-derivable constant, so every expected pixel distance
// below is independently computed (not round-tripped through the function
// under test) — same rigor as the HTTP fixture's threshold-flip cases
// (topo_pen_hover_target.json #5/#6).
//
// Camera: eye=(0,0,5), lookAt origin, up=(0,1,0), fovY=90 deg (f = 1/tan(45)
// = 1), aspect=1, width=height=800. Both the hit point and every candidate
// below sit at world Z=0 (same depth as the lookAt target), so the
// perspective divide's w is constant (== distance == 5) across all of
// them, and the projection collapses to a PURE uniform scale + centering:
//   screenX = 400 + S*worldX,  screenY = 400 - S*worldY,  S = f*0.5*height/eye.z
//           = 1 * 0.5*800/5 = 80 px per world unit.
// (This is the SAME derivation the topo_pen_hover_target.json fixture's
// provenance uses for its az=0/el=0 cube cases — see that file's notes.)
// ---------------------------------------------------------------------------
version (unittest) private Viewport makeHoverTestViewport() {
    import math : lookAt, perspectiveMatrix;
    import std.math : PI;
    Viewport vp;
    vp.eye    = Vec3(0, 0, 5);
    vp.view   = lookAt(vp.eye, Vec3(0, 0, 0), Vec3(0, 1, 0));
    vp.proj   = perspectiveMatrix(PI / 2, 1.0f, 0.1f, 100.0f);
    vp.width  = 800;
    vp.height = 800;
    vp.x = 0;
    vp.y = 0;
    return vp;
}

unittest { // resolveHoverTarget — no hit -> None (default packet)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;   // hit == false by default
    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.None, "no hit must resolve to None");
    assert(t.vert == -1 && t.edge == -1);
}

unittest { // resolveHoverTarget — vertex within threshold wins (S=80 px/unit;
           // a 0.1-world-unit offset at Z=0 depth projects to exactly 8px)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit           = true;
    h.point         = Vec3(0, 0, 0);          // projects to (400,400)
    h.nearestVert   = 3;
    h.nearestVertPos = Vec3(0.1f, 0, 0);      // projects to (408,400): 8px away
    h.nearestEdge   = -1;                     // no edge candidate this case

    auto wide = resolveHoverTarget(h, vp, 12.0f);     // 8 <= 12
    assert(wide.kind == HoverTargetKind.Vertex, "8px within a 12px radius must snap to Vertex");
    assert(wide.vert == 3);

    auto narrow = resolveHoverTarget(h, vp, 4.0f);    // 8 > 4
    assert(narrow.kind == HoverTargetKind.Face, "8px outside a 4px radius must fall through to Face");
}

unittest { // resolveHoverTarget — edge wins when the vertex candidate is far
           // but the edge segment passes through the hit's projected pixel
           // (vert offset (2,0,0) -> 160px away; edge endpoints (0,+-0.1,0)
           // -> a vertical segment straddling (400,400) exactly, 0px).
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit         = true;
    h.point       = Vec3(0, 0, 0);
    h.nearestVert = 1;
    h.nearestVertPos = Vec3(2.0f, 0, 0);      // 160px away — outside any sane radius
    h.nearestEdge = 5;
    h.nearestEdgeA = Vec3(0,  0.1f, 0);       // projects to (400, 392)
    h.nearestEdgeB = Vec3(0, -0.1f, 0);       // projects to (400, 408)

    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Edge, "vertex far / edge through the hit pixel must resolve to Edge");
    assert(t.edge == 5);
}

unittest { // resolveHoverTarget — a FARTHER vertex still beats a NEARER edge.
           //
           // Task 0496, the deliberately-opposite test. The rival law once
           // written into this file's docstring — "take the one closest
           // candidate across all types, apply the radius afterwards" — would
           // resolve the EDGE here. It was refuted on the reference twice, on
           // two independent cells (a vertex at 5.83px beat an edge at 3.00px
           // and a polygon at 0.00px; a vertex at 7.07px beat an edge at
           // 7.00px). This case is that shape, at this viewport's 80px per
           // world unit: the vertex sits 5.6px from the hit pixel and the edge
           // segment passes straight THROUGH it at 0px, with both inside the
           // press-pick reach — and the vertex must win.
           //
           // Red under "one closest across types"; green under the measured
           // vertex-first short circuit.
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit            = true;
    h.point          = Vec3(0, 0, 0);          // projects to (400, 400)
    h.nearestVert    = 2;
    h.nearestVertPos = Vec3(0.07f, 0, 0);      // 5.6px away — farther than the edge
    h.nearestEdge    = 9;
    h.nearestEdgeA   = Vec3(0,  0.1f, 0);      // the segment straddles (400,400):
    h.nearestEdgeB   = Vec3(0, -0.1f, 0);      // distance 0px, i.e. strictly nearer

    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Vertex,
        "a vertex INSIDE the press-pick reach must win over a strictly nearer edge — the "
      ~ "'one closest candidate across types' law was measured-negative and must not be ported");
    assert(t.vert == 2, "and it must be that vertex");
}

unittest { // resolveHoverTarget — neither candidate in range -> Face
           // (vert offset (2,0,0) -> 160px; edge same offset -> also far)
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit         = true;
    h.point       = Vec3(0, 0, 0);
    h.nearestVert = 0;
    h.nearestVertPos = Vec3(2.0f, 0, 0);
    h.nearestEdge = 0;
    h.nearestEdgeA = Vec3(2.0f,  0.1f, 0);
    h.nearestEdgeB = Vec3(2.0f, -0.1f, 0);

    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Face, "no candidate within the default radius must resolve to Face");
    assert(t.vert == -1 && t.edge == -1);
}

unittest { // resolveHoverTarget — near-threshold, independently computed:
           // a 0.1499-world-unit offset at S=80px/unit projects to ~11.992px
           // (0.1499*80=11.992), a hair BELOW the 12.0f this case passes rather
           // than exactly on it (review NIT-2 — the prior version picked an
           // offset landing EXACTLY at the threshold and asserted `==`
           // through the full lookAt/perspective/mulMV pipeline; that FP
           // chain isn't guaranteed bit-exact, so resting a "must snap"
           // assertion on hitting the boundary precisely was fragile).
           // Comfortably-separated margins on both sides (12.0 - 11.992 =
           // 0.008px "inside", 11.992 - 11.9 = 0.092px "outside") are each
           // orders of magnitude larger than any plausible FP rounding
           // noise from that pipeline, so this still exercises the `<=`
           // inclusive comparison's intent (a just-inside point snaps)
           // without resting on exact equality.
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit           = true;
    h.point         = Vec3(0, 0, 0);
    h.nearestVert   = 7;
    h.nearestVertPos = Vec3(0.1499f, 0, 0);   // ~11.992px from the hit
    h.nearestEdge   = -1;

    auto justInside = resolveHoverTarget(h, vp, 12.0f);
    assert(justInside.kind == HoverTargetKind.Vertex,
        "a point just inside the snap radius must snap");

    auto justOutside = resolveHoverTarget(h, vp, 11.9f);
    assert(justOutside.kind == HoverTargetKind.Face,
        "a threshold just below the point's actual distance must NOT snap");
}

unittest { // resolveHoverTarget — stale candidate reset to -1 by the
           // producer's consistency guard (review NIT-1) resolves to Face,
           // not a phantom vertex at the world origin. Before NIT-1,
           // `raycastBackground` (source/toolpipe/stages/constrain.d)
           // could leave `nearestVert`/`nearestEdge` at whatever
           // nearestFaceVertex/nearestFaceEdge returned while separately
           // gating ONLY the position fill on an in-bounds check — so a
           // stale index (>= 0) could reach here paired with the packet's
           // default `Vec3(0,0,0)` position. Since the hit point itself is
           // ALSO at the origin, a buggy producer trusting that pairing
           // would make resolveHoverTarget snap to a "vertex" that is
           // really just the struct default, at 0px away — a false
           // positive indistinguishable from a genuine coincident hit.
           // `consistentCandidateIndex` (constraint.d) now resets the
           // index to -1 in that case, so this packet (as the FIXED
           // producer would actually publish it) must fall through to
           // Face instead.
    auto vp = makeHoverTestViewport();
    ConstrainHitPacket h;
    h.hit            = true;
    h.point          = Vec3(0, 0, 0);          // projects to (400, 400)
    h.nearestVert    = -1;                     // consistentCandidateIndex()'s output
    h.nearestVertPos = Vec3(0, 0, 0);           // struct default — never actually filled
    h.nearestEdge    = -1;                      // same story for the edge candidate
    h.nearestEdgeA   = Vec3(0, 0, 0);
    h.nearestEdgeB   = Vec3(0, 0, 0);

    auto t = resolveHoverTarget(h, vp, topoPenPressPickPx(vp));
    assert(t.kind == HoverTargetKind.Face,
        "a reset (-1) candidate must never resolve to a phantom origin vertex/edge");
    assert(t.vert == -1 && t.edge == -1);
}
