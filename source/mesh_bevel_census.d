module mesh_bevel_census;

// Task 0445 — a refusal CENSUS for `Mesh.bevelEdgesByMask` over realistic
// meshes, not just the cube every existing bevel test runs on.
//
// WHY THIS FILE EXISTS. Across tests/test_edge_bevel*.d and the unittest
// blocks next to bevelEdgesByMask in source/mesh.d, `makeCube()` supplies
// the mesh 128 times, `cubeMinusBottom` 8, a synthetic propeller 2 — and
// NOTHING else. A cube has only valence-3 vertices, so a whole class of
// topology (a free end at valence>3, ordinary on any subdivided or
// already-beveled mesh) could never appear in any of those tests. The
// owner hit that class twice in one live session before any test did
// (see doc/tasks/done/0445-edge-bevel-realistic-mesh-sweep.md).
//
// WHAT THIS IS NOT. Not golden parity — that needs a captured reference
// dump per mesh, which we don't have for a sphere/cylinder/torus. This is
// a black-box CENSUS: for every edge (and a bounded set of small connected
// edge groups) of a handful of realistic meshes, call the REAL kernel and
// record whether it processed the selection, and — only when it declined —
// attribute a best-effort reason by re-checking the same topological
// conditions the kernel's own preflight guards check. The "processed or
// not" bit always comes from a direct `bevelEdgesByMask()` call; the
// reason label is a read-only, best-effort mirror of the kernel's guards
// (see `classifyDecline` below) that can go stale without corrupting the
// headline numbers — see the comment on that function.
//
// SCOPE / CONSTRAINTS (task 0445): this file must never call into or
// change `bevelEdgesByMask`'s behaviour — two sibling tasks (0436, 0439)
// are actively working on that function. This module only *measures* it
// through its existing public contract (mask in, processed-count out).
// Where a needed mesh primitive (UV sphere / cylinder / torus) doesn't
// exist in source/mesh.d, it is built HERE, test-only, rather than added
// to the production primitive-factory set.
//
// WHERE THIS RUNS. Plain `unittest {}` blocks in a source/ module, so
// `dub test --config=modeling` (the `dubtest` lane already in
// run_all.d's default suite set) exercises it — no vibe3d process, no
// HTTP round-trip, no new run_all.d lane needed. Every mesh here tops out
// in the low hundreds of vertices/edges, and `bevelEdgesByMask` is O(mesh
// size), so the whole census runs in a small fraction of a second: cheap
// enough to ride the existing pre-commit dubtest gate on every run.
//
// `version (unittest)` gates the ENTIRE file body below the imports —
// none of this (primitives, classifier, census loop) compiles into the
// shipped `vibe3d` binary; it only exists under `dub test`.
//
// EXTENDED 2026-07-20 (still task 0445): the census above measures
// ACCEPTANCE only — after task 0439's free-end cap landed, that number
// reached 1884/1884 accepted, which answers "does it refuse?" but not
// "does it work?", "does every parameter it takes do anything?", or "does
// it survive a selection that spans more than one vertex-anchored
// cluster?" (the exact shape that reached the owner as a crash, assert
// "rounded edge bevel rail must be approved before materialization",
// fixed in 0d1b3be — the original census structurally could not have
// built that selection, since every trial mask was anchored at ONE
// vertex). Three more lanes below, same census philosophy (real kernel
// call, pinned-by-equality baseline, loud failure on ANY movement):
//   - SOUNDNESS: is the accepted geometry actually well-formed?
//   - ROUND-LEVEL: does the roundLevel parameter ever do anything outside
//     the well-supported K==3 corner-hub shape?
//   - MIXED SELECTIONS: chains, ring+trailing-chain, disjoint clusters,
//     and the specific corner-hub-plus-free-end shape that crashed.

import mesh;
import math : Vec3;

version (unittest):

import std.stdio : writefln;
import std.math : PI, cos, sin, fabs;

// ===========================================================================
// Test-only mesh primitives (sphere / cylinder / torus) — NOT present in
// source/mesh.d's factory set (makeCube / makeOctahedron / makeGridPlane /
// subdivideCube / ...). Winding is outward-CCW, verified by hand (cross-
// product sign check against the expected outward direction) for each
// face-family below, and cross-checked at runtime by the manifold
// self-check in `censusMesh` (every edge must show exactly 1 or 2 incident
// faces — a winding bug would show up as an `edgeFaceUseCounts()` anomaly
// or a buildLoops() inconsistency, not a silent wrong number).
// ===========================================================================

/// UV sphere: 1 north pole + (rings-1) latitude rings of `segments` verts
/// + 1 south pole. Triangulated pole caps, quad body. Pole vertices have
/// valence == segments — deliberately high, to exercise the "free end at
/// valence>3" family the cube can never reach.
private Mesh makeUvSphereForCensus(int rings, int segments, float radius = 1.0f) {
    assert(rings >= 2 && segments >= 3);
    Mesh m;
    m.vertices ~= Vec3(0, radius, 0); // 0: north pole
    foreach (r; 1 .. rings) {
        immutable float theta = PI * r / rings;
        immutable float y     = radius * cos(theta);
        immutable float ringR = radius * sin(theta);
        foreach (s; 0 .. segments) {
            immutable float phi = 2 * PI * s / segments;
            m.vertices ~= Vec3(ringR * cos(phi), y, ringR * sin(phi));
        }
    }
    m.vertices ~= Vec3(0, -radius, 0); // south pole, last index
    immutable uint northIdx = 0;
    immutable uint southIdx = cast(uint)(m.vertices.length - 1);

    // North cap: [ring0[s], north, ring0[s+1]] — verified outward CCW.
    foreach (s; 0 .. segments)
        m.addFace([1u + s, northIdx, 1u + cast(uint)((s + 1) % segments)]);

    // Body quads between consecutive rings:
    // [ring[r+1][s], ring[r][s], ring[r][s+1], ring[r+1][s+1]] — verified
    // outward CCW (ring[r] is nearer the north pole / higher Y).
    foreach (r; 0 .. rings - 2) {
        immutable uint ring0 = cast(uint)(1 + r * segments);
        immutable uint ring1 = cast(uint)(1 + (r + 1) * segments);
        foreach (s; 0 .. segments) {
            immutable uint sN = cast(uint)((s + 1) % segments);
            m.addFace([ring1 + s, ring0 + s, ring0 + sN, ring1 + sN]);
        }
    }

    // South cap: [south, ringLast[s], ringLast[s+1]] — verified outward CCW.
    immutable uint ringLast = cast(uint)(1 + (rings - 2) * segments);
    foreach (s; 0 .. segments)
        m.addFace([southIdx, ringLast + s, ringLast + cast(uint)((s + 1) % segments)]);

    m.buildLoops();
    return m;
}

/// Cylinder: `heightSegments+1` rings of `segments` verts around the Y
/// axis, optionally capped with a single N-gon face at each end. An
/// UNcapped cylinder gives boundary (open-fan) rim vertices — the other
/// topology class the cube structurally cannot produce.
private Mesh makeCylinderForCensus(int segments, int heightSegments, float radius,
                                    float height, bool caps) {
    assert(segments >= 3 && heightSegments >= 1);
    Mesh m;
    immutable int rings = heightSegments + 1;
    m.vertices.length = cast(size_t)rings * segments;
    foreach (r; 0 .. rings) {
        immutable float y = -height * 0.5f + height * cast(float)r / cast(float)heightSegments;
        foreach (s; 0 .. segments) {
            immutable float phi = 2 * PI * s / segments;
            m.vertices[cast(size_t)r * segments + s] =
                Vec3(radius * cos(phi), y, radius * sin(phi));
        }
    }

    // Side quads: [bottom_s, top_s, top_{s+1}, bottom_{s+1}] — verified
    // outward CCW.
    foreach (r; 0 .. heightSegments) {
        immutable uint ringB = cast(uint)(r * segments);
        immutable uint ringT = cast(uint)((r + 1) * segments);
        foreach (s; 0 .. segments) {
            immutable uint sN = cast(uint)((s + 1) % segments);
            m.addFace([ringB + s, ringT + s, ringT + sN, ringB + sN]);
        }
    }

    if (caps) {
        // Bottom cap (outward -Y): increasing-s order — verified.
        uint[] bottom;
        foreach (s; 0 .. segments) bottom ~= cast(uint)s;
        m.addFace(bottom);
        // Top cap (outward +Y): DEcreasing-s order — verified.
        uint[] top;
        immutable uint topRing = cast(uint)(heightSegments * segments);
        foreach_reverse (s; 0 .. segments) top ~= topRing + cast(uint)s;
        m.addFace(top);
    }

    m.buildLoops();
    return m;
}

