// Topology Pen — Smooth mode relaxation KERNEL (task 0477 continuation,
// doc/tasks/work/0478-topopen-smooth-kernel.md).
//
// This module is the pure-math half of the Smooth gesture: it knows nothing
// about `Mesh`, tools, undo, or the background re-snap. It takes a
// double-precision position array plus a frozen `RelaxTopology` (CSR
// adjacency + a per-slot open-edge flag) and runs N relaxation iterations.
// The caller (`tools/edit/topology_pen/tool.d`, `applySmoothPasses`) owns the
// float↔double conversion, the background snap, and the undo record.
//
// WHY A SEPARATE MODULE, AND WHY DOUBLE: this law is pinned by a reference
// parity fixture whose expected positions are full-precision doubles, and
// the conformance test asserts against them at 1e-9. Running the kernel in
// `Vec3`'s float would floor the achievable error at ~1e-7 — a storage
// limit, not a kernel error, but one that would make the fixture useless as
// a regression gate. Keeping the kernel in `double` and rounding ONCE on the
// way back into `Mesh.vertices` puts every bit of the remaining error in the
// storage step, where it belongs.
//
// ---------------------------------------------------------------------------
// THE LAW (measured against the reference; see the conformance unittest in
// `tests/unit/tools/edit/topology_pen/gestures_test.d`,
// which reproduces 6 independently-captured cases). Per
// iteration, with `F = strength / 20`:
//
//   C(v)  = v's 1-ring, restricted to OPEN-edge neighbours when v is a
//           boundary vertex (a vertex with at least one open edge)
//   A(v)  = F * Σ_{i∈C(v)} (P_i − P_v)              [a SUM, not a mean]
//   D(v)  = Σ_{i∈C(v)} |P_v − P_i|
//   u_i   = (P_v − P_i) / |P_v − P_i|               [UNIT edge direction]
//   r_i   = |P_v − P_i| / D(v)                      [LONGER edges weigh MORE]
//   C_i   = r_i * ( A(v) − u_i * dot(A(v), u_i) )   [edge-PERPENDICULAR part]
//   force[v] += C_i ;  force[i] −= C_i              [equal and opposite]
//
// and, only after EVERY vertex has been accumulated, `P += force`.
//
// Three parts of that are load-bearing, each isolated by its own ablation
// against the fixture (numbers are the worst-case error the ablation costs,
// against a baseline of 2.3e-16):
//
//   * the reaction term `force[i] −= C_i`      — dropping it costs 2.7e-01
//   * the boundary restriction of C(v)         — dropping it costs 4.3e-02
//   * the edge-PERPENDICULAR projection        — this is what preserves edge
//     length; an unprojected step contracts the mesh, which is a different
//     trajectory with a different fixed point, not merely a different step
//     size (no pass count of the unprojected form reaches these targets).
//
// The `r_i` weights are proportional to edge LENGTH. A `1/len` does appear
// in the law, but ONLY as the normaliser that makes `u_i` a unit vector for
// the dot product — it is NOT the weighting. (An earlier, superseded reading
// of the same measurements had this backwards, as an inverse-edge-length
// weighted MEAN; `inverseEdgeLenRelax` in the pen's tool.d still implements
// that older law for the separate 1-D Smooth+Loop path, whose own weighting
// has not been re-measured. Do not conflate the two.)
// ---------------------------------------------------------------------------
module tools.edit.smooth_relax;

import std.math : sqrt, isFinite;

/// A double-precision position/force triple. Deliberately NOT `Vec3` — see
/// the module header on why this kernel runs in double.
struct RelaxVec3 {
    double x = 0, y = 0, z = 0;

    // Attributed to match `math.d`'s `Vec3`, which carries the same set on
    // every equivalent operator — this is what lets `relaxPasses` below be
    // `@safe pure nothrow` in turn.
    RelaxVec3 opBinary(string op)(const RelaxVec3 r) const @safe pure nothrow @nogc
        if (op == "+" || op == "-")
    {
        return mixin("RelaxVec3(x " ~ op ~ " r.x, y " ~ op ~ " r.y, z " ~ op ~ " r.z)");
    }
    RelaxVec3 opBinary(string op : "*")(double s) const @safe pure nothrow @nogc {
        return RelaxVec3(x * s, y * s, z * s);
    }
    double dot(const RelaxVec3 r) const @safe pure nothrow @nogc {
        return x * r.x + y * r.y + z * r.z;
    }
    double length() const @safe pure nothrow @nogc { return sqrt(x * x + y * y + z * z); }
}

