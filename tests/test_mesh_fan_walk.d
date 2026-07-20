// Task 0447 — vertex-fan-walk auditor (KEEP-TWIN).
//
// `buildLoops` pairs half-edge twins by undirected-edge identity without
// checking direction, so on inconsistently-wound faces a SAME-direction dart
// pair sharing an edge is linked as "twins". The vertex fan walk then crosses
// such an edge and yields elements based at the OTHER endpoint (a foreign
// edge/face/neighbour). The KEEP-TWIN fix leaves the twin populated (the
// winding-repair tool reads it) and instead flags the affected vertices NOT
// `vertexFanOrdered`, serving them from a complete CSR fallback.
//
// This is a pure kernel test (no HTTP): it walks EVERY vertex / edge of a set
// of topologies and asserts the walk is sound — only incident elements, no
// duplicates, correct counts, and a slot-adjacency oracle that verifies the
// predicate `vertexFanOrdered` itself against `faces[]`. See
// doc/vertex_fan_walk_foreign_edge_plan.md §Phase 0 / §8.

import mesh;
import math;
import std.algorithm : sort;

void main() {}

// ---------------------------------------------------------------------------
// Auditor
// ---------------------------------------------------------------------------

struct AuditResult {
    size_t foreignEdges, foreignFaces, foreignNbrs; // element not incident to V
    size_t selfLoopNbrs;                            // neighbour == V
    size_t dupEdges, dupFaces, dupNbrs;             // repeated element in a fan
    size_t badAnchor;                               // vertLoop[V] not based at V
    size_t slotViolations;                          // slot lockstep vs faces[]
    size_t unorderedVerts;                          // !vertexFanOrdered
    size_t gateEdges;                               // edge with an unordered endpoint
    size_t faeUnder, faeOver;                       // facesAroundEdge miscount
    size_t faeForeign;                              // facesAroundEdge foreign face
    size_t sameDirPairs;                            // same-direction twin pairs
}

private void addUnique(ref uint[] arr, uint v) {
    foreach (x; arr) if (x == v) return;
    arr ~= v;
}

private size_t countDups(const(uint)[] xs) {
    size_t dups = 0;
    foreach (i; 0 .. xs.length)
        foreach (j; i + 1 .. xs.length)
            if (xs[i] == xs[j]) { ++dups; break; }
    return dups;
}

// Undirected: does face fi have (a,b) as a consecutive vertex pair?
private bool faceHasUndirectedEdge(const ref Mesh m, uint fi, uint a, uint b) {
    const uint[] f = m.faces[fi];
    size_t N = f.length;
    foreach (j; 0 .. N) {
        uint x = f[j], y = f[(j + 1) % N];
        if ((x == a && y == b) || (x == b && y == a)) return true;
    }
    return false;
}

// The V-incident edge indices of face fi (via consecutive vertex pairs).
private uint[] vIncidentFaceEdges(const ref Mesh m, uint fi, uint V) {
    uint[] res;
    const uint[] f = m.faces[fi];
    size_t N = f.length;
    foreach (j; 0 .. N) {
        uint a = f[j], b = f[(j + 1) % N];
        if (a == V || b == V) {
            uint ei = m.edgeIndex(a, b);
            if (ei != ~0u) addUnique(res, ei);
        }
    }
    return res;
}

private bool edgeSetEq(uint[] a, uint[] b) {
    if (a.length != b.length) return false;
    a = a.dup; b = b.dup;
    a.sort(); b.sort();
    return a == b;
}