/// Torus: `segMajor` × `segMinor` fully periodic quad grid — every vertex
/// has uniform valence 4, a useful contrast to the sphere's/cube's varied
/// valence and to the cylinder's boundary case.
private Mesh makeTorusForCensus(int segMajor, int segMinor, float rMajor, float rMinor) {
    assert(segMajor >= 3 && segMinor >= 3);
    Mesh m;
    m.vertices.length = cast(size_t)segMajor * segMinor;
    foreach (i; 0 .. segMajor) {
        immutable float theta = 2 * PI * i / segMajor;
        foreach (j; 0 .. segMinor) {
            immutable float phi = 2 * PI * j / segMinor;
            immutable float ringR = rMajor + rMinor * cos(phi);
            m.vertices[cast(size_t)i * segMinor + j] =
                Vec3(ringR * cos(theta), rMinor * sin(phi), ringR * sin(theta));
        }
    }
    // [ring[i+1][j], ring[i][j], ring[i][j+1], ring[i+1][j+1]] — verified
    // outward CCW (same derivation as the sphere's body quad, doubly
    // periodic in both i (major) and j (minor)).
    foreach (i; 0 .. segMajor) {
        immutable uint ring0 = cast(uint)(i * segMinor);
        immutable uint ring1 = cast(uint)(((i + 1) % segMajor) * segMinor);
        foreach (j; 0 .. segMinor) {
            immutable uint jN = cast(uint)((j + 1) % segMinor);
            m.addFace([ring1 + j, ring0 + j, ring0 + jN, ring1 + jN]);
        }
    }
    m.buildLoops();
    return m;
}

/// "Output of a previous bevel" — the case the owner actually got stuck
/// on twice in one session (task 0445's motivating log entry): a mesh
/// that has ALREADY been through edge.bevel, now carrying mixed valence
/// (round-level rail vertices, corner caps) that a fresh cube can never
/// have. Two disjoint corner-hub bevels (K==3, the well-supported "full
/// ring" case) on opposite cube corners, so the result carries more than
/// one beveled region.
private Mesh makePostBevelCubeForCensus() {
    Mesh m = makeCube();
    {
        uint[] vEdges;
        foreach (ei; m.edgesAroundVertex(6)) vEdges ~= ei;
        auto mask = new bool[](m.edges.length);
        foreach (ei; vEdges) mask[ei] = true;
        immutable size_t n = m.bevelEdgesByMask(mask, 0.2f, 1);
        assert(n > 0, "post-bevel fixture: corner-hub bevel #1 must succeed");
    }
    {
        // Vertex 0 is makeCube()'s opposite corner and untouched by the
        // bevel above (bevelEdgesByMask only appends new vertices; it
        // never renumbers untouched ones), so its edge indices are still
        // valid to look up post-mutation.
        uint[] vEdges;
        foreach (ei; m.edgesAroundVertex(0)) vEdges ~= ei;
        auto mask = new bool[](m.edges.length);
        foreach (ei; vEdges) mask[ei] = true;
        immutable size_t n = m.bevelEdgesByMask(mask, 0.2f, 0);
        assert(n > 0, "post-bevel fixture: corner-hub bevel #2 must succeed");
    }
    return m;
}

// ===========================================================================
// Safe isolated clone. `bevelEdgesByMask` mutates in place, and `Mesh` is a
// struct whose array fields alias on plain struct assignment (see Mesh's
// own doc comment on `_adjCsrOffset`/`_adjCsrNeighbors`: "these slices must
// never be shared live across a mutating value copy of a Mesh... Safe
// today because every live Mesh copy is source-dies / fresh-local /
// snapshot-.dup"). We want to run hundreds of trials against ONE built
// template mesh without re-synthesizing it (subdivideCube in particular
// is not cheap — it runs a real OpenSubdiv limit-surface eval), so every
// trial clones the template first. `.dup` every field the kernel can
// reach and reassign (not mutate-in-place) so the template is provably
// unaffected — verified, not just assumed, by the checksum guard in
// `censusMesh` below.
// ===========================================================================
private Mesh cloneMeshForTrial(const ref Mesh src) {
    // `cast` past the const: every array/AA field this function can see is
    // about to be reassigned to an independently `.dup`'d copy below, and
    // the remaining scalar fields are copied by value regardless — so this
    // does not actually expose `src`'s storage to mutation.
    Mesh m = cast(Mesh)src;
    m.vertices = src.vertices.dup;
    m.edges    = src.edges.dup;
    m.faces.length = 0;
    foreach (f; src.faces) m.faces ~= f.dup;
    m.edgeIndexMap = src.edgeIndexMap.dup;
    m.loops    = src.loops.dup;
    m.faceLoop = src.faceLoop.dup;
    m.vertLoop = src.vertLoop.dup;
    m.loopEdge = src.loopEdge.dup;
    return m;
}

// ===========================================================================
// Refusal classification. READ-ONLY mirrors of bevelEdgesByMask's own
// preflight guards (source/mesh.d, `bevelEdgesByMask`, roughly lines
// 8526-9070 as of task 0445):
//   - the 3+-incident-faces refusal (task 0438's guard),
//   - the per-vertex "keep V" partial-fan notch refusal (task 0439's
//     `fanActive[k] != fanActive[kr]` check — the free-end/valence>3
//     family this whole task exists to surface),
//   - the malformed/non-manifold fan skip (`d < 2 || (nE != d && !openFan)`).
//
// These are DUPLICATED here, not imported/reused, because the kernel
// exposes no reason code and this task must not modify the kernel to add
// one (two sibling tasks are actively editing it). Staleness risk: if
// 0436/0438/0439 change what the kernel refuses, this classifier can
// mislabel a decline — but it can NEVER misreport whether the kernel
// declined, because `Reason.Processed` vs. a decline always comes from a
// live `bevelEdgesByMask()` call in `runTrial`, never from this
// classifier. A stale classifier shows up as a rising `Unclassified`
// bucket, which is exactly the "loud, separate" signal task 0445 asks
// for — not a silently wrong headline number.
// ===========================================================================
enum Reason {
    Processed,        // not a decline
    FacesGE3,         // known family: edge shared by 3+ faces (task 0438)
    PartialFanNotch,  // known family: free end / partial-fan notch at valence>3 (task 0439)
    MalformedFan,     // non-manifold / malformed fan shape at an affected vertex
    NoQualifying,      // none of the masked edges touch any face at all (degenerate mask)
    Unclassified,      // declined, but none of the above explains it — REPORT LOUDLY
}

private bool[] affectedVertices(const ref Mesh m, const bool[] mask) {
    auto affected = new bool[](m.vertices.length);
    foreach (i; 0 .. m.edges.length)
        if (i < mask.length && mask[i]) {
            affected[m.edges[i][0]] = true;
            affected[m.edges[i][1]] = true;
        }
    return affected;
}

private bool edgeSetHasFacesGE3(const ref Mesh m, const bool[] mask) {
    auto use = m.edgeFaceUseCounts();
    foreach (i; 0 .. m.edges.length)
        if (i < mask.length && mask[i] && i < use.length && use[i] >= 3) return true;
    return false;
}

private bool anyMaskedEdgeQualifies(const ref Mesh m, const bool[] mask) {
    // Mirrors bevelEdgesByMask Step 1's qualification loop: a masked edge
    // "qualifies" iff it has at least one incident face.
    auto use = m.edgeFaceUseCounts();
    foreach (i; 0 .. m.edges.length)
        if (i < mask.length && mask[i] && i < use.length && use[i] >= 1) return true;
    return false;
}

private bool anyAffectedVertexMalformed(const ref Mesh m, const bool[] mask) {
    auto affected = affectedVertices(m, mask);
    foreach (V; 0 .. cast(uint)m.vertices.length) {
        if (!affected[V]) continue;
        size_t d = 0;
        foreach (fi; m.facesAroundVertex(V)) ++d;
        size_t nE = 0;
        foreach (ei; m.edgesAroundVertex(V)) ++nE;
        immutable bool openFan = (nE == d + 1);
        if (d < 2 || (nE != d && !openFan)) return true;
    }
    return false;
}

