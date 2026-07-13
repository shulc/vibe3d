module tools.align_kernels;

// Shared kernels for the Align deform-tools family — Linear Align /
// Radial Align (task 0361). Both the interactive tools
// (tools/linear_align_tool.d, tools/radial_align_tool.d) and the one-shot
// commands (commands/mesh/linear_align.d, commands/mesh/radial_align.d)
// call these so the two entry points run byte-identical geometry.
//
// Reference algorithm — measured by live reference-editor capture (task
// 0361; the raw captures are private, only the LAW is reproduced here):
//
//   Chain extraction: both tools operate on an ORDERED CHAIN of vertices,
//   walked through mesh-edge connectivity from the current selection
//   (Vertices mode: any selected vert; Edges mode: verts of selected
//   edges; Polygons mode: verts on the BOUNDARY of the selected face
//   region), falling back to selection/click order
//   (Mesh.vertexSelectionOrder) when the induced subgraph isn't a single
//   simple path or cycle (branching, multiple disconnected pieces, or no
//   qualifying edges at all). See extractAlignChain below.
//
//   Linear Align (mode=line — see linearAlignTargets's doc comment for
//   why `curve` isn't implemented): the chain's two ENDPOINTS never move.
//   Every interior vertex lands on the line between them, either by its
//   OWN spatial projection onto that line (uniform=false — "aligns
//   positions to the closest position along the line") or by equal
//   chain-index spacing (uniform=true — "aligns points with the same
//   spans"). Both forms reduce to the same formula,
//   `new = endpointA + t * (endpointB - endpointA)`, differing only in
//   how `t` is computed — and both naturally reproduce t=0/t=1 (i.e. "no
//   move") at the two endpoints without any special-casing.
//
//   Radial Align (mode=circle/nside — CONFIRMED: no cylinder/sphere mode
//   exists in the reference tool): center = mean chain position, radius =
//   mean distance from center (auto-computed), and the N chain points are
//   placed at equal 360/N-degree slots, in chain order, around that
//   circle. `angle` is a pure additive rotation of the whole slot
//   framework (measured bit-exact as a cyclic permutation of the
//   unrotated result). See radialAlignTargets's doc comment for the
//   UNVERIFIED base-anchor convention this implementation uses — the
//   reference tool's actual anchor formula was not pinned by the capture.
//
//   Both tools: `weight` blends `lerp(source, aligned, weight)` — the
//   SAME per-component linear blend the rest of the deform-tool family
//   uses (Move / Bend / Push; see agent memory vibe3d_scale_blend_gap).
//   Per-vertex falloff modulation (WGHT stage) multiplies into this same
//   `weight` at the call site — this module has no falloff dependency.

import mesh     : Mesh;
import editmode : EditMode;
import math     : Vec3, dot, cross;
import std.math : sqrt, cos, sin, PI, abs;
import std.algorithm : sort;

// ---------------------------------------------------------------------
// Chain extraction
// ---------------------------------------------------------------------

/// Ordered vertex chain extracted from a selection. `closed` marks a full
/// loop (every masked vertex degree-2 in the induced adjacency, e.g. a
/// ring selection) as opposed to an open chain with two fixed endpoints.
/// `verts` IS the full moving set — both align laws below process exactly
/// (and only) these indices, in this order.
struct AlignChain {
    uint[] verts;
    bool   closed;
}

/// Pack an unordered vertex-index pair into a single lookup key (min in
/// the high word). Local helper — deliberately not reaching into Mesh's
/// own private edge-key helper, since this module only needs read access
/// to `mesh.edges`/`mesh.faces`, not any Mesh internals.
private ulong packEdgeKey(uint a, uint b) pure nothrow @nogc @safe {
    if (a > b) { uint t = a; a = b; b = t; }
    return (cast(ulong)a << 32) | cast(ulong)b;
}