/// Frozen topology for a relaxation run. Positions move during a run;
/// topology never does, so this is built ONCE per gesture and reused across
/// every iteration.
///
/// `offset`/`nbrs` are a standard CSR vertex→neighbour adjacency (the
/// neighbours of `v` are `nbrs[offset[v] .. offset[v+1]]`). `openTo` is
/// aligned SLOT-FOR-SLOT with `nbrs`: `openTo[k]` is true when the edge
/// joining `v` to `nbrs[k]` is OPEN (incident to fewer than two faces).
/// `boundary` is per-vertex and derived from `openTo` by `deriveBoundary`
/// below — never supplied by hand, so it can never drift out of sync.
struct RelaxTopology {
    const(size_t)[] offset;
    const(uint)[]   nbrs;
    const(bool)[]   openTo;
    const(bool)[]   boundary;

    size_t vertexCount() const @safe pure nothrow @nogc {
        return offset.length ? offset.length - 1 : 0;
    }

    /// True when this topology is internally consistent and safe to index
    /// against a position array of `nVerts`. Checked by `relaxPasses` — a
    /// malformed topology is a no-op, never an out-of-bounds read.
    ///
    /// The monotonicity check is what makes that promise true rather than
    /// merely likely: without it `offset = [0, 100, 5]` against a 5-element
    /// `nbrs` satisfies every other condition here (right lengths, right
    /// terminator, in-range neighbours) and then walks `offset[v] .. offset[v+1]`
    /// straight past the end — caught by the bounds check in a debug build,
    /// undefined behaviour under `-release`. No producer emits a
    /// non-monotone offset today; the point is that `valid()` states a
    /// safety contract, so it has to actually establish it.
    bool valid(size_t nVerts) const @safe pure nothrow @nogc {
        if (offset.length != nVerts + 1) return false;
        if (openTo.length != nbrs.length) return false;
        if (boundary.length != nVerts) return false;
        if (nVerts && offset[nVerts] != nbrs.length) return false;
        foreach (i; 0 .. nVerts) if (offset[i] > offset[i + 1]) return false;
        foreach (n; nbrs) if (n >= nVerts) return false;
        return true;
    }
}

/// Per-vertex boundary flag: true when the vertex has at least ONE open
/// (fewer-than-two-face) incident edge. Computed ONCE, before any iteration
/// — the flag is a property of topology, and topology does not move.
///
/// NOTE — a refinement the reference has and this does NOT, deliberately and
/// permanently: the reference additionally gates its boundary test on
/// `deg(v) > 2`, leaving a degree-2 boundary vertex UNrestricted.
///
/// That gate is unobservable, and not merely because the fixture happens not
/// to cover it. It is STRUCTURALLY UNREACHABLE. The gate can only change an
/// outcome for a degree-2 vertex whose two incident edges differ in openness
/// — one open, one shared by ≥2 faces — because when both are open the
/// restriction keeps the whole ring anyway, and when both are interior the
/// vertex is not flagged boundary at all. But such a vertex cannot be built:
/// every face incident to `v` contributes exactly two edges at `v`, so a
/// vertex of degree 2 whose first edge carries N faces necessarily has those
/// same N faces on its second edge. Openness is therefore always EQUAL
/// across a degree-2 vertex's two edges, and the discriminating case does
/// not exist. Confirmed two ways: the conformance fixture (which does
/// contain four degree-2 vertices) yields a bit-identical 2.2888e-16 with
/// and without the gate, and a search over 200k random face soups —
/// including non-manifold ones — produced zero instances.
///
/// Recorded here so this is not reopened as an oversight: for the RING the
/// gate cannot fire. It does matter for the smooth tool's boundary scale `c`
/// (task 9484): only a gated vertex gets c != 1, so that caller applies
/// `deg(v) > 2` itself when it builds `cScale`.
bool[] deriveBoundary(const(size_t)[] offset, const(bool)[] openTo) @safe pure nothrow {
    if (offset.length == 0) return null;
    auto b = new bool[](offset.length - 1);
    foreach (v; 0 .. b.length) {
        foreach (k; offset[v] .. offset[v + 1])
            if (k < openTo.length && openTo[k]) { b[v] = true; break; }
    }
    return b;
}

