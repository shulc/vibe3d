module tools.alignment.align_kernels;

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
//   unrotated result). The ring's phase (which vertex starts it, and the
//   Circle-mode turn search) is read law — see
//   radialAlignTargets.
//
//   Both tools: `weight` blends `lerp(source, aligned, weight)` — the
//   SAME per-component linear blend the rest of the deform-tool family
//   uses (Move / Bend / Push; see agent memory vibe3d_scale_blend_gap).
//   Per-vertex falloff modulation (WGHT stage) multiplies into this same
//   `weight` at the call site — this module has no falloff dependency.

import mesh     : Mesh, edgeKey;
import editmode : EditMode;
import math     : Vec3, dot, cross;
import std.math : sqrt, cos, sin, atan, PI, abs;
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
    bool[] vmask;   // assigned from the L1 funnel below

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
    // L1 funnel (task 0613, S5): the modal vertex fan-in — and its whole-mesh
    // fallback, now narrowed to the VISIBLE vertices — lives in
    // Mesh.operandVertexMask. This is shape D's fifth definition and the ONE
    // that is not byte-identical to its siblings: Polygons mode additionally
    // needs `boundaryEdge`, which is derived from the same face selection but
    // is not part of the vertex operand set. So the vmask build moves to the
    // funnel and the boundary-edge classification stays here, keyed off the
    // face selection exactly as before.
    vmask = mesh.operandVertexMask(editMode);
    if (editMode == EditMode.Polygons) {
        int[ulong] selCount;
        foreach (fi; 0 .. mesh.faces.length) {
            if (!mesh.isFaceSelected(fi)) continue;
            auto ring = mesh.faces[fi];
            immutable size_t n = ring.length;
            foreach (k; 0 .. n) {
                ulong key = edgeKey(ring[k], ring[(k + 1) % n]);
                if (auto c = key in selCount) ++(*c);
                else selCount[key] = 1;
            }
        }
        boundaryEdge.length = mesh.edges.length;
        foreach (ei; 0 .. mesh.edges.length) {
            ulong key = edgeKey(mesh.edges[ei][0], mesh.edges[ei][1]);
            if (auto c = key in selCount)
                boundaryEdge[ei] = (*c == 1);
        }
    }

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
private enum double radialPi = cast(double)PI;

// Task 20261040: N-sided phase and corners use the C binary64 evaluation
// policy; retain residuals and cross the Vec3 boundary only after chords.
private double radialSin(double angle) pure nothrow @safe @nogc {
    import core.stdc.math : cSin = sin;
    return cSin(angle);
}
private double radialCos(double angle) pure nothrow @safe @nogc {
    import core.stdc.math : cCos = cos;
    return cCos(angle);
}

/// Edge-neighbours of every chain vertex that lie OUTSIDE the operand set
/// (`Mesh.operandVertexMask`), as positions indexed like `chain`. These are
/// the only points Radial Align's circle-phase search measures against:
/// a closed selection with no outside neighbour has an empty
/// list everywhere, and the search keeps the start vertex at its own angle.
Vec3[][] alignOutsideNeighbours(Mesh* mesh, EditMode editMode, const(uint)[] chain) {
    const bool[] inside = mesh.operandVertexMask(editMode);
    int[uint] slotOf;
    foreach (k, vi; chain) slotOf[vi] = cast(int)k;
    auto result = new Vec3[][](chain.length);
    foreach (e; mesh.edges) {
        foreach (s; 0 .. 2) {
            const uint a = e[s], b = e[1 - s];
            if (inside[b]) continue;
            if (auto k = a in slotOf) result[*k] ~= mesh.vertices[b];
        }
    }
    return result;
}

