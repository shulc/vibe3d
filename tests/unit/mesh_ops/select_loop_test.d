// Module unittests for the select.loop family (`mesh_ops.select_loop`) — the
// differential test against the frozen head-restart oracles, the seed-scan
// step budget, and the corpus fixtures both run on.
//
// The family was a `mixin MeshSelectLoopOps` inside `struct Mesh` until task
// 1903 Stage C turned it into free functions over `ref const(Mesh)`. The op
// call sites below (`m.selectLoopFaces()`, …) are unchanged — UFCS keeps that
// spelling. The seed-scan counter is the one thing that could not: it was
// `Mesh.gSelectLoopSeedScanSteps`, a static injected into the struct, and a
// `Mesh.`-qualified name is not a UFCS call, so it is now the module-level
// `gSelectLoopSeedScanSteps` this file reads through `import mesh;`.
//
// Moved here by task 0717 when the family was split out of mesh.d. 0706 had
// left these in source/ as "blocks that read private"; they do not. The
// fixtures were `version (unittest) private` at mesh.d module scope, which is
// what made them unreachable from tests/unit/ — but nothing in their bodies
// touches a private member, so moving the fixtures WITH the blocks is enough,
// and the compiler is the one saying so.
module tests.unit.mesh_ops.select_loop_test;

import mesh;
import math;






// ---------------------------------------------------------------------------
// select.loop seed scans — corpus fixtures.
// ---------------------------------------------------------------------------
// The two blocks these feed (equivalence against the head-restart oracle, and
// the seed-scan step budget) sit next to the walks themselves; the fixtures
// stay here because a struct cannot host a free function.

version (unittest) private {
    // Deterministic xorshift — std.random's global generator is shared state.
    struct SlRng {
        uint s = 0x2545F491;
        uint next() { s ^= s << 13; s ^= s >> 17; s ^= s << 5; return s; }
        uint upto(uint n) { return n ? next() % n : 0; }
    }

    /// n x n quad grid; `tri` splits every cell into two triangles.
    Mesh slGrid(int n, bool tri) {
        Mesh m;
        foreach (r; 0 .. n + 1)
            foreach (c; 0 .. n + 1) m.addVertex(Vec3(c, 0, r));
        uint vid(int r, int c) { return cast(uint)(r * (n + 1) + c); }
        foreach (r; 0 .. n)
            foreach (c; 0 .. n) {
                if (tri) {
                    m.addFace([vid(r,c),   vid(r,c+1),   vid(r+1,c+1)]);
                    m.addFace([vid(r,c),   vid(r+1,c+1), vid(r+1,c)]);
                } else {
                    m.addFace([vid(r,c), vid(r,c+1), vid(r+1,c+1), vid(r+1,c)]);
                }
            }
        m.buildLoops();
        return m;
    }

    /// `k` components that share no vertex — `sides`-gons side by side.
    Mesh slDisjoint(int k, int sides) {
        Mesh m;
        foreach (i; 0 .. k) {
            uint base = cast(uint)m.vertices.length;
            uint[] f;
            foreach (o; 0 .. sides) {
                import std.math : cos, sin, PI;
                const a = 2 * PI * o / sides;
                m.addVertex(Vec3(i * 4 + cos(a), 0, sin(a)));
                f ~= base + cast(uint)o;
            }
            m.addFace(f);
        }
        m.buildLoops();
        return m;
    }

    /// Quad grid where a random third of the cells is split into two triangles
    /// — mixed parity, so partner pairing and the odd-sided skip both fire.
    Mesh slMixedGrid(int n, ref SlRng rng) {
        Mesh m;
        foreach (r; 0 .. n + 1)
            foreach (c; 0 .. n + 1) m.addVertex(Vec3(c, 0, r));
        uint vid(int r, int c) { return cast(uint)(r * (n + 1) + c); }
        foreach (r; 0 .. n)
            foreach (c; 0 .. n) {
                if (rng.upto(3) == 0) {
                    m.addFace([vid(r,c),   vid(r,c+1),   vid(r+1,c+1)]);
                    m.addFace([vid(r,c),   vid(r+1,c+1), vid(r+1,c)]);
                } else {
                    m.addFace([vid(r,c), vid(r,c+1), vid(r+1,c+1), vid(r+1,c)]);
                }
            }
        m.buildLoops();
        return m;
    }

    /// `k` quads all hinged on the SAME edge — a non-manifold fan, so
    /// edgeFaces[e] holds more than two faces.
    Mesh slNonManifoldFan(int k) {
        Mesh m;
        m.addVertex(Vec3(0, 0, 0));
        m.addVertex(Vec3(1, 0, 0));
        foreach (i; 0 .. k) {
            uint base = cast(uint)m.vertices.length;
            m.addVertex(Vec3(1, i + 1, 0));
            m.addVertex(Vec3(0, i + 1, 0));
            m.addFace([0u, 1u, base, base + 1]);
        }
        m.buildLoops();
        return m;
    }

    /// Random face soup over a sliding vertex window: shared edges, bowties,
    /// duplicate faces, 3..6 sides, and the occasional isolated island.
    Mesh slSoup(int nv, int nf, ref SlRng rng) {
        Mesh m;
        foreach (i; 0 .. nv)
            m.addVertex(Vec3(rng.upto(20), rng.upto(20), rng.upto(20)));
        foreach (_; 0 .. nf) {
            const sides = 3 + rng.upto(4);
            const win   = rng.upto(cast(uint)nv);
            uint[] f;
            foreach (__; 0 .. sides) {
                uint v = (win + rng.upto(8)) % nv;
                bool dup = false;
                foreach (x; f) if (x == v) { dup = true; break; }
                if (!dup) f ~= v;
            }
            if (f.length >= 3) m.addFace(f);
        }
        m.buildLoops();
        return m;
    }

    /// Select `frac`/16 of the elements in a scrambled order, so the
    /// selection-history order the scans sort by is NOT the index order.
    void slSelectFaces(ref Mesh m, ref SlRng rng, uint frac) {
        m.resizeFaceSelection();
        m.faceSelectionOrder.length = m.faces.length;
        uint[] idx;
        foreach (i; 0 .. m.faces.length) idx ~= cast(uint)i;
        foreach_reverse (i; 1 .. idx.length) {
            const j = rng.upto(cast(uint)i + 1);
            const t = idx[i]; idx[i] = idx[j]; idx[j] = t;
        }
        foreach (i; idx) if (rng.upto(16) < frac) m.selectFace(cast(int)i);
    }

    void slSelectVerts(ref Mesh m, ref SlRng rng, uint frac) {
        m.resizeVertexSelection();
        uint[] idx;
        foreach (i; 0 .. m.vertices.length) idx ~= cast(uint)i;
        foreach_reverse (i; 1 .. idx.length) {
            const j = rng.upto(cast(uint)i + 1);
            const t = idx[i]; idx[i] = idx[j]; idx[j] = t;
        }
        foreach (i; idx) if (rng.upto(16) < frac) m.selectVertex(cast(int)i);
    }

    string slDiff(const bool[] got, const bool[] want) {
        import std.format : format;
        foreach (i; 0 .. want.length) {
            if (i >= got.length) return format("truncated at %d", i);
            if (got[i] != want[i])
                return format("first divergence at element %d: fast=%s oracle=%s",
                              i, got[i], want[i]);
        }
        return got.length != want.length ? "length mismatch" : "identical";
    }
}