private bool anyAffectedVertexHasPartialNotch(const ref Mesh m, const bool[] mask) {
    auto affected = affectedVertices(m, mask);
    foreach (V; 0 .. cast(uint)m.vertices.length) {
        if (!affected[V]) continue;
        size_t d = 0;
        foreach (fi; m.facesAroundVertex(V)) ++d;
        bool[] fanSelected;
        foreach (ei; m.edgesAroundVertex(V))
            fanSelected ~= (ei < mask.length && mask[ei]);
        immutable bool openFan = (fanSelected.length == d + 1);
        if (!openFan && fanSelected.length != d) continue; // malformed — different family
        size_t K = 0;
        foreach (s; fanSelected) if (s) ++K;
        if (K == 0 || (!openFan && K == d)) continue; // untouched, or a full hub

        immutable size_t nSlots = fanSelected.length;
        auto fanActive = new bool[](nSlots);
        foreach (k; 0 .. nSlots) {
            if (fanSelected[k]) continue;
            if (openFan) {
                fanActive[k] = (k > 0 && fanSelected[k - 1]) ||
                               (k + 1 < nSlots && fanSelected[k + 1]);
                if (!fanActive[k] && (k == 0 || k == nSlots - 1))
                    fanActive[k] = fanSelected[k == 0 ? nSlots - 1 : 0];
            } else {
                fanActive[k] = fanSelected[(k + nSlots - 1) % nSlots] ||
                               fanSelected[(k + 1) % nSlots];
            }
        }
        foreach (k; 0 .. d) {
            immutable size_t kr = (k + 1) % nSlots;
            if (fanSelected[k] || fanSelected[kr]) continue;
            if (fanActive[k] != fanActive[kr]) return true;
        }
    }
    return false;
}

private Reason classifyDecline(const ref Mesh m, const bool[] mask) {
    if (edgeSetHasFacesGE3(m, mask)) return Reason.FacesGE3;
    if (!anyMaskedEdgeQualifies(m, mask)) return Reason.NoQualifying;
    if (anyAffectedVertexHasPartialNotch(m, mask)) return Reason.PartialFanNotch;
    if (anyAffectedVertexMalformed(m, mask)) return Reason.MalformedFan;
    return Reason.Unclassified;
}

// ===========================================================================
// Census machinery
// ===========================================================================

struct Census {
    size_t total;
    size_t[Reason] byReason;
    void record(Reason r) {
        ++total;
        byReason[r] = byReason.get(r, 0) + 1;
    }
    size_t declined() const {
        return total - byReason.get(Reason.Processed, 0);
    }
}

private void runTrial(const ref Mesh template_, const bool[] mask, ref Census census, float width) {
    auto clone = cloneMeshForTrial(template_);
    immutable size_t processed = clone.bevelEdgesByMask(mask, width);
    if (processed > 0) {
        census.record(Reason.Processed);
        return;
    }
    census.record(classifyDecline(template_, mask));
}

/// Runs the trial matrix (every single edge, plus a bounded set of small
/// connected edge groups anchored at every vertex) against one mesh and
/// prints a grouped breakdown. Returns the aggregate `Census` so callers
/// can assert on totals.
private Census censusMesh(string label, const ref Mesh m, float width = 0.08f) {
    Census c;
    immutable size_t nE = m.edges.length;
    immutable size_t nV = m.vertices.length;

    // Self-check: this function must not mutate its own input. Every
    // trial runs on a `cloneMeshForTrial` copy — this guard turns "the
    // clone is safe" from an assumption into something this test itself
    // verifies on every run, rather than trusting the aliasing analysis
    // in cloneMeshForTrial's doc comment blindly.
    immutable size_t vBefore = m.vertices.length;
    immutable size_t eBefore = m.edges.length;
    immutable size_t fBefore = m.faces.length;
    double posBefore = 0.0;
    foreach (v; m.vertices) posBefore += cast(double)v.x + cast(double)v.y * 2.0 + cast(double)v.z * 3.0;

    // 1) Every single edge in isolation — the primary census axis, and
    // (with only one edge selected) already exactly the "free end at
    // valence>3" shape from task 0445's motivating bug: K==1 at a
    // vertex whose valence may be anything.
    foreach (i; 0 .. nE) {
        auto mask = new bool[](nE);
        mask[i] = true;
        runTrial(m, mask, c, width);
    }

    // 2) Small connected edge sets anchored at every vertex: full hub
    // (every incident edge selected — the N-way-junction / closed-ring
    // shape), an adjacent pair (a loop "turn"), and — at valence>=4 —
    // an all-but-one selection (the owner's other motivating bug: four
    // edges converging at one point, refusing both as a set AND
    // individually) and a non-adjacent pair.
    foreach (V; 0 .. cast(uint)nV) {
        uint[] vEdges;
        foreach (ei; m.edgesAroundVertex(V)) vEdges ~= ei;
        immutable size_t nEv = vEdges.length;
        if (nEv < 2) continue;

        { // full hub
            auto mask = new bool[](nE);
            foreach (ei; vEdges) mask[ei] = true;
            runTrial(m, mask, c, width);
        }
        { // adjacent pair
            auto mask = new bool[](nE);
            mask[vEdges[0]] = true;
            mask[vEdges[1]] = true;
            runTrial(m, mask, c, width);
        }
        if (nEv >= 4) { // all-but-one (single gap)
            auto mask = new bool[](nE);
            foreach (ei; vEdges) mask[ei] = true;
            mask[vEdges[0]] = false;
            runTrial(m, mask, c, width);
        }
        if (nEv >= 4) { // non-adjacent pair
            auto mask = new bool[](nE);
            mask[vEdges[0]] = true;
            mask[vEdges[2]] = true;
            runTrial(m, mask, c, width);
        }
    }

    assert(m.vertices.length == vBefore && m.edges.length == eBefore && m.faces.length == fBefore,
        "census corrupted its own template mesh (element count) for '" ~ label ~
        "' — cloneMeshForTrial aliasing bug, not a bevel-kernel finding");
    double posAfter = 0.0;
    foreach (v; m.vertices) posAfter += cast(double)v.x + cast(double)v.y * 2.0 + cast(double)v.z * 3.0;
    assert(posAfter == posBefore,
        "census corrupted its own template mesh (vertex positions) for '" ~ label ~
        "' — cloneMeshForTrial aliasing bug, not a bevel-kernel finding");

    writefln("[edge.bevel census] %-16s edges=%-5d verts=%-5d trials=%-6d declined=%-5d (%.1f%%)",
        label, nE, nV, c.total, c.declined(), c.total ? 100.0 * c.declined() / c.total : 0.0);
    static immutable Reason[] knownOrder =
        [Reason.FacesGE3, Reason.PartialFanNotch, Reason.MalformedFan,
         Reason.NoQualifying, Reason.Unclassified];
    foreach (r; knownOrder) {
        immutable n = c.byReason.get(r, 0);
        if (n > 0) writefln("    %-18s %d", r, n);
    }
    return c;
}

// ===========================================================================
// The census itself. Baseline numbers below were measured 2026-07-20
// (task 0445) against the current `bevelEdgesByMask` (post task-0438's
// 3+-faces guard, pre task-0436/0439 fixes). They are asserted EXACTLY,
// not as an upper bound: the point of a baseline is that ANY move — up
// (regression) or down (a fix landed) — is visible as a failing assert
// here, per task 0445's explicit "verify 0439 actually lowers the
// baseline, not just rewords the refusal" requirement. When a sibling
// task changes these numbers, update the constant with a comment noting
// which task and which direction it moved.
// ===========================================================================

