// Topology Pen Add Loop — reference conformance over the frozen 8-case golden
// (tests/fixtures/topopen_addloop.json, schema topology_pen.addloop.conformance/1).
// FIVE of the eight cases are OPEN SPANS (the ring terminates at a mesh
// boundary): dV=N+1 / dE=2N+1 / dF=N for N crossed quads; the other three are
// closed rings (N, 2N, N). Each case asserts four independent things:
//   1. the exact SET of crossed input edges — `expected.not_crossed_edges`
//      lists every OTHER input edge and each must receive nothing, and
//      crossed + not-crossed must account for every input edge, so a wrong
//      ring (too long, too short, the perpendicular loop) cannot pass;
//   2. the exact POSITION of every inserted vertex (the reference's own
//      post-gesture dump, to full float precision);
//   3. the DIRECTED fraction of each inserted vertex along its host edge,
//      measured from that edge's lower-index endpoint — this is what
//      discriminates the side-B mirror on a two-sided open span (see below);
//   4. ONE uniform scalar for the whole ring: the spread of the
//      orientation-folded fraction must stay inside the reference's own
//      declared `law_selfcheck.max_deviation_from_uniform_scalar`.
//
// ORIENTATION (the trap): `insertEdgeLoops` measures its ratio in the seed
// edge's own side-A dart, while the fixture states the scalar as a fraction
// from the seed edge's LOWER-index endpoint. Those two agree or disagree as a
// whole — one bit per case, read from that dart BEFORE the cut
// (`flip = faces[f0][j] != min(seed)`, f0 = the seed's first incident face) —
// and the bit is never fitted per row. Every crossed edge OTHER than the seed
// is therefore a genuine prediction: its expected position comes straight
// from the reference dump, with no per-row orientation freedom at all.
//
// WHY THE MIRROR IS PINNED HERE: `gridwarp_edge_third_click_0233` seeds on an
// INTERIOR edge whose ring is still open, so the ring is walked in BOTH
// directions and the side-B rails come back with the opposite sense (see
// mesh_ops/loop_slice.d's `EdgeRingEntry.mirror`, task 0398). The reference
// puts all four rails at the SAME fraction 0.514065 from their lower-index
// endpoint; the un-mirrored alternative would land the side-B rails at
// 0.485935 — 0.028 away, against a positional agreement of ~1e-8 here. That
// makes assert (3) on this case, not a hand-built extra mesh, the pin for the
// two-sided open span.
//
// The tolerance is the fixture's own 1e-6 and must NOT be tightened: the
// reference dump is float32 and our kernel rounds in float32 too, so exact
// agreement lands at ~1e-8 with headroom, not at 0.
//
// Run via: ./run_test.d topopen_addloop_conformance

import mesh;
import math;
import std.json;
import std.format : format;
import std.math : abs, fmin, fmax;
import fixture_helpers : requireProvenance;

void main() {}

// Fraction-space slack for asserts (3) and (4). Two orders looser than the
// worst measured deviation over the whole suite (7.3e-8, on cc1) and three
// orders TIGHTER than the smallest mirror / per-edge-recomputation error the
// fixture can produce (0.028, on gridwarp).
private enum double kFracTol = 1e-5;

private double dbl(JSONValue v) {
    switch (v.type) {
        case JSONType.integer:  return cast(double)v.integer;
        case JSONType.uinteger: return cast(double)v.uinteger;
        case JSONType.float_:   return v.floating;
        default: assert(0, "fixture: number expected");
    }
}

private Vec3 jvec(JSONValue v) {
    auto a = v.array;
    return Vec3(cast(float)dbl(a[0]), cast(float)dbl(a[1]), cast(float)dbl(a[2]));
}

private Mesh buildCaseMesh(JSONValue mj) {
    Mesh m;
    foreach (v; mj["vertices"].array) m.vertices ~= jvec(v);
    foreach (f; mj["faces"].array) {
        uint[] idx;
        foreach (i; f.array) idx ~= cast(uint)i.integer;
        m.addFace(idx);
    }
    m.buildLoops();
    return m;
}

// Parametric foot of `p` on segment a-b, plus the distance to it.
private float segFoot(Vec3 a, Vec3 b, Vec3 p, out float dist) {
    Vec3  ab = b - a;
    float L2 = dot(ab, ab);
    float t  = (L2 > 0.0f) ? dot(p - a, ab) / L2 : 0.0f;
    if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
    dist = (p - (a + ab * t)).length();
    return t;
}