// ---------------------------------------------------------------------------
// select.loop seed scans: cost and equivalence
// ---------------------------------------------------------------------------
// The recovered face/vertex walks consume seeds one group at a time. Every
// pass used to re-scan the whole selected list from the head, so the pass
// sequence cost O(passes x selected) — quadratic, and the pass count EQUALS
// the selected count on the two shapes an importer and the array tools
// actually produce: a triangulated mesh in polygon mode (selectBandTrace skips
// odd-sided neighbours, so a triangle never advances and is always a group of
// one) and many small components in vertex mode. Command.apply() runs on the
// main thread, so that is a frozen UI.
//
// The scans are now forward-only. The tests below hold that down from both
// sides: the cost is asserted in SEED-SCAN STEPS (deterministic — a wall-clock
// threshold would flake on a loaded machine), and the ANSWER is asserted
// against a frozen head-restart oracle over a corpus, because a cursor that
// skipped one element too many would be a silent selection bug.
// ---------------------------------------------------------------------------
unittest { // the forward-only seed scans answer EXACTLY what head-restart did
    SlRng rng;
    size_t cases = 0;

    void check(string shape, ref Mesh m, uint frac) {
        import std.format : format;
        slSelectFaces(m, rng, frac);
        auto gotF  = m.selectLoopFaces();
        auto wantF = m.selectLoopFacesHeadRestart();
        assert(gotF == wantF,
            format("%s (frac %d/16), polygon mode: %s", shape, frac, slDiff(gotF, wantF)));

        slSelectVerts(m, rng, frac);
        auto gotV  = m.selectLoopVertices();
        auto wantV = m.selectLoopVerticesHeadRestart();
        assert(gotV == wantV,
            format("%s (frac %d/16), vertex mode: %s", shape, frac, slDiff(gotV, wantV)));
        ++cases;
    }

    foreach (frac; [16u, 12u, 8u, 4u, 2u]) {
        auto a = slGrid(6, false);       check("quad grid 6",        a, frac);
        auto b = slGrid(6, true);        check("tri grid 6",         b, frac);
        auto c = slDisjoint(9, 4);       check("9 disjoint quads",   c, frac);
        auto d = slDisjoint(9, 3);       check("9 disjoint tris",    d, frac);
        auto e = slDisjoint(6, 6);       check("6 disjoint hexes",   e, frac);
        auto f = slMixedGrid(6, rng);    check("mixed-parity grid",  f, frac);
        auto g = slNonManifoldFan(5);    check("non-manifold fan",   g, frac);
        foreach (s; 0 .. 12) {
            auto h = slSoup(24, 20, rng);
            check("random soup", h, frac);
        }
    }
    assert(cases == 5 * 19, "the corpus ran end to end");
}