/// Extract the ordered chain for the CURRENT selection under `editMode`.
/// Uses the same "nothing selected ⇒ whole mesh" convention as
/// `Mesh.selectedVertexIndices{Vertices,Edges,Faces}` (so an align op on
/// an empty selection behaves like "select all", matching every other
/// selection-driven op in this codebase). See the module doc comment for
/// the extraction rule; `mesh` is read-only here (kept as a plain `Mesh*`
/// to match this codebase's convention rather than fighting D's const
/// propagation through Mesh's largely non-const method surface).
AlignChain extractAlignChain(Mesh* mesh, EditMode editMode) {
    immutable size_t N = mesh.vertices.length;
    bool[] vmask = new bool[](N);

    // Polygons mode additionally restricts the walk to BOUNDARY edges of
    // the selected-face region (per the captured description: in
    // Polygons mode the reference tool uses the boundary edges and
    // connects them as in Edges mode) — an INTERIOR edge of a multi-face
    // patch selection would otherwise branch the walk (a vertex shared by
    // two selected faces has degree > 2 once every incident edge counts).
    // `boundaryEdge[ei]` is only populated/consulted when
    // editMode == Polygons.
    bool[] boundaryEdge;

    // Perf (task 0388): `mesh.selectedX` is a @property that rebuilds a
    // whole `bool[]` per read — indexing it inside these loops was
    // O(mesh²). Iterate the lock-step `*Marks.length` and test via the
    // non-allocating `isXSelected(i)` scalar accessor instead.
    final switch (editMode) {
        case EditMode.Vertices:
            foreach (i; 0 .. mesh.vertexMarks.length)
                if (mesh.isVertexSelected(i)) vmask[i] = true;
            break;
        case EditMode.Edges:
            foreach (i; 0 .. mesh.edgeMarks.length)
                if (mesh.isEdgeSelected(i))
                    foreach (vi; mesh.edges[i]) vmask[vi] = true;
            break;
        case EditMode.Polygons: {
            int[ulong] selCount;
            foreach (fi; 0 .. mesh.faces.length) {
                if (!mesh.isFaceSelected(fi)) continue;
                auto ring = mesh.faces[fi];
                immutable size_t n = ring.length;
                foreach (k; 0 .. n) {
                    uint a = ring[k], b = ring[(k + 1) % n];
                    vmask[a] = true; vmask[b] = true;
                    ulong key = packEdgeKey(a, b);
                    if (auto c = key in selCount) ++(*c);
                    else selCount[key] = 1;
                }
            }
            boundaryEdge.length = mesh.edges.length;
            foreach (ei; 0 .. mesh.edges.length) {
                ulong key = packEdgeKey(mesh.edges[ei][0], mesh.edges[ei][1]);
                if (auto c = key in selCount)
                    boundaryEdge[ei] = (*c == 1);
            }
            break;
        }
    }

    bool any = false;
    foreach (m; vmask) if (m) { any = true; break; }
    if (!any) foreach (i; 0 .. N) vmask[i] = true;

    uint[] idx;
    foreach (i; 0 .. N) if (vmask[i]) idx ~= cast(uint)i;
    if (idx.length < 2) return AlignChain(idx, false);

    // Build adjacency restricted to the included edges (both endpoints
    // masked; Polygons mode additionally requires a boundary edge).
    uint[][uint] adj;
    int[uint]    degree;
    foreach (vi; idx) { adj[vi] = []; degree[vi] = 0; }
    bool overDegree = false;
    foreach (ei; 0 .. mesh.edges.length) {
        uint a = mesh.edges[ei][0], b = mesh.edges[ei][1];
        if (!vmask[a] || !vmask[b]) continue;
        if (editMode == EditMode.Polygons && !boundaryEdge[ei]) continue;
        adj[a] ~= b; adj[b] ~= a;
        degree[a]++; degree[b]++;
        if (degree[a] > 2 || degree[b] > 2) overDegree = true;
    }

    // Fallback: selection/click order (Mesh.vertexSelectionOrder is a
    // 1-based counter, 0 = not manually clicked — e.g. reached via
    // "select all" or the empty-selection whole-mesh convention above).
    // Order-0 entries sort after every genuinely-clicked entry, tie-broken
    // by raw index — deterministic even when nothing was individually
    // clicked.
    AlignChain fallbackOrder() {
        uint[] ord = idx.dup;
        sort!((a, b) {
            int oa = a < mesh.vertexSelectionOrder.length ? mesh.vertexSelectionOrder[a] : 0;
            int ob = b < mesh.vertexSelectionOrder.length ? mesh.vertexSelectionOrder[b] : 0;
            if (oa == 0 && ob == 0) return a < b;
            if (oa == 0) return false;
            if (ob == 0) return true;
            return oa < ob;
        })(ord);
        return AlignChain(ord, false);
    }

    if (overDegree) return fallbackOrder();

    uint[] endpoints;
    foreach (vi; idx) if (degree[vi] == 1) endpoints ~= vi;

    uint startV;
    bool closed;
    if (endpoints.length == 2) {
        startV = endpoints[0];
        closed = false;
    } else if (endpoints.length == 0) {
        // Either a single closed cycle (every masked vertex degree 2) or
        // some vertices have degree 0 (no qualifying incident edge at
        // all) — only the former is a valid closed chain.
        bool allDegree2 = true;
        foreach (vi; idx) if (degree[vi] != 2) { allDegree2 = false; break; }
        if (!allDegree2) return fallbackOrder();
        startV = idx[0];
        closed = true;
    } else {
        // >2 endpoints: multiple disjoint open pieces in the selection
        // (the reference tool aligns each edge group separately — not
        // implemented here, see module doc comment; falls back to
        // selection order instead of guessing a grouping).
        return fallbackOrder();
    }

    // Walk from startV, avoiding backtracking (same algorithm as
    // Mesh.extractSelectedEdgeChain, retargeted to an arbitrary vertex
    // mask instead of mesh.selectedEdges).
    bool[uint] visited;
    uint[] chain;
    uint cur = startV, prev = uint.max;
    while (cur !in visited) {
        visited[cur] = true;
        chain ~= cur;
        uint next = uint.max;
        foreach (n; adj[cur])
            if (n != prev) { next = n; break; }
        if (next == uint.max) break;
        prev = cur;
        cur  = next;
    }

    if (closed) {
        if (cur != startV) return fallbackOrder();   // didn't close → bad component
        if (chain.length < 3) return fallbackOrder();
    } else {
        if (chain.length < 2) return fallbackOrder();
    }
    // Every masked vertex must have been visited — otherwise the
    // selection spans more than one connected component.
    if (chain.length != idx.length) return fallbackOrder();

    return AlignChain(chain, closed);
}