AuditResult auditMesh(ref Mesh m) {
    AuditResult r;

    // Same-direction twin pair count (each pair counted once).
    foreach (li; 0 .. m.loops.length) {
        uint tw = m.loops[li].twin;
        if (tw != ~0u && cast(uint)li < tw && m.loops[tw].vert == m.loops[li].vert)
            ++r.sameDirPairs;
    }

    foreach (uint V; 0 .. cast(uint)m.vertices.length) {
        uint[] vF, vE, vN;
        foreach (fi; m.facesAroundVertex(V)) vF ~= cast(uint)fi;
        foreach (ei; m.edgesAroundVertex(V)) vE ~= ei;
        foreach (nb; m.verticesAroundVertex(V)) vN ~= nb;

        // (i)/(ii)/(iii) incidence — no foreign elements.
        foreach (ei; vE)
            if (m.edges[ei][0] != V && m.edges[ei][1] != V) ++r.foreignEdges;
        foreach (fi; vF) {
            bool has = false;
            foreach (x; m.faces[fi]) if (x == V) { has = true; break; }
            if (!has) ++r.foreignFaces;
        }
        foreach (nb; vN) {
            if (nb == V) ++r.selfLoopNbrs;
            else if (m.edgeIndex(V, nb) == ~0u) ++r.foreignNbrs;
        }

        // (v) no duplicates.
        r.dupEdges += countDups(vE);
        r.dupFaces += countDups(vF);
        r.dupNbrs  += countDups(vN);

        // (iv) vertLoop[V] based at V (non-isolated vertices).
        if (V < m.vertLoop.length && m.vertLoop[V] != ~0u)
            if (m.loops[m.vertLoop[V]].vert != V) ++r.badAnchor;

        if (!m.vertexFanOrdered(V)) { ++r.unorderedVerts; continue; }

        // (vi) slot-adjacency oracle on ORDERED fans: face f_k must be bordered
        // by exactly the two V-incident edge slots {k, k+1}. CLOSED fan
        // (nE==d) wraps; OPEN fan (nE==d+1) runs e_0..e_d with no wrap.
        int d = cast(int)vF.length, nE = cast(int)vE.length;
        bool openFan = (nE == d + 1);
        if (d < 2 || (nE != d && !openFan)) continue; // malformed shape — skip
        foreach (k; 0 .. d) {
            int kr = openFan ? (k + 1) : ((k + 1) % nE);
            uint[] want = [vE[k], vE[kr]];
            uint[] got  = vIncidentFaceEdges(m, vF[k], V);
            if (!edgeSetEq(want, got)) ++r.slotViolations;
        }
    }

    // Edge auditor: facesAroundEdge by COUNT vs a direct faces[] enumeration,
    // plus foreign-face detection and the endpoint-status gate coverage.
    foreach (uint ei; 0 .. cast(uint)m.edges.length) {
        uint va = m.edges[ei][0], vb = m.edges[ei][1];
        if (!m.vertexFanOrdered(va) || !m.vertexFanOrdered(vb)) ++r.gateEdges;

        size_t refCnt = 0;
        foreach (uint fi; 0 .. cast(uint)m.faces.length)
            if (faceHasUndirectedEdge(m, fi, va, vb)) ++refCnt;
        size_t refCapped = refCnt > 2 ? 2 : refCnt;   // uint[2] contract (§5.2)

        size_t got = 0;
        foreach (fi; m.facesAroundEdge(ei)) {
            ++got;
            if (!faceHasUndirectedEdge(m, fi, va, vb)) ++r.faeForeign;
        }
        if (got < refCapped) r.faeUnder += (refCapped - got);
        if (got > refCapped) r.faeOver  += (got - refCapped);
    }
    return r;
}

