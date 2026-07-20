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

import mesh;
import math : Vec3;

version (unittest):

import std.stdio : writefln;
import std.math : PI, cos, sin;

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
    enum size_t BASELINE_TOTAL_TRIALS   = 1_884;
    enum size_t BASELINE_DECLINED       = 1_784;
    enum size_t BASELINE_FACES_GE3      = 0;
    enum size_t BASELINE_PARTIAL_NOTCH  = 1_784;
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