// ---------------------------------------------------------------------
// Blend
// ---------------------------------------------------------------------

/// Per-component linear blend — the `weight` law shared by both align
/// kernels (and by the per-vertex falloff-modulated effective weight the
/// callers derive it from). Same law as the rest of the deform-tool
/// family: `M(w) = (1-w)*source + w*target`.
Vec3 lerp3(Vec3 a, Vec3 b, float t) pure nothrow @nogc @safe {
    return Vec3(a.x + (b.x - a.x) * t,
                a.y + (b.y - a.y) * t,
                a.z + (b.z - a.z) * t);
}

// ---------------------------------------------------------------------
// Linear Align
// ---------------------------------------------------------------------

/// Linear Align target positions — mode=line ONLY. `mode=curve` ("tries
/// to fit a curve to the selected edges") was never captured/measured by
/// the toolcard this port is grounded in — no spline formula is known, so
/// it is NOT implemented; callers route `mode=curve` through this SAME
/// function rather than guessing a curve fit or silently no-op'ing (see
/// the Tool / Command call sites for the explicit fallback comment).
///
/// `source` is the chain's CURRENT (pre-align) positions, in chain order.
/// The two endpoints (index 0 and $-1) are mathematically fixed by the
/// formula below — not special-cased: `t` naturally evaluates to exactly
/// 0 / 1 there.
Vec3[] linearAlignTargets(const(Vec3)[] source, bool uniform) pure nothrow @safe {
    immutable size_t n = source.length;
    Vec3[] result = new Vec3[](n);
    if (n == 0) return result;
    if (n == 1) { result[0] = source[0]; return result; }

    Vec3 a = source[0];
    Vec3 b = source[n - 1];
    Vec3 lineVec = b - a;
    float lenSq = dot(lineVec, lineVec);

    foreach (i; 0 .. n) {
        float t;
        if (uniform || lenSq < 1e-12f) {
            // Equal chain-index spacing — also the degenerate fallback
            // when the two endpoints coincide (no line direction to
            // project non-uniform points onto).
            t = cast(float)i / cast(float)(n - 1);
        } else {
            Vec3 d = source[i] - a;
            t = dot(d, lineVec) / lenSq;
        }
        result[i] = a + lineVec * t;
    }
    return result;
}

