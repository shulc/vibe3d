// Module unittests for `tools.edit.smooth_relax`, moved verbatim out of source/tools/edit/smooth_relax.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.tools.edit.smooth_relax_test;

import std.math : sqrt, isFinite;
import tools.edit.smooth_relax;

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

    // A NON-MONOTONE offset passes every length / terminator / range check
    // and would then walk `nbrs` past its end. `valid()` states a safety
    // contract, so it must reject this rather than rely on no producer ever
    // emitting it (bounds-checked in debug, undefined behaviour under
    // `-release`).
    size_t[] skew = [0, 100, 4, 6];
    assert(skew.length == base.length + 1 && skew[base.length] == nbrs.length,
        "setup: the skewed offset must satisfy the length and terminator checks, so that "
      ~ "monotonicity is the ONLY thing left to reject it");
    RelaxTopology nonMono = { skew, nbrs, openTo, deriveBoundary(off, openTo) };
    assert(!nonMono.valid(base.length), "a non-monotone offset must fail validation");
    relaxPasses(p, nonMono, 0.05, 3);
    assert(p == base, "a non-monotone offset must be a no-op, never an out-of-bounds read");
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
