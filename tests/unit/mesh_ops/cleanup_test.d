// Module unittests for `mesh_ops.cleanup`, moved verbatim out of source/mesh_ops/cleanup.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.cleanup_test;

import mesh;
import math;
import mesh_ops.cleanup;

unittest { // duplicate face (reversed winding) removed; lowest-index kept
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    // Install both faces directly — makePolygonFromVerts would reject the dup.
    m.faces = [[0u,1u,2u,3u], [3u,2u,1u,0u]]; // same vertex set, reversed winding
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t removed = m.unifyFaces();
    assert(removed == 1, "expected 1 face removed, got " ~ uintToStr(removed));
    assert(m.faces.length == 1, "expected 1 face remaining");
    // First occurrence (index 0) must be the survivor.
    assert(m.faces[0][] == [0u,1u,2u,3u], "lowest-index face must be kept");
}

unittest { // no duplicate faces → no-op, version unchanged
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    m.buildLoops();
    m.faces = [[0u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    const verBefore = m.topologyVersion;
    size_t removed = m.unifyFaces();
    assert(removed == 0, "single face: no dup to remove");
    assert(m.topologyVersion == verBefore, "no-op must not bump topology version");
}

unittest { // O(F) hash-bucket rewrite matches the naive O(F²) makePolyVertexSetMatch_
    // pairwise scan: plain duplicate + reversed-winding duplicate + a
    // non-duplicate that merely shares some vertices with the kept face
    // (task 0396). Reference mask computed inline via the same
    // makePolyVertexSetMatch_ helper the old implementation used.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0), Vec3(2,0,0)];
    m.faces = [
        [0u,1u,2u,3u],  // F0: kept (first occurrence)
        [3u,2u,1u,0u],  // F1: reversed-winding duplicate of F0 → removed
        [1u,2u,4u],     // F2: shares verts 1,2 with F0 but is NOT a duplicate (arity 3 vs 4) → kept
        [0u,1u,2u,3u],  // F3: plain duplicate of F0 → removed
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    // Reference: naive O(F²) pairwise mask via the retained helper.
    bool[] refMask;
    refMask.length = m.faces.length;
    foreach (i; 0 .. m.faces.length) {
        if (refMask[i]) continue;
        foreach (j; i + 1 .. m.faces.length) {
            if (refMask[j]) continue;
            if (Mesh.makePolyVertexSetMatch_(m.faces[i][], m.faces[j][]))
                refMask[j] = true;
        }
    }
    size_t refRemoved = 0;
    foreach (b; refMask) if (b) ++refRemoved;
    assert(refMask == [false, true, false, true],
        "reference mask sanity: F1 and F3 are duplicates of F0, F2 is not");

    size_t removed = m.unifyFaces();
    assert(removed == refRemoved,
        "hash-bucket unifyFaces must remove the same count as the naive scan, got "
        ~ uintToStr(removed) ~ " vs " ~ uintToStr(refRemoved));
    assert(m.faces.length == 2, "expected F0 and F2 to survive, got " ~ uintToStr(m.faces.length));
    assert(m.faces[0][] == [0u,1u,2u,3u], "lowest-index face (F0) must be kept");
    assert(m.faces[1][] == [1u,2u,4u], "non-duplicate F2 (shares verts but different arity) must survive");
}

unittest { // literal 2-vertex face removed (only exercisable via direct assignment)
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    // 2-vertex face: bypasses makePolygonFromVerts guard (which requires ≥3 entries).
    m.faces = [[0u, 1u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t n = m.cleanDegenerateFaces();
    assert(n >= 1, "2-vertex face must be removed");
    assert(m.faces.length == 0, "no faces should remain");
}

unittest { // face [0,1,1]: 3 entries, <3 distinct → removed
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    m.faces = [[0u, 1u, 1u]];  // repeated vert 1 → collapses to [0,1] → dropped
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t n = m.cleanDegenerateFaces();
    assert(n >= 1, "[0,1,1] must be removed (<3 distinct after dedup)");
    assert(m.faces.length == 0);
}

unittest { // consecutive-dup rewritten: [0,1,1,2,3] → [0,1,2,3], face kept
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    // Face with a consecutively duplicated vert; after collapse → valid quad.
    m.faces = [[0u, 1u, 1u, 2u, 3u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t n = m.cleanDegenerateFaces();
    assert(n == 1, "rewritten face counts as 1 affected");
    assert(m.faces.length == 1, "face must be kept after rewrite");
    assert(m.faces[0].length == 4, "expect 4 verts after removing consecutive dup");
}

unittest { // zero-area collinear triangle removed
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(2,0,0)]; // three points on x-axis
    m.faces = [[0u, 1u, 2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t n = m.cleanDegenerateFaces();
    assert(n >= 1, "zero-area (collinear) face must be removed");
    assert(m.faces.length == 0);
}

unittest { // clean triangle → no-op, no commitChange (topology version unchanged)
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0)];
    m.faces = [[0u, 1u, 2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    const verBefore = m.topologyVersion;
    size_t n = m.cleanDegenerateFaces();
    assert(n == 0, "clean mesh: expected no changes");
    assert(m.topologyVersion == verBefore, "no version bump on clean mesh (early-return)");
}

unittest { // all-dirty mesh: each stage fires correctly
    // Layout:
    //   verts 0-3: quad [0,1,2,3]              positions (0,0,0)-(1,0,0)-(1,1,0)-(0,1,0)
    //   vert 4:    (0.5,0,0) — used in zero-area triangle [0,4,1] (collinear)
    //   vert 5:    (0,0,0)   — coincident with vert 0; used in face [5,6,7]
    //   verts 6-7: (2,0,0),(2,1,0) — for valid triangle [5,6,7] → [0,6,7] after weld
    //   vert 8:    (9,9,9)   — pure orphan (not in any face)
    //   face [0,1,2,3]: valid quad
    //   face [0,1,2,3]: duplicate of above
    //   face [0,4,1]:   zero-area (collinear on x-axis) → cleanDegenerateFaces drops it
    //   face [5,6,7]:   valid, becomes [0,6,7] after weld of 5→0
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),   // 0-3
        Vec3(0.5f,0,0),                                          // 4 (collinear)
        Vec3(0,0,0),                                             // 5 (coincident with 0)
        Vec3(2,0,0), Vec3(2,1,0),                               // 6-7
        Vec3(9,9,9),                                             // 8 (orphan)
    ];
    m.faces = [
        [0u,1u,2u,3u],
        [0u,1u,2u,3u],  // duplicate
        [0u,4u,1u],     // zero-area (0, 0.5, 1 on x-axis)
        [5u,6u,7u],     // valid triangle (5 coincident with 0)
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    auto r = m.cleanupMesh();

    // Stage counts — each stage that fired must be non-zero.
    assert(r.welded     >= 1, "weld: vert 5→0 expected; got " ~ uintToStr(r.welded));
    assert(r.degenerate >= 1, "degenerate: zero-area [0,4,1] expected; got " ~ uintToStr(r.degenerate));
    assert(r.unified    >= 1, "unified: duplicate [0,1,2,3] expected; got " ~ uintToStr(r.unified));
    assert(r.dissolved  == 0, "dissolve2Valent is off by default");
    // Note: r.orphans may be 0 even though orphan verts were removed, because
    // cleanDegenerateFaces() / unifyFaces() each call compactUnreferenced()
    // internally — by the time cleanupMesh's own intermediate compact runs,
    // the orphans are already gone. The geometry counts below verify correctness.

    // Final geometry: verts {0,1,2,3,6,7} only; faces [0,1,2,3] and [0,6,7]
    assert(m.faces.length == 2, "expected 2 faces, got " ~ uintToStr(m.faces.length));
    assert(m.vertices.length == 6, "expected 6 verts, got " ~ uintToStr(m.vertices.length));
    assert(r.anyAffected(), "anyAffected must be true");
}

unittest { // weld-creates-a-duplicate order guard (regression)
    // Two coincident verts A(0)=B(3) + faces [A,1,2] and [B,1,2].
    // Correct order: weld B→A first, then unifyFaces removes the dup.
    // Wrong order (unify-before-weld): dup survives because they look distinct pre-weld.
    Mesh m;
    m.vertices = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0),  // 0,1,2
        Vec3(0,0,0),                              // 3 = coincident with 0
    ];
    m.faces = [[0u,1u,2u], [3u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    auto r = m.cleanupMesh();

    assert(r.welded >= 1, "weld: vert 3→0 expected");
    assert(r.unified >= 1, "unify: weld-created dup must be caught");
    assert(m.faces.length == 1, "expected 1 face; weld-dup must be removed");
    assert(m.vertices.length == 3, "expected 3 verts after compact");
}

unittest { // removeOrphans:false: orphan vert preserved; no stage fires → no-op
    // Triangle + one floating vert (orphan).  No dirty geometry → all other stages
    // are no-ops.  With removeOrphans:false the orphan must survive untouched.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(9,9,9)]; // vert 3 = orphan
    m.faces = [[0u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    CleanupOptions o;
    o.removeOrphans = false;
    auto r = m.cleanupMesh(o);

    assert(!r.anyAffected(), "clean mesh + removeOrphans:false: no stage should fire");
    assert(m.vertices.length == 4, "orphan must survive when removeOrphans is false");
}

unittest { // all-stages-off + orphan: true no-op, topology version unchanged
    // This is the contract test: before the fix, the unconditional final
    // compactUnreferenced would mutate the mesh and bump the topology version
    // even with every stage disabled.  With the fix this is a genuine no-op.
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(0,1,0), Vec3(9,9,9)]; // vert 3 = orphan
    m.faces = [[0u,1u,2u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    const verBefore = m.topologyVersion;

    CleanupOptions o;
    o.mergeVerts      = false;
    o.dropDegenerate  = false;
    o.unify           = false;
    o.removeOrphans   = false;
    o.dissolve2Valent = false;
    auto r = m.cleanupMesh(o);

    assert(!r.anyAffected(), "all-stages-off must return no-op result");
    assert(m.vertices.length == 4, "orphan must not be removed with all stages off");
    assert(m.topologyVersion == verBefore,
        "topology version must not change on a true no-op (no-op contract)");
}

unittest { // well-formed mesh: no-op, byte-identical
    import std.algorithm : map;
    import std.array : array;
    Mesh m = makeCube();
    m.buildLoops();
    auto before = m.faces.dup.map!(f => f.dup).array;
    const verBefore = m.topologyVersion;
    size_t n = m.fixFaceOrientation();
    assert(n == 0, "consistently-wound cube must report 0 flips");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi][] == before[fi][], "well-formed mesh: face " ~ uintToStr(fi) ~ " must be unchanged");
    assert(m.topologyVersion == verBefore,
        "well-formed mesh: topologyVersion must not change (flipFacesByMask short-circuits on an all-false mask)");
}

unittest { // single corrupted face on a closed cube: exactly 1 flip, restores
           // the original (outward-consistent) winding exactly
    import std.algorithm : map;
    import std.array : array;
    Mesh m = makeCube();
    m.buildLoops();
    auto original = m.faces.dup.map!(f => f.dup).array;

    bool[] mask = new bool[](m.faces.length);
    mask[2] = true;
    size_t nFlipped = m.flipFacesByMask(mask);
    assert(nFlipped == 1, "sanity: corrupting setup must flip exactly face 2");
    assert(m.faces[2][] != original[2][], "sanity: face 2 must now differ from its original winding");

    size_t n = m.fixFaceOrientation();
    assert(n == 1, "exactly 1 face (the corrupted one) must be flipped back");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi][] == original[fi][],
            "fixFaceOrientation must restore the cube's original outward-consistent winding exactly, face "
            ~ uintToStr(fi) ~ " differs");

    // No same-direction shared edge remains anywhere in the mesh.
    foreach (fi; 0 .. m.faces.length) {
        const uint[] f = m.faces[fi];
        foreach (k; 0 .. f.length) {
            uint u = f[k], v = f[(k + 1) % f.length];
            foreach (fj; 0 .. m.faces.length) {
                if (fj == fi) continue;
                const uint[] g = m.faces[fj];
                foreach (kk; 0 .. g.length) {
                    if (g[kk] == u && g[(kk + 1) % g.length] == v)
                        assert(false, "same-direction shared edge (" ~ uintToStr(u) ~ "," ~ uintToStr(v)
                            ~ ") remains between faces " ~ uintToStr(fi) ~ " and " ~ uintToStr(fj));
                }
            }
        }
    }
}

unittest { // multiple same-direction shared edges (several faces wound
           // backwards, mimicking a corrupted import) are ALL healed in one pass
    import std.algorithm : map;
    import std.array : array;
    Mesh m = makeCube();
    m.buildLoops();
    auto original = m.faces.dup.map!(f => f.dup).array;

    bool[] mask = new bool[](m.faces.length);
    mask[0] = true; mask[3] = true; mask[5] = true; // flip 3 of 6 faces
    m.flipFacesByMask(mask);

    size_t n = m.fixFaceOrientation();
    assert(n > 0, "expected at least 1 corrective flip");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi][] == original[fi][],
            "fixFaceOrientation must restore the original winding for face " ~ uintToStr(fi)
            ~ " even when multiple faces started corrupted");
}

unittest { // subpatch + material survive the flip -- reversing a face's
           // vertex cycle is index-order only; the face SLOT is never
           // added/removed/reordered, so faceMarks/faceMaterial (both
           // indexed by face slot) must stay aligned across the flip.
    Mesh m = makeCube();
    m.buildLoops();
    m.resetSelection();
    m.faceMarks[2] |= Mesh.Marks.Subpatch;
    m.faceMaterial.length = m.faces.length;
    m.faceMaterial[2] = 7;

    bool[] mask = new bool[](m.faces.length);
    mask[2] = true;
    m.flipFacesByMask(mask);

    size_t n = m.fixFaceOrientation();
    assert(n == 1, "expected exactly 1 corrective flip");
    assert(m.isFaceSubpatch(2), "face 2's subpatch flag must survive the flip");
    assert(m.faceMaterial[2] == 7, "face 2's material index must survive the flip");
}

unittest { // selection-restricted: with an active face selection, only the
           // connected COMPONENT containing a selected face is healed;
           // components with no selected face are left completely untouched
           // (matches reference-editor selection-restricted Recalculate
           // Normals behavior)
    import std.algorithm : map;
    import std.array : array;
    Mesh a = makeCube();
    Mesh b = makeCube();
    foreach (ref v; b.vertices) v = v + Vec3(10, 0, 0); // disjoint component, far away

    Mesh m;
    m.vertices = a.vertices.dup ~ b.vertices.dup;
    foreach (f; a.faces) m.addFace(f.dup);
    const uint offset = cast(uint)a.vertices.length;
    foreach (f; b.faces) {
        uint[] nf;
        foreach (vi; f) nf ~= vi + offset;
        m.addFace(nf);
    }
    m.buildLoops();
    m.resetSelection();
    auto originalA = m.faces[0 .. a.faces.length].dup.map!(f => f.dup).array;
    auto originalB = m.faces[a.faces.length .. $].dup.map!(f => f.dup).array;

    bool[] mask = new bool[](m.faces.length);
    mask[1]                     = true; // corrupt a face in component A
    mask[a.faces.length + 1]    = true; // corrupt a face in component B
    m.flipFacesByMask(mask);

    m.faceMarks[0] |= Mesh.Marks.Select; // select a face ONLY in component A

    size_t n = m.fixFaceOrientation();
    assert(n == 1, "only component A's single corrupted face should be flipped back");
    foreach (fi; 0 .. a.faces.length)
        assert(m.faces[fi][] == originalA[fi][], "component A (selected) must be fully healed, face " ~ uintToStr(fi));
    bool bStillCorrupt = false;
    foreach (fi; 0 .. b.faces.length)
        if (m.faces[a.faces.length + fi][] != originalB[fi][]) bStillCorrupt = true;
    assert(bStillCorrupt, "component B (not selected) must be left untouched -- still corrupted");
}

// Site 11 (task 1902 Stage E) — cleanDegenerateFaces's single rewrite pass:
// every surviving face's SOLE plane source is its OWN old index, carried by
// `mesh_planes.rewriteFaces` (`FaceSource(oldOfNew)`, identity over the
// kept range). No existing test in this file asserts material/part/set-
// membership by value — every prior unittest checks only counts and shape.
// The dropped face sits in the MIDDLE (face 2 of 5), not the tail — task
// 0921's front-truncated-slice class: a bug that reads `faceMaterial[newIdx]`
// instead of `faceMaterial[oldIdx]` would leave every survivor AFTER the
// drop wearing its NEIGHBOUR's value, which a tail-only drop cannot expose.
unittest {
    import std.conv : to;
    import mesh_selsets : selSetEditPolygon, SetEditMode;

    Mesh m;
    m.vertices = [
        Vec3(0,0,0),  Vec3(1,0,0),  Vec3(0,1,0),    // face 0
        Vec3(10,0,0), Vec3(11,0,0), Vec3(10,1,0),   // face 1
        Vec3(20,0,0), Vec3(21,0,0), Vec3(22,0,0),   // face 2 — collinear (dropped)
        Vec3(30,0,0), Vec3(31,0,0), Vec3(30,1,0),   // face 3
        Vec3(40,0,0), Vec3(41,0,0), Vec3(40,1,0),   // face 4
    ];
    m.faces = [
        [0u,1u,2u], [3u,4u,5u], [6u,7u,8u], [9u,10u,11u], [12u,13u,14u],
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    static immutable uint[5] wantMat  = [1000, 1001, 1002, 1003, 1004];
    static immutable uint[5] wantPart = [2000, 2001, 2002, 2003, 2004];
    foreach (fi; 0 .. 5) {
        m.faceMaterial[fi] = wantMat[fi];
        m.facePart[fi]     = wantPart[fi];
    }
    // A polygon set on face 4 only, so faceSetMask is non-uniform too.
    bool[] polySel = new bool[](5);
    polySel[4] = true;
    selSetEditPolygon(m, "S", SetEditMode.replace, polySel);

    size_t n = m.cleanDegenerateFaces();
    assert(n >= 1, "collinear middle face must be removed");
    assert(m.faces.length == 4,
        "expected 4 survivors after dropping the middle face, got "
        ~ m.faces.length.to!string);

    // Survivors 0,1,3,4 land at compacted positions 0,1,2,3 — each keeping
    // its OWN material/part, not a front-truncated slice of the original.
    static immutable uint[4] survivingMat  = [1000, 1001, 1003, 1004];
    static immutable uint[4] survivingPart = [2000, 2001, 2003, 2004];
    foreach (i; 0 .. 4) {
        assert(m.faceMaterial[i] == survivingMat[i],
            "cleanDegenerateFaces: survivor at position " ~ i.to!string
            ~ " must keep its OWN material through the middle-drop "
            ~ "compaction (got " ~ m.faceMaterial[i].to!string ~ ", want "
            ~ survivingMat[i].to!string ~ ")");
        assert(m.facePart[i] == survivingPart[i],
            "cleanDegenerateFaces: survivor at position " ~ i.to!string
            ~ " must keep its OWN part through the middle-drop compaction "
            ~ "(got " ~ m.facePart[i].to!string ~ ", want "
            ~ survivingPart[i].to!string ~ ")");
    }
    // Old face 4 (now at compacted position 3) must keep its set membership.
    assert(m.faceSetMask[3] != 0,
        "cleanDegenerateFaces: surviving face's set membership must follow "
        ~ "it through the middle-drop compaction");
}

// Task 1902 Step 0 review addition — the site-11 witness above checks
// faceMaterial/facePart by value and faceSetMask only ONE-SIDED (a survivor
// that IS a set member reads nonzero); neither proves a survivor that is
// NOT a member reads zero, nor that faceMarks (the plane the Hide bit lives
// in) is carried by VALUE rather than by some blanket copy. Same
// middle-drop fixture (face 2 dropped, collinear), so the compacted-
// position mapping is identical: old face 3 -> position 2, old face 4 ->
// position 3.
unittest {
    import std.conv : to;
    import mesh_selsets : selSetEditPolygon, SetEditMode;

    Mesh m;
    m.vertices = [
        Vec3(0,0,0),  Vec3(1,0,0),  Vec3(0,1,0),    // face 0
        Vec3(10,0,0), Vec3(11,0,0), Vec3(10,1,0),   // face 1
        Vec3(20,0,0), Vec3(21,0,0), Vec3(22,0,0),   // face 2 — collinear (dropped)
        Vec3(30,0,0), Vec3(31,0,0), Vec3(30,1,0),   // face 3
        Vec3(40,0,0), Vec3(41,0,0), Vec3(40,1,0),   // face 4
    ];
    m.faces = [
        [0u,1u,2u], [3u,4u,5u], [6u,7u,8u], [9u,10u,11u], [12u,13u,14u],
    ];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();

    // Face 4 is HIDDEN before the compaction; faces 0/1/3 stay visible.
    m.setFaceHidden(4, true);

    // A polygon set on face 4 only, so faceSetMask is non-uniform (mirrors
    // the site-11 witness above).
    bool[] polySel = new bool[](5);
    polySel[4] = true;
    selSetEditPolygon(m, "S", SetEditMode.replace, polySel);

    size_t n = m.cleanDegenerateFaces();
    assert(n >= 1, "collinear middle face must be removed");
    assert(m.faces.length == 4,
        "expected 4 survivors after dropping the middle face, got "
        ~ m.faces.length.to!string);

    // faceMarks (Hide) by VALUE: old face 4 (now position 3) stays hidden;
    // old face 3 (now position 2) was never hidden and must not have picked
    // up the bit through a mis-indexed carry.
    assert(m.isFaceHidden(3) && !m.isFaceHidden(2),
        "cleanDegenerateFaces: faceMarks (Hide) must follow each survivor "
        ~ "by its OWN old index through the middle-drop compaction (got "
        ~ "isFaceHidden(2)=" ~ m.isFaceHidden(2).to!string
        ~ " isFaceHidden(3)=" ~ m.isFaceHidden(3).to!string ~ ")");

    // faceSetMask two-sided: position 3 (old 4) IS a member, position 2
    // (old 3) is NOT — a carry that stamped every survivor with the SAME
    // (e.g. the last-seen) mask word would pass a one-sided check but fail
    // this one.
    assert(m.faceSetMask[3] != 0,
        "cleanDegenerateFaces: surviving face's set membership must follow "
        ~ "it through the middle-drop compaction");
    assert(m.faceSetMask[2] == 0,
        "cleanDegenerateFaces: a surviving face that was NOT a set member "
        ~ "must not read as one after the middle-drop compaction (got "
        ~ m.faceSetMask[2].to!string ~ ")");
}