unittest { // …and they cost O(selected), not O(selected^2)
    import std.format : format;

    // Both shapes below are measured at two sizes, the second with FOUR TIMES
    // the selected elements of the first. A linear scan grows ~4x; a scan that
    // restarts at the head grows ~16x. The gate is 6x — comfortably above the
    // real ratio and far below the quadratic one, so it does not depend on the
    // per-element constant and cannot flake (the counter is deterministic; a
    // wall-clock threshold would not be).
    enum RATIO_GATE = 6;

    // Polygon mode on a triangulated grid: selectBandTrace skips odd-sided
    // neighbours, so a triangle never advances and every one of them is a
    // group of its own — head-restart walked the whole selection once PER
    // SELECTED FACE, twice (NEXT_GROUP and the partner scan).
    size_t polySteps(int n) {
        auto m = slGrid(n, true);
        m.resizeFaceSelection();
        m.faceSelectionOrder.length = m.faces.length;
        foreach (i; 0 .. m.faces.length) m.selectFace(cast(int)i);
        gSelectLoopSeedScanSteps = 0;
        m.selectLoopFaces();
        return gSelectLoopSeedScanSteps;
    }
    const p1 = polySteps(20);   //   800 triangles
    const p2 = polySteps(40);   //  3200 triangles
    assert(p2 <= RATIO_GATE * p1,
        format("polygon seed scan is superlinear: 4x the selected polygons cost "
             ~ "%.1fx the seed-scan steps (%d -> %d). Head-restart scored ~16x. "
             ~ "Something reintroduced a scan that does not start where the last "
             ~ "one stopped.", cast(double)p2 / p1, p1, p2));

    // Vertex mode with many small components: one pass per component, and each
    // pass used to re-walk every vertex ahead of it. Note the dead-end pairs a
    // consumed edge leaves behind are NOT marked, so the leading-run cursor
    // alone does not save this shape — the burn memo does.
    size_t vertSteps(int k) {
        auto m = slDisjoint(k, 4);
        m.resizeVertexSelection();
        foreach (i; 0 .. m.vertices.length) m.selectVertex(cast(int)i);
        gSelectLoopSeedScanSteps = 0;
        m.selectLoopVertices();
        return gSelectLoopSeedScanSteps;
    }
    const v1 = vertSteps(250);   // 1000 vertices
    const v2 = vertSteps(1000);  // 4000 vertices
    assert(v2 <= RATIO_GATE * v1,
        format("vertex seed scan is superlinear: 4x the selected vertices cost "
             ~ "%.1fx the seed-scan steps (%d -> %d). Head-restart scored ~16x.",
               cast(double)v2 / v1, v1, v2));

    // A per-element ceiling as well, so a linear-but-absurd scan is caught too.
    // Measured: ~8 steps/polygon (cursor + A's edges x their face degree) and
    // ~3 steps/vertex.
    assert(p2 <= 24 * 3200, format("polygon seed scan: %d steps for 3200 polygons", p2));
    assert(v2 <= 24 * 4000, format("vertex seed scan: %d steps for 4000 vertices", v2));

    // NON-VACUITY FLOOR (task 1903 Stage C). Every assertion above is an UPPER
    // bound, so a counter that never increments satisfies all four — measured:
    // deleting the three `++gSelectLoopSeedScanSteps` sites left this block
    // green, and with them the only evidence that the walks under test are the
    // ones being measured at all. A scan that touches a selected element must
    // cost at least one step per element it consumed; anything at or below the
    // element count means the instrument is disconnected, not that the scan
    // got faster.
    assert(p1 >= 800 && p2 >= 3200,
        format("the polygon seed-scan counter did not count: %d steps for 800 "
             ~ "selected polygons and %d for 3200. Every other assertion here "
             ~ "is an upper bound, so a dead counter passes them all — this "
             ~ "floor is what says the walk being measured is the live one "
             ~ "(task 1903 Stage C).", p1, p2));
    assert(v1 >= 1000 && v2 >= 4000,
        format("the vertex seed-scan counter did not count: %d steps for 1000 "
             ~ "selected vertices and %d for 4000 (task 1903 Stage C).", v1, v2));
}