/// Shared radial target authority. Circle retains the captured start/search
/// schedule (task 9490); N-sided uses integer knot ownership and double chords
/// (task 20261040, frozen radial_nsided_original fixture). Initialization rotates
/// source order before integer Rotate; only final targets cross the Vec3 seam.
Vec3[] radialAlignTargets(const(Vec3)[] source, bool nsideMode, int sides,
                          float angleDeg, int rotate,
                          const(Vec3[])[] outside = null) pure nothrow @safe {
    immutable size_t n = source.length;
    Vec3[] result = new Vec3[](n);
    if (n == 0) return result;
    if (n == 1) { result[0] = source[0]; return result; }

    auto p = new D3[](n);
    foreach (i, s; source) p[i] = D3(s.x, s.y, s.z);
    D3 center = D3(0, 0, 0);
    foreach (q; p) center = center + q;
    center = center * (1.0 / n);
    double radius = 0;
    foreach (q; p) radius += (q - center).len;
    radius /= n;
    if (radius < 1e-9) { result[] = source[]; return result; }

    const D3 normal = ringNormal(p, center);
    const size_t start = radialAlignStart(p, center, normal);
    if (nsideMode) {
        import workplane_fit : PlaneFrame, planeFrame;
        int cappedSides = sides;
        if (cappedSides < 1) cappedSides = 1;
        else if (cappedSides > MAX_ALIGN_SIDES) cappedSides = MAX_ALIGN_SIDES;
        const size_t count = n < cappedSides ? n : cappedSides;
        const long m = cast(long)n;
        const size_t a = cast(size_t)((cast(long)rotate % m + m) % m);
        auto ordered = new D3[](n);
        foreach (k; 0 .. n) ordered[k] = p[(start + k) % n];
        PlaneFrame frame;
        if (!planeFrame([normal.x, normal.y, normal.z], frame))
            frame.M = [[-1.0, 0, 0], [0.0, 1, 0], [0.0, 0, -1]];
        const D3 delta = ordered[a] - center;
        const D3 direction = delta * (1.0 / delta.len);
        const uv = frame.toPlane([direction.x, direction.y, direction.z]);
        const double nominalStep = (2.0 * radialPi) / cast(double)n;
        const double nominalArgument = nominalStep * cast(double)a;
        const double nominal = xyAngle(radialCos(nominalArgument), radialSin(nominalArgument));
        const double correction = xyAngle(uv[0], uv[1]) - nominal;
        const double angleRadians = cast(double)angleDeg * (radialPi / 180.0);
        const double alpha = angleRadians + correction;
        const size_t q = n / count, remainder = n - q * count;
        auto corners = new D3[](count);
        auto knots = new size_t[](count);
        foreach (j; 0 .. count) {
            knots[j] = (a + j * q + (j < remainder ? j : remainder)) % n;
            const double cornerStep = (2.0 * radialPi) / cast(double)count;
            const double cornerOffset = cast(double)j * cornerStep;
            const double phi = alpha + cornerOffset;
            const world = frame.fromPlane(radius * radialCos(phi), radius * radialSin(phi), 0);
            corners[j] = center + D3(world[0], world[1], world[2]);
        }
        auto targets = new D3[](n);
        foreach (j; 0 .. count) {
            targets[knots[j]] = corners[j];
            const size_t gap = q + (j < remainder ? 1 : 0);
            foreach (t; 1 .. gap)
                targets[(knots[j] + t) % n] = corners[j] +
                    (corners[(j + 1) % count] - corners[j]) * (cast(double)t / gap);
        }
        // Static orientation pass; captured positive cells constrain its output,
        // without asserting runtime reachability of negative odd winding.
        if ((targets[0] - center).cross(targets[1] - center).dot(normal) < 0) {
            foreach (i; 1 .. n / 2) {
                const D3 saved = targets[i];
                targets[i] = targets[n - i];
                targets[n - i] = saved;
            }
        }
        foreach (k, target; targets)
            result[(start + k) % n] = Vec3(cast(float)target.x,
                cast(float)target.y, cast(float)target.z);
        return result;
    }
    D3 u = p[start] - center;
    u = u - normal * u.dot(normal);
    if (u.len < 1e-9) {
        // the start vertex sits on the center: any in-plane axis will do
        const D3 arb = abs(normal.x) < 0.9 ? D3(1, 0, 0) : D3(0, 1, 0);
        u = arb - normal * arb.dot(normal);
    }
    u = u * (1.0 / u.len);
    const D3 v = normal.cross(u);

    int effSides = cast(int)n;
    if (effSides < 1) effSides = 1;
    else if (effSides > MAX_ALIGN_SIDES) effSides = MAX_ALIGN_SIDES;
    immutable double step = 2.0 * PI / effSides;
    D3 slotAt(size_t k, double turn) {
        const double a = k * step + turn;
        return center + u * (radius * cos(a)) + v * (radius * sin(a));
    }

    double turn = 0;
    if (!nsideMode && outside.length == n) {
        double totalDistance(double t) {
            double acc = 0;
            foreach (k; 0 .. n)
                foreach (q; outside[(start + k) % n]) {
                    const D3 d = slotAt(k, t) - D3(q.x, q.y, q.z);
                    acc += d.dot(d);
                }
            return sqrt(acc);
        }
        turn = radialAlignSearch(&totalDistance, n, radius);
    }
    turn += angleDeg * (PI / 180.0);
    foreach (k; 0 .. n) {
        const D3 r = slotAt(k, turn);
        result[(start + k) % n] = Vec3(cast(float)r.x, cast(float)r.y, cast(float)r.z);
    }
    return result;
}