unittest {
    // Small/medium closed manifolds with high-valence poles/interior
    // vertices — cube can never produce these.
    auto sphere      = makeUvSphereForCensus(6, 10);
    auto cylClosed   = makeCylinderForCensus(12, 2, 1.0f, 1.5f, true);
    auto cylOpen     = makeCylinderForCensus(12, 2, 1.0f, 1.5f, false);
    auto torus       = makeTorusForCensus(12, 8, 1.0f, 0.35f);
    auto subdivCube  = subdivideCube(2);
    auto postBevel   = makePostBevelCubeForCensus();

    Census total;
    void merge(Census c) {
        total.total += c.total;
        foreach (r, n; c.byReason) total.byReason[r] = total.byReason.get(r, 0) + n;
    }

    merge(censusMesh("sphere",        sphere));
    merge(censusMesh("cylinder",      cylClosed));
    merge(censusMesh("cylinder_open", cylOpen));
    merge(censusMesh("torus",         torus));
    merge(censusMesh("subdiv_cube_L2", subdivCube));
    merge(censusMesh("post_bevel",    postBevel));

    writefln("[edge.bevel census] TOTAL trials=%d declined=%d (%.1f%%)",
        total.total, total.declined(), 100.0 * total.declined() / total.total);
    static immutable Reason[] knownOrder =
        [Reason.FacesGE3, Reason.PartialFanNotch, Reason.MalformedFan,
         Reason.NoQualifying, Reason.Unclassified];
    foreach (r; knownOrder) {
        immutable n = total.byReason.get(r, 0);
        if (n > 0) writefln("    %-18s %d", r, n);
    }

    // The loud signal task 0445 exists to produce: a refusal this
    // classifier cannot attribute to any known family is a NEW class,
    // and must fail the build rather than pass silently.
    assert(total.byReason.get(Reason.Unclassified, 0) == 0,
        "edge.bevel census found an UNCLASSIFIED refusal family — a decline "
        ~ "that is neither the 3+-faces guard (0438), the partial-fan notch "
        ~ "(0439), nor a malformed-fan skip. This is exactly the 'new class "
        ~ "before the user finds it' signal task 0445 exists to produce — "
        ~ "investigate before touching this baseline.");

    // Baseline, measured 2026-07-20 (task 0445) against the current
    // `bevelEdgesByMask` (post task-0438's 3+-faces guard landing on
    // main, pre task-0436/0439). See the block comment above for why
    // this is an exact match, not a ceiling.
    //
    // The headline finding: 94.7% of trials across a sphere, a capped
    // and an open cylinder, a torus, a level-2 subdivided cube, and a
    // twice-bevel-touched cube ALL decline, and every single decline is
    // the partial-fan-notch guard (task 0439's family) — not the 3+-faces
    // guard (0438, never triggered by any of these manifold meshes) and
    // not a malformed-fan skip. Mechanically this is because a lone
    // selected edge already has K==1 at both endpoints, and the notch
    // guard refuses K==1 at ANY valence>=4 vertex outright (verified by
    // hand-tracing the guard's algebra for a valence-4 fan with one
    // selected slot: exactly one of its two non-selected neighbor slots
    // is "active" and the other isn't, which is precisely the mismatch
    // the guard rejects) — and almost every vertex in these meshes (UV
    // sphere latitude rings, torus, subdivided-cube interior, a
    // cylinder's non-cap rings) has valence>=4. A cube-only test suite
    // cannot see this because a cube has no valence>=4 vertex at all.
    //
    // UPDATE — task 0439 landed the free-end/partial-fan cap and the
    // baseline went 1784 -> 0: every trial on every mesh here is now
    // accepted. The census measures acceptance only, so acceptance was
    // separately checked for SOUNDNESS over the 656 single-edge results:
    // zero non-manifold edges, zero orphans, zero coincident vertices,
    // zero degenerate faces, and no new boundary on any CLOSED mesh. The
    // one mesh whose boundary does grow is `cylinder_open`, which is the
    // reference-verified behaviour for an edge that terminates on a rim
    // (a rim-anchored bevel legitimately lengthens the rim).
    enum size_t BASELINE_TOTAL_TRIALS   = 1_884;
    enum size_t BASELINE_DECLINED       = 0;
    enum size_t BASELINE_FACES_GE3      = 0;
    enum size_t BASELINE_PARTIAL_NOTCH  = 0;
    enum size_t BASELINE_MALFORMED_FAN  = 0;
    enum size_t BASELINE_NO_QUALIFYING  = 0;

    assert(total.total == BASELINE_TOTAL_TRIALS,
        "trial count moved — a mesh primitive above changed shape; update "
        ~ "BASELINE_TOTAL_TRIALS (and re-derive the other baselines) rather "
        ~ "than just this one constant");
    assert(total.declined() == BASELINE_DECLINED,
        "edge.bevel realistic-mesh refusal baseline moved (task 0445). If "
        ~ "this DROPPED, a sibling task (0436/0438/0439) landed a fix — "
        ~ "update the baseline down and note which task in this comment. "
        ~ "If it ROSE, that's a regression.");
    assert(total.byReason.get(Reason.FacesGE3, 0) == BASELINE_FACES_GE3);
    assert(total.byReason.get(Reason.PartialFanNotch, 0) == BASELINE_PARTIAL_NOTCH);
    assert(total.byReason.get(Reason.MalformedFan, 0) == BASELINE_MALFORMED_FAN);
    assert(total.byReason.get(Reason.NoQualifying, 0) == BASELINE_NO_QUALIFYING);
}

// ===========================================================================
// LANE 2 (task 0445, extended scope, 2026-07-20) — SOUNDNESS of what
// edge.bevel ACCEPTS.
//
// WHY. The acceptance census above answers "did it refuse?" — after task
// 0439's free-end cap landed, the answer is "never" (1884/1884 accepted).
// "Stopped refusing" is not "started working": acceptance could just as
// easily mean the kernel now emits BROKEN geometry instead of declining
// honestly. This lane checks the RESULT of every accepted trial for five
// concrete properties a mesh must never lose to a bevel:
//   - no edge left shared by more than two faces,
//   - no vertex left unreferenced by any edge (orphaned),
//   - no two distinct vertices left at the same position,
//   - no zero-area face,
//   - no NEW boundary appearing on a mesh that started closed.
//
// The coincident-vertex threshold reuses `weldCoincidentVertices`'s own
// default `epsSq = 1e-12` (source/mesh.d) rather than inventing a new
// tolerance — this is the kernel's OWN definition of "the same point".
//
// The boundary check is intentionally NOT "boundary count == 0" for every
// mesh: on an already-open mesh (`cylinder_open`) the boundary
// legitimately GROWS when a bevel terminates on a rim (a rim-anchored
// bevel lengthens the rim it touches — verified behaviour, not a bug). So
// the check compares each trial's TEMPLATE's own pre-op boundary edge
// count against the RESULT's: a violation is only counted when the
// template was closed (0 boundary edges) and the result is not.
//
// SCOPE. Runs the SAME full trial matrix as the acceptance census above —
// `generateTrialMasks` below is the acceptance census's own mask-
// generation loop, extracted so both lanes build the IDENTICAL mask set
// from one place instead of two copies that could drift apart. (The
// acceptance census's own loop is left as-is, not rewired to call this —
// zero-behavior-change risk to an already-landed, already-asserted
// baseline, for no measurable benefit.) This is a superset of today's
// hand-probe, which spot-checked only the single-edge sub-matrix (656 of
// the 1884 trials, all five counters zero); this lane pins zero across
// the FULL matrix instead.
// ===========================================================================

/// Identical mask set to the acceptance census's own trial loop (single
/// edge, per-vertex full hub, adjacent pair, and — at valence>=4 —
/// all-but-one and non-adjacent pair). See the block comment above for why
/// this is a read-only extraction, not a shared dependency the acceptance
/// census itself was rewired onto.
private bool[][] generateTrialMasks(const ref Mesh m) {
    bool[][] masks;
    immutable size_t nE = m.edges.length;
    immutable size_t nV = m.vertices.length;
    foreach (i; 0 .. nE) {
        auto mask = new bool[](nE);
        mask[i] = true;
        masks ~= mask;
    }
    foreach (V; 0 .. cast(uint)nV) {
        uint[] vEdges;
        foreach (ei; m.edgesAroundVertex(V)) vEdges ~= ei;
        immutable size_t nEv = vEdges.length;
        if (nEv < 2) continue;
        { auto mask = new bool[](nE); foreach (ei; vEdges) mask[ei] = true; masks ~= mask; }
        { auto mask = new bool[](nE); mask[vEdges[0]] = true; mask[vEdges[1]] = true; masks ~= mask; }
        if (nEv >= 4) { auto mask = new bool[](nE); foreach (ei; vEdges) mask[ei] = true; mask[vEdges[0]] = false; masks ~= mask; }
        if (nEv >= 4) { auto mask = new bool[](nE); mask[vEdges[0]] = true; mask[vEdges[2]] = true; masks ~= mask; }
    }
    return masks;
}

struct SoundnessCounters {
    size_t trialsChecked;       // accepted trials actually checked
    size_t edgeOveruse;         // trials leaving an edge used by >2 faces
    size_t orphanVertices;      // trials leaving a vertex no edge references
    size_t coincidentVertices;  // trials leaving 2+ distinct verts at 1 position
    size_t degenerateFaces;     // trials leaving a zero-area face
    size_t newBoundaryOnClosed; // trials that opened a boundary on a CLOSED input
}

private size_t boundaryEdgeCount(const ref Mesh m) {
    size_t n = 0;
    foreach (u; m.edgeFaceUseCounts()) if (u == 1) ++n;
    return n;
}

private bool hasEdgeOveruse(const ref Mesh m) {
    foreach (u; m.edgeFaceUseCounts()) if (u > 2) return true;
    return false;
}

