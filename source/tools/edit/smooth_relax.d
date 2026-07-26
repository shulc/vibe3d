// Topology Pen — Smooth mode relaxation KERNEL (task 0477 continuation,
// doc/tasks/work/0478-topopen-smooth-kernel.md).
//
// This module is the pure-math half of the Smooth gesture: it knows nothing
// about `Mesh`, tools, undo, or the background re-snap. It takes a
// double-precision position array plus a frozen `RelaxTopology` (CSR
// adjacency + a per-slot open-edge flag) and runs N relaxation iterations.
// The caller (`tools/edit/topology_pen.d`, `applySmoothPasses`) owns the
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
// topology_pen.d, which reproduces 6 independently-captured cases). Per
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
// weighted MEAN; `inverseEdgeLenRelax` in topology_pen.d still implements
// that older law for the separate 1-D Smooth+Loop path, whose own weighting
// has not been re-measured. Do not conflate the two.)
// ---------------------------------------------------------------------------
module tools.edit.smooth_relax;

import std.math : sqrt, isFinite;

/// A double-precision position/force triple. Deliberately NOT `Vec3` — see
/// the module header on why this kernel runs in double.
struct RelaxVec3 {
    double x = 0, y = 0, z = 0;

    RelaxVec3 opBinary(string op)(const RelaxVec3 r) const
        if (op == "+" || op == "-")
    {
        return mixin("RelaxVec3(x " ~ op ~ " r.x, y " ~ op ~ " r.y, z " ~ op ~ " r.z)");
    }
    RelaxVec3 opBinary(string op : "*")(double s) const {
        return RelaxVec3(x * s, y * s, z * s);
    }
    double dot(const RelaxVec3 r) const { return x * r.x + y * r.y + z * r.z; }
    double length() const { return sqrt(x * x + y * y + z * z); }
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

    size_t vertexCount() const { return offset.length ? offset.length - 1 : 0; }

    /// True when this topology is internally consistent and safe to index
    /// against a position array of `nVerts`. Checked by `relaxPasses` — a
    /// malformed topology is a no-op, never an out-of-bounds read.
    bool valid(size_t nVerts) const {
        if (offset.length != nVerts + 1) return false;
        if (openTo.length != nbrs.length) return false;
        if (boundary.length != nVerts) return false;
        if (nVerts && offset[nVerts] != nbrs.length) return false;
        foreach (n; nbrs) if (n >= nVerts) return false;
        return true;
    }
}

/// Per-vertex boundary flag: true when the vertex has at least ONE open
/// (fewer-than-two-face) incident edge. Computed ONCE, before any iteration
/// — the flag is a property of topology, and topology does not move.
///
/// NOTE — an UNIMPLEMENTED, deliberately-open refinement: the reference
/// additionally gates this test on `deg(v) > 2`, so a degree-2 boundary
/// vertex would be left UNrestricted there. That gate is a static-only
/// observation: the conformance fixture contains four degree-2 vertices, and
/// running it with and without the gate produces the IDENTICAL worst-case
/// error (2.2888e-16 either way), so the fixture does not discriminate the
/// two rules and there is nothing here to justify the extra gate from. Left
/// out on purpose rather than guessed at; a rig where a degree-2 vertex has
/// one open and one interior edge would settle it.
bool[] deriveBoundary(const(size_t)[] offset, const(bool)[] openTo) {
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
void relaxPasses(RelaxVec3[] pos, const ref RelaxTopology topo, double F, int iters) {
    if (iters <= 0 || pos.length == 0) return;
    if (!isFinite(F)) return;
    if (!topo.valid(pos.length)) return;

    immutable size_t nV = pos.length;
    auto force = new RelaxVec3[](nV);

    foreach (_; 0 .. iters) {
        force[] = RelaxVec3(0, 0, 0);

        foreach (v; 0 .. nV) {
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
                D += dv.length();
            }
            if (D == 0) continue;   // no usable neighbours, or all coincident
            A = A * F;

            foreach (k; lo .. hi) {
                if (bnd && !topo.openTo[k]) continue;
                immutable uint w = topo.nbrs[k];
                auto e = pos[v] - pos[w];
                immutable double d = e.length();
                if (d == 0) continue;
                auto u  = e * (1.0 / d);
                auto Ci = (A - u * A.dot(u)) * (d / D);
                force[v] = force[v] + Ci;
                force[w] = force[w] - Ci;   // the reaction term — NOT optional
            }
        }

        foreach (v; 0 .. nV) pos[v] = pos[v] + force[v];
    }
}

// ---------------------------------------------------------------------------
// Kernel unittests. The AUTHORITATIVE gate is the 6-case reference parity
// conformance test in topology_pen.d (it drives this kernel through the real
// `Mesh`→`RelaxTopology` extraction); these cover the structural properties
// that test would only catch as a number, and the guard paths it never
// reaches.
// ---------------------------------------------------------------------------