/// The ring normal: the least-squares plane fit `n . p = 1` in double
/// (`workplane_fit.planeFitNormal`), or — when that system is singular —
/// the bounding box's thinnest world axis; turned so the first two chain
/// points wind positively about it. Read law (K-RAF): the start frame's
/// sensitivity to a normal off a world axis comes from THIS normal.
private D3 ringNormal(const(D3)[] p, D3 center) pure nothrow @safe {
    import workplane_fit : planeFitNormal, SkewFit;
    auto pts = new double[3][](p.length);
    foreach (i, q; p) pts[i] = [q.x, q.y, q.z];
    double[3] f;
    D3 n;
    if (planeFitNormal(pts, f) == SkewFit.ok) n = D3(f[0], f[1], f[2]);
    else {
        D3 lo = p[0], hi = p[0];
        foreach (q; p) {
            lo = D3(q.x < lo.x ? q.x : lo.x, q.y < lo.y ? q.y : lo.y, q.z < lo.z ? q.z : lo.z);
            hi = D3(q.x > hi.x ? q.x : hi.x, q.y > hi.y ? q.y : hi.y, q.z > hi.z ? q.z : hi.z);
        }
        const D3 ext = hi - lo;
        n = (ext.x < ext.y && ext.x < ext.z) ? D3(1, 0, 0)
          : (ext.y < ext.z) ? D3(0, 1, 0) : D3(0, 0, 1);
    }
    return (p[0] - center).cross(p[1] - center).dot(n) < 0 ? n * -1.0 : n;
}

/// The chain vertex the slot ring starts at: the one whose direction from
/// `center`, read in `workplane_fit.planeFrame` of `normal`, has the
/// smallest `|angle| mod 90°`; the first such vertex wins a tie. A normal
/// exactly opposite its dominant axis turns half a revolution about world Y
/// instead (as read — for a −Y normal that leaves the frame upside down;
/// the reference may reach the other frame through fit noise, task card).
private size_t radialAlignStart(const(D3)[] p, D3 center, D3 normal) pure nothrow @safe {
    import workplane_fit : PlaneFrame, planeFrame;
    PlaneFrame f;
    if (!planeFrame([normal.x, normal.y, normal.z], f))
        f.M = [[-1.0, 0, 0], [0.0, 1, 0], [0.0, 0, -1]];
    size_t best = 0;
    double bestKey = double.infinity;
    foreach (i, q; p) {
        const D3 d = q - center;
        const double normSquared = (d.y * d.y + d.z * d.z) + d.x * d.x;
        const double length = sqrt(normSquared);
        const D3 direction = length > 0 ? d * (1.0 / length) : d;
        const uv = f.toPlane([direction.x, direction.y, direction.z]);
        const double a = abs(xyAngle(uv[0], uv[1]));
        const double quarter = radialPi / 2.0;
        const double quotient = a / quarter;
        const int whole = cast(int)quotient;
        const double multiple = cast(double)whole * quarter;
        const double key = a - multiple;
        if (key < bestKey) { bestKey = key; best = i; }
    }
    return best;
}

/// The ring turn (radians) Circle mode applies after laying the slots:
/// a bounded step search on `totalDistance` from 0 — probe
/// one degree (half a slot when a slot is narrower), the other side when
/// the first probe does not improve, then step on while improving and
/// back while not, halving the step at each change of verdict; stop when
/// two successive distances differ by at most `radius / 3_360_000`
/// (floor 1e-10) or after 100 steps. The schedule, not just the minimum,
/// is the law: the search stops short of the exact minimum.
private double radialAlignSearch(scope double delegate(double) pure nothrow @safe totalDistance,
                         size_t n, double radius) pure nothrow @safe {
    enum int MAX_STEPS = 100;
    const double tol = radius / 3_360_000.0 > 1e-10 ? radius / 3_360_000.0 : 1e-10;
    const double slot = 2.0 * PI / n;
    double probe = PI / 180.0;
    if (probe > slot) probe = slot * 0.5;
    double walk(double t, double d, double fp, double fc) {
        if (abs(fp - fc) <= tol) return t;
        foreach (_; 0 .. MAX_STEPS) {
            const bool better = fc < fp;
            t += better ? d : -d;
            const double fn = totalDistance(t);
            if (better != (fn < fc)) d *= 0.5;
            fp = fc;
            fc = fn;
            if (abs(fp - fc) <= tol) break;
        }
        return t;
    }
    const double f0 = totalDistance(0);
    const double fUp = totalDistance(probe);
    if (f0 > fUp) return walk(probe, probe, f0, fUp);
    const double fDown = totalDistance(-probe);
    return f0 > fDown ? walk(-probe, -probe, f0, fDown) : 0.0;
}