private bool hasOrphanVertex(const ref Mesh m) {
    auto used = new bool[](m.vertices.length);
    foreach (e; m.edges) { used[e[0]] = true; used[e[1]] = true; }
    foreach (u; used) if (!u) return true;
    return false;
}

private bool hasCoincidentVertices(const ref Mesh m) {
    // Same threshold `weldCoincidentVertices` uses by default (mesh.d) —
    // the kernel's OWN notion of "the same point", not an independently
    // invented tolerance.
    enum double EPS_SQ = 1e-12;
    immutable size_t n = m.vertices.length;
    foreach (i; 0 .. n) foreach (j; i + 1 .. n) {
        immutable double dx = m.vertices[i].x - m.vertices[j].x;
        immutable double dy = m.vertices[i].y - m.vertices[j].y;
        immutable double dz = m.vertices[i].z - m.vertices[j].z;
        if (dx * dx + dy * dy + dz * dz < EPS_SQ) return true;
    }
    return false;
}

private bool hasDegenerateFace(const ref Mesh m) {
    // Newell's method (same idiom already used for winding checks
    // elsewhere in mesh.d, e.g. the hub-cap orientation check around line
    // 9410): the raw (undivided) Newell sum has magnitude 2*area, so its
    // SQUARED magnitude is (2*area)^2 — comparing that against a small
    // epsilon is a divide-free zero-area test.
    enum double NEWELL_MAG2_EPS = 1e-10; // ~ area < 5e-6 at this census's ~1.0-scale meshes
    foreach (f; m.faces) {
        if (f.length < 3) return true; // degenerate by construction
        double nx = 0, ny = 0, nz = 0;
        foreach (i; 0 .. f.length) {
            immutable Vec3 a = m.vertices[f[i]];
            immutable Vec3 b = m.vertices[f[(i + 1) % f.length]];
            nx += cast(double)(a.y - b.y) * (a.z + b.z);
            ny += cast(double)(a.z - b.z) * (a.x + b.x);
            nz += cast(double)(a.x - b.x) * (a.y + b.y);
        }
        if (nx * nx + ny * ny + nz * nz < NEWELL_MAG2_EPS) return true;
    }
    return false;
}

private void checkSoundness(const ref Mesh preTemplate, const ref Mesh post, ref SoundnessCounters sc) {
    ++sc.trialsChecked;
    if (hasEdgeOveruse(post))        ++sc.edgeOveruse;
    if (hasOrphanVertex(post))       ++sc.orphanVertices;
    if (hasCoincidentVertices(post)) ++sc.coincidentVertices;
    if (hasDegenerateFace(post))     ++sc.degenerateFaces;
    if (boundaryEdgeCount(preTemplate) == 0 && boundaryEdgeCount(post) > 0)
        ++sc.newBoundaryOnClosed;
}

private SoundnessCounters soundnessCensusMesh(string label, const ref Mesh m, float width = 0.08f) {
    SoundnessCounters sc;
    foreach (mask; generateTrialMasks(m)) {
        auto clone = cloneMeshForTrial(m);
        immutable size_t processed = clone.bevelEdgesByMask(mask, width);
        if (processed == 0) continue; // acceptance-only lane; declines are the lane above's job
        checkSoundness(m, clone, sc);
    }
    writefln("[edge.bevel census] soundness  %-16s checked=%-5d edgeOveruse=%-2d orphan=%-2d coincident=%-2d degenerate=%-2d newBoundary=%-2d",
        label, sc.trialsChecked, sc.edgeOveruse, sc.orphanVertices, sc.coincidentVertices,
        sc.degenerateFaces, sc.newBoundaryOnClosed);
    return sc;
}

unittest {
    // Same 6 meshes, same construction, as the acceptance census above.
    auto sphere      = makeUvSphereForCensus(6, 10);
    auto cylClosed   = makeCylinderForCensus(12, 2, 1.0f, 1.5f, true);
    auto cylOpen     = makeCylinderForCensus(12, 2, 1.0f, 1.5f, false);
    auto torus       = makeTorusForCensus(12, 8, 1.0f, 0.35f);
    auto subdivCube  = subdivideCube(2);
    auto postBevel   = makePostBevelCubeForCensus();

    SoundnessCounters total;
    void merge(SoundnessCounters c) {
        total.trialsChecked       += c.trialsChecked;
        total.edgeOveruse         += c.edgeOveruse;
        total.orphanVertices      += c.orphanVertices;
        total.coincidentVertices  += c.coincidentVertices;
        total.degenerateFaces     += c.degenerateFaces;
        total.newBoundaryOnClosed += c.newBoundaryOnClosed;
    }

    merge(soundnessCensusMesh("sphere",        sphere));
    merge(soundnessCensusMesh("cylinder",      cylClosed));
    merge(soundnessCensusMesh("cylinder_open", cylOpen));
    merge(soundnessCensusMesh("torus",         torus));
    merge(soundnessCensusMesh("subdiv_cube_L2", subdivCube));
    merge(soundnessCensusMesh("post_bevel",    postBevel));

    writefln("[edge.bevel census] soundness  TOTAL checked=%d edgeOveruse=%d orphan=%d coincident=%d degenerate=%d newBoundary=%d",
        total.trialsChecked, total.edgeOveruse, total.orphanVertices, total.coincidentVertices,
        total.degenerateFaces, total.newBoundaryOnClosed);

    // Baseline, measured 2026-07-20 (task 0445 extension). Pinned EXACTLY,
    // same rationale as the acceptance census: a DROP means a bug got
    // fixed (or a mesh primitive changed), a RISE means a regression.
    enum size_t BASELINE_SOUNDNESS_TRIALS_CHECKED = 1_884;
    enum size_t BASELINE_EDGE_OVERUSE             = 0;
    enum size_t BASELINE_ORPHAN_VERTICES          = 0;
    enum size_t BASELINE_COINCIDENT_VERTICES      = 0;
    enum size_t BASELINE_DEGENERATE_FACES         = 0;
    enum size_t BASELINE_NEW_BOUNDARY_ON_CLOSED   = 0;

    assert(total.trialsChecked == BASELINE_SOUNDNESS_TRIALS_CHECKED,
        "soundness lane checked a different number of accepted trials than the pinned "
        ~ "baseline — a mesh primitive or the acceptance census's trial matrix changed; "
        ~ "re-derive BASELINE_SOUNDNESS_TRIALS_CHECKED (and the counters below) rather "
        ~ "than just this one constant");
    assert(total.edgeOveruse == BASELINE_EDGE_OVERUSE,
        "edge.bevel left an edge shared by >2 faces on an ACCEPTED trial — a soundness "
        ~ "regression, not a refusal-family change; investigate before touching this baseline.");
    assert(total.orphanVertices == BASELINE_ORPHAN_VERTICES,
        "edge.bevel left an orphan (unreferenced) vertex on an ACCEPTED trial — investigate "
        ~ "before touching this baseline.");
    assert(total.coincidentVertices == BASELINE_COINCIDENT_VERTICES,
        "edge.bevel left two distinct vertices at the same position (by the kernel's OWN weld "
        ~ "threshold) on an ACCEPTED trial — investigate before touching this baseline.");
    assert(total.degenerateFaces == BASELINE_DEGENERATE_FACES,
        "edge.bevel left a zero-area face on an ACCEPTED trial — investigate before touching "
        ~ "this baseline.");
    assert(total.newBoundaryOnClosed == BASELINE_NEW_BOUNDARY_ON_CLOSED,
        "edge.bevel opened a NEW boundary on a mesh that started CLOSED, on an ACCEPTED trial "
        ~ "(this does NOT fire for meshes that were already open, e.g. cylinder_open, where "
        ~ "boundary growth at a rim-anchored bevel is expected) — investigate before touching "
        ~ "this baseline.");
}

// ===========================================================================
// LANE 3 (task 0445, extended scope, 2026-07-20) — silently ignored
// PARAMETERS: does Round Level do anything?
//
// WHY. A parameter that is accepted, validated, and silently has NO EFFECT
// on the output is its own defect class — distinct from both refusal
// (lane 1) and unsound output (lane 2). This lane runs every single-edge
// trial at Round Level 0 and at Round Level 1 and counts how often the two
// results are geometrically identical: identical means the parameter did
// nothing observable for that trial.
//
// Today's hand measurement (2026-07-20): Round Level changed nothing for
// sphere/torus/open-cylinder/subdivided-cube (both levels) single-edge
// trials, changed SOME closed-cylinder trials (the ones touching the
// N-gon cap), and changed EVERY plain-cube trial. The mechanism: Round
// Level only affects the well-supported K==3 full-corner-hub shape (a
// plain cube's corners, or a capped cylinder's cap-adjacent rim); every
// other topology in this census exercises a code path Round Level does
// not reach — so the parameter is silently a no-op there. Pinned below so
// a free-end cap at Round Level (once implemented) shows up as these
// numbers MOVING, not as silence.
// ===========================================================================