/// Run `iters` relaxation iterations over `pos` in place. `F` is the already
/// -divided force factor (`strength / 20`), NOT the raw strength.
///
/// A non-finite `F` (NaN/Inf — reachable through a headless attr injection,
/// which `.enforceBounds()` does NOT clamp) is rejected outright: the
/// positions are left untouched rather than poisoned into NaN. `iters <= 0`,
/// an empty mesh, or an inconsistent topology are likewise no-ops. The
/// caller is responsible for capping `iters` to a sane ceiling BEFORE
/// calling — this kernel is O(iters · E) and will honour whatever it is
/// given.
void relaxPasses(RelaxVec3[] pos, const ref RelaxTopology topo, double F, int iters)
    @safe pure nothrow
{
    if (iters <= 0 || !relaxable(pos, topo, F)) return;
    auto work = RelaxScratch(pos.length, topo.nbrs.length);
    foreach (_; 0 .. iters) relaxStep(pos, topo, F, null, null, work);
}

/// True when `relaxStep` may run on this input (finite `F`, a non-empty
/// position array, a topology consistent with it).
bool relaxable(const(RelaxVec3)[] pos, const ref RelaxTopology topo, double F)
    @safe pure nothrow @nogc
{
    return pos.length != 0 && isFinite(F) && topo.valid(pos.length);
}

/// Per-run buffers of `relaxStep`, allocated once per run.
struct RelaxScratch {
    RelaxVec3[] force;
    // Edge length per CSR SLOT, carried from the A/D loop to the force loop:
    // one `sqrt` per slot instead of two (bit-exact; the squares are equal).
    double[]    slotLen;
    this(size_t nVerts, size_t nSlots) @safe pure nothrow {
        force = new RelaxVec3[](nVerts);
        slotLen = new double[](nSlots);
    }
}

/// ONE relaxation iteration (the law in the module header). `active` (null =
/// every vertex) selects the vertices that receive a force and move; an
/// inactive vertex is a FIXED neighbour and its reactions are dropped (task
/// 9484, the selection law). `cScale` (null = 1 everywhere) is the smooth
/// tool's boundary scale `c`: `u_i = (P_v − P_i) · c / |P_v − P_i|`. The pen's
/// relax passes neither. Precondition: `relaxable(pos, topo, F)`.
void relaxStep(RelaxVec3[] pos, const ref RelaxTopology topo, double F,
               const(bool)[] active, const(double)[] cScale, ref RelaxScratch work)
    @safe pure nothrow
{
    immutable size_t nV = pos.length;
    auto force = work.force;
    auto slotLen = work.slotLen;
    force[] = RelaxVec3(0, 0, 0);

    foreach (v; 0 .. nV) {
        if (active !is null && !active[v]) continue;
        immutable size_t lo = topo.offset[v], hi = topo.offset[v + 1];
        immutable bool   bnd = topo.boundary[v];

        // A(v) and D(v) over the (possibly boundary-restricted) 1-ring.
        // The second loop below re-applies the SAME `bnd && !openTo[k]`
        // restriction rather than materialising a neighbour list per
        // vertex per iteration — this is the hot loop of the gesture.
        RelaxVec3 A;
        double    D = 0;
        foreach (k; lo .. hi) {
            if (bnd && !topo.openTo[k]) continue;
            auto dv = pos[topo.nbrs[k]] - pos[v];
            A = A + dv;
            immutable double len = dv.length();
            slotLen[k] = len;
            D += len;
        }
        if (D == 0) continue;   // no usable neighbours, or all coincident
        A = A * F;
        immutable double c = cScale is null ? 1.0 : cScale[v];

        foreach (k; lo .. hi) {
            if (bnd && !topo.openTo[k]) continue;
            immutable uint   w = topo.nbrs[k];
            immutable double d = slotLen[k];
            if (d == 0) continue;
            auto u  = (pos[v] - pos[w]) * (c / d);
            auto Ci = (A - u * A.dot(u)) * (d / D);
            force[v] = force[v] + Ci;
            force[w] = force[w] - Ci;   // the reaction term — NOT optional
        }
    }

    foreach (v; 0 .. nV)
        if (active is null || active[v]) pos[v] = pos[v] + force[v];
}

// ---------------------------------------------------------------------------
// Kernel unittests. The AUTHORITATIVE gate is the 6-case reference parity
// conformance test in the pen's unittest module (it drives this kernel
// through the real
// `Mesh`→`RelaxTopology` extraction); these cover the structural properties
// that test would only catch as a number, and the guard paths it never
// reaches.
// ---------------------------------------------------------------------------