/// Plane-frame angle of (x, y) in (−π, π]; on x == 0 it answers ±π/2 by
/// the sign of y (−π/2 at the origin), as the read law does.
private double xyAngle(double x, double y) pure nothrow @safe @nogc {
    const double quarter = radialPi / 2.0;
    if (x == 0) return y > 0 ? quarter : -quarter;
    const double quotient = y / x;
    const double a = atan(quotient);
    if (x > 0) return a;
    return y < 0 ? a - radialPi : a + radialPi;
}

/// Double-precision point for the radial kernel (the read law runs in
/// double; float slots drift the search's stopping point).
private struct D3 {
    double x = 0, y = 0, z = 0;
    D3 opBinary(string op : "+")(D3 o) const pure nothrow @safe @nogc
    { return D3(x + o.x, y + o.y, z + o.z); }
    D3 opBinary(string op : "-")(D3 o) const pure nothrow @safe @nogc
    { return D3(x - o.x, y - o.y, z - o.z); }
    D3 opBinary(string op : "*")(double s) const pure nothrow @safe @nogc
    { return D3(x * s, y * s, z * s); }
    double dot(D3 o) const pure nothrow @safe @nogc { return x * o.x + y * o.y + z * o.z; }
    D3 cross(D3 o) const pure nothrow @safe @nogc
    { return D3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x); }
    double len() const pure nothrow @safe @nogc { return sqrt(dot(this)); }
}


// ---------------------------------------------------------------------
// Unit tests — bit-exact / structural laws locked against the private
// capture (task 0361, cases "la_nonuniform" / "la_uniform" / "la_weight05"
// / "ra_circle" / "ra_circle_angle90" / "ra_nside4" / "ra_circle_weight05").
// No reference engine runs at test time — every expected number below was
// hand-verified against the captured data once and is reproduced as a
// literal.
// ---------------------------------------------------------------------

unittest { // Task 20261040: private radialAlignStart, original first equal-key owner.
    import std.file : readText;
    import std.json : parseJSON, JSONType;
    import std.format : format;
    auto fixture = parseJSON(readText("tests/fixtures/radial_nsided_original.json"));
    assert(fixture["model"]["vertices"].array.length == 90 &&
        fixture["orderedIds"].array.length == 18, "full original population");
    D3[] p;
    foreach (k, id; fixture["orderedIds"].array) {
        assert(id.integer == 72 + k, "original ordered mapping");
        auto v = fixture["model"]["vertices"][cast(size_t)id.integer];
        double value(size_t i) { return cast(float)(v[i].type == JSONType.integer ? cast(double)v[i].integer : v[i].floating); }
        p ~= D3(value(0), value(1), value(2));
    }
    D3 center;
    foreach (q; p) center = center + q;
    center = center * (1.0 / p.length);
    const normal = ringNormal(p, center);
    const start = radialAlignStart(p, center, normal);
    double radius = 0;
    foreach (q; p) radius += (q-center).len;
    radius /= p.length;
    assert(start == 0, format("original-start expected=0 actual=%s", start));

    // Captured small-N fallback initializer, independently of target geometry.
    D3[] anti = [D3(-.5,-.5,-.5), D3(.7071067690849304,-.5,0),
        D3(.5,-.5,.5), D3(-.5,-.5,.5)];
    D3 antiCenter;
    foreach(q;anti) antiCenter=antiCenter+q;
    antiCenter=antiCenter*(1.0/anti.length);
    const antiNormal=ringNormal(anti,antiCenter);
    assert(anti.length==4 && antiNormal.x==0 && antiNormal.y==-1 && antiNormal.z==0,
        "small-N negative-Y fallback population");
    const fallbackStart=radialAlignStart(anti,antiCenter,antiNormal);
    assert(fallbackStart==3,format("fallback-start expected=3 actual=%s",fallbackStart));
}