// Assert every soundness field is zero (foreign / dup / anchor / slot / fae).
private void assertSound(ref AuditResult r, string label) {
    import std.conv : to;
    assert(r.foreignEdges == 0, label ~ ": foreign edges " ~ r.foreignEdges.to!string);
    assert(r.foreignFaces == 0, label ~ ": foreign faces " ~ r.foreignFaces.to!string);
    assert(r.foreignNbrs  == 0, label ~ ": foreign neighbours " ~ r.foreignNbrs.to!string);
    assert(r.selfLoopNbrs == 0, label ~ ": self-loop neighbours " ~ r.selfLoopNbrs.to!string);
    assert(r.dupEdges == 0, label ~ ": duplicate edges " ~ r.dupEdges.to!string);
    assert(r.dupFaces == 0, label ~ ": duplicate faces " ~ r.dupFaces.to!string);
    assert(r.dupNbrs  == 0, label ~ ": duplicate neighbours " ~ r.dupNbrs.to!string);
    assert(r.badAnchor == 0, label ~ ": vertLoop not based at V " ~ r.badAnchor.to!string);
    assert(r.slotViolations == 0, label ~ ": slot-adjacency violations " ~ r.slotViolations.to!string);
    assert(r.faeUnder == 0, label ~ ": facesAroundEdge undercounts " ~ r.faeUnder.to!string);
    assert(r.faeOver  == 0, label ~ ": facesAroundEdge overcounts " ~ r.faeOver.to!string);
    assert(r.faeForeign == 0, label ~ ": facesAroundEdge foreign faces " ~ r.faeForeign.to!string);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// Two quads sharing spine (0,1), wound the SAME direction across it. V=0 and
// V=1 are the inconsistently-wound endpoints. (matches mesh.d's hinge())
private Mesh makeHinge() {
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 1), Vec3(0, 0, -1),
        Vec3(1, 0, 1), Vec3(1, 0, -1),
        Vec3(-0.5f, 0.866025f, 1), Vec3(-0.5f, 0.866025f, -1),
    ];
    m.addFace([0u, 2u, 3u, 1u]);
    m.addFace([0u, 4u, 5u, 1u]);
    m.buildLoops();
    return m;
}

// The SAME two quads wound CONSISTENTLY across the spine — a clean control.
private Mesh makeConsistentHinge() {
    Mesh m;
    m.vertices = [
        Vec3(0, 0, 1), Vec3(0, 0, -1),
        Vec3(1, 0, 1), Vec3(1, 0, -1),
        Vec3(-0.5f, 0.866025f, 1), Vec3(-0.5f, 0.866025f, -1),
    ];
    m.addFace([0u, 2u, 3u, 1u]);
    m.addFace([0u, 1u, 5u, 4u]);   // reversed across (0,1) => consistent
    m.buildLoops();
    return m;
}