// ---------------------------------------------------------------------
// Radial Align
// ---------------------------------------------------------------------

/// Upper bound on Radial Align's `side` (N-Sided mode) — belt-and-braces
/// DoS clamp (task 0361 review convention; see radial_sweep_tool.d's
/// MAX_SWEEP_SIDES precedent). `side` only scales the additive slot-angle
/// step here — no new geometry is allocated per side, unlike Radial
/// Sweep's ring count — but an unbounded/garbage value still degenerates
/// the `360/side` division, so it gets the same double-clamp discipline
/// (Param-level `.max().enforceBounds()` PLUS this kernel-level clamp) as
/// every other count-like Param in this codebase.
enum int MAX_ALIGN_SIDES = 1024;

/// Radial Align target positions — mode=circle/nside. `nsideMode==false`
/// (Circle) always uses `effSides = source.length` (one slot per selected
/// point); `nsideMode==true` (N-Sided) uses `sides` (clamped to
/// `[1, MAX_ALIGN_SIDES]`) — CONFIRMED: no cylinder/sphere mode exists in
/// the reference tool (see module doc comment).
///
/// `source` is the chain's CURRENT (pre-align) positions, in chain order.
///
/// *** BASE ANCHOR CONVENTION — UNVERIFIED (task 0361) ***
/// The reference tool's angle=0 slot base was measured to sit at neither
/// chain-index-0's own angle nor an obvious circular-mean fit of the
/// source angles (no closed form matched the captured base offsets for
/// Circle vs. N-Sided(4) on the same input — see the private toolcard's
/// capture notes). The real anchor formula is an open follow-up, NOT
/// guessed here. This implementation anchors chain index 0 at angle 0
/// (plus `angleDeg` / `rotateDeg`) — the simplest well-defined
/// convention, per task 0361's instruction to implement a documented
/// default rather than invent a divergent formula. Only the `u` basis
/// vector below needs to change if/when the real anchor is captured. The
/// rotation SIGN/handedness (CW vs CCW as the offset increases) is
/// likewise an implementation choice, not bit-verified against the
/// reference.
///
/// What IS bit-exact verified (anchor-independent): `center` = mean
/// source position, `radius` = mean distance from `center`, the N points
/// sit at equal 360/effSides-degree slots, and `angleDeg` is a pure
/// additive rotation of the whole slot framework (see align_kernels.d's
/// unittests for the measured numbers).
Vec3[] radialAlignTargets(const(Vec3)[] source, bool nsideMode, int sides,
                          float angleDeg, float rotateDeg) pure nothrow @safe {
    immutable size_t n = source.length;
    Vec3[] result = new Vec3[](n);
    if (n == 0) return result;
    if (n == 1) { result[0] = source[0]; return result; }

    Vec3 center = Vec3(0, 0, 0);
    foreach (p; source) center = center + p;
    center = center * (1.0f / cast(float)n);

    float distSum = 0.0f;
    foreach (p; source) {
        Vec3 d = p - center;
        distSum += sqrt(dot(d, d));
    }
    float radius = distSum / cast(float)n;
    if (radius < 1e-9f) {
        // Degenerate — every selected point already coincides with the
        // center; there is no well-defined circle to distribute onto.
        foreach (i; 0 .. n) result[i] = source[i];
        return result;
    }

    // Best-fit alignment-plane normal via Newell's method over the
    // ordered chain (wrapping cyclically regardless of open/closed — a
    // standard robust plane-fit technique for a near-planar ordered point
    // set; this codebase already uses the same formula for face
    // normals). Degenerates gracefully to world-up when the fit is
    // numerically flat (e.g. a perfectly collinear source set).
    Vec3 normal = Vec3(0, 0, 0);
    foreach (i; 0 .. n) {
        Vec3 pa = source[i];
        Vec3 pb = source[(i + 1) % n];
        normal.x += (pa.y - pb.y) * (pa.z + pb.z);
        normal.y += (pa.z - pb.z) * (pa.x + pb.x);
        normal.z += (pa.x - pb.x) * (pa.y + pb.y);
    }
    float nl = sqrt(dot(normal, normal));
    if (nl < 1e-9f) normal = Vec3(0, 1, 0);
    else            normal = normal * (1.0f / nl);

    // In-plane basis: `u` is chain-index-0's own (plane-projected)
    // direction from center — this is what anchors index 0 at angle 0,
    // see the BASE ANCHOR note above. `v` completes a right-handed
    // (normal, u, v) frame.
    Vec3 p0 = source[0] - center;
    Vec3 u  = p0 - normal * dot(p0, normal);
    float ul = sqrt(dot(u, u));
    if (ul < 1e-9f) {
        // chain[0] sits exactly on the center (degenerate) — fall back
        // to an arbitrary in-plane axis so the distribution stays
        // well-defined.
        Vec3 arb = (abs(normal.x) < 0.9f) ? Vec3(1, 0, 0) : Vec3(0, 1, 0);
        u  = arb - normal * dot(arb, normal);
        ul = sqrt(dot(u, u));
    }
    u = u * (1.0f / ul);
    Vec3 v = cross(normal, u);

    int effSides = nsideMode ? sides : cast(int)n;
    if (effSides < 1) effSides = 1;
    else if (effSides > MAX_ALIGN_SIDES) effSides = MAX_ALIGN_SIDES;
    immutable float slotStepDeg = 360.0f / cast(float)effSides;
    // `rotateDeg` is the reference's N-Sided-only slot offset ("Offsets
    // the start position... when you select N-Sided", analogous to
    // `angleDeg` for Circle mode per the docs' parallel wording). Composed
    // additively with `angleDeg` for nside mode rather than choosing one
    // exclusively — not independently verified for the nside+rotate
    // combination (the capture only exercised nside at rotate=0).
    immutable float offsetDeg = angleDeg + (nsideMode ? rotateDeg : 0.0f);

    foreach (i; 0 .. n) {
        // side > n (fewer selected points than sides): the reference
        // tool INSERTS interpolated points at the unused corners — not
        // captured/implemented (untested this round per the toolcard).
        // This implementation instead places the n selected points on
        // the FIRST n of `effSides` equal slots — a safe, deterministic,
        // topology-free fallback, NOT a reproduction of the reference's
        // corner-interpolation behaviour.
        immutable float deg = offsetDeg + cast(float)i * slotStepDeg;
        immutable float rad = deg * cast(float)(PI / 180.0);
        immutable float c = cos(rad), s = sin(rad);
        result[i] = center + u * (radius * c) + v * (radius * s);
    }
    return result;
}