unittest {
    enum string json = import("fixtures/topopen_addloop.json");
    auto fx = parseJSON(json);
    requireProvenance(fx, fx["name"].str);      // task 0366 golden-fixture gate
    immutable float tol = cast(float)(("tolerance" in fx) ? dbl(fx["tolerance"]) : 1e-6);
    assert(fx["schema"].str == "topology_pen.addloop.conformance/1",
        "unexpected fixture schema");
    assert(fx["cases"].array.length == 8, "the frozen golden has 8 cases");

    size_t openSpans = 0, closedRings = 0;

    foreach (cs; fx["cases"].array) {
        immutable string name = cs["name"].str;
        Mesh m = buildCaseMesh(cs["mesh"]);

        Vec3[] V0 = m.vertices.dup;
        immutable size_t nv0 = V0.length, nf0 = m.faces.length, ne0 = m.edges.length;

        auto se = cs["input"]["seed_edge"].array;
        uint sa = cast(uint)se[0].integer, sb = cast(uint)se[1].integer;
        uint lo = sa < sb ? sa : sb, hi = sa < sb ? sb : sa;
        uint seed = m.edgeIndex(lo, hi);
        assert(seed != ~0u, name ~ ": seed edge must exist in the built mesh");

        auto ct = cs["expected"]["counts"];
        assert(nv0 == cast(size_t)ct["vertices_before"].integer
            && nf0 == cast(size_t)ct["faces_before"].integer,
            format("%s: input mesh must build to the captured %d verts / %d faces, got %d/%d",
                   name, ct["vertices_before"].integer, ct["faces_before"].integer, nv0, nf0));

        // ---- the ONE orientation bit, read BEFORE the cut ------------------
        uint f0 = uint.max;
        foreach (fi; m.facesAroundEdge(seed)) { f0 = fi; break; }
        assert(f0 != uint.max, name ~ ": seed edge must have an incident face");
        int j = m.findEdgeInFace(f0, edgeKey(lo, hi));
        assert(j >= 0, name ~ ": seed edge must be found in its own incident face");
        immutable bool   flip   = (m.faces[f0][j] != lo);
        immutable double scalar = dbl(cs["input"]["scalar"]);
        immutable float  t      = cast(float)(flip ? 1.0 - scalar : scalar);

        assert(m.insertEdgeLoops(seed, [t]), name ~ ": insertEdgeLoops must succeed");

        // ---- counts + the open/closed invariant ----------------------------
        assert(m.vertices.length == cast(size_t)ct["vertices_after"].integer,
            format("%s: V after: want %d got %d", name,
                   ct["vertices_after"].integer, m.vertices.length));
        assert(m.faces.length == cast(size_t)ct["faces_after"].integer,
            format("%s: F after: want %d got %d", name,
                   ct["faces_after"].integer, m.faces.length));
        foreach (const f; m.faces)
            assert(f.length == 4, name ~ ": every face must stay a quad");

        immutable size_t dV = m.vertices.length - nv0;
        immutable size_t dF = m.faces.length    - nf0;
        immutable size_t dE = m.edges.length    - ne0;
        assert(dE == dV + dF, format("%s: dE must be dV+dF (got %d, %d, %d)", name, dE, dV, dF));
        assert(dV == dF || dV == dF + 1,
            format("%s: a loop cut is a closed ring (dV==dF) or an open span (dV==dF+1); got %d/%d",
                   name, dV, dF));
        if (dV == dF + 1) ++openSpans; else ++closedRings;

        // ---- no original vertex moved (law_selfcheck.original_vertices_moved) ----
        foreach (i; 0 .. nv0)
            assert((m.vertices[i] - V0[i]).length() <= tol,
                format("%s: original vertex %d moved", name, i));

        // ---- the crossed SET accounts for every input edge ------------------
        auto crossed    = cs["expected"]["crossed_edges"].array;
        auto notCrossed = cs["expected"]["not_crossed_edges"].array;
        assert(crossed.length + notCrossed.length == ne0,
            format("%s: fixture must classify every one of the %d input edges "
                   ~ "(%d crossed + %d not crossed)", name, ne0,
                   crossed.length, notCrossed.length));

        // ---- crossed edges: the SET, the positions, the directed fraction ---
        assert(dV == crossed.length,
            format("%s: want %d new vertices (one per crossed edge), got %d",
                   name, crossed.length, dV));

        auto used = new bool[](dV);
        double dirLo = 2.0, dirHi = -1.0;   // directed fraction, our output
        double nrmLo = 2.0, nrmHi = -1.0;   // ... folded to the edge's own sense
        double fixLo = 2.0, fixHi = -1.0;   // directed fraction, the reference
        foreach (row; crossed) {
            auto e = row["edge"].array;
            uint u = cast(uint)e[0].integer, v = cast(uint)e[1].integer;
            immutable double tr   = dbl(row["t"]);
            Vec3            want  = jvec(row["position"]);
            size_t          match = size_t.max;
            foreach (k; 0 .. dV) {
                if (used[k]) continue;
                if ((m.vertices[nv0 + k] - want).length() <= tol) {
                    used[k] = true; match = nv0 + k; break;
                }
            }
            assert(match != size_t.max,
                format("%s: no new vertex within %.1e of the reference cut on edge "
                       ~ "(%d,%d) at t=%.9f", name, tol, u, v, tr));

            // Directed fraction from the LOWER-index endpoint: the mirror
            // discriminator (a mirrored rail lands at 1-t, ~0.03..0.25 away).
            Vec3   ab = V0[v] - V0[u];
            double L2 = dot(ab, ab);
            assert(L2 > 0.0, format("%s: degenerate crossed edge (%d,%d)", name, u, v));
            double f = dot(m.vertices[match] - V0[u], ab) / L2;
            assert(abs(f - tr) <= kFracTol,
                format("%s: edge (%d,%d) cut at %.9f of its own length, reference "
                       ~ "says %.9f (a %.4f miss — an un-mirrored side-B rail "
                       ~ "lands at 1-t)", name, u, v, f, tr, abs(f - tr)));

            dirLo = fmin(dirLo, f);  dirHi = fmax(dirHi, f);
            fixLo = fmin(fixLo, tr); fixHi = fmax(fixHi, tr);
            double nf = fmin(f, 1.0 - f);
            nrmLo = fmin(nrmLo, nf); nrmHi = fmax(nrmHi, nf);
        }
        foreach (k; 0 .. dV)
            assert(used[k], format("%s: new vertex %d is not on any crossed edge", name, nv0 + k));

        // ---- not_crossed_edges: nothing landed on them ----------------------
        foreach (row; notCrossed) {
            auto e = row.array;
            uint u = cast(uint)e[0].integer, v = cast(uint)e[1].integer;
            foreach (k; 0 .. dV) {
                float dist;
                immutable float tp = segFoot(V0[u], V0[v], m.vertices[nv0 + k], dist);
                assert(!(dist <= tol && tp > tol && tp < 1.0f - tol),
                    format("%s: edge (%d,%d) must receive no new vertex (got one at t=%.6f)",
                           name, u, v, tp));
            }
        }

        // ---- ONE uniform scalar over the whole ring -------------------------
        // The reference applies a single fraction to every crossed edge; read
        // per-edge from the lower-index endpoint it shows up as t or 1-t, so
        // fold each fraction into its own edge's sense before taking the
        // spread. The bound is the reference's OWN declared deviation plus
        // float32 slack — a per-edge re-derivation of the fraction would
        // scatter by ~1e-2 and blow straight through it.
        immutable double declared = dbl(cs["law_selfcheck"]["max_deviation_from_uniform_scalar"]);
        assert(nrmHi - nrmLo <= declared + kFracTol,
            format("%s: the cut fraction must be ONE scalar for the whole ring — "
                   ~ "folded spread %.3e exceeds the reference's own %.3e",
                   name, nrmHi - nrmLo, declared));

        // Where the reference's own DIRECTED fractions are all equal (a planar
        // cut — including the two-sided open span gridwarp_..._0233), ours must
        // be too: this is the mirror pin restated as a per-case invariant.
        if (fixHi - fixLo <= 1e-9)
            assert(dirHi - dirLo <= kFracTol,
                format("%s: the reference cut every rail at the same directed fraction "
                       ~ "(%.9f); ours spread by %.3e (side-B mirror?)",
                       name, fixLo, dirHi - dirLo));
    }

    // The fixture's whole point: the open span is MEASURED, not extrapolated
    // from the closed-ring controls.
    assert(openSpans == 5, format("expected 5 open-span cases, saw %d", openSpans));
    assert(closedRings == 3, format("expected 3 closed-ring cases, saw %d", closedRings));
}