// makeCube with faces `flip` reversed (deterministic corruption).
private Mesh makeCubeFlipped(const size_t[] flip) {
    Mesh m = makeCube();
    bool[] mask = new bool[](m.faces.length);
    foreach (fi; flip) mask[fi] = true;
    m.flipFacesByMask(mask);  // re-syncs loops
    return m;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

unittest { // §2: clean corpus — sound, fully ordered, gate catches ZERO edges.
    Mesh[] corpus = [makeCube(), makeConsistentHinge(),
                     subdivideCube(1), subdivideCube(2)];
    string[] names = ["cube", "consistent_hinge", "subdiv_cube_L1", "subdiv_cube_L2"];
    foreach (i, ref m; corpus) {
        auto r = auditMesh(m);
        assertSound(r, names[i]);
        assert(r.unorderedVerts == 0, names[i] ~ ": clean mesh must be fully fan-ordered");
        assert(r.gateEdges == 0, names[i] ~ ": gate must catch 0 edges on a clean mesh");
        assert(r.sameDirPairs == 0, names[i] ~ ": clean mesh has no same-direction pairs");
    }
}

unittest { // §2: hinge — the motivating defect. Sound after the fix; exactly
           // the two spine endpoints are unordered; exactly one same-dir pair.
    auto m = makeHinge();
    auto r = auditMesh(m);
    assertSound(r, "hinge");
    assert(r.sameDirPairs == 1, "hinge: exactly one same-direction pair (the spine)");
    assert(r.unorderedVerts == 2, "hinge: exactly the two spine endpoints unordered");
    assert(!m.vertexFanOrdered(0) && !m.vertexFanOrdered(1), "hinge: V0,V1 unordered");
    assert(m.vertexFanOrdered(2) && m.vertexFanOrdered(3)
        && m.vertexFanOrdered(4) && m.vertexFanOrdered(5), "hinge: page tips ordered");
    // facesAroundEdge on the spine recovers BOTH faces.
    uint spine = m.edgeIndex(0, 1);
    assert(spine != ~0u, "hinge: spine edge exists");
    size_t nf = 0; foreach (_; m.facesAroundEdge(spine)) ++nf;
    assert(nf == 2, "hinge: facesAroundEdge(spine) must recover both faces");
}

unittest { // §2: inverted cubes. Even a CLOSED manifold is not immune —
           // flipping faces creates same-direction shared edges. Sound after
           // the fix; the defect IS exercised (some vertices go unordered).
    foreach (flip; [[2UL], [0UL, 5UL], [0UL, 1UL, 2UL, 3UL, 5UL]]) {
        Mesh m = makeCubeFlipped(cast(size_t[])flip);
        auto r = auditMesh(m);
        import std.conv : to;
        assertSound(r, "cube_flipped_" ~ flip.length.to!string);
        assert(r.sameDirPairs > 0, "cube_flipped: winding defect must be present");
        assert(r.unorderedVerts > 0, "cube_flipped: some vertices must be unordered");
        // Every internal cube edge is shared by exactly two faces; with both
        // endpoints possibly unordered the endpoint-gated CSR must still
        // recover both (measured undercount before the §5 remediation).
    }
}

// Build a fresh corpus base by index (0=cube, 1=subdiv L1, 2=subdiv L2) so each
// generative variant starts from an uncorrupted mesh.
private Mesh stripBase(size_t bi) {
    return bi == 0 ? makeCube() : subdivideCube(cast(int)bi);
}

unittest { // §8: generative strip — a deterministic LCG picks N distinct faces
           // to flip on several bases; the auditor must stay strictly zero on
           // EVERY variant. The pre-fix baseline was nonzero (the cube already
           // showed foreign faces + facesAroundEdge undercounts), so this pins
           // the whole defect class to zero across a generated family.
    import std.conv : to;
    string[] bnames = ["cube", "subdiv_L1", "subdiv_L2"];
    foreach (bi; 0 .. 3) {
        foreach (N; [1, 2, 5]) {
            Mesh m = stripBase(bi);
            uint nF = cast(uint)m.faces.length;
            bool[] mask = new bool[](nF);
            uint seed = 0x0447u + cast(uint)(bi * 97 + N);
            int placed = 0, guard = 0;
            while (placed < N && guard < 4096) {
                seed = seed * 1103515245u + 12345u;
                uint pick = (seed >> 8) % nF;
                if (!mask[pick]) { mask[pick] = true; ++placed; }
                ++guard;
            }
            m.flipFacesByMask(mask);
            auto r = auditMesh(m);
            assertSound(r, "strip_" ~ bnames[bi] ~ "_N" ~ N.to!string);
        }
    }
}

unittest { // §7 side-finding: assigning faces directly (bypassing addFace) and
           // calling buildLoops() leaves edges[] EMPTY — buildLoops re-syncs
           // half-edge loops but does NOT rebuild the edge set. Callers that
           // set faces directly must call rebuildEdges()/rebuildEdgesFromFaces()
           // (scene.loadMesh does). Documented, not "fixed" — buildLoops's
           // semantics are unchanged.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f),
        Vec3(0.5f, 0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
    ];
    m.faces._store = [[0u, 3u, 2u, 1u]];
    m.buildLoops();
    assert(m.edges.length == 0,
        "direct faces._store + buildLoops leaves edges empty (footgun §7)");
    // Correct recovery: rebuild the edge set FIRST, then re-sync the loops
    // against it (rebuildEdgesFromFaces leaves loops/loopEdge stale — this is
    // the exact sequence scene.loadMesh uses). After it the fan walk is sound.
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    assert(m.edges.length == 4, "single quad has 4 edges after rebuild");
    auto r = auditMesh(m);
    assertSound(r, "sec7_after_rebuild");
}