// ---------------------------------------------------------------------
// Unit tests — bit-exact / structural laws locked against the private
// capture (task 0361, cases "la_nonuniform" / "la_uniform" / "la_weight05"
// / "ra_circle" / "ra_circle_angle90" / "ra_nside4" / "ra_circle_weight05").
// No reference engine runs at test time — every expected number below was
// hand-verified against the captured data once and is reproduced as a
// literal.
// ---------------------------------------------------------------------

unittest { // Linear Align — chain interpolation law, BIT-EXACT verified
           // against the "la_nonuniform" / "la_uniform" capture cases.
           // 4-vertex open chain on a unit cube (corners
           // A=(-.5,-.5,-.5), B=(.5,-.5,-.5) pre-displaced by
           // (-0.3,+0.35,+0.4), C=(.5,-.5,.5), D=(.5,.5,.5)); endpoints
           // A/D never move.
    Vec3[] source = [
        Vec3(-0.5f, -0.5f, -0.5f),   // A (endpoint)
        Vec3( 0.2f, -0.15f, -0.1f),  // B (interior, displaced)
        Vec3( 0.5f, -0.5f,  0.5f),   // C (interior)
        Vec3( 0.5f,  0.5f,  0.5f),   // D (endpoint)
    ];

    auto nonUniform = linearAlignTargets(source, false);
    assert(nonUniform.length == 4);
    assert(abs(nonUniform[0].x - (-0.5f)) < 1e-5f && abs(nonUniform[0].y - (-0.5f)) < 1e-5f
        && abs(nonUniform[0].z - (-0.5f)) < 1e-5f, "endpoint A must not move");
    assert(abs(nonUniform[3].x - 0.5f) < 1e-5f && abs(nonUniform[3].y - 0.5f) < 1e-5f
        && abs(nonUniform[3].z - 0.5f) < 1e-5f, "endpoint D must not move");
    // t = dot(B-A, D-A)/|D-A|^2 = 1.45/3 = 0.483333...
    enum float nb = -0.0166667f;
    assert(abs(nonUniform[1].x - nb) < 1e-4f && abs(nonUniform[1].y - nb) < 1e-4f
        && abs(nonUniform[1].z - nb) < 1e-4f, "nonuniform B mismatch");
    // t = dot(C-A, D-A)/|D-A|^2 = 2.0/3 = 0.666667... (C wasn't displaced,
    // so its natural index-spacing t and its own-projection t coincide —
    // captured note: a stock cube can't discriminate uniform vs
    // nonuniform for an un-displaced orthogonal-step vertex).
    enum float nc = 0.1666667f;
    assert(abs(nonUniform[2].x - nc) < 1e-4f && abs(nonUniform[2].y - nc) < 1e-4f
        && abs(nonUniform[2].z - nc) < 1e-4f, "nonuniform C mismatch");

    auto uniform = linearAlignTargets(source, true);
    // t = index/(n-1): B at 1/3, C at 2/3.
    enum float ub = -0.1666667f;
    assert(abs(uniform[1].x - ub) < 1e-4f && abs(uniform[1].y - ub) < 1e-4f
        && abs(uniform[1].z - ub) < 1e-4f, "uniform B mismatch");
    assert(abs(uniform[2].x - nc) < 1e-4f && abs(uniform[2].y - nc) < 1e-4f
        && abs(uniform[2].z - nc) < 1e-4f, "uniform C mismatch (matches nonuniform for undisplaced C)");
    assert(abs(uniform[0].x - (-0.5f)) < 1e-5f, "uniform endpoint A must not move");
    assert(abs(uniform[3].x - 0.5f) < 1e-5f, "uniform endpoint D must not move");
}