private struct RoundLevelCensus {
    size_t total;
    size_t identical;
    size_t acceptDeclineMismatch; // RL flipped accept vs. decline outright — always worth a loud look
    size_t differed() const { return total - identical - acceptDeclineMismatch; }
}

private bool meshesGeometricallyIdentical(const ref Mesh a, const ref Mesh b) {
    if (a.vertices.length != b.vertices.length) return false;
    if (a.faces.length    != b.faces.length)    return false;
    enum float EPS = 1e-6f;
    foreach (i; 0 .. a.vertices.length) {
        immutable Vec3 va = a.vertices[i];
        immutable Vec3 vb = b.vertices[i];
        if (fabs(va.x - vb.x) > EPS || fabs(va.y - vb.y) > EPS || fabs(va.z - vb.z) > EPS)
            return false;
    }
    return true;
}

private RoundLevelCensus censusRoundLevelSingleEdge(string label, const ref Mesh m, float width = 0.08f) {
    RoundLevelCensus c;
    immutable size_t nE = m.edges.length;
    foreach (i; 0 .. nE) {
        auto mask = new bool[](nE);
        mask[i] = true;
        auto clone0 = cloneMeshForTrial(m);
        auto clone1 = cloneMeshForTrial(m);
        immutable size_t p0 = clone0.bevelEdgesByMask(mask, width, 0);
        immutable size_t p1 = clone1.bevelEdgesByMask(mask, width, 1);
        ++c.total;
        if ((p0 > 0) != (p1 > 0)) { ++c.acceptDeclineMismatch; continue; }
        if (p0 == 0 && p1 == 0)   { ++c.identical; continue; } // both declined: RL moot either way
        if (meshesGeometricallyIdentical(clone0, clone1)) ++c.identical;
    }
    writefln("[edge.bevel census] roundLevel %-16s trials=%-5d identical=%-5d (%.1f%%)",
        label, c.total, c.identical, c.total ? 100.0 * c.identical / c.total : 0.0);
    return c;
}

unittest {
    // NOT the same 6-mesh set as the other lanes: adds a level-1 subdivided
    // cube and a PLAIN cube — the plain cube in particular is the mesh that
    // shows Round Level having full effect (every corner is a K==3 hub),
    // which none of the other census meshes can show (a cube has no
    // valence>=4 vertex, so it never appears in the acceptance/soundness
    // lanes' primitive set — see their own header comments).
    auto sphere       = makeUvSphereForCensus(6, 10);
    auto cylClosed    = makeCylinderForCensus(12, 2, 1.0f, 1.5f, true);
    auto cylOpen      = makeCylinderForCensus(12, 2, 1.0f, 1.5f, false);
    auto torus        = makeTorusForCensus(12, 8, 1.0f, 0.35f);
    auto subdivCubeL1 = subdivideCube(1);
    auto subdivCubeL2 = subdivideCube(2);
    auto plainCube    = makeCube();

    auto rSphere  = censusRoundLevelSingleEdge("sphere",         sphere);
    auto rCyl     = censusRoundLevelSingleEdge("cylinder",       cylClosed);
    auto rCylOpen = censusRoundLevelSingleEdge("cylinder_open",  cylOpen);
    auto rTorus   = censusRoundLevelSingleEdge("torus",          torus);
    auto rSubL1   = censusRoundLevelSingleEdge("subdiv_cube_L1", subdivCubeL1);
    auto rSubL2   = censusRoundLevelSingleEdge("subdiv_cube_L2", subdivCubeL2);
    auto rCube    = censusRoundLevelSingleEdge("cube",           plainCube);

    assert(rSphere.acceptDeclineMismatch == 0 && rCyl.acceptDeclineMismatch == 0 &&
           rCylOpen.acceptDeclineMismatch == 0 && rTorus.acceptDeclineMismatch == 0 &&
           rSubL1.acceptDeclineMismatch == 0 && rSubL2.acceptDeclineMismatch == 0 &&
           rCube.acceptDeclineMismatch == 0,
        "Round Level flipped accept vs. decline outright for some trial — that is a much "
        ~ "bigger finding than a silently-ignored parameter and needs its own investigation "
        ~ "before this baseline is touched.");

    // Baselines measured 2026-07-20 (task 0445 extension). Pinned EXACTLY:
    // when the free-end cap at Round Level lands, these numbers must MOVE
    // (more trials identical -> fewer, i.e. more topologies observably
    // respond to roundLevel); a rise in "identical" with no code change
    // anywhere near Round Level would itself be worth investigating.
    enum size_t BASELINE_SPHERE_TOTAL    = 110;
    enum size_t BASELINE_SPHERE_IDENT    = 110; // Round Level: no effect at all
    enum size_t BASELINE_CYL_TOTAL       = 60;
    enum size_t BASELINE_CYL_IDENT       = 36; // Round Level affects the 24 cap-adjacent edges
    enum size_t BASELINE_CYLOPEN_TOTAL   = 60;
    enum size_t BASELINE_CYLOPEN_IDENT   = 60; // no cap -> no effect
    enum size_t BASELINE_TORUS_TOTAL     = 192;
    enum size_t BASELINE_TORUS_IDENT     = 192; // no effect
    enum size_t BASELINE_SUBL1_TOTAL     = 48;
    enum size_t BASELINE_SUBL1_IDENT     = 48; // no effect
    enum size_t BASELINE_SUBL2_TOTAL     = 192;
    enum size_t BASELINE_SUBL2_IDENT     = 192; // no effect
    enum size_t BASELINE_CUBE_TOTAL      = 12;
    enum size_t BASELINE_CUBE_IDENT      = 0; // Round Level affects EVERY edge (all corners are K==3 hubs)

    assert(rSphere.total == BASELINE_SPHERE_TOTAL && rSphere.identical == BASELINE_SPHERE_IDENT,
        "roundLevel/sphere baseline moved — update BASELINE_SPHERE_* (task 0445 extension)");
    assert(rCyl.total == BASELINE_CYL_TOTAL && rCyl.identical == BASELINE_CYL_IDENT,
        "roundLevel/cylinder baseline moved — update BASELINE_CYL_* (task 0445 extension)");
    assert(rCylOpen.total == BASELINE_CYLOPEN_TOTAL && rCylOpen.identical == BASELINE_CYLOPEN_IDENT,
        "roundLevel/cylinder_open baseline moved — update BASELINE_CYLOPEN_* (task 0445 extension)");
    assert(rTorus.total == BASELINE_TORUS_TOTAL && rTorus.identical == BASELINE_TORUS_IDENT,
        "roundLevel/torus baseline moved — update BASELINE_TORUS_* (task 0445 extension)");
    assert(rSubL1.total == BASELINE_SUBL1_TOTAL && rSubL1.identical == BASELINE_SUBL1_IDENT,
        "roundLevel/subdiv_cube_L1 baseline moved — update BASELINE_SUBL1_* (task 0445 extension)");
    assert(rSubL2.total == BASELINE_SUBL2_TOTAL && rSubL2.identical == BASELINE_SUBL2_IDENT,
        "roundLevel/subdiv_cube_L2 baseline moved — update BASELINE_SUBL2_* (task 0445 extension)");
    assert(rCube.total == BASELINE_CUBE_TOTAL && rCube.identical == BASELINE_CUBE_IDENT,
        "roundLevel/cube baseline moved — update BASELINE_CUBE_* (task 0445 extension). If this "
        ~ "moved UP (more identical), Round Level started reaching the plain-cube corner shape "
        ~ "differently — investigate. If a free-end-cap-at-Round-Level fix landed and this "
        ~ "stayed put, that fix did not touch the plain-cube path — worth a second look.");
}

