// Module unittests for the edge/vertex bevel kernel family
// (`mesh_ops.bevel`, mixed into `struct Mesh` as `MeshBevelOps`).
//
// Moved VERBATIM out of source/mesh_ops/bevel.d by task 0706, when the `tests`
// dub configuration gave module unittests somewhere to live other than
// `source/`. Nothing about the assertions changed -- the blocks are in their
// original order, the `version (unittest)` helpers they call came with them,
// and the selective imports below are the ones the blocks used to resolve
// through their old module scope (`mesh`, `math`) plus the ones the old file
// already listed for them.
//
// Everything here reaches Mesh through its PUBLIC surface: the mixin's methods
// and fields are public members of Mesh, and `makeCube`/`makeDisk` and friends
// are public factories. That is why the whole test region could move; a block
// that needed a private member would have had to stay behind.
module tests.unit.mesh_ops.bevel_test;

import mesh;
import math;
import tests.unit.fixtures;

// ===========================================================================
// Module unittests. Moved VERBATIM from mesh.d, where they lived until the
// mesh.d decomposition split this kernel family out: a test belongs in the
// module holding the code it asserts on. Blocks are in their original mesh.d
// order; the `version (unittest)` helpers they call moved with them (no
// caller for those helpers stayed behind in mesh.d, so nothing is duplicated).
//
// The selective imports below mirror mesh.d's module-scope import list. A
// moved block used to resolve these bare names through its old home's
// module scope; mirroring them HERE keeps every block byte-identical to the
// version that ran in mesh.d instead of editing the tests.
// ===========================================================================
version (unittest) {
    import std.math : sqrt;
    import mesh_edit_delta : MeshEditTracker, MeshEditScope;
}

unittest { // bevelEdgesByMask: cube edge (6,7) between +Y and +Z faces, width=0.1
    import std.math : abs, sqrt;
    // Cube verts: 6=(0.5,0.5,0.5), 7=(-0.5,0.5,0.5).
    // Edge (6,7) is shared by face1=[4,5,6,7](+Z) and face4=[3,7,6,2](+Y).
    // After bevel: 10 verts (8+4-2), 7 faces, fv-dist {4:5,5:2}.
    // Chamfer centroid (0, 0.45, 0.45), chamfer normal points in (+Y+Z) dir.
    auto m = makeCube();

    // Find edge (6,7)
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a==6&&b==7)||(a==7&&b==6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "edge (6,7) not found in cube");

    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;

    // width=0 must be no-op
    assert(m.bevelEdgesByMask(mask, 0.0f) == 0, "width=0 must be no-op");
    assert(m.vertices.length == 8);
    assert(m.faces.length    == 6);

    assert(m.bevelEdgesByMask(mask, 0.1f) == 1, "should process 1 edge");
    assert(m.vertices.length == 10, "expected 10 verts");
    assert(m.faces.length    == 7,  "expected 7 faces");

    // fv-dist: 5 quads (4-gons) + 2 pentagons (5-gons)
    int[int] fvd;
    foreach (f; m.faces) { int n = cast(int)f.length; fvd[n]++; }
    assert(fvd.get(4,0)==5 && fvd.get(5,0)==2, "fv-dist should be {4:5,5:2}");

    // Chamfer centroid = (0, 0.45, 0.45)
    // The chamfer face is the newly-selected face.
    Vec3 cen = Vec3(0,0,0);
    int chamferCount = 0;
    foreach (fi; 0..m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        foreach (vi; m.faces[fi]) cen = cen + m.vertices[vi];
        chamferCount = cast(int)m.faces[fi].length;
        cen = cen * (1.0f / cast(float)chamferCount);
        break;
    }
    assert(chamferCount == 4, "chamfer should be a quad");
    assert(abs(cen.x) < 1e-3f && abs(cen.y-0.45f)<1e-3f && abs(cen.z-0.45f)<1e-3f,
           "chamfer centroid should be near (0,0.45,0.45)");

    // Winding: chamfer normal should point outward (dot with (0,1,1)/sqrt(2) > 0.9)
    Vec3 n = m.faceNormal(cast(uint)(m.faces.length-1));
    // The chamfer is the last face added — or we find it by selection.
    // Use the selected face.
    foreach (fi; 0..m.faces.length) {
        if (!m.isFaceSelected(fi)) continue;
        n = m.faceNormal(cast(uint)fi);
        break;
    }
    float dot = n.y * (1.0f/sqrt(2.0f)) + n.z * (1.0f/sqrt(2.0f));
    assert(dot > 0.9f, "chamfer normal should point outward (+Y+Z direction)");
}

// Find the chamfer face produced by the fixture above, by its known centroid
// (0, 0.45, 0.45) — geometry-keyed, not selection-keyed, so it works even
// when the chamfer itself ends up Hidden (a hidden face cannot be selected,
// §3.1 — selection would find nothing in that case).
version (unittest) private int findChamferByCentroid(ref Mesh m) {
    import std.math : abs;
    foreach (fi; 0 .. m.faces.length) {
        if (m.faces[fi].length != 4) continue;
        Vec3 c = Vec3(0, 0, 0);
        foreach (vi; m.faces[fi]) c = c + m.vertices[vi];
        c = c * (1.0f / 4.0f);
        if (abs(c.x) < 1e-3f && abs(c.y - 0.45f) < 1e-3f && abs(c.z - 0.45f) < 1e-3f)
            return cast(int)fi;
    }
    return -1;
}

unittest { // S4/S5 code review (task 0613 §4.2): the chamfer strip's
    // multi-source Hide combine is ALL-source AND (Mesh.combineFaceMarksWords),
    // not the ANY-source OR that Subpatch still (correctly) uses. Same
    // fixture as the byte-identical bevel test above: cube edge (6,7) shared
    // by face1=[4,5,6,7](+Z) and face4=[3,7,6,2](+Y).
    //
    // Discriminator: hide ONLY face1, leave face4 visible, then bevel the
    // shared edge. An ANY-source OR reads the chamfer as hidden (one source
    // was); the correct ALL-source AND reads it as visible (not every
    // source was) — the same law §1.2 uses to derive a vertex's hidden state
    // from its incident faces.
    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.setFaceHidden(1, true);   // face1 (+Z) only
    assert(!m.isFaceHidden(4)); // face4 (+Y) stays visible

    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "edge (6,7) not found in cube");
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f) == 1, "should process 1 edge");

    immutable int chamferFi = findChamferByCentroid(m);
    assert(chamferFi >= 0, "chamfer face not found by centroid");
    assert(!m.isFaceHidden(chamferFi),
        "S5: chamfer strip must be VISIBLE when only ONE of its two source "
        ~ "faces was hidden (ALL-source AND, not ANY-source OR)");
}

unittest { // S4/S5 companion — BOTH sources hidden: the chamfer strip must
    // still come back Hidden. Proves the AND rule actually ANDs instead of
    // degenerating to "never hidden" (which would pass the row above but
    // fail this one).
    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();
    m.setFaceHidden(1, true);
    m.setFaceHidden(4, true);

    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "edge (6,7) not found in cube");
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f) == 1, "should process 1 edge");

    immutable int chamferFi = findChamferByCentroid(m);
    assert(chamferFi >= 0, "chamfer face not found by centroid");
    assert(m.isFaceHidden(chamferFi),
        "S5 companion: chamfer strip must be HIDDEN when BOTH source faces "
        ~ "were");
}

// Width-mode dihedral conversion (parity task, fuzz divergence D1). In WIDTH
// mode the tool value is the true PERPENDICULAR bevel width, so the along-face
// corner slide it produces on a crease of surface-opening angle θ is
// `width / sin(θ/2)`. INSET mode keeps the value AS the along-face slide
// (byte-identical to the pre-change path). Verified against the exact law:
//   • 90° cube edge  ⇒ slide = w / sin(45°) = w·√2.
//   • 120° tent edge ⇒ slide = w / sin(60°) = w·(2/√3).
unittest {
    import std.math : abs, sqrt;

    bool[] edgeMask(ref Mesh m, uint a, uint b) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        int ei = findEdge(m, a, b);
        assert(ei >= 0, "edge not found");
        mask[ei] = true;
        return mask;
    }
    // Distance from p to the NEARER of the beveled edge's two (original)
    // endpoints — a slide corner sits exactly `slide` away from its source.
    float distToNearestEndpoint(Vec3 p, Vec3 e0, Vec3 e1) {
        immutable float d0 = (p - e0).length, d1 = (p - e1).length;
        return d0 < d1 ? d0 : d1;
    }

    immutable float w = 0.1f;

    // ---- 90° cube edge (6,7): endpoints (0.5,0.5,0.5) and (-0.5,0.5,0.5). ----
    immutable Vec3 c6 = Vec3( 0.5f, 0.5f, 0.5f);
    immutable Vec3 c7 = Vec3(-0.5f, 0.5f, 0.5f);

    // WIDTH mode: every chamfer corner slides w/sin(45°) = w·√2 from its source.
    {
        auto m = makeCube();
        assert(m.bevelEdgesByMask(edgeMask(m, 6, 7), w, 0, /*widthMode=*/true) == 1);
        assert(m.vertices.length == 10 && m.faces.length == 7,
               "width mode keeps the same topology (no clamp): 10v/7f");
        immutable float expected = w * sqrt(2.0f);   // w / sin(45°)
        int corners = 0;
        foreach (fi; 0 .. m.faces.length) {
            if (!m.isFaceSelected(fi)) continue;   // the chamfer face
            corners = cast(int)m.faces[fi].length;
            foreach (vi; m.faces[fi]) {
                immutable float dist = distToNearestEndpoint(m.vertices[vi], c6, c7);
                assert(abs(dist - expected) < 1e-5f,
                       "90° width-mode slide must equal w·√2");
            }
            break;
        }
        assert(corners == 4, "chamfer is a quad");
    }

    // INSET mode on the SAME edge is UNCHANGED: the value IS the slide (w),
    // and the chamfer centroid stays (0, 0.45, 0.45) — the pre-change result.
    {
        auto m = makeCube();
        assert(m.bevelEdgesByMask(edgeMask(m, 6, 7), w, 0, /*widthMode=*/false) == 1);
        Vec3 cen = Vec3(0, 0, 0);
        int n = 0;
        foreach (fi; 0 .. m.faces.length) {
            if (!m.isFaceSelected(fi)) continue;
            n = cast(int)m.faces[fi].length;
            foreach (vi; m.faces[fi]) {
                cen = cen + m.vertices[vi];
                immutable float dist = distToNearestEndpoint(m.vertices[vi], c6, c7);
                assert(abs(dist - w) < 1e-5f,
                       "inset-mode slide is the raw value w (UNCHANGED)");
            }
            cen = cen * (1.0f / cast(float)n);
            break;
        }
        assert(abs(cen.x) < 1e-3f && abs(cen.y - 0.45f) < 1e-3f
               && abs(cen.z - 0.45f) < 1e-3f,
               "inset chamfer centroid unchanged at (0,0.45,0.45)");
    }

    // Equivalence: on a uniform-dihedral single edge, WIDTH(w) is IDENTICAL
    // to INSET at the scaled value — the whole point of the factor. Proves the
    // rounding/rebuild stay consistent, not just the raw corner positions.
    {
        auto mW = makeCube();
        mW.bevelEdgesByMask(edgeMask(mW, 6, 7), w, 0, /*widthMode=*/true);
        auto mI = makeCube();
        mI.bevelEdgesByMask(edgeMask(mI, 6, 7), w * sqrt(2.0f), 0, /*widthMode=*/false);
        assert(mW.vertices.length == mI.vertices.length);
        foreach (i; 0 .. mW.vertices.length)
            assert((mW.vertices[i] - mI.vertices[i]).length < 1e-5f,
                   "width(w) == inset(w·√2) on a 90° edge");
    }

    // ---- Non-90° "tent": two quads meeting at a 120° surface-opening
    // dihedral (factor = 1/sin(60°) = 2/√3). The along-face slide must scale
    // by exactly that factor — this is what "varies per edge" means. ----
    {
        immutable float z = sqrt(3.0f) / 2.0f;   // sin(120°)
        // Freshly-built mesh each call — never a struct copy (Mesh's array
        // fields would alias and the bevel's appends could clobber the source).
        Mesh makeTent() {
            Mesh t;
            t.vertices = [
                Vec3(0.0f, 0.0f, 0.0f),   // 0  V0  (shared-edge start)
                Vec3(2.0f, 0.0f, 0.0f),   // 1  V1  (shared-edge end)
                Vec3(0.0f, 1.0f, 0.0f),   // 2  A0  (+Y face)
                Vec3(2.0f, 1.0f, 0.0f),   // 3  A1
                Vec3(0.0f, -0.5f, z),     // 4  B0  (folded face, +120°)
                Vec3(2.0f, -0.5f, z),     // 5  B1
            ];
            t.addFace([0, 1, 3, 2]);   // face A, normal +Z
            t.addFace([1, 0, 4, 5]);   // face B, folded (consistent winding)
            t.buildLoops();
            return t;
        }

        immutable float factor = 2.0f / sqrt(3.0f);   // 1/sin(60°)

        auto mW = makeTent();
        assert(mW.bevelEdgesByMask(edgeMask(mW, 0, 1), w, 0, /*widthMode=*/true) == 1,
               "tent edge must bevel in width mode");
        auto mI = makeTent();
        assert(mI.bevelEdgesByMask(edgeMask(mI, 0, 1), w * factor, 0,
                                   /*widthMode=*/false) == 1);
        // width(w) on the 120° crease == inset at w/sin(60°): the code's
        // per-edge dihedral factor equals 2/√3.
        assert(mW.vertices.length == mI.vertices.length,
               "tent width/inset vertex counts match");
        foreach (i; 0 .. mW.vertices.length)
            assert((mW.vertices[i] - mI.vertices[i]).length < 1e-4f,
                   "120° width(w) == inset(w·2/√3)");

        // Direct magnitude: each chamfer corner sits w·(2/√3) from V0 or V1
        // (the beveled edge's original endpoints).
        immutable Vec3 v0 = Vec3(0, 0, 0), v1 = Vec3(2, 0, 0);
        immutable float expected = w * factor;   // w / sin(60°)
        int checked = 0;
        foreach (fi; 0 .. mW.faces.length) {
            if (!mW.isFaceSelected(fi)) continue;   // the chamfer face
            foreach (vi; mW.faces[fi]) {
                immutable float dist = distToNearestEndpoint(mW.vertices[vi], v0, v1);
                assert(abs(dist - expected) < 1e-4f,
                       "120° width-mode slide must equal w/sin(60°) = w·2/√3");
                ++checked;
            }
            break;
        }
        assert(checked >= 2, "tent bevel produced a selected chamfer face");
    }
}

// Case A (task 0304 overshoot guard, re-measured task 0436): an isolated
// interior edge of a unit cube, both ends bare, every neighbouring edge
// length 1.0. `toolcards/edge.bevel/clamp_findings.md`, Case A: clamping is
// per-direction and bit-exact (`clampedWidth`) — but the reference does NOT
// weld a clamp-saturated SLIDE corner into the pre-existing far vertex it
// lands on. It leaves TWO separate vertex records at that position, and the
// vertex/face COUNTS stay flat across the threshold (no collapse) at every
// width tested and at both Round Levels. (The two stale assumptions this
// replaces — "no coincident verts" / "no degenerate faces" at width ==
// farLen — were never reference-verified; the reference's own capture shows
// both DO happen here, and that is correct.)
unittest { // Case A: vertex/face counts stay flat across the clamp
           // threshold, at both Round Level 0 and 1.
    import std.conv : to;

    bool[] edgeMask(ref Mesh m, uint a, uint b) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        int ei = findEdge(m, a, b);
        assert(ei >= 0, "cube edge not found");
        mask[ei] = true;
        return mask;
    }

    immutable float[4] widths = [0.3f, 0.9f, 1.0f, 1.4f];
    foreach (w; widths) {
        auto m0 = makeCube();
        assert(m0.bevelEdgesByMask(edgeMask(m0, 6, 7), w) == 1,
            "case A L0 w=" ~ w.to!string ~ ": must process the edge");
        assert(m0.vertices.length == 10 && m0.faces.length == 7,
            "case A L0 w=" ~ w.to!string ~ ": expected 10v/7f, got " ~
            m0.vertices.length.to!string ~ "v/" ~ m0.faces.length.to!string ~ "f");

        auto m1 = makeCube();
        assert(m1.bevelEdgesByMask(edgeMask(m1, 6, 7), w, 1) == 1,
            "case A L1 w=" ~ w.to!string ~ ": must process the edge");
        assert(m1.vertices.length == 12 && m1.faces.length == 8,
            "case A L1 w=" ~ w.to!string ~ ": expected 12v/8f, got " ~
            m1.vertices.length.to!string ~ "v/" ~ m1.faces.length.to!string ~ "f");
    }
}

unittest { // Case A: saturation — w=1.0 and w=1.4 land every slide corner
           // on the SAME position (each has already reached its own
           // farLen at w=1.0), so the two vertex arrays are bit-identical.
    import std.conv : to;
    bool[] edgeMask(ref Mesh m, uint a, uint b) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        int ei = findEdge(m, a, b);
        assert(ei >= 0, "cube edge not found");
        mask[ei] = true;
        return mask;
    }
    auto mA = makeCube(); mA.bevelEdgesByMask(edgeMask(mA, 6, 7), 1.0f);
    auto mB = makeCube(); mB.bevelEdgesByMask(edgeMask(mB, 6, 7), 1.4f);
    assert(mA.vertices.length == mB.vertices.length, "case A: w=1.0/1.4 vertex count must match");
    foreach (i; 0 .. mA.vertices.length)
        assert((mA.vertices[i] - mB.vertices[i]).length < 1e-6f,
            "case A: w=1.0 and w=1.4 must saturate to the same vertex " ~ i.to!string);
}

unittest { // Case A: no weld against the original mesh — at w >= 1.0, each
           // of the 4 slide corners that reaches its own neighbour's far
           // vertex duplicates that vertex's POSITION but keeps its own,
           // separate INDEX (10 vertex records, not 9-or-fewer). Below
           // threshold there is no coincidence at all.
    import std.conv : to;
    bool[] edgeMask(ref Mesh m, uint a, uint b) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        int ei = findEdge(m, a, b);
        assert(ei >= 0, "cube edge not found");
        mask[ei] = true;
        return mask;
    }
    int coincidentPairs(ref Mesh m) {
        int n = 0;
        foreach (i; 0 .. m.vertices.length)
            foreach (j; i + 1 .. m.vertices.length)
                if ((m.vertices[i] - m.vertices[j]).length < 1e-6f) ++n;
        return n;
    }

    auto mLow = makeCube();
    mLow.bevelEdgesByMask(edgeMask(mLow, 6, 7), 0.9f);
    assert(mLow.vertices.length == 10, "case A w=0.9: expected 10v (no clamp yet)");
    assert(coincidentPairs(mLow) == 0, "case A w=0.9: no coincidence expected below threshold");

    auto mAt = makeCube();
    mAt.bevelEdgesByMask(edgeMask(mAt, 6, 7), 1.0f);
    assert(mAt.vertices.length == 10,
        "case A w=1.0: expected 10 vertex RECORDS (no weld), got " ~ mAt.vertices.length.to!string);
    assert(coincidentPairs(mAt) == 4,
        "case A w=1.0: expected 4 coincident (new-slide, pre-existing) pairs, got " ~
        coincidentPairs(mAt).to!string);
}

unittest { // Case B (task 0436, clamp_findings.md main pass): a 3-edge chain
           // on a frustum with ASYMMETRIC neighbour-edge lengths at its
           // bare ends — the discriminator between per-direction and
           // global clamping, plus (at w=1.4) the new-vs-new merge law.
    import std.conv : to;

    static Mesh buildFrustum() {
        Mesh m;
        m.vertices = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f),
            Vec3(0.5f, 0.5f, -0.5f),   Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.2f, -0.2f, 0.5f),  Vec3(0.2f, -0.2f, 0.5f),
            Vec3(0.2f, 0.2f, 0.5f),    Vec3(-0.2f, 0.2f, 0.5f),
        ];
        m.addFace([3u, 2u, 1u, 0u]);
        m.addFace([4u, 5u, 6u, 7u]);
        m.addFace([0u, 1u, 5u, 4u]);
        m.addFace([1u, 2u, 6u, 5u]);
        m.addFace([2u, 3u, 7u, 6u]);
        m.addFace([3u, 0u, 4u, 7u]);
        m.buildLoops();
        return m;
    }
    bool[] chainMask(ref Mesh m) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[0u, 1u], [1u, 5u], [5u, 6u]]) {
            int ei = findEdge(m, pair[0], pair[1]);
            assert(ei >= 0, "case B: chain edge missing");
            mask[ei] = true;
        }
        return mask;
    }
    int findVertNear(ref Mesh m, Vec3 p, double tol = 1e-4) {
        foreach (i; 0 .. m.vertices.length)
            if ((m.vertices[i] - p).length < tol) return cast(int)i;
        return -1;
    }

    // Counts stay flat across 0.3/0.9/1.0; collapse only at 1.4.
    foreach (w; [0.3f, 0.9f, 1.0f]) {
        auto m = buildFrustum();
        assert(m.bevelEdgesByMask(chainMask(m), w) == 3, "case B w=" ~ w.to!string);
        assert(m.vertices.length == 12 && m.faces.length == 9,
            "case B w=" ~ w.to!string ~ ": expected 12v/9f, got " ~
            m.vertices.length.to!string ~ "v/" ~ m.faces.length.to!string ~ "f");
    }

    // Per-direction discriminator at w=0.9: v6 has two directions in
    // DIFFERENT clamp states in the SAME call (farLen 0.4 clamps, farLen
    // 1.086278 does not) — a global-minimum clamp would force both to 0.4
    // and would miss every one of these bit-exact positions.
    {
        auto m = buildFrustum();
        assert(m.bevelEdgesByMask(chainMask(m), 0.9f) == 3);
        assert(findVertNear(m, Vec3(-0.5f, 0.4f, -0.5f)) >= 0, "case B w=0.9: v0->v3 unclamped");
        assert(findVertNear(m, Vec3(-0.2514449f, -0.2514449f, 0.3285172f)) >= 0, "case B w=0.9: v0->v4 unclamped");
        assert(findVertNear(m, Vec3(0.5f, 0.4f, -0.5f)) >= 0, "case B w=0.9: v1->v2 unclamped");
        assert(findVertNear(m, Vec3(-0.2f, -0.2f, 0.5f)) >= 0, "case B w=0.9: v5->v4 clamped, lands on v4");
        assert(findVertNear(m, Vec3(-0.2f, 0.2f, 0.5f)) >= 0, "case B w=0.9: v6->v7 clamped, lands on v7");
        assert(findVertNear(m, Vec3(0.4485551f, 0.4485551f, -0.3285172f)) >= 0, "case B w=0.9: v6->v2 unclamped");
    }

    // New-vs-new merge at w=1.4: v1->v2 and v6->v2 both saturate at v2;
    // v0->v4 and v5->v4 both saturate at v4. Each pair pools into ONE
    // shared identity (both new, coincide, corners of the same rebuilt
    // face — `bevelEdgesByMask`'s Step 1) and each host face's own
    // construction (Step 2) then drops the duplicate occurrence, landing
    // exactly on the measured 12v -> 10v / two-triangles-from-quads
    // outcome. The pre-existing v2 and v4 remain separate records (the
    // guard's "no weld against the original" law is unconditional, not
    // narrowed by this merge) — checked positively via "exactly 2 records
    // at each target position" (original + one pooled slide), never 3
    // (never pooled) or 1 (welded into the original).
    {
        auto m = buildFrustum();
        assert(m.bevelEdgesByMask(chainMask(m), 1.4f) == 3);
        assert(m.vertices.length == 10 && m.faces.length == 9,
            "case B w=1.4: expected 10v/9f, got " ~
            m.vertices.length.to!string ~ "v/" ~ m.faces.length.to!string ~ "f");
        int countNear(Vec3 p, double tol = 1e-4) {
            int n = 0;
            foreach (v; m.vertices) if ((v - p).length < tol) ++n;
            return n;
        }
        assert(countNear(Vec3(0.5f, 0.5f, -0.5f)) == 2,
            "case B w=1.4: expected exactly 2 records at v2's position (original + merged slide), got " ~
            countNear(Vec3(0.5f, 0.5f, -0.5f)).to!string);
        assert(countNear(Vec3(-0.2f, -0.2f, 0.5f)) == 2,
            "case B w=1.4: expected exactly 2 records at v4's position (original + merged slide), got " ~
            countNear(Vec3(-0.2f, -0.2f, 0.5f)).to!string);
        // Both merges resolve their host faces into CLEAN triangles (not a
        // corner-repeating "bowtie" quad) — direct proof the pooled
        // identity, not just position, drives Step 2's construction.
        int triCount = 0;
        foreach (f; m.faces) if (f.length == 3) ++triCount;
        assert(triCount == 2,
            "case B w=1.4: expected exactly 2 clean triangles (two collapsed quads), got " ~ triCount.to!string);
    }
}

unittest { // Case C (task 0436, clamp_findings.md follow-up pass): two
           // disjoint top-face edges of a unit cube with NO clamp
           // anywhere (every farLen is 1.0, every width tested is well
           // under it) — the discriminator proving the new-vs-new merge is
           // independent of clamp state entirely. At the one width where
           // the two bare-end top-face slide corners coincide on each
           // side, the shared top-face quad vanishes ENTIRELY (not a
           // degenerate triangle) because all 4 of its corners collapse
           // pairwise to 2 distinct points.
    import std.conv : to;

    bool[] twoTopEdgeMask(ref Mesh m) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[4u, 5u], [6u, 7u]]) {
            int ei = findEdge(m, pair[0], pair[1]);
            assert(ei >= 0, "case C: top-face edge missing");
            mask[ei] = true;
        }
        return mask;
    }
    int findVertNear(ref Mesh m, Vec3 p, double tol = 1e-4) {
        foreach (i; 0 .. m.vertices.length)
            if ((m.vertices[i] - p).length < tol) return cast(int)i;
        return -1;
    }
    int facesReferencing(ref Mesh m, uint vi) {
        int n = 0;
        foreach (f; m.faces) foreach (c; f) if (c == vi) { ++n; break; }
        return n;
    }

    // Control: below and past the coincidence width, full topology (both
    // bonus points: the collapse is a single-width phenomenon, not sticky).
    foreach (w; [0.4f, 0.6f]) {
        auto m = makeCube();
        assert(m.bevelEdgesByMask(twoTopEdgeMask(m), w) == 2, "case C w=" ~ w.to!string);
        assert(m.vertices.length == 12 && m.faces.length == 8,
            "case C w=" ~ w.to!string ~ ": expected 12v/8f, got " ~
            m.vertices.length.to!string ~ "v/" ~ m.faces.length.to!string ~ "f");
    }

    // Test: at w=0.5 the two top-face slide-corner pairs coincide and merge.
    auto m = makeCube();
    assert(m.bevelEdgesByMask(twoTopEdgeMask(m), 0.5f) == 2);
    assert(m.vertices.length == 10 && m.faces.length == 7,
        "case C w=0.5: expected 10v/7f (top-face quad vanishes entirely), got " ~
        m.vertices.length.to!string ~ "v/" ~ m.faces.length.to!string ~ "f");

    int viLeft  = findVertNear(m, Vec3(-0.5f, 0.0f, 0.5f));
    int viRight = findVertNear(m, Vec3(0.5f, 0.0f, 0.5f));
    assert(viLeft >= 0 && viRight >= 0, "case C w=0.5: merged corners must exist");
    // Each merged corner is a SINGLE shared vertex record, referenced by
    // exactly 2 (side-strip) faces — direct proof it is one record, not two
    // separate coincident ones (unlike Case A/B/D's "duplicate, not welded").
    // Reference dump cross-check (clamp_findings.md, width 0.5): the merged
    // corner is a corner of THREE faces — the reduced 5-gon side face (was
    // a 6-gon) PLUS both chamfer strips — not just the "two different strip
    // faces" the writeup calls out by name (that phrase highlights the
    // double chamfer-strip duty specifically; the reference's own dump
    // shows the same 5-gon side face reference vibe3d produces here, e.g.
    // its `[9, 2, 0, 6, 7]` / `[8, 5, 4, 1, 3]` left/right 5-gons).
    assert(facesReferencing(m, cast(uint)viLeft)  == 3,
        "case C w=0.5: merged left corner must be a single shared vertex (5-gon side face + 2 strips)");
    assert(facesReferencing(m, cast(uint)viRight) == 3,
        "case C w=0.5: merged right corner must be a single shared vertex (5-gon side face + 2 strips)");
}

unittest { // Case D (task 0436, clamp_findings.md follow-up pass):
           // coincidence WITHOUT merge. The reference fixture is two
           // disjoint single-FACE quads (each bare-end vertex touching only
           // 1 face); vibe3d's per-vertex corner pass requires `d >= 2`
           // incident faces to visit a vertex at all, so an isolated
           // single-face island is a stricter degenerate case the kernel
           // does not support today (a `d < 2` no-op) and is out of this
           // task's scope (flagged separately, not patched here). This
           // reconstructs the SAME discriminating property — a CLAMPED
           // slide and an UNCLAMPED slide from two wholly disconnected mesh
           // components landing on the identical point, in one bevel call —
           // on two disjoint unit cubes (`makeCube()`'s own topology,
           // already `d == 3` everywhere and proven by the Case A
           // unittests above), one of them uniformly scaled 4x and
           // translated so its analogous bare-end slide is UNCLAMPED
           // (farLen 4.0 > width 1.4) yet still lands on cube 1's own
           // CLAMPED landing point (Case A: edge (6,7), width>=1.0, one
           // slide corner saturates at exactly (-0.5,0.5,-0.5)).
    import std.conv : to;

    static Mesh makeTranslatedScaledCube(Vec3 scale, Vec3 offset) {
        Mesh m = makeCube();
        foreach (ref v; m.vertices)
            v = Vec3(v.x * scale.x + offset.x, v.y * scale.y + offset.y, v.z * scale.z + offset.z);
        return m;
    }
    static Mesh buildTwoCubes(Vec3 scale2, Vec3 offset2) {
        Mesh mm;
        mm.vertices = makeCube().vertices ~ makeTranslatedScaledCube(scale2, offset2).vertices;
        foreach (f; makeCube().faces) mm.addFace(f.dup);
        foreach (f; makeCube().faces) {
            uint[] shifted; foreach (vi; f) shifted ~= vi + 8;
            mm.addFace(shifted);
        }
        mm.buildLoops();
        return mm;
    }
    int countNear(ref Mesh m, Vec3 p, double tol = 1e-4) {
        int n = 0;
        foreach (v; m.vertices) if ((v - p).length < tol) ++n;
        return n;
    }

    // cube1: standard unit cube (Case A's own fixture). cube2: scaled 4x,
    // translated so its OWN edge-(6,7)-equivalent bare-end slide (same
    // relative construction, unclamped since farLen=4.0 > width=1.4) lands
    // EXACTLY on cube1's clamped landing point (-0.5,0.5,-0.5) — solved
    // directly from the unclamped slide law `V + width*dir`: cube2's
    // analogous source vertex is at scale*(-0.5,0.5,0.5)+offset, sliding in
    // direction (0,0,-1); offset chosen so that position + 1.4*(0,0,-1) ==
    // (-0.5,0.5,-0.5).
    immutable Vec3 scale2  = Vec3(4, 4, 4);
    immutable Vec3 offset2 = Vec3(1.5f, -1.5f, -1.1f);

    bool[] maskFor(ref Mesh mm) {
        bool[] mk; mk.length = mm.edges.length; mk[] = false;
        int e1 = findEdge(mm, 6, 7);
        int e2 = findEdge(mm, 14, 15); // cube2's own (6,7)-equivalent, shifted +8
        assert(e1 >= 0 && e2 >= 0, "case D: both cubes' target edges must exist");
        mk[e1] = true;
        mk[e2] = true;
        return mk;
    }

    // Control: a width well under BOTH cubes' clamp thresholds — no
    // coincidence anywhere, plain per-cube Case A topology twice over.
    auto mCtrl = buildTwoCubes(scale2, offset2);
    assert(mCtrl.bevelEdgesByMask(maskFor(mCtrl), 0.3f) == 2, "case D control: must process both edges");
    assert(mCtrl.vertices.length == 20 && mCtrl.faces.length == 14,
        "case D w=0.3 control: expected 20v/14f (2x Case A's 10v/7f), got " ~
        mCtrl.vertices.length.to!string ~ "v/" ~ mCtrl.faces.length.to!string ~ "f");

    auto m = buildTwoCubes(scale2, offset2);
    auto mask = maskFor(m);

    // Test: cube1's slide clamps (farLen 1.0 < 1.4) onto its OWN original
    // vertex 3's position; cube2's analogous slide is unclamped (farLen 4.0
    // > 1.4) and, by construction, lands on the SAME point via a wholly
    // unrelated component (different mesh island, different source vertex,
    // zero shared ancestry, never a corner of any face cube1 touches).
    // Counts stay IDENTICAL to the control — the two-clause discriminator:
    // "both new" alone says nothing here (Case A's own new-vs-original
    // pairs are all over both cubes already); "same rebuilt face" is what
    // rules out a cross-component merge.
    assert(m.bevelEdgesByMask(mask, 1.4f) == 2, "case D test: must process both edges");
    assert(m.vertices.length == 20 && m.faces.length == 14,
        "case D w=1.4: expected 20v/14f (no merge at all), got " ~
        m.vertices.length.to!string ~ "v/" ~ m.faces.length.to!string ~ "f");
    assert(countNear(m, Vec3(-0.5f, 0.5f, -0.5f)) == 3,
        "case D w=1.4: expected 3 separate records at (-0.5,0.5,-0.5) " ~
        "(cube1's original v3, cube1's clamped slide, cube2's unclamped slide), got " ~
        countNear(m, Vec3(-0.5f, 0.5f, -0.5f)).to!string);
}

// Task 0391 Phase 1/2 winding-backstop helper: `runTopologyDiffSuite` only
// checks vertex-SET + face-COUNT (fixture_helpers.d:890), NOT face-vertex
// correspondence — a topologically-broken but position-correct cap (e.g.
// the old edge-bevel branch's per-face-independent junction caps, which
// double-welded / left non-manifold edges at the shared corner — the exact
// defect that opened this task) could still pass the fixture. This asserts
// true manifold cleanliness: every edge shared by EXACTLY 2 faces (no
// cracks, no non-manifold fans), no coincident vertices, no degenerate
// (zero-area or <3-distinct-vertex) faces, and the Euler characteristic
// V-E+F==2 (closed genus-0 — bevel must not change the mesh's topological
// genus, only add detail).
version (unittest) private void assertBevelManifoldClean(ref Mesh m, string tag) {
    import std.conv : to;

    // The valence-4 free-end cap (L>=1, "Decision C") DELIBERATELY reproduces
    // the reference's cap: at each such free end the ORIGINAL free-end vertex
    // is RETAINED at the cap ring's opposite-edge slot (coincident with the
    // chamfer-strip pinch wherever the rounded rail degenerates onto it), and
    // one opposite-edge slide is left ORPHANED. The bevel records those exact
    // positions; waive EXACTLY them here (both lists empty for every other
    // bevel and every L0 bevel, so this is a no-op elsewhere) and exclude the
    // intended orphans from the Euler count. Any OTHER coincident/orphan/
    // degenerate vertex or face still fails the asserts below.
    bool nearRecorded(Vec3 p, const(Vec3)[] recorded) {
        foreach (r; recorded)
            if ((p - r).length < 1e-6f) return true;
        return false;
    }
    const capCoincident = m.bevelCapCoincidentPos_;
    const capOrphan     = m.bevelCapOrphanPos_;
    static ulong ekey(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
    }
    // Edges bounding an intended degenerate pinched cap. Such a cap is zero-area
    // (all its corners collinear on the free-end edge) so its winding is
    // ill-defined and reads back CO-ORIENTED with the real face on the other
    // side of each shared edge — an artifact of the reference's own degenerate
    // cap, not a cracked junction. Collected below and used to waive EXACTLY
    // those edges' winding assert; every other co-oriented edge still fails.
    bool[ulong] pinchedCapEdge;

    foreach (i; 0 .. m.vertices.length)
        foreach (j; i + 1 .. m.vertices.length)
            assert((m.vertices[i] - m.vertices[j]).length > 1e-6f
                    || nearRecorded(m.vertices[i], capCoincident),
                tag ~ ": coincident verts " ~ i.to!string ~ "," ~ j.to!string);

    foreach (fi, f; m.faces) {
        bool[uint] distinct;
        foreach (v; f) distinct[v] = true;
        assert(distinct.length >= 3,
            tag ~ ": face " ~ fi.to!string ~ " has <3 distinct verts");
        // A reference-parity PINCHED cap face carries the coincident pair
        // (retained free-end vertex + chamfer-strip pinch) at a recorded cap
        // position and is deliberately zero-area — the reference emits the same
        // degenerate cap. Waive the zero-area assert for EXACTLY such a face;
        // every other zero-area face still fails.
        bool intendedPinchedCap = false;
        if (capCoincident.length > 0) {
            outer: foreach (ci; 0 .. f.length) {
                if (!nearRecorded(m.vertices[f[ci]], capCoincident)) continue;
                foreach (cj; ci + 1 .. f.length)
                    if ((m.vertices[f[ci]] - m.vertices[f[cj]]).length < 1e-6f) {
                        intendedPinchedCap = true;
                        break outer;
                    }
            }
        }
        if (intendedPinchedCap)
            foreach (k; 0 .. f.length)
                pinchedCapEdge[ekey(f[k], f[(k + 1) % f.length])] = true;
        Vec3 nsum = Vec3(0, 0, 0);
        foreach (k; 0 .. f.length) {
            Vec3 a = m.vertices[f[k]], b = m.vertices[f[(k + 1) % f.length]];
            nsum.x += (a.y - b.y) * (a.z + b.z);
            nsum.y += (a.z - b.z) * (a.x + b.x);
            nsum.z += (a.x - b.x) * (a.y + b.y);
        }
        assert(nsum.length * 0.5f > 1e-9f || intendedPinchedCap,
            tag ~ ": face " ~ fi.to!string ~ " is degenerate (zero-area)");
    }

    // Every physical edge must border EXACTLY 2 faces — a non-manifold
    // (0/1/3+) count here is precisely the double-weld / cracked-junction
    // defect class this backstop exists to catch.
    int[ulong] edgeUse;
    int[ulong] edgeWinding;
    uint[] vertexUse; vertexUse.length = m.vertices.length;
    foreach (f; m.faces)
        foreach (k; 0 .. f.length) {
            uint a = f[k], b = f[(k + 1) % f.length];
            edgeUse[ekey(a, b)]++;
            edgeWinding[ekey(a, b)] += a < b ? 1 : -1;
            ++vertexUse[a];
        }
    long intendedOrphans = 0;
    foreach (vi, count; vertexUse) {
        if (count == 0 && nearRecorded(m.vertices[vi], capOrphan)) {
            ++intendedOrphans;   // reference-parity orphan cap slide — expected
            continue;
        }
        assert(count > 0, tag ~ ": orphan vertex " ~ vi.to!string);
    }
    size_t edgeCount = 0;
    foreach (key, count; edgeUse) {
        assert(count == 2, tag ~ ": non-manifold edge (used by " ~
            count.to!string ~ " faces, expected 2)");
        if (key !in pinchedCapEdge)
            assert(edgeWinding[key] == 0,
                tag ~ ": co-oriented edge winding (both incident faces use the same direction)");
        ++edgeCount;
    }

    // Euler characteristic: V - E + F == 2 for a closed genus-0 mesh (a
    // beveled cube stays genus-0 — bevel only adds detail, never a handle).
    // Intended orphan cap slides are isolated points, not part of the surface —
    // exclude them from V so the identity still measures the real manifold.
    immutable long V = cast(long)m.vertices.length - intendedOrphans;
    immutable long E = cast(long)edgeCount;
    immutable long F = cast(long)m.faces.length;
    assert(V - E + F == 2,
        tag ~ ": Euler characteristic V-E+F=" ~ (V - E + F).to!string ~ " != 2");
}

// Task 0439 (doc/edge_bevel_freeend_cap_plan.md §F): an OPEN mesh (disk, grid
// — anything with a boundary) fails `assertBevelManifoldClean`'s hard
// `V-E+F==2` unconditionally, since that identity assumes a closed genus-0
// mesh. This variant accepts the same coincident-vertex / degenerate-face /
// orphan-vertex checks, but an edge may border ONE face (a boundary/rim edge)
// as well as two (interior, still winding-checked) — never zero or three-or-
// more — and the caller supplies the expected Euler characteristic instead of
// a hardcoded 2 (a simply-connected disk with one boundary loop is 1; bevel
// only adds detail, so it must never change).
version (unittest) private void assertBevelManifoldCleanOpen(ref Mesh m, string tag, long wantEuler) {
    import std.conv : to;

    // The valence-4 full-hub free-end cap (L>=1) DELIBERATELY reproduces the
    // reference's degenerate cap: a coincident pair (side_pinch + chamfer_pinch)
    // at each free-end position, plus one orphan opposite-edge slide. The bevel
    // records those exact positions; waive EXACTLY them here (empty for every
    // other bevel, so this is a no-op elsewhere) and exclude the intended
    // orphans from the Euler count. Any OTHER coincident/orphan vertex still
    // fails the asserts below.
    bool nearRecorded(Vec3 p, const(Vec3)[] recorded) {
        foreach (r; recorded)
            if ((p - r).length < 1e-6f) return true;
        return false;
    }
    const capCoincident = m.bevelCapCoincidentPos_;
    const capOrphan     = m.bevelCapOrphanPos_;
    static ulong ekey(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
    }
    // Edges bounding an intended degenerate pinched cap — zero-area, so its
    // winding is ill-defined and reads back CO-ORIENTED with the real face
    // across each shared edge (the reference's own antipodal degenerate cap,
    // not a cracked junction). Used below to waive EXACTLY those edges' winding
    // assert; every other co-oriented interior edge still fails.
    bool[ulong] pinchedCapEdge;

    foreach (i; 0 .. m.vertices.length)
        foreach (j; i + 1 .. m.vertices.length)
            assert((m.vertices[i] - m.vertices[j]).length > 1e-6f
                    || nearRecorded(m.vertices[i], capCoincident),
                tag ~ ": coincident verts " ~ i.to!string ~ "," ~ j.to!string);

    foreach (fi, f; m.faces) {
        bool[uint] distinct;
        foreach (v; f) distinct[v] = true;
        assert(distinct.length >= 3,
            tag ~ ": face " ~ fi.to!string ~ " has <3 distinct verts");
        // The reference-parity PINCHED cap face carries the coincident pair
        // (side_pinch + chamfer_pinch) at a recorded cap position; at Round
        // Level >= 2 its rail interiors are collinear along the free-end
        // edge too, so the whole cap face is deliberately zero-area — the
        // reference emits the same degenerate cap. Waive the zero-area assert
        // for EXACTLY a face that carries such a coincident cap pair; every
        // other zero-area face still fails.
        bool intendedPinchedCap = false;
        if (capCoincident.length > 0) {
            outer: foreach (ci; 0 .. f.length) {
                if (!nearRecorded(m.vertices[f[ci]], capCoincident)) continue;
                foreach (cj; ci + 1 .. f.length)
                    if ((m.vertices[f[ci]] - m.vertices[f[cj]]).length < 1e-6f) {
                        intendedPinchedCap = true;
                        break outer;
                    }
            }
        }
        if (intendedPinchedCap)
            foreach (k; 0 .. f.length)
                pinchedCapEdge[ekey(f[k], f[(k + 1) % f.length])] = true;
        Vec3 nsum = Vec3(0, 0, 0);
        foreach (k; 0 .. f.length) {
            Vec3 a = m.vertices[f[k]], b = m.vertices[f[(k + 1) % f.length]];
            nsum.x += (a.y - b.y) * (a.z + b.z);
            nsum.y += (a.z - b.z) * (a.x + b.x);
            nsum.z += (a.x - b.x) * (a.y + b.y);
        }
        assert(nsum.length * 0.5f > 1e-9f || intendedPinchedCap,
            tag ~ ": face " ~ fi.to!string ~ " is degenerate (zero-area)");
    }

    int[ulong] edgeUse;
    int[ulong] edgeWinding;
    uint[] vertexUse; vertexUse.length = m.vertices.length;
    foreach (f; m.faces)
        foreach (k; 0 .. f.length) {
            uint a = f[k], b = f[(k + 1) % f.length];
            edgeUse[ekey(a, b)]++;
            edgeWinding[ekey(a, b)] += a < b ? 1 : -1;
            ++vertexUse[a];
        }
    long intendedOrphans = 0;
    foreach (vi, count; vertexUse) {
        if (count == 0 && nearRecorded(m.vertices[vi], capOrphan)) {
            ++intendedOrphans;   // reference-parity orphan cap slide — expected
            continue;
        }
        assert(count > 0, tag ~ ": orphan vertex " ~ vi.to!string);
    }
    size_t edgeCount = 0;
    foreach (key, count; edgeUse) {
        assert(count == 1 || count == 2, tag ~ ": edge used by " ~ count.to!string ~
            " faces (expected 1 boundary or 2 interior)");
        if (count == 2 && key !in pinchedCapEdge)
            assert(edgeWinding[key] == 0,
                tag ~ ": co-oriented edge winding (both incident faces use the same direction)");
        ++edgeCount;
    }

    // Intended orphan cap slides are not part of the surface — exclude them
    // from V so the Euler characteristic still measures the real manifold.
    immutable long V = cast(long)m.vertices.length - intendedOrphans;
    immutable long E = cast(long)edgeCount;
    immutable long F = cast(long)m.faces.length;
    assert(V - E + F == wantEuler,
        tag ~ ": Euler characteristic V-E+F=" ~ (V - E + F).to!string ~
        " != " ~ wantEuler.to!string);
}

// Task 0439 (doc/edge_bevel_freeend_cap_plan.md §F): full position +
// connectivity + WINDING comparison against a captured reference dump.
// `runTopologyDiffSuite` (tests/fixture_helpers.d) only checks the vertex
// position CLOUD and face COUNT — it would pass a winding regression (the
// right vertex set rewoven with the wrong connectivity or a flipped normal)
// silently. This compares the SET of vertex positions (rounded to 5 decimal
// digits) and the SET of faces, each face canonicalized as its sequence of
// (rounded) positions rotated to the lexicographically smallest starting
// point WITHOUT trying the reversed sequence — so it is sensitive to winding
// direction, not just to which 3+ vertices bound a face.
version (unittest) private void assertFacesMatchByPosition(ref Mesh m, const Vec3[] wantVerts,
                                         const uint[][] wantFaces, string tag) {
    import std.algorithm : sort, map;
    import std.array : array;
    import std.format : format;
    import std.conv : to;

    static string posKey(Vec3 p) {
        // Normalize near-zero components to a clean +0.0 before formatting:
        // a component that rounds to zero at 5 decimals (e.g. cos(pi/2) in
        // float32 is a tiny NEGATIVE number, not exactly 0) prints as
        // "-0.00000" on one side and "0.00000" on the other at the sign bit
        // — a spurious mismatch, not a real position difference. Threshold
        // is half the last displayed digit, matching the rounding boundary.
        import std.math : abs;
        immutable float x = (abs(p.x) < 5e-6f) ? 0.0f : p.x;
        immutable float y = (abs(p.y) < 5e-6f) ? 0.0f : p.y;
        immutable float z = (abs(p.z) < 5e-6f) ? 0.0f : p.z;
        return format("%.5f,%.5f,%.5f", x, y, z);
    }
    static string canonFace(const Vec3[] ring) {
        string best;
        foreach (start; 0 .. ring.length) {
            string s;
            foreach (k; 0 .. ring.length)
                s ~= posKey(ring[(start + k) % ring.length]) ~ "|";
            if (best.length == 0 || s < best) best = s;
        }
        return best;
    }
    static string faceKey(const uint[] f, const Vec3[] verts) {
        Vec3[] ring; foreach (v; f) ring ~= verts[v];
        return canonFace(ring);
    }

    auto gotPos = m.vertices.map!posKey.array;
    auto wantPos = wantVerts.map!posKey.array;
    sort(gotPos);
    sort(wantPos);
    assert(gotPos == wantPos, tag ~ ": vertex position set mismatch\ngot:  " ~
        gotPos.to!string ~ "\nwant: " ~ wantPos.to!string);

    auto gotFaces = m.faces._store.map!(f => faceKey(f, m.vertices)).array;
    auto wantFaceKeys = wantFaces.map!(f => faceKey(f, wantVerts)).array;
    sort(gotFaces);
    sort(wantFaceKeys);
    assert(gotFaces == wantFaceKeys, tag ~ ": face connectivity/winding mismatch\ngot:  " ~
        gotFaces.to!string ~ "\nwant: " ~ wantFaceKeys.to!string);
}

// Task 0456 — bidirectional max nearest-vertex distance between the beveled mesh
// and a reference dump's vertices, asserted within `band`. Used where the mesh
// matches the reference in SHAPE but not vertex-for-vertex under the %.5f bucket:
//   • the odd-N L>=2 hub ring's ~3.6e-3 corner-move/newC_i residual (0453);
//   • the mixed owner mesh, whose valence-4 full-hub free-end caps carry a
//     coincident pair + orphan slide (now reproduced, not welded) — a
//     bidirectional nearest-distance check tolerates the coincident duplicates
//     while still holding every reference position at the float32 floor.
// NOT a parity claim at the float32 floor — the band is stated per call site.
version (unittest) private void assertHubHausdorffWithin(ref Mesh m, const(Vec3)[] refVerts,
                                                         float band, string tag) {
    import std.conv : to;
    static float maxNearest(const(Vec3)[] a, const(Vec3)[] b) {
        float worst = 0;
        foreach (p; a) {
            float best = float.max;
            foreach (q; b) {
                immutable float d = (p - q).length;
                if (d < best) best = d;
            }
            if (best > worst) worst = best;
        }
        return worst;
    }
    immutable float d1 = maxNearest(m.vertices, refVerts);
    immutable float d2 = maxNearest(refVerts, m.vertices);
    immutable float worst = d1 > d2 ? d1 : d2;
    assert(worst <= band, tag ~ ": max nearest-vertex distance " ~
        worst.to!string ~ " exceeds band " ~ band.to!string);
}

// Task 0456 — like assertFacesMatchByPosition but at a caller-chosen decimal
// precision. The %.5f bucket (1e-5) is too tight for a SYMMETRIC hub whose rail
// midpoints land exactly on a %.5f rounding boundary (our float32 accumulation vs
// the reference's float64→float32 differ by ~1e-7, straddling e.g. 0.201015 →
// 0.20102 vs 0.20101 — plan risk R3). %.4f (1e-4) clears that boundary while the
// verified reference dumps have zero %.4f vertex collisions, so connectivity +
// position parity are still both checked, just at a boundary-robust precision.
version (unittest) private void assertFacesMatchByPositionDp(ref Mesh m, const Vec3[] wantVerts,
                                          const uint[][] wantFaces, string tag, int dp) {
    import std.algorithm : sort, map;
    import std.array : array;
    import std.format : format;
    import std.conv : to;
    import std.math : abs;
    string posKey(Vec3 p) {
        immutable float x = (abs(p.x) < 5e-6f) ? 0.0f : p.x;
        immutable float y = (abs(p.y) < 5e-6f) ? 0.0f : p.y;
        immutable float z = (abs(p.z) < 5e-6f) ? 0.0f : p.z;
        immutable string fmt = "%." ~ dp.to!string ~ "f";
        return format(fmt ~ "," ~ fmt ~ "," ~ fmt, x, y, z);
    }
    string canonFace(const Vec3[] ring) {
        string best;
        foreach (start; 0 .. ring.length) {
            string s;
            foreach (k; 0 .. ring.length)
                s ~= posKey(ring[(start + k) % ring.length]) ~ "|";
            if (best.length == 0 || s < best) best = s;
        }
        return best;
    }
    string faceKey(const uint[] f, const Vec3[] verts) {
        Vec3[] ring; foreach (v; f) ring ~= verts[v];
        return canonFace(ring);
    }
    auto gotPos = m.vertices.map!posKey.array;
    auto wantPos = wantVerts.map!posKey.array;
    sort(gotPos);
    sort(wantPos);
    assert(gotPos == wantPos, tag ~ ": vertex position set mismatch\ngot:  " ~
        gotPos.to!string ~ "\nwant: " ~ wantPos.to!string);
    auto gotFaces = m.faces._store.map!(f => faceKey(f, m.vertices)).array;
    auto wantFaceKeys = wantFaces.map!(f => faceKey(f, wantVerts)).array;
    sort(gotFaces);
    sort(wantFaceKeys);
    assert(gotFaces == wantFaceKeys, tag ~ ": face connectivity/winding mismatch\ngot:  " ~
        gotFaces.to!string ~ "\nwant: " ~ wantFaceKeys.to!string);
}

unittest { // bevelEdgesByMask: LOOP cap manifold-cleanliness backstop
           // (task 0391 Phase 1) — the 4-edge top-face-perimeter loop.
    auto m = makeCube();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    // The +Z face's own perimeter in makeCube()'s vertex numbering (verts
    // 4,5,6,7 all sit at z=0.5) — structurally the same "one face's own
    // 4-edge boundary, every corner a K==2 loop turn" shape as the public
    // edge_bevel_loop.json fixture (which uses the +Y face instead).
    foreach (pair; [[4u,7u], [7u,6u], [6u,5u], [5u,4u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0, "loop perimeter edge not found");
        mask[ei] = true;
    }
    size_t n = m.bevelEdgesByMask(mask, 0.1f);
    assert(n == 4, "should process all 4 loop edges");
    assert(m.vertices.length == 12, "expected 12 verts");
    assert(m.faces.length    == 10, "expected 10 faces");
    int[int] fvd;
    foreach (f; m.faces) fvd[cast(int)f.length]++;
    assert(fvd.get(4, 0) == 10, "loop cap should be ALL quads (no triangle/pentagon)");
    assertBevelManifoldClean(m, "loop cap");
}

unittest { // bevelEdgesByMask: 3-WAY JUNCTION cap manifold-cleanliness
           // backstop (task 0391 Phase 2, highest-risk) — all 3 edges at one
           // cube corner selected together (hub-fill + 3 independent
           // bare-end pentagons in the SAME case).
    auto m = makeCube();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    // Corner 6=(0.5,0.5,0.5); its 3 edges go to 5=(0.5,0.5,-0.5),
    // 2=(0.5,-0.5,0.5), 7=(-0.5,0.5,0.5).
    foreach (pair; [[6u,5u], [6u,2u], [6u,7u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0, "junction edge not found");
        mask[ei] = true;
    }
    size_t n = m.bevelEdgesByMask(mask, 0.1f);
    assert(n == 3, "should process all 3 junction edges");
    assert(m.vertices.length == 13, "expected 13 verts (3 hubs + 6 bare-end + 4 untouched)");
    assert(m.faces.length    == 10, "expected 10 faces");
    int[int] fvd;
    foreach (f; m.faces) fvd[cast(int)f.length]++;
    assert(fvd.get(4, 0) == 6 && fvd.get(5, 0) == 3 && fvd.get(3, 0) == 1,
        "fv-dist should be {quad:6, pentagon:3, triangle:1}");
    assertBevelManifoldClean(m, "junction cap");
}

unittest { // bevelEdgesByMask: roundLevel DoS clamp — an absurd roundLevel
           // must clamp to MAX_ROUND_LEVEL, not allocate 2^L points (task
           // 0391 Phase 3). A direct/scripted caller can reach this kernel
           // without going through the command/tool Param's `.max()` hint,
           // which is UI/HTTP-only and does not clamp this path.
    auto m = makeCube();
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    size_t n = m.bevelEdgesByMask(mask, 0.1f, 1_000_000);
    assert(n == 1, "should still process (roundLevel clamped, not rejected)");
    // MAX_ROUND_LEVEL=10 → 2·10=20 quad rings for this one edge — bounded,
    // not the ~2000000 the unclamped 2·request would imply.
    assert(m.faces.length > 7 && m.faces.length < 2100,
        "chamfer ring count should reflect the CLAMPED level, not the raw request");
}

unittest { // bevelEdgesByMask: selected interior edge with ONE endpoint on an
           // open-mesh boundary (task 0439, golden test 6). The boundary
           // endpoint itself is supported (the per-vertex pass walks its
           // OPEN fan); the other endpoint is the grid's fully interior
           // vertex 4, a valence-FOUR free end (K == 1). Before task 0439
           // this was a preflight no-op (the removed `keep V` guard rejected
           // vertex 4's shape outright); the source vertex is now always cut
           // and gets its free-end cap (Decision B/C,
           // doc/edge_bevel_freeend_cap_plan.md) instead of a hole.
           //
           // Reference-verified: 12v/6f with a 9-edge rim (the pre-bevel rim
           // is 8, plus one from splitting the boundary vertex). NOTE: an
           // earlier draft of this comment claimed a "12-edge rim, where 8 is
           // correct" — that reading is wrong; 8 is the rim BEFORE the bevel,
           // and the reference's own post-bevel rim is 9, not 8.
    //   0   1   2
    //   3   4   5     <- 2x2 quad grid; vertex 4 is fully interior (valence
    //   6   7   8        4); vertex 1 is a top-boundary vertex (valence 3,
    //                     only 2 faces) — selecting edge (1,4) is interior
    //                     (shared by the 2 top faces) but asymmetric.
    Mesh m;
    m.vertices = [
        Vec3(-1, 1, 0), Vec3(0, 1, 0), Vec3(1, 1, 0),
        Vec3(-1, 0, 0), Vec3(0, 0, 0), Vec3(1, 0, 0),
        Vec3(-1,-1, 0), Vec3(0,-1, 0), Vec3(1,-1, 0),
    ];
    m.addFace([0, 3, 4, 1]);
    m.addFace([1, 4, 5, 2]);
    m.addFace([3, 6, 7, 4]);
    m.addFace([4, 7, 8, 5]);
    m.buildLoops();

    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 1 && b == 4) || (a == 4 && b == 1)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "edge (1,4) not found");
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;

    size_t n = m.bevelEdgesByMask(mask, 0.1f);
    assert(n == 1, "the free-end cap must let this edge bevel, not skip it");
    assert(m.vertices.length == 12 && m.faces.length == 6,
        "boundary-adjacent asymmetric span golden must be 12v/6f");
    static ulong ekey(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
    }
    int[ulong] edgeUse;
    foreach (f; m.faces)
        foreach (k; 0 .. f.length) edgeUse[ekey(f[k], f[(k + 1) % f.length])]++;
    int rim = 0, nonManifold = 0;
    foreach (v; edgeUse.byValue) {
        if (v == 1) ++rim;
        else if (v != 2) ++nonManifold;
    }
    assert(rim == 9, "rim must grow from 8 to 9 edges (one split at the boundary endpoint)");
    // Golden test 6 (doc/edge_bevel_freeend_cap_plan.md §F): full position +
    // connectivity + winding match against task0439_A_freeend_v4grid_L0.
    // All-axis-aligned geometry (no trig), so unlike the disk golden tests
    // below, transcribed decimal literals carry no 5th-decimal rounding-
    // boundary risk.
    static immutable Vec3[] wantVerts = [
        Vec3(-1, -1, 0), Vec3(0, -1, 0), Vec3(1, -1, 0),
        Vec3(-1, 0, 0), Vec3(1, 0, 0), Vec3(-1, 1, 0), Vec3(1, 1, 0),
        Vec3(0, -0.1f, 0), Vec3(0.1f, 0, 0), Vec3(-0.1f, 0, 0),
        Vec3(-0.1f, 1, 0), Vec3(0.1f, 1, 0),
    ];
    static immutable uint[][] wantFaces = [
        [4, 6, 11, 8], [9, 10, 5, 3], [2, 4, 8, 7, 1], [1, 7, 9, 3, 0],
        [10, 9, 8, 11], [7, 8, 9],
    ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "grid 2x2 boundary-adjacent free-end cap");
    assert(nonManifold == 0, "the free-end cap must not introduce a non-manifold edge");
    assertBevelManifoldCleanOpen(m, "grid 2x2 boundary-adjacent free-end cap", 1);
}

unittest { // bevelEdgesByMask: roundLevel=1 end-to-end arc geometry — the
           // single isolated-edge case rounded to a true circular arc
           // (reference-captured law, edge.bevel spec behavior.miter_rail_law).
           // Cross-checked analytically: at vertex 6=(0.5,0.5,0.5), edge (6,7)
           // width=0.1's 2 flat L0 corners are E_A=(0.5,0.5,0.4) and
           // E_B=(0.5,0.4,0.5) (existing L0 unittest above). The arc rounds
           // the corner CONVEXLY, centred at C = E_A + E_B - V6 = (0.5,0.4,0.4)
           // with radius=width, so the L=1 45° bisector bulges TOWARD the
           // original corner: C + 0.1*normalize((0,1,1)) =
           // (0.5, 0.4 + 0.1/sqrt(2), 0.4 + 0.1/sqrt(2)). (The old V-centred
           // arc bulged the WRONG way, to 0.5 - 0.1/sqrt(2) — a concave notch.)
    import std.math : SQRT1_2, abs;
    import std.conv : to;
    auto m = makeCube();
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 1);
    // +1 new interior arc vertex per endpoint (t=1 of 2); the single flat
    // chamfer quad splits into 2 quad rings (+1 face).
    assert(m.vertices.length == 12, "expected 10+2=12 verts at roundLevel=1");
    assert(m.faces.length    == 8,  "expected 7+1=8 faces at roundLevel=1");
    immutable float off = 0.1f * SQRT1_2;
    immutable Vec3 wantV6 = Vec3(0.5f, 0.4f + off, 0.4f + off);
    immutable Vec3 wantV7 = Vec3(-0.5f, 0.4f + off, 0.4f + off);
    bool foundV6 = false, foundV7 = false;
    foreach (v; m.vertices) {
        if ((v - wantV6).length < 1e-4f) foundV6 = true;
        if ((v - wantV7).length < 1e-4f) foundV7 = true;
    }
    assert(foundV6, "L=1 arc midpoint at vertex 6's end not found");
    assert(foundV7, "L=1 arc midpoint at vertex 7's end not found");

    // MANDATORY manifold backstop (post-review hardening): a rounded
    // chamfer strip subdivides its cross-section rail at BOTH endpoints;
    // the "back face" at each bare end must thread that SAME arc (not a
    // stale straight chord) or the rail's edges border only one face — a
    // non-manifold hole. Positions/counts alone (asserted above) do NOT
    // catch this — see the sibling loop/junction tests' own manifold
    // checks above, which this test was previously missing.
    assertBevelManifoldClean(m, "round L1");
    int[int] fvd;
    foreach (f; m.faces) fvd[cast(int)f.length]++;
    // Each back face (g0 at v0, g1 at v1) had V replaced by [predSide, 1
    // shared interior arc vertex, succSide] (n-1=1 interior point at L=1)
    // instead of the flat [predSide, succSide] pair — a quad losing 1
    // corner but gaining 3 gains a net +2 sides: 4→6 (hexagon), not a
    // pentagon (that's the L=0/flat 2-vertex-split shape).
    assert(fvd.get(6, 0) == 2,
        "both back faces should now be hexagons (quad -1 corner +3: predSide/interior/succSide), got " ~
        fvd.to!string);
    assert(fvd.get(4, 0) == 6,
        "4 untouched/fL/fR quads + 2 rounded chamfer-strip quads, got " ~ fvd.to!string);
}

unittest { // bevelEdgesByMask: K=2 miter round profile GOLDEN — a 2-edge
           // shared-vertex miter at cube vertex 6, rounded, matches the
           // reference editor bit-for-bit (edge.bevel spec
           // behavior.miter_rail_law, task 0435 — closes the K2 external gap).
           // Two independent rail families are checked:
           //   • the shared-vertex HUB arc (unequal-radius miter hub);
           //   • the two BARE-END arcs (each a plain K1 corner fillet).
    import std.math : SQRT1_2;
    auto m = makeCube();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[6u,7u], [2u,6u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 2);
    // Same topology as the reference: 8 corners survive minus vertex 6, plus
    // 6 flat miter/slide corners + 3 rounded interior points = 14v/10f.
    assert(m.vertices.length == 14 && m.faces.length == 10,
        "K2 miter L1 must be 14v/10f");
    immutable float off = 0.1f * SQRT1_2;   // 0.0707…
    immutable Vec3[] want = [
        Vec3( 0.4f + off, 0.4f + off, 0.4f + off),  // shared hub arc bisector
        Vec3(-0.5f,       0.4f + off, 0.4f + off),  // bare end at vertex 7
        Vec3( 0.4f + off, 0.4f + off, -0.5f),       // bare end at vertex 2
    ];
    foreach (w; want) {
        bool found = false;
        foreach (v; m.vertices) if ((v - w).length < 1e-4f) { found = true; break; }
        assert(found, "K2 miter L1 reference point not reproduced");
    }
    assertBevelManifoldClean(m, "K2 miter round golden");
}

unittest { // bevelEdgesByMask: NON-90° dihedral round arc is a TRUE circular
           // fillet — radius = width·tan(φ/2), swept 180°−φ (reference-captured
           // general law, edge.bevel generalization_findings, task 0435). The
           // cube's 90° corner is a DEGENERACY (tan45°=1, sweep=90°); a closed
           // equilateral triangular prism has 60°-corner vertical edges that
           // discriminate the general SLERP fillet from the old fixed-90° blend.
    import std.math : tan, abs, PI;
    immutable float h = 0.8660254f;   // sqrt(3)/2, equilateral side 1
    Mesh m;
    m.vertices = [
        Vec3(0, 0, -0.5f), Vec3(1, 0, -0.5f), Vec3(0.5f, h, -0.5f),  // bottom tri
        Vec3(0, 0,  0.5f), Vec3(1, 0,  0.5f), Vec3(0.5f, h,  0.5f),  // top tri
    ];
    m.addFace([0u, 2u, 1u]);          // bottom cap (−Z)
    m.addFace([3u, 4u, 5u]);          // top cap (+Z)
    m.addFace([0u, 1u, 4u, 3u]);      // side A
    m.addFace([1u, 2u, 5u, 4u]);      // side B
    m.addFace([2u, 0u, 3u, 5u]);      // side C
    m.buildLoops();
    m.syncSelection();
    int ei = -1;                      // vertical edge v0–v3 (60°-corner at v0/v3)
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 0 && b == 3) || (a == 3 && b == 0)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0, "prism vertical edge missing");
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 1, "prism edge bevel must apply");
    // At the z=-0.5 end (source V=(0,0,-0.5)) the L0 chamfer corners slide along
    // the two 60°-apart triangle edges: E_A=(0.1,0,-0.5), E_B=(0.05,0.0866,-0.5).
    // The true fillet (r=0.1·tan30°=0.057735, centre from the two-tangent-line
    // intersection, SLERP bisector) puts the level-1 interior point at
    // (0.05, 0.028868, -0.5); the OLD fixed-90° blend gives (0.0439, 0.0254).
    immutable Vec3 wantM = Vec3(0.05f, 0.0288675f, -0.5f);
    bool found = false;
    foreach (v; m.vertices) if ((v - wantM).length < 1e-4f) { found = true; break; }
    assert(found,
        "φ=60° round arc must land on the true fillet bisector (0.05,0.02887,-0.5); "
        ~ "the fixed-90° blend (0.0439,0.0254) is wrong off-cube");
    // Independent geometric check: E_A, M, E_B lie on one circle of radius
    // r=width·tan(φ/2) — the defining fillet property (fails for the old blend).
    immutable Vec3 EA = Vec3(0.1f, 0, -0.5f), EB = Vec3(0.05f, 0.0866025f, -0.5f);
    immutable float sa = (EB - wantM).length, sb = (EA - wantM).length, sc = (EA - EB).length;
    immutable float area = 0.5f * cross(EB - EA, wantM - EA).length;
    immutable float circumR = sa * sb * sc / (4.0f * area);
    immutable float wantR = 0.1f * tan(30.0f * (PI / 180.0f));  // 0.057735
    assert(abs(circumR - wantR) < 1e-4f,
        "fillet circumradius must equal width·tan(φ/2)=0.0577, not the 90° value");
    assertBevelManifoldClean(m, "non-90° prism fillet");
}

unittest { // bevelEdgesByMask: K=2 loop rails are shared at L1 and L2.
           // Rail POSITIONS follow the reference-captured miter law (verified
           // bit-exact on the 2-edge K2 golden above); this 4-turn loop case
           // asserts the shared-rail TOPOLOGY/manifoldness only.
    foreach (level; [1, 2]) {
        auto m = makeCube();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[4u,7u], [7u,6u], [6u,5u], [5u,4u]]) {
            int ei = findEdge(m, pair[0], pair[1]);
            assert(ei >= 0);
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 4);
        immutable int n = 1 << level;
        // L0 has 12 vertices/10 faces.  All four rounded strips gain n-1
        // quads, and the four shared rails own their interiors exactly once.
        assert(m.vertices.length == 12 + 4 * (n - 1));
        assert(m.faces.length == 10 + 4 * (n - 1));
        assertBevelManifoldClean(m, "loop shared rails");
    }
}

unittest { // bevelEdgesByMask: K=3 junction round cap, matches the reference at
           // every Round Level (task 0435). One general L×L Gregory ring:
           // L1=20v/15f (fan), L2=38v/30f, L3=62v/51f.
           // NOTE on "bit-exact": the open-boundary and K3-L0 fixtures ARE
           // bit-for-bit with the dump, but the Gregory hub/ring values here
           // agree only to the position tolerance the comparison uses — our
           // float32 order-of-operations differs from the reference's by a few
           // ULPs (e.g. hub 0.46094760 vs dump 0.46094757), ~1e-7. That rounds
           // identically at posKey's %.5f so the fixture passes, but the older
           // "bit-exact" wording on this law overclaimed; it is tolerance-exact
           // (task 0450 re-sourcing finding).
           // The central Gregory hub is level-independent;
           // the 3 pairwise boundary arcs are geodesics on the corner-rounding
           // sphere (centre V−width·Σn̂) subdivided into 2·L segments (not 2^L).
           // N>=4 junctions take the sibling N-sided ring (junctionRingN,
           // task 0454/0456); this K3 golden is the N==3 path and is unmoved.
           // Provenance (task 0450): the L1 and L2 want* numbers below are
           // transcribed directly FROM the reference capture dump
           // (corner3_level1 / corner3_level2_w01), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's own vertex ordering substitutes
           // directly. This makes the fixture a PARITY guard, not merely a
           // regression guard on our own output. L3 has NO reference dump
           // captured (no level-3 corner dump exists), so the L3 block stays
           // kernel-frozen — a regression guard only — until one is captured.
    import std.math : SQRT1_2;
    foreach (level; [1, 2, 3]) {
        auto m = makeCube();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[6u,5u], [6u,2u], [6u,7u]]) {
            int ei = findEdge(m, pair[0], pair[1]);
            assert(ei >= 0);
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 3);
        // The central Gregory hub is level-independent; present at every level.
        immutable Vec3 wantHub = Vec3(0.460948f, 0.460948f, 0.460948f);
        bool foundHub = false;
        foreach (v; m.vertices) if ((v - wantHub).length < 1e-4f) foundHub = true;
        assert(foundHub, "K3 central Gregory hub (0.4609)³ not reproduced");
        int[int] fvd;
        foreach (f; m.faces) ++fvd[cast(int)f.length];
        if (level == 1) {
            // 13 L0 + 6 rail interiors + 1 HUB = 20v; 10 + 3 strips + 2 (3-quad
            // fan replaces the flat cap) = 15f. The pairwise arc must round to
            // (0.4,0.4707,0.4707), not the (0.4,0.45,0.45) degenerate midpoint.
            assert(m.vertices.length == 20 && m.faces.length == 15,
                "K3 L1 must be the reference 20v/15f hub-fan cap");
            immutable float off = 0.1f * SQRT1_2;
            bool foundBis = false;
            foreach (v; m.vertices)
                if ((v - Vec3(0.4f, 0.4f + off, 0.4f + off)).length < 1e-4f) foundBis = true;
            assert(foundBis, "K3 L1 pairwise arc must be the true-arc bisector");
            // Task 0443: the spot-checks above only ever pinned a handful of
            // positions; the full position+connectivity freeze (every vertex,
            // every face canonicalized over rotation) is what the private
            // scratchpad script actually verified and the repo never kept.
            immutable Vec3[] wantVertsL1 = [
                Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f),
                Vec3(-0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
                Vec3(0.5f, -0.5f, 0.400000006f), Vec3(0.400000006f, -0.5f, 0.5f),
                Vec3(0.400000006f, 0.5f, -0.5f), Vec3(0.5f, 0.400000006f, -0.5f),
                Vec3(0.400000006f, 0.5f, 0.400000006f), Vec3(0.400000006f, 0.400000006f, 0.5f),
                Vec3(0.5f, 0.400000006f, 0.400000006f), Vec3(-0.5f, 0.5f, 0.400000006f),
                Vec3(-0.5f, 0.400000006f, 0.5f), Vec3(0.470710695f, 0.470710695f, -0.5f),
                Vec3(0.470710695f, 0.470710695f, 0.400000006f), Vec3(0.470710695f, -0.5f, 0.470710695f),
                Vec3(0.470710695f, 0.400000006f, 0.470710695f), Vec3(0.400000006f, 0.470710695f, 0.470710695f),
                Vec3(-0.5f, 0.470710695f, 0.470710695f), Vec3(0.460947573f, 0.460947573f, 0.460947573f),
            ];
            static immutable uint[][] wantFacesL1 = [
                [11u, 8u, 6u, 3u], [18u, 11u, 3u, 0u, 2u, 12u], [12u, 2u, 5u, 9u],
                [10u, 4u, 1u, 7u], [6u, 13u, 7u, 1u, 0u, 3u], [1u, 4u, 15u, 5u, 2u, 0u],
                [10u, 7u, 13u, 14u], [14u, 13u, 6u, 8u], [9u, 5u, 15u, 16u],
                [16u, 15u, 4u, 10u], [12u, 9u, 17u, 18u], [18u, 17u, 8u, 11u],
                [8u, 17u, 19u, 14u], [9u, 16u, 19u, 17u], [10u, 14u, 19u, 16u],
            ];
            assertFacesMatchByPosition(m, wantVertsL1, wantFacesL1, "K3 L1 hub-fan cap (task 0443 freeze)");
        } else if (level == 2) {
            // Rational-Gregory interior ring over a 2×2-per-sub-quad grid.
            assert(m.vertices.length == 38 && m.faces.length == 30,
                "K3 L2 must be the reference 38v/30f Gregory-ring cap");
            bool fA = false, fB = false;
            foreach (v; m.vertices) {
                if ((v - Vec3(0.468270f, 0.468270f, 0.435948f)).length < 1e-4f) fA = true;
                if ((v - Vec3(0.439017f, 0.485392f, 0.439017f)).length < 1e-4f) fB = true;
            }
            assert(fA && fB, "K3 L2 Gregory ring must reproduce the typeA + typeB points");
            assert(fvd.get(8, 0) == 3, "K3 L2 must keep the 3 octagon absorber faces");
            // Topology guard: a specific reference cap quad must exist by
            // position — [pairwise-rail interior, typeB, typeA, R bisector].
            // Catches the g-transpose class of bug (the right vertex SET woven
            // with the WRONG connectivity, which a Hausdorff/count/manifold
            // check silently passes — the transpose leaves positions, edge
            // lengths and manifoldness identical, only re-weaving the ring onto
            // the neighbouring sub-quad's rails).
            immutable Vec3[4] wantQuad = [
                Vec3(0.43827f, 0.49239f, 0.4f),      // pairwise-rail interior
                Vec3(0.43902f, 0.48539f, 0.43902f),  // typeB
                Vec3(0.46827f, 0.46827f, 0.43595f),  // typeA
                Vec3(0.47071f, 0.47071f, 0.4f),      // R bisector
            ];
            bool foundQuad = false;
            foreach (f; m.faces) {
                if (f.length != 4) continue;
                int matched = 0;
                foreach (w; wantQuad)
                    foreach (vi; f) if ((m.vertices[vi] - w).length < 1e-4f) { ++matched; break; }
                if (matched == 4) { foundQuad = true; break; }
            }
            assert(foundQuad,
                "K3 L2 ring must weave the reference [rail,typeB,typeA,R] quad; a "
                ~ "count/manifold-clean pass with the wrong connectivity fails here");
            // Task 0443: full position+connectivity freeze (see the L1 branch
            // above for why the topology-guard quad alone isn't enough).
            immutable Vec3[] wantVertsL2 = [
                Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f),
                Vec3(-0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
                Vec3(0.5f, -0.5f, 0.400000006f), Vec3(0.400000006f, -0.5f, 0.5f),
                Vec3(0.400000006f, 0.5f, -0.5f), Vec3(0.5f, 0.400000006f, -0.5f),
                Vec3(0.400000006f, 0.5f, 0.400000006f), Vec3(0.400000006f, 0.400000006f, 0.5f),
                Vec3(0.5f, 0.400000006f, 0.400000006f), Vec3(-0.5f, 0.5f, 0.400000006f),
                Vec3(-0.5f, 0.400000006f, 0.5f), Vec3(0.49238795f, 0.438268334f, -0.5f),
                Vec3(0.49238795f, 0.438268334f, 0.400000006f), Vec3(0.470710695f, 0.470710695f, -0.5f),
                Vec3(0.470710695f, 0.470710695f, 0.400000006f), Vec3(0.438268334f, 0.49238795f, -0.5f),
                Vec3(0.438268334f, 0.49238795f, 0.400000006f), Vec3(0.438268334f, -0.5f, 0.49238795f),
                Vec3(0.438268334f, 0.400000006f, 0.49238795f), Vec3(0.470710695f, -0.5f, 0.470710695f),
                Vec3(0.470710695f, 0.400000006f, 0.470710695f), Vec3(0.49238795f, -0.5f, 0.438268334f),
                Vec3(0.49238795f, 0.400000006f, 0.438268334f), Vec3(0.400000006f, 0.438268334f, 0.49238795f),
                Vec3(-0.5f, 0.438268334f, 0.49238795f), Vec3(0.400000006f, 0.470710695f, 0.470710695f),
                Vec3(-0.5f, 0.470710695f, 0.470710695f), Vec3(0.400000006f, 0.49238795f, 0.438268334f),
                Vec3(-0.5f, 0.49238795f, 0.438268334f), Vec3(0.460947573f, 0.460947573f, 0.460947573f),
                Vec3(0.468269914f, 0.468269914f, 0.435947567f), Vec3(0.439017057f, 0.485392362f, 0.439017057f),
                Vec3(0.435947567f, 0.468269914f, 0.468269914f), Vec3(0.439017057f, 0.439017057f, 0.485392362f),
                Vec3(0.468269914f, 0.435947567f, 0.468269914f), Vec3(0.485392362f, 0.439017057f, 0.439017057f),
            ];
            static immutable uint[][] wantFacesL2 = [
                [11u, 8u, 6u, 3u], [26u, 28u, 30u, 11u, 3u, 0u, 2u, 12u], [12u, 2u, 5u, 9u],
                [10u, 4u, 1u, 7u], [6u, 17u, 15u, 13u, 7u, 1u, 0u, 3u], [1u, 4u, 23u, 21u, 19u, 5u, 2u, 0u],
                [10u, 7u, 13u, 14u], [14u, 13u, 15u, 16u], [16u, 15u, 17u, 18u],
                [18u, 17u, 6u, 8u], [9u, 5u, 19u, 20u], [20u, 19u, 21u, 22u],
                [22u, 21u, 23u, 24u], [24u, 23u, 4u, 10u], [12u, 9u, 25u, 26u],
                [26u, 25u, 27u, 28u], [28u, 27u, 29u, 30u], [30u, 29u, 8u, 11u],
                [8u, 29u, 33u, 18u], [18u, 33u, 32u, 16u], [29u, 27u, 34u, 33u],
                [33u, 34u, 31u, 32u], [9u, 20u, 35u, 25u], [25u, 35u, 34u, 27u],
                [20u, 22u, 36u, 35u], [35u, 36u, 31u, 34u], [10u, 14u, 37u, 24u],
                [24u, 37u, 36u, 22u], [14u, 16u, 32u, 37u], [37u, 32u, 31u, 36u],
            ];
            assertFacesMatchByPosition(m, wantVertsL2, wantFacesL2, "K3 L2 Gregory ring (task 0443 freeze)");
        } else {
            // Round Level 3: general L×L Gregory ring — the arc is subdivided
            // into 2·L segments (5 rail interiors), not 2^L. 62v/51f {quad:48,
            // decagon:3}, bit-exact.
            assert(m.vertices.length == 62 && m.faces.length == 51,
                "K3 L3 must be the reference 62v/51f Gregory-ring cap");
            assert(fvd.get(10, 0) == 3, "K3 L3 must keep the 3 decagon absorber faces");
            // Task 0443: full position+connectivity freeze.
            immutable Vec3[] wantVertsL3 = [
                Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f),
                Vec3(-0.5f, 0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
                Vec3(0.400000006f, 0.5f, -0.5f), Vec3(0.5f, 0.400000006f, -0.5f),
                Vec3(0.5f, -0.5f, 0.400000006f), Vec3(0.400000006f, -0.5f, 0.5f),
                Vec3(0.400000006f, 0.5f, 0.400000006f), Vec3(0.400000006f, 0.400000006f, 0.5f),
                Vec3(0.5f, 0.400000006f, 0.400000006f), Vec3(-0.5f, 0.5f, 0.400000006f),
                Vec3(-0.5f, 0.400000006f, 0.5f),
                Vec3(0.400000006f, 0.496592581f, 0.425881922f), Vec3(0.400000006f, 0.486602545f, 0.449999988f),
                Vec3(0.400000006f, 0.470710695f, 0.470710695f), Vec3(0.400000006f, 0.449999988f, 0.486602545f),
                Vec3(0.400000006f, 0.425881922f, 0.496592581f), Vec3(0.425881922f, 0.400000006f, 0.496592581f),
                Vec3(0.449999988f, 0.400000006f, 0.486602545f), Vec3(0.470710695f, 0.400000006f, 0.470710695f),
                Vec3(0.486602545f, 0.400000006f, 0.449999988f), Vec3(0.496592581f, 0.400000006f, 0.425881922f),
                Vec3(0.425881922f, 0.496592581f, 0.400000006f), Vec3(0.449999988f, 0.486602545f, 0.400000006f),
                Vec3(0.470710695f, 0.470710695f, 0.400000006f), Vec3(0.486602545f, 0.449999988f, 0.400000006f),
                Vec3(0.496592581f, 0.425881922f, 0.400000006f),
                Vec3(0.496592581f, -0.5f, 0.425881922f), Vec3(0.486602545f, -0.5f, 0.449999988f),
                Vec3(0.470710695f, -0.5f, 0.470710695f), Vec3(0.449999988f, -0.5f, 0.486602545f),
                Vec3(0.425881922f, -0.5f, 0.496592581f),
                Vec3(-0.5f, 0.496592581f, 0.425881922f), Vec3(-0.5f, 0.486602545f, 0.449999988f),
                Vec3(-0.5f, 0.470710695f, 0.470710695f), Vec3(-0.5f, 0.449999988f, 0.486602545f),
                Vec3(-0.5f, 0.425881922f, 0.496592581f),
                Vec3(0.425881922f, 0.496592581f, -0.5f), Vec3(0.449999988f, 0.486602545f, -0.5f),
                Vec3(0.470710695f, 0.470710695f, -0.5f), Vec3(0.486602545f, 0.449999988f, -0.5f),
                Vec3(0.496592581f, 0.425881922f, -0.5f),
                Vec3(0.460947603f, 0.460947603f, 0.460947603f),
                Vec3(0.425181419f, 0.46962586f, 0.46962586f), Vec3(0.445497334f, 0.466371536f, 0.466371536f),
                Vec3(0.426759779f, 0.493034244f, 0.426759779f), Vec3(0.426775515f, 0.483684719f, 0.4503932f),
                Vec3(0.4503932f, 0.483684719f, 0.426775575f), Vec3(0.449284881f, 0.476583421f, 0.449284822f),
                Vec3(0.46962586f, 0.425181419f, 0.46962586f), Vec3(0.466371536f, 0.445497334f, 0.466371536f),
                Vec3(0.426759779f, 0.426759779f, 0.493034244f), Vec3(0.4503932f, 0.426775515f, 0.483684719f),
                Vec3(0.426775575f, 0.4503932f, 0.483684719f), Vec3(0.449284822f, 0.449284881f, 0.476583421f),
                Vec3(0.46962586f, 0.46962586f, 0.425181419f), Vec3(0.466371536f, 0.466371536f, 0.445497334f),
                Vec3(0.493034244f, 0.426759779f, 0.426759779f), Vec3(0.483684719f, 0.4503932f, 0.426775515f),
                Vec3(0.483684719f, 0.426775575f, 0.4503932f), Vec3(0.476583421f, 0.449284822f, 0.449284881f),
            ];
            static immutable uint[][] wantFacesL3 = [
                [0u, 2u, 4u, 38u, 39u, 40u, 41u, 42u, 5u, 1u], [3u, 7u, 9u, 12u],
                [0u, 3u, 12u, 37u, 36u, 35u, 34u, 33u, 11u, 2u], [1u, 5u, 10u, 6u],
                [2u, 11u, 8u, 4u], [0u, 1u, 6u, 28u, 29u, 30u, 31u, 32u, 7u, 3u],
                [6u, 10u, 22u, 28u], [28u, 22u, 21u, 29u], [29u, 21u, 20u, 30u],
                [30u, 20u, 19u, 31u], [31u, 19u, 18u, 32u], [32u, 18u, 9u, 7u],
                [8u, 11u, 33u, 13u], [13u, 33u, 34u, 14u], [14u, 34u, 35u, 15u],
                [15u, 35u, 36u, 16u], [16u, 36u, 37u, 17u], [17u, 37u, 12u, 9u],
                [4u, 8u, 23u, 38u], [38u, 23u, 24u, 39u], [39u, 24u, 25u, 40u],
                [40u, 25u, 26u, 41u], [41u, 26u, 27u, 42u], [42u, 27u, 10u, 5u],
                [8u, 13u, 46u, 23u], [13u, 14u, 47u, 46u], [14u, 15u, 44u, 47u],
                [23u, 46u, 48u, 24u], [46u, 47u, 49u, 48u], [47u, 44u, 45u, 49u],
                [24u, 48u, 56u, 25u], [48u, 49u, 57u, 56u], [49u, 45u, 43u, 57u],
                [9u, 18u, 52u, 17u], [18u, 19u, 53u, 52u], [19u, 20u, 50u, 53u],
                [17u, 52u, 54u, 16u], [52u, 53u, 55u, 54u], [53u, 50u, 51u, 55u],
                [16u, 54u, 44u, 15u], [54u, 55u, 45u, 44u], [55u, 51u, 43u, 45u],
                [10u, 27u, 58u, 22u], [27u, 26u, 59u, 58u], [26u, 25u, 56u, 59u],
                [22u, 58u, 60u, 21u], [58u, 59u, 61u, 60u], [59u, 56u, 57u, 61u],
                [21u, 60u, 50u, 20u], [60u, 61u, 51u, 50u], [61u, 57u, 43u, 51u],
            ];
            assertFacesMatchByPosition(m, wantVertsL3, wantFacesL3, "K3 L3 Gregory ring (task 0443 freeze)");
        }
        assertBevelManifoldClean(m, "junction shared rails");
    }
}

unittest { // bevelEdgesByMask: DEGENERATE ("parallel-edge") K3 hub — the shape
           // on which the N=3 and N≥4 ring branches disagree (task 0698).
           //
           // The two branches gate a side on DIFFERENT flags: N=3 on `hasBez`
           // (set for every full hub, no non-degeneracy test), N≥4 on `hubRail`
           // (`hasBez` AND distinct poles AND distinct finding-(I) pivots). They
           // can only differ where one of those two extra tests fails, so this
           // fixture makes one fail EXACTLY: cube vertex 7 is moved onto the ray
           // 6→5, which makes `dir(6→7) == dir(6→5)` bit-for-bit. The rail along
           // edge (6,2) then takes its two neighbour pivots from edges 6→5 and
           // 6→7 — the same direction, so |jA − jB| == 0 exactly — and is
           // registered `hasBez=true, hubRail=false`. (Measured with the two
           // lengths printed from `registerRail`: |jA−jB| = 0, |P0−P3| = 0.0786;
           // every rail of the pristine cube reads 0.1414 for both.)
           //
           // WHAT THIS TEST IS. It is a one-sided characterization, NOT a parity
           // freeze: no reference capture covers a degenerate hub (the four
           // `tests/fixtures/edge_bevel_*.json` goldens are a pristine cube and
           // an open grid, and the `edge_bevel_*` rows of
           // `tests/fixtures/uv_corner_transfer.json` are a flat grid with a
           // single selected edge — none of them reaches a hub cap ring at all),
           // so there is no `reference_*` half to record and none is invented
           // here. It pins what vibe3d does TODAY so that the divergence is a
           // measurement instead of a code reading, and so that the day task 0707
           // settles the rule, the change is visible rather than silent.
           //
           // THE MEASURED ALTERNATIVE. Swapping the N=3 branch's gate to
           // `hubRail` (i.e. applying the N≥4 rule here) leaves the pristine cube
           // untouched at 20v/15f and 38v/30f, and turns THIS fixture into
           // 19v/13f at L1 and 31v/19f at L2: the ring is dropped and the cap
           // becomes one flat n-gon (a hexagon at L1, a 12-gon at L2) bounded by
           // the still-rounded arcs. Both outcomes are defensible; picking one is
           // 0707's job, not this test's.
    static Mesh parallelEdgeHub() {
        auto mm = makeCube();
        // v7 = (-0.5, 0.5, 0.5) -> onto the ray 6→5. Both offsets are exact
        // binary fractions, so the two normalized directions are bit-equal.
        mm.vertices[7] = Vec3(0.5f, 0.0f, 0.5f);
        mm.buildLoops();
        return mm;
    }
    {
        // The fixture's defining property, asserted in the same terms
        // `neighPivot` computes the pivots in — if this stops holding the test
        // below is measuring an ordinary hub and proves nothing.
        auto m = parallelEdgeHub();
        immutable Vec3 d5 = safeNormalize(m.vertices[5] - m.vertices[6]);
        immutable Vec3 d7 = safeNormalize(m.vertices[7] - m.vertices[6]);
        assert(d5.x == d7.x && d5.y == d7.y && d5.z == d7.z,
            "degenerate-K3 fixture must have edges 6→5 and 6→7 exactly parallel");
        int deg = 0;
        foreach (ei; m.edgesAroundVertex(6)) ++deg;
        assert(deg == 3, "degenerate-K3 fixture must keep vertex 6 at valence 3");
    }
    foreach (level; [1, 2]) {
        auto m = parallelEdgeHub();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[6u, 5u], [6u, 2u], [6u, 7u]]) {
            immutable int ei = findEdge(m, pair[0], pair[1]);
            assert(ei >= 0);
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 3);
        int[int] fvd;
        foreach (f; m.faces) ++fvd[cast(int)f.length];
        if (level == 1) {
            assert(m.vertices.length == 20 && m.faces.length == 15,
                "degenerate K3 hub rounds TODAY (20v/15f); the N≥4 rule would "
                ~ "give 19v/13f — see task 0707 before changing either gate");
            // The ring signature: three cap quads and no flat cap n-gon. Under
            // the N≥4 rule the three quads collapse into a fourth hexagon.
            assert(fvd.get(6, 0) == 3 && fvd.get(4, 0) == 12,
                "L1 degenerate hub must emit the 3-quad Gregory fan, not a flat "
                ~ "hexagonal cap");
        } else {
            assert(m.vertices.length == 38 && m.faces.length == 30,
                "degenerate K3 hub rounds TODAY (38v/30f); the N≥4 rule would "
                ~ "give 31v/19f — see task 0707 before changing either gate");
            assert(fvd.get(12, 0) == 0,
                "L2 degenerate hub must not emit the flat 12-gon cap");
        }
        // The degeneracy IS visible in the output: the sliver face (6,5,…,7),
        // whose two edges at the corner are parallel, takes `offsetMeet`'s
        // parallel fallback, whose two perpendicular offsets are opposite — so
        // its miter lands EXACTLY on the uncut corner. That pole is what the
        // ring is then built on. The pristine cube's K3 golden has no vertex
        // there (every corner is cut), so this is a real discriminator.
        bool uncutPole = false;
        foreach (v; m.vertices)
            if (v.x == 0.5f && v.y == 0.5f && v.z == 0.5f) uncutPole = true;
        assert(uncutPole,
            "the sliver face's miter must land on the uncut corner — without it "
            ~ "this fixture is no longer the degenerate shape task 0698 measured");
    }
}

unittest { // bevelEdgesByMask: mixed adjacent K2 at a valence-4 octahedron
           // (task 0439). Vertex 0's own K=2-adjacent shape was already
           // MITER/SLIDE-supported pre-0439 (one miter + one both-unselected
           // face); what used to reject this case was its two selected
           // edges' FAR endpoints (vertices 1 and 2), each a valence-4 K=1
           // free end whose middle unselected edge was "inactive" by the old
           // `keep V` guard. That guard is gone (Decision A/C,
           // doc/edge_bevel_freeend_cap_plan.md) — both far ends now get
           // their own triangular free-end cap, and vertex 0's ring (1 miter
           // + 2 slides) gets its own triangular cap too.
    Mesh makeValence4Octahedron() {
        Mesh m;
        m.vertices = [
            Vec3( 0, 1, 0), Vec3( 1, 0, 0), Vec3(0, 0, 1),
            Vec3(-1, 0, 0), Vec3( 0, 0,-1), Vec3(0,-1, 0),
        ];
        // Closed, consistently wound octahedron.  Vertex 0 has valence four.
        m.addFace([0u, 2u, 1u]); m.addFace([0u, 3u, 2u]);
        m.addFace([0u, 4u, 3u]); m.addFace([0u, 1u, 4u]);
        m.addFace([5u, 1u, 2u]); m.addFace([5u, 2u, 3u]);
        m.addFace([5u, 3u, 4u]); m.addFace([5u, 4u, 1u]);
        m.buildLoops();
        m.syncSelection(); // grow parallel marks/material/part arrays after addFace
        m.faceMaterial[0] = 7u; m.facePart[0] = 23u;
        m.setFaceSubpatch(0, true);
        m.selectFace(0);
        return m;
    }
    bool[] selectPairs(ref Mesh m, uint[][] pairs) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; pairs) {
            int ei = -1;
            foreach (i; 0 .. m.edges.length) {
                uint a = m.edges[i][0], b = m.edges[i][1];
                if ((a == pair[0] && b == pair[1]) || (a == pair[1] && b == pair[0])) {
                    ei = cast(int)i;
                    break;
                }
            }
            assert(ei >= 0, "selected octahedron edge missing");
            mask[ei] = true;
        }
        return mask;
    }

    auto m = makeValence4Octahedron();
    auto mask = selectPairs(m, [[0u, 1u], [0u, 2u]]);
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 2,
        "mixed adjacent K2 must now bevel both edges");
    // task 0449: the two far-endpoint free-end caps are now a second
    // support-consumer for their own bordering rails, so Round Level 1
    // rounds them too (was 12v/13f flat before this task).
    assert(m.vertices.length == 16 && m.faces.length == 15,
        "adjacent K2 valence-4 octahedron golden must be 16v/15f at Round Level 1");
    assertBevelManifoldClean(m, "adjacent valence-4 K2 free-end cap");
}

unittest { // bevelEdgesByMask: non-adjacent K2 at valence four (task 0439).
           // Vertex 0's own alternating-K2 shape resolves to MITER/SLIDE
           // only (no both-unselected face at all, so no cap forms there —
           // its ring is exactly 2 slides, degenerate, like a valence-3 free
           // end); what used to reject this case was — exactly as in the
           // adjacent-K2 sibling above — its two selected edges' FAR
           // endpoints (vertices 1 and 3), each a valence-4 K=1 free end.
           // Both now get their own triangular free-end cap instead of
           // hitting the removed `keep V` guard.
    Mesh makeValence4Octahedron() {
        Mesh m;
        m.vertices = [
            Vec3( 0, 1, 0), Vec3( 1, 0, 0), Vec3(0, 0, 1),
            Vec3(-1, 0, 0), Vec3( 0, 0,-1), Vec3(0,-1, 0),
        ];
        m.addFace([0u, 2u, 1u]); m.addFace([0u, 3u, 2u]);
        m.addFace([0u, 4u, 3u]); m.addFace([0u, 1u, 4u]);
        m.addFace([5u, 1u, 2u]); m.addFace([5u, 2u, 3u]);
        m.addFace([5u, 3u, 4u]); m.addFace([5u, 4u, 1u]);
        m.buildLoops();
        m.syncSelection(); // grow parallel marks/material/part arrays after addFace
        m.faceMaterial[0] = 7u; m.facePart[0] = 23u;
        m.setFaceSubpatch(0, true);
        m.selectFace(0);
        return m;
    }
    bool[] selectPairs(ref Mesh m) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[0u, 1u], [0u, 3u]]) {
            int ei = -1;
            foreach (i; 0 .. m.edges.length) {
                uint a = m.edges[i][0], b = m.edges[i][1];
                if ((a == pair[0] && b == pair[1]) || (a == pair[1] && b == pair[0])) {
                    ei = cast(int)i;
                    break;
                }
            }
            assert(ei >= 0, "non-adjacent K2 octahedron edge missing");
            mask[ei] = true;
        }
        return mask;
    }
    auto m = makeValence4Octahedron();
    auto mask = selectPairs(m);
    assert(m.bevelEdgesByMask(mask, 0.1f, 1) == 2,
        "non-adjacent K2 must now bevel both edges");
    // task 0449: same second-consumer registration as the adjacent sibling
    // above — was 11v/12f flat before this task.
    assert(m.vertices.length == 14 && m.faces.length == 14,
        "non-adjacent K2 valence-4 octahedron golden must be 14v/14f at Round Level 1");
    assertBevelManifoldClean(m, "non-adjacent valence-4 K2 free-end cap");
}

unittest { // bevelEdgesByMask: a two-face HINGE must not take the process down.
           // Regression for a crash the reference-diff suite surfaced the
           // moment it was re-enabled: `edgeOtherVertex: vi does not belong to
           // edge ei`, asserted from the per-vertex fan pass and fatal to the
           // whole application when reached through the tool.
           //
           // The cause is NOT in this function. On this shape
           // `edgesAroundVertex` yields an edge that is not incident to the
           // vertex at all — at V=0 it returns the edge (3,1) — while the
           // counts still look healthy (2 faces, 3 edges, so it reads as a
           // well-formed open fan). The walk is wrong, and every operation
           // that iterates a vertex fan sees the same bad edge; that is
           // tracked separately. Here we only require that the bevel treats
           // it as the malformed fan it is and declines, rather than
           // asserting.
    Mesh hinge() {
        // Two quads sharing the spine (0,1), nothing else at either endpoint.
        Mesh m;
        m.vertices = [
            Vec3(0, 0, 1), Vec3(0, 0, -1),
            Vec3(1, 0, 1), Vec3(1, 0, -1),
            Vec3(-0.5f, 0.866025f, 1), Vec3(-0.5f, 0.866025f, -1),
        ];
        m.addFace([0u, 2u, 3u, 1u]);
        m.addFace([0u, 4u, 5u, 1u]);
        m.buildLoops();
        m.syncSelection();
        return m;
    }

    // Premise (task 0447 KEEP-TWIN — this block moved when the fan-walk
    // defect was fixed): the walk USED to return a foreign edge here (at V=0
    // it yielded edge (3,1), which contains neither endpoint). The fix makes
    // the walk return ONLY incident edges, and flags the inconsistently-wound
    // spine endpoints as NOT fan-ordered so slot-position consumers decline.
    // Revisit — do not delete — if this ever changes.
    {
        auto m = hinge();
        bool sawForeignEdge = false;
        foreach (V; 0 .. cast(uint)m.vertices.length)
            foreach (ei; m.edgesAroundVertex(V)) {
                immutable uint a = m.edges[ei][0], b = m.edges[ei][1];
                if (a != V && b != V) { sawForeignEdge = true; break; }
            }
        assert(!sawForeignEdge,
            "fan walk must no longer return a foreign edge on the hinge");
        // The spine (0,1) is traversed the same direction by both faces, so
        // both its endpoints are marked unordered; the page-tip vertices
        // (2,3,4,5) sit on no same-direction edge and stay ordered.
        assert(!m.vertexFanOrdered(0) && !m.vertexFanOrdered(1),
            "hinge spine endpoints must be flagged not-fan-ordered");
        foreach (uint V; [2u, 3u, 4u, 5u])
            assert(m.vertexFanOrdered(V),
                "hinge page-tip vertices must stay fan-ordered");
    }

    bool[] edgeMaskFor(ref Mesh m, uint pa, uint pb) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (i; 0 .. m.edges.length) {
            immutable uint a = m.edges[i][0], b = m.edges[i][1];
            if ((a == pa && b == pb) || (a == pb && b == pa)) { mask[i] = true; break; }
        }
        return mask;
    }
    // Pairs that TOUCH the inconsistently-wound spine (vertex 0/1, flagged
    // not-fan-ordered above): the bevel must DECLINE, not assert, and leave
    // the mesh byte-identical. [0,1] is the spine itself; [0,2] is a rim edge
    // with one endpoint (v0) on the malformed spine.
    foreach (pair; [[0u, 1u], [0u, 2u]])
        foreach (level; 0 .. 2) {
            auto m = hinge();
            auto mask = edgeMaskFor(m, pair[0], pair[1]);
            auto vertsBefore = m.vertices.dup;
            auto facesBefore = m.faces._store.dup;
            // Completing at all is the regression check — this used to assert.
            assert(m.bevelEdgesByMask(mask, 0.15f, cast(int)level) == 0,
                "a malformed fan must decline, not assert");
            assert(m.vertices == vertsBefore && m.faces._store == facesBefore,
                "the decline must leave the mesh byte-identical");
        }

    // Edge [2,3] is a CLEAN boundary edge of one page (face [0,2,3,1]) whose
    // two endpoints (v2, v3) are page-tip corners with a single incident face
    // each — fan-ordered, NOT on the malformed spine. It is exactly the open-
    // mesh rim end-cap shape, so the single-incident-face rim-corner path must
    // BEVEL it (asymmetric 1-vs-2 split → the touched quad becomes a pentagon,
    // 6v/2f → 7v/2f), leaving the untouched page unchanged.
    foreach (level; 0 .. 2) {
        auto m = hinge();
        auto mask = edgeMaskFor(m, 2u, 3u);
        assert(m.bevelEdgesByMask(mask, 0.15f, cast(int)level) == 1,
            "a clean rim edge off the malformed spine must bevel, not decline");
        assert(m.vertices.length == 7 && m.faces.length == 2,
            "hinge rim-edge bevel golden must be 7v/2f");
    }
}

unittest { // bevelEdgesByMask on a CLOSED inverted cube: task 0447. Closedness
           // does not immunise a mesh — flipping one face makes all four of
           // its shared edges same-direction, so its four corner vertices are
           // NOT vertexFanOrdered. Selecting that face's edges must make bevel
           // DECLINE (every affected vertex is unordered), leaving the mesh
           // byte-identical. This is the motivating-scenario point fixture
           // (the generative bevel census over inverted variants is 0445).
    Mesh cubeFlip2() {
        Mesh m = makeCube();
        bool[] fm = new bool[](m.faces.length);
        fm[2] = true;               // flip face 2 = [0,4,7,3]
        m.flipFacesByMask(fm);
        m.syncSelection();
        return m;
    }
    {
        auto m = cubeFlip2();
        // The four corners of the flipped face are unordered; the rest ordered.
        foreach (uint V; [0u, 3u, 4u, 7u])
            assert(!m.vertexFanOrdered(V), "flipped-face corner must be unordered");
        foreach (uint V; [1u, 2u, 5u, 6u])
            assert(m.vertexFanOrdered(V), "non-flipped corner must stay ordered");
    }
    // Select the four edges of the flipped face; both endpoints of each are
    // unordered, so the whole selection declines.
    foreach (level; 0 .. 2) {
        auto m = cubeFlip2();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (pair; [[3u, 7u], [7u, 4u], [4u, 0u], [0u, 3u]])
            foreach (i; 0 .. m.edges.length) {
                immutable uint a = m.edges[i][0], b = m.edges[i][1];
                if ((a == pair[0] && b == pair[1]) || (a == pair[1] && b == pair[0])) {
                    mask[i] = true; break;
                }
            }
        auto vertsBefore = m.vertices.dup;
        auto facesBefore = m.faces._store.dup;
        assert(m.bevelEdgesByMask(mask, 0.15f, cast(int)level) == 0,
            "inverted-cube unordered selection must decline");
        assert(m.vertices == vertsBefore && m.faces._store == facesBefore,
            "the decline must leave the inverted cube byte-identical");
    }
}

unittest { // bevelEdgesByMask: K=3 junction Round Level 0 — the flat N-gon
           // cap (task 0443 freeze). Companion to the L1/L2/L3 Gregory-ring
           // test above; same cube corner, same width, no rounding at all.
           // Full position+connectivity freeze. Provenance (task 0450): the
           // want* numbers below are transcribed directly FROM the reference
           // capture dump (corner3_sharp0), not from our kernel's output, so
           // this is a PARITY guard — assertFacesMatchByPosition canonicalises
           // by position+connectivity, letting the reference's own vertex
           // ordering substitute directly.
    auto m = makeCube();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[6u,5u], [6u,2u], [6u,7u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 3);
    assert(m.vertices.length == 13 && m.faces.length == 10,
        "K3 L0 must be the reference 13v/10f flat cap");
    immutable Vec3[] wantVerts = [
        Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f),
        Vec3(-0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
        Vec3(0.5f, -0.5f, 0.400000006f), Vec3(0.400000006f, -0.5f, 0.5f),
        Vec3(0.400000006f, 0.5f, -0.5f), Vec3(0.5f, 0.400000006f, -0.5f),
        Vec3(0.400000006f, 0.5f, 0.400000006f), Vec3(0.400000006f, 0.400000006f, 0.5f),
        Vec3(0.5f, 0.400000006f, 0.400000006f), Vec3(-0.5f, 0.5f, 0.400000006f),
        Vec3(-0.5f, 0.400000006f, 0.5f),
    ];
    static immutable uint[][] wantFaces = [
        [11u, 8u, 6u, 3u], [11u, 3u, 0u, 2u, 12u], [12u, 2u, 5u, 9u],
        [10u, 4u, 1u, 7u], [6u, 7u, 1u, 0u, 3u], [1u, 4u, 5u, 2u, 0u],
        [10u, 7u, 6u, 8u], [9u, 5u, 4u, 10u], [12u, 9u, 8u, 11u],
        [8u, 9u, 10u],
    ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "K3 L0 flat cap (task 0443 freeze)");
    assertBevelManifoldClean(m, "K3 L0 flat cap");
}

unittest { // bevelEdgesByMask: a K3 junction whose far endpoints are valence-4
           // FREE ENDS must not assert. Regression for a crash that reached a
           // user (`rounded edge bevel rail must be approved before
           // materialization`, hit through the tool's live preview).
           //
           // The two cap mechanisms meet in one operation here: the corner is a
           // full ring (K == valence == 3) and takes the hub-cap path, while its
           // three far endpoints are valence-4 free ends and take the cap added
           // by task 0439. Before task 0449 that far-endpoint cap withheld its
           // rails' second consumer, so the whole span run degraded to L0 at
           // EVERY requested level (34v/31f regardless of level) — this test
           // used to be titled "cap-bearing free ends degrade the whole run to
           // L0". Since 0449 the far cap IS its rails' second consumer, so the
           // hub and its three free ends now round INDEPENDENTLY at Round
           // Level > 0 (capture-verified composition — the reference's own
           // used-vertex counts for this exact shape are 41/59/83, and since
           // this task reproduces the Decision-C free-end cap on all three
           // valence-4 free ends, we now emit the reference's 3 orphaned
           // opposite-edge slides too, so our TOTAL counts are 44/62/86 =
           // 41/59/83 used + 3 orphans, matching the reference vertex array
           // in full). The K3 Gregory branch still must not assume its own
           // rails are
           // approved just because they usually are now — it checks approval
           // and falls back to the flat cap on any span the fixed point
           // withholds for some OTHER reason, which is what this test still
           // regression-guards.
           //
           // Unreachable before 0439: the valence-4 free ends were refused
           // outright, so the junction never got the chance to round.
    import std.conv : to;
    // A once-subdivided cube is exactly this shape: 26v/24f, corner vertices at
    // valence 3, every one of their neighbours at valence 4.
    auto probe = subdivideCube(1);
    int corner = -1;
    foreach (V; 0 .. cast(uint)probe.vertices.length) {
        size_t d = 0;
        foreach (fi; probe.facesAroundVertex(V)) ++d;
        if (d == 3) { corner = cast(int)V; break; }
    }
    assert(corner >= 0, "a subdivided cube must have a valence-3 corner");
    {
        size_t d = 0, e = 0;
        foreach (fi; probe.facesAroundVertex(cast(uint)corner)) ++d;
        foreach (ei; probe.edgesAroundVertex(cast(uint)corner)) ++e;
        assert(d == 3 && e == 3, "corner must be a closed valence-3 fan");
        foreach (ei; probe.edgesAroundVertex(cast(uint)corner)) {
            immutable uint far = probe.edgeOtherVertex(ei, cast(uint)corner);
            size_t fd = 0;
            foreach (fi; probe.facesAroundVertex(far)) ++fd;
            assert(fd == 4, "each far endpoint must be valence 4 for this regression");
        }
    }

    // task 0449: L0 never rounds by definition (stays the flat 34v/31f base),
    // but L1/L2 now round the hub AND all three free-end caps independently.
    // This task: the three valence-4 free ends' selected edges land on the K3
    // corner (a FULL HUB), so each reproduces the Decision-C cap — the raw
    // free-end original is RETAINED and its opposite-edge slide kept as an
    // ORPHAN, adding +3 verts over the pre-task 41/59 counts ⇒ 44/62.
    static immutable size_t[3] wantV = [34, 44, 62];
    static immutable size_t[3] wantF = [31, 36, 51];
    foreach (level; 0 .. 3) {
        auto m = subdivideCube(1);
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        size_t sel = 0;
        foreach (ei; m.edgesAroundVertex(cast(uint)corner)) { mask[ei] = true; ++sel; }
        assert(sel == 3, "expected the corner's three edges");
        // The assertion this guards against fired inside the kernel, so simply
        // completing is the regression check; the counts pin the composed
        // (hub + 3 independent Decision-C free-end caps) result at each level.
        immutable size_t n = m.bevelEdgesByMask(mask, 0.05f, cast(int)level);
        assert(n == 3, "all three junction edges must bevel at every Round Level");
        assert(m.vertices.length == wantV[level] && m.faces.length == wantF[level],
            "K3 hub and its three valence-4 free ends must round independently "
            ~ "at Round Level " ~ level.to!string);
        assertBevelManifoldClean(m, "K3 junction with valence-4 free ends");
    }
}

unittest { // bevelEdgesByMask: open-boundary "chain3" (task 0443 freeze) —
           // 3-edge chain E-F,F-G,G-H (three of the +X face's four edges); both
           // chain ends sit on the open rim. BASE = unit cube -0.5..0.5 with one (or, for
           // "bothends", two) face(s) omitted, leaving an open rim.
           // Reference-verified at width=0.15, Round Level 0/1/2 (task
           // 0391's open-boundary law + its Round Level follow-up) — full
           // position+connectivity freeze, not just the vertex/face counts
           // the repo kept until now. Provenance (task 0450): the want*
           // numbers below are transcribed directly FROM the matching reference
           // capture dump (open_<case>_w015[_levelN]), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's vertex ordering substitutes
           // directly. This makes each level a PARITY guard, not merely a
           // regression guard on our own output.
    import std.conv : to;
    immutable Vec3[8] baseVerts = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,-0.5f),
        Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f), Vec3(0.5f,0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
    ];
    static immutable uint[][] baseFaces = [[0,1,2,3],[4,5,6,7],[3,2,6,5],[0,3,5,4],[1,7,6,2]];
    static immutable uint[2][] edges = [[4u,5u],[5u,6u],[6u,7u]];

    foreach (level; [0, 1, 2]) {
        Mesh m;
        m.vertices = baseVerts.dup;
        foreach (f; baseFaces) m.addFace(f.dup);
        m.buildLoops();
        m.syncSelection();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (e; edges) {
            int ei = findEdge(m, e[0], e[1]);
            assert(ei >= 0, "open-boundary chain3: selected edge not found");
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.15f, level) == edges.length);


        if (level == 0) {
        // 12v/8f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, -0.5f), Vec3(0.5f, 0.349999994f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.349999994f),
            Vec3(0.5f, -0.5f, 0.349999994f), Vec3(0.349999994f, -0.5f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [11u, 8u, 2u, 1u], [3u, 6u, 4u, 0u],
            [2u, 8u, 6u, 3u], [7u, 9u, 10u, 5u], [7u, 5u, 4u, 6u],
            [9u, 7u, 6u, 8u], [10u, 9u, 8u, 11u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary chain3 L0 (task 0443 freeze)");

        } else if (level == 1) {
        // 16v/11f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, -0.5f), Vec3(0.5f, 0.349999994f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.349999994f),
            Vec3(0.5f, -0.5f, 0.349999994f), Vec3(0.349999994f, -0.5f, 0.5f),
            Vec3(0.456066012f, -0.5f, -0.456066012f), Vec3(0.456066012f, 0.456066012f, -0.456066012f),
            Vec3(0.456066012f, 0.456066012f, 0.456066012f), Vec3(0.456066012f, -0.5f, 0.456066012f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [11u, 8u, 2u, 1u], [3u, 6u, 4u, 0u],
            [2u, 8u, 6u, 3u], [7u, 9u, 10u, 5u], [7u, 5u, 12u, 13u],
            [13u, 12u, 4u, 6u], [9u, 7u, 13u, 14u], [14u, 13u, 6u, 8u],
            [10u, 9u, 14u, 15u], [15u, 14u, 8u, 11u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary chain3 L1 (task 0443 freeze)");

        } else {
        // 24v/17f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, -0.5f), Vec3(0.5f, 0.349999994f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.349999994f),
            Vec3(0.5f, -0.5f, 0.349999994f), Vec3(0.349999994f, -0.5f, 0.5f),
            Vec3(0.488581926f, -0.5f, -0.407402515f), Vec3(0.488581926f, 0.407402515f, -0.407402515f),
            Vec3(0.456066012f, -0.5f, -0.456066012f), Vec3(0.456066012f, 0.456066012f, -0.456066012f),
            Vec3(0.407402515f, -0.5f, -0.488581926f), Vec3(0.407402515f, 0.488581926f, -0.488581926f),
            Vec3(0.488581926f, 0.407402515f, 0.407402515f), Vec3(0.456066012f, 0.456066012f, 0.456066012f),
            Vec3(0.407402515f, 0.488581926f, 0.488581926f), Vec3(0.488581926f, -0.5f, 0.407402515f),
            Vec3(0.456066012f, -0.5f, 0.456066012f), Vec3(0.407402515f, -0.5f, 0.488581926f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [11u, 8u, 2u, 1u], [3u, 6u, 4u, 0u],
            [2u, 8u, 6u, 3u], [7u, 9u, 10u, 5u], [7u, 5u, 12u, 13u],
            [13u, 12u, 14u, 15u], [15u, 14u, 16u, 17u], [17u, 16u, 4u, 6u],
            [9u, 7u, 13u, 18u], [18u, 13u, 15u, 19u], [19u, 15u, 17u, 20u],
            [20u, 17u, 6u, 8u], [10u, 9u, 18u, 21u], [21u, 18u, 19u, 22u],
            [22u, 19u, 20u, 23u], [23u, 20u, 8u, 11u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary chain3 L2 (task 0443 freeze)");

        }
        assertBevelManifoldCleanOpen(m, "open-boundary chain3", 1);
    }
}

unittest { // bevelEdgesByMask: open-boundary "oneend" (task 0443 freeze) —
           // one edge whose far end sits on the open rim, near end is interior. BASE = unit cube -0.5..0.5 with one (or, for
           // "bothends", two) face(s) omitted, leaving an open rim.
           // Reference-verified at width=0.15, Round Level 0/1/2 (task
           // 0391's open-boundary law + its Round Level follow-up) — full
           // position+connectivity freeze, not just the vertex/face counts
           // the repo kept until now. Provenance (task 0450): the want*
           // numbers below are transcribed directly FROM the matching reference
           // capture dump (open_<case>_w015[_levelN]), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's vertex ordering substitutes
           // directly. This makes each level a PARITY guard, not merely a
           // regression guard on our own output.
    import std.conv : to;
    immutable Vec3[8] baseVerts = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,-0.5f),
        Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f), Vec3(0.5f,0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
    ];
    static immutable uint[][] baseFaces = [[0,1,2,3],[4,5,6,7],[3,2,6,5],[0,3,5,4],[1,7,6,2]];
    static immutable uint[2][] edges = [[4u,5u]];

    foreach (level; [0, 1, 2]) {
        Mesh m;
        m.vertices = baseVerts.dup;
        foreach (f; baseFaces) m.addFace(f.dup);
        m.buildLoops();
        m.syncSelection();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (e; edges) {
            int ei = findEdge(m, e[0], e[1]);
            assert(ei >= 0, "open-boundary oneend: selected edge not found");
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.15f, level) == edges.length);


        if (level == 0) {
        // 10v/6f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, 0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, -0.5f), Vec3(0.5f, 0.5f, -0.349999994f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [3u, 8u, 6u, 0u], [2u, 4u, 9u, 8u, 3u],
            [9u, 4u, 5u, 7u], [1u, 5u, 4u, 2u], [9u, 7u, 6u, 8u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary oneend L0 (task 0443 freeze)");

        } else if (level == 1) {
        // 12v/7f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, 0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, -0.5f), Vec3(0.5f, 0.5f, -0.349999994f),
            Vec3(0.456066012f, -0.5f, -0.456066012f), Vec3(0.456066012f, 0.5f, -0.456066012f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [3u, 8u, 6u, 0u], [2u, 4u, 9u, 11u, 8u, 3u],
            [9u, 4u, 5u, 7u], [1u, 5u, 4u, 2u], [9u, 7u, 10u, 11u],
            [11u, 10u, 6u, 8u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary oneend L1 (task 0443 freeze)");

        } else {
        // 16v/9f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, 0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.349999994f),
            Vec3(0.349999994f, 0.5f, -0.5f), Vec3(0.5f, 0.5f, -0.349999994f),
            Vec3(0.488581926f, -0.5f, -0.407402515f), Vec3(0.488581926f, 0.5f, -0.407402515f),
            Vec3(0.456066012f, -0.5f, -0.456066012f), Vec3(0.456066012f, 0.5f, -0.456066012f),
            Vec3(0.407402515f, -0.5f, -0.488581926f), Vec3(0.407402515f, 0.5f, -0.488581926f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [3u, 8u, 6u, 0u], [2u, 4u, 9u, 11u, 13u, 15u, 8u, 3u],
            [9u, 4u, 5u, 7u], [1u, 5u, 4u, 2u], [9u, 7u, 10u, 11u],
            [11u, 10u, 12u, 13u], [13u, 12u, 14u, 15u], [15u, 14u, 6u, 8u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary oneend L2 (task 0443 freeze)");

        }
        assertBevelManifoldCleanOpen(m, "open-boundary oneend", 1);
    }
}

unittest { // bevelEdgesByMask: open-boundary "interior" (task 0443 freeze) —
           // one edge whose both ends are interior — neither touches the rim. BASE = unit cube -0.5..0.5 with one (or, for
           // "bothends", two) face(s) omitted, leaving an open rim.
           // Reference-verified at width=0.15, Round Level 0/1/2 (task
           // 0391's open-boundary law + its Round Level follow-up) — full
           // position+connectivity freeze, not just the vertex/face counts
           // the repo kept until now. Provenance (task 0450): the want*
           // numbers below are transcribed directly FROM the matching reference
           // capture dump (open_<case>_w015[_levelN]), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's vertex ordering substitutes
           // directly. This makes each level a PARITY guard, not merely a
           // regression guard on our own output.
    import std.conv : to;
    immutable Vec3[8] baseVerts = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,-0.5f),
        Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f), Vec3(0.5f,0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
    ];
    static immutable uint[][] baseFaces = [[0,1,2,3],[4,5,6,7],[3,2,6,5],[0,3,5,4],[1,7,6,2]];
    static immutable uint[2][] edges = [[5u,6u]];

    foreach (level; [0, 1, 2]) {
        Mesh m;
        m.vertices = baseVerts.dup;
        foreach (f; baseFaces) m.addFace(f.dup);
        m.buildLoops();
        m.syncSelection();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (e; edges) {
            int ei = findEdge(m, e[0], e[1]);
            assert(ei >= 0, "open-boundary interior: selected edge not found");
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.15f, level) == edges.length);


        if (level == 0) {
        // 10v/6f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.5f, 0.349999994f, -0.5f), Vec3(0.349999994f, 0.5f, -0.5f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [5u, 9u, 8u, 2u, 1u], [3u, 7u, 6u, 4u, 0u],
            [2u, 8u, 7u, 3u], [6u, 9u, 5u, 4u], [9u, 6u, 7u, 8u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary interior L0 (task 0443 freeze)");

        } else if (level == 1) {
        // 12v/7f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.5f, 0.349999994f, -0.5f), Vec3(0.349999994f, 0.5f, -0.5f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.5f),
            Vec3(0.456066012f, 0.456066012f, -0.5f), Vec3(0.456066012f, 0.456066012f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [5u, 9u, 11u, 8u, 2u, 1u], [3u, 7u, 10u, 6u, 4u, 0u],
            [2u, 8u, 7u, 3u], [6u, 9u, 5u, 4u], [9u, 6u, 10u, 11u],
            [11u, 10u, 7u, 8u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary interior L1 (task 0443 freeze)");

        } else {
        // 16v/9f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.5f, 0.349999994f, -0.5f), Vec3(0.349999994f, 0.5f, -0.5f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.5f),
            Vec3(0.488581926f, 0.407402515f, -0.5f), Vec3(0.488581926f, 0.407402515f, 0.5f),
            Vec3(0.456066012f, 0.456066012f, -0.5f), Vec3(0.456066012f, 0.456066012f, 0.5f),
            Vec3(0.407402515f, 0.488581926f, -0.5f), Vec3(0.407402515f, 0.488581926f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [5u, 9u, 11u, 13u, 15u, 8u, 2u, 1u], [3u, 7u, 14u, 12u, 10u, 6u, 4u, 0u],
            [2u, 8u, 7u, 3u], [6u, 9u, 5u, 4u], [9u, 6u, 10u, 11u],
            [11u, 10u, 12u, 13u], [13u, 12u, 14u, 15u], [15u, 14u, 7u, 8u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary interior L2 (task 0443 freeze)");

        }
        assertBevelManifoldCleanOpen(m, "open-boundary interior", 1);
    }
}

unittest { // bevelEdgesByMask: open-boundary "rimedge" (task 0443 freeze) —
           // the rim edge itself (1 incident face) — Round Level must be
           // completely inert (byte-identical L0/L1/L2). BASE = unit cube -0.5..0.5 with one (or, for
           // "bothends", two) face(s) omitted, leaving an open rim.
           // Reference-verified at width=0.15, Round Level 0/1/2 (task
           // 0391's open-boundary law + its Round Level follow-up) — full
           // position+connectivity freeze, not just the vertex/face counts
           // the repo kept until now. Provenance (task 0450): the want*
           // numbers below are transcribed directly FROM the matching reference
           // capture dump (open_<case>_w015[_levelN]), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's vertex ordering substitutes
           // directly. This makes each level a PARITY guard, not merely a
           // regression guard on our own output.
    import std.conv : to;
    immutable Vec3[8] baseVerts = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,-0.5f),
        Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f), Vec3(0.5f,0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
    ];
    static immutable uint[][] baseFaces = [[0,1,2,3],[4,5,6,7],[3,2,6,5],[0,3,5,4],[1,7,6,2]];
    static immutable uint[2][] edges = [[7u,4u]];

    foreach (level; [0, 1, 2]) {
        Mesh m;
        m.vertices = baseVerts.dup;
        foreach (f; baseFaces) m.addFace(f.dup);
        m.buildLoops();
        m.syncSelection();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (e; edges) {
            int ei = findEdge(m, e[0], e[1]);
            assert(ei >= 0, "open-boundary rimedge: selected edge not found");
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.15f, level) == edges.length);


        if (level == 0) {
        // 10v/5f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, 0.5f, -0.5f), Vec3(0.5f, 0.5f, 0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.349999994f, -0.5f),
            Vec3(0.5f, -0.349999994f, 0.5f), Vec3(0.349999994f, -0.5f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [4u, 5u, 8u, 7u], [3u, 2u, 5u, 4u],
            [3u, 4u, 7u, 6u, 0u], [9u, 8u, 5u, 2u, 1u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary rimedge L0 (task 0443 freeze)");

        } else if (level == 1) {
        // 10v/5f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, 0.5f, -0.5f), Vec3(0.5f, 0.5f, 0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.349999994f, -0.5f),
            Vec3(0.5f, -0.349999994f, 0.5f), Vec3(0.349999994f, -0.5f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [4u, 5u, 8u, 7u], [3u, 2u, 5u, 4u],
            [3u, 4u, 7u, 6u, 0u], [9u, 8u, 5u, 2u, 1u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary rimedge L1 (task 0443 freeze)");

        } else {
        // 10v/5f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, 0.5f, -0.5f), Vec3(0.5f, 0.5f, 0.5f),
            Vec3(0.349999994f, -0.5f, -0.5f), Vec3(0.5f, -0.349999994f, -0.5f),
            Vec3(0.5f, -0.349999994f, 0.5f), Vec3(0.349999994f, -0.5f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [4u, 5u, 8u, 7u], [3u, 2u, 5u, 4u],
            [3u, 4u, 7u, 6u, 0u], [9u, 8u, 5u, 2u, 1u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary rimedge L2 (task 0443 freeze)");

        }
        assertBevelManifoldCleanOpen(m, "open-boundary rimedge", 1);
    }
}

unittest { // bevelEdgesByMask: open-boundary "bothends" (task 0443 freeze) —
           // an edge with BOTH endpoints on a rim (base mesh drops a second
           // face) — no cap face, Round Level inert. BASE = unit cube -0.5..0.5 with one (or, for
           // "bothends", two) face(s) omitted, leaving an open rim.
           // Reference-verified at width=0.15, Round Level 0/1/2 (task
           // 0391's open-boundary law + its Round Level follow-up) — full
           // position+connectivity freeze, not just the vertex/face counts
           // the repo kept until now. Provenance (task 0450): the want*
           // numbers below are transcribed directly FROM the matching reference
           // capture dump (open_<case>_w015[_levelN]), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's vertex ordering substitutes
           // directly. This makes each level a PARITY guard, not merely a
           // regression guard on our own output.
    import std.conv : to;
    immutable Vec3[8] baseVerts = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,-0.5f),
        Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f), Vec3(0.5f,0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
    ];
    static immutable uint[][] baseFaces = [[0,1,2,3],[4,5,6,7],[0,3,5,4],[1,7,6,2]];
    static immutable uint[2][] edges = [[5u,6u]];

    foreach (level; [0, 1, 2]) {
        Mesh m;
        m.vertices = baseVerts.dup;
        foreach (f; baseFaces) m.addFace(f.dup);
        m.buildLoops();
        m.syncSelection();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (e; edges) {
            int ei = findEdge(m, e[0], e[1]);
            assert(ei >= 0, "open-boundary bothends: selected edge not found");
            mask[ei] = true;
        }
        assert(m.bevelEdgesByMask(mask, 0.15f, level) == edges.length);


        if (level == 0) {
        // 10v/4f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.5f, 0.349999994f, -0.5f), Vec3(0.349999994f, 0.5f, -0.5f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [6u, 9u, 5u, 4u], [3u, 7u, 6u, 4u, 0u],
            [5u, 9u, 8u, 2u, 1u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary bothends L0 (task 0443 freeze)");

        } else if (level == 1) {
        // 10v/4f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.5f, 0.349999994f, -0.5f), Vec3(0.349999994f, 0.5f, -0.5f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [6u, 9u, 5u, 4u], [3u, 7u, 6u, 4u, 0u],
            [5u, 9u, 8u, 2u, 1u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary bothends L1 (task 0443 freeze)");

        } else {
        // 10v/4f
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, -0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, 0.5f),
            Vec3(0.5f, 0.349999994f, -0.5f), Vec3(0.349999994f, 0.5f, -0.5f),
            Vec3(0.349999994f, 0.5f, 0.5f), Vec3(0.5f, 0.349999994f, 0.5f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 1u, 2u, 3u], [6u, 9u, 5u, 4u], [3u, 7u, 6u, 4u, 0u],
            [5u, 9u, 8u, 2u, 1u],
        ];

            assertFacesMatchByPosition(m, wantVerts, wantFaces,
                "open-boundary bothends L2 (task 0443 freeze)");

        }
        assertBevelManifoldCleanOpen(m, "open-boundary bothends", 0);
    }
}

unittest { // bevelEdgesByMask: N-way junction "K4 junction (symmetric)" (task 0443
           // freeze) — a symmetric 4-valence apex — 4 triangular faces around one apex,
           // all 4 edges from the apex selected (square-pyramid, 45-degree
           // polar half-angle).
           // Round Level 0 (the flat N-gon cap). L>=1 now rounds via the
           // N-sided Gregory ring (task 0454/0456 — see the L1/L2/L3 parity
           // fixtures below); L0 is unchanged and already matches the reference
           // bit-exact. Provenance (task 0450):
           // the want* numbers below are transcribed directly FROM the
           // reference capture dump (gen_k*_level0), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's vertex ordering substitutes
           // directly, making this a PARITY guard rather than a regression
           // guard on our own output.
    import std.conv : to;
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.414213562373095f,0,1.4142135623730951f),
        Vec3(8.659560562354932e-17f,1.414213562373095f,1.4142135623730951f),
        Vec3(-1.414213562373095f,1.7319121124709863e-16f,1.4142135623730951f),
        Vec3(-2.5978681687064796e-16f,-1.414213562373095f,1.4142135623730951f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    size_t nSel = 0;
    foreach (ei; m.edgesAroundVertex(0)) { mask[ei] = true; ++nSel; }
    assert(m.bevelEdgesByMask(mask, 0.15f, 0) == nSel);

        // 12v/9f
        immutable Vec3[] wantVerts = [
            Vec3(-0.122474484f, 0.122474484f, 0.244948968f), Vec3(-0.122474484f, -0.122474484f, 0.244948968f),
            Vec3(0.122474484f, -0.122474484f, 0.244948968f), Vec3(0.122474484f, 0.122474484f, 0.244948968f),
            Vec3(1.30814755f, 0.106066018f, 1.41421354f), Vec3(1.30814755f, -0.106066018f, 1.41421354f),
            Vec3(-0.106066018f, 1.30814755f, 1.41421354f), Vec3(0.106066018f, 1.30814755f, 1.41421354f),
            Vec3(-1.30814755f, -0.106066018f, 1.41421354f), Vec3(-1.30814755f, 0.106066018f, 1.41421354f),
            Vec3(0.106066018f, -1.30814755f, 1.41421354f), Vec3(-0.106066018f, -1.30814755f, 1.41421354f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 2u, 5u], [3u, 7u, 6u, 0u],
            [0u, 9u, 8u, 1u], [1u, 11u, 10u, 2u], [0u, 1u, 2u, 3u],
        ];

    assertFacesMatchByPosition(m, wantVerts, wantFaces, "K4 junction (symmetric) L0 (task 0443 freeze)");
    assertBevelManifoldCleanOpen(m, "K4 junction (symmetric) L0", 1);
}

unittest { // bevelEdgesByMask: N-way junction "K5 junction (symmetric)" (task 0443
           // freeze) — a symmetric 5-valence apex — 5 triangular faces around one apex,
           // all 5 edges from the apex selected.
           // Round Level 0 (the flat N-gon cap). L>=1 now rounds via the
           // N-sided Gregory ring (task 0454/0456 — see the L1/L2/L3 parity
           // fixtures below); L0 is unchanged and already matches the reference
           // bit-exact. Provenance (task 0450):
           // the want* numbers below are transcribed directly FROM the
           // reference capture dump (gen_k*_level0), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's vertex ordering substitutes
           // directly, making this a PARITY guard rather than a regression
           // guard on our own output.
    import std.conv : to;
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.414213562373095f,0,1.4142135623730951f),
        Vec3(0.4370160244488211f,1.3449970239279145f,1.4142135623730951f),
        Vec3(-1.1441228056353683f,0.8312538755549069f,1.4142135623730951f),
        Vec3(-1.1441228056353687f,-0.8312538755549066f,1.4142135623730951f),
        Vec3(0.43701602444882076f,-1.3449970239279145f,1.4142135623730951f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,5u]); m.addFace([0u,5u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    size_t nSel = 0;
    foreach (ei; m.edgesAroundVertex(0)) { mask[ei] = true; ++nSel; }
    assert(m.bevelEdgesByMask(mask, 0.15f, 0) == nSel);

        // 15v/11f
        immutable Vec3[] wantVerts = [
            Vec3(-0.0701444149f, 0.215882301f, 0.28057763f), Vec3(-0.226992086f, 0f, 0.28057763f),
            Vec3(-0.0701444149f, -0.215882301f, 0.28057763f), Vec3(0.18364045f, -0.133422598f, 0.28057763f),
            Vec3(0.18364045f, 0.133422598f, 0.28057763f), Vec3(1.32604575f, 0.121352553f, 1.41421354f),
            Vec3(1.32604575f, -0.121352553f, 1.41421354f), Vec3(0.294357538f, 1.29864454f, 1.41421354f),
            Vec3(0.525183797f, 1.2236445f, 1.41421354f), Vec3(-1.14412284f, 0.68125391f, 1.41421354f),
            Vec3(-1.00146437f, 0.877606452f, 1.41421354f), Vec3(-1.00146437f, -0.877606452f, 1.41421354f),
            Vec3(-1.14412284f, -0.68125391f, 1.41421354f), Vec3(0.525183797f, -1.2236445f, 1.41421354f),
            Vec3(0.294357538f, -1.29864454f, 1.41421354f),
        ];
        static immutable uint[][] wantFaces = [
            [3u, 13u, 6u], [2u, 11u, 14u], [1u, 9u, 12u],
            [0u, 7u, 10u], [4u, 5u, 8u], [5u, 4u, 3u, 6u],
            [4u, 8u, 7u, 0u], [0u, 10u, 9u, 1u], [1u, 12u, 11u, 2u],
            [2u, 14u, 13u, 3u], [0u, 1u, 2u, 3u, 4u],
        ];

    assertFacesMatchByPosition(m, wantVerts, wantFaces, "K5 junction (symmetric) L0 (task 0443 freeze)");
    assertBevelManifoldCleanOpen(m, "K5 junction (symmetric) L0", 1);
}

unittest { // bevelEdgesByMask: "K4 junction (symmetric)" L1
           // Parity fixture (task 0456), transcribed FROM the reference capture
           // dump edge_bevel_gen_k4_junction_level1 — NOT our kernel's output. Even-N rounds to
           // reference parity to the %.5f canonicalisation (float32-mesh floor
           // ~1e-7); assertFacesMatchByPosition canonicalises by position and
           // connectivity so the dump's own vertex ordering substitutes directly.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.414213562373095f,0,1.4142135623730951f),
        Vec3(8.659560562354932e-17f,1.414213562373095f,1.4142135623730951f),
        Vec3(-1.414213562373095f,1.7319121124709863e-16f,1.4142135623730951f),
        Vec3(-2.5978681687064796e-16f,-1.414213562373095f,1.4142135623730951f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 1);
        immutable Vec3[] wantVerts = [
            Vec3(-0.122474484f, 0.122474484f, 0.244948968f), Vec3(-0.122474484f, -0.122474484f, 0.244948968f), Vec3(0.122474484f, -0.122474484f, 0.244948968f),
            Vec3(0.122474484f, 0.122474484f, 0.244948968f), Vec3(1.30814755f, 0.106066018f, 1.41421354f), Vec3(1.30814755f, -0.106066018f, 1.41421354f),
            Vec3(-0.106066018f, 1.30814755f, 1.41421354f), Vec3(0.106066018f, 1.30814755f, 1.41421354f), Vec3(-1.30814755f, -0.106066018f, 1.41421354f),
            Vec3(-1.30814755f, 0.106066018f, 1.41421354f), Vec3(0.106066018f, -1.30814755f, 1.41421354f), Vec3(-0.106066018f, -1.30814755f, 1.41421354f),
            Vec3(0.122474484f, 0f, 0.201014981f), Vec3(1.35208154f, 0f, 1.41421354f), Vec3(0f, 1.35208154f, 1.41421354f),
            Vec3(0f, 0.122474484f, 0.201014981f), Vec3(-1.35208154f, 0f, 1.41421354f), Vec3(-0.122474484f, 0f, 0.201014981f),
            Vec3(0f, -1.35208154f, 1.41421354f), Vec3(0f, -0.122474484f, 0.201014981f), Vec3(0f, 0f, 0.13462998f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 12u, 13u], [13u, 12u, 2u, 5u],
            [3u, 7u, 14u, 15u], [15u, 14u, 6u, 0u], [0u, 9u, 16u, 17u],
            [17u, 16u, 8u, 1u], [1u, 11u, 18u, 19u], [19u, 18u, 10u, 2u],
            [0u, 17u, 20u, 15u], [1u, 19u, 20u, 17u], [2u, 12u, 20u, 19u],
            [3u, 15u, 20u, 12u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K4 junction (symmetric) L1 (task 0456 parity)", 4);
    assertBevelManifoldCleanOpen(m, "K4 junction (symmetric) L1 (task 0456 parity)", 1);
}

unittest { // bevelEdgesByMask: "K4 junction (symmetric)" L2
           // Parity fixture (task 0456), transcribed FROM the reference capture
           // dump edge_bevel_gen_k4_junction_level2 — NOT our kernel's output. Even-N rounds to
           // reference parity to the %.5f canonicalisation (float32-mesh floor
           // ~1e-7); assertFacesMatchByPosition canonicalises by position and
           // connectivity so the dump's own vertex ordering substitutes directly.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.414213562373095f,0,1.4142135623730951f),
        Vec3(8.659560562354932e-17f,1.414213562373095f,1.4142135623730951f),
        Vec3(-1.414213562373095f,1.7319121124709863e-16f,1.4142135623730951f),
        Vec3(-2.5978681687064796e-16f,-1.414213562373095f,1.4142135623730951f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 2);
        immutable Vec3[] wantVerts = [
            Vec3(-0.122474484f, 0.122474484f, 0.244948968f), Vec3(-0.122474484f, -0.122474484f, 0.244948968f), Vec3(0.122474484f, -0.122474484f, 0.244948968f),
            Vec3(0.122474484f, 0.122474484f, 0.244948968f), Vec3(1.30814755f, 0.106066018f, 1.41421354f), Vec3(1.30814755f, -0.106066018f, 1.41421354f),
            Vec3(-0.106066018f, 1.30814755f, 1.41421354f), Vec3(0.106066018f, 1.30814755f, 1.41421354f), Vec3(-1.30814755f, -0.106066018f, 1.41421354f),
            Vec3(-1.30814755f, 0.106066018f, 1.41421354f), Vec3(0.106066018f, -1.30814755f, 1.41421354f), Vec3(-0.106066018f, -1.30814755f, 1.41421354f),
            Vec3(0.122474484f, 0.0637675971f, 0.212433055f), Vec3(1.34066343f, 0.0574025139f, 1.41421354f), Vec3(0.122474484f, 0f, 0.201014981f),
            Vec3(1.35208154f, 0f, 1.41421354f), Vec3(0.122474484f, -0.0637675971f, 0.212433055f), Vec3(1.34066343f, -0.0574025139f, 1.41421354f),
            Vec3(0.0574025139f, 1.34066343f, 1.41421354f), Vec3(0.0637675971f, 0.122474484f, 0.212433055f), Vec3(0f, 1.35208154f, 1.41421354f),
            Vec3(0f, 0.122474484f, 0.201014981f), Vec3(-0.0574025139f, 1.34066343f, 1.41421354f), Vec3(-0.0637675971f, 0.122474484f, 0.212433055f),
            Vec3(-1.34066343f, 0.0574025139f, 1.41421354f), Vec3(-0.122474484f, 0.0637675971f, 0.212433055f), Vec3(-1.35208154f, 0f, 1.41421354f),
            Vec3(-0.122474484f, 0f, 0.201014981f), Vec3(-1.34066343f, -0.0574025139f, 1.41421354f), Vec3(-0.122474484f, -0.0637675971f, 0.212433055f),
            Vec3(-0.0574025139f, -1.34066343f, 1.41421354f), Vec3(-0.0637675971f, -0.122474484f, 0.212433055f), Vec3(0f, -1.35208154f, 1.41421354f),
            Vec3(0f, -0.122474484f, 0.201014981f), Vec3(0.0574025139f, -1.34066343f, 1.41421354f), Vec3(0.0637675971f, -0.122474484f, 0.212433055f),
            Vec3(0f, 0f, 0.13462998f), Vec3(0f, 0.0626468956f, 0.148419857f), Vec3(-0.0634889528f, 0.0634889528f, 0.162209719f),
            Vec3(-0.0626468956f, 0f, 0.148419857f), Vec3(-0.0634889528f, -0.0634889528f, 0.162209719f), Vec3(0f, -0.0626468956f, 0.148419857f),
            Vec3(0.0634889528f, -0.0634889528f, 0.162209719f), Vec3(0.0626468956f, 0f, 0.148419857f), Vec3(0.0634889528f, 0.0634889528f, 0.162209719f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 12u, 13u], [13u, 12u, 14u, 15u],
            [15u, 14u, 16u, 17u], [17u, 16u, 2u, 5u], [3u, 7u, 18u, 19u],
            [19u, 18u, 20u, 21u], [21u, 20u, 22u, 23u], [23u, 22u, 6u, 0u],
            [0u, 9u, 24u, 25u], [25u, 24u, 26u, 27u], [27u, 26u, 28u, 29u],
            [29u, 28u, 8u, 1u], [1u, 11u, 30u, 31u], [31u, 30u, 32u, 33u],
            [33u, 32u, 34u, 35u], [35u, 34u, 10u, 2u], [0u, 25u, 38u, 23u],
            [23u, 38u, 37u, 21u], [25u, 27u, 39u, 38u], [38u, 39u, 36u, 37u],
            [1u, 31u, 40u, 29u], [29u, 40u, 39u, 27u], [31u, 33u, 41u, 40u],
            [40u, 41u, 36u, 39u], [2u, 16u, 42u, 35u], [35u, 42u, 41u, 33u],
            [16u, 14u, 43u, 42u], [42u, 43u, 36u, 41u], [3u, 19u, 44u, 12u],
            [12u, 44u, 43u, 14u], [19u, 21u, 37u, 44u], [44u, 37u, 36u, 43u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K4 junction (symmetric) L2 (task 0456 parity)", 4);
    assertBevelManifoldCleanOpen(m, "K4 junction (symmetric) L2 (task 0456 parity)", 1);
}

unittest { // bevelEdgesByMask: "K4 junction (symmetric)" L3
           // Parity fixture (task 0456), transcribed FROM the reference capture
           // dump edge_bevel_gen_k4_junction_level3 — NOT our kernel's output. Even-N rounds to
           // reference parity to the %.5f canonicalisation (float32-mesh floor
           // ~1e-7); assertFacesMatchByPosition canonicalises by position and
           // connectivity so the dump's own vertex ordering substitutes directly.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.414213562373095f,0,1.4142135623730951f),
        Vec3(8.659560562354932e-17f,1.414213562373095f,1.4142135623730951f),
        Vec3(-1.414213562373095f,1.7319121124709863e-16f,1.4142135623730951f),
        Vec3(-2.5978681687064796e-16f,-1.414213562373095f,1.4142135623730951f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 3);
        immutable Vec3[] wantVerts = [
            Vec3(-0.122474484f, 0.122474484f, 0.244948968f), Vec3(-0.122474484f, -0.122474484f, 0.244948968f), Vec3(0.122474484f, -0.122474484f, 0.244948968f),
            Vec3(0.122474484f, 0.122474484f, 0.244948968f), Vec3(1.30814755f, 0.106066018f, 1.41421354f), Vec3(1.30814755f, -0.106066018f, 1.41421354f),
            Vec3(-0.106066018f, 1.30814755f, 1.41421354f), Vec3(0.106066018f, 1.30814755f, 1.41421354f), Vec3(-1.30814755f, -0.106066018f, 1.41421354f),
            Vec3(-1.30814755f, 0.106066018f, 1.41421354f), Vec3(0.106066018f, -1.30814755f, 1.41421354f), Vec3(-0.106066018f, -1.30814755f, 1.41421354f),
            Vec3(0.122474484f, 0.0841440558f, 0.221111178f), Vec3(1.33198535f, 0.075000003f, 1.41421354f), Vec3(0.122474484f, 0.0428268015f, 0.206126109f),
            Vec3(1.34697044f, 0.0388228558f, 1.41421354f), Vec3(0.122474484f, 0f, 0.201014981f), Vec3(1.35208154f, 0f, 1.41421354f),
            Vec3(0.122474484f, -0.0428268015f, 0.206126109f), Vec3(1.34697044f, -0.0388228558f, 1.41421354f), Vec3(0.122474484f, -0.0841440558f, 0.221111178f),
            Vec3(1.33198535f, -0.075000003f, 1.41421354f), Vec3(0.075000003f, 1.33198535f, 1.41421354f), Vec3(0.0841440558f, 0.122474484f, 0.221111178f),
            Vec3(0.0388228558f, 1.34697044f, 1.41421354f), Vec3(0.0428268015f, 0.122474484f, 0.206126109f), Vec3(0f, 1.35208154f, 1.41421354f),
            Vec3(0f, 0.122474484f, 0.201014981f), Vec3(-0.0388228558f, 1.34697044f, 1.41421354f), Vec3(-0.0428268015f, 0.122474484f, 0.206126109f),
            Vec3(-0.075000003f, 1.33198535f, 1.41421354f), Vec3(-0.0841440558f, 0.122474484f, 0.221111178f), Vec3(-1.33198535f, 0.075000003f, 1.41421354f),
            Vec3(-0.122474484f, 0.0841440558f, 0.221111178f), Vec3(-1.34697044f, 0.0388228558f, 1.41421354f), Vec3(-0.122474484f, 0.0428268015f, 0.206126109f),
            Vec3(-1.35208154f, 0f, 1.41421354f), Vec3(-0.122474484f, 0f, 0.201014981f), Vec3(-1.34697044f, -0.0388228558f, 1.41421354f),
            Vec3(-0.122474484f, -0.0428268015f, 0.206126109f), Vec3(-1.33198535f, -0.075000003f, 1.41421354f), Vec3(-0.122474484f, -0.0841440558f, 0.221111178f),
            Vec3(-0.075000003f, -1.33198535f, 1.41421354f), Vec3(-0.0841440558f, -0.122474484f, 0.221111178f), Vec3(-0.0388228558f, -1.34697044f, 1.41421354f),
            Vec3(-0.0428268015f, -0.122474484f, 0.206126109f), Vec3(0f, -1.35208154f, 1.41421354f), Vec3(0f, -0.122474484f, 0.201014981f),
            Vec3(0.0388228558f, -1.34697044f, 1.41421354f), Vec3(0.0428268015f, -0.122474484f, 0.206126109f), Vec3(0.075000003f, -1.33198535f, 1.41421354f),
            Vec3(0.0841440558f, -0.122474484f, 0.221111178f), Vec3(0f, 0f, 0.13462998f), Vec3(0f, 0.0814544857f, 0.159145311f),
            Vec3(-0.0836713314f, 0.0836713314f, 0.183660641f), Vec3(-0.0435517728f, 0.0820116103f, 0.165274143f), Vec3(0f, 0.0428019501f, 0.140758812f),
            Vec3(-0.0820116103f, 0.0435517728f, 0.165274143f), Vec3(-0.0429962352f, 0.0429962352f, 0.146887645f), Vec3(-0.0814544857f, 0f, 0.159145311f),
            Vec3(-0.0428019501f, 0f, 0.140758812f), Vec3(-0.0836713314f, -0.0836713314f, 0.183660641f), Vec3(-0.0820116103f, -0.0435517728f, 0.165274143f),
            Vec3(-0.0435517728f, -0.0820116103f, 0.165274143f), Vec3(-0.0429962352f, -0.0429962352f, 0.146887645f), Vec3(0f, -0.0814544857f, 0.159145311f),
            Vec3(0f, -0.0428019501f, 0.140758812f), Vec3(0.0836713314f, -0.0836713314f, 0.183660641f), Vec3(0.0435517728f, -0.0820116103f, 0.165274143f),
            Vec3(0.0820116103f, -0.0435517728f, 0.165274143f), Vec3(0.0429962352f, -0.0429962352f, 0.146887645f), Vec3(0.0814544857f, 0f, 0.159145311f),
            Vec3(0.0428019501f, 0f, 0.140758812f), Vec3(0.0836713314f, 0.0836713314f, 0.183660641f), Vec3(0.0820116103f, 0.0435517728f, 0.165274143f),
            Vec3(0.0435517728f, 0.0820116103f, 0.165274143f), Vec3(0.0429962352f, 0.0429962352f, 0.146887645f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 12u, 13u], [13u, 12u, 14u, 15u],
            [15u, 14u, 16u, 17u], [17u, 16u, 18u, 19u], [19u, 18u, 20u, 21u],
            [21u, 20u, 2u, 5u], [3u, 7u, 22u, 23u], [23u, 22u, 24u, 25u],
            [25u, 24u, 26u, 27u], [27u, 26u, 28u, 29u], [29u, 28u, 30u, 31u],
            [31u, 30u, 6u, 0u], [0u, 9u, 32u, 33u], [33u, 32u, 34u, 35u],
            [35u, 34u, 36u, 37u], [37u, 36u, 38u, 39u], [39u, 38u, 40u, 41u],
            [41u, 40u, 8u, 1u], [1u, 11u, 42u, 43u], [43u, 42u, 44u, 45u],
            [45u, 44u, 46u, 47u], [47u, 46u, 48u, 49u], [49u, 48u, 50u, 51u],
            [51u, 50u, 10u, 2u], [0u, 33u, 54u, 31u], [31u, 54u, 55u, 29u],
            [29u, 55u, 53u, 27u], [33u, 35u, 57u, 54u], [54u, 57u, 58u, 55u],
            [55u, 58u, 56u, 53u], [35u, 37u, 59u, 57u], [57u, 59u, 60u, 58u],
            [58u, 60u, 52u, 56u], [1u, 43u, 61u, 41u], [41u, 61u, 62u, 39u],
            [39u, 62u, 59u, 37u], [43u, 45u, 63u, 61u], [61u, 63u, 64u, 62u],
            [62u, 64u, 60u, 59u], [45u, 47u, 65u, 63u], [63u, 65u, 66u, 64u],
            [64u, 66u, 52u, 60u], [2u, 20u, 67u, 51u], [51u, 67u, 68u, 49u],
            [49u, 68u, 65u, 47u], [20u, 18u, 69u, 67u], [67u, 69u, 70u, 68u],
            [68u, 70u, 66u, 65u], [18u, 16u, 71u, 69u], [69u, 71u, 72u, 70u],
            [70u, 72u, 52u, 66u], [3u, 23u, 73u, 12u], [12u, 73u, 74u, 14u],
            [14u, 74u, 71u, 16u], [23u, 25u, 75u, 73u], [73u, 75u, 76u, 74u],
            [74u, 76u, 72u, 71u], [25u, 27u, 53u, 75u], [75u, 53u, 56u, 76u],
            [76u, 56u, 52u, 72u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K4 junction (symmetric) L3 (task 0456 parity)", 4);
    assertBevelManifoldCleanOpen(m, "K4 junction (symmetric) L3 (task 0456 parity)", 1);
}

unittest { // bevelEdgesByMask: "K4 junction (asymmetric)" L1
           // Parity fixture (task 0456), transcribed FROM the reference capture
           // dump edge_bevel_gen_k4_asym1_level1 — NOT our kernel's output. Even-N rounds to
           // reference parity to the %.5f canonicalisation (float32-mesh floor
           // ~1e-7); assertFacesMatchByPosition canonicalises by position and
           // connectivity so the dump's own vertex ordering substitutes directly.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.6f,0,1.3f),
        Vec3(0.3f,1.9f,1.6f),
        Vec3(-1.4f,0.5f,1.0f),
        Vec3(0,-1.2f,1.9f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 1);
        immutable Vec3[] wantVerts = [
            Vec3(-0.112768523f, 0.177031413f, 0.204165533f), Vec3(-0.123843782f, -0.0404020101f, 0.222460389f), Vec3(0.137606427f, -0.0946779326f, 0.261711925f),
            Vec3(0.154816538f, 0.131210014f, 0.219448209f), Vec3(1.51600754f, 0.122758187f, 1.31938279f), Vec3(1.48506093f, -0.0862043649f, 1.3431021f),
            Vec3(0.18828249f, 1.80799735f, 1.56057036f), Vec3(0.383992463f, 1.77724183f, 1.58061719f), Vec3(-1.31173038f, 0.3928155f, 1.05674469f),
            Vec3(-1.28828239f, 0.59200269f, 1.03942966f), Vec3(0.114939153f, -1.11379564f, 1.85689783f), Vec3(-0.0882695839f, -1.09281552f, 1.84325528f),
            Vec3(0.142643929f, 0.0115596363f, 0.196396962f), Vec3(1.54178405f, 0.0106972363f, 1.3182857f), Vec3(0.291667879f, 1.83545864f, 1.58232534f),
            Vec3(0.0211993475f, 0.144870266f, 0.172403663f), Vec3(-1.34016037f, 0.495457351f, 1.028777f), Vec3(-0.121873707f, 0.0616082959f, 0.169129848f),
            Vec3(0.00792567246f, -1.14252865f, 1.87032747f), Vec3(0.00705666328f, -0.0767904222f, 0.202682957f), Vec3(0.0114309229f, 0.0240856726f, 0.124656767f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 12u, 13u], [13u, 12u, 2u, 5u],
            [3u, 7u, 14u, 15u], [15u, 14u, 6u, 0u], [0u, 9u, 16u, 17u],
            [17u, 16u, 8u, 1u], [1u, 11u, 18u, 19u], [19u, 18u, 10u, 2u],
            [0u, 17u, 20u, 15u], [1u, 19u, 20u, 17u], [2u, 12u, 20u, 19u],
            [3u, 15u, 20u, 12u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K4 junction (asymmetric) L1 (task 0456 parity)", 4);
    assertBevelManifoldCleanOpen(m, "K4 junction (asymmetric) L1 (task 0456 parity)", 1);
}

unittest { // bevelEdgesByMask: "K4 junction (asymmetric)" L2
           // Parity fixture (task 0456), transcribed FROM the reference capture
           // dump edge_bevel_gen_k4_asym1_level2 — NOT our kernel's output. Even-N rounds to
           // reference parity to the %.5f canonicalisation (float32-mesh floor
           // ~1e-7); assertFacesMatchByPosition canonicalises by position and
           // connectivity so the dump's own vertex ordering substitutes directly.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.6f,0,1.3f),
        Vec3(0.3f,1.9f,1.6f),
        Vec3(-1.4f,0.5f,1.0f),
        Vec3(0,-1.2f,1.9f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 2);
        immutable Vec3[] wantVerts = [
            Vec3(-0.112768523f, 0.177031413f, 0.204165533f), Vec3(-0.123843782f, -0.0404020101f, 0.222460389f), Vec3(0.137606427f, -0.0946779326f, 0.261711925f),
            Vec3(0.154816538f, 0.131210014f, 0.219448209f), Vec3(1.51600754f, 0.122758187f, 1.31938279f), Vec3(1.48506093f, -0.0862043649f, 1.3431021f),
            Vec3(0.18828249f, 1.80799735f, 1.56057036f), Vec3(0.383992463f, 1.77724183f, 1.58061719f), Vec3(-1.31173038f, 0.3928155f, 1.05674469f),
            Vec3(-1.28828239f, 0.59200269f, 1.03942966f), Vec3(0.114939153f, -1.11379564f, 1.85689783f), Vec3(-0.0882695839f, -1.09281552f, 1.84325528f),
            Vec3(0.148377761f, 0.0723031014f, 0.197439536f), Vec3(1.53943622f, 0.0691874698f, 1.31523669f), Vec3(0.142643929f, 0.0115596363f, 0.196396962f),
            Vec3(1.54178405f, 0.0106972363f, 1.3182857f), Vec3(0.138777554f, -0.0456733219f, 0.218482301f), Vec3(1.52269518f, -0.0438540168f, 1.32806802f),
            Vec3(0.34386614f, 1.81582618f, 1.58475244f), Vec3(0.0902084187f, 0.135333121f, 0.186350763f), Vec3(0.291667879f, 1.83545864f, 1.58232534f),
            Vec3(0.0211993475f, 0.144870266f, 0.172403663f), Vec3(0.236577287f, 1.83268654f, 1.57376266f), Vec3(-0.0478998013f, 0.159159586f, 0.178698942f),
            Vec3(-1.32325816f, 0.5491395f, 1.02908552f), Vec3(-0.117238984f, 0.120837063f, 0.174466655f), Vec3(-1.34016037f, 0.495457351f, 1.028777f),
            Vec3(-0.121873707f, 0.0616082959f, 0.169129848f), Vec3(-1.33608437f, 0.440182656f, 1.03855693f), Vec3(-0.124640971f, 0.00589003693f, 0.186920971f),
            Vec3(-0.0460525043f, -1.12658072f, 1.86132753f), Vec3(-0.0607145429f, -0.0606710501f, 0.203789964f), Vec3(0.00792567246f, -1.14252865f, 1.87032747f),
            Vec3(0.00705666328f, -0.0767904222f, 0.202682957f), Vec3(0.0647252202f, -1.13801789f, 1.86876464f), Vec3(0.0747377947f, -0.0881576166f, 0.221818313f),
            Vec3(0.0114309229f, 0.0240856726f, 0.124656767f), Vec3(0.0142914429f, 0.0840891749f, 0.130381763f), Vec3(-0.0533207729f, 0.101356357f, 0.137767628f),
            Vec3(-0.0554667488f, 0.0421170145f, 0.128821224f), Vec3(-0.0568217486f, -0.0150819765f, 0.146192834f), Vec3(0.011255553f, -0.0324820168f, 0.145472676f),
            Vec3(0.0764667168f, -0.0445603207f, 0.169327438f), Vec3(0.0769043118f, 0.0122208623f, 0.145096272f), Vec3(0.0819212422f, 0.073833324f, 0.147628903f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 12u, 13u], [13u, 12u, 14u, 15u],
            [15u, 14u, 16u, 17u], [17u, 16u, 2u, 5u], [3u, 7u, 18u, 19u],
            [19u, 18u, 20u, 21u], [21u, 20u, 22u, 23u], [23u, 22u, 6u, 0u],
            [0u, 9u, 24u, 25u], [25u, 24u, 26u, 27u], [27u, 26u, 28u, 29u],
            [29u, 28u, 8u, 1u], [1u, 11u, 30u, 31u], [31u, 30u, 32u, 33u],
            [33u, 32u, 34u, 35u], [35u, 34u, 10u, 2u], [0u, 25u, 38u, 23u],
            [23u, 38u, 37u, 21u], [25u, 27u, 39u, 38u], [38u, 39u, 36u, 37u],
            [1u, 31u, 40u, 29u], [29u, 40u, 39u, 27u], [31u, 33u, 41u, 40u],
            [40u, 41u, 36u, 39u], [2u, 16u, 42u, 35u], [35u, 42u, 41u, 33u],
            [16u, 14u, 43u, 42u], [42u, 43u, 36u, 41u], [3u, 19u, 44u, 12u],
            [12u, 44u, 43u, 14u], [19u, 21u, 37u, 44u], [44u, 37u, 36u, 43u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K4 junction (asymmetric) L2 (task 0456 parity)", 4);
    assertBevelManifoldCleanOpen(m, "K4 junction (asymmetric) L2 (task 0456 parity)", 1);
}

unittest { // bevelEdgesByMask: "K4 junction (asymmetric)" L3
           // Parity fixture (task 0456), transcribed FROM the reference capture
           // dump edge_bevel_gen_k4_asym1_level3 — NOT our kernel's output. Even-N rounds to
           // reference parity to the %.5f canonicalisation (float32-mesh floor
           // ~1e-7); assertFacesMatchByPosition canonicalises by position and
           // connectivity so the dump's own vertex ordering substitutes directly.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.6f,0,1.3f),
        Vec3(0.3f,1.9f,1.6f),
        Vec3(-1.4f,0.5f,1.0f),
        Vec3(0,-1.2f,1.9f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 3);
        immutable Vec3[] wantVerts = [
            Vec3(-0.112768523f, 0.177031413f, 0.204165533f), Vec3(-0.123843782f, -0.0404020101f, 0.222460389f), Vec3(0.137606427f, -0.0946779326f, 0.261711925f),
            Vec3(0.154816538f, 0.131210014f, 0.219448209f), Vec3(1.51600754f, 0.122758187f, 1.31938279f), Vec3(1.48506093f, -0.0862043649f, 1.3431021f),
            Vec3(0.18828249f, 1.80799735f, 1.56057036f), Vec3(0.383992463f, 1.77724183f, 1.58061719f), Vec3(-1.31173038f, 0.3928155f, 1.05674469f),
            Vec3(-1.28828239f, 0.59200269f, 1.03942966f), Vec3(0.114939153f, -1.11379564f, 1.85689783f), Vec3(-0.0882695839f, -1.09281552f, 1.84325528f),
            Vec3(0.150508583f, 0.0924216881f, 0.202663437f), Vec3(1.53385627f, 0.0880196691f, 1.31582808f), Vec3(0.146326184f, 0.0519840419f, 0.194574609f),
            Vec3(1.54264712f, 0.0498024002f, 1.31545401f), Vec3(0.142643929f, 0.0115596363f, 0.196396962f), Vec3(1.54178405f, 0.0106972363f, 1.3182857f),
            Vec3(0.139798701f, -0.0272913165f, 0.208585531f), Vec3(1.53132558f, -0.0266447682f, 1.32413149f), Vec3(0.138060108f, -0.0631349981f, 0.230762616f),
            Vec3(1.51198065f, -0.0596920922f, 1.33259487f), Vec3(0.35898909f, 1.80479467f, 1.58409059f), Vec3(0.112441637f, 0.133340284f, 0.19537124f),
            Vec3(0.327383965f, 1.82472384f, 1.58467531f), Vec3(0.0674842373f, 0.137932122f, 0.179475442f), Vec3(0.291667879f, 1.83545864f, 1.58232534f),
            Vec3(0.0211993475f, 0.144870266f, 0.172403663f), Vec3(0.254655629f, 1.83615303f, 1.57722569f), Vec3(-0.0251257755f, 0.153931066f, 0.174373582f),
            Vec3(0.21926409f, 1.82675231f, 1.56977844f), Vec3(-0.0702019557f, 0.164789572f, 0.185171291f), Vec3(-1.31336677f, 0.565045416f, 1.03147256f),
            Vec3(-0.115630753f, 0.140235454f, 0.181732312f), Vec3(-1.33111513f, 0.5320158f, 1.0278281f), Vec3(-0.118867084f, 0.101101607f, 0.169947207f),
            Vec3(-1.34016037f, 0.495457351f, 1.028777f), Vec3(-0.121873707f, 0.0616082959f, 0.169129848f), Vec3(-1.33980632f, 0.458185345f, 1.03424609f),
            Vec3(-0.124043308f, 0.0236884449f, 0.178678736f), Vec3(-1.33007991f, 0.423070014f, 1.0438143f), Vec3(-0.124835826f, -0.0108514493f, 0.197159529f),
            Vec3(-0.0618299618f, -1.11708283f, 1.85619068f), Vec3(-0.0825012326f, -0.0543306805f, 0.208248377f), Vec3(-0.028951874f, -1.13407409f, 1.86544359f),
            Vec3(-0.0384095386f, -0.0665459335f, 0.201297075f), Vec3(0.00792567246f, -1.14252865f, 1.87032747f), Vec3(0.00705666328f, -0.0767904222f, 0.202682957f),
            Vec3(0.0460669696f, -1.14181936f, 1.87048006f), Vec3(0.0524826311f, -0.084912248f, 0.213110521f), Vec3(0.0826425627f, -1.1319989f, 1.86589003f),
            Vec3(0.0964555442f, -0.0908608288f, 0.232852727f), Vec3(0.0114309229f, 0.0240856726f, 0.124656767f), Vec3(0.0160718001f, 0.102467075f, 0.138152272f),
            Vec3(-0.0737957805f, 0.126802608f, 0.154936835f), Vec3(-0.0301351156f, 0.113077901f, 0.140463904f), Vec3(0.012924511f, 0.0648996457f, 0.125542343f),
            Vec3(-0.0752601773f, 0.0891969725f, 0.140440643f), Vec3(-0.0323977768f, 0.0759523362f, 0.126589045f), Vec3(-0.0767005831f, 0.0489744581f, 0.136657238f),
            Vec3(-0.0337002166f, 0.0356830694f, 0.124209143f), Vec3(-0.0792590752f, -0.0251010396f, 0.164559767f), Vec3(-0.0780934095f, 0.00960881636f, 0.144442663f),
            Vec3(-0.0344335213f, -0.0374474116f, 0.155128926f), Vec3(-0.0343861468f, -0.003710713f, 0.133677498f), Vec3(0.0115636466f, -0.0481876135f, 0.158345103f),
            Vec3(0.0111307343f, -0.0152012715f, 0.135567144f), Vec3(0.0972379372f, -0.0633268505f, 0.195794344f), Vec3(0.0562003069f, -0.0568980053f, 0.172477156f),
            Vec3(0.0960010216f, -0.0294400472f, 0.170406163f), Vec3(0.0553870387f, -0.0239482298f, 0.148385197f), Vec3(0.0970303789f, 0.0101596136f, 0.156396672f),
            Vec3(0.0559290498f, 0.0152289551f, 0.136039481f), Vec3(0.106023706f, 0.0921096578f, 0.165184543f), Vec3(0.100398958f, 0.0519564562f, 0.154410273f),
            Vec3(0.0623731948f, 0.0953078046f, 0.146794945f), Vec3(0.0582413487f, 0.0565847158f, 0.135437429f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 12u, 13u], [13u, 12u, 14u, 15u],
            [15u, 14u, 16u, 17u], [17u, 16u, 18u, 19u], [19u, 18u, 20u, 21u],
            [21u, 20u, 2u, 5u], [3u, 7u, 22u, 23u], [23u, 22u, 24u, 25u],
            [25u, 24u, 26u, 27u], [27u, 26u, 28u, 29u], [29u, 28u, 30u, 31u],
            [31u, 30u, 6u, 0u], [0u, 9u, 32u, 33u], [33u, 32u, 34u, 35u],
            [35u, 34u, 36u, 37u], [37u, 36u, 38u, 39u], [39u, 38u, 40u, 41u],
            [41u, 40u, 8u, 1u], [1u, 11u, 42u, 43u], [43u, 42u, 44u, 45u],
            [45u, 44u, 46u, 47u], [47u, 46u, 48u, 49u], [49u, 48u, 50u, 51u],
            [51u, 50u, 10u, 2u], [0u, 33u, 54u, 31u], [31u, 54u, 55u, 29u],
            [29u, 55u, 53u, 27u], [33u, 35u, 57u, 54u], [54u, 57u, 58u, 55u],
            [55u, 58u, 56u, 53u], [35u, 37u, 59u, 57u], [57u, 59u, 60u, 58u],
            [58u, 60u, 52u, 56u], [1u, 43u, 61u, 41u], [41u, 61u, 62u, 39u],
            [39u, 62u, 59u, 37u], [43u, 45u, 63u, 61u], [61u, 63u, 64u, 62u],
            [62u, 64u, 60u, 59u], [45u, 47u, 65u, 63u], [63u, 65u, 66u, 64u],
            [64u, 66u, 52u, 60u], [2u, 20u, 67u, 51u], [51u, 67u, 68u, 49u],
            [49u, 68u, 65u, 47u], [20u, 18u, 69u, 67u], [67u, 69u, 70u, 68u],
            [68u, 70u, 66u, 65u], [18u, 16u, 71u, 69u], [69u, 71u, 72u, 70u],
            [70u, 72u, 52u, 66u], [3u, 23u, 73u, 12u], [12u, 73u, 74u, 14u],
            [14u, 74u, 71u, 16u], [23u, 25u, 75u, 73u], [73u, 75u, 76u, 74u],
            [74u, 76u, 72u, 71u], [25u, 27u, 53u, 75u], [75u, 53u, 56u, 76u],
            [76u, 56u, 52u, 72u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K4 junction (asymmetric) L3 (task 0456 parity)", 4);
    assertBevelManifoldCleanOpen(m, "K4 junction (asymmetric) L3 (task 0456 parity)", 1);
}

unittest { // bevelEdgesByMask: "K5 junction (symmetric)" L1
           // Parity fixture (task 0456), transcribed FROM the reference capture
           // dump edge_bevel_gen_k5_junction_level1 — NOT our kernel's output. Even-N rounds to
           // reference parity to the %.5f canonicalisation (float32-mesh floor
           // ~1e-7); assertFacesMatchByPosition canonicalises by position and
           // connectivity so the dump's own vertex ordering substitutes directly.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.414213562373095f,0,1.4142135623730951f),
        Vec3(0.4370160244488211f,1.3449970239279145f,1.4142135623730951f),
        Vec3(-1.1441228056353683f,0.8312538755549069f,1.4142135623730951f),
        Vec3(-1.1441228056353687f,-0.8312538755549066f,1.4142135623730951f),
        Vec3(0.43701602444882076f,-1.3449970239279145f,1.4142135623730951f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,5u]); m.addFace([0u,5u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 1);
        immutable Vec3[] wantVerts = [
            Vec3(-0.0701444149f, 0.215882301f, 0.28057763f), Vec3(-0.226992086f, 0f, 0.28057763f), Vec3(-0.0701444149f, -0.215882301f, 0.28057763f),
            Vec3(0.18364045f, -0.133422598f, 0.28057763f), Vec3(0.18364045f, 0.133422598f, 0.28057763f), Vec3(1.32604575f, 0.121352553f, 1.41421354f),
            Vec3(1.32604575f, -0.121352553f, 1.41421354f), Vec3(0.294357538f, 1.29864454f, 1.41421354f), Vec3(0.525183797f, 1.2236445f, 1.41421354f),
            Vec3(-1.14412284f, 0.68125391f, 1.41421354f), Vec3(-1.00146437f, 0.877606452f, 1.41421354f), Vec3(-1.00146437f, -0.877606452f, 1.41421354f),
            Vec3(-1.14412284f, -0.68125391f, 1.41421354f), Vec3(0.525183797f, -1.2236445f, 1.41421354f), Vec3(0.294357538f, -1.29864454f, 1.41421354f),
            Vec3(0.170461401f, 0f, 0.237929314f), Vec3(1.36547554f, 0f, 1.41421354f), Vec3(0.421955168f, 1.29864454f, 1.41421354f),
            Vec3(0.052675467f, 0.16211842f, 0.237929314f), Vec3(-1.10469306f, 0.802606463f, 1.41421354f), Vec3(-0.137906179f, 0.1001947f, 0.237929314f),
            Vec3(-1.10469306f, -0.802606463f, 1.41421354f), Vec3(-0.137906179f, -0.1001947f, 0.237929314f), Vec3(0.421955168f, -1.29864454f, 1.41421354f),
            Vec3(0.052675467f, -0.16211842f, 0.237929314f), Vec3(0f, 0f, 0.153479129f),
        ];
        static immutable uint[][] wantFaces = [
            [3u, 13u, 6u], [2u, 11u, 14u], [1u, 9u, 12u],
            [0u, 7u, 10u], [4u, 5u, 8u], [5u, 4u, 15u, 16u],
            [16u, 15u, 3u, 6u], [4u, 8u, 17u, 18u], [18u, 17u, 7u, 0u],
            [0u, 10u, 19u, 20u], [20u, 19u, 9u, 1u], [1u, 12u, 21u, 22u],
            [22u, 21u, 11u, 2u], [2u, 14u, 23u, 24u], [24u, 23u, 13u, 3u],
            [0u, 20u, 25u, 18u], [1u, 22u, 25u, 20u], [2u, 24u, 25u, 22u],
            [3u, 15u, 25u, 24u], [4u, 18u, 25u, 15u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K5 junction (symmetric) L1 (task 0456 parity, odd-N L1 exact)", 4);
    assertBevelManifoldCleanOpen(m, "K5 junction (symmetric) L1 (task 0456 parity, odd-N L1 exact)", 1);
}

unittest { // bevelEdgesByMask: "K5 junction (symmetric)" L2
           // Parity fixture (task 0453, flipped from the prior XFAIL Hausdorff
           // band). newC_i's TRUE final value (center-normal planar
           // projection + odd-N corner-move sin-angle recurrence,
           // finding J) closes the ~4e-3 residual finding (H) originally
           // reported — transcribed FROM the reference capture dump
           // edge_bevel_gen_k5_junction_level2, NOT our kernel's output.
           // dp=4 per plan risk R3 (a symmetric hub's rail midpoints land on a
           // %.5f rounding boundary; %.4f clears it, matching the K5-sym L1
           // fixture above).
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.414213562373095f,0,1.4142135623730951f),
        Vec3(0.4370160244488211f,1.3449970239279145f,1.4142135623730951f),
        Vec3(-1.1441228056353683f,0.8312538755549069f,1.4142135623730951f),
        Vec3(-1.1441228056353687f,-0.8312538755549066f,1.4142135623730951f),
        Vec3(0.43701602444882076f,-1.3449970239279145f,1.4142135623730951f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,5u]); m.addFace([0u,5u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 2);
        immutable Vec3[] wantVerts = [
            Vec3(-0.0701444149f, 0.215882301f, 0.28057763f), Vec3(-0.226992086f, 0f, 0.28057763f),
            Vec3(-0.0701444149f, -0.215882301f, 0.28057763f), Vec3(0.18364045f, -0.133422598f, 0.28057763f),
            Vec3(0.18364045f, 0.133422598f, 0.28057763f), Vec3(1.32604575f, 0.121352553f, 1.41421354f),
            Vec3(1.32604575f, -0.121352553f, 1.41421354f), Vec3(0.294357538f, 1.29864454f, 1.41421354f),
            Vec3(0.525183797f, 1.2236445f, 1.41421354f), Vec3(-1.14412284f, 0.68125391f, 1.41421354f),
            Vec3(-1.00146437f, 0.877606452f, 1.41421354f), Vec3(-1.00146437f, -0.877606452f, 1.41421354f),
            Vec3(-1.14412284f, -0.68125391f, 1.41421354f), Vec3(0.525183797f, -1.2236445f, 1.41421354f),
            Vec3(0.294357538f, -1.29864454f, 1.41421354f), Vec3(0.173903361f, 0.0671154186f, 0.249067754f),
            Vec3(1.35537088f, 0.063798815f, 1.41421354f), Vec3(0.170461401f, 0f, 0.237929314f),
            Vec3(1.36547554f, 0f, 1.41421354f), Vec3(0.173903361f, -0.0671154186f, 0.249067754f),
            Vec3(1.35537088f, -0.063798815f, 1.41421354f), Vec3(0.479508907f, 1.26931942f, 1.41421354f),
            Vec3(0.117569648f, 0.144652128f, 0.249067754f), Vec3(0.421955168f, 1.29864454f, 1.41421354f),
            Vec3(0.052675467f, 0.16211842f, 0.237929314f), Vec3(0.358156353f, 1.30874932f, 1.41421354f),
            Vec3(-0.010091465f, 0.186131731f, 0.249067754f), Vec3(-1.05901814f, 0.848281384f, 1.41421354f),
            Vec3(-0.101241328f, 0.156515345f, 0.249067754f), Vec3(-1.10469306f, 0.802606463f, 1.41421354f),
            Vec3(-0.137906179f, 0.1001947f, 0.237929314f), Vec3(-1.13401806f, 0.745052695f, 1.41421354f),
            Vec3(-0.180140227f, 0.0479203202f, 0.249067754f), Vec3(-1.13401806f, -0.745052695f, 1.41421354f),
            Vec3(-0.180140227f, -0.0479203202f, 0.249067754f), Vec3(-1.10469306f, -0.802606463f, 1.41421354f),
            Vec3(-0.137906179f, -0.1001947f, 0.237929314f), Vec3(-1.05901814f, -0.848281384f, 1.41421354f),
            Vec3(-0.101241328f, -0.156515345f, 0.249067754f), Vec3(0.358156353f, -1.30874932f, 1.41421354f),
            Vec3(-0.010091465f, -0.186131731f, 0.249067754f), Vec3(0.421955168f, -1.29864454f, 1.41421354f),
            Vec3(0.052675467f, -0.16211842f, 0.237929314f), Vec3(0.479508907f, -1.26931942f, 1.41421354f),
            Vec3(0.117569648f, -0.144652128f, 0.249067754f), Vec3(0f, 0f, 0.153479129f),
            Vec3(0.0275201984f, 0.0846984684f, 0.169366434f), Vec3(-0.0394169502f, 0.118936077f, 0.186611712f),
            Vec3(-0.0710294694f, 0.0516059324f, 0.169366434f), Vec3(-0.124025501f, 0f, 0.186418399f),
            Vec3(-0.0710294694f, -0.0516059324f, 0.169366434f), Vec3(-0.0394169502f, -0.118936077f, 0.186611712f),
            Vec3(0.0275201984f, -0.0846984684f, 0.169366434f), Vec3(0.102709487f, -0.0743011981f, 0.186391726f),
            Vec3(0.0921325088f, 0f, 0.169366434f), Vec3(0.102709487f, 0.0743011981f, 0.186391726f),
        ];
        static immutable uint[][] wantFaces = [
            [3u, 13u, 6u], [2u, 11u, 14u], [1u, 9u, 12u],
            [0u, 7u, 10u], [4u, 5u, 8u], [5u, 4u, 15u, 16u],
            [16u, 15u, 17u, 18u], [18u, 17u, 19u, 20u], [20u, 19u, 3u, 6u],
            [4u, 8u, 21u, 22u], [22u, 21u, 23u, 24u], [24u, 23u, 25u, 26u],
            [26u, 25u, 7u, 0u], [0u, 10u, 27u, 28u], [28u, 27u, 29u, 30u],
            [30u, 29u, 31u, 32u], [32u, 31u, 9u, 1u], [1u, 12u, 33u, 34u],
            [34u, 33u, 35u, 36u], [36u, 35u, 37u, 38u], [38u, 37u, 11u, 2u],
            [2u, 14u, 39u, 40u], [40u, 39u, 41u, 42u], [42u, 41u, 43u, 44u],
            [44u, 43u, 13u, 3u], [0u, 28u, 47u, 26u], [26u, 47u, 46u, 24u],
            [28u, 30u, 48u, 47u], [47u, 48u, 45u, 46u], [1u, 34u, 49u, 32u],
            [32u, 49u, 48u, 30u], [34u, 36u, 50u, 49u], [49u, 50u, 45u, 48u],
            [2u, 40u, 51u, 38u], [38u, 51u, 50u, 36u], [40u, 42u, 52u, 51u],
            [51u, 52u, 45u, 50u], [3u, 19u, 53u, 44u], [44u, 53u, 52u, 42u],
            [19u, 17u, 54u, 53u], [53u, 54u, 45u, 52u], [4u, 22u, 55u, 15u],
            [15u, 55u, 54u, 17u], [22u, 24u, 46u, 55u], [55u, 46u, 45u, 54u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K5 junction (symmetric) L2 (task 0453 parity)", 4);
    assertBevelManifoldCleanOpen(m, "K5 junction (symmetric) L2 (task 0453 parity)", 1);
}

unittest { // bevelEdgesByMask: "K5 junction (symmetric)" L3
           // Parity fixture (task 0453, flipped from the prior XFAIL Hausdorff
           // band) — see the L2 test above for the newC_i two-stage
           // correction that closes this. Transcribed FROM the reference
           // capture dump edge_bevel_gen_k5_junction_level3, NOT our kernel's
           // output.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.414213562373095f,0,1.4142135623730951f),
        Vec3(0.4370160244488211f,1.3449970239279145f,1.4142135623730951f),
        Vec3(-1.1441228056353683f,0.8312538755549069f,1.4142135623730951f),
        Vec3(-1.1441228056353687f,-0.8312538755549066f,1.4142135623730951f),
        Vec3(0.43701602444882076f,-1.3449970239279145f,1.4142135623730951f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,5u]); m.addFace([0u,5u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 3);
        immutable Vec3[] wantVerts = [
            Vec3(-0.0701444149f, 0.215882301f, 0.28057763f), Vec3(-0.226992086f, 0f, 0.28057763f),
            Vec3(-0.0701444149f, -0.215882301f, 0.28057763f), Vec3(0.18364045f, -0.133422598f, 0.28057763f),
            Vec3(0.18364045f, 0.133422598f, 0.28057763f), Vec3(1.32604575f, 0.121352553f, 1.41421354f),
            Vec3(1.32604575f, -0.121352553f, 1.41421354f), Vec3(0.294357538f, 1.29864454f, 1.41421354f),
            Vec3(0.525183797f, 1.2236445f, 1.41421354f), Vec3(-1.14412284f, 0.68125391f, 1.41421354f),
            Vec3(-1.00146437f, 0.877606452f, 1.41421354f), Vec3(-1.00146437f, -0.877606452f, 1.41421354f),
            Vec3(-1.14412284f, -0.68125391f, 1.41421354f), Vec3(0.525183797f, -1.2236445f, 1.41421354f),
            Vec3(0.294357538f, -1.29864454f, 1.41421354f), Vec3(0.17651172f, 0.0893723145f, 0.257508576f),
            Vec3(1.34762645f, 0.0839737505f, 1.41421354f), Vec3(0.172003523f, 0.044779174f, 0.242919758f),
            Vec3(1.36096394f, 0.0429248847f, 1.41421354f), Vec3(0.170461401f, 0f, 0.237929314f),
            Vec3(1.36547554f, 0f, 1.41421354f), Vec3(0.172003523f, -0.044779174f, 0.242919758f),
            Vec3(1.36096394f, -0.0429248847f, 1.41421354f), Vec3(0.17651172f, -0.0893723145f, 0.257508576f),
            Vec3(1.34762645f, -0.0839737505f, 1.41421354f), Vec3(0.496303231f, 1.25571966f, 1.41421354f),
            Vec3(0.13954325f, 0.140255064f, 0.257508576f), Vec3(0.461384982f, 1.28108919f, 1.41421354f),
            Vec3(0.095739536f, 0.14974755f, 0.242919758f), Vec3(0.421955168f, 1.29864454f, 1.41421354f),
            Vec3(0.052675467f, 0.16211842f, 0.237929314f), Vec3(0.37973702f, 1.30761826f, 1.41421354f),
            Vec3(0.0105644856f, 0.177422598f, 0.242919758f), Vec3(0.336575687f, 1.30761826f, 1.41421354f),
            Vec3(-0.0304530058f, 0.195490196f, 0.257508576f), Vec3(-1.04089415f, 0.860051155f, 1.41421354f),
            Vec3(-0.0902692601f, 0.176054716f, 0.257508576f), Vec3(-1.07581246f, 0.834681571f, 1.41421354f),
            Vec3(-0.112833239f, 0.137328252f, 0.242919758f), Vec3(-1.10469306f, 0.802606463f, 1.41421354f),
            Vec3(-0.137906179f, 0.1001947f, 0.237929314f), Vec3(-1.12627363f, 0.765227675f, 1.41421354f),
            Vec3(-0.165474325f, 0.0648740232f, 0.242919758f), Vec3(-1.13961124f, 0.724178791f, 1.41421354f),
            Vec3(-0.195332721f, 0.0314472653f, 0.257508576f), Vec3(-1.13961124f, -0.724178791f, 1.41421354f),
            Vec3(-0.195332721f, -0.0314472653f, 0.257508576f), Vec3(-1.12627363f, -0.765227675f, 1.41421354f),
            Vec3(-0.165474325f, -0.0648740232f, 0.242919758f), Vec3(-1.10469306f, -0.802606463f, 1.41421354f),
            Vec3(-0.137906179f, -0.1001947f, 0.237929314f), Vec3(-1.07581246f, -0.834681571f, 1.41421354f),
            Vec3(-0.112833239f, -0.137328252f, 0.242919758f), Vec3(-1.04089415f, -0.860051155f, 1.41421354f),
            Vec3(-0.0902692601f, -0.176054716f, 0.257508576f), Vec3(0.336575687f, -1.30761826f, 1.41421354f),
            Vec3(-0.0304530058f, -0.195490196f, 0.257508576f), Vec3(0.37973702f, -1.30761826f, 1.41421354f),
            Vec3(0.0105644856f, -0.177422598f, 0.242919758f), Vec3(0.421955168f, -1.29864454f, 1.41421354f),
            Vec3(0.052675467f, -0.16211842f, 0.237929314f), Vec3(0.461384982f, -1.28108919f, 1.41421354f),
            Vec3(0.095739536f, -0.14974755f, 0.242919758f), Vec3(0.496303231f, -1.25571966f, 1.41421354f),
            Vec3(0.13954325f, -0.140255064f, 0.257508576f), Vec3(0f, 0f, 0.153479129f),
            Vec3(0.0351347737f, 0.108133726f, 0.181723237f), Vec3(-0.0493872538f, 0.151111647f, 0.210518301f),
            Vec3(-0.0106120091f, 0.128404945f, 0.189850703f), Vec3(0.0191254169f, 0.0588619933f, 0.160540164f),
            Vec3(-0.0677968487f, 0.109681003f, 0.189847544f), Vec3(-0.0285200775f, 0.0848556459f, 0.169212312f),
            Vec3(-0.0913799852f, 0.0663914457f, 0.181723237f), Vec3(-0.0488628857f, 0.0355009623f, 0.160540164f),
            Vec3(-0.158553377f, 0f, 0.210450068f), Vec3(-0.124416769f, 0.0300364532f, 0.189712837f),
            Vec3(-0.124416769f, -0.0300364532f, 0.189712837f), Vec3(-0.0875538662f, 0f, 0.168942183f),
            Vec3(-0.0913799852f, -0.0663914457f, 0.181723237f), Vec3(-0.0488628857f, -0.0355009623f, 0.160540164f),
            Vec3(-0.0493872538f, -0.151111647f, 0.210518301f), Vec3(-0.0677968487f, -0.109681003f, 0.189847544f),
            Vec3(-0.0106120091f, -0.128404945f, 0.189850703f), Vec3(-0.0285200775f, -0.0848556459f, 0.169212312f),
            Vec3(0.0351347737f, -0.108133726f, 0.181723237f), Vec3(0.0191254169f, -0.0588619933f, 0.160540164f),
            Vec3(0.128997087f, -0.0936612561f, 0.21043618f), Vec3(0.0845224187f, -0.0985211208f, 0.189710811f),
            Vec3(0.120313279f, -0.0497607328f, 0.189663827f), Vec3(0.0750086904f, -0.0536398329f, 0.168922797f),
            Vec3(0.115520909f, 0f, 0.181723237f), Vec3(0.0655359253f, 0f, 0.160540149f),
            Vec3(0.128997087f, 0.0936612561f, 0.21043618f), Vec3(0.120313279f, 0.0497607328f, 0.189663827f),
            Vec3(0.0845224187f, 0.0985211208f, 0.189710811f), Vec3(0.0750086904f, 0.0536398329f, 0.168922797f),
        ];
        static immutable uint[][] wantFaces = [
            [3u, 13u, 6u], [2u, 11u, 14u], [1u, 9u, 12u],
            [0u, 7u, 10u], [4u, 5u, 8u], [5u, 4u, 15u, 16u],
            [16u, 15u, 17u, 18u], [18u, 17u, 19u, 20u], [20u, 19u, 21u, 22u],
            [22u, 21u, 23u, 24u], [24u, 23u, 3u, 6u], [4u, 8u, 25u, 26u],
            [26u, 25u, 27u, 28u], [28u, 27u, 29u, 30u], [30u, 29u, 31u, 32u],
            [32u, 31u, 33u, 34u], [34u, 33u, 7u, 0u], [0u, 10u, 35u, 36u],
            [36u, 35u, 37u, 38u], [38u, 37u, 39u, 40u], [40u, 39u, 41u, 42u],
            [42u, 41u, 43u, 44u], [44u, 43u, 9u, 1u], [1u, 12u, 45u, 46u],
            [46u, 45u, 47u, 48u], [48u, 47u, 49u, 50u], [50u, 49u, 51u, 52u],
            [52u, 51u, 53u, 54u], [54u, 53u, 11u, 2u], [2u, 14u, 55u, 56u],
            [56u, 55u, 57u, 58u], [58u, 57u, 59u, 60u], [60u, 59u, 61u, 62u],
            [62u, 61u, 63u, 64u], [64u, 63u, 13u, 3u], [0u, 36u, 67u, 34u],
            [34u, 67u, 68u, 32u], [32u, 68u, 66u, 30u], [36u, 38u, 70u, 67u],
            [67u, 70u, 71u, 68u], [68u, 71u, 69u, 66u], [38u, 40u, 72u, 70u],
            [70u, 72u, 73u, 71u], [71u, 73u, 65u, 69u], [1u, 46u, 74u, 44u],
            [44u, 74u, 75u, 42u], [42u, 75u, 72u, 40u], [46u, 48u, 76u, 74u],
            [74u, 76u, 77u, 75u], [75u, 77u, 73u, 72u], [48u, 50u, 78u, 76u],
            [76u, 78u, 79u, 77u], [77u, 79u, 65u, 73u], [2u, 56u, 80u, 54u],
            [54u, 80u, 81u, 52u], [52u, 81u, 78u, 50u], [56u, 58u, 82u, 80u],
            [80u, 82u, 83u, 81u], [81u, 83u, 79u, 78u], [58u, 60u, 84u, 82u],
            [82u, 84u, 85u, 83u], [83u, 85u, 65u, 79u], [3u, 23u, 86u, 64u],
            [64u, 86u, 87u, 62u], [62u, 87u, 84u, 60u], [23u, 21u, 88u, 86u],
            [86u, 88u, 89u, 87u], [87u, 89u, 85u, 84u], [21u, 19u, 90u, 88u],
            [88u, 90u, 91u, 89u], [89u, 91u, 65u, 85u], [4u, 26u, 92u, 15u],
            [15u, 92u, 93u, 17u], [17u, 93u, 90u, 19u], [26u, 28u, 94u, 92u],
            [92u, 94u, 95u, 93u], [93u, 95u, 91u, 90u], [28u, 30u, 66u, 94u],
            [94u, 66u, 69u, 95u], [95u, 69u, 65u, 91u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K5 junction (symmetric) L3 (task 0453 parity)", 4);
    assertBevelManifoldCleanOpen(m, "K5 junction (symmetric) L3 (task 0453 parity)", 1);
}

unittest { // bevelEdgesByMask: "K5 junction (ASYMMETRIC)" L1 (task 0453)
           // Companion to the K5-symmetric fixtures above — 5 rays at
           // irregular azimuth/radius/height (73.6/71.7/92.0/56.3/66.4 deg
           // gaps; radii 1.60/1.77/1.58/1.66/1.75; heights 1.3/1.6/1.1/1.8/1.0)
           // so every pairwise adjacent-direction angle differs. This is the
           // capture that pinned the odd-N corner-move's (i,i+1) forward pairing
           // (gate A4, toolcards/edge.bevel/nway_hub_law_findings.md finding
           // J) — the K5-SYMMETRIC fixture's 5-fold symmetry collapses every
           // adjacent-pair angle to <=2 distinct values, so a WRONG pairing
           // reproduces it too; this asymmetric case cannot be fooled that
           // way. L1 has NO ring surface (m=L-1=0, mesh.d ~9880) so it is a
           // topology/regression guard only — it does NOT exercise
           // the center-normal/corner-move steps (L2/L3 below do). Transcribed FROM the
           // reference capture dump edge_bevel_gen_k5_asym1_level1, NOT our
           // kernel's output.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.6f, 0.0f, 1.3f),
        Vec3(0.5f, 1.7f, 1.6f),
        Vec3(-1.3f, 0.9f, 1.1f),
        Vec3(-0.9f, -1.4f, 1.8f),
        Vec3(0.7f, -1.6f, 1.0f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,5u]); m.addFace([0u,5u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 1);
        immutable Vec3[] wantVerts = [
            Vec3(-0.0852779001f, 0.21604526f, 0.227394179f), Vec3(-0.170565262f, -0.0169928204f, 0.2136603f),
            Vec3(-0.00400275411f, -0.28355059f, 0.25553444f), Vec3(0.207560346f, -0.146821991f, 0.208215892f),
            Vec3(0.182297945f, 0.131709948f, 0.240604565f), Vec3(1.51939225f, 0.124575652f, 1.32198393f),
            Vec3(1.52742362f, -0.129024804f, 1.27580786f), Vec3(0.367141694f, 1.64095187f, 1.56309497f),
            Vec3(0.580607772f, 1.57542443f, 1.57801604f), Vec3(-1.27538168f, 0.758444786f, 1.14308202f),
            Vec3(-1.16714168f, 0.959048092f, 1.13690507f), Vec3(-0.766666651f, -1.41666663f, 1.73333323f),
            Vec3(-0.924618244f, -1.25844479f, 1.75691795f), Vec3(0.772576451f, -1.47097528f, 1.02419209f),
            Vec3(0.566666663f, -1.58333337f, 1.06666672f), Vec3(0.176859111f, -0.00486478489f, 0.186566129f),
            Vec3(1.55881381f, -0.00119623414f, 1.29940629f), Vec3(0.485036939f, 1.6474154f, 1.58313584f),
            Vec3(0.0452261008f, 0.158713356f, 0.195000172f), Vec3(-1.25526452f, 0.876561582f, 1.12272251f),
            Vec3(-0.123035066f, 0.0951575413f, 0.177007675f), Vec3(-0.86892724f, -1.36430454f, 1.76863182f),
            Vec3(-0.076281935f, -0.13924621f, 0.198674411f), Vec3(0.683072448f, -1.55940878f, 1.02531433f),
            Vec3(0.0897960663f, -0.19845508f, 0.191888586f), Vec3(0.0156460032f, -0.0159189813f, 0.121292256f),
        ];
        static immutable uint[][] wantFaces = [
            [3u, 13u, 6u], [2u, 11u, 14u], [1u, 9u, 12u],
            [0u, 7u, 10u], [4u, 5u, 8u], [5u, 4u, 15u, 16u],
            [16u, 15u, 3u, 6u], [4u, 8u, 17u, 18u], [18u, 17u, 7u, 0u],
            [0u, 10u, 19u, 20u], [20u, 19u, 9u, 1u], [1u, 12u, 21u, 22u],
            [22u, 21u, 11u, 2u], [2u, 14u, 23u, 24u], [24u, 23u, 13u, 3u],
            [0u, 20u, 25u, 18u], [1u, 22u, 25u, 20u], [2u, 24u, 25u, 22u],
            [3u, 15u, 25u, 24u], [4u, 18u, 25u, 15u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K5 junction (asymmetric) L1 (task 0453 parity, topology guard)", 4);
    assertBevelManifoldCleanOpen(m, "K5 junction (asymmetric) L1 (task 0453 parity, topology guard)", 1);
}

unittest { // bevelEdgesByMask: "K5 junction (ASYMMETRIC)" L2 (task 0453)
           // THE DISCRIMINATING NON-PLANAR ODD-N ORACLE: only BOTH
           // the center-normal step (Stage 1, planarizes the newC ring) AND
           // the odd-N corner-move step (Stage 2, the odd-N sin-angle magnitude
           // recurrence with its (i,i+1)-forward pairing) wired correctly
           // pass this fixture — a Stage-1-only or Stage-2-only port fails
           // it (verified while landing this port: reverting either stage
           // reproduces a real, non-roundoff mismatch here, unlike the
           // near-planar/5-fold-symmetric K5-SYMMETRIC fixture above, which
           // cannot tell a wrong/missing mechanism apart). Transcribed FROM
           // the reference capture dump edge_bevel_gen_k5_asym1_level2, NOT
           // our kernel's output.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.6f, 0.0f, 1.3f),
        Vec3(0.5f, 1.7f, 1.6f),
        Vec3(-1.3f, 0.9f, 1.1f),
        Vec3(-0.9f, -1.4f, 1.8f),
        Vec3(0.7f, -1.6f, 1.0f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,5u]); m.addFace([0u,5u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 2);
        immutable Vec3[] wantVerts = [
            Vec3(-0.0852779001f, 0.21604526f, 0.227394179f), Vec3(-0.170565262f, -0.0169928204f, 0.2136603f),
            Vec3(-0.00400275411f, -0.28355059f, 0.25553444f), Vec3(0.207560346f, -0.146821991f, 0.208215892f),
            Vec3(0.182297945f, 0.131709948f, 0.240604565f), Vec3(1.51939225f, 0.124575652f, 1.32198393f),
            Vec3(1.52742362f, -0.129024804f, 1.27580786f), Vec3(0.367141694f, 1.64095187f, 1.56309497f),
            Vec3(0.580607772f, 1.57542443f, 1.57801604f), Vec3(-1.27538168f, 0.758444786f, 1.14308202f),
            Vec3(-1.16714168f, 0.959048092f, 1.13690507f), Vec3(-0.766666651f, -1.41666663f, 1.73333323f),
            Vec3(-0.924618244f, -1.25844479f, 1.75691795f), Vec3(0.772576451f, -1.47097528f, 1.02419209f),
            Vec3(0.566666663f, -1.58333337f, 1.06666672f), Vec3(0.175049499f, 0.0656174943f, 0.20458667f),
            Vec3(1.54771912f, 0.0642910376f, 1.31124806f), Vec3(0.176859111f, -0.00486478489f, 0.186566129f),
            Vec3(1.55881381f, -0.00119623414f, 1.29940629f), Vec3(0.187990263f, -0.0767353475f, 0.18806769f),
            Vec3(1.55188358f, -0.0672070235f, 1.28730464f), Vec3(0.539268434f, 1.61974263f, 1.58387649f),
            Vec3(0.114473499f, 0.140980408f, 0.208330557f), Vec3(0.485036939f, 1.6474154f, 1.58313584f),
            Vec3(0.0452261008f, 0.158713356f, 0.195000172f), Vec3(0.425034881f, 1.65480876f, 1.57589161f),
            Vec3(-0.022327533f, 0.18426767f, 0.201784655f), Vec3(-1.21764696f, 0.925425231f, 1.12553203f),
            Vec3(-0.101113625f, 0.156254679f, 0.190227464f), Vec3(-1.25526452f, 0.876561582f, 1.12272251f),
            Vec3(-0.123035066f, 0.0951575413f, 0.177007675f), Vec3(-1.2753377f, 0.818505943f, 1.12882423f),
            Vec3(-0.147497505f, 0.0363321416f, 0.18641825f), Vec3(-0.905133247f, -1.31509936f, 1.76886296f),
            Vec3(-0.122292675f, -0.0752562359f, 0.199059933f), Vec3(-0.86892724f, -1.36430454f, 1.76863182f),
            Vec3(-0.076281935f, -0.13924621f, 0.198674411f), Vec3(-0.820689201f, -1.39968789f, 1.7562542f),
            Vec3(-0.0359070748f, -0.208884075f, 0.216690674f), Vec3(0.625275314f, -1.58078015f, 1.04168904f),
            Vec3(0.0386393443f, -0.235370308f, 0.212197214f), Vec3(0.683072448f, -1.55940878f, 1.02531433f),
            Vec3(0.0897960663f, -0.19845508f, 0.191888586f), Vec3(0.733961999f, -1.52147341f, 1.01926947f),
            Vec3(0.147240192f, -0.170318812f, 0.19256112f), Vec3(0.0156460032f, -0.0159189813f, 0.121292256f),
            Vec3(0.0279410314f, 0.0808866695f, 0.136409372f), Vec3(-0.039511662f, 0.119883671f, 0.149317011f),
            Vec3(-0.0506241322f, 0.0464868993f, 0.128361225f), Vec3(-0.0777839422f, -0.0191027895f, 0.136521921f),
            Vec3(-0.0284031741f, -0.0883590505f, 0.138172224f), Vec3(-7.924893e-05f, -0.169746548f, 0.168530405f),
            Vec3(0.0440978631f, -0.113180876f, 0.139003575f), Vec3(0.110189766f, -0.085667029f, 0.139268145f),
            Vec3(0.0959199816f, -0.00571418973f, 0.131871849f), Vec3(0.101141796f, 0.0711638331f, 0.152629852f),
        ];
        static immutable uint[][] wantFaces = [
            [3u, 13u, 6u], [2u, 11u, 14u], [1u, 9u, 12u],
            [0u, 7u, 10u], [4u, 5u, 8u], [5u, 4u, 15u, 16u],
            [16u, 15u, 17u, 18u], [18u, 17u, 19u, 20u], [20u, 19u, 3u, 6u],
            [4u, 8u, 21u, 22u], [22u, 21u, 23u, 24u], [24u, 23u, 25u, 26u],
            [26u, 25u, 7u, 0u], [0u, 10u, 27u, 28u], [28u, 27u, 29u, 30u],
            [30u, 29u, 31u, 32u], [32u, 31u, 9u, 1u], [1u, 12u, 33u, 34u],
            [34u, 33u, 35u, 36u], [36u, 35u, 37u, 38u], [38u, 37u, 11u, 2u],
            [2u, 14u, 39u, 40u], [40u, 39u, 41u, 42u], [42u, 41u, 43u, 44u],
            [44u, 43u, 13u, 3u], [0u, 28u, 47u, 26u], [26u, 47u, 46u, 24u],
            [28u, 30u, 48u, 47u], [47u, 48u, 45u, 46u], [1u, 34u, 49u, 32u],
            [32u, 49u, 48u, 30u], [34u, 36u, 50u, 49u], [49u, 50u, 45u, 48u],
            [2u, 40u, 51u, 38u], [38u, 51u, 50u, 36u], [40u, 42u, 52u, 51u],
            [51u, 52u, 45u, 50u], [3u, 19u, 53u, 44u], [44u, 53u, 52u, 42u],
            [19u, 17u, 54u, 53u], [53u, 54u, 45u, 52u], [4u, 22u, 55u, 15u],
            [15u, 55u, 54u, 17u], [22u, 24u, 46u, 55u], [55u, 46u, 45u, 54u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K5 junction (asymmetric) L2 (task 0453 parity, both stages load-bearing)", 4);
    assertBevelManifoldCleanOpen(m, "K5 junction (asymmetric) L2 (task 0453 parity, both stages load-bearing)", 1);
}

unittest { // bevelEdgesByMask: "K5 junction (ASYMMETRIC)" L3 (task 0453)
           // Same discriminating oracle as L2 above, one Round Level deeper
           // (exercises genuinely-interior off-diagonal ring samples like
           // (1/3,2/3) that L2 cannot reach). Transcribed FROM the reference
           // capture dump edge_bevel_gen_k5_asym1_level3, NOT our kernel's
           // output.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.6f, 0.0f, 1.3f),
        Vec3(0.5f, 1.7f, 1.6f),
        Vec3(-1.3f, 0.9f, 1.1f),
        Vec3(-0.9f, -1.4f, 1.8f),
        Vec3(0.7f, -1.6f, 1.0f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,5u]); m.addFace([0u,5u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 3);
        immutable Vec3[] wantVerts = [
            Vec3(-0.0852779001f, 0.21604526f, 0.227394179f), Vec3(-0.170565262f, -0.0169928204f, 0.2136603f),
            Vec3(-0.00400275411f, -0.28355059f, 0.25553444f), Vec3(0.207560346f, -0.146821991f, 0.208215892f),
            Vec3(0.182297945f, 0.131709948f, 0.240604565f), Vec3(1.51939225f, 0.124575652f, 1.32198393f),
            Vec3(1.52742362f, -0.129024804f, 1.27580786f), Vec3(0.367141694f, 1.64095187f, 1.56309497f),
            Vec3(0.580607772f, 1.57542443f, 1.57801604f), Vec3(-1.27538168f, 0.758444786f, 1.14308202f),
            Vec3(-1.16714168f, 0.959048092f, 1.13690507f), Vec3(-0.766666651f, -1.41666663f, 1.73333323f),
            Vec3(-0.924618244f, -1.25844479f, 1.75691795f), Vec3(0.772576451f, -1.47097528f, 1.02419209f),
            Vec3(0.566666663f, -1.58333337f, 1.06666672f), Vec3(0.176504508f, 0.088282004f, 0.214736521f),
            Vec3(1.54011583f, 0.0851874575f, 1.31498969f), Vec3(0.1746099f, 0.042464938f, 0.196455553f),
            Vec3(1.55339742f, 0.0428134538f, 1.30738294f), Vec3(0.176859111f, -0.00486478489f, 0.186566129f),
            Vec3(1.55881381f, -0.00119623414f, 1.29940629f), Vec3(0.183275163f, -0.0528150909f, 0.185403317f),
            Vec3(1.55619228f, -0.0454393774f, 1.29131377f), Vec3(0.193652064f, -0.100459799f, 0.192822561f),
            Vec3(1.54561663f, -0.0885062963f, 1.2833631f), Vec3(0.554791629f, 1.60657072f, 1.58263576f),
            Vec3(0.137401685f, 0.136945382f, 0.217112079f), Vec3(0.522298634f, 1.63104677f, 1.58437645f),
            Vec3(0.091389738f, 0.145963222f, 0.201673597f), Vec3(0.485036939f, 1.6474154f, 1.58313584f),
            Vec3(0.0452261008f, 0.158713356f, 0.195000172f), Vec3(0.445194721f, 1.6547153f, 1.57898688f),
            Vec3(-0.000180424089f, 0.17495963f, 0.197318077f), Vec3(0.40511167f, 1.6525178f, 1.57217324f),
            Vec3(-0.0439624377f, 0.194274694f, 0.208361819f), Vec3(-1.20196116f, 0.938576758f, 1.12842035f),
            Vec3(-0.0950065628f, 0.176519543f, 0.200005487f), Vec3(-1.23188746f, 0.910564542f, 1.12360406f),
            Vec3(-0.107904911f, 0.135848567f, 0.183144376f), Vec3(-1.25526452f, 0.876561582f, 1.12272251f),
            Vec3(-0.123035066f, 0.0951575413f, 0.177007675f), Vec3(-1.27079868f, 0.838449538f, 1.12582457f),
            Vec3(-0.139302745f, 0.0554835051f, 0.181001902f), Vec3(-1.27763045f, 0.7983374f, 1.13273859f),
            Vec3(-0.15553534f, 0.0177934244f, 0.193835691f), Vec3(-0.913659811f, -1.29669082f, 1.76618922f),
            Vec3(-0.138309717f, -0.0552029535f, 0.202592403f), Vec3(-0.894730687f, -1.332672f, 1.77017069f),
            Vec3(-0.10652934f, -0.09594699f, 0.197115898f), Vec3(-0.86892724f, -1.36430454f, 1.76863182f),
            Vec3(-0.076281935f, -0.13924621f, 0.198674411f), Vec3(-0.83774364f, -1.38975656f, 1.76166165f),
            Vec3(-0.0485505946f, -0.185066864f, 0.208448157f), Vec3(-0.802985847f, -1.40755415f, 1.74966383f),
            Vec3(-0.0242109057f, -0.233267426f, 0.227266297f), Vec3(0.605519414f, -1.58377743f, 1.04917288f),
            Vec3(0.0233915951f, -0.250141799f, 0.224125654f), Vec3(0.644940376f, -1.57567537f, 1.03516877f),
            Vec3(0.0548376963f, -0.221879855f, 0.202871248f), Vec3(0.683072448f, -1.55940878f, 1.02531433f),
            Vec3(0.0897960663f, -0.19845508f, 0.191888586f), Vec3(0.718119323f, -1.53574407f, 1.02007353f),
            Vec3(0.127573758f, -0.178966865f, 0.190314054f), Vec3(0.748429954f, -1.50579596f, 1.01969361f),
            Vec3(0.16723974f, -0.162182152f, 0.196489543f), Vec3(0.0156460032f, -0.0159189813f, 0.121292256f),
            Vec3(0.0325232409f, 0.106165238f, 0.148557052f), Vec3(-0.0549883246f, 0.153035805f, 0.170429468f),
            Vec3(-0.0139833326f, 0.128386274f, 0.154183015f), Vec3(0.0236116331f, 0.0521278195f, 0.127413303f),
            Vec3(-0.063408941f, 0.111812562f, 0.149248138f), Vec3(-0.0229631364f, 0.0828471631f, 0.133481041f),
            Vec3(-0.0722201988f, 0.0649933815f, 0.136948436f), Vec3(-0.0286490396f, 0.026707219f, 0.12321116f),
            Vec3(-0.106871739f, -0.0180096272f, 0.15247862f), Vec3(-0.088266708f, 0.0216247197f, 0.137940541f),
            Vec3(-0.0702802613f, -0.0606360473f, 0.143736973f), Vec3(-0.0488278717f, -0.0197665412f, 0.127204314f),
            Vec3(-0.0403597616f, -0.108367428f, 0.149791509f), Vec3(-0.0150283678f, -0.0661994815f, 0.129442766f),
            Vec3(-0.00214856048f, -0.209951326f, 0.195481926f), Vec3(-0.0194822382f, -0.161401808f, 0.169401199f),
            Vec3(0.0211955477f, -0.17650637f, 0.169162616f), Vec3(0.00311598345f, -0.125553101f, 0.145899698f),
            Vec3(0.053511925f, -0.141043276f, 0.149762869f), Vec3(0.034582518f, -0.0827843472f, 0.130467519f),
            Vec3(0.139528811f, -0.104365431f, 0.153893396f), Vec3(0.0954061076f, -0.118196003f, 0.14440158f),
            Vec3(0.126481757f, -0.0560885407f, 0.14210996f), Vec3(0.0819861442f, -0.0659179911f, 0.130202487f),
            Vec3(0.118787929f, -0.00447732257f, 0.141160846f), Vec3(0.0716019273f, -0.00793138612f, 0.125854418f),
            Vec3(0.126539528f, 0.0910913497f, 0.175776079f), Vec3(0.120283306f, 0.046029035f, 0.152999446f),
            Vec3(0.081633471f, 0.0964240134f, 0.157129362f), Vec3(0.0759667456f, 0.048969537f, 0.135532603f),
        ];
        static immutable uint[][] wantFaces = [
            [3u, 13u, 6u], [2u, 11u, 14u], [1u, 9u, 12u],
            [0u, 7u, 10u], [4u, 5u, 8u], [5u, 4u, 15u, 16u],
            [16u, 15u, 17u, 18u], [18u, 17u, 19u, 20u], [20u, 19u, 21u, 22u],
            [22u, 21u, 23u, 24u], [24u, 23u, 3u, 6u], [4u, 8u, 25u, 26u],
            [26u, 25u, 27u, 28u], [28u, 27u, 29u, 30u], [30u, 29u, 31u, 32u],
            [32u, 31u, 33u, 34u], [34u, 33u, 7u, 0u], [0u, 10u, 35u, 36u],
            [36u, 35u, 37u, 38u], [38u, 37u, 39u, 40u], [40u, 39u, 41u, 42u],
            [42u, 41u, 43u, 44u], [44u, 43u, 9u, 1u], [1u, 12u, 45u, 46u],
            [46u, 45u, 47u, 48u], [48u, 47u, 49u, 50u], [50u, 49u, 51u, 52u],
            [52u, 51u, 53u, 54u], [54u, 53u, 11u, 2u], [2u, 14u, 55u, 56u],
            [56u, 55u, 57u, 58u], [58u, 57u, 59u, 60u], [60u, 59u, 61u, 62u],
            [62u, 61u, 63u, 64u], [64u, 63u, 13u, 3u], [0u, 36u, 67u, 34u],
            [34u, 67u, 68u, 32u], [32u, 68u, 66u, 30u], [36u, 38u, 70u, 67u],
            [67u, 70u, 71u, 68u], [68u, 71u, 69u, 66u], [38u, 40u, 72u, 70u],
            [70u, 72u, 73u, 71u], [71u, 73u, 65u, 69u], [1u, 46u, 74u, 44u],
            [44u, 74u, 75u, 42u], [42u, 75u, 72u, 40u], [46u, 48u, 76u, 74u],
            [74u, 76u, 77u, 75u], [75u, 77u, 73u, 72u], [48u, 50u, 78u, 76u],
            [76u, 78u, 79u, 77u], [77u, 79u, 65u, 73u], [2u, 56u, 80u, 54u],
            [54u, 80u, 81u, 52u], [52u, 81u, 78u, 50u], [56u, 58u, 82u, 80u],
            [80u, 82u, 83u, 81u], [81u, 83u, 79u, 78u], [58u, 60u, 84u, 82u],
            [82u, 84u, 85u, 83u], [83u, 85u, 65u, 79u], [3u, 23u, 86u, 64u],
            [64u, 86u, 87u, 62u], [62u, 87u, 84u, 60u], [23u, 21u, 88u, 86u],
            [86u, 88u, 89u, 87u], [87u, 89u, 85u, 84u], [21u, 19u, 90u, 88u],
            [88u, 90u, 91u, 89u], [89u, 91u, 65u, 85u], [4u, 26u, 92u, 15u],
            [15u, 92u, 93u, 17u], [17u, 93u, 90u, 19u], [26u, 28u, 94u, 92u],
            [92u, 94u, 95u, 93u], [93u, 95u, 91u, 90u], [28u, 30u, 66u, 94u],
            [94u, 66u, 69u, 95u], [95u, 69u, 65u, 91u],
        ];
    assertFacesMatchByPositionDp(m, wantVerts, wantFaces, "K5 junction (asymmetric) L3 (task 0453 parity, both stages load-bearing)", 4);
    assertBevelManifoldCleanOpen(m, "K5 junction (asymmetric) L3 (task 0453 parity, both stages load-bearing)", 1);
}

unittest { // centerNormalProject: planarity invariant (task 0453),
           // pure-D property test — NO reference capture needed. A hand-built
           // non-planar EVEN-N (N=4) newC ring (deliberately NOT coplanar —
           // every existing even-N reference fixture happens to be
           // near-planar, per R7 in doc/nway_odd_movepoints_plan.md) is fed
           // through Stage 1 alone; every output point must satisfy the
           // projection's own defining invariant: dot(p-hub, Navg)~=0 for the
           // SAME Navg the function derives internally. Locks the every-N
           // (not just odd-N) planar-projection geometry without a
           // reference capture.
    import std.conv : to;
    immutable Vec3 hub = Vec3(0.0f, 0.0f, 0.0f);
    // Deliberately non-planar: 4 points around hub, none sharing a common
    // plane (the 4th point is pulled well off the plane the first 3 define).
    Vec3[] ring = [
        Vec3(1.0f, 0.0f, 0.0f),
        Vec3(0.0f, 1.0f, 0.2f),
        Vec3(-1.0f, 0.2f, 0.5f),
        Vec3(0.1f, -1.0f, 0.9f),
    ];
    // Independently recompute the SAME Navg the function derives (forward-
    // adjacent cross products of the ORIGINAL ring, averaged + normalized) so
    // this test does not just assert "unchanged" — it pins the actual plane.
    immutable Vec3[] ring0 = ring.dup;
    Vec3 crossSum = Vec3(0, 0, 0);
    immutable int N = 4;
    foreach (i; 0 .. N) {
        immutable int pv = (i + N - 1) % N;
        immutable Vec3 a = ring0[pv] - hub;
        immutable Vec3 b = ring0[i] - hub;
        immutable Vec3 cr = cross(a, b);
        crossSum = crossSum + cr / cr.length;
    }
    immutable Vec3 Navg = crossSum / crossSum.length;
    // Sanity: this hand-built ring is genuinely non-planar (Navg well-defined
    // and the pre-projection points are NOT already all on one plane) —
    // otherwise the test would trivially pass on a no-op.
    float maxPreDeviation = 0.0f;
    foreach (p; ring0) {
        immutable float d = dot(hub - p, Navg);
        if (d < 0) maxPreDeviation = maxPreDeviation > -d ? maxPreDeviation : -d;
        else maxPreDeviation = maxPreDeviation > d ? maxPreDeviation : d;
    }
    assert(maxPreDeviation > 0.05f, "centerNormalProject planarity test: hand-built ring must be genuinely non-planar pre-projection (got max deviation "
        ~ maxPreDeviation.to!string ~ ") — otherwise this test is a no-op, not a real check");

    // Task 0717 moved this out of struct Mesh into mesh_ops.bevel_curves; it
    // was a `static` member with exactly one caller (junctionRingN) and this
    // one test, and it is pure math with no mesh in it.
    import mesh_ops.bevel_curves : centerNormalProject;
    centerNormalProject(N, hub, ring);

    foreach (i, p; ring) {
        immutable float dev = dot(p - hub, Navg);
        assert(dev > -1e-4f && dev < 1e-4f,
            "centerNormalProject planarity invariant violated at ring[" ~ i.to!string
            ~ "]: dot(p-hub, Navg) = " ~ dev.to!string ~ " (want ~0)");
    }
}

unittest { // bevelEdgesByMask: "mixed K4 free-end" w0.05 L1
           // OWNER MESH (task 0456 live gate): once-subdivided cube, N=4 hub at an
           // interior cube-edge midpoint (2 of its 4 rays are FLAT internal split
           // edges, 2 are 90deg cube edges). Reference edge_bevel_mixed_k4fe_w0p05_L1
           // has 46v/38f; our FACE count matches exactly (38). Our vertex count
           // now MATCHES the reference: at each planar valence-4 full-hub free-end
           // cap (Round Level >= 1) the two reduced side faces stay anchored
           // at the RETAINED original free-end vertex (coincident with the
           // chamfer-strip pinch → a pinched cap quad), and the slide along
           // the OPPOSITE edge is kept as an intended orphan — reproducing the
           // reference cap topology derived purely from its measured dumps.
           // Every reference vertex position is reproduced within the
           // float32-mesh floor.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f),
        Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
        Vec3(0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(0f,0f,-0.5f),
        Vec3(-0.5f,0f,-0.5f), Vec3(0f,0.5f,-0.5f), Vec3(0.5f,0f,-0.5f),
        Vec3(0f,-0.5f,-0.5f), Vec3(0f,0f,0.5f), Vec3(0f,-0.5f,0.5f),
        Vec3(0.5f,0f,0.5f), Vec3(0f,0.5f,0.5f), Vec3(-0.5f,0f,0.5f),
        Vec3(0f,-0.5f,0f), Vec3(0.5f,-0.5f,0f), Vec3(-0.5f,-0.5f,0f),
        Vec3(0f,0.5f,0f), Vec3(-0.5f,0.5f,0f), Vec3(0.5f,0.5f,0f),
        Vec3(-0.5f,0f,0f), Vec3(0.5f,0f,0f),
    ];
    m.addFace([0u,9u,8u,12u]); m.addFace([3u,10u,8u,9u]); m.addFace([2u,11u,8u,10u]); m.addFace([1u,12u,8u,11u]);
    m.addFace([4u,14u,13u,17u]); m.addFace([5u,15u,13u,14u]); m.addFace([6u,16u,13u,15u]); m.addFace([7u,17u,13u,16u]);
    m.addFace([0u,12u,18u,20u]); m.addFace([1u,19u,18u,12u]); m.addFace([5u,14u,18u,19u]); m.addFace([4u,20u,18u,14u]);
    m.addFace([3u,22u,21u,10u]); m.addFace([7u,16u,21u,22u]); m.addFace([6u,23u,21u,16u]); m.addFace([2u,10u,21u,23u]);
    m.addFace([0u,20u,24u,9u]); m.addFace([4u,17u,24u,20u]); m.addFace([7u,22u,24u,17u]); m.addFace([3u,9u,24u,22u]);
    m.addFace([1u,11u,25u,19u]); m.addFace([2u,23u,25u,11u]); m.addFace([6u,15u,25u,23u]); m.addFace([5u,19u,25u,15u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(23)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.05f, 1);
    assert(m.faces.length == 38, "mixed K4fe w0.05 L1 (task 0456 owner): face count == reference");
    assert(m.vertices.length == 46, "mixed K4fe w0.05 L1 (task 0456 owner): vertex count matches reference (46)");
        immutable Vec3[] dumpVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.5f, -0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f),
            Vec3(0f, 0f, -0.5f), Vec3(-0.5f, 0f, -0.5f), Vec3(0f, 0.5f, -0.5f),
            Vec3(0.5f, 0f, -0.5f), Vec3(0f, -0.5f, -0.5f), Vec3(0f, 0f, 0.5f),
            Vec3(0f, -0.5f, 0.5f), Vec3(0.5f, 0f, 0.5f), Vec3(0f, 0.5f, 0.5f),
            Vec3(-0.5f, 0f, 0.5f), Vec3(0f, -0.5f, 0f), Vec3(0.5f, -0.5f, 0f),
            Vec3(-0.5f, -0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(-0.5f, 0.5f, 0f),
            Vec3(-0.5f, 0f, 0f), Vec3(0.5f, 0f, 0f), Vec3(0.449999988f, 0.5f, -0.5f),
            Vec3(0.5f, 0.449999988f, -0.5f), Vec3(0.5f, 0.449999988f, 0.5f), Vec3(0.449999988f, 0.5f, 0.5f),
            Vec3(-0.0500000007f, 0.5f, 0f), Vec3(0f, 0.5f, 0.0500000007f), Vec3(0f, 0.5f, -0.0500000007f),
            Vec3(0.5f, 0.449999988f, 0.0500000007f), Vec3(0.5f, 0.449999988f, -0.0500000007f), Vec3(0.449999988f, 0.5f, -0.0500000007f),
            Vec3(0.449999988f, 0.5f, 0.0500000007f), Vec3(0.5f, 0f, -0.0500000007f), Vec3(0.5f, 0f, 0.0500000007f),
            Vec3(0.5f, -0.0500000007f, 0f), Vec3(0.485355347f, 0.485355347f, 0.5f), Vec3(0.485355347f, 0.485355347f, 0.0500000007f),
            Vec3(0.449999988f, 0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(0.485355347f, 0.485355347f, -0.0500000007f),
            Vec3(0.485355347f, 0.485355347f, -0.5f), Vec3(0.5f, 0.449999988f, 0f), Vec3(0.5f, 0f, 0f),
            Vec3(0.485355347f, 0.485355347f, 0f),
        ];
    assertHubHausdorffWithin(m, dumpVerts, 1e-4f, "mixed K4fe w0.05 L1 (task 0456 owner)");
    assertBevelManifoldCleanOpen(m, "mixed K4fe w0.05 L1 (task 0456 owner)", 2);
}

unittest { // bevelEdgesByMask: "mixed K4 free-end" w0.05 L2
           // OWNER MESH (task 0456 live gate): once-subdivided cube, N=4 hub at an
           // interior cube-edge midpoint (2 of its 4 rays are FLAT internal split
           // edges, 2 are 90deg cube edges). Reference edge_bevel_mixed_k4fe_w0p05_L2
           // has 70v/58f; our FACE count matches exactly (58). Our vertex count
           // now MATCHES the reference: at each planar valence-4 full-hub free-end
           // cap (Round Level >= 1) the two reduced side faces stay anchored
           // at the RETAINED original free-end vertex (coincident with the
           // chamfer-strip pinch → a pinched cap quad), and the slide along
           // the OPPOSITE edge is kept as an intended orphan — reproducing the
           // reference cap topology derived purely from its measured dumps.
           // Every reference vertex position is reproduced within the
           // float32-mesh floor.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f),
        Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
        Vec3(0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(0f,0f,-0.5f),
        Vec3(-0.5f,0f,-0.5f), Vec3(0f,0.5f,-0.5f), Vec3(0.5f,0f,-0.5f),
        Vec3(0f,-0.5f,-0.5f), Vec3(0f,0f,0.5f), Vec3(0f,-0.5f,0.5f),
        Vec3(0.5f,0f,0.5f), Vec3(0f,0.5f,0.5f), Vec3(-0.5f,0f,0.5f),
        Vec3(0f,-0.5f,0f), Vec3(0.5f,-0.5f,0f), Vec3(-0.5f,-0.5f,0f),
        Vec3(0f,0.5f,0f), Vec3(-0.5f,0.5f,0f), Vec3(0.5f,0.5f,0f),
        Vec3(-0.5f,0f,0f), Vec3(0.5f,0f,0f),
    ];
    m.addFace([0u,9u,8u,12u]); m.addFace([3u,10u,8u,9u]); m.addFace([2u,11u,8u,10u]); m.addFace([1u,12u,8u,11u]);
    m.addFace([4u,14u,13u,17u]); m.addFace([5u,15u,13u,14u]); m.addFace([6u,16u,13u,15u]); m.addFace([7u,17u,13u,16u]);
    m.addFace([0u,12u,18u,20u]); m.addFace([1u,19u,18u,12u]); m.addFace([5u,14u,18u,19u]); m.addFace([4u,20u,18u,14u]);
    m.addFace([3u,22u,21u,10u]); m.addFace([7u,16u,21u,22u]); m.addFace([6u,23u,21u,16u]); m.addFace([2u,10u,21u,23u]);
    m.addFace([0u,20u,24u,9u]); m.addFace([4u,17u,24u,20u]); m.addFace([7u,22u,24u,17u]); m.addFace([3u,9u,24u,22u]);
    m.addFace([1u,11u,25u,19u]); m.addFace([2u,23u,25u,11u]); m.addFace([6u,15u,25u,23u]); m.addFace([5u,19u,25u,15u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(23)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.05f, 2);
    assert(m.faces.length == 58, "mixed K4fe w0.05 L2 (task 0456 owner): face count == reference");
    assert(m.vertices.length == 70, "mixed K4fe w0.05 L2 (task 0456 owner): vertex count matches reference (70)");
        immutable Vec3[] dumpVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.5f, -0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f),
            Vec3(0f, 0f, -0.5f), Vec3(-0.5f, 0f, -0.5f), Vec3(0f, 0.5f, -0.5f),
            Vec3(0.5f, 0f, -0.5f), Vec3(0f, -0.5f, -0.5f), Vec3(0f, 0f, 0.5f),
            Vec3(0f, -0.5f, 0.5f), Vec3(0.5f, 0f, 0.5f), Vec3(0f, 0.5f, 0.5f),
            Vec3(-0.5f, 0f, 0.5f), Vec3(0f, -0.5f, 0f), Vec3(0.5f, -0.5f, 0f),
            Vec3(-0.5f, -0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(-0.5f, 0.5f, 0f),
            Vec3(-0.5f, 0f, 0f), Vec3(0.5f, 0f, 0f), Vec3(0.449999988f, 0.5f, -0.5f),
            Vec3(0.5f, 0.449999988f, -0.5f), Vec3(0.5f, 0.449999988f, 0.5f), Vec3(0.449999988f, 0.5f, 0.5f),
            Vec3(-0.0500000007f, 0.5f, 0f), Vec3(0f, 0.5f, 0.0500000007f), Vec3(0f, 0.5f, -0.0500000007f),
            Vec3(0.5f, 0.449999988f, 0.0500000007f), Vec3(0.5f, 0.449999988f, -0.0500000007f), Vec3(0.449999988f, 0.5f, -0.0500000007f),
            Vec3(0.449999988f, 0.5f, 0.0500000007f), Vec3(0.5f, 0f, -0.0500000007f), Vec3(0.5f, 0f, 0.0500000007f),
            Vec3(0.5f, -0.0500000007f, 0f), Vec3(0.469134152f, 0.496193975f, 0.5f), Vec3(0.469134152f, 0.496193975f, 0.0500000007f),
            Vec3(0.485355347f, 0.485355347f, 0.5f), Vec3(0.485355347f, 0.485355347f, 0.0500000007f), Vec3(0.496193975f, 0.469134152f, 0.5f),
            Vec3(0.496193975f, 0.469134152f, 0.0500000007f), Vec3(0.449999988f, 0.5f, 0.0250000004f), Vec3(0f, 0.5f, 0.0250000004f),
            Vec3(0.449999988f, 0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(0.449999988f, 0.5f, -0.0250000004f),
            Vec3(0f, 0.5f, -0.0250000004f), Vec3(0.469134152f, 0.496193975f, -0.0500000007f), Vec3(0.469134152f, 0.496193975f, -0.5f),
            Vec3(0.485355347f, 0.485355347f, -0.0500000007f), Vec3(0.485355347f, 0.485355347f, -0.5f), Vec3(0.496193975f, 0.469134152f, -0.0500000007f),
            Vec3(0.496193975f, 0.469134152f, -0.5f), Vec3(0.5f, 0.449999988f, -0.0250000004f), Vec3(0.5f, 0f, -0.0250000004f),
            Vec3(0.5f, 0.449999988f, 0f), Vec3(0.5f, 0f, 0f), Vec3(0.5f, 0.449999988f, 0.0250000004f),
            Vec3(0.5f, 0f, 0.0250000004f), Vec3(0.485355347f, 0.485355347f, 0f), Vec3(0.485355347f, 0.485355347f, 0.0250000004f),
            Vec3(0.496204793f, 0.469328195f, 0.0250000004f), Vec3(0.496338844f, 0.469194174f, 0f), Vec3(0.496204793f, 0.469328195f, -0.0250000004f),
            Vec3(0.485355347f, 0.485355347f, -0.0250000004f), Vec3(0.469328195f, 0.496204793f, -0.0250000004f), Vec3(0.469194174f, 0.496338844f, 0f),
            Vec3(0.469328195f, 0.496204793f, 0.0250000004f),
        ];
    assertHubHausdorffWithin(m, dumpVerts, 1e-4f, "mixed K4fe w0.05 L2 (task 0456 owner)");
    assertBevelManifoldCleanOpen(m, "mixed K4fe w0.05 L2 (task 0456 owner)", 2);
}

unittest { // bevelEdgesByMask: "mixed K4 free-end" w0.05 L3
           // OWNER MESH (task 0456 live gate): once-subdivided cube, N=4 hub at an
           // interior cube-edge midpoint (2 of its 4 rays are FLAT internal split
           // edges, 2 are 90deg cube edges). Reference edge_bevel_mixed_k4fe_w0p05_L3
           // has 102v/86f; our FACE count matches exactly (86). Our vertex count
           // now MATCHES the reference: at each planar valence-4 full-hub free-end
           // cap (Round Level >= 1) the two reduced side faces stay anchored
           // at the RETAINED original free-end vertex (coincident with the
           // chamfer-strip pinch → a pinched cap quad), and the slide along
           // the OPPOSITE edge is kept as an intended orphan — reproducing the
           // reference cap topology derived purely from its measured dumps.
           // Every reference vertex position is reproduced within the
           // float32-mesh floor.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f),
        Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
        Vec3(0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(0f,0f,-0.5f),
        Vec3(-0.5f,0f,-0.5f), Vec3(0f,0.5f,-0.5f), Vec3(0.5f,0f,-0.5f),
        Vec3(0f,-0.5f,-0.5f), Vec3(0f,0f,0.5f), Vec3(0f,-0.5f,0.5f),
        Vec3(0.5f,0f,0.5f), Vec3(0f,0.5f,0.5f), Vec3(-0.5f,0f,0.5f),
        Vec3(0f,-0.5f,0f), Vec3(0.5f,-0.5f,0f), Vec3(-0.5f,-0.5f,0f),
        Vec3(0f,0.5f,0f), Vec3(-0.5f,0.5f,0f), Vec3(0.5f,0.5f,0f),
        Vec3(-0.5f,0f,0f), Vec3(0.5f,0f,0f),
    ];
    m.addFace([0u,9u,8u,12u]); m.addFace([3u,10u,8u,9u]); m.addFace([2u,11u,8u,10u]); m.addFace([1u,12u,8u,11u]);
    m.addFace([4u,14u,13u,17u]); m.addFace([5u,15u,13u,14u]); m.addFace([6u,16u,13u,15u]); m.addFace([7u,17u,13u,16u]);
    m.addFace([0u,12u,18u,20u]); m.addFace([1u,19u,18u,12u]); m.addFace([5u,14u,18u,19u]); m.addFace([4u,20u,18u,14u]);
    m.addFace([3u,22u,21u,10u]); m.addFace([7u,16u,21u,22u]); m.addFace([6u,23u,21u,16u]); m.addFace([2u,10u,21u,23u]);
    m.addFace([0u,20u,24u,9u]); m.addFace([4u,17u,24u,20u]); m.addFace([7u,22u,24u,17u]); m.addFace([3u,9u,24u,22u]);
    m.addFace([1u,11u,25u,19u]); m.addFace([2u,23u,25u,11u]); m.addFace([6u,15u,25u,23u]); m.addFace([5u,19u,25u,15u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(23)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.05f, 3);
    assert(m.faces.length == 86, "mixed K4fe w0.05 L3 (task 0456 owner): face count == reference");
    assert(m.vertices.length == 102, "mixed K4fe w0.05 L3 (task 0456 owner): vertex count matches reference (102)");
        immutable Vec3[] dumpVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.5f, -0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f),
            Vec3(0f, 0f, -0.5f), Vec3(-0.5f, 0f, -0.5f), Vec3(0f, 0.5f, -0.5f),
            Vec3(0.5f, 0f, -0.5f), Vec3(0f, -0.5f, -0.5f), Vec3(0f, 0f, 0.5f),
            Vec3(0f, -0.5f, 0.5f), Vec3(0.5f, 0f, 0.5f), Vec3(0f, 0.5f, 0.5f),
            Vec3(-0.5f, 0f, 0.5f), Vec3(0f, -0.5f, 0f), Vec3(0.5f, -0.5f, 0f),
            Vec3(-0.5f, -0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(-0.5f, 0.5f, 0f),
            Vec3(-0.5f, 0f, 0f), Vec3(0.5f, 0f, 0f), Vec3(0.449999988f, 0.5f, -0.5f),
            Vec3(0.5f, 0.449999988f, -0.5f), Vec3(0.5f, 0.449999988f, 0.5f), Vec3(0.449999988f, 0.5f, 0.5f),
            Vec3(-0.0500000007f, 0.5f, 0f), Vec3(0f, 0.5f, 0.0500000007f), Vec3(0f, 0.5f, -0.0500000007f),
            Vec3(0.5f, 0.449999988f, 0.0500000007f), Vec3(0.5f, 0.449999988f, -0.0500000007f), Vec3(0.449999988f, 0.5f, -0.0500000007f),
            Vec3(0.449999988f, 0.5f, 0.0500000007f), Vec3(0.5f, 0f, -0.0500000007f), Vec3(0.5f, 0f, 0.0500000007f),
            Vec3(0.5f, -0.0500000007f, 0f), Vec3(0.462940931f, 0.498296291f, 0.5f), Vec3(0.462940931f, 0.498296291f, 0.0500000007f),
            Vec3(0.474999994f, 0.493301272f, 0.5f), Vec3(0.474999994f, 0.493301272f, 0.0500000007f), Vec3(0.485355347f, 0.485355347f, 0.5f),
            Vec3(0.485355347f, 0.485355347f, 0.0500000007f), Vec3(0.493301272f, 0.474999994f, 0.5f), Vec3(0.493301272f, 0.474999994f, 0.0500000007f),
            Vec3(0.498296291f, 0.462940931f, 0.5f), Vec3(0.498296291f, 0.462940931f, 0.0500000007f), Vec3(0.449999988f, 0.5f, 0.0333333351f),
            Vec3(0f, 0.5f, 0.0333333351f), Vec3(0.449999988f, 0.5f, 0.0166666675f), Vec3(0f, 0.5f, 0.0166666675f),
            Vec3(0.449999988f, 0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(0.449999988f, 0.5f, -0.0166666675f),
            Vec3(0f, 0.5f, -0.0166666675f), Vec3(0.449999988f, 0.5f, -0.0333333351f), Vec3(0f, 0.5f, -0.0333333351f),
            Vec3(0.462940931f, 0.498296291f, -0.0500000007f), Vec3(0.462940931f, 0.498296291f, -0.5f), Vec3(0.474999994f, 0.493301272f, -0.0500000007f),
            Vec3(0.474999994f, 0.493301272f, -0.5f), Vec3(0.485355347f, 0.485355347f, -0.0500000007f), Vec3(0.485355347f, 0.485355347f, -0.5f),
            Vec3(0.493301272f, 0.474999994f, -0.0500000007f), Vec3(0.493301272f, 0.474999994f, -0.5f), Vec3(0.498296291f, 0.462940931f, -0.0500000007f),
            Vec3(0.498296291f, 0.462940931f, -0.5f), Vec3(0.5f, 0.449999988f, -0.0333333351f), Vec3(0.5f, 0f, -0.0333333351f),
            Vec3(0.5f, 0.449999988f, -0.0166666675f), Vec3(0.5f, 0f, -0.0166666675f), Vec3(0.5f, 0.449999988f, 0f),
            Vec3(0.5f, 0f, 0f), Vec3(0.5f, 0.449999988f, 0.0166666675f), Vec3(0.5f, 0f, 0.0166666675f),
            Vec3(0.5f, 0.449999988f, 0.0333333351f), Vec3(0.5f, 0f, 0.0333333351f), Vec3(0.485355347f, 0.485355347f, 0f),
            Vec3(0.485355347f, 0.485355347f, 0.0333333351f), Vec3(0.498257101f, 0.463248819f, 0.0333333351f), Vec3(0.493263751f, 0.475145727f, 0.0333333351f),
            Vec3(0.485355347f, 0.485355347f, 0.0166666675f), Vec3(0.498329669f, 0.46317625f, 0.0166666675f), Vec3(0.493401051f, 0.475008428f, 0.0166666675f),
            Vec3(0.498372823f, 0.463133097f, 0f), Vec3(0.493491262f, 0.474918216f, 0f), Vec3(0.498257101f, 0.463248819f, -0.0333333351f),
            Vec3(0.498329669f, 0.46317625f, -0.0166666675f), Vec3(0.493263751f, 0.475145727f, -0.0333333351f), Vec3(0.493401051f, 0.475008428f, -0.0166666675f),
            Vec3(0.485355347f, 0.485355347f, -0.0333333351f), Vec3(0.485355347f, 0.485355347f, -0.0166666675f), Vec3(0.463248819f, 0.498257101f, -0.0333333351f),
            Vec3(0.475145727f, 0.493263751f, -0.0333333351f), Vec3(0.46317625f, 0.498329669f, -0.0166666675f), Vec3(0.475008428f, 0.493401051f, -0.0166666675f),
            Vec3(0.463133097f, 0.498372823f, 0f), Vec3(0.474918216f, 0.493491262f, 0f), Vec3(0.463248819f, 0.498257101f, 0.0333333351f),
            Vec3(0.46317625f, 0.498329669f, 0.0166666675f), Vec3(0.475145727f, 0.493263751f, 0.0333333351f), Vec3(0.475008428f, 0.493401051f, 0.0166666675f),
        ];
    assertHubHausdorffWithin(m, dumpVerts, 1e-4f, "mixed K4fe w0.05 L3 (task 0456 owner)");
    assertBevelManifoldCleanOpen(m, "mixed K4fe w0.05 L3 (task 0456 owner)", 2);
}

unittest { // bevelEdgesByMask: "mixed K4 free-end" w0.10 L1
           // OWNER MESH (task 0456 live gate): once-subdivided cube, N=4 hub at an
           // interior cube-edge midpoint (2 of its 4 rays are FLAT internal split
           // edges, 2 are 90deg cube edges). Reference edge_bevel_mixed_k4fe_w0p10_L1
           // has 46v/38f; our FACE count matches exactly (38). Our vertex count
           // now MATCHES the reference: at each planar valence-4 full-hub free-end
           // cap (Round Level >= 1) the two reduced side faces stay anchored
           // at the RETAINED original free-end vertex (coincident with the
           // chamfer-strip pinch → a pinched cap quad), and the slide along
           // the OPPOSITE edge is kept as an intended orphan — reproducing the
           // reference cap topology derived purely from its measured dumps.
           // Every reference vertex position is reproduced within the
           // float32-mesh floor.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f),
        Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
        Vec3(0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(0f,0f,-0.5f),
        Vec3(-0.5f,0f,-0.5f), Vec3(0f,0.5f,-0.5f), Vec3(0.5f,0f,-0.5f),
        Vec3(0f,-0.5f,-0.5f), Vec3(0f,0f,0.5f), Vec3(0f,-0.5f,0.5f),
        Vec3(0.5f,0f,0.5f), Vec3(0f,0.5f,0.5f), Vec3(-0.5f,0f,0.5f),
        Vec3(0f,-0.5f,0f), Vec3(0.5f,-0.5f,0f), Vec3(-0.5f,-0.5f,0f),
        Vec3(0f,0.5f,0f), Vec3(-0.5f,0.5f,0f), Vec3(0.5f,0.5f,0f),
        Vec3(-0.5f,0f,0f), Vec3(0.5f,0f,0f),
    ];
    m.addFace([0u,9u,8u,12u]); m.addFace([3u,10u,8u,9u]); m.addFace([2u,11u,8u,10u]); m.addFace([1u,12u,8u,11u]);
    m.addFace([4u,14u,13u,17u]); m.addFace([5u,15u,13u,14u]); m.addFace([6u,16u,13u,15u]); m.addFace([7u,17u,13u,16u]);
    m.addFace([0u,12u,18u,20u]); m.addFace([1u,19u,18u,12u]); m.addFace([5u,14u,18u,19u]); m.addFace([4u,20u,18u,14u]);
    m.addFace([3u,22u,21u,10u]); m.addFace([7u,16u,21u,22u]); m.addFace([6u,23u,21u,16u]); m.addFace([2u,10u,21u,23u]);
    m.addFace([0u,20u,24u,9u]); m.addFace([4u,17u,24u,20u]); m.addFace([7u,22u,24u,17u]); m.addFace([3u,9u,24u,22u]);
    m.addFace([1u,11u,25u,19u]); m.addFace([2u,23u,25u,11u]); m.addFace([6u,15u,25u,23u]); m.addFace([5u,19u,25u,15u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(23)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.10f, 1);
    assert(m.faces.length == 38, "mixed K4fe w0.10 L1 (task 0456 owner): face count == reference");
    assert(m.vertices.length == 46, "mixed K4fe w0.10 L1 (task 0456 owner): vertex count matches reference (46)");
        immutable Vec3[] dumpVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.5f, -0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f),
            Vec3(0f, 0f, -0.5f), Vec3(-0.5f, 0f, -0.5f), Vec3(0f, 0.5f, -0.5f),
            Vec3(0.5f, 0f, -0.5f), Vec3(0f, -0.5f, -0.5f), Vec3(0f, 0f, 0.5f),
            Vec3(0f, -0.5f, 0.5f), Vec3(0.5f, 0f, 0.5f), Vec3(0f, 0.5f, 0.5f),
            Vec3(-0.5f, 0f, 0.5f), Vec3(0f, -0.5f, 0f), Vec3(0.5f, -0.5f, 0f),
            Vec3(-0.5f, -0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(-0.5f, 0.5f, 0f),
            Vec3(-0.5f, 0f, 0f), Vec3(0.5f, 0f, 0f), Vec3(0.400000006f, 0.5f, -0.5f),
            Vec3(0.5f, 0.400000006f, -0.5f), Vec3(0.5f, 0.400000006f, 0.5f), Vec3(0.400000006f, 0.5f, 0.5f),
            Vec3(-0.100000001f, 0.5f, 0f), Vec3(0f, 0.5f, 0.100000001f), Vec3(0f, 0.5f, -0.100000001f),
            Vec3(0.5f, 0.400000006f, 0.100000001f), Vec3(0.5f, 0.400000006f, -0.100000001f), Vec3(0.400000006f, 0.5f, -0.100000001f),
            Vec3(0.400000006f, 0.5f, 0.100000001f), Vec3(0.5f, 0f, -0.100000001f), Vec3(0.5f, 0f, 0.100000001f),
            Vec3(0.5f, -0.100000001f, 0f), Vec3(0.470710695f, 0.470710695f, 0.5f), Vec3(0.470710695f, 0.470710695f, 0.100000001f),
            Vec3(0.400000006f, 0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(0.470710695f, 0.470710695f, -0.100000001f),
            Vec3(0.470710695f, 0.470710695f, -0.5f), Vec3(0.5f, 0.400000006f, 0f), Vec3(0.5f, 0f, 0f),
            Vec3(0.470710665f, 0.470710665f, 0f),
        ];
    assertHubHausdorffWithin(m, dumpVerts, 1e-4f, "mixed K4fe w0.10 L1 (task 0456 owner)");
    assertBevelManifoldCleanOpen(m, "mixed K4fe w0.10 L1 (task 0456 owner)", 2);
}

unittest { // bevelEdgesByMask: "mixed K4 free-end" w0.10 L2
           // OWNER MESH (task 0456 live gate): once-subdivided cube, N=4 hub at an
           // interior cube-edge midpoint (2 of its 4 rays are FLAT internal split
           // edges, 2 are 90deg cube edges). Reference edge_bevel_mixed_k4fe_w0p10_L2
           // has 70v/58f; our FACE count matches exactly (58). Our vertex count
           // now MATCHES the reference: at each planar valence-4 full-hub free-end
           // cap (Round Level >= 1) the two reduced side faces stay anchored
           // at the RETAINED original free-end vertex (coincident with the
           // chamfer-strip pinch → a pinched cap quad), and the slide along
           // the OPPOSITE edge is kept as an intended orphan — reproducing the
           // reference cap topology derived purely from its measured dumps.
           // Every reference vertex position is reproduced within the
           // float32-mesh floor.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f),
        Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
        Vec3(0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(0f,0f,-0.5f),
        Vec3(-0.5f,0f,-0.5f), Vec3(0f,0.5f,-0.5f), Vec3(0.5f,0f,-0.5f),
        Vec3(0f,-0.5f,-0.5f), Vec3(0f,0f,0.5f), Vec3(0f,-0.5f,0.5f),
        Vec3(0.5f,0f,0.5f), Vec3(0f,0.5f,0.5f), Vec3(-0.5f,0f,0.5f),
        Vec3(0f,-0.5f,0f), Vec3(0.5f,-0.5f,0f), Vec3(-0.5f,-0.5f,0f),
        Vec3(0f,0.5f,0f), Vec3(-0.5f,0.5f,0f), Vec3(0.5f,0.5f,0f),
        Vec3(-0.5f,0f,0f), Vec3(0.5f,0f,0f),
    ];
    m.addFace([0u,9u,8u,12u]); m.addFace([3u,10u,8u,9u]); m.addFace([2u,11u,8u,10u]); m.addFace([1u,12u,8u,11u]);
    m.addFace([4u,14u,13u,17u]); m.addFace([5u,15u,13u,14u]); m.addFace([6u,16u,13u,15u]); m.addFace([7u,17u,13u,16u]);
    m.addFace([0u,12u,18u,20u]); m.addFace([1u,19u,18u,12u]); m.addFace([5u,14u,18u,19u]); m.addFace([4u,20u,18u,14u]);
    m.addFace([3u,22u,21u,10u]); m.addFace([7u,16u,21u,22u]); m.addFace([6u,23u,21u,16u]); m.addFace([2u,10u,21u,23u]);
    m.addFace([0u,20u,24u,9u]); m.addFace([4u,17u,24u,20u]); m.addFace([7u,22u,24u,17u]); m.addFace([3u,9u,24u,22u]);
    m.addFace([1u,11u,25u,19u]); m.addFace([2u,23u,25u,11u]); m.addFace([6u,15u,25u,23u]); m.addFace([5u,19u,25u,15u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(23)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.10f, 2);
    assert(m.faces.length == 58, "mixed K4fe w0.10 L2 (task 0456 owner): face count == reference");
    assert(m.vertices.length == 70, "mixed K4fe w0.10 L2 (task 0456 owner): vertex count matches reference (70)");
        immutable Vec3[] dumpVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.5f, -0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f),
            Vec3(0f, 0f, -0.5f), Vec3(-0.5f, 0f, -0.5f), Vec3(0f, 0.5f, -0.5f),
            Vec3(0.5f, 0f, -0.5f), Vec3(0f, -0.5f, -0.5f), Vec3(0f, 0f, 0.5f),
            Vec3(0f, -0.5f, 0.5f), Vec3(0.5f, 0f, 0.5f), Vec3(0f, 0.5f, 0.5f),
            Vec3(-0.5f, 0f, 0.5f), Vec3(0f, -0.5f, 0f), Vec3(0.5f, -0.5f, 0f),
            Vec3(-0.5f, -0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(-0.5f, 0.5f, 0f),
            Vec3(-0.5f, 0f, 0f), Vec3(0.5f, 0f, 0f), Vec3(0.400000006f, 0.5f, -0.5f),
            Vec3(0.5f, 0.400000006f, -0.5f), Vec3(0.5f, 0.400000006f, 0.5f), Vec3(0.400000006f, 0.5f, 0.5f),
            Vec3(-0.100000001f, 0.5f, 0f), Vec3(0f, 0.5f, 0.100000001f), Vec3(0f, 0.5f, -0.100000001f),
            Vec3(0.5f, 0.400000006f, 0.100000001f), Vec3(0.5f, 0.400000006f, -0.100000001f), Vec3(0.400000006f, 0.5f, -0.100000001f),
            Vec3(0.400000006f, 0.5f, 0.100000001f), Vec3(0.5f, 0f, -0.100000001f), Vec3(0.5f, 0f, 0.100000001f),
            Vec3(0.5f, -0.100000001f, 0f), Vec3(0.438268334f, 0.49238795f, 0.5f), Vec3(0.438268334f, 0.49238795f, 0.100000001f),
            Vec3(0.470710695f, 0.470710695f, 0.5f), Vec3(0.470710695f, 0.470710695f, 0.100000001f), Vec3(0.49238795f, 0.438268334f, 0.5f),
            Vec3(0.49238795f, 0.438268334f, 0.100000001f), Vec3(0.400000006f, 0.5f, 0.0500000007f), Vec3(0f, 0.5f, 0.0500000007f),
            Vec3(0.400000006f, 0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(0.400000006f, 0.5f, -0.0500000007f),
            Vec3(0f, 0.5f, -0.0500000007f), Vec3(0.438268334f, 0.49238795f, -0.100000001f), Vec3(0.438268334f, 0.49238795f, -0.5f),
            Vec3(0.470710695f, 0.470710695f, -0.100000001f), Vec3(0.470710695f, 0.470710695f, -0.5f), Vec3(0.49238795f, 0.438268334f, -0.100000001f),
            Vec3(0.49238795f, 0.438268334f, -0.5f), Vec3(0.5f, 0.400000006f, -0.0500000007f), Vec3(0.5f, 0f, -0.0500000007f),
            Vec3(0.5f, 0.400000006f, 0f), Vec3(0.5f, 0f, 0f), Vec3(0.5f, 0.400000006f, 0.0500000007f),
            Vec3(0.5f, 0f, 0.0500000007f), Vec3(0.470710665f, 0.470710665f, 0f), Vec3(0.470710665f, 0.470710665f, 0.0500000007f),
            Vec3(0.492409587f, 0.43865642f, 0.0500000007f), Vec3(0.492677659f, 0.438388348f, 0f), Vec3(0.492409587f, 0.43865642f, -0.0500000007f),
            Vec3(0.470710665f, 0.470710665f, -0.0500000007f), Vec3(0.43865642f, 0.492409587f, -0.0500000007f), Vec3(0.438388348f, 0.492677659f, 0f),
            Vec3(0.43865642f, 0.492409587f, 0.0500000007f),
        ];
    assertHubHausdorffWithin(m, dumpVerts, 1e-4f, "mixed K4fe w0.10 L2 (task 0456 owner)");
    assertBevelManifoldCleanOpen(m, "mixed K4fe w0.10 L2 (task 0456 owner)", 2);
}

unittest { // bevelEdgesByMask: "mixed K4 free-end" w0.10 L3
           // OWNER MESH (task 0456 live gate): once-subdivided cube, N=4 hub at an
           // interior cube-edge midpoint (2 of its 4 rays are FLAT internal split
           // edges, 2 are 90deg cube edges). Reference edge_bevel_mixed_k4fe_w0p10_L3
           // has 102v/86f; our FACE count matches exactly (86). Our vertex count
           // now MATCHES the reference: at each planar valence-4 full-hub free-end
           // cap (Round Level >= 1) the two reduced side faces stay anchored
           // at the RETAINED original free-end vertex (coincident with the
           // chamfer-strip pinch → a pinched cap quad), and the slide along
           // the OPPOSITE edge is kept as an intended orphan — reproducing the
           // reference cap topology derived purely from its measured dumps.
           // Every reference vertex position is reproduced within the
           // float32-mesh floor.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f),
        Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
        Vec3(0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(0f,0f,-0.5f),
        Vec3(-0.5f,0f,-0.5f), Vec3(0f,0.5f,-0.5f), Vec3(0.5f,0f,-0.5f),
        Vec3(0f,-0.5f,-0.5f), Vec3(0f,0f,0.5f), Vec3(0f,-0.5f,0.5f),
        Vec3(0.5f,0f,0.5f), Vec3(0f,0.5f,0.5f), Vec3(-0.5f,0f,0.5f),
        Vec3(0f,-0.5f,0f), Vec3(0.5f,-0.5f,0f), Vec3(-0.5f,-0.5f,0f),
        Vec3(0f,0.5f,0f), Vec3(-0.5f,0.5f,0f), Vec3(0.5f,0.5f,0f),
        Vec3(-0.5f,0f,0f), Vec3(0.5f,0f,0f),
    ];
    m.addFace([0u,9u,8u,12u]); m.addFace([3u,10u,8u,9u]); m.addFace([2u,11u,8u,10u]); m.addFace([1u,12u,8u,11u]);
    m.addFace([4u,14u,13u,17u]); m.addFace([5u,15u,13u,14u]); m.addFace([6u,16u,13u,15u]); m.addFace([7u,17u,13u,16u]);
    m.addFace([0u,12u,18u,20u]); m.addFace([1u,19u,18u,12u]); m.addFace([5u,14u,18u,19u]); m.addFace([4u,20u,18u,14u]);
    m.addFace([3u,22u,21u,10u]); m.addFace([7u,16u,21u,22u]); m.addFace([6u,23u,21u,16u]); m.addFace([2u,10u,21u,23u]);
    m.addFace([0u,20u,24u,9u]); m.addFace([4u,17u,24u,20u]); m.addFace([7u,22u,24u,17u]); m.addFace([3u,9u,24u,22u]);
    m.addFace([1u,11u,25u,19u]); m.addFace([2u,23u,25u,11u]); m.addFace([6u,15u,25u,23u]); m.addFace([5u,19u,25u,15u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(23)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.10f, 3);
    assert(m.faces.length == 86, "mixed K4fe w0.10 L3 (task 0456 owner): face count == reference");
    assert(m.vertices.length == 102, "mixed K4fe w0.10 L3 (task 0456 owner): vertex count matches reference (102)");
        immutable Vec3[] dumpVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.5f, -0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f),
            Vec3(0f, 0f, -0.5f), Vec3(-0.5f, 0f, -0.5f), Vec3(0f, 0.5f, -0.5f),
            Vec3(0.5f, 0f, -0.5f), Vec3(0f, -0.5f, -0.5f), Vec3(0f, 0f, 0.5f),
            Vec3(0f, -0.5f, 0.5f), Vec3(0.5f, 0f, 0.5f), Vec3(0f, 0.5f, 0.5f),
            Vec3(-0.5f, 0f, 0.5f), Vec3(0f, -0.5f, 0f), Vec3(0.5f, -0.5f, 0f),
            Vec3(-0.5f, -0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(-0.5f, 0.5f, 0f),
            Vec3(-0.5f, 0f, 0f), Vec3(0.5f, 0f, 0f), Vec3(0.400000006f, 0.5f, -0.5f),
            Vec3(0.5f, 0.400000006f, -0.5f), Vec3(0.5f, 0.400000006f, 0.5f), Vec3(0.400000006f, 0.5f, 0.5f),
            Vec3(-0.100000001f, 0.5f, 0f), Vec3(0f, 0.5f, 0.100000001f), Vec3(0f, 0.5f, -0.100000001f),
            Vec3(0.5f, 0.400000006f, 0.100000001f), Vec3(0.5f, 0.400000006f, -0.100000001f), Vec3(0.400000006f, 0.5f, -0.100000001f),
            Vec3(0.400000006f, 0.5f, 0.100000001f), Vec3(0.5f, 0f, -0.100000001f), Vec3(0.5f, 0f, 0.100000001f),
            Vec3(0.5f, -0.100000001f, 0f), Vec3(0.425881922f, 0.496592581f, 0.5f), Vec3(0.425881922f, 0.496592581f, 0.100000001f),
            Vec3(0.450000018f, 0.486602545f, 0.5f), Vec3(0.450000018f, 0.486602545f, 0.100000001f), Vec3(0.470710695f, 0.470710695f, 0.5f),
            Vec3(0.470710695f, 0.470710695f, 0.100000001f), Vec3(0.486602545f, 0.450000018f, 0.5f), Vec3(0.486602545f, 0.450000018f, 0.100000001f),
            Vec3(0.496592581f, 0.425881922f, 0.5f), Vec3(0.496592581f, 0.425881922f, 0.100000001f), Vec3(0.400000006f, 0.5f, 0.0666666701f),
            Vec3(0f, 0.5f, 0.0666666701f), Vec3(0.400000006f, 0.5f, 0.0333333351f), Vec3(0f, 0.5f, 0.0333333351f),
            Vec3(0.400000006f, 0.5f, 0f), Vec3(0f, 0.5f, 0f), Vec3(0.400000006f, 0.5f, -0.0333333351f),
            Vec3(0f, 0.5f, -0.0333333351f), Vec3(0.400000006f, 0.5f, -0.0666666701f), Vec3(0f, 0.5f, -0.0666666701f),
            Vec3(0.425881922f, 0.496592581f, -0.100000001f), Vec3(0.425881922f, 0.496592581f, -0.5f), Vec3(0.450000018f, 0.486602545f, -0.100000001f),
            Vec3(0.450000018f, 0.486602545f, -0.5f), Vec3(0.470710695f, 0.470710695f, -0.100000001f), Vec3(0.470710695f, 0.470710695f, -0.5f),
            Vec3(0.486602545f, 0.450000018f, -0.100000001f), Vec3(0.486602545f, 0.450000018f, -0.5f), Vec3(0.496592581f, 0.425881922f, -0.100000001f),
            Vec3(0.496592581f, 0.425881922f, -0.5f), Vec3(0.5f, 0.400000006f, -0.0666666701f), Vec3(0.5f, 0f, -0.0666666701f),
            Vec3(0.5f, 0.400000006f, -0.0333333351f), Vec3(0.5f, 0f, -0.0333333351f), Vec3(0.5f, 0.400000006f, 0f),
            Vec3(0.5f, 0f, 0f), Vec3(0.5f, 0.400000006f, 0.0333333351f), Vec3(0.5f, 0f, 0.0333333351f),
            Vec3(0.5f, 0.400000006f, 0.0666666701f), Vec3(0.5f, 0f, 0.0666666701f), Vec3(0.470710665f, 0.470710665f, 0f),
            Vec3(0.470710665f, 0.470710665f, 0.0666666701f), Vec3(0.496514201f, 0.426497668f, 0.0666666701f), Vec3(0.486527503f, 0.450291485f, 0.0666666701f),
            Vec3(0.470710665f, 0.470710665f, 0.0333333351f), Vec3(0.496659338f, 0.426352531f, 0.0333333351f), Vec3(0.486802101f, 0.450016886f, 0.0333333351f),
            Vec3(0.496745616f, 0.426266223f, 0f), Vec3(0.486982524f, 0.449836463f, 0f), Vec3(0.496514201f, 0.426497668f, -0.0666666701f),
            Vec3(0.496659338f, 0.426352531f, -0.0333333351f), Vec3(0.486527503f, 0.450291485f, -0.0666666701f), Vec3(0.486802101f, 0.450016886f, -0.0333333351f),
            Vec3(0.470710665f, 0.470710665f, -0.0666666701f), Vec3(0.470710665f, 0.470710665f, -0.0333333351f), Vec3(0.426497668f, 0.496514201f, -0.0666666701f),
            Vec3(0.450291485f, 0.486527503f, -0.0666666701f), Vec3(0.426352531f, 0.496659338f, -0.0333333351f), Vec3(0.450016886f, 0.486802101f, -0.0333333351f),
            Vec3(0.426266223f, 0.496745616f, 0f), Vec3(0.449836463f, 0.486982524f, 0f), Vec3(0.426497668f, 0.496514201f, 0.0666666701f),
            Vec3(0.426352531f, 0.496659338f, 0.0333333351f), Vec3(0.450291485f, 0.486527503f, 0.0666666701f), Vec3(0.450016886f, 0.486802101f, 0.0333333351f),
        ];
    assertHubHausdorffWithin(m, dumpVerts, 2e-4f, "mixed K4fe w0.10 L3 (task 0456 owner)");
    assertBevelManifoldCleanOpen(m, "mixed K4fe w0.10 L3 (task 0456 owner)", 2);
}

unittest { // bevelEdgesByMask: "mixed K4 free-end" w0.05 L0
           // OWNER MESH (task 0456 flat-cap freeze): once-subdivided cube, N=4 hub
           // at an interior cube-edge midpoint, Round Level 0 (flat chamfer, no
           // rounding). Transcribed FROM the reference capture dump
           // edge_bevel_mixed_k4fe_w0p05_L0 — NOT our kernel's output. L0 has no
           // free-end duplicate quirk (35v/31f, 0 coincident); a clean parity
           // freeze of the N-way flat-cap topology the rounding builds on.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f),
        Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
        Vec3(0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(0f,0f,-0.5f),
        Vec3(-0.5f,0f,-0.5f), Vec3(0f,0.5f,-0.5f), Vec3(0.5f,0f,-0.5f),
        Vec3(0f,-0.5f,-0.5f), Vec3(0f,0f,0.5f), Vec3(0f,-0.5f,0.5f),
        Vec3(0.5f,0f,0.5f), Vec3(0f,0.5f,0.5f), Vec3(-0.5f,0f,0.5f),
        Vec3(0f,-0.5f,0f), Vec3(0.5f,-0.5f,0f), Vec3(-0.5f,-0.5f,0f),
        Vec3(0f,0.5f,0f), Vec3(-0.5f,0.5f,0f), Vec3(0.5f,0.5f,0f),
        Vec3(-0.5f,0f,0f), Vec3(0.5f,0f,0f),
    ];
    m.addFace([0u,9u,8u,12u]); m.addFace([3u,10u,8u,9u]); m.addFace([2u,11u,8u,10u]); m.addFace([1u,12u,8u,11u]);
    m.addFace([4u,14u,13u,17u]); m.addFace([5u,15u,13u,14u]); m.addFace([6u,16u,13u,15u]); m.addFace([7u,17u,13u,16u]);
    m.addFace([0u,12u,18u,20u]); m.addFace([1u,19u,18u,12u]); m.addFace([5u,14u,18u,19u]); m.addFace([4u,20u,18u,14u]);
    m.addFace([3u,22u,21u,10u]); m.addFace([7u,16u,21u,22u]); m.addFace([6u,23u,21u,16u]); m.addFace([2u,10u,21u,23u]);
    m.addFace([0u,20u,24u,9u]); m.addFace([4u,17u,24u,20u]); m.addFace([7u,22u,24u,17u]); m.addFace([3u,9u,24u,22u]);
    m.addFace([1u,11u,25u,19u]); m.addFace([2u,23u,25u,11u]); m.addFace([6u,15u,25u,23u]); m.addFace([5u,19u,25u,15u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(23)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.05f, 0);
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.5f, -0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f),
            Vec3(0.0f, 0.0f, -0.5f), Vec3(-0.5f, 0.0f, -0.5f), Vec3(0.0f, 0.5f, -0.5f),
            Vec3(0.5f, 0.0f, -0.5f), Vec3(0.0f, -0.5f, -0.5f), Vec3(0.0f, 0.0f, 0.5f),
            Vec3(0.0f, -0.5f, 0.5f), Vec3(0.5f, 0.0f, 0.5f), Vec3(0.0f, 0.5f, 0.5f),
            Vec3(-0.5f, 0.0f, 0.5f), Vec3(0.0f, -0.5f, 0.0f), Vec3(0.5f, -0.5f, 0.0f),
            Vec3(-0.5f, -0.5f, 0.0f), Vec3(-0.5f, 0.5f, 0.0f), Vec3(-0.5f, 0.0f, 0.0f),
            Vec3(0.44999998807907104f, 0.5f, -0.5f), Vec3(0.5f, 0.44999998807907104f, -0.5f), Vec3(0.5f, 0.44999998807907104f, 0.5f),
            Vec3(0.44999998807907104f, 0.5f, 0.5f), Vec3(-0.05000000074505806f, 0.5f, 0.0f), Vec3(0.0f, 0.5f, 0.05000000074505806f),
            Vec3(0.0f, 0.5f, -0.05000000074505806f), Vec3(0.5f, 0.44999998807907104f, 0.05000000074505806f), Vec3(0.5f, 0.44999998807907104f, -0.05000000074505806f),
            Vec3(0.44999998807907104f, 0.5f, -0.05000000074505806f), Vec3(0.44999998807907104f, 0.5f, 0.05000000074505806f), Vec3(0.5f, 0.0f, -0.05000000074505806f),
            Vec3(0.5f, 0.0f, 0.05000000074505806f), Vec3(0.5f, -0.05000000074505806f, 0.0f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 7u, 6u, 10u], [2u, 8u, 6u, 7u], [17u, 34u, 33u, 13u, 4u],
            [1u, 10u, 6u, 9u], [3u, 12u, 11u, 15u], [4u, 13u, 11u, 12u],
            [13u, 33u, 28u, 23u], [5u, 15u, 11u, 14u], [0u, 10u, 16u, 18u],
            [1u, 17u, 16u, 10u], [4u, 12u, 16u, 17u], [3u, 18u, 16u, 12u],
            [29u, 32u, 9u, 22u], [9u, 32u, 34u, 17u, 1u], [8u, 27u, 30u, 21u],
            [31u, 26u, 14u, 24u], [0u, 18u, 20u, 7u], [3u, 15u, 20u, 18u],
            [5u, 19u, 20u, 15u], [2u, 7u, 20u, 19u], [14u, 26u, 25u, 19u, 5u],
            [19u, 25u, 27u, 8u, 2u], [24u, 14u, 11u, 13u, 23u], [22u, 9u, 6u, 8u, 21u],
            [31u, 24u, 23u, 28u], [26u, 31u, 30u, 27u], [21u, 30u, 29u, 22u],
            [32u, 29u, 28u, 33u], [25u, 26u, 27u], [28u, 29u, 30u, 31u],
            [32u, 33u, 34u],
        ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "mixed K4fe w0.05 L0 (task 0456 flat-cap freeze)");
    assertBevelManifoldCleanOpen(m, "mixed K4fe w0.05 L0 (task 0456 flat-cap freeze)", 2);
}

unittest { // bevelEdgesByMask: "mixed K4 free-end" w0.10 L0
           // OWNER MESH (task 0456 flat-cap freeze): as w0.05 L0 but width 0.10.
           // Transcribed FROM the reference capture dump edge_bevel_mixed_k4fe_w0p10_L0
           // — NOT our kernel's output. 35v/31f, 0 coincident.
    Mesh m;
    m.vertices = [
        Vec3(-0.5f,-0.5f,-0.5f), Vec3(0.5f,-0.5f,-0.5f), Vec3(0.5f,0.5f,-0.5f),
        Vec3(-0.5f,0.5f,-0.5f), Vec3(-0.5f,-0.5f,0.5f), Vec3(0.5f,-0.5f,0.5f),
        Vec3(0.5f,0.5f,0.5f), Vec3(-0.5f,0.5f,0.5f), Vec3(0f,0f,-0.5f),
        Vec3(-0.5f,0f,-0.5f), Vec3(0f,0.5f,-0.5f), Vec3(0.5f,0f,-0.5f),
        Vec3(0f,-0.5f,-0.5f), Vec3(0f,0f,0.5f), Vec3(0f,-0.5f,0.5f),
        Vec3(0.5f,0f,0.5f), Vec3(0f,0.5f,0.5f), Vec3(-0.5f,0f,0.5f),
        Vec3(0f,-0.5f,0f), Vec3(0.5f,-0.5f,0f), Vec3(-0.5f,-0.5f,0f),
        Vec3(0f,0.5f,0f), Vec3(-0.5f,0.5f,0f), Vec3(0.5f,0.5f,0f),
        Vec3(-0.5f,0f,0f), Vec3(0.5f,0f,0f),
    ];
    m.addFace([0u,9u,8u,12u]); m.addFace([3u,10u,8u,9u]); m.addFace([2u,11u,8u,10u]); m.addFace([1u,12u,8u,11u]);
    m.addFace([4u,14u,13u,17u]); m.addFace([5u,15u,13u,14u]); m.addFace([6u,16u,13u,15u]); m.addFace([7u,17u,13u,16u]);
    m.addFace([0u,12u,18u,20u]); m.addFace([1u,19u,18u,12u]); m.addFace([5u,14u,18u,19u]); m.addFace([4u,20u,18u,14u]);
    m.addFace([3u,22u,21u,10u]); m.addFace([7u,16u,21u,22u]); m.addFace([6u,23u,21u,16u]); m.addFace([2u,10u,21u,23u]);
    m.addFace([0u,20u,24u,9u]); m.addFace([4u,17u,24u,20u]); m.addFace([7u,22u,24u,17u]); m.addFace([3u,9u,24u,22u]);
    m.addFace([1u,11u,25u,19u]); m.addFace([2u,23u,25u,11u]); m.addFace([6u,15u,25u,23u]); m.addFace([5u,19u,25u,15u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(23)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.10f, 0);
        immutable Vec3[] wantVerts = [
            Vec3(-0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.5f, -0.5f),
            Vec3(-0.5f, -0.5f, 0.5f), Vec3(0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f),
            Vec3(0.0f, 0.0f, -0.5f), Vec3(-0.5f, 0.0f, -0.5f), Vec3(0.0f, 0.5f, -0.5f),
            Vec3(0.5f, 0.0f, -0.5f), Vec3(0.0f, -0.5f, -0.5f), Vec3(0.0f, 0.0f, 0.5f),
            Vec3(0.0f, -0.5f, 0.5f), Vec3(0.5f, 0.0f, 0.5f), Vec3(0.0f, 0.5f, 0.5f),
            Vec3(-0.5f, 0.0f, 0.5f), Vec3(0.0f, -0.5f, 0.0f), Vec3(0.5f, -0.5f, 0.0f),
            Vec3(-0.5f, -0.5f, 0.0f), Vec3(-0.5f, 0.5f, 0.0f), Vec3(-0.5f, 0.0f, 0.0f),
            Vec3(0.4000000059604645f, 0.5f, -0.5f), Vec3(0.5f, 0.4000000059604645f, -0.5f), Vec3(0.5f, 0.4000000059604645f, 0.5f),
            Vec3(0.4000000059604645f, 0.5f, 0.5f), Vec3(-0.10000000149011612f, 0.5f, 0.0f), Vec3(0.0f, 0.5f, 0.10000000149011612f),
            Vec3(0.0f, 0.5f, -0.10000000149011612f), Vec3(0.5f, 0.4000000059604645f, 0.10000000149011612f), Vec3(0.5f, 0.4000000059604645f, -0.10000000149011612f),
            Vec3(0.4000000059604645f, 0.5f, -0.10000000149011612f), Vec3(0.4000000059604645f, 0.5f, 0.10000000149011612f), Vec3(0.5f, 0.0f, -0.10000000149011612f),
            Vec3(0.5f, 0.0f, 0.10000000149011612f), Vec3(0.5f, -0.10000000149011612f, 0.0f),
        ];
        static immutable uint[][] wantFaces = [
            [0u, 7u, 6u, 10u], [2u, 8u, 6u, 7u], [17u, 34u, 33u, 13u, 4u],
            [1u, 10u, 6u, 9u], [3u, 12u, 11u, 15u], [4u, 13u, 11u, 12u],
            [13u, 33u, 28u, 23u], [5u, 15u, 11u, 14u], [0u, 10u, 16u, 18u],
            [1u, 17u, 16u, 10u], [4u, 12u, 16u, 17u], [3u, 18u, 16u, 12u],
            [29u, 32u, 9u, 22u], [9u, 32u, 34u, 17u, 1u], [8u, 27u, 30u, 21u],
            [31u, 26u, 14u, 24u], [0u, 18u, 20u, 7u], [3u, 15u, 20u, 18u],
            [5u, 19u, 20u, 15u], [2u, 7u, 20u, 19u], [14u, 26u, 25u, 19u, 5u],
            [19u, 25u, 27u, 8u, 2u], [24u, 14u, 11u, 13u, 23u], [22u, 9u, 6u, 8u, 21u],
            [31u, 24u, 23u, 28u], [26u, 31u, 30u, 27u], [21u, 30u, 29u, 22u],
            [32u, 29u, 28u, 33u], [25u, 26u, 27u], [28u, 29u, 30u, 31u],
            [32u, 33u, 34u],
        ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "mixed K4fe w0.10 L0 (task 0456 flat-cap freeze)");
    assertBevelManifoldCleanOpen(m, "mixed K4fe w0.10 L0 (task 0456 flat-cap freeze)", 2);
}

unittest { // bevelEdgesByMask: "K4 junction (asymmetric)" L0
           // Flat-cap freeze (task 0456): the asymmetric-K4 tripod-plus hub at
           // Round Level 0 (no rounding). Transcribed FROM the reference capture
           // dump edge_bevel_gen_k4_asym1_level0 — NOT our kernel's output.
           // Complements the symmetric-K4 L0 freeze (task 0443) with a genuinely
           // asymmetric flat-cap case (12v/9f).
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.6f,0,1.3f),
        Vec3(0.3f,1.9f,1.6f),
        Vec3(-1.4f,0.5f,1.0f),
        Vec3(0,-1.2f,1.9f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.15f, 0);
        immutable Vec3[] wantVerts = [
            Vec3(-0.11276852339506149f, 0.17703141272068024f, 0.2041655331850052f), Vec3(-0.12384378165006638f, -0.04040201008319855f, 0.22246038913726807f), Vec3(0.1376064270734787f, -0.09467793256044388f, 0.2617119252681732f),
            Vec3(0.15481653809547424f, 0.13121001422405243f, 0.21944820880889893f), Vec3(1.5160075426101685f, 0.12275818735361099f, 1.3193827867507935f), Vec3(1.4850609302520752f, -0.08620436489582062f, 1.3431020975112915f),
            Vec3(0.18828248977661133f, 1.8079973459243774f, 1.5605703592300415f), Vec3(0.383992463350296f, 1.777241826057434f, 1.5806171894073486f), Vec3(-1.3117303848266602f, 0.392815500497818f, 1.0567446947097778f),
            Vec3(-1.2882823944091797f, 0.5920026898384094f, 1.0394296646118164f), Vec3(0.11493915319442749f, -1.1137956380844116f, 1.8568978309631348f), Vec3(-0.08826958388090134f, -1.0928155183792114f, 1.8432552814483643f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 2u, 5u], [3u, 7u, 6u, 0u],
            [0u, 9u, 8u, 1u], [1u, 11u, 10u, 2u], [0u, 1u, 2u, 3u],
        ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "K4 junction (asymmetric) L0 (task 0456 flat-cap freeze)");
    assertBevelManifoldCleanOpen(m, "K4 junction (asymmetric) L0 (task 0456 flat-cap freeze)", 1);
}

unittest { // bevelEdgesByMask: MAX_JUNCTION_VALENCE DoS backstop (task 0456).
           // A rounded N-way hub emits ~valence·(2^L)² faces, so a crafted
           // high-valence full hub is an attacker-scalable allocation vector.
           // Over the kernel cap, the hub must fall through to the flat N-gon cap
           // (no Gregory ring) and stay sound — verified here on a valence
           // (MAX_JUNCTION_VALENCE+2) fan apex.
    import std.math : cos, sin, PI;
    enum int N = MAX_JUNCTION_VALENCE + 2; // 66 > 64
    Mesh m;
    m.vertices ~= Vec3(0, 0, 0); // apex
    // Rim radius large enough that adjacent rim points are well clear of the
    // bevel width (2π·R/N ≫ width), so the flat fallback stays coincidence-free.
    enum float R = 20.0f;
    foreach (k; 0 .. N) {
        immutable float a = 2.0f * cast(float)PI * cast(float)k / cast(float)N;
        m.vertices ~= Vec3(R * cos(a), R * sin(a), 3.0f);
    }
    foreach (k; 0 .. N)
        m.addFace([0u, cast(uint)(1 + k), cast(uint)(1 + (k + 1) % N)]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (ei; m.edgesAroundVertex(0)) mask[ei] = true;
    m.bevelEdgesByMask(mask, 0.1f, 1);
    // Flat fallback: the cap is ONE large polygon (poles + rounded rail
    // interiors threaded into a single ring, >= N sides), NOT a rounded Gregory
    // ring (which would be all-quads + a hub vertex + interior grid).
    bool foundFlatCap = false;
    foreach (f; m.faces) if (f.length >= N) { foundFlatCap = true; break; }
    assert(foundFlatCap, "over-cap full hub must fall back to the flat N-gon cap");
    assertBevelManifoldCleanOpen(m, "MAX_JUNCTION_VALENCE flat fallback (task 0456)", 1);
}


unittest { // bevelEdgesByMask: N-way junction "K4 junction (asymmetric)" (task 0443
           // freeze) — the SAME topology as K4 above (4 triangles, all 4 edges selected)
           // but a deliberately irregular base ring — unequal edge lengths
           // and unequal azimuthal spacing, so no two of the 4 faces are
           // congruent (rules out a symmetry coincidence hiding a bug).
           // Round Level 0 (the flat N-gon cap). L>=1 now rounds via the
           // N-sided Gregory ring (task 0454/0456 — see the L1/L2/L3 parity
           // fixtures below); L0 is unchanged and already matches the reference
           // bit-exact. Provenance (task 0450):
           // the want* numbers below are transcribed directly FROM the
           // reference capture dump (gen_k*_level0), not from our kernel's
           // output — assertFacesMatchByPosition canonicalises by position and
           // connectivity, so the reference's vertex ordering substitutes
           // directly, making this a PARITY guard rather than a regression
           // guard on our own output.
    import std.conv : to;
    Mesh m;
    m.vertices = [
        Vec3(0,0,0),
        Vec3(1.6f,0,1.3f),
        Vec3(0.3f,1.9f,1.6f),
        Vec3(-1.4f,0.5f,1.0f),
        Vec3(0,-1.2f,1.9f),
    ];
    m.addFace([0u,1u,2u]); m.addFace([0u,2u,3u]); m.addFace([0u,3u,4u]); m.addFace([0u,4u,1u]);
    m.buildLoops();
    m.syncSelection();
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    size_t nSel = 0;
    foreach (ei; m.edgesAroundVertex(0)) { mask[ei] = true; ++nSel; }
    assert(m.bevelEdgesByMask(mask, 0.15f, 0) == nSel);

        // 12v/9f
        immutable Vec3[] wantVerts = [
            Vec3(-0.112768523f, 0.177031413f, 0.204165533f), Vec3(-0.123843782f, -0.0404020101f, 0.222460389f),
            Vec3(0.137606427f, -0.0946779326f, 0.261711925f), Vec3(0.154816538f, 0.131210014f, 0.219448209f),
            Vec3(1.51600754f, 0.122758187f, 1.31938279f), Vec3(1.48506093f, -0.0862043649f, 1.3431021f),
            Vec3(0.18828249f, 1.80799735f, 1.56057036f), Vec3(0.383992463f, 1.77724183f, 1.58061719f),
            Vec3(-1.31173038f, 0.3928155f, 1.05674469f), Vec3(-1.28828239f, 0.59200269f, 1.03942966f),
            Vec3(0.114939153f, -1.11379564f, 1.85689783f), Vec3(-0.0882695839f, -1.09281552f, 1.84325528f),
        ];
        static immutable uint[][] wantFaces = [
            [2u, 10u, 5u], [1u, 8u, 11u], [0u, 6u, 9u],
            [3u, 4u, 7u], [4u, 3u, 2u, 5u], [3u, 7u, 6u, 0u],
            [0u, 9u, 8u, 1u], [1u, 11u, 10u, 2u], [0u, 1u, 2u, 3u],
        ];

    assertFacesMatchByPosition(m, wantVerts, wantFaces, "K4 junction (asymmetric) L0 (task 0443 freeze)");
    assertBevelManifoldCleanOpen(m, "K4 junction (asymmetric) L0", 1);
}

unittest { // bevelEdgesByMask: an ISOLATED fin bundle — a spine edge shared by
           // N≥3 fins whose endpoints touch nothing else — is beveled by the
           // measured reference law (task 0438), while a 3-face edge EMBEDDED in
           // a larger mesh stays refused, byte-identical (unmeasured — no
           // extrapolation).
           //
           // Measured law (`edge_bevel_0438_{A3face,B4face}_*`): each fin is
           // inset in place (its spine corner p → p + width·û_perp, the ordinary
           // two-face per-face formula) and exactly one new N-gon fan cap is
           // added at each spine end. `sharp` is inert (not even a kernel param)
           // and Round Level does not round this cap — both verified inert here
           // by asserting L0 and L1 produce the identical result.
    import std.math : cos, sin, PI, abs;
    // "Propeller": one spine edge (0,0,+1)-(0,0,-1) shared by `fins` quad fins
    // fanning around z at even azimuths, radius 1 — the exact capture geometry.
    Mesh propeller(int fins) {
        Mesh m;
        m.vertices = [Vec3(0, 0, 1), Vec3(0, 0, -1)];   // spine top / bottom
        foreach (i; 0 .. fins) {
            immutable float a = 2.0f * PI * i / fins;
            m.vertices ~= Vec3(cos(a), sin(a),  1.0f);
            m.vertices ~= Vec3(cos(a), sin(a), -1.0f);
        }
        foreach (i; 0 .. fins)
            m.addFace([0u, cast(uint)(2 + 2 * i), cast(uint)(3 + 2 * i), 1u]);
        m.buildLoops();
        m.syncSelection();
        return m;
    }
    int findSpine(ref Mesh m) {
        foreach (i; 0 .. m.edges.length) {
            uint a = m.edges[i][0], b = m.edges[i][1];
            if ((a == 0 && b == 1) || (a == 1 && b == 0)) return cast(int)i;
        }
        return -1;
    }
    bool hasVertNear(ref Mesh m, Vec3 p) {
        foreach (v; m.vertices) if ((v - p).length < 1e-4f) return true;
        return false;
    }
    enum float W = 0.15f;

    foreach (fins; [3, 4]) {
        // L0 and L1 must be byte-identical (Round Level inert on this cap).
        Mesh[2] outs;
        foreach (li, level; [0, 1]) {
            auto m = propeller(fins);
            auto use = m.edgeFaceUseCounts();
            immutable int spine = findSpine(m);
            assert(spine >= 0, "spine edge missing");
            assert(use[spine] == fins, "spine must carry every fin");

            bool[] mask; mask.length = m.edges.length; mask[] = false;
            mask[spine] = true;
            immutable size_t n = m.bevelEdgesByMask(mask, W, level);
            assert(n > 0, "an isolated fin bundle must bevel, not refuse");

            // Topology: −2 spine verts + 2N rails; fins unchanged + 2 caps.
            assert(m.vertices.length == cast(size_t)(2 + 2 * fins) - 2 + 2 * fins,
                "isolated fin bundle vertex count");
            assert(m.faces.length == cast(size_t)fins + 2,
                "fins stay in place (+1 cap per end)");
            // The two spine verts are gone.
            assert(!hasVertNear(m, Vec3(0, 0, 1)) && !hasVertNear(m, Vec3(0, 0, -1)),
                "the spine endpoints must be consumed");
            // Every fin's two rail points exist: p + W·(cosθ,sinθ,0) at each end.
            foreach (i; 0 .. fins) {
                immutable float a = 2.0f * PI * i / fins;
                immutable Vec3 dir = Vec3(cos(a), sin(a), 0);
                assert(hasVertNear(m, Vec3(0, 0,  1) + dir * W), "top rail missing");
                assert(hasVertNear(m, Vec3(0, 0, -1) + dir * W), "bottom rail missing");
            }
            // Exactly one N-gon cap per end: a face with `fins` corners all at
            // z=+1, and another all at z=−1 (the fins are quads spanning both).
            int topCap = 0, botCap = 0;
            foreach (f; m.faces) {
                if (f.length != cast(size_t)fins) continue;
                bool allTop = true, allBot = true;
                foreach (vi; f) {
                    if (abs(m.vertices[vi].z - 1.0f) > 1e-4f) allTop = false;
                    if (abs(m.vertices[vi].z + 1.0f) > 1e-4f) allBot = false;
                }
                if (allTop) ++topCap;
                if (allBot) ++botCap;
            }
            assert(topCap == 1 && botCap == 1,
                "exactly one N-gon fan cap per spine end");
            outs[li] = m;
        }
        // Round Level inert: L0 and L1 vertex sets + face store match exactly.
        assert(outs[0].vertices == outs[1].vertices && outs[0].faces._store == outs[1].faces._store,
            "Round Level must not change the N-gon end cap (measured inert)");
    }

    // EMBEDDED 3-face edge (endpoint carries an extra, non-spine face): NOT the
    // measured topology — must still refuse, byte-identical, no mutation.
    {
        auto m = propeller(3);
        // Add a triangle touching the top spine vertex (0) but NOT the spine
        // edge — so vertex 0 now has 4 incident faces while the spine still has
        // 3. This is the "embedded in a larger mesh" case task 0438 leaves
        // refused. (verts 2 and 4 are two of the outer-top fin corners.)
        m.addFace([2u, 0u, 4u]);
        m.buildLoops();
        m.syncSelection();
        immutable int spine = findSpine(m);
        assert(spine >= 0 && m.edgeFaceUseCounts()[spine] == 3,
            "spine still shared by exactly the 3 fins");
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        mask[spine] = true;
        auto vertsBefore = m.vertices.dup;
        auto facesBefore = m.faces._store.dup;
        foreach (level; [0, 1]) {
            assert(m.bevelEdgesByMask(mask, W, level) == 0,
                "an embedded (unmeasured) 3-face edge must be refused");
            assert(m.vertices == vertsBefore && m.faces._store == facesBefore,
                "the refusal must leave the mesh byte-identical");
        }
    }
}

unittest { // bevelEdgesByMask: a MULTI-EDGE selection THROUGH an isolated fin
           // bundle — the spine plus "extra" edges that are fins' outer boundary
           // edges at a spine endpoint — bevels by the measured reference law
           // (parity task, fuzz divergence D2), while unmeasured extensions stay
           // refused byte-identical.
           //
           // Measured law (captured bit-exact vs. the reference on a rectangular
           // AND a skewed fin): a fin whose outer edge at the spine endpoint is
           // ALSO selected replaces that spine corner with a MITER (spine-inset ∩
           // outer-inset) and corner-cuts the extra edge's far vertex into two
           // (perpendicular inset of the fin's next edge + a slide along it); the
           // end cap fans the miter there, the plain spine rail elsewhere.
    import std.math : abs;
    // The D2 capture geometry: a 3-fin bundle, spine (0,0,±1), plus two extra
    // edges (both at the +z spine endpoint, one on each of two fins).
    Mesh finBundle() {
        Mesh m;
        m.vertices = [
            Vec3(0, 0, 1), Vec3(0, 0, -1),
            Vec3(1, 0, 1), Vec3(1, 0, -1),
            Vec3(-0.5f, 0.866025f, 1), Vec3(-0.5f, 0.866025f, -1),
            Vec3(-0.5f, -0.866025f, 1), Vec3(-0.5f, -0.866025f, -1),
        ];
        m.addFace([0u, 2u, 3u, 1u]);   // fin f0 (+x)
        m.addFace([0u, 4u, 5u, 1u]);   // fin f1 (upper-left)
        m.addFace([0u, 6u, 7u, 1u]);   // fin f2 (lower-left)
        m.buildLoops();
        m.syncSelection();
        return m;
    }
    int edgeIdx(ref Mesh m, uint a, uint b) {
        foreach (i; 0 .. m.edges.length) {
            uint u = m.edges[i][0], v = m.edges[i][1];
            if ((u == a && v == b) || (u == b && v == a)) return cast(int)i;
        }
        return -1;
    }
    bool hasVertNear(ref Mesh m, Vec3 p) {
        foreach (v; m.vertices) if ((v - p).length < 2e-3f) return true;
        return false;
    }
    enum float W = 0.49f;

    // (1) The measured triangle selection: spine (0,1) + E_a (0,2) + E_b (0,4).
    {
        auto m = finBundle();
        immutable int es = edgeIdx(m, 0, 1), ea = edgeIdx(m, 0, 2), eb = edgeIdx(m, 0, 4);
        assert(es >= 0 && ea >= 0 && eb >= 0);
        assert(m.edgeFaceUseCounts()[es] == 3, "spine carries all 3 fins");
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        mask[es] = true; mask[ea] = true; mask[eb] = true;
        immutable size_t n = m.bevelEdgesByMask(mask, W);
        assert(n > 0, "multi-edge fin-bundle selection must bevel, not refuse");
        assert(m.vertices.length == 14, "D2 result is 14 verts");
        assert(m.faces.length == 5, "D2 result is 5 faces");
        // Spine endpoints consumed.
        assert(!hasVertNear(m, Vec3(0, 0, 1)) && !hasVertNear(m, Vec3(0, 0, -1)),
            "spine endpoints must be consumed");
        // Plain spine rails at the −z end (no extra edges there).
        assert(hasVertNear(m, Vec3(0.49f, 0, -1)),        "f0 −z rail");
        assert(hasVertNear(m, Vec3(-0.245f, 0.42435f, -1)), "f1 −z rail");
        assert(hasVertNear(m, Vec3(-0.245f, -0.42435f, -1)), "f2 −z rail");
        // f2 has no extra edge → plain +z rail.
        assert(hasVertNear(m, Vec3(-0.245f, -0.42435f, 1)), "f2 +z rail");
        // f0 / f1 spine corners at +z are MITERS (z = 1 − W = 0.51).
        assert(hasVertNear(m, Vec3(0.49f, 0, 0.51f)),        "f0 +z miter");
        assert(hasVertNear(m, Vec3(-0.245f, 0.42435f, 0.51f)), "f1 +z miter");
        // Corner-cuts of the extra edges' far vertices.
        assert(hasVertNear(m, Vec3(0.51f, 0, 1)) && hasVertNear(m, Vec3(1, 0, 0.51f)),
            "f0 corner-cut of v2");
        assert(hasVertNear(m, Vec3(-0.255f, 0.44167f, 1)) && hasVertNear(m, Vec3(-0.5f, 0.866025f, 0.51f)),
            "f1 corner-cut of v4");
        // Two triangular fan caps: [f2 rail, f0 miter, f1 miter] at +z and the
        // three plain rails at −z.
        int tris = 0; foreach (f; m.faces) if (f.length == 3) ++tris;
        assert(tris == 2, "two triangular fan caps");
    }
    // (2) Gate: a fin carrying extra edges at BOTH spine ends is unmeasured — must
    // refuse, byte-identical. Add (3,1) = f0's outer edge at the −z endpoint.
    {
        auto m = finBundle();
        immutable int es = edgeIdx(m, 0, 1), ea = edgeIdx(m, 0, 2), eb2 = edgeIdx(m, 3, 1);
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        mask[es] = true; mask[ea] = true; mask[eb2] = true;
        auto vertsBefore = m.vertices.dup;
        auto facesBefore = m.faces._store.dup;
        assert(m.bevelEdgesByMask(mask, W) == 0,
            "extras at both ends of one fin is unmeasured — must refuse");
        assert(m.vertices == vertsBefore && m.faces._store == facesBefore,
            "the refusal must leave the mesh byte-identical");
    }
}

unittest { // bevelEdgesByMask: OPEN-BOUNDARY support at Round Level 0 — a chain
           // whose end vertices sit on the rim of a hole must bevel every
           // selected edge, not just the interior ones.
           //
           // Before open-fan support the per-vertex pass rejected any vertex
           // whose edge ring was longer than its face ring (a boundary vertex
           // emits one extra "open" edge), so both end spans were silently
           // dropped and a 3-edge selection produced ONE chamfer.  The fan is
           // now walked as an open slot sequence e_0..e_d with no wrap.
           //
           // Every number below is reference-captured
           // (`edge_bevel_open_*_w015`, width 0.15) and reproduced bit-exactly.
    Mesh cubeMinusBottom() {
        // Unit cube with the y == -0.5 face removed: 8 verts, 5 faces, one
        // open rim of 4 edges. Rim vertices are 0, 1, 4, 7.
        Mesh m;
        m.vertices = [
            Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f,-0.5f),
            Vec3( 0.5f,-0.5f,-0.5f), Vec3( 0.5f, 0.5f,-0.5f),
            Vec3( 0.5f, 0.5f, 0.5f), Vec3( 0.5f,-0.5f, 0.5f),
        ];
        m.addFace([0u, 1u, 2u, 3u]);   // -X
        m.addFace([4u, 5u, 6u, 7u]);   // +X
        m.addFace([3u, 2u, 6u, 5u]);   // +Y
        m.addFace([0u, 3u, 5u, 4u]);   // -Z
        m.addFace([1u, 7u, 6u, 2u]);   // +Z
        m.buildLoops();
        m.syncSelection();
        return m;
    }
    static ulong ekey(uint a, uint b) {
        return a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
    }
    // Counts edges by how many faces use them: [rim (1 face), non-manifold (>2)].
    int[2] edgeUseProfile(ref Mesh m) {
        int[ulong] use;
        foreach (f; m.faces)
            foreach (k; 0 .. f.length) use[ekey(f[k], f[(k + 1) % f.length])]++;
        int[2] r = [0, 0];
        foreach (kv; use.byKeyValue) {
            if (kv.value == 1) ++r[0];
            else if (kv.value != 2) ++r[1];
        }
        return r;
    }
    bool hasVert(ref Mesh m, Vec3 want) {
        foreach (v; m.vertices) if ((v - want).length < 1e-5f) return true;
        return false;
    }
    bool[] selectPairs(ref Mesh m, uint[2][] pairs) {
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (p; pairs) {
            bool found = false;
            foreach (i; 0 .. m.edges.length) {
                uint a = m.edges[i][0], b = m.edges[i][1];
                if ((a == p[0] && b == p[1]) || (a == p[1] && b == p[0])) {
                    mask[i] = true; found = true; break;
                }
            }
            assert(found, "selected edge missing");
        }
        return mask;
    }

    // Premise: the chain's two end vertices really are on the rim (open fan),
    // i.e. edge-ring length == face-ring length + 1.
    {
        auto m = cubeMinusBottom();
        foreach (V; [4u, 7u]) {
            size_t d = 0, e = 0;
            foreach (fi; m.facesAroundVertex(V)) ++d;
            foreach (ei; m.edgesAroundVertex(V)) ++e;
            assert(e == d + 1, "rim vertex must present an OPEN fan");
        }
        foreach (V; [5u, 6u]) {
            size_t d = 0, e = 0;
            foreach (fi; m.facesAroundVertex(V)) ++d;
            foreach (ei; m.edgesAroundVertex(V)) ++e;
            assert(e == d, "interior chain vertex must present a CLOSED fan");
        }
        assert(edgeUseProfile(m) == [4, 0], "input must have a 4-edge rim and be otherwise manifold");
    }

    // `chain3`: all three edges bevel, including the two anchored on the rim.
    {
        auto m = cubeMinusBottom();
        auto mask = selectPairs(m, [[4u, 5u], [5u, 6u], [6u, 7u]]);
        assert(m.bevelEdgesByMask(mask, 0.15f, 0) == 3,
            "all three edges must bevel — the two rim-anchored ones included");
        assert(m.vertices.length == 12 && m.faces.length == 8,
            "open-boundary L0 chain bevel must be 12v/8f");
        // The bevel notches the rim at each end (one rim vertex becomes two),
        // so the hole grows from 4 to 6 edges — and NOTHING else may open.
        assert(edgeUseProfile(m) == [6, 0],
            "rim must grow 4 -> 6 edges with no new non-manifold edge");
        foreach (want; [Vec3(0.35f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, -0.35f),
                        Vec3(0.5f, -0.5f,  0.35f), Vec3(0.35f, -0.5f, 0.5f)])
            assert(hasVert(m, want), "expected rim slide corner missing");
        foreach (v; m.vertices)
            assert(v.y >= -0.5f - 1e-6f, "bevel must not push geometry past the rim plane");
    }

    // Round Level at a RIM vertex rounds by the same circular-fillet law as an
    // interior vertex (reference `edge_bevel_open_chain3_w015_level{1,2}`, rail
    // points matching the fillet+SLERP closed form to <= 7.09e-9). The rail is
    // approved with a single consumer there: an interior rail needs the strip
    // plus the back face, but a rim rail has no back face — the open boundary
    // takes its place.
    {
        static immutable size_t[3] wantV = [12, 16, 24];
        static immutable size_t[3] wantF = [8, 11, 17];
        foreach (level; 0 .. 3) {
            auto mr = cubeMinusBottom();
            auto maskr = selectPairs(mr, [[4u, 5u], [5u, 6u], [6u, 7u]]);
            assert(mr.bevelEdgesByMask(maskr, 0.15f, cast(int)level) == 3,
                "rounded open-boundary chain must bevel all three edges");
            assert(mr.vertices.length == wantV[level] && mr.faces.length == wantF[level],
                "rounded open-boundary chain vertex/face count regressed");
            assert(edgeUseProfile(mr)[1] == 0, "rounding must add no non-manifold edge");
            foreach (v; mr.vertices)
                assert(v.y >= -0.5f - 1e-6f, "rounding must not cross the rim plane");
        }
        // The rim polyline itself is NEVER subdivided; the extra points appear
        // only on a beveled vertex's own chamfer rail, which the boundary then
        // follows. Reference rim-edge counts are 6 / 8 / 12 — that is the four
        // untouched rim edges plus the segments of the two rim-anchored rails
        // (2 chords at L0, then 2·L segments each).
        static immutable size_t[3] wantRim = [6, 8, 12];
        foreach (level; 0 .. 3) {
            auto mr = cubeMinusBottom();
            auto maskr = selectPairs(mr, [[4u, 5u], [5u, 6u], [6u, 7u]]);
            mr.bevelEdgesByMask(maskr, 0.15f, cast(int)level);
            assert(edgeUseProfile(mr)[0] == wantRim[level],
                "rim edge count must follow the rail subdivision, nothing else");
        }
        // A fully interior bevel on the same open mesh never touches the rim.
        foreach (level; 0 .. 3) {
            auto mi = cubeMinusBottom();
            auto maski = selectPairs(mi, [[5u, 6u]]);
            mi.bevelEdgesByMask(maski, 0.15f, cast(int)level);
            assert(edgeUseProfile(mi)[0] == 4, "an interior bevel must leave the rim alone");
        }
    }

    // `rimedge`: a selected RIM edge (exactly ONE incident face) bevels too,
    // but adds NO face — its lone face's border insets by `width` and the
    // neighbours absorb the corner cut, becoming pentagons. 10v/5f.
    //
    // Round Level does nothing here, at any level: with no bridge quad there
    // is no chamfer strip, hence no rail to subdivide. The reference dumps at
    // levels 0, 1 and 2 are byte-identical, so ours must be too.
    {
        foreach (level; 0 .. 3) {
            auto ml = cubeMinusBottom();
            auto maskl = selectPairs(ml, [[7u, 4u]]);
            assert(ml.bevelEdgesByMask(maskl, 0.15f, cast(int)level) == 1,
                "a rim edge must bevel at every Round Level");
            assert(ml.vertices.length == 10 && ml.faces.length == 5,
                "Round Level must not change a rim edge's result");
        }
        auto m = cubeMinusBottom();
        auto mask = selectPairs(m, [[7u, 4u]]);
        assert(m.bevelEdgesByMask(mask, 0.15f, 0) == 1,
            "a rim edge with one incident face must still bevel");
        assert(m.vertices.length == 10 && m.faces.length == 5,
            "rim-edge bevel adds two verts and NO face");
        foreach (want; [Vec3(0.5f, -0.35f, -0.5f), Vec3(0.5f, -0.35f, 0.5f),
                        Vec3(0.35f, -0.5f, -0.5f), Vec3(0.35f, -0.5f,  0.5f)])
            assert(hasVert(m, want), "expected rim-edge bevel vertex missing");
        // The source endpoints are NOT retained — the corner is fully cut.
        foreach (gone; [Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, -0.5f, 0.5f)])
            assert(!hasVert(m, gone), "rim-edge endpoint must be cut, not kept");
        assert(edgeUseProfile(m)[1] == 0, "rim-edge bevel must add no non-manifold edge");
    }

    // `bothends`: same law when BOTH endpoints are on a rim — an open tube
    // (both Y faces removed) beveled on F-G, which has one incident face.
    // 10v/4f.
    {
        Mesh tube;
        tube.vertices = [
            Vec3(-0.5f,-0.5f,-0.5f), Vec3(-0.5f,-0.5f, 0.5f),
            Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f,-0.5f),
            Vec3( 0.5f,-0.5f,-0.5f), Vec3( 0.5f, 0.5f,-0.5f),
            Vec3( 0.5f, 0.5f, 0.5f), Vec3( 0.5f,-0.5f, 0.5f),
        ];
        tube.addFace([0u, 1u, 2u, 3u]);
        tube.addFace([4u, 5u, 6u, 7u]);
        tube.addFace([0u, 3u, 5u, 4u]);
        tube.addFace([1u, 7u, 6u, 2u]);
        tube.buildLoops();
        tube.syncSelection();
        auto mask = selectPairs(tube, [[5u, 6u]]);
        assert(tube.bevelEdgesByMask(mask, 0.15f, 0) == 1,
            "an edge with both endpoints on a rim must bevel");
        assert(tube.vertices.length == 10 && tube.faces.length == 4,
            "both-ends-on-rim bevel adds two verts and NO face");
        foreach (want; [Vec3(0.5f, 0.35f, -0.5f), Vec3(0.5f, 0.35f, 0.5f),
                        Vec3(0.35f, 0.5f, -0.5f), Vec3(0.35f, 0.5f,  0.5f)])
            assert(hasVert(tube, want), "expected both-ends-on-rim bevel vertex missing");
        assert(edgeUseProfile(tube)[1] == 0, "must add no non-manifold edge");
    }
}

unittest { // bevelEdgesByMask: a partial K2 fan at valence FOUR whose selected
           // edges alternate with the unselected ones (every fan gap == 1 edge)
           // is SUPPORTED at every Round Level — every face at such a vertex
           // borders a selected edge, so the fan resolves to MITER/SLIDE only
           // and never reaches the partial-notch branch.  The old preflight
           // rejected the whole family on a coarse `d>3 && K>=2 && K<d`
           // signature, silently turning Round Level > 0 into a no-op here.
           //
           // Provenance: this is a cube whose (+,+,+) corner was itself edge-
           // beveled (the reference-verified K3 junction), then the 3-edge
           // chain crossing that junction cap is beveled again.  The chain's
           // two shared vertices land at valence 4 with alternating K2; its
           // free ends stay valence 3.
    Mesh chainOnBeveledCorner() {
        auto m = makeCube();
        int corner = -1;
        foreach (i, v; m.vertices)
            if ((v - Vec3(0.5f, 0.5f, 0.5f)).length < 1e-6f) corner = cast(int)i;
        assert(corner >= 0, "cube corner (+,+,+) missing");
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (i; 0 .. m.edges.length)
            if (m.edges[i][0] == corner || m.edges[i][1] == corner) mask[i] = true;
        assert(m.bevelEdgesByMask(mask, 0.273983f, 0) == 3, "K3 corner setup must bevel 3 edges");
        assert(m.vertices.length == 13 && m.faces.length == 10, "K3 L0 setup must be 13v/10f");
        return m;
    }
    // The 3-edge chain: two junction-cap edges plus one rail edge, meeting at
    // the two valence-4 vertices (0.226017, 0.5, 0.226017) / (0.226017, 0.226017, 0.5).
    bool[] selectChain(ref Mesh m) {
        static immutable Vec3[2][3] pairs = [
            [Vec3(0.226017f, -0.5f, 0.5f),      Vec3(0.226017f, 0.226017f, 0.5f)],
            [Vec3(0.226017f, 0.5f, 0.226017f),  Vec3(0.226017f, 0.5f, -0.5f)],
            [Vec3(0.226017f, 0.226017f, 0.5f),  Vec3(0.226017f, 0.5f, 0.226017f)],
        ];
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (p; pairs) {
            bool found = false;
            foreach (i; 0 .. m.edges.length) {
                Vec3 a = m.vertices[m.edges[i][0]], b = m.vertices[m.edges[i][1]];
                if (((a - p[0]).length < 1e-5f && (b - p[1]).length < 1e-5f) ||
                    ((a - p[1]).length < 1e-5f && (b - p[0]).length < 1e-5f)) {
                    mask[i] = true; found = true; break;
                }
            }
            assert(found, "chain edge missing from the beveled-corner cube");
        }
        return mask;
    }

    // Guard premise: the two shared vertices really are valence-4 alternating
    // K2, i.e. the exact family the old signature rejected.
    {
        auto m = chainOnBeveledCorner();
        auto mask = selectChain(m);
        size_t alternatingK2 = 0;
        foreach (V; 0 .. cast(uint)m.vertices.length) {
            size_t d = 0;
            foreach (fi; m.facesAroundVertex(V)) ++d;
            bool[] fan;
            foreach (ei; m.edgesAroundVertex(V)) fan ~= mask[ei];
            if (fan.length != d || d != 4) continue;
            size_t K = 0;
            foreach (s; fan) if (s) ++K;
            if (K != 2) continue;
            bool gapOk = true;
            foreach (k; 0 .. d) if (!fan[k] && !fan[(k + 1) % d]) gapOk = false;
            if (gapOk) ++alternatingK2;
        }
        assert(alternatingK2 == 2, "setup must expose exactly two alternating-K2 valence-4 vertices");
    }

    // 2·L segments per rail × 4 rails (two K1 free ends + two K2 miters):
    // L0 17v/13f, then +4 verts and +2 faces per level step.
    static immutable size_t[4] wantVerts = [17, 21, 29, 37];
    static immutable size_t[4] wantFaces = [13, 16, 22, 28];
    foreach (level; 0 .. 4) {
        auto m = chainOnBeveledCorner();
        auto mask = selectChain(m);
        assert(m.bevelEdgesByMask(mask, 0.1f, cast(int)level) == 3,
            "alternating K2 at valence 4 must bevel all 3 chain edges at every Round Level");
        assert(m.vertices.length == wantVerts[level] && m.faces.length == wantFaces[level],
            "alternating-K2 chain vertex/face count regressed");
        assertBevelManifoldClean(m, "alternating K2 valence-4 chain");
    }
}

unittest { // bevelEdgesByMask: explicit L0 golden for an isolated cube edge.
           // Do not compare two calls through the same implementation: these
    // values are the pre-rounding topology/attribute contract.
    auto m = makeCube();
    m.syncSelection(); // initialize parallel marks/material/part arrays
    m.faceMaterial[1] = 7u; m.facePart[1] = 23u;
    m.setFaceSubpatch(1, true);
    int ei = -1;
    foreach (i; 0 .. m.edges.length) {
        uint a = m.edges[i][0], b = m.edges[i][1];
        if ((a == 6 && b == 7) || (a == 7 && b == 6)) { ei = cast(int)i; break; }
    }
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 1);
    assert(m.vertices.length == 10 && m.faces.length == 7);
    int[int] fvd;
    foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(4, 0) == 5 && fvd.get(5, 0) == 2,
        "L0 isolated-edge face golden must stay {quad:5,pentagon:2}");
    assert(m.faceMaterial[1] == 7u && m.facePart[1] == 23u && m.isFaceSubpatch(1),
        "L0 source material/part/subpatch must be preserved");
    assert(m.countSelectedFaces() == 1,
        "L0 selection policy must select the one new chamfer face");
    assertBevelManifoldClean(m, "L0 isolated-edge golden");
}

// ---------------------------------------------------------------------------
// task 0439: free-end cap at valence > 3, partial-fan notch (Decisions A-D,
// doc/edge_bevel_freeend_cap_plan.md). Golden tests 1-6 reproduce a captured
// reference dump bit-for-bit (position + connectivity + winding, width=0.1,
// roundLevel=0); smoke tests 7-8 cover the extrapolated (K>=3 / miter-ring)
// zone with manifold+connectivity+χ only; regression tests 9-10 close two
// pre-existing holes on unpatched main; degrade tests 11-13 exercise the
// Round Level local-degrade fixed point (Decision D); test 14 is the
// byte-stable reject for a cap on an OPEN (boundary) fan (Decision A-5).
// ---------------------------------------------------------------------------

unittest { // golden test 1: disk N=4, hub-R0 selected -> triangle cap.
    import std.math : cos, sin, PI;
    auto m = makeDisk(4);
    // Reference-verified law (task0439_A2_freeend_v4fan_L0): every slide
    // vertex is `source + width*normalize(neighbor - source)` — the SAME
    // formula the kernel's own `getSlide` uses. Deriving "want" positions
    // from the pre-bevel mesh (rather than re-typing decimal literals from
    // the capture dump) sidesteps a float32 rounding-boundary artifact at
    // the 5th decimal (e.g. sqrt(3)/2 prints as "0.86603" from a computed
    // cos/sin but "0.86602" from a truncated 6-digit literal) — a pure
    // formatting mismatch the plan's own capture pass hit for the same
    // reason (findings §"Прототип против эталонных дампов").
    immutable Vec3[] orig = m.vertices.dup;
    Vec3 slide(int from, int to) {
        return orig[from] + safeNormalize(orig[to] - orig[from]) * 0.1f;
    }
    int ei = findEdge(m, 0, 1);
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 1);
    assert(m.vertices.length == 8 && m.faces.length == 6,
        "disk N=4 hub-R0 golden must be 8v/6f");
    int[int] fvd; foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(3, 0) == 3, "the free-end cap at N-K=3 must be a triangle");
    Vec3[] wantVerts = [
        orig[2], orig[3], orig[4],
        slide(0, 2), slide(0, 3), slide(0, 4),
        slide(1, 2), slide(1, 4),
    ];
    static immutable uint[][] wantFaces = [
        [5, 2, 7], [4, 1, 2, 5], [3, 0, 1, 4], [3, 6, 0], [6, 3, 5, 7], [3, 4, 5],
    ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "disk N=4 hub-R0");
    assertBevelManifoldCleanOpen(m, "disk N=4 hub-R0", 1);
}

unittest { // golden test 2: disk N=5, hub-R0 selected -> quad cap.
    import std.math : cos, sin, PI;
    auto m = makeDisk(5);
    immutable Vec3[] orig = m.vertices.dup;
    Vec3 slide(int from, int to) {
        return orig[from] + safeNormalize(orig[to] - orig[from]) * 0.1f;
    }
    int ei = findEdge(m, 0, 1);
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 1);
    assert(m.vertices.length == 10 && m.faces.length == 7,
        "disk N=5 hub-R0 golden must be 10v/7f");
    int[int] fvd; foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(4, 0) >= 1, "the free-end cap at N-K=4 must include a quad");
    Vec3[] wantVerts = [
        orig[2], orig[3], orig[4], orig[5],
        slide(0, 2), slide(0, 3), slide(0, 4), slide(0, 5),
        slide(1, 2), slide(1, 5),
    ];
    static immutable uint[][] wantFaces = [
        [7, 3, 9], [6, 2, 3, 7], [5, 1, 2, 6], [4, 0, 1, 5], [4, 8, 0],
        [8, 4, 7, 9], [4, 5, 6, 7],
    ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "disk N=5 hub-R0");
    assertBevelManifoldCleanOpen(m, "disk N=5 hub-R0", 1);
}

unittest { // golden test 3: disk N=6, hub-R0 selected -> pentagon cap.
    import std.math : cos, sin, PI;
    auto m = makeDisk(6);
    immutable Vec3[] orig = m.vertices.dup;
    Vec3 slide(int from, int to) {
        return orig[from] + safeNormalize(orig[to] - orig[from]) * 0.1f;
    }
    int ei = findEdge(m, 0, 1);
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 1);
    assert(m.vertices.length == 12 && m.faces.length == 8,
        "disk N=6 hub-R0 golden must be 12v/8f");
    int[int] fvd; foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(5, 0) >= 1, "the free-end cap at N-K=5 must include a pentagon");
    Vec3[] wantVerts = [
        orig[2], orig[3], orig[4], orig[5], orig[6],
        slide(0, 2), slide(0, 3), slide(0, 4), slide(0, 5), slide(0, 6),
        slide(1, 2), slide(1, 6),
    ];
    static immutable uint[][] wantFaces = [
        [9, 4, 11], [8, 3, 4, 9], [7, 2, 3, 8], [6, 1, 2, 7], [5, 0, 1, 6],
        [5, 10, 0], [10, 5, 9, 11], [5, 6, 7, 8, 9],
    ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "disk N=6 hub-R0");
    assertBevelManifoldCleanOpen(m, "disk N=6 hub-R0", 1);
}

unittest { // golden test 4: disk N=5, hub-R0 + hub-R2 (gap 1/2) -> triangle cap.
    import std.math : cos, sin, PI;
    auto m = makeDisk(5);
    immutable Vec3[] orig = m.vertices.dup;
    Vec3 slide(int from, int to) {
        return orig[from] + safeNormalize(orig[to] - orig[from]) * 0.1f;
    }
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[0u, 1u], [0u, 3u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 2);
    assert(m.vertices.length == 10 && m.faces.length == 8,
        "disk N=5 hub-R0+hub-R2 (gap 1/2) golden must be 10v/8f");
    int[int] fvd; foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(3, 0) >= 1, "the free-end cap at ring=3 must include a triangle");
    // hub-R0 and hub-R2 selected: hub (0), R0 (1, endpoint) and R2 (3,
    // endpoint) are all fully cut. R1 (2) and R4 (5) are untouched rim
    // verts; R3 (4) is untouched too (both its bordering edges unselected,
    // no source-vertex cut there). hub's cap ring threads its 3 unselected
    // slides (toward R1, R3, R4); R0 and R2 each get their own 2 slide
    // points from their own (unaffected-by-the-cap) per-face substitution.
    Vec3[] wantVerts = [
        orig[2], orig[4], orig[5],
        slide(0, 2), slide(0, 4), slide(0, 5),
        slide(1, 2), slide(1, 5),
        slide(3, 4), slide(3, 2),
    ];
    static immutable uint[][] wantFaces = [
        [5, 2, 7], [4, 1, 2, 5], [4, 8, 1], [3, 0, 9], [3, 6, 0],
        [6, 3, 5, 7], [3, 9, 8, 4], [3, 4, 5],
    ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "disk N=5 notch gap(1,2)");
    assertBevelManifoldCleanOpen(m, "disk N=5 notch gap(1,2)", 1);
}

unittest { // golden test 5: disk N=6, hub-R0 + hub-R2 (gap 1/3) -> quad cap,
           // includes the slide on the "inactive" middle unselected edge
           // (hub-R4) that the old preflight's active/inactive distinction
           // used to single out and reject on.
    import std.math : cos, sin, PI;
    auto m = makeDisk(6);
    immutable Vec3[] orig = m.vertices.dup;
    Vec3 slide(int from, int to) {
        return orig[from] + safeNormalize(orig[to] - orig[from]) * 0.1f;
    }
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[0u, 1u], [0u, 3u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 2);
    assert(m.vertices.length == 12 && m.faces.length == 9,
        "disk N=6 hub-R0+hub-R2 (gap 1/3) golden must be 12v/9f");
    int[int] fvd; foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(4, 0) >= 1, "the free-end cap at ring=4 must include a quad");
    // hub-R0 and hub-R2 selected: hub (0), R0 (1) and R2 (3) fully cut.
    // hub's cap ring threads its 4 unselected slides (toward R1, R3, R4,
    // R5) — including the "inactive" middle one (R4) that the old
    // active/inactive distinction used to single out and reject on.
    Vec3[] wantVerts = [
        orig[2], orig[4], orig[5], orig[6],
        slide(0, 2), slide(0, 4), slide(0, 5), slide(0, 6),
        slide(1, 2), slide(1, 6),
        slide(3, 4), slide(3, 2),
    ];
    static immutable uint[][] wantFaces = [
        [7, 3, 9], [6, 2, 3, 7], [5, 1, 2, 6], [5, 10, 1], [4, 0, 11],
        [4, 8, 0], [8, 4, 7, 9], [4, 11, 10, 5], [4, 5, 6, 7],
    ];
    assertFacesMatchByPosition(m, wantVerts, wantFaces, "disk N=6 notch gap(1,3)");
    assertBevelManifoldCleanOpen(m, "disk N=6 notch gap(1,3)", 1);
}

// ===========================================================================
// Task 0449 fixtures (F1-F4, doc/edge_bevel_freeend_cap_roundlevel_plan.md
// §"Фаза 3"). Literals below are MECHANICALLY generated from the raw
// reference dumps `toolcards/edge.bevel/capture/task0439fu_*.json` (full
// float precision) against the matching private case description's setup
// mesh — orphan reference vertices (never referenced by any reference
// face) filtered, indices recompacted. Only the generated literals are
// committed; the one-off generator script itself stayed in scratchpad per
// the plan.
// ===========================================================================

unittest { // F1a: K=1 free end at Round Level, disk N=5 (valence 5), L1-L3.
           // Bit-exact vs reference at every level (task 0449 Замер 1): the
           // cap ring's own two boundary rails are threaded through the same
           // reference-captured fillet law every rail uses, and the reference
           // itself leaves the K=1 cap as ONE face with the arc woven in.
    import std.math : cos, sin, PI;
    import std.conv : to;
    static immutable Vec3[] v5L1Verts = [
        Vec3(0.30901700258255005f, 0.9510565400123596f, 0.0f),
        Vec3(-0.80901700258255f, 0.5877852439880371f, 0.0f),
        Vec3(-0.80901700258255f, -0.5877852439880371f, 0.0f),
        Vec3(0.30901700258255005f, -0.9510565400123596f, 0.0f),
        Vec3(0.030901700258255005f, 0.09510564804077148f, 0.0f),
        Vec3(-0.08090169727802277f, 0.05877852439880371f, 0.0f),
        Vec3(-0.08090169727802277f, -0.05877852439880371f, 0.0f),
        Vec3(0.030901700258255005f, -0.09510564804077148f, 0.0f),
        Vec3(0.9412214756011963f, 0.08090169727802277f, 0.0f),
        Vec3(0.9412214756011963f, -0.08090169727802277f, 0.0f),
        Vec3(0.015838444232940674f, 0.0f, 0.0f),
        Vec3(0.9675080180168152f, 0.0f, 0.0f),
    ];
    static immutable uint[][] v5L1Faces = [
        [7u, 3u, 9u], [6u, 2u, 3u, 7u], [5u, 1u, 2u, 6u], [4u, 0u, 1u, 5u],
        [4u, 8u, 0u], [8u, 4u, 10u, 11u], [11u, 10u, 7u, 9u],
        [4u, 5u, 6u, 7u, 10u],
    ];
    static immutable Vec3[] v5L2Verts = [
        Vec3(0.30901700258255005f, 0.9510565400123596f, 0.0f),
        Vec3(-0.80901700258255f, 0.5877852439880371f, 0.0f),
        Vec3(-0.80901700258255f, -0.5877852439880371f, 0.0f),
        Vec3(0.30901700258255005f, -0.9510565400123596f, 0.0f),
        Vec3(0.030901700258255005f, 0.09510564804077148f, 0.0f),
        Vec3(-0.08090169727802277f, 0.05877852439880371f, 0.0f),
        Vec3(-0.08090169727802277f, -0.05877852439880371f, 0.0f),
        Vec3(0.030901700258255005f, -0.09510564804077148f, 0.0f),
        Vec3(0.9412214756011963f, 0.08090169727802277f, 0.0f),
        Vec3(0.9412214756011963f, -0.08090169727802277f, 0.0f),
        Vec3(0.019627584144473076f, 0.04814557731151581f, 0.0f),
        Vec3(0.9607715606689453f, 0.0425325408577919f, 0.0f),
        Vec3(0.015838444232940674f, 0.0f, 0.0f),
        Vec3(0.9675080180168152f, 0.0f, 0.0f),
        Vec3(0.019627584144473076f, -0.04814557731151581f, 0.0f),
        Vec3(0.9607715606689453f, -0.0425325408577919f, 0.0f),
    ];
    static immutable uint[][] v5L2Faces = [
        [7u, 3u, 9u], [6u, 2u, 3u, 7u], [5u, 1u, 2u, 6u], [4u, 0u, 1u, 5u],
        [4u, 8u, 0u], [8u, 4u, 10u, 11u], [11u, 10u, 12u, 13u],
        [13u, 12u, 14u, 15u], [15u, 14u, 7u, 9u],
        [4u, 5u, 6u, 7u, 14u, 12u, 10u],
    ];
    static immutable Vec3[] v5L3Verts = [
        Vec3(0.30901700258255005f, 0.9510565400123596f, 0.0f),
        Vec3(-0.80901700258255f, 0.5877852439880371f, 0.0f),
        Vec3(-0.80901700258255f, -0.5877852439880371f, 0.0f),
        Vec3(0.30901700258255005f, -0.9510565400123596f, 0.0f),
        Vec3(0.030901700258255005f, 0.09510564804077148f, 0.0f),
        Vec3(-0.08090169727802277f, 0.05877852439880371f, 0.0f),
        Vec3(-0.08090169727802277f, -0.05877852439880371f, 0.0f),
        Vec3(0.030901700258255005f, -0.09510564804077148f, 0.0f),
        Vec3(0.9412214756011963f, 0.08090169727802277f, 0.0f),
        Vec3(0.9412214756011963f, -0.08090169727802277f, 0.0f),
        Vec3(0.02256392128765583f, 0.06398863345384598f, 0.0f),
        Vec3(0.955608606338501f, 0.055982496589422226f, 0.0f),
        Vec3(0.01752443239092827f, 0.032170552760362625f, 0.0f),
        Vec3(0.9645003080368042f, 0.028616588562726974f, 0.0f),
        Vec3(0.015838444232940674f, 0.0f, 0.0f),
        Vec3(0.9675080180168152f, 0.0f, 0.0f),
        Vec3(0.01752443239092827f, -0.032170552760362625f, 0.0f),
        Vec3(0.9645003080368042f, -0.028616588562726974f, 0.0f),
        Vec3(0.02256392128765583f, -0.06398863345384598f, 0.0f),
        Vec3(0.955608606338501f, -0.055982496589422226f, 0.0f),
    ];
    static immutable uint[][] v5L3Faces = [
        [7u, 3u, 9u], [6u, 2u, 3u, 7u], [5u, 1u, 2u, 6u], [4u, 0u, 1u, 5u],
        [4u, 8u, 0u], [8u, 4u, 10u, 11u], [11u, 10u, 12u, 13u],
        [13u, 12u, 14u, 15u], [15u, 14u, 16u, 17u], [17u, 16u, 18u, 19u],
        [19u, 18u, 7u, 9u], [4u, 5u, 6u, 7u, 18u, 16u, 14u, 12u, 10u],
    ];
    const(Vec3[])[3]   wantVertsByLevel = [v5L1Verts, v5L2Verts, v5L3Verts];
    const(uint[][])[3] wantFacesByLevel = [v5L1Faces, v5L2Faces, v5L3Faces];
    foreach (level; 1 .. 4) {
        auto m = makeDisk(5);
        int ei = findEdge(m, 0, 1);
        assert(ei >= 0);
        bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 1);
        assertFacesMatchByPosition(m, wantVertsByLevel[level - 1], wantFacesByLevel[level - 1],
            "F1a disk N=5 hub-R0 L" ~ level.to!string);
        assertBevelManifoldCleanOpen(m, "F1a disk N=5 hub-R0", 1);
    }
}

unittest { // F1b: K=1 free end at Round Level, disk N=6 (valence 6), L1-L3.
           // Bit-exact vs reference at every level (task 0449 Замер 1).
    import std.math : cos, sin, PI;
    import std.conv : to;
    static immutable Vec3[] v6L1Verts = [
        Vec3(0.5f, 0.8660253882408142f, 0.0f), Vec3(-0.5f, 0.8660253882408142f, 0.0f),
        Vec3(-1.0f, 1.22464685e-16f, 0.0f), Vec3(-0.5f, -0.8660253882408142f, 0.0f),
        Vec3(0.5f, -0.8660253882408142f, 0.0f),
        Vec3(0.05000000074505806f, 0.08660253882408142f, 0.0f),
        Vec3(-0.05000000074505806f, 0.08660253882408142f, 0.0f),
        Vec3(-0.10000000149011612f, 1.22464685e-17f, 0.0f),
        Vec3(-0.05000000074505806f, -0.08660253882408142f, 0.0f),
        Vec3(0.05000000074505806f, -0.08660253882408142f, 0.0f),
        Vec3(0.949999988079071f, 0.08660253882408142f, 0.0f),
        Vec3(0.949999988079071f, -0.08660253882408142f, 0.0f),
        Vec3(0.02679491974413395f, 0.0f, 0.0f), Vec3(0.9732050895690918f, 0.0f, 0.0f),
    ];
    static immutable uint[][] v6L1Faces = [
        [9u, 4u, 11u], [8u, 3u, 4u, 9u], [7u, 2u, 3u, 8u], [6u, 1u, 2u, 7u],
        [5u, 0u, 1u, 6u], [5u, 10u, 0u], [10u, 5u, 12u, 13u], [13u, 12u, 9u, 11u],
        [5u, 6u, 7u, 8u, 9u, 12u],
    ];
    static immutable Vec3[] v6L2Verts = [
        Vec3(0.5f, 0.8660253882408142f, 0.0f), Vec3(-0.5f, 0.8660253882408142f, 0.0f),
        Vec3(-1.0f, 1.22464685e-16f, 0.0f), Vec3(-0.5f, -0.8660253882408142f, 0.0f),
        Vec3(0.5f, -0.8660253882408142f, 0.0f),
        Vec3(0.05000000074505806f, 0.08660253882408142f, 0.0f),
        Vec3(-0.05000000074505806f, 0.08660253882408142f, 0.0f),
        Vec3(-0.10000000149011612f, 1.22464685e-17f, 0.0f),
        Vec3(-0.05000000074505806f, -0.08660253882408142f, 0.0f),
        Vec3(0.05000000074505806f, -0.08660253882408142f, 0.0f),
        Vec3(0.949999988079071f, 0.08660253882408142f, 0.0f),
        Vec3(0.949999988079071f, -0.08660253882408142f, 0.0f),
        Vec3(0.032696738839149475f, 0.04482877254486084f, 0.0f),
        Vec3(0.9673032760620117f, 0.04482877254486084f, 0.0f),
        Vec3(0.02679491974413395f, 0.0f, 0.0f), Vec3(0.9732050895690918f, 0.0f, 0.0f),
        Vec3(0.032696738839149475f, -0.04482877254486084f, 0.0f),
        Vec3(0.9673032760620117f, -0.04482877254486084f, 0.0f),
    ];
    static immutable uint[][] v6L2Faces = [
        [9u, 4u, 11u], [8u, 3u, 4u, 9u], [7u, 2u, 3u, 8u], [6u, 1u, 2u, 7u],
        [5u, 0u, 1u, 6u], [5u, 10u, 0u], [10u, 5u, 12u, 13u], [13u, 12u, 14u, 15u],
        [15u, 14u, 16u, 17u], [17u, 16u, 9u, 11u], [5u, 6u, 7u, 8u, 9u, 16u, 14u, 12u],
    ];
    static immutable Vec3[] v6L3Verts = [
        Vec3(0.5f, 0.8660253882408142f, 0.0f), Vec3(-0.5f, 0.8660253882408142f, 0.0f),
        Vec3(-1.0f, 1.22464685e-16f, 0.0f), Vec3(-0.5f, -0.8660253882408142f, 0.0f),
        Vec3(0.5f, -0.8660253882408142f, 0.0f),
        Vec3(0.05000000074505806f, 0.08660253882408142f, 0.0f),
        Vec3(-0.05000000074505806f, 0.08660253882408142f, 0.0f),
        Vec3(-0.10000000149011612f, 1.22464685e-17f, 0.0f),
        Vec3(-0.05000000074505806f, -0.08660253882408142f, 0.0f),
        Vec3(0.05000000074505806f, -0.08660253882408142f, 0.0f),
        Vec3(0.949999988079071f, 0.08660253882408142f, 0.0f),
        Vec3(0.949999988079071f, -0.08660253882408142f, 0.0f),
        Vec3(0.037240464240312576f, 0.05923962593078613f, 0.0f),
        Vec3(0.9627594947814941f, 0.05923962593078613f, 0.0f),
        Vec3(0.029426293447613716f, 0.03007674589753151f, 0.0f),
        Vec3(0.9705737233161926f, 0.03007674589753151f, 0.0f),
        Vec3(0.02679491974413395f, 0.0f, 0.0f), Vec3(0.9732050895690918f, 0.0f, 0.0f),
        Vec3(0.029426293447613716f, -0.03007674589753151f, 0.0f),
        Vec3(0.9705737233161926f, -0.03007674589753151f, 0.0f),
        Vec3(0.037240464240312576f, -0.05923962593078613f, 0.0f),
        Vec3(0.9627594947814941f, -0.05923962593078613f, 0.0f),
    ];
    static immutable uint[][] v6L3Faces = [
        [9u, 4u, 11u], [8u, 3u, 4u, 9u], [7u, 2u, 3u, 8u], [6u, 1u, 2u, 7u],
        [5u, 0u, 1u, 6u], [5u, 10u, 0u], [10u, 5u, 12u, 13u], [13u, 12u, 14u, 15u],
        [15u, 14u, 16u, 17u], [17u, 16u, 18u, 19u], [19u, 18u, 20u, 21u],
        [21u, 20u, 9u, 11u], [5u, 6u, 7u, 8u, 9u, 20u, 18u, 16u, 14u, 12u],
    ];
    const(Vec3[])[3]   wantVertsByLevel = [v6L1Verts, v6L2Verts, v6L3Verts];
    const(uint[][])[3] wantFacesByLevel = [v6L1Faces, v6L2Faces, v6L3Faces];
    foreach (level; 1 .. 4) {
        auto m = makeDisk(6);
        int ei = findEdge(m, 0, 1);
        assert(ei >= 0);
        bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 1);
        assertFacesMatchByPosition(m, wantVertsByLevel[level - 1], wantFacesByLevel[level - 1],
            "F1b disk N=6 hub-R0 L" ~ level.to!string);
        assertBevelManifoldCleanOpen(m, "F1b disk N=6 hub-R0", 1);
    }
}

unittest { // F1c: K=1 free end at Round Level, NON-PLANAR valence-4 "tent"
           // fan (asymmetric Z-tilts), L1-L3. The single most valuable F1
           // sub-case: the only family here where the law is confirmed on
           // genuinely non-flat 3D geometry with no antipodal degeneracy
           // (contrast F2 below, same valence but planar-antipodal).
    import std.conv : to;
    Mesh makeTent() {
        Mesh m;
        m.vertices = [
            Vec3(0, 0, 0),
            Vec3(1.0f, 0.0f, 0.35f),
            Vec3(6.123234e-17f, 1.0f, -0.2f),
            Vec3(-1.0f, 1.2246468e-16f, 0.15f),
            Vec3(-1.8369702e-16f, -1.0f, -0.3f),
        ];
        m.addFace([0u, 1u, 2u]); m.addFace([0u, 2u, 3u]);
        m.addFace([0u, 3u, 4u]); m.addFace([0u, 4u, 1u]);
        m.buildLoops();
        m.syncSelection();
        return m;
    }
    static immutable Vec3[] tentL1Verts = [
        Vec3(6.12323426e-17f, 1.0f, -0.20000000298023224f),
        Vec3(-1.0f, 1.22464685e-16f, 0.15000000596046448f),
        Vec3(-1.83697015e-16f, -1.0f, -0.30000001192092896f),
        Vec3(6.00432498e-18f, 0.0980580672621727f, -0.01961161382496357f),
        Vec3(-0.09889363497495651f, 1.2110978e-17f, 0.014834045432507992f),
        Vec3(-1.75949836e-17f, -0.09578263014554977f, -0.028734790161252022f),
        Vec3(0.9340977668762207f, 0.0659022405743599f, 0.31375375390052795f),
        Vec3(0.9357507228851318f, -0.06424925476312637f, 0.3082379698753357f),
        Vec3(-2.94137919e-18f, 0.0005774405435658991f, -0.01226893998682499f),
        Vec3(0.9605934619903564f, 0.0005004822742193937f, 0.3263810873031616f),
    ];
    static immutable uint[][] tentL1Faces = [
        [5u, 2u, 7u], [4u, 1u, 2u, 5u], [3u, 0u, 1u, 4u], [3u, 6u, 0u],
        [6u, 3u, 8u, 9u], [9u, 8u, 5u, 7u], [3u, 4u, 5u, 8u],
    ];
    static immutable Vec3[] tentL2Verts = [
        Vec3(6.12323426e-17f, 1.0f, -0.20000000298023224f),
        Vec3(-1.0f, 1.22464685e-16f, 0.15000000596046448f),
        Vec3(-1.83697015e-16f, -1.0f, -0.30000001192092896f),
        Vec3(6.00432498e-18f, 0.0980580672621727f, -0.01961161382496357f),
        Vec3(-0.09889363497495651f, 1.2110978e-17f, 0.014834045432507992f),
        Vec3(-1.75949836e-17f, -0.09578263014554977f, -0.028734790161252022f),
        Vec3(0.9340977668762207f, 0.0659022405743599f, 0.31375375390052795f),
        Vec3(0.9357507228851318f, -0.06424925476312637f, 0.3082379698753357f),
        Vec3(2.28662562e-18f, 0.0495423749089241f, -0.012958211824297905f),
        Vec3(0.9534143209457397f, 0.03639378026127815f, 0.3238682746887207f),
        Vec3(-2.94137919e-18f, 0.0005774405435658991f, -0.01226893998682499f),
        Vec3(0.9605934619903564f, 0.0005004822742193937f, 0.3263810873031616f),
        Vec3(-9.60170079e-18f, -0.04810630902647972f, -0.017554080113768578f),
        Vec3(0.9543238878250122f, -0.03522201254963875f, 0.3208332061767578f),
    ];
    static immutable uint[][] tentL2Faces = [
        [5u, 2u, 7u], [4u, 1u, 2u, 5u], [3u, 0u, 1u, 4u], [3u, 6u, 0u],
        [6u, 3u, 8u, 9u], [9u, 8u, 10u, 11u], [11u, 10u, 12u, 13u],
        [13u, 12u, 5u, 7u], [3u, 4u, 5u, 12u, 10u, 8u],
    ];
    static immutable Vec3[] tentL3Verts = [
        Vec3(6.12323426e-17f, 1.0f, -0.20000000298023224f),
        Vec3(-1.0f, 1.22464685e-16f, 0.15000000596046448f),
        Vec3(-1.83697015e-16f, -1.0f, -0.30000001192092896f),
        Vec3(6.00432498e-18f, 0.0980580672621727f, -0.01961161382496357f),
        Vec3(-0.09889363497495651f, 1.2110978e-17f, 0.014834045432507992f),
        Vec3(-1.75949836e-17f, -0.09578263014554977f, -0.028734790161252022f),
        Vec3(0.9340977668762207f, 0.0659022405743599f, 0.31375375390052795f),
        Vec3(0.9357507228851318f, -0.06424925476312637f, 0.3082379698753357f),
        Vec3(3.69688192e-18f, 0.06580017507076263f, -0.014516410417854786f),
        Vec3(0.9481908082962036f, 0.04724028334021568f, 0.3212765157222748f),
        Vec3(7.08371524e-19f, 0.0332346111536026f, -0.012063427828252316f),
        Vec3(0.9572705030441284f, 0.024828020483255386f, 0.3256036937236786f),
        Vec3(-2.94137919e-18f, 0.0005774405435658991f, -0.01226893998682499f),
        Vec3(0.9605934619903564f, 0.0005004822742193937f, 0.3263810873031616f),
        Vec3(-7.22815566e-18f, -0.03195466846227646f, -0.01513158343732357f),
        Vec3(0.9578874707221985f, -0.023750487715005875f, 0.323544979095459f),
        Vec3(-1.21235164e-17f, -0.06414588540792465f, -0.020632365718483925f),
        Vec3(0.949374258518219f, -0.045939311385154724f, 0.3173275887966156f),
    ];
    static immutable uint[][] tentL3Faces = [
        [5u, 2u, 7u], [4u, 1u, 2u, 5u], [3u, 0u, 1u, 4u], [3u, 6u, 0u],
        [6u, 3u, 8u, 9u], [9u, 8u, 10u, 11u], [11u, 10u, 12u, 13u],
        [13u, 12u, 14u, 15u], [15u, 14u, 16u, 17u], [17u, 16u, 5u, 7u],
        [3u, 4u, 5u, 16u, 14u, 12u, 10u, 8u],
    ];
    const(Vec3[])[3]   wantVertsByLevel = [tentL1Verts, tentL2Verts, tentL3Verts];
    const(uint[][])[3] wantFacesByLevel = [tentL1Faces, tentL2Faces, tentL3Faces];
    foreach (level; 1 .. 4) {
        auto m = makeTent();
        int ei = findEdge(m, 0, 1);
        assert(ei >= 0);
        bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 1);
        assertFacesMatchByPosition(m, wantVertsByLevel[level - 1], wantFacesByLevel[level - 1],
            "F1c non-planar valence-4 tent L" ~ level.to!string);
        assertBevelManifoldCleanOpen(m, "F1c non-planar valence-4 tent", 1);
    }
}

unittest { // F1d: F1's own regression bar EXTENDED to `MAX_ROUND_LEVEL`
           // (task 0449 test-plan requirement: "F1 must run at
           // MAX_ROUND_LEVEL, not only L3"). No reference dump exists at
           // this depth (the plan's own captures stop at L3) — this is a
           // scale/DoS-clamp sanity check, not a position-parity fixture:
           // the cap ring now participates in Round Level, so its own
           // growth (`(N-K) + K*(2L-1)`, still linear in the ALREADY-
           // clamped `L` per the two-layer DoS clamp at `MAX_ROUND_LEVEL`)
           // must not blow past a bounded count or leave the mesh unsound
           // at the clamp boundary either.
    import std.math : cos, sin, PI;
    auto m = makeDisk(5);
    int ei = findEdge(m, 0, 1);
    assert(ei >= 0);
    bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
    assert(m.bevelEdgesByMask(mask, 0.1f, MAX_ROUND_LEVEL) == 1);
    // Measured (not derived from the ring-growth formula alone, which only
    // bounds the cap ring's own corner count, not the whole mesh's):
    // MAX_ROUND_LEVEL=10 gives 48v/26f for this disk. Pinned exactly so any
    // future change to this path shows up here, not just as an allocation
    // blowup caught by a looser bound.
    assert(m.vertices.length == 48 && m.faces.length == 26,
        "F1d disk N=5 hub-R0 at MAX_ROUND_LEVEL golden must be 48v/26f");
    assertBevelManifoldCleanOpen(m, "F1d disk N=5 hub-R0 at MAX_ROUND_LEVEL", 1);
}

unittest { // F2: K=1 free end, valence-4 fan, PLANAR (all rim verts at
           // z=0) — the antipodal-fillet degeneracy: the hub's two ring-
           // neighbours of the selected slot sit exactly opposite each other,
           // so `railInterior`'s `sinO < 1e-6` fallback fires and the "arc" is
           // a straight chord. This is the PLANAR / far-a-free-end cell of the
           // measured 2×2 that pins bevelEdgesByMask's Decision-C free-end cap
           // (planar OR far-full-hub ⇒ the reference keeps the raw free-end
           // vertex in its cap ring). The reference substitutes the ring's
           // opposite unselected slot with the RAW hub position (0,0,0) and
           // separately (unpooled) computes its own degenerate rail interior,
           // which lands on that SAME position — TWO distinct vertex records at
           // one spot (a coincident pair) — and leaves the plain slide
           // (-0.1,0,0) that used to fill that slot as an ORPHAN referenced by
           // no face. vibe3d now REPRODUCES this exactly: the frozen arrays
           // below are the reference cap (positions + winding), and the
           // coincident-pair / orphan residual — a documented XFAIL before this
           // task — is asserted as a HARD requirement at every Round Level.
    import std.math : cos, sin, PI;
    import std.conv : to;
    // Reproduced reference cap ("Decision C"). Index 0 is the RETAINED raw
    // free-end vertex (0,0,0); the chamfer pinch lands on the same spot (a
    // coincident pair); the (-0.1,0,0) opposite-edge slide is the intended
    // ORPHAN (present, referenced by no face — assertFacesMatchByPosition
    // compares the full position MULTISET, so both the pair and the orphan
    // are pinned).
    static immutable Vec3[] v4L1Verts = [
        Vec3(0f, 0f, 0f),
        Vec3(-4.37113883e-08f, 1f, 0f), Vec3(-1f, -8.74227766e-08f, 0f),
        Vec3(1.19248806e-08f, -1f, 0f), Vec3(-4.37113901e-09f, 0.100000001f, 0f),
        Vec3(1.19248811e-09f, -0.100000001f, 0f), Vec3(-0.100000001f, -8.74227801e-09f, 0f),
        Vec3(0.929289341f, 0.0707106814f, 0f), Vec3(0.929289341f, -0.0707106814f, 0f),
        Vec3(-1.58932545e-09f, 0f, 0f), Vec3(0.958578706f, 0f, 0f),
    ];
    static immutable uint[][] v4L1Faces = [
        [4u, 7u, 1u], [0u, 4u, 1u, 2u], [5u, 0u, 2u, 3u], [5u, 3u, 8u],
        [5u, 8u, 10u, 9u], [9u, 10u, 7u, 4u], [5u, 0u, 4u, 9u],
    ];
    static immutable Vec3[] v4L2Verts = [
        Vec3(0f, 0f, 0f),
        Vec3(-4.37113883e-08f, 1f, 0f), Vec3(-1f, -8.74227766e-08f, 0f),
        Vec3(1.19248806e-08f, -1f, 0f), Vec3(-4.37113901e-09f, 0.100000001f, 0f),
        Vec3(1.19248811e-09f, -0.100000001f, 0f), Vec3(-0.100000001f, -8.74227801e-09f, 0f),
        Vec3(0.929289341f, 0.0707106814f, 0f), Vec3(0.929289341f, -0.0707106814f, 0f),
        Vec3(-2.98023228e-09f, 0.0500000045f, 0f), Vec3(-1.58932545e-09f, 0f, 0f),
        Vec3(-1.9841867e-10f, -0.0500000045f, 0f), Vec3(0.950966597f, 0.0382683501f, 0f),
        Vec3(0.958578706f, 0f, 0f), Vec3(0.950966597f, -0.0382683501f, 0f),
    ];
    static immutable uint[][] v4L2Faces = [
        [4u, 7u, 1u], [0u, 4u, 1u, 2u], [5u, 0u, 2u, 3u], [5u, 3u, 8u],
        [5u, 8u, 14u, 11u], [11u, 14u, 13u, 10u], [10u, 13u, 12u, 9u],
        [9u, 12u, 7u, 4u], [5u, 0u, 4u, 9u, 10u, 11u],
    ];
    static immutable Vec3[] v4L3Verts = [
        Vec3(0f, 0f, 0f),
        Vec3(-4.37113883e-08f, 1f, 0f), Vec3(-1f, -8.74227766e-08f, 0f),
        Vec3(1.19248806e-08f, -1f, 0f), Vec3(-4.37113901e-09f, 0.100000001f, 0f),
        Vec3(1.19248811e-09f, -0.100000001f, 0f), Vec3(-0.100000001f, -8.74227801e-09f, 0f),
        Vec3(0.929289341f, 0.0707106814f, 0f), Vec3(0.929289341f, -0.0707106814f, 0f),
        Vec3(-3.44386786e-09f, 0.0666666701f, 0f), Vec3(-2.51659649e-09f, 0.0333333276f, 0f),
        Vec3(-1.58932545e-09f, 0f, 0f), Vec3(-6.62054189e-10f, -0.0333333388f, 0f),
        Vec3(2.65216848e-10f, -0.0666666627f, 0f), Vec3(0.945181191f, 0.0500000007f, 0f),
        Vec3(0.955171227f, 0.0258819051f, 0f), Vec3(0.958578706f, 0f, 0f),
        Vec3(0.955171227f, -0.0258819126f, 0f), Vec3(0.945181191f, -0.0500000007f, 0f),
    ];
    static immutable uint[][] v4L3Faces = [
        [4u, 7u, 1u], [0u, 4u, 1u, 2u], [5u, 0u, 2u, 3u], [5u, 3u, 8u],
        [5u, 8u, 18u, 13u], [13u, 18u, 17u, 12u], [12u, 17u, 16u, 11u],
        [11u, 16u, 15u, 10u], [10u, 15u, 14u, 9u], [9u, 14u, 7u, 4u],
        [5u, 0u, 4u, 9u, 10u, 11u, 12u, 13u],
    ];
    const(Vec3[])[3]   wantVertsByLevel = [v4L1Verts, v4L2Verts, v4L3Verts];
    const(uint[][])[3] wantFacesByLevel = [v4L1Faces, v4L2Faces, v4L3Faces];
    // Decision C's two artefacts, HARD-asserted at every level (was a
    // documented XFAIL residual before this task): a coincident PAIR at the
    // retained free-end position, and the opposite-edge slide kept as an
    // ORPHAN referenced by no face.
    static immutable Vec3 hubPos    = Vec3(0.0f, 0.0f, 0.0f);
    static immutable Vec3 orphanPos = Vec3(-0.1f, 0.0f, 0.0f);
    foreach (level; 1 .. 4) {
        auto m = makeDisk(4);
        int ei = findEdge(m, 0, 1);
        assert(ei >= 0);
        bool[] mask; mask.length = m.edges.length; mask[] = false; mask[ei] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 1);
        assertFacesMatchByPosition(m, wantVertsByLevel[level - 1], wantFacesByLevel[level - 1],
            "F2 disk N=4 antipodal hub-R0 L" ~ level.to!string);
        size_t atHub = 0, atOrphan = 0;
        foreach (v; m.vertices) {
            if ((v - hubPos).length    < 1e-4f) ++atHub;
            if ((v - orphanPos).length < 1e-4f) ++atOrphan;
        }
        assert(atHub == 2,
            "F2 L" ~ level.to!string ~ ": reference keeps a COINCIDENT PAIR at the free-end (0,0,0)");
        assert(atOrphan == 1,
            "F2 L" ~ level.to!string ~ ": the opposite-edge slide (-0.1,0,0) is retained (reference orphan)");
        bool[] used; used.length = m.vertices.length;
        foreach (f; m.faces) foreach (vi; f) used[vi] = true;
        bool orphanUnref = false;
        foreach (vi, v; m.vertices)
            if ((v - orphanPos).length < 1e-4f && !used[vi]) orphanUnref = true;
        assert(orphanUnref,
            "F2 L" ~ level.to!string ~ ": the (-0.1,0,0) slide must be an ORPHAN — referenced by NO face");
        assertBevelManifoldCleanOpen(m, "F2 disk N=4 antipodal hub-R0", 1);
    }
}

unittest { // F3: K>=2 notch cap interior, disks N=5 gap(1,2) and N=6
           // gap(1,3), L1-L3.
           //   • N=5 gap(1,2) — the NARROW notch: CLOSED bit-exact (parity
           //     task). The triangle cap is tessellated into a (2·L)×(2·L)
           //     grid whose base edge is a circular arc about the source
           //     vertex and whose interior is a recursive circular fillet
           //     pivoted at the apex corner. Asserted as a full set-equality
           //     against the reference dump at EVERY level (both directions:
           //     nothing emitted is off-reference, nothing on-reference is
           //     missing) — not just a subset.
           //   • N=6 gap(1,3) — the WIDE notch: still a SUBSET fixture. Its
           //     count law + base-gap CHORD subdivision are decoded, but the
           //     interior grid's central points route through an undecoded
           //     reference (Gregory hub) builder, so we leave that cap FLAT:
           //     every vertex we emit still matches SOME reference position
           //     bit-exact, but our result stays a strict subset. Counts pin
           //     the KNOWN incompleteness exactly.
    import std.math : cos, sin, PI;
    import std.conv : to;
    bool everyVertexMatchesSomeReference(ref Mesh m, const Vec3[] refPositions) {
        foreach (v; m.vertices) {
            bool ok = false;
            foreach (r; refPositions) if ((v - r).length < 1e-4f) { ok = true; break; }
            if (!ok) return false;
        }
        return true;
    }
    // Full set-equality: every emitted vertex is on-reference AND every
    // reference position is emitted. Combined with an exact count assert this
    // is a bit-exact reproduction of the dump's used-vertex SET.
    bool vertexSetEqualsReference(ref Mesh m, const Vec3[] refPositions) {
        if (!everyVertexMatchesSomeReference(m, refPositions)) return false;
        foreach (r; refPositions) {
            bool ok = false;
            foreach (v; m.vertices) if ((v - r).length < 1e-4f) { ok = true; break; }
            if (!ok) return false;
        }
        return true;
    }

    // N=5 gap(1,2) — NARROW notch, CLOSED bit-exact (parity task). Full
    // reference counts (16v/13f, 34v/29f, 60v/53f) and full set-equality vs
    // the reference dump at every level.
    {
        static immutable size_t[3] wantV = [16, 34, 60];
        static immutable size_t[3] wantF = [13, 29, 53];
        static immutable Vec3[] refV5L1 = [
            Vec3(0.30901700258255005f, 0.9510565400123596f, 0.0f),
            Vec3(-0.80901700258255f, -0.5877852439880371f, 0.0f),
            Vec3(0.30901700258255005f, -0.9510565400123596f, 0.0f),
            Vec3(0.030901700258255005f, 0.09510564804077148f, 0.0f),
            Vec3(-0.08090169727802277f, -0.05877852439880371f, 0.0f),
            Vec3(0.030901700258255005f, -0.09510564804077148f, 0.0f),
            Vec3(0.9412214756011963f, 0.08090169727802277f, 0.0f),
            Vec3(0.9412214756011963f, -0.08090169727802277f, 0.0f),
            Vec3(-0.80901700258255f, 0.4877852499485016f, 0.0f),
            Vec3(-0.7139113545417786f, 0.6186869740486145f, 0.0f),
            Vec3(0.015838444232940674f, 0.0f, 0.0f),
            Vec3(0.9675080180168152f, 0.0f, 0.0f),
            Vec3(-0.7827304601669312f, 0.5686869621276855f, 0.0f),
            Vec3(-0.01281356904655695f, 0.009309601970016956f, 0.0f),
            Vec3(-0.030901696532964706f, -0.09510564804077148f, 0.0f),
            Vec3(0.001146096852608025f, 0.0035273197572678328f, 0.0f),
        ];
        static immutable Vec3[] refV5L2 = [
            Vec3(0.30901700258255005f, 0.9510565400123596f, 0.0f),
            Vec3(-0.80901700258255f, -0.5877852439880371f, 0.0f),
            Vec3(0.30901700258255005f, -0.9510565400123596f, 0.0f),
            Vec3(0.030901700258255005f, 0.09510564804077148f, 0.0f),
            Vec3(-0.08090169727802277f, -0.05877852439880371f, 0.0f),
            Vec3(0.030901700258255005f, -0.09510564804077148f, 0.0f),
            Vec3(0.9412214756011963f, 0.08090169727802277f, 0.0f),
            Vec3(0.9412214756011963f, -0.08090169727802277f, 0.0f),
            Vec3(-0.80901700258255f, 0.4877852499485016f, 0.0f),
            Vec3(-0.7139113545417786f, 0.6186869740486145f, 0.0f),
            Vec3(0.019627584144473076f, 0.04814557731151581f, 0.0f),
            Vec3(0.9607715606689453f, 0.0425325408577919f, 0.0f),
            Vec3(0.015838444232940674f, 0.0f, 0.0f),
            Vec3(0.9675080180168152f, 0.0f, 0.0f),
            Vec3(0.019627584144473076f, -0.04814557731151581f, 0.0f),
            Vec3(0.9607715606689453f, -0.0425325408577919f, 0.0f),
            Vec3(-0.7522805333137512f, 0.5991368889808655f, 0.0f),
            Vec3(0.012420213781297207f, 0.05048739165067673f, 0.0f),
            Vec3(-0.7827304601669312f, 0.5686869621276855f, 0.0f),
            Vec3(-0.01281356904655695f, 0.009309601970016956f, 0.0f),
            Vec3(-0.8022804856300354f, 0.5303177833557129f, 0.0f),
            Vec3(-0.044178307056427f, -0.027413787320256233f, 0.0f),
            Vec3(-0.05877852439880371f, -0.08090169727802277f, 0.0f),
            Vec3(-0.030901696532964706f, -0.09510564804077148f, 0.0f),
            Vec3(1.566544893805144e-09f, -0.09999999403953552f, 0.0f),
            Vec3(0.0028683547861874104f, -0.04582749679684639f, 0.0f),
            Vec3(-0.013502245768904686f, -0.04155564308166504f, 0.0f),
            Vec3(-0.02925727143883705f, -0.0353892482817173f, 0.0f),
            Vec3(0.008422976359724998f, 0.001475027995184064f, 0.0f),
            Vec3(0.001146096852608025f, 0.0035273197572678328f, 0.0f),
            Vec3(-0.005947329103946686f, 0.006144222337752581f, 0.0f),
            Vec3(0.017792632803320885f, 0.04862440004944801f, 0.0f),
            Vec3(0.015977893024683f, 0.04917489364743233f, 0.0f),
            Vec3(0.014186167158186436f, 0.049796212464571f, 0.0f),
        ];
        static immutable Vec3[] refV5L3 = [
            Vec3(0.30901700258255005f, 0.9510565400123596f, 0.0f),
            Vec3(-0.80901700258255f, -0.5877852439880371f, 0.0f),
            Vec3(0.30901700258255005f, -0.9510565400123596f, 0.0f),
            Vec3(0.030901700258255005f, 0.09510564804077148f, 0.0f),
            Vec3(-0.08090169727802277f, -0.05877852439880371f, 0.0f),
            Vec3(0.030901700258255005f, -0.09510564804077148f, 0.0f),
            Vec3(0.9412214756011963f, 0.08090169727802277f, 0.0f),
            Vec3(0.9412214756011963f, -0.08090169727802277f, 0.0f),
            Vec3(-0.80901700258255f, 0.4877852499485016f, 0.0f),
            Vec3(-0.7139113545417786f, 0.6186869740486145f, 0.0f),
            Vec3(0.02256392128765583f, 0.06398863345384598f, 0.0f),
            Vec3(0.955608606338501f, 0.055982496589422226f, 0.0f),
            Vec3(0.01752443239092827f, 0.032170552760362625f, 0.0f),
            Vec3(0.9645003080368042f, 0.028616588562726974f, 0.0f),
            Vec3(0.015838444232940674f, 0.0f, 0.0f),
            Vec3(0.9675080180168152f, 0.0f, 0.0f),
            Vec3(0.01752443239092827f, -0.032170552760362625f, 0.0f),
            Vec3(0.9645003080368042f, -0.028616588562726974f, 0.0f),
            Vec3(0.02256392128765583f, -0.06398863345384598f, 0.0f),
            Vec3(0.955608606338501f, -0.055982496589422226f, 0.0f),
            Vec3(-0.7401978969573975f, 0.6069834232330322f, 0.0f),
            Vec3(0.01935698464512825f, 0.06503063440322876f, 0.0f),
            Vec3(-0.7634767293930054f, 0.590070366859436f, 0.0f),
            Vec3(0.004731815308332443f, 0.03632712364196777f, 0.0f),
            Vec3(-0.7827304601669312f, 0.5686869621276855f, 0.0f),
            Vec3(-0.01281356904655695f, 0.009309601970016956f, 0.0f),
            Vec3(-0.7971175312995911f, 0.5437677502632141f, 0.0f),
            Vec3(-0.03308693692088127f, -0.01572592183947563f, 0.0f),
            Vec3(-0.8060092926025391f, 0.5164018273353577f, 0.0f),
            Vec3(-0.055866170674562454f, -0.038505155593156815f, 0.0f),
            Vec3(-0.06691306084394455f, -0.07431448251008987f, 0.0f),
            Vec3(-0.04999999701976776f, -0.08660253882408142f, 0.0f),
            Vec3(-0.030901696532964706f, -0.09510564804077148f, 0.0f),
            Vec3(-0.010452844202518463f, -0.0994521901011467f, 0.0f),
            Vec3(0.010452847927808762f, -0.0994521826505661f, 0.0f),
            Vec3(0.008729668334126472f, -0.06265654414892197f, 0.0f),
            Vec3(-0.004935841076076031f, -0.06012379378080368f, 0.0f),
            Vec3(-0.018328607082366943f, -0.05640965327620506f, 0.0f),
            Vec3(-0.031346697360277176f, -0.05154239013791084f, 0.0f),
            Vec3(-0.04389104247093201f, -0.04555904492735863f, 0.0f),
            Vec3(0.00867867935448885f, -0.03092736378312111f, 0.0f),
            Vec3(-5.880459139007144e-05f, -0.029070153832435608f, 0.0f),
            Vec3(-0.008645452558994293f, -0.026607971638441086f, 0.0f),
            Vec3(-0.017039431259036064f, -0.02355281449854374f, 0.0f),
            Vec3(-0.02519984357059002f, -0.019919563084840775f, 0.0f),
            Vec3(0.010881642811000347f, 0.0009186886018142104f, 0.0f),
            Vec3(0.005979715380817652f, 0.0020955370273441076f, 0.0f),
            Vec3(0.001146096852608025f, 0.0035273197572678328f, 0.0f),
            Vec3(-0.0036059634294360876f, 0.005210112314671278f, 0.0f),
            Vec3(-0.008263440802693367f, 0.00713930232450366f, 0.0f),
            Vec3(0.015336178243160248f, 0.03267575055360794f, 0.0f),
            Vec3(0.013166888616979122f, 0.03325701132416725f, 0.0f),
            Vec3(0.011019205674529076f, 0.03391362354159355f, 0.0f),
            Vec3(0.008895746432244778f, 0.03464478626847267f, 0.0f),
            Vec3(0.00679909810423851f, 0.03544961288571358f, 0.0f),
            Vec3(0.022022124379873276f, 0.06413888931274414f, 0.0f),
            Vec3(0.021483032032847404f, 0.06429857760667801f, 0.0f),
            Vec3(0.020946810021996498f, 0.0644676461815834f, 0.0f),
            Vec3(0.02041362039744854f, 0.06464605033397675f, 0.0f),
            Vec3(0.019883623346686363f, 0.06483373045921326f, 0.0f),
        ];
        static immutable(Vec3[])[3] refV5 = [refV5L1, refV5L2, refV5L3];
        foreach (level; 1 .. 4) {
            auto m = makeDisk(5);
            bool[] mask; mask.length = m.edges.length; mask[] = false;
            foreach (pair; [[0u, 1u], [0u, 3u]]) mask[findEdge(m, pair[0], pair[1])] = true;
            assert(m.bevelEdgesByMask(mask, 0.1f, level) == 2);
            assert(m.vertices.length == wantV[level - 1] && m.faces.length == wantF[level - 1],
                "F3 disk N=5 gap(1,2) L" ~ level.to!string ~ " count mismatch");
            // Bit-exact SET equality at every level: the narrow-notch cap
            // interior is fully decoded (base-gap arc + recursive apex fillet).
            assert(vertexSetEqualsReference(m, refV5[level - 1]),
                "F3 disk N=5 gap(1,2) L" ~ level.to!string
                ~ ": emitted vertex set must equal the reference dump bit-exact");
            assertBevelManifoldCleanOpen(m, "F3 disk N=5 gap(1,2)", 1);
        }
    }

    // N=6 gap(1,3) — WIDE notch: still SUBSET, cap left FLAT (parity task).
    // Our counts 16v/11f, 24v/15f, 32v/19f (a strict subset of the reference's
    // 19/14, 39/30, 67/54). The count law + the base-gap CHORD subdivision law
    // (the reference's v16/v17 — a width-3 gap's f_gap>=2 chords, not an arc)
    // ARE decoded, but the interior grid's central (2L-1)^2 point(s) route
    // through a different reference builder (an N-sided Gregory hub patch) whose
    // pole/boundary-curve mapping is not yet decoded — position-fit alone fails
    // by ~0.003 (transfinite Coons) to ~0.08 (every arc/slerp candidate),
    // above the ~1e-6 float floor, so we do NOT emit a placeholder we can't
    // verify. This cap therefore stays flat until a narrow rr/gdb follow-up
    // pins the Gregory argument setup for the K=2 wide-gap case. The narrow
    // (N=5) cap above IS fully closed; the two differ because the wide gap's
    // base is a polyline (>=2 chords) rather than a single arc edge.
    {
        static immutable size_t[3] wantV = [16, 24, 32];
        static immutable size_t[3] wantF = [11, 15, 19];
        static immutable Vec3[] refL1 = [
            Vec3(0.5f, 0.8660253882408142f, 0.0f),
            Vec3(-1.0f, 1.22464685e-16f, 0.0f),
            Vec3(-0.5f, -0.8660253882408142f, 0.0f),
            Vec3(0.5f, -0.8660253882408142f, 0.0f),
            Vec3(0.05000000074505806f, 0.08660253882408142f, 0.0f),
            Vec3(-0.10000000149011612f, 1.22464685e-17f, 0.0f),
            Vec3(-0.05000000074505806f, -0.08660253882408142f, 0.0f),
            Vec3(0.05000000074505806f, -0.08660253882408142f, 0.0f),
            Vec3(0.949999988079071f, 0.08660253882408142f, 0.0f),
            Vec3(0.949999988079071f, -0.08660253882408142f, 0.0f),
            Vec3(-0.550000011920929f, 0.7794228196144104f, 0.0f),
            Vec3(-0.4000000059604645f, 0.8660253882408142f, 0.0f),
            Vec3(0.02679491974413395f, 0.0f, 0.0f),
            Vec3(0.9732050895690918f, 0.0f, 0.0f),
            Vec3(-0.4866025447845459f, 0.8428202867507935f, 0.0f),
            Vec3(-0.013397459872066975f, 0.02320507913827896f, 0.0f),
            Vec3(-0.07500000298023224f, -0.04330126941204071f, 0.0f),
            Vec3(0.0f, -0.08660253882408142f, 0.0f),
            Vec3(-0.017991282045841217f, -0.03116181306540966f, 0.0f),
        ];
        foreach (level; 1 .. 4) {
            auto m = makeDisk(6);
            bool[] mask; mask.length = m.edges.length; mask[] = false;
            foreach (pair; [[0u, 1u], [0u, 3u]]) mask[findEdge(m, pair[0], pair[1])] = true;
            assert(m.bevelEdgesByMask(mask, 0.1f, level) == 2);
            assert(m.vertices.length == wantV[level - 1] && m.faces.length == wantF[level - 1],
                "F3 disk N=6 gap(1,3) L" ~ level.to!string ~ " count mismatch");
            if (level == 1)
                assert(everyVertexMatchesSomeReference(m, refL1),
                    "F3 disk N=6 gap(1,3) L1: emitted a position not in the reference dump — "
                    ~ "our output must stay a STRICT SUBSET of the reference's used vertices");
            assertBevelManifoldCleanOpen(m, "F3 disk N=6 gap(1,3)", 1);
        }
    }
}

unittest { // F4: composition on a REAL user-shaped mesh — a K3 hub (K ==
           // valence == 3) with its 3 far endpoints each an independent
           // valence-4 free end, on the same 26v/24f LINEAR-split unit cube
           // (NOT `subdivideCube(1)`'s Catmull-Clark limit surface — that
           // has the same topology and thus the same vertex/face COUNTS,
           // but different smoothed POSITIONS, so it cannot stand in for a
           // position-comparison fixture) as the reference case. Each free
           // end is a NON-planar 90° edge-crease whose single selected edge
           // lands on the K3 corner — a FULL HUB — so this is the "non-planar
           // + far-full-hub" cell of the Decision-C 2×2, and all three free
           // ends now REPRODUCE the reference cap: the raw ORIGINAL free-end
           // vertex is RETAINED in its cap ring (was substituted-away by our
           // plain slide before this task), and our former slide is kept as an
           // ORPHAN — exactly the reference's own 3 extra slide points (task
           // 0449 Замер 1). L0 stays the reference's bit-exact 34v/31f (no
           // rounding ⇒ no Decision C). L1-L3 now match the reference's FULL
           // vertex COUNT (used + 3 orphans) and face count.
    import std.conv : to;
    static immutable Vec3[] baseVerts = [
        Vec3(0.5f, -0.5f, -0.5f), Vec3(0.5f, 0.5f, -0.5f), Vec3(0.5f, 0.5f, 0.5f),
        Vec3(0.5f, -0.5f, 0.5f), Vec3(0.5f, 0.0f, 0.0f), Vec3(0.5f, 0.0f, -0.5f),
        Vec3(0.5f, 0.5f, 0.0f), Vec3(0.5f, 0.0f, 0.5f), Vec3(0.5f, -0.5f, 0.0f),
        Vec3(-0.5f, -0.5f, 0.5f), Vec3(-0.5f, 0.5f, 0.5f), Vec3(-0.5f, 0.5f, -0.5f),
        Vec3(-0.5f, -0.5f, -0.5f), Vec3(-0.5f, 0.0f, 0.0f), Vec3(-0.5f, 0.0f, 0.5f),
        Vec3(-0.5f, 0.5f, 0.0f), Vec3(-0.5f, 0.0f, -0.5f), Vec3(-0.5f, -0.5f, 0.0f),
        Vec3(0.0f, 0.5f, 0.0f), Vec3(0.0f, 0.5f, 0.5f), Vec3(0.0f, 0.5f, -0.5f),
        Vec3(0.0f, -0.5f, 0.0f), Vec3(0.0f, -0.5f, -0.5f), Vec3(0.0f, -0.5f, 0.5f),
        Vec3(0.0f, 0.0f, 0.5f), Vec3(0.0f, 0.0f, -0.5f),
    ];
    static immutable uint[][] baseFaces = [
        [0u, 5u, 4u, 8u], [1u, 6u, 4u, 5u], [2u, 7u, 4u, 6u], [3u, 8u, 4u, 7u],
        [9u, 14u, 13u, 17u], [10u, 15u, 13u, 14u], [11u, 16u, 13u, 15u], [12u, 17u, 13u, 16u],
        [11u, 15u, 18u, 20u], [10u, 19u, 18u, 15u], [2u, 6u, 18u, 19u], [1u, 20u, 18u, 6u],
        [9u, 17u, 21u, 23u], [12u, 22u, 21u, 17u], [0u, 8u, 21u, 22u], [3u, 23u, 21u, 8u],
        [9u, 23u, 24u, 14u], [3u, 7u, 24u, 23u], [2u, 19u, 24u, 7u], [10u, 14u, 24u, 19u],
        [12u, 16u, 25u, 22u], [11u, 20u, 25u, 16u], [1u, 5u, 25u, 20u], [0u, 22u, 25u, 5u],
    ];
    // Fixture assembly note: this is `setup.vertices`/`setup.faces` of
    // `task0439fu_combined_subcube_corner_L1.json` (task 0449 plan §Фаза
    // 3), transcribed once, mechanically, for the whole F4 block — the SAME
    // 26v/24f LINEAR-split cube every level (L0-L3) selects on. Corner
    // vertex 2=(0.5,0.5,0.5); its 3 far endpoints are 6=(0.5,0.5,0.0),
    // 7=(0.5,0.0,0.5), 19=(0.0,0.5,0.5) — each a valence-4 free end (same
    // shape mesh.d's own K3-composition unittest exercises via
    // `subdivideCube(1)` for its count-only regression check — that
    // function's Catmull-Clark limit-surface smoothing gives the same
    // topology but different POSITIONS, so it cannot stand in here).
    static immutable Vec3[] diffCorners = [
        Vec3(0.5f, 0.5f, 0.0f), Vec3(0.5f, 0.0f, 0.5f), Vec3(0.0f, 0.5f, 0.5f),
    ];
    static immutable size_t[4] wantF4 = [31, 36, 51, 72];
    // L>=1 add +3 verts over the pre-task counts: the 3 retained free-end
    // originals (Decision C). L0 stays the reference's bit-exact 34v.
    static immutable size_t[4] wantV4 = [34, 44, 62, 86];
    bool positionIn(Vec3 v, const Vec3[] set) {
        foreach (p; set) if ((v - p).length < 1e-4f) return true;
        return false;
    }
    foreach (level; 0 .. 4) {
        Mesh m;
        m.vertices = baseVerts.dup;
        foreach (f; baseFaces) m.addFace(f.dup);
        m.buildLoops();
        m.syncSelection();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        foreach (far; [6u, 7u, 19u]) {
            foreach (i; 0 .. m.edges.length) {
                uint a = m.edges[i][0], b = m.edges[i][1];
                if ((a == 2 && b == far) || (a == far && b == 2)) { mask[i] = true; break; }
            }
        }
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 3);
        assert(m.faces.length == wantF4[level],
            "F4 combined K3+3-free-ends L" ~ level.to!string ~ " face count mismatch");
        assert(m.vertices.length == wantV4[level],
            "F4 combined K3+3-free-ends L" ~ level.to!string ~ " vertex count mismatch");
        // Count the 3 raw free-end original positions retained in the mesh.
        size_t diffCount = 0;
        foreach (v; m.vertices)
            if (positionIn(v, diffCorners)) ++diffCount;
        if (level == 0) {
            assert(diffCount == 0,
                "F4 L0: no rounding ⇒ no Decision C — the 3 free-end originals are cut away");
        } else {
            assert(diffCount == 3,
                "F4 L" ~ level.to!string ~ ": Decision C REPRODUCED — all 3 raw free-end "
                ~ "original positions retained in their cap rings");
        }
        assertBevelManifoldClean(m, "F4 combined K3+3-free-ends L" ~ level.to!string);
    }
}

unittest { // smoke test 7 (extrapolated zone, no reference dump): disk N=7,
           // K=3 at slots 0/2/4 (gaps 1/1/2) -> quad cap.
    import std.math : cos, sin, PI;
    auto m = makeDisk(7);
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[0u, 1u], [0u, 3u], [0u, 5u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 3);
    assert(m.vertices.length == 14 && m.faces.length == 11,
        "disk N=7 K=3 (gaps 1/1/2) must be 14v/11f");
    int[int] fvd; foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(4, 0) >= 1, "the free-end cap at ring=4 must include a quad");
    assertBevelManifoldCleanOpen(m, "disk N=7 K=3 smoke", 1);
}

unittest { // smoke test 8 (extrapolated zone, no reference dump): disk N=6,
           // K=2 ADJACENT (hub-R0, hub-R1) -> ring with a miter, pentagon cap.
           // This is the clean single-vertex form of the "K=2 adjacent"
           // pre-existing hole (see the adjacent-K2 octahedron test above,
           // which combines this same pattern with two more valence-4 K=1
           // free ends at its far endpoints).
    import std.math : cos, sin, PI;
    auto m = makeDisk(6);
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[0u, 1u], [0u, 2u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 2);
    assert(m.vertices.length == 13 && m.faces.length == 9,
        "disk N=6 K=2 adjacent must be 13v/9f");
    int[int] fvd; foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(5, 0) >= 1, "the miter-ring cap at ring=5 must include a pentagon");
    assertBevelManifoldCleanOpen(m, "disk N=6 K=2 adjacent smoke", 1);
}

unittest { // regression test 9: disk N=6, K=3 "every other" (hub-R0, hub-R2,
           // hub-R4) — a pre-existing hole on unpatched main (the guard
           // passed this shape through with no cap: ret=3, 12v/9f, χ=0).
           // Fixed to a triangle cap, χ=1, no non-manifold edge.
    import std.math : cos, sin, PI;
    auto m = makeDisk(6);
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[0u, 1u], [0u, 3u], [0u, 5u]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 3);
    assert(m.vertices.length == 12 && m.faces.length == 10,
        "disk N=6 K=3 every-other golden must be 12v/10f (was 12v/9f/hole on main)");
    int[int] fvd; foreach (f; m.faces) ++fvd[cast(int)f.length];
    assert(fvd.get(3, 0) >= 1, "the free-end cap at ring=3 must include a triangle");
    assertBevelManifoldCleanOpen(m, "disk N=6 K=3 every-other (was a hole)", 1);
}

unittest { // regression test 10: 3x3-quad grid (4x4 verts), L-turn selection
           // (1,0)-(1,1)-(0,1) at the interior valence-4 vertex (1,1) — a
           // pre-existing hole on unpatched main (the L-shaped chamfer on a
           // quad grid: ret=2, 20v/11f, χ=0). Fixed to χ=1 with a miter-ring
           // cap, no non-manifold edge.
    Mesh makeGrid(int rows, int cols) {
        Mesh m;
        foreach (r; 0 .. rows + 1)
            foreach (c; 0 .. cols + 1)
                m.vertices ~= Vec3(cast(float)c, cast(float)r, 0);
        uint idx(int r, int c) { return cast(uint)(r * (cols + 1) + c); }
        foreach (r; 0 .. rows)
            foreach (c; 0 .. cols)
                m.addFace([idx(r, c), idx(r, c + 1), idx(r + 1, c + 1), idx(r + 1, c)]);
        m.buildLoops();
        m.syncSelection();
        return m;
    }
    auto m = makeGrid(3, 3);
    uint idx(int r, int c) { return cast(uint)(r * 4 + c); }
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    foreach (pair; [[idx(1, 0), idx(1, 1)], [idx(1, 1), idx(0, 1)]]) {
        int ei = findEdge(m, pair[0], pair[1]);
        assert(ei >= 0);
        mask[ei] = true;
    }
    assert(m.bevelEdgesByMask(mask, 0.1f, 0) == 2);
    assert(m.vertices.length == 20 && m.faces.length == 12,
        "grid 3x3 L-turn golden must be 20v/12f (was 20v/11f/hole on main)");
    assertBevelManifoldCleanOpen(m, "grid 3x3 L-turn (was a hole)", 1);
}

unittest { // Round Level local-degrade tests 11-13 (was Decision D of task
           // 0439; task 0449 supersedes the "always flat" premise for the
           // general free-end cap, but THIS specific vertex still rounds to
           // a degenerate straight chord rather than a visible arc — for a
           // topological reason unrelated to the withheld-consumer mechanism
           // that used to be the whole story here). A cube whose top face is
           // quartered around a center pole C (valence 4) with 4 edge
           // midpoints (valence 3 each): C's own two ring-neighbours of the
           // selected slot (M12, M30) sit exactly opposite each other across
           // C (a planar quartered disk), which is the antipodal-fillet
           // degeneracy documented at `railInterior`'s `sinO < 1e-6` branch
           // — the fillet centre pulls to infinity and the arc collapses to
           // the straight chord between the two rail endpoints (Decision C,
           // doc/edge_bevel_freeend_cap_roundlevel_plan.md). The far
           // endpoint M01 (an edge midpoint of the base cube, valence 3) is
           // independently degenerate for the same reason along the OTHER
           // axis: its own two ring-neighbours (toward T0, toward T1) sit on
           // the original straight cube edge, also exactly antipodal. So
           // BOTH of this span's rails are straight chords, verified below
           // by an explicit collinearity check rather than assumed from the
           // vertex/face counts alone.
    import std.conv : to;
    import std.math : abs, sqrt;
    // Distance from point `p` to the infinite line through `a`,`b` — used
    // below to verify a "rounded" rail is actually a DEGENERATE straight
    // chord (distance ~0), not a real arc bulging off that line.
    float distToLine(Vec3 p, Vec3 a, Vec3 b) {
        Vec3 ab = b - a, ap = p - a;
        immutable float len2 = ab.x * ab.x + ab.y * ab.y + ab.z * ab.z;
        if (len2 < 1e-12f) return sqrt(ap.x * ap.x + ap.y * ap.y + ap.z * ap.z);
        immutable float t = (ap.x * ab.x + ap.y * ab.y + ap.z * ab.z) / len2;
        Vec3 closest = a + ab * t;
        Vec3 d = p - closest;
        return sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    }
    Mesh quarteredTopCube() {
        auto m0 = makeCube();
        immutable Vec3 T0 = m0.vertices[4], T1 = m0.vertices[5],
                        T2 = m0.vertices[6], T3 = m0.vertices[7];
        immutable Vec3 C   = (T0 + T1 + T2 + T3) * 0.25f;
        immutable Vec3 M01 = (T0 + T1) * 0.5f;
        immutable Vec3 M12 = (T1 + T2) * 0.5f;
        immutable Vec3 M23 = (T2 + T3) * 0.5f;
        immutable Vec3 M30 = (T3 + T0) * 0.5f;
        Mesh m;
        m.vertices = m0.vertices.dup;
        m.vertices ~= [C, M01, M12, M23, M30]; // 8, 9, 10, 11, 12
        m.addFace([0u, 3u, 2u, 1u]);       // bottom, unchanged
        m.addFace([0u, 4u, 12u, 7u, 3u]);  // side touching T3-T0, split at M30
        m.addFace([1u, 2u, 6u, 10u, 5u]);  // side touching T1-T2, split at M12
        m.addFace([3u, 7u, 11u, 6u, 2u]);  // side touching T2-T3, split at M23
        m.addFace([0u, 1u, 5u, 9u, 4u]);   // side touching T0-T1, split at M01
        m.addFace([4u, 9u, 8u, 12u]);      // top quad 1 (T0, M01, C, M30)
        m.addFace([9u, 5u, 10u, 8u]);      // top quad 2 (M01, T1, M12, C)
        m.addFace([10u, 6u, 11u, 8u]);     // top quad 3 (M12, T2, M23, C)
        m.addFace([11u, 7u, 12u, 8u]);     // top quad 4 (M23, T3, M30, C)
        m.buildLoops();
        m.syncSelection();
        return m;
    }
    // Premise: C (index 8) really is a closed-fan valence-4 vertex.
    {
        auto m = quarteredTopCube();
        size_t d = 0, e = 0;
        foreach (fi; m.facesAroundVertex(8)) ++d;
        foreach (ei; m.edgesAroundVertex(8)) ++e;
        assert(d == 4 && e == 4, "pole C must be a closed-fan valence-4 vertex");
    }
    // Test 11: span C-M01 alone (touches the pole) — task 0449: rounds at
    // every level (was flat 16v/11f at every level before that task), and
    // BOTH its rails are the antipodal-fillet degeneracy above. This task: C
    // is a PLANAR valence-4 free end, so it reproduces the Decision-C cap —
    // the raw pole vertex (0,0,0.5) is RETAINED (a coincident pair with the
    // degenerate chamfer pinch) and the opposite-edge slide (0,0.1,0.5) is
    // kept as an ORPHAN. That adds +1 vert at each rounded level (16/18/22 →
    // 16/19/23), face counts unchanged.
    static immutable size_t[3] wantV11 = [16, 19, 23];
    static immutable size_t[3] wantF11 = [11, 12, 14];
    foreach (level; 0 .. 3) {
        auto m = quarteredTopCube();
        bool[] mask; mask.length = m.edges.length; mask[] = false;
        mask[findEdge(m, 8, 9)] = true;
        assert(m.bevelEdgesByMask(mask, 0.1f, level) == 1);
        assert(m.vertices.length == wantV11[level] && m.faces.length == wantF11[level],
            "pole-touching span must round to the degenerate straight-chord "
            ~ "profile at Round Level " ~ level.to!string);
        // C's rail collapses to the straight chord through its two slides
        // bordering the selected edge, (-0.1,0,0.5)–(0.1,0,0.5); M01's to
        // (-0.1,-0.5,0.5)–(0.1,-0.5,0.5). Every ROUNDING vertex (index >= 16 —
        // rail interiors are strictly appended) must sit on one of those two
        // straight chords; a real arc would bulge off both. Named by POSITION
        // (not index) so it survives Decision C shifting the layout: the cap
        // retains the pole (0,0,0.5), which lies ON C's chord, and orphans the
        // opposite-edge slide (0,0.1,0.5), which is NOT a rounding vertex and
        // is exempt.
        static immutable Vec3 cA = Vec3(-0.1f, 0f, 0.5f), cB = Vec3(0.1f, 0f, 0.5f);
        static immutable Vec3 mA = Vec3(-0.1f, -0.5f, 0.5f), mB = Vec3(0.1f, -0.5f, 0.5f);
        static immutable Vec3 capOrphan = Vec3(0f, 0.1f, 0.5f);
        enum float EPS = 1e-5f;
        foreach (vi; 16 .. m.vertices.length) {
            if ((m.vertices[vi] - capOrphan).length < 1e-4f) continue; // Decision-C orphan slide
            immutable float dC   = distToLine(m.vertices[vi], cA, cB);
            immutable float dM01 = distToLine(m.vertices[vi], mA, mB);
            assert(dC < EPS || dM01 < EPS,
                "pole-touching span's new vertex " ~ vi.to!string ~ " at L" ~
                level.to!string ~ " is off BOTH degenerate chords — this is a real "
                ~ "arc, not the antipodal straight-chord degeneracy");
        }
        assertBevelManifoldClean(m, "degrade C-M01 span");
    }
    // Test 12: span M01-T0 alone (control, does not touch the pole) — rounds
    // normally: 15v/10f -> 17v/11f -> 21v/13f.
    {
        static immutable size_t[3] wantV = [15, 17, 21];
        static immutable size_t[3] wantF = [10, 11, 13];
        foreach (level; 0 .. 3) {
            auto m = quarteredTopCube();
            bool[] mask; mask.length = m.edges.length; mask[] = false;
            mask[findEdge(m, 9, 4)] = true;
            assert(m.bevelEdgesByMask(mask, 0.1f, level) == 1);
            assert(m.vertices.length == wantV[level] && m.faces.length == wantF[level],
                "non-pole control span must round normally at L" ~ level.to!string);
            assertBevelManifoldClean(m, "degrade control M01-T0 span");
        }
    }
    // Test 13: span C-M01 UNION a disconnected bottom edge — task 0449: BOTH
    // spans round now, independently. The pole span's own profile is still the
    // antipodal straight-chord degeneracy (test 11, same C/M01 rails) and now
    // also reproduces the Decision-C free-end cap at C (+1 vert per rounded
    // level, so 18/22/30 → 18/23/31); the disconnected bottom edge is an
    // ordinary cube corner and rounds to a real arc — this test only pins the
    // composed counts, test 11 owns the per-vertex degeneracy proof.
    {
        static immutable size_t[3] wantV = [18, 23, 31];
        static immutable size_t[3] wantF = [12, 14, 18];
        foreach (level; 0 .. 3) {
            auto m = quarteredTopCube();
            bool[] mask; mask.length = m.edges.length; mask[] = false;
            mask[findEdge(m, 8, 9)] = true;
            mask[findEdge(m, 0, 1)] = true;
            assert(m.bevelEdgesByMask(mask, 0.1f, level) == 2);
            assert(m.vertices.length == wantV[level] && m.faces.length == wantF[level],
                "pole span and disconnected span must round independently at L" ~
                level.to!string);
            assertBevelManifoldClean(m, "degrade C-M01 plus disconnected bottom edge");
        }
    }
}

unittest { // byte-stable reject test 14 (Decision A-5, doc/edge_bevel_freeend_cap_plan.md
           // §E): a cap on an OPEN (boundary) fan has no reference dump and
           // must be refused BEFORE any mutation — this is the ONLY new
           // reject task 0439 adds. Modeled on the (pre-0439) non-adjacent-K2
           // octahedron test, the strongest byte-stability battery in this
           // file: every parallel array, every selection set, every version
           // counter, and the edit recorder must all be untouched. The input
           // mesh carries non-empty faceMaterial/facePart, a subpatch bit and
           // a pre-selected face so this battery actually exercises those
           // checks instead of comparing zeros to zeros.
    import std.math : cos, sin, PI;
    import std.conv : to;
    Mesh halfDisk() {
        // Hub + 5 rim verts spanning 180 degrees (4 triangular faces): an
        // OPEN fan at the hub (d=4 faces, e=5 edges, e == d+1).
        Mesh m;
        m.vertices ~= Vec3(0, 0, 0);
        foreach (i; 0 .. 5) {
            immutable float a = PI * i / 4;
            m.vertices ~= Vec3(cos(a), sin(a), 0);
        }
        foreach (i; 0 .. 4)
            m.addFace([0u, cast(uint)(1 + i), cast(uint)(2 + i)]);
        m.buildLoops();
        m.syncSelection();
        m.faceMaterial[1] = 7u; m.facePart[1] = 23u;
        m.setFaceSubpatch(1, true);
        m.selectFace(1);
        return m;
    }
    auto m = halfDisk();
    // Premise: the hub really does present an OPEN fan, and the selected
    // edge's ring (3 unselected slots, K=1, no miter) is >= 3.
    {
        size_t d = 0, e = 0;
        foreach (fi; m.facesAroundVertex(0)) ++d;
        foreach (ei; m.edgesAroundVertex(0)) ++e;
        assert(e == d + 1, "half-disk hub must present an OPEN fan");
    }
    bool[] mask; mask.length = m.edges.length; mask[] = false;
    mask[findEdge(m, 0, 3)] = true; // an INTERIOR hub spoke (not a rim edge)

    foreach (level; 0 .. 2) {
        auto mm = halfDisk();
        bool[] mmask; mmask.length = mm.edges.length; mmask[] = false;
        mmask[findEdge(mm, 0, 3)] = true;

        auto vertsBefore = mm.vertices.dup;
        auto edgesBefore = mm.edges.dup;
        auto facesBefore = mm.faces._store.dup;
        auto vertexMarksBefore = mm.vertexMarks.dup;
        auto edgeMarksBefore = mm.edgeMarks.dup;
        auto faceMarksBefore = mm.faceMarks.dup;
        auto vertexSelectionOrderBefore = mm.vertexSelectionOrder.dup;
        auto edgeSelectionOrderBefore = mm.edgeSelectionOrder.dup;
        auto faceSelectionOrderBefore = mm.faceSelectionOrder.dup;
        auto faceMaterialBefore = mm.faceMaterial.dup;
        auto facePartBefore = mm.facePart.dup;
        auto selectedVerticesBefore = mm.selectedVertices;
        auto selectedEdgesBefore = mm.selectedEdges;
        auto selectedFacesBefore = mm.selectedFaces;
        immutable ulong mutationBefore = mm.mutationVersion;
        immutable ulong topologyBefore = mm.topologyVersion;
        immutable ulong structBefore = mm.structVersion;
        immutable uint pendingBefore = mm.pendingChanges_;
        immutable uint pendingSelBefore = mm.pendingSelDomains_;
        MeshEditTracker recorder;
        mm.beginEditBatch(&recorder, MeshEditScope.Geometry);
        assert(mm.isRecordingEdits());

        assert(mm.bevelEdgesByMask(mmask, 0.1f, cast(int)level) == 0,
            "an open-fan cap must be refused before any mutation, at L" ~ level.to!string);
        assert(mm.vertices == vertsBefore && mm.edges == edgesBefore &&
               mm.faces._store == facesBefore,
            "open-fan cap preflight must leave geometry byte-identical");
        assert(mm.vertexMarks == vertexMarksBefore && mm.edgeMarks == edgeMarksBefore &&
               mm.faceMarks == faceMarksBefore &&
               mm.vertexSelectionOrder == vertexSelectionOrderBefore &&
               mm.edgeSelectionOrder == edgeSelectionOrderBefore &&
               mm.faceSelectionOrder == faceSelectionOrderBefore &&
               mm.faceMaterial == faceMaterialBefore && mm.facePart == facePartBefore,
            "open-fan cap preflight must leave parallel attributes byte-identical");
        assert(mm.selectedVertices == selectedVerticesBefore &&
               mm.selectedEdges == selectedEdgesBefore &&
               mm.selectedFaces == selectedFacesBefore,
            "open-fan cap preflight must leave selection byte-identical");
        assert(mm.mutationVersion == mutationBefore && mm.topologyVersion == topologyBefore &&
               mm.structVersion == structBefore && mm.pendingChanges_ == pendingBefore &&
               mm.pendingSelDomains_ == pendingSelBefore,
            "open-fan cap preflight must not bump versions or pending changes");
        assert(recorder.isEmpty(), "open-fan cap preflight must not write an edit record");
        assert(mm.endEditBatch().isEmpty(), "open-fan cap preflight must finish with an empty delta");
        assertBevelManifoldCleanOpen(mm, "half-disk open-fan cap reject, unchanged input", 1);
    }

    // Verify the 15 open-mesh reference cases' own shapes (boundary ring <=
    // 2) are NOT caught by this new reject — they stay accepted.
    {
        auto md = halfDisk();
        size_t d = 0, e = 0;
        foreach (fi; md.facesAroundVertex(1)) ++d; // a rim vertex
        foreach (ei; md.edgesAroundVertex(1)) ++e;
        assert(e == d + 1, "rim vertex must itself be an open fan");
        assert(d <= 2, "a rim vertex on this half-disk has ring <= 2, below the reject threshold");
    }
}

// bevelVerticesByMask unittests
// ---------------------------------------------------------------------------

// Basic: cube corner 0, amount=0.2 → 3 new verts (8→10), 1 cap tri + 3
// pentagons (6→7 faces). Material and subpatch carried from incident face.
unittest {
    import std.math : sqrt;
    import std.conv : to;

    auto m = makeCube();
    m.buildLoops();
    m.syncSelection();

    // Assign non-default material + subpatch to one incident face of vertex 0.
    uint incFi = uint.max;
    foreach (fi; m.facesAroundVertex(0)) { incFi = fi; break; }
    assert(incFi != uint.max, "bevelVert: no incident face at vertex 0");
    m.faceMaterial[incFi] = 7u;
    m.setFaceSubpatch(incFi, true);

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;
    size_t n = m.bevelVerticesByMask(mask, 0.2f);

    assert(n == 1,
           "bevelVert: expected 1 processed, got " ~ n.to!string);
    assert(m.vertices.length == 10,
           "bevelVert: expected 10 verts, got " ~ m.vertices.length.to!string);
    assert(m.faces.length == 7,
           "bevelVert: expected 7 faces, got " ~ m.faces.length.to!string);

    // Tally arities: exactly 1 tri (cap) + 3 pentagons.
    int triCount = 0, pentCount = 0;
    bool capSubpatch = false;
    bool capMat7     = false;
    foreach (fi; 0 .. m.faces.length) {
        int arity = cast(int)m.faces[fi].length;
        if (arity == 3) {
            ++triCount;
            if (m.isFaceSubpatch(cast(uint)fi)) capSubpatch = true;
            if (m.faceMaterial[fi] == 7u)        capMat7     = true;
        } else if (arity == 5) {
            ++pentCount;
        }
    }
    assert(triCount  == 1, "bevelVert: expected 1 cap tri, got "    ~ triCount.to!string);
    assert(pentCount == 3, "bevelVert: expected 3 pentagons, got " ~ pentCount.to!string);
    assert(capSubpatch, "bevelVert: cap must carry subpatch from incident face");
    assert(capMat7,     "bevelVert: cap must carry material 7 from incident face");

    // Split verts at expected positions (amount=0.2, unit-cube edges).
    // Corner 0 = (-0.5,-0.5,-0.5); neighbours at (+0.5,-0.5,-0.5),
    // (-0.5,+0.5,-0.5), (-0.5,-0.5,+0.5).
    Vec3[3] expected = [Vec3(-0.3f,-0.5f,-0.5f),
                        Vec3(-0.5f,-0.3f,-0.5f),
                        Vec3(-0.5f,-0.5f,-0.3f)];
    bool[3] found;
    foreach (v; m.vertices) {
        foreach (j; 0 .. 3) {
            Vec3 e = expected[j];
            float d = sqrt((v.x-e.x)*(v.x-e.x) +
                           (v.y-e.y)*(v.y-e.y) +
                           (v.z-e.z)*(v.z-e.z));
            if (d < 1e-4f) found[j] = true;
        }
    }
    foreach (j; 0 .. 3)
        assert(found[j], "bevelVert: split vert " ~ j.to!string ~ " not found");

    // Original corner 0 must have been compacted away.
    bool origPresent = false;
    foreach (v; m.vertices) {
        float d = sqrt((v.x+0.5f)*(v.x+0.5f) +
                       (v.y+0.5f)*(v.y+0.5f) +
                       (v.z+0.5f)*(v.z+0.5f));
        if (d < 1e-4f) { origPresent = true; break; }
    }
    assert(!origPresent, "bevelVert: original corner 0 must be compacted away");
}

// No-op: amount=0 → returns 0, mesh unchanged.
unittest {
    auto m = makeCube();
    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true;
    size_t n = m.bevelVerticesByMask(mask, 0.0f);
    assert(n == 0,                "bevelVert no-op: expected 0 processed");
    assert(m.vertices.length == 8, "bevelVert no-op: vertex count unchanged");
    assert(m.faces.length    == 6, "bevelVert no-op: face count unchanged");
}