unittest { // Linear Align — weight blend, BIT-EXACT verified against
           // the "la_weight05" capture case (nonuniform + weight=0.5).
    Vec3[] source = [
        Vec3(-0.5f, -0.5f, -0.5f),
        Vec3( 0.2f, -0.15f, -0.1f),
        Vec3( 0.5f, -0.5f,  0.5f),
        Vec3( 0.5f,  0.5f,  0.5f),
    ];
    auto aligned = linearAlignTargets(source, false);
    Vec3 b05 = lerp3(source[1], aligned[1], 0.5f);
    Vec3 c05 = lerp3(source[2], aligned[2], 0.5f);
    assert(abs(b05.x - 0.0916667f) < 1e-4f && abs(b05.y - (-0.0833333f)) < 1e-4f
        && abs(b05.z - (-0.0583333f)) < 1e-4f, "weight=0.5 B mismatch");
    assert(abs(c05.x - 0.3333333f) < 1e-4f && abs(c05.y - (-0.1666667f)) < 1e-4f
        && abs(c05.z - 0.3333333f) < 1e-4f, "weight=0.5 C mismatch");
}

unittest { // Linear Align — degenerate 2-vertex chain is a no-op (both
           // verts are endpoints; t=0/1 exactly regardless of mode).
    Vec3[] source = [Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, 0.5f, 0.5f)];
    foreach (uniform; [false, true]) {
        auto r = linearAlignTargets(source, uniform);
        assert(abs(r[0].x - source[0].x) < 1e-6f && abs(r[0].y - source[0].y) < 1e-6f);
        assert(abs(r[1].x - source[1].x) < 1e-6f && abs(r[1].y - source[1].y) < 1e-6f);
    }
}