// ===========================================================================
// LANE 4 (task 0445, extended scope, 2026-07-20) — MIXED selections.
//
// WHY. This is the exact blind spot that let a crash reach the owner
// before any test did (assert "rounded edge bevel rail must be approved
// before materialization", fixed in 0d1b3be). Every trial mask in the
// acceptance/soundness/round-level lanes above is anchored at ONE vertex
// (a single edge, or a hub/pair/etc. around one vertex) — structurally,
// that matrix can never build a selection that combines a full ring (a
// closed hub) at one vertex with an unrelated free end somewhere else in
// the SAME call, which is precisely the shape that crashed. This lane
// builds four families of genuinely multi-anchor selections:
//   - connected CHAINS of 3-6 edges, walked across several vertices of
//     differing valence and differing K (not just K==1 or K==full-hub),
//   - a full RING at one vertex plus a TRAILING chain extending outward
//     from it (ring and chain share exactly one vertex — connected, but
//     not anchored at a single point),
//   - a full hub at one vertex plus a DISJOINT free end elsewhere (no
//     shared vertex at all — this is the family that crashed),
//   - two entirely DISJOINT clusters combined into one selection.
//
// The specific crash-reproducing case — a full ring at one corner of a
// ONCE-subdivided cube, unioned with a disjoint free end — is included
// unconditionally as its own explicit trial (`cornerHubPlusFreeEndMask`),
// not left to chance sampling: Catmull-Clark subdivision leaves an
// original vertex's valence unchanged (only the newly-inserted face/edge
// points get valence 4), so a once-subdivided cube's 8 original corners
// are still valence-3 hubs — exactly the shape that asserted.
//
// Every ACCEPTED trial here is also run through the lane-2 soundness
// checks (`checkSoundness`): mixed, multi-anchor selections are exactly
// where a new soundness bug is most likely to surface next.
// ===========================================================================

/// Walks a connected chain of `length` edges starting at `startEdge`,
/// extending through unvisited edges sharing an endpoint with the current
/// edge. Deterministic: at each step takes the first unvisited edge found
/// in `edgesAroundVertex` order at either endpoint. May return a chain
/// shorter than `length` if the walk dead-ends (e.g. hits a low-valence
/// boundary vertex) — callers discard chains under 3 edges.
private uint[] walkEdgeChain(const ref Mesh m, uint startEdge, size_t length) {
    uint[] chain = [startEdge];
    bool[uint] visited;
    visited[startEdge] = true;
    uint cur = startEdge;
    while (chain.length < length) {
        immutable uint a = m.edges[cur][0];
        immutable uint b = m.edges[cur][1];
        uint next = uint.max;
        foreach (end; [a, b]) {
            foreach (ei; m.edgesAroundVertex(end)) {
                if (ei !in visited) { next = ei; break; }
            }
            if (next != uint.max) break;
        }
        if (next == uint.max) break;
        chain ~= next;
        visited[next] = true;
        cur = next;
    }
    return chain;
}

private bool[] maskFromEdges(size_t nE, const uint[] edgeIndices) {
    auto mask = new bool[](nE);
    foreach (ei; edgeIndices) if (ei < nE) mask[ei] = true;
    return mask;
}

private bool masksDisjoint(const bool[] a, const bool[] b) {
    immutable size_t n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n) if (a[i] && b[i]) return false;
    return true;
}

/// Connected chains of 3-6 edges, walked from a handful of deterministic,
/// spread-out starting edges — several different vertices of differing
/// valence and differing K along each chain, by construction.
private bool[][] chainMasks(const ref Mesh m) {
    bool[][] masks;
    immutable size_t nE = m.edges.length;
    if (nE == 0) return masks;
    static immutable size_t[] lengths = [3, 4, 5, 6];
    foreach (length; lengths) {
        foreach (size_t startFrac; 0 .. 4) {
            immutable uint start = cast(uint)((startFrac * nE) / 4 % nE);
            auto chain = walkEdgeChain(m, start, length);
            if (chain.length < 3) continue;
            masks ~= maskFromEdges(nE, chain);
        }
    }
    return masks;
}

/// A full ring (every incident edge — a closed hub) at one vertex, plus a
/// short chain extending outward from that ring — connected (they share
/// exactly the ring's near vertex... no: the chain extends from the FAR
/// endpoint of one ring edge, so ring and chain share zero edges but the
/// combined selection is still one connected piece through that far
/// vertex), never anchored at a single point the way the acceptance
/// census's per-vertex matrix is.
private bool[][] ringPlusTrailingMasks(const ref Mesh m) {
    bool[][] masks;
    immutable size_t nE = m.edges.length;
    immutable size_t nV = m.vertices.length;
    if (nV == 0 || nE == 0) return masks;
    foreach (size_t frac; 0 .. 4) {
        immutable uint V = cast(uint)((frac * nV) / 4 % nV);
        uint[] ring;
        foreach (ei; m.edgesAroundVertex(V)) ring ~= ei;
        if (ring.length < 3) continue;

        auto mask = new bool[](nE);
        bool[uint] visited;
        foreach (ei; ring) { mask[ei] = true; visited[ei] = true; }

        uint cur = ring[0];
        size_t added = 0;
        while (added < 3) {
            immutable uint a = m.edges[cur][0];
            immutable uint b = m.edges[cur][1];
            uint next = uint.max;
            foreach (end; [a, b]) {
                foreach (ei; m.edgesAroundVertex(end)) {
                    if (ei !in visited) { next = ei; break; }
                }
                if (next != uint.max) break;
            }
            if (next == uint.max) break;
            mask[next] = true;
            visited[next] = true;
            cur = next;
            ++added;
        }
        masks ~= mask;
    }
    return masks;
}

/// A full hub at `hubVertex` plus ONE edge that touches neither the hub
/// vertex nor any of its ring-adjacent neighbors — a genuinely DISJOINT
/// free end, zero shared vertices with the hub. This is the exact shape
/// that crashed (see the lane's header comment).
private bool[] hubPlusDisjointFreeEndMask(const ref Mesh m, uint hubVertex) {
    immutable size_t nE = m.edges.length;
    auto mask = new bool[](nE);
    foreach (ei; m.edgesAroundVertex(hubVertex)) mask[ei] = true;

    auto touched = new bool[](m.vertices.length);
    touched[hubVertex] = true;
    foreach (ei; 0 .. nE)
        if (mask[ei]) { touched[m.edges[ei][0]] = true; touched[m.edges[ei][1]] = true; }

    foreach (ei; 0 .. nE) {
        if (mask[ei]) continue;
        if (touched[m.edges[ei][0]] || touched[m.edges[ei][1]]) continue;
        mask[ei] = true;
        break;
    }
    return mask;
}

private bool[][] hubPlusFreeEndMasks(const ref Mesh m) {
    bool[][] masks;
    immutable size_t nV = m.vertices.length;
    if (nV == 0) return masks;
    foreach (size_t frac; 0 .. 4) {
        immutable uint V = cast(uint)((frac * nV) / 4 % nV);
        size_t nEv = 0;
        foreach (ei; m.edgesAroundVertex(V)) ++nEv;
        if (nEv < 3) continue;
        masks ~= hubPlusDisjointFreeEndMask(m, V);
    }
    return masks;
}

/// Two entirely disjoint hub clusters (vertex 0 and the vertex at the
/// opposite "end" of the index range), combined into ONE selection —
/// skipped (yields no mask) if the two hubs happen to share an edge on a
/// small mesh, rather than silently testing a non-disjoint case under a
/// "disjoint clusters" label.
private bool[][] disjointClusterMasks(const ref Mesh m) {
    bool[][] masks;
    immutable size_t nE = m.edges.length;
    immutable size_t nV = m.vertices.length;
    if (nV < 4 || nE == 0) return masks;

    bool[] hubMaskAt(uint V) {
        auto mask = new bool[](nE);
        foreach (ei; m.edgesAroundVertex(V)) mask[ei] = true;
        return mask;
    }

    immutable uint Va = 0;
    immutable uint Vb = cast(uint)(nV / 2);
    if (Va == Vb) return masks;
    auto ma = hubMaskAt(Va);
    auto mb = hubMaskAt(Vb);
    if (masksDisjoint(ma, mb)) {
        auto combined = new bool[](nE);
        foreach (i; 0 .. nE) combined[i] = ma[i] || mb[i];
        masks ~= combined;
    }
    return masks;
}

/// The SPECIFIC shape that crashed (see the lane's header comment): a full
/// ring at one of the mesh's valence-3 vertices, unioned with a disjoint
/// free end. Finds its anchor by scanning for a valence-3 vertex rather
/// than assuming an index — `subdivideCube`'s vertex order after its OSD
/// preview rebuild (source/mesh.d) is not part of this module's contract,
/// so an index assumption would be fragile in a way a topological search
/// is not.
private bool[] cornerHubPlusFreeEndMask(const ref Mesh m) {
    immutable size_t nV = m.vertices.length;
    uint corner = uint.max;
    foreach (V; 0 .. cast(uint)nV) {
        size_t nEv = 0;
        foreach (ei; m.edgesAroundVertex(V)) ++nEv;
        if (nEv == 3) { corner = V; break; }
    }
    assert(corner != uint.max,
        "cornerHubPlusFreeEndMask: no valence-3 vertex found on this mesh — "
        ~ "subdivideCube's original-corner-keeps-its-valence assumption no "
        ~ "longer holds, and this fixture needs a new anchor strategy to keep "
        ~ "reproducing the 0d1b3be crash shape (full ring + disjoint free end)");
    return hubPlusDisjointFreeEndMask(m, corner);
}