unittest {   // Newton's third law: the per-iteration force field SUMS TO ZERO.
             // Every contribution is written twice with opposite signs, so
             // the centroid of a free (all-vertices-moving) relaxation is
             // invariant. This is the structural fingerprint of the reaction
             // term — a regression that dropped it would drift the centroid
             // and fail here without needing any reference number.
    import std.math : abs;

    // Irregular closed-ish patch: two triangles sharing an edge, deliberately
    // asymmetric so a centroid drift cannot cancel by symmetry.
    RelaxVec3[] pos = [
        RelaxVec3(0, 0, 0), RelaxVec3(1.7, 0.1, -0.3),
        RelaxVec3(0.2, 2.3, 0.4), RelaxVec3(-1.1, 0.9, 1.6),
    ];
    size_t[] off  = [0, 3, 5, 8, 10];
    uint[]   nbrs = [1, 2, 3,  0, 2,  0, 1, 3,  0, 2];
    auto openTo   = new bool[](nbrs.length);   // no boundary restriction at all
    RelaxTopology topo = { off, nbrs, openTo, deriveBoundary(off, openTo) };

    auto start = pos.dup;
    RelaxVec3 c0;
    foreach (p; pos) c0 = c0 + p;

    relaxPasses(pos, topo, 1.0 / 20.0, 7);

    RelaxVec3 c1;
    foreach (p; pos) c1 = c1 + p;
    assert(abs(c1.x - c0.x) < 1e-12 && abs(c1.y - c0.y) < 1e-12 && abs(c1.z - c0.z) < 1e-12,
        "the reaction term makes the force field sum to zero — the centroid must be invariant");

    bool moved = false;
    foreach (i; 0 .. pos.length) if ((pos[i] - start[i]).length() > 1e-6) { moved = true; break; }
    assert(moved, "setup: the rig must actually relax, or the invariance above is vacuous");
}

unittest {   // The step is edge-PERPENDICULAR: on a single edge (each endpoint
             // seeing only the other), A(v) is parallel to the edge, so the
             // projection cancels it EXACTLY and nothing moves. An
             // unprojected kernel would collapse the two vertices together.
    RelaxVec3[] pos = [RelaxVec3(-1, 0, 0), RelaxVec3(1, 0, 0)];
    size_t[] off  = [0, 1, 2];
    uint[]   nbrs = [1, 0];
    auto openTo   = new bool[](2);
    RelaxTopology topo = { off, nbrs, openTo, deriveBoundary(off, openTo) };

    relaxPasses(pos, topo, 1.0 / 20.0, 40);

    assert((pos[0] - RelaxVec3(-1, 0, 0)).length() < 1e-14
        && (pos[1] - RelaxVec3( 1, 0, 0)).length() < 1e-14,
        "a lone edge is entirely along-edge — the perpendicular projection must "
      ~ "cancel it exactly, leaving both endpoints fixed for any pass count");
}

unittest {   // Guard paths: non-finite F, non-positive iters, and a malformed
             // topology are all no-ops rather than NaN poisoning or an
             // out-of-bounds read.
    import std.math : isNaN;

    RelaxVec3[] base = [RelaxVec3(0, 0, 0), RelaxVec3(1, 1, 0), RelaxVec3(2, 0, 0)];
    size_t[] off  = [0, 2, 4, 6];
    uint[]   nbrs = [1, 2,  0, 2,  0, 1];
    auto openTo   = new bool[](nbrs.length);
    RelaxTopology topo = { off, nbrs, openTo, deriveBoundary(off, openTo) };

    auto p = base.dup;
    relaxPasses(p, topo, double.nan, 3);
    assert(p == base, "a NaN force factor must leave positions untouched, never poison them");
    relaxPasses(p, topo, double.infinity, 3);
    assert(p == base, "an infinite force factor must leave positions untouched");
    relaxPasses(p, topo, 0.05, 0);
    assert(p == base, "zero iterations must be a no-op");

    RelaxTopology bad = { off, nbrs, openTo[0 .. $ - 1], deriveBoundary(off, openTo) };
    assert(!bad.valid(base.length), "a short openTo must fail validation");
    relaxPasses(p, bad, 0.05, 3);
    assert(p == base, "a malformed topology must be a no-op, never an out-of-bounds read");
}

unittest {   // `strength` scales the step LINEARLY at first order: halving it
             // halves the single-iteration displacement. Locks in the meaning
             // of the parameter independently of the reference numbers.
    import std.math : abs;

    RelaxVec3[] start = [
        RelaxVec3(0, 0, 0), RelaxVec3(1.3, 0.2, 0), RelaxVec3(0.1, 1.9, 0.5), RelaxVec3(-1.4, 0.7, -0.6),
    ];
    size_t[] off  = [0, 3, 5, 8, 10];
    uint[]   nbrs = [1, 2, 3,  0, 2,  0, 1, 3,  0, 2];
    auto openTo   = new bool[](nbrs.length);
    RelaxTopology topo = { off, nbrs, openTo, deriveBoundary(off, openTo) };

    auto full = start.dup;  relaxPasses(full, topo, 1.0 / 20.0, 1);
    auto half = start.dup;  relaxPasses(half, topo, 0.5 / 20.0, 1);

    foreach (i; 0 .. start.length) {
        auto dFull = full[i] - start[i];
        auto dHalf = half[i] - start[i];
        assert((dHalf * 2.0 - dFull).length() < 1e-14,
            "one iteration is linear in strength — half the strength must be half the step");
    }
    assert((full[0] - start[0]).length() > 1e-6, "setup: the rig must actually move");
}