unittest { // Radial Align — center/radius auto-compute law, BIT-EXACT
           // verified against the "ra_circle" capture case (measured
           // center=(0.051777,-0.5,0.125), radius=0.688103). Closed
           // 4-vertex loop on the y=-0.5 cube
           // face (A=(-.5,-.5,-.5), B=(.5,-.5,-.5) pre-displaced within
           // the same plane by (0.2071,0,0.5), C=(.5,-.5,.5),
           // E=(-.5,-.5,.5)).
           //
           // The BASE ANCHOR (which point sits at angle 0) is NOT
           // verified against the reference — see radialAlignTargets's
           // doc comment — so beyond center/radius this only checks the
           // anchor-INDEPENDENT structural properties: equal slot
           // spacing and the additive-angle cyclic-permutation law (also
           // measured bit-exact in ra_circle_angle90.json).
    Vec3[] source = [
        Vec3(-0.5f,     -0.5f, -0.5f),
        Vec3( 0.7071f,  -0.5f,  0.0f),
        Vec3( 0.5f,     -0.5f,  0.5f),
        Vec3(-0.5f,     -0.5f,  0.5f),
    ];

    Vec3 center = Vec3(0, 0, 0);
    foreach (p; source) center = center + p;
    center = center * 0.25f;
    assert(abs(center.x - 0.051777f) < 2e-3f, "center.x mismatch");
    assert(abs(center.y - (-0.5f))   < 1e-6f, "center.y mismatch");
    assert(abs(center.z - 0.125f)    < 1e-6f, "center.z mismatch");

    auto result = radialAlignTargets(source, false, 4, 0.0f, 0.0f);
    assert(result.length == 4);
    foreach (p; result) {
        Vec3 d = p - center;
        float r = sqrt(dot(d, d));
        assert(abs(r - 0.688103f) < 2e-3f, "radius mismatch");
    }
    // Equal 90-degree slot spacing (measured: all 4 consecutive edge
    // lengths equal R*sqrt(2), a regular inscribed square).
    immutable float expectedEdge = 0.688103f * sqrt(2.0f);
    foreach (i; 0 .. 4) {
        Vec3 a = result[i], b = result[(i + 1) % 4];
        Vec3 d = b - a;
        float edgeLen = sqrt(dot(d, d));
        assert(abs(edgeLen - expectedEdge) < 2e-3f, "slot spacing mismatch");
    }

    // angle=90 (== 360/4, exactly one slot step) is a pure additive
    // rotation — measured bit-exact as a cyclic permutation of the
    // angle=0 result. Verified here against OUR OWN angle=0 result (the
    // absolute base-anchor value is unverified, but this additive
    // property is guaranteed by construction for any anchor choice).
    auto result90 = radialAlignTargets(source, false, 4, 90.0f, 0.0f);
    foreach (i; 0 .. 4) {
        Vec3 a = result90[i], b = result[(i + 1) % 4];
        assert(abs(a.x - b.x) < 1e-3f && abs(a.y - b.y) < 1e-3f && abs(a.z - b.z) < 1e-3f,
               "angle=90 should cyclically permute the angle=0 result");
    }
}