private void runMixedTrial(const ref Mesh template_, const bool[] mask, ref Census census,
                            ref SoundnessCounters sc, float width) {
    auto clone = cloneMeshForTrial(template_);
    immutable size_t processed = clone.bevelEdgesByMask(mask, width);
    if (processed > 0) {
        census.record(Reason.Processed);
        checkSoundness(template_, clone, sc);
        return;
    }
    census.record(classifyDecline(template_, mask));
}

private struct MixedResult {
    Census census;
    SoundnessCounters soundness;
}

private MixedResult mixedSelectionCensusMesh(string label, const ref Mesh m, float width = 0.08f) {
    bool[][] masks;
    masks ~= chainMasks(m);
    masks ~= ringPlusTrailingMasks(m);
    masks ~= hubPlusFreeEndMasks(m);
    masks ~= disjointClusterMasks(m);

    MixedResult r;
    foreach (mask; masks) runMixedTrial(m, mask, r.census, r.soundness, width);

    immutable size_t violations = r.soundness.edgeOveruse + r.soundness.orphanVertices +
        r.soundness.coincidentVertices + r.soundness.degenerateFaces + r.soundness.newBoundaryOnClosed;
    writefln("[edge.bevel census] mixed      %-16s trials=%-5d declined=%-5d soundness-violations=%-3d",
        label, r.census.total, r.census.declined(), violations);
    static immutable Reason[] knownOrder =
        [Reason.FacesGE3, Reason.PartialFanNotch, Reason.MalformedFan, Reason.NoQualifying, Reason.Unclassified];
    foreach (rr; knownOrder) {
        immutable n = r.census.byReason.get(rr, 0);
        if (n > 0) writefln("    %-18s %d", rr, n);
    }
    return r;
}

unittest {
    auto sphere       = makeUvSphereForCensus(6, 10);
    auto cylClosed    = makeCylinderForCensus(12, 2, 1.0f, 1.5f, true);
    auto cylOpen      = makeCylinderForCensus(12, 2, 1.0f, 1.5f, false);
    auto torus        = makeTorusForCensus(12, 8, 1.0f, 0.35f);
    auto subdivCubeL2 = subdivideCube(2);
    auto postBevel    = makePostBevelCubeForCensus();
    auto subdivCubeL1 = subdivideCube(1); // anchor mesh for the crash-repro trial specifically

    Census total;
    SoundnessCounters totalSound;
    void merge(MixedResult r) {
        total.total += r.census.total;
        foreach (rr, n; r.census.byReason) total.byReason[rr] = total.byReason.get(rr, 0) + n;
        totalSound.trialsChecked       += r.soundness.trialsChecked;
        totalSound.edgeOveruse         += r.soundness.edgeOveruse;
        totalSound.orphanVertices      += r.soundness.orphanVertices;
        totalSound.coincidentVertices  += r.soundness.coincidentVertices;
        totalSound.degenerateFaces     += r.soundness.degenerateFaces;
        totalSound.newBoundaryOnClosed += r.soundness.newBoundaryOnClosed;
    }

    merge(mixedSelectionCensusMesh("sphere",         sphere));
    merge(mixedSelectionCensusMesh("cylinder",       cylClosed));
    merge(mixedSelectionCensusMesh("cylinder_open",  cylOpen));
    merge(mixedSelectionCensusMesh("torus",          torus));
    merge(mixedSelectionCensusMesh("subdiv_cube_L2", subdivCubeL2));
    merge(mixedSelectionCensusMesh("post_bevel",     postBevel));
    merge(mixedSelectionCensusMesh("subdiv_cube_L1", subdivCubeL1));

    // The explicit crash-repro trial (see the lane header comment): NOT
    // left to `hubPlusFreeEndMasks`'s sampling grid landing on a valence-3
    // corner by chance — run unconditionally so it is permanently in the
    // set regardless of where that grid falls.
    {
        auto mask = cornerHubPlusFreeEndMask(subdivCubeL1);
        runMixedTrial(subdivCubeL1, mask, total, totalSound, 0.08f);
    }

    writefln("[edge.bevel census] mixed      TOTAL trials=%d declined=%d", total.total, total.declined());
    static immutable Reason[] knownOrder =
        [Reason.FacesGE3, Reason.PartialFanNotch, Reason.MalformedFan, Reason.NoQualifying, Reason.Unclassified];
    foreach (r; knownOrder) {
        immutable n = total.byReason.get(r, 0);
        if (n > 0) writefln("    %-18s %d", r, n);
    }

    // Same loud signal as the acceptance census: a refusal this
    // classifier cannot attribute to a known family is a NEW class.
    assert(total.byReason.get(Reason.Unclassified, 0) == 0,
        "edge.bevel MIXED-selection census found an UNCLASSIFIED refusal family — investigate "
        ~ "before touching this baseline (task 0445 extension).");

    // Baselines measured 2026-07-20 (task 0445 extension).
    // 176 = 7 meshes x 25 sampled masks (chain x16 + ring+trailing x4 +
    // hub+freeEnd x4 + disjoint-clusters x1) + 1 explicit crash-repro trial.
    // Every trial is ACCEPTED (0d1b3be holds) and every accepted trial is
    // sound — the exact selection shape that used to crash now measures
    // clean on all five soundness counters.
    enum size_t BASELINE_MIXED_TOTAL       = 176;
    enum size_t BASELINE_MIXED_DECLINED    = 0;
    enum size_t BASELINE_MIXED_SOUND_CHECKED     = 176;
    enum size_t BASELINE_MIXED_EDGE_OVERUSE      = 0;
    enum size_t BASELINE_MIXED_ORPHAN_VERTICES   = 0;
    enum size_t BASELINE_MIXED_COINCIDENT_VERTS  = 0;
    enum size_t BASELINE_MIXED_DEGENERATE_FACES  = 0;
    enum size_t BASELINE_MIXED_NEW_BOUNDARY      = 0;

    assert(total.total == BASELINE_MIXED_TOTAL,
        "mixed-selection trial count moved — a mesh primitive or a mask-generator above "
        ~ "changed shape; update BASELINE_MIXED_TOTAL (and re-derive the rest) rather than "
        ~ "just this one constant");
    assert(total.declined() == BASELINE_MIXED_DECLINED,
        "edge.bevel mixed-selection refusal baseline moved (task 0445 extension). If this "
        ~ "DROPPED, a fix landed — update the baseline down and note which task. If it ROSE, "
        ~ "that's a regression — this is exactly the class of selection (full ring at one "
        ~ "vertex + free ends at others) that crashed before any test caught it.");
    assert(totalSound.trialsChecked == BASELINE_MIXED_SOUND_CHECKED,
        "mixed-selection soundness lane checked a different number of accepted trials than "
        ~ "pinned — update BASELINE_MIXED_SOUND_CHECKED (task 0445 extension)");
    assert(totalSound.edgeOveruse == BASELINE_MIXED_EDGE_OVERUSE,
        "edge.bevel left an edge shared by >2 faces on an ACCEPTED mixed-selection trial — "
        ~ "investigate before touching this baseline.");
    assert(totalSound.orphanVertices == BASELINE_MIXED_ORPHAN_VERTICES,
        "edge.bevel left an orphan vertex on an ACCEPTED mixed-selection trial — investigate "
        ~ "before touching this baseline.");
    assert(totalSound.coincidentVertices == BASELINE_MIXED_COINCIDENT_VERTS,
        "edge.bevel left coincident vertices on an ACCEPTED mixed-selection trial — investigate "
        ~ "before touching this baseline.");
    assert(totalSound.degenerateFaces == BASELINE_MIXED_DEGENERATE_FACES,
        "edge.bevel left a degenerate face on an ACCEPTED mixed-selection trial — investigate "
        ~ "before touching this baseline.");
    assert(totalSound.newBoundaryOnClosed == BASELINE_MIXED_NEW_BOUNDARY,
        "edge.bevel opened a new boundary on a CLOSED mixed-selection trial — investigate "
        ~ "before touching this baseline.");
}