unittest { // Radial Align — N-Sided(4) uses the SAME center + radius as
           // Circle mode for an identical input (bit-exact match measured
           // in ra_nside4.json vs ra_circle.json) — anchor-independent
           // structural fact.
    Vec3[] source = [
        Vec3(-0.5f,     -0.5f, -0.5f),
        Vec3( 0.7071f,  -0.5f,  0.0f),
        Vec3( 0.5f,     -0.5f,  0.5f),
        Vec3(-0.5f,     -0.5f,  0.5f),
    ];
    auto circle = radialAlignTargets(source, false, 4, 0.0f, 0.0f);
    auto nside4 = radialAlignTargets(source, true, 4, 0.0f, 0.0f);
    assert(circle.length == nside4.length);
    // Same radius from the same (shared) center for every point.
    Vec3 center = Vec3(0, 0, 0);
    foreach (p; source) center = center + p;
    center = center * 0.25f;
    foreach (i; 0 .. circle.length) {
        float rc = sqrt(dot(circle[i] - center, circle[i] - center));
        float rn = sqrt(dot(nside4[i] - center, nside4[i] - center));
        assert(abs(rc - rn) < 1e-5f, "circle vs nside4 radius should match");
    }
}

unittest { // Radial Align — weight blend uses the same lerp law as
           // Linear Align (measured bit-exact in ra_circle_weight05.json
           // against ra_circle.json).
    Vec3 source = Vec3(0.7071f, -0.5f, 0.0f);
    Vec3 aligned = Vec3(1.0f, -0.5f, 1.0f);
    Vec3 h = lerp3(source, aligned, 0.5f);
    assert(abs(h.x - 0.85355f) < 1e-4f);
    assert(abs(h.y - (-0.5f))  < 1e-6f);
    assert(abs(h.z - 0.5f)     < 1e-6f);
}

unittest { // Radial Align — degenerate single-vertex "chain" is a no-op
           // (no circle can be defined from one point).
    Vec3[] source = [Vec3(1, 2, 3)];
    auto r = radialAlignTargets(source, false, 4, 0.0f, 0.0f);
    assert(r.length == 1);
    assert(abs(r[0].x - 1.0f) < 1e-6f && abs(r[0].y - 2.0f) < 1e-6f && abs(r[0].z - 3.0f) < 1e-6f);
}

unittest { // Radial Align — `side`/effSides DoS clamp: an absurd `sides`
           // value must not divide-by-zero or hang, and clamps to
           // MAX_ALIGN_SIDES rather than propagating unbounded.
    Vec3[] source = [
        Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(-1, 0, 0), Vec3(0, -1, 0),
    ];
    auto r1 = radialAlignTargets(source, true, 2_000_000_000, 0.0f, 0.0f);
    assert(r1.length == 4);
    foreach (p; r1) {
        assert(p.x == p.x && p.y == p.y && p.z == p.z, "NaN in clamped-sides result"); // NaN check
    }
    auto r2 = radialAlignTargets(source, true, -5, 0.0f, 0.0f);
    assert(r2.length == 4);
    foreach (p; r2) {
        assert(p.x == p.x && p.y == p.y && p.z == p.z, "NaN in negative-sides result");
    }
}
