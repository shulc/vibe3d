// Module unittests for `mesh_ops.cleanup`, moved verbatim out of source/mesh_ops/cleanup.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.cleanup_test;

import mesh;
import math;
import std.conv : to;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, MeshOpEntry;
import mesh_ops.cleanup;

// TASK 1903 Stage E1 — the four mutating hygiene kernels are free functions
// over `ref MeshEditBatch` now, so a test cannot call one on a bare `Mesh` any
// more: that is the point of the receiver, and it is why every call site in
// this file goes through one of the four wrappers below. The batches are
// UNRECORDED for the same reason the three production callers' are (see
// source/mesh_ops/cleanup.d's header): nothing in these blocks reads an
// op-log, and track 1 is the conversion axis only. The one block that DOES
// read an op-log opens its own RECORDING batch inline and says so.
private size_t unifyOnce(ref Mesh m) {
    auto ed = MeshEditBatch.unrecorded(m, kCleanupEditScope);
    const n = ed.unifyFaces();
    ed.close();
    return n;
}

private size_t cleanDegenerateOnce(ref Mesh m) {
    auto ed = MeshEditBatch.unrecorded(m, kCleanupEditScope);
    const n = ed.cleanDegenerateFaces();
    ed.close();
    return n;
}

private CleanupResult cleanupOnce(ref Mesh m, CleanupOptions o = CleanupOptions.init) {
    auto ed = MeshEditBatch.unrecorded(m, kCleanupEditScope);
    auto r = ed.cleanupMesh(o);
    ed.close();
    return r;
}

private size_t fixOrientationOnce(ref Mesh m) {
    auto ed = MeshEditBatch.unrecorded(m, kCleanupEditScope);
    const n = ed.fixFaceOrientation();
    ed.close();
    return n;
}

unittest { // duplicate face (reversed winding) removed; lowest-index kept
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    // Install both faces directly — makePolygonFromVerts would reject the dup.
    m.faces = [[0u,1u,2u,3u], [3u,2u,1u,0u]]; // same vertex set, reversed winding
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    size_t removed = unifyOnce(m);
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
    size_t removed = unifyOnce(m);
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

    size_t removed = unifyOnce(m);
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
    size_t n = cleanDegenerateOnce(m);
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
    size_t n = cleanDegenerateOnce(m);
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
    size_t n = cleanDegenerateOnce(m);
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
    size_t n = cleanDegenerateOnce(m);
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
    size_t n = cleanDegenerateOnce(m);
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

    auto r = cleanupOnce(m);

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

    auto r = cleanupOnce(m);

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
    auto r = cleanupOnce(m, o);

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
    auto r = cleanupOnce(m, o);

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
    size_t n = fixOrientationOnce(m);
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

    size_t n = fixOrientationOnce(m);
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

    size_t n = fixOrientationOnce(m);
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

    size_t n = fixOrientationOnce(m);
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

    size_t n = fixOrientationOnce(m);
    assert(n == 1, "only component A's single corrupted face should be flipped back");
    foreach (fi; 0 .. a.faces.length)
        assert(m.faces[fi][] == originalA[fi][], "component A (selected) must be fully healed, face " ~ uintToStr(fi));
    bool bStillCorrupt = false;
    foreach (fi; 0 .. b.faces.length)
        if (m.faces[a.faces.length + fi][] != originalB[fi][]) bStillCorrupt = true;
    assert(bStillCorrupt, "component B (not selected) must be left untouched -- still corrupted");
}

// Task 1909 (review of 1903 Stage E1, NC-4): `fixFaceOrientation`'s opening
// `ed.buildLoops()` (source/mesh_ops/cleanup.d) was witnessed by NOTHING --
// deleting it left 278/278 unit modules green, because every stand in this
// file (including all the ones above) builds `faces`, THEN calls
// `buildLoops()`, THEN corrupts winding through `flipFacesByMask` -- and
// `flipFacesByMask` itself ends with a `buildLoops()` call (see its own doc
// comment / mesh.d), so `loops` is never actually stale by the time any
// existing test reaches the kernel. This is a check that could not come out
// differently: a fixture that always arrives synchronized cannot exercise a
// precondition that exists to RE-synchronize.
//
// The discriminating rig: corrupt `faces[1]`'s winding through the SAME raw
// indexed write real kernels use (`ed.faces[fi] = …` -- `mesh_ops/extrude.d`,
// `commands/mesh/bevel.d`), which is `structVersion`-INDIFFERENT (mesh.d's
// `structVersion` doc comment: bumped only by addEdge/addFace/addFaceFast/
// rebuildEdges*, never by an in-place `faces[]` element write) -- so
// `loopsValid()` would still read true even though `loops` no longer matches
// `faces`. Two independently-built meshes (a fresh call to the helper
// allocates its own arrays -- a struct COPY would alias the same backing
// storage and corrupt both sides at once) get the IDENTICAL corruption:
// `control` has its loops resynced BY THE CALLER before the kernel runs (the
// ground truth); `subject` does not, and relies on `fixFaceOrientation`'s
// own internal `ed.buildLoops()` to reach the same answer WITHOUT caller
// help. If that call is missing, `subject` analyzes the STALE pre-corruption
// loops (still describing consistent winding) and reports nothing to heal,
// diverging from `control`.
private Mesh openTriPairStand_() {
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    // Two triangles sharing edge (0,2), consistently wound: face 0 traverses
    // the shared edge 2->0, face 1 traverses it 0->2 -- opposite directions.
    m.faces = [[0u,1u,2u], [0u,2u,3u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

unittest { // desynchronized loops: `ed.buildLoops()` must make the kernel
           // analyze the CURRENT faces[], not whatever loops the caller
           // last built
    import std.format : format;

    // Control: corrupt face 1's winding (reverse [0,2,3] -> [3,2,0], which
    // makes both faces traverse the shared edge (0,2) in the SAME direction
    // -- the corruption signature), then resync loops BEFORE the kernel
    // runs. This is the ground truth for "faces == [[0,1,2],[3,2,0]]"
    // regardless of who rebuilds the loops.
    Mesh control = openTriPairStand_();
    control.faces[1] = [3u, 2u, 0u];
    control.buildLoops();
    size_t nControl = fixOrientationOnce(control);
    assert(nControl > 0, "sanity: reversing face 1 must create a healable "
        ~ "same-direction shared edge with face 0 -- the rig does not "
        ~ "discriminate anything otherwise");

    // Subject: the IDENTICAL corruption, but the caller does NOT resync --
    // `subject.loops` still reflects face 1's ORIGINAL, consistent winding.
    // `structVersion` did not move either (a raw `faces[fi] = …` element
    // write bumps neither it nor `loopsStamp`), so `loopsValid()` would
    // still read true even though `loops` no longer matches `faces`.
    Mesh subject = openTriPairStand_();
    subject.faces[1] = [3u, 2u, 0u]; // same corruption, no buildLoops() after

    size_t nSubject = fixOrientationOnce(subject);
    assert(nSubject == nControl,
        format("fixFaceOrientation must re-derive loops from the CURRENT "
            ~ "faces[] via its own ed.buildLoops() precondition, not "
            ~ "whatever loops the caller last built -- desynced-loops stand "
            ~ "flipped %d face(s), the freshly-resynced control flipped %d",
            nSubject, nControl));
    foreach (fi; 0 .. subject.faces.length)
        assert(subject.faces[fi][] == control.faces[fi][],
            "fixFaceOrientation's ed.buildLoops() precondition: desynced-loops "
            ~ "stand's face " ~ uintToStr(cast(uint)fi) ~ " diverged from the "
            ~ "freshly-resynced control -- the kernel analyzed STALE loops "
            ~ "instead of the faces[] actually passed to it");
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

    size_t n = cleanDegenerateOnce(m);
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

    size_t n = cleanDegenerateOnce(m);
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

// ===========================================================================
// THE RECORDING BATCH (task 1903 Stage E1).
//
// Everything above this line runs the family through an UNRECORDED batch and
// measures the mesh. These four blocks open a RECORDING one and measure the
// SEAM: the scope the batch declares, the op-log the kernel produces, and what
// `MeshEditDelta.revert` can and cannot put back. None of it is visible to a
// geometry assertion — a kernel that mutates through a bare `faces ~= …`
// instead of a hooked mutator produces the same mesh and an empty log.
//
// THE REVERT VERDICT IS MEASURED PER ENTRY, NOT ASSUMED, and the four entries
// of this one family land on THREE different answers (measured 2026-08-25, on
// the stands below, before these assertions were written):
//
//   unifyFaces            RemoveFaces                 -> COMPLETE
//   cleanDegenerateFaces  RemoveVerts, Reindex        -> faces do NOT come back
//   fixFaceOrientation    (empty)                     -> nothing comes back
//   cleanupMesh           RemoveFaces, RemoveVerts,
//                         Reindex                     -> counts yes, windings no
//
// That spread is the finding: "this family reverts" would have been true of
// one entry in four. The incomplete ones are written to REDDEN when track 2
// arms the missing publishers — and WHICH stage does so is read off the
// L-table (`doc/mesh_edit_seam_plan.md` §5.5), which is keyed by COMMAND and
// not by kernel, so this one file spans THREE of them:
//
//   mesh.cleanup        -> **L5**  cleanDegenerateFaces, cleanupMesh. L5 arms
//                                  `FaceReindex` at `cleanDegenerateFaces`, so
//                                  Stage J (`CornerCarry`'s `FaceReindex`
//                                  case) IS its prerequisite.
//   poly.unify          -> **L10** unifyFaces. `FaceReindex` + the vertex
//                                  `Reindex`; its delta already reverts whole.
//   mesh.fixOrientation -> **L2**  fixFaceOrientation. `AddVerts`/`AddFaces`/
//                                  `ReshapeFaces`, and the row says "needs
//                                  FaceReindex: NO" — so Stage J is NOT a
//                                  prerequisite for it and its message must
//                                  not send an L2 engineer looking at J.
//
// Each incomplete assertion carries in its OWN message the stage that flips it
// and what to rewrite when it does.
// ===========================================================================

private string dumpMeshState(ref Mesh m) {
    import std.format : format;
    string s = format("V=%d F=%d", m.vertices.length, m.faces.length);
    // `%a` — the HEX float form, so this compares BITS. `%g` would let a
    // `-0.0`/`+0.0` pair read as equal (task 1903 Stage D2's signed-zero cell).
    foreach (i, v; m.vertices) s ~= format(" v%d(%a,%a,%a)", i, v.x, v.y, v.z);
    foreach (i, f; m.faces)    s ~= format(" f%d%s", i, f.to!string);
    s ~= " marks" ~ m.faceMarks.to!string;
    return s;
}

/// One quad listed twice with reversed winding — the cell `unifyFaces` keys on
/// (same unordered vertex SET, opposite order).
private Mesh duplicateQuadStand() {
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0)];
    m.faces = [[0u,1u,2u,3u], [3u,2u,1u,0u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

/// Three faces that make `cleanDegenerateFaces` do BOTH of its jobs in one
/// call: face 1 is RESHAPED (a repeated index collapses [0,1,1,2] to a
/// triangle) and face 2 is DROPPED (three collinear points, zero Newell area).
/// A stand with only a drop would leave the reshape half of the revert
/// unmeasured, and the reshape is the half `rewriteFaces` never records.
private Mesh degenerateStand() {
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0), Vec3(2,0,0)];
    m.faces = [[0u,1u,2u,3u], [0u,1u,1u,2u], [0u,1u,4u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

/// A cube with face 1's vertex cycle reversed — the corruption
/// `fixFaceOrientation` exists to heal, and the only channel its revert could
/// possibly restore (no face or vertex is added or removed).
private Mesh corruptWindingCube() {
    Mesh m = makeCube();
    m.buildLoops();
    auto f = m.faces[1].dup;
    foreach (i, v; f) m.faces[1][i] = f[$ - 1 - i];
    m.buildLoops();
    m.resetSelection();
    return m;
}

/// Dirty enough that a DEFAULT `cleanupMesh` fires four of its six stages,
/// each on a DIFFERENT face, so the per-stage counts below discriminate:
///   * v4 is coincident with v1                       -> weld
///   * face 3 is three collinear points (zero area)   -> degenerate DROP
///   * faces 0 and 1 are the same quad once the weld
///     lands                                          -> unify
///   * v5 is a floating orphan                        -> compact
/// Face 2 (`[0,1,1,2]`) is the fifth cell and it is deliberately NOT counted
/// by the degenerate stage: the WELD's `applyVertexRemap` already collapses
/// its repeated index, measured — `degenerate` reads 0 for it. That is why
/// face 3 exists at all, and why the "reshaped face does not come back"
/// assertion at the bottom is attributed to the weld rather than to the
/// degenerate pass.
private Mesh dirtySweepStand() {
    Mesh m;
    m.vertices = [Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),
                  Vec3(1,0,0), Vec3(5,5,5), Vec3(2,0,0)];
    m.faces = [[0u,1u,2u,3u], [0u,4u,2u,3u], [0u,1u,1u,2u], [0u,1u,6u]];
    m.rebuildEdgesFromFaces();
    m.buildLoops();
    m.resetSelection();
    return m;
}

/// How many entries of `k` the delta's op-log carries.
private size_t countKind(ref MeshEditDelta d, MeshOpEntry.Kind k) {
    size_t n;
    foreach (ref e; d.log) if (e.kind == k) ++n;
    return n;
}

/// The scope every mutating entry of this family declares, written out from
/// the enum INDEPENDENTLY of `kCleanupEditScope`.
///
/// `d.scope_` IS `kCleanupEditScope` fed through `MeshEditTracker.declare`, so
/// `d.scope_ == kCleanupEditScope` is the measurement judging itself: set the
/// constant to 0 and that equality stays true. Measured at Stage D2, on the
/// reduce family, where exactly that draft stayed green under
/// `enum uint kReduceEditScope = 0;`. So the expectation below is written from
/// what the kernels DO — they drop faces (Polygons), compact the vertices
/// those drops orphan (Points) and re-mask the whole faceMarks word through
/// the non-committing `setFaceMarksFrom` (Marks) — and the equality against
/// the constant is asserted separately, AFTER it, where it can only see a
/// broken `declare`/`close` path.
private enum uint kExpectedCleanupScope = MeshEditScope.Points
                                        | MeshEditScope.Polygons
                                        | MeshEditScope.Marks;

private void assertDeclaredScope(string what, ref MeshEditDelta d) {
    import std.format : format;
    assert(cast(uint)d.scope_ == kExpectedCleanupScope,
        format("%s: a recording sweep declared scope 0x%x, expected 0x%x "
             ~ "(Points|Polygons|Marks). Missing: 0x%x. Unexpected: 0x%x. "
             ~ "`MeshEditDelta.finalize` reads scope_ back on a revert to "
             ~ "decide what to bump and rebuild, so a wrong constant is a "
             ~ "wrong invalidation, not a cosmetic mismatch "
             ~ "(task 1903 Stage E1)",
               what, cast(uint)d.scope_, kExpectedCleanupScope,
               kExpectedCleanupScope & ~cast(uint)d.scope_,
               cast(uint)d.scope_ & ~kExpectedCleanupScope));
    assert(cast(uint)d.scope_ == kCleanupEditScope,
        format("%s: the delta's scope_ (0x%x) is not the kCleanupEditScope the "
             ~ "batch was opened with (0x%x) — the declared scope is not "
             ~ "reaching MeshEditDelta.scope_ at all",
               what, cast(uint)d.scope_, kCleanupEditScope));
}

/// NO POSITION WRITE, EVER — the behavioural twin of `kCleanupEditScope`'s
/// "NOT Position" doc comment and of this file's §5.7 census count being 0
/// rather than a retired allow-entry. A weld keeps the survivor's own
/// coordinates, a dissolve and a compaction only DROP vertices, and the
/// degenerate pass never touches `vertices`.
private void assertNoPositionWrite(string what, ref MeshEditDelta d) {
    import std.format : format;
    immutable size_t setPos = countKind(d, MeshOpEntry.Kind.SetPos);
    assert(setPos == 0,
        format("%s: the op-log carries %d Kind.SetPos entries, expected 0 — a "
             ~ "cleanup kernel now moves an EXISTING vertex. That is a real "
             ~ "behaviour change: add MeshEditScope.Position to "
             ~ "kCleanupEditScope and rewrite its doc comment, or take the "
             ~ "write back out (task 1903 §5.7)", what, setPos));
}

unittest { // unifyFaces: the ONE entry of this family whose delta reverts whole
    import std.format : format;
    Mesh m = duplicateQuadStand();
    immutable string preState = dumpMeshState(m);
    immutable size_t preV = m.vertices.length, preF = m.faces.length;

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, kCleanupEditScope);   // RECORDING
        n = ed.unifyFaces();
        d = ed.close();
    }

    // Anti-vacuity: a stand with no duplicate returns 0 and every assertion
    // below is satisfied by a kernel that did nothing at all.
    assert(n == 1, format("the stand unified %d face(s), expected 1 — every "
                        ~ "assertion below would be vacuous on it", n));
    assert(m.faces.length == preF - 1,
        format("face count went %d -> %d", preF, m.faces.length));

    assertDeclaredScope("unifyFaces", d);
    assertNoPositionWrite("unifyFaces", d);

    // THE OP-LOG SHAPE. `deleteFacesByMask` is the hooked dropper and coalesces
    // the whole mask into ONE `RemoveFaces` entry; a kernel that filtered
    // `faces` by hand would leave the log empty and this at 0.
    immutable size_t removeFaces = countKind(d, MeshOpEntry.Kind.RemoveFaces);
    assert(removeFaces == 1,
        format("the op-log carries %d Kind.RemoveFaces entries, expected "
             ~ "exactly 1 — the duplicate must leave through "
             ~ "Mesh.deleteFacesByMask, which is the hooked dropper; a bare "
             ~ "`faces = kept` compiles inside a recording batch "
             ~ "(`alias mesh this`) and records nothing", removeFaces));

    // THE REVERT IS COMPLETE — measured, and it is the only entry of this
    // family for which that is true today. `deleteFacesByMask` records the
    // dropped windings AND their material/part/subpatch words, so the reverse
    // re-inserts them; nothing here rewrites a surviving face, so there is no
    // unrecorded reshape to lose. What this does NOT say is that `poly.unify`'s
    // undo is a constructor flip: that command's undo is still the whole-mesh
    // snapshot until **Stage L10** — `unify` sits in the L-table's
    // topo-misc/reindexing row, not in L5's cleanup row (§5.5).
    const bool reverted = d.revert(m);
    assert(reverted, "revert() refused the delta outright");
    assert(m.vertices.length == preV && m.faces.length == preF,
        format("revert restored V=%d F=%d, expected V=%d F=%d",
               m.vertices.length, m.faces.length, preV, preF));
    assert(dumpMeshState(m) == preState,
        format("revert restored the counts but not the state.\n  pre : %s\n"
             ~ "  post: %s", preState, dumpMeshState(m)));
}

unittest { // cleanDegenerateFaces: ARMED at Stage K — the whole edit reverts
    import std.format : format;
    Mesh m = degenerateStand();
    immutable string preState = dumpMeshState(m);
    immutable size_t preV = m.vertices.length, preF = m.faces.length;

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, kCleanupEditScope);   // RECORDING
        n = ed.cleanDegenerateFaces();
        d = ed.close();
    }

    // Anti-vacuity, and it has to name BOTH halves: 2 = one face DROPPED
    // (collinear) plus one face RESHAPED (repeated index collapsed away).
    assert(n == 2, format("the stand affected %d face(s), expected 2 (one "
                        ~ "dropped, one reshaped) — every assertion below "
                        ~ "would be vacuous on it", n));
    immutable size_t postV = m.vertices.length, postF = m.faces.length;
    assert(postF == preF - 1 && postV == preV - 1,
        format("the stand went V=%d F=%d -> V=%d F=%d, expected one face "
             ~ "dropped and its orphaned vertex compacted",
               preV, preF, postV, postF));

    assertDeclaredScope("cleanDegenerateFaces", d);
    assertNoPositionWrite("cleanDegenerateFaces", d);

    // THE VERTEX SIDE IS RECORDED. `compactUnreferenced` is hooked, so the
    // orphan's removal and the remap that follows it are both in the log.
    assert(countKind(d, MeshOpEntry.Kind.RemoveVerts) == 1
        && countKind(d, MeshOpEntry.Kind.Reindex) == 1,
        format("the op-log carries %d RemoveVerts and %d Reindex entries, "
             ~ "expected 1 and 1 — the vertex the dropped face orphaned "
             ~ "leaves through Mesh.compactUnreferenced, which is hooked",
               countKind(d, MeshOpEntry.Kind.RemoveVerts),
               countKind(d, MeshOpEntry.Kind.Reindex)));

    // THE FACE SIDE IS RECORDED TOO, SINCE STAGE K (2026-08-27). This kernel
    // hands one whole new face array to `mesh_planes.rewriteFaces` and records
    // its face change nowhere else, so Stage K wrapped that call in a
    // `faceReindexScope()` and the publisher now fires. This block used to
    // assert the OPPOSITE — "no face entry, and the revert leaves the
    // post-clean face count while answering true" — and its own message named
    // this as the flip. It is not a widening of what was asserted: the
    // incomplete-revert assertions have been REPLACED by the complete ones,
    // so a regression that disarms the scope reddens here rather than going
    // quietly back to the weaker law.
    //
    // ONE entry, not two: `RemoveFaces`/`ReshapeFaces` must stay at zero.
    // Both would describe the same drop a second time, and the LIFO revert
    // would then re-insert the face TWICE — the double revert the per-rewrite
    // scope exists to prevent (plan §5.3, "K's red row";
    // tests/unit/face_reindex_arming_test.d drives the mixed batch that shows
    // it end to end).
    assert(countKind(d, MeshOpEntry.Kind.FaceReindex) == 1
        && countKind(d, MeshOpEntry.Kind.RemoveFaces) == 0
        && countKind(d, MeshOpEntry.Kind.ReshapeFaces) == 0,
        format("the op-log carries %d FaceReindex / %d RemoveFaces / %d "
             ~ "ReshapeFaces entr(ies), expected 1 / 0 / 0. ZERO FaceReindex "
             ~ "means `cleanDegenerateFaces`' rewrite lost its "
             ~ "`faceReindexScope()` and the face side of this delta is "
             ~ "unrecorded again. MORE THAN ONE, or a RemoveFaces beside it, "
             ~ "means the same drop is described twice and the revert will "
             ~ "overshoot (task 1903 Stage K, plan §5.3)",
               countKind(d, MeshOpEntry.Kind.FaceReindex),
               countKind(d, MeshOpEntry.Kind.RemoveFaces),
               countKind(d, MeshOpEntry.Kind.ReshapeFaces)));
    const bool reverted = d.revert(m);
    assert(reverted, "revert() refused the delta outright");
    assert(m.vertices.length == preV,
        format("revert restored %d vertices of %d", m.vertices.length, preV));
    assert(m.faces.length == preF,
        format("revert restored %d faces (pre-clean %d, post-clean %d) — the "
             ~ "dropped collinear face must come back with the armed entry",
               m.faces.length, preF, postF));
    assert(m.faces[1].length == 4,
        format("face 1 was RESHAPED from [0,1,1,2] to a triangle by the "
             ~ "collapse and came back with arity %d, expected 4. A face "
             ~ "COUNT that comes back while a WINDING does not is the failure "
             ~ "mode a count-only revert assertion cannot see, which is why "
             ~ "this channel is separate from the count above",
               m.faces[1].length));
    assert(dumpMeshState(m) == preState,
        format("revert restored the counts but not the state.\n  pre : %s\n"
             ~ "  post: %s", preState, dumpMeshState(m)));
}

unittest { // fixFaceOrientation: the delta is EMPTY, so its revert is a no-op
    import std.format : format;
    Mesh m = corruptWindingCube();
    const uint[] corrupted = m.faces[1].dup;
    immutable string preState = dumpMeshState(m);

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, kCleanupEditScope);   // RECORDING
        n = ed.fixFaceOrientation();
        d = ed.close();
    }

    // Anti-vacuity, and here it is the whole point: this kernel adds and
    // removes NOTHING, so a count-based check cannot tell "healed one face"
    // from "did nothing". The winding itself is the only channel.
    assert(n == 1, format("the stand flipped %d face(s), expected 1 — every "
                        ~ "assertion below would be vacuous on it", n));
    assert(m.faces[1] != corrupted,
        "the stand's corrupted winding was not actually rewritten, so the "
      ~ "revert claim below would be trivially satisfied");

    assertDeclaredScope("fixFaceOrientation", d);
    // NOT `assertNoPositionWrite` here, and the omission is deliberate: this
    // kernel's op-log is EMPTY (measured, asserted below), so a "no SetPos
    // entry" check on it cannot come out differently. The claim it would make
    // is subsumed by `d.log.length == 0`.

    // FLIPPED BY STAGE L2-a, 2026-08-27, EXACTLY AS THIS BLOCK WAS WRITTEN TO
    // BE. What stood here until then were three assertions in their NEGATIVE
    // form — `d.log.length == 0`, `m.faces[1] != corrupted`,
    // `dumpMeshState(m) != preState` — each labelled "STAGE L2 FLIPS THIS" and
    // each naming the fix: a `recordReshapeFaces` call INSIDE the primitive
    // `Mesh.flipFacesByMask`, which until L2-a reversed a face's vertex cycle
    // in place, added/removed/reordered no slot, reached no hooked mutator, and
    // so produced an EMPTY op-log whose `revert()` answered TRUE and changed
    // nothing.
    //
    // THAT IS WHY THIS BLOCK IS WORTH MORE THAN A PLAN ROW: it could not be
    // green both before and after. It was red on the unmodified tree the
    // moment `flipFacesByMask` started routing its windings through
    // `Mesh.setFaceWindings`, with the message above naming the entry count it
    // had just gained.
    //
    // WHY ONE ENTRY AND NOT THE `[MeshMapDelta, ReshapeFaces]` PAIR that
    // `mesh.flip`'s own cells assert: `corruptWindingCube()` carries no
    // PolyVertex map, so `recordPolyVertexPayload` declines and there is
    // nothing for a payload to hold. The pair — and the corner PERMUTATION it
    // exists to restore — is measured on a stand that has one,
    // `tests/unit/flip_and_spin_delta_test.d` cell C. A cube is the wrong
    // stand for that half and the right one for this.
    assert(d.log.length == 1,
        format("fixFaceOrientation's op-log carries %d entr(ies), expected 1 "
             ~ "(a ReshapeFaces over the healed face). ZERO is the pre-L2 "
             ~ "state, in which the revert below is a silent no-op",
               d.log.length));
    assert(d.log[0].kind == MeshOpEntry.Kind.ReshapeFaces,
        format("the entry is %s, expected ReshapeFaces", d.log[0].kind));
    const bool reverted = d.revert(m);
    assert(reverted, "revert() refused the delta outright");
    assert(m.faces[1] == corrupted,
        format("revert() left face 1 healed (%s); the pre-op winding was %s. "
             ~ "An equal-arity winding rewrite changes no count, so this "
             ~ "per-winding compare is the only channel that can see a revert "
             ~ "which answered true and did nothing",
               m.faces[1].to!string, corrupted.to!string));
    assert(dumpMeshState(m) == preState,
        format("revert() restored the winding but not the whole state.\n"
             ~ "  pre : %s\n  post: %s", preState, dumpMeshState(m)));
}

unittest { // cleanupMesh: the six-stage sweep, and the three channels it loses
    import std.format : format;
    Mesh m = dirtySweepStand();
    immutable size_t preV = m.vertices.length, preF = m.faces.length;
    const uint[] preFace1 = m.faces[1].dup;

    MeshEditDelta d;
    CleanupResult r;
    {
        auto ed = MeshEditBatch(m, kCleanupEditScope);   // RECORDING
        r = ed.cleanupMesh();
        d = ed.close();
    }

    // Anti-vacuity, PER STAGE: the stand is built so that three of the six
    // fire on three different faces, and a stand where only one fires would
    // make the op-log shape below agree for the wrong reason. The two zeros
    // are measured facts about this stand, not slack: `removeOrphans`' own
    // compactions find nothing left to do because `cleanDegenerateFaces` and
    // `unifyFaces` each run one internally when they fire, and
    // `dissolve2Valent` is off by default.
    assert(r.welded == 1 && r.degenerate == 1 && r.unified == 1,
        format("the sweep reported welded=%d degenerate=%d unified=%d, "
             ~ "expected 1/1/1 — this stand exists to make all three fire in "
             ~ "one call", r.welded, r.degenerate, r.unified));
    assert(r.orphans == 0 && r.dissolved == 0 && r.finalOrphans == 0,
        format("the sweep reported orphans=%d dissolved=%d finalOrphans=%d, "
             ~ "expected 0/0/0 — the earlier stages' internal compactions "
             ~ "already removed every orphan, and dissolve2Valent is off by "
             ~ "default", r.orphans, r.dissolved, r.finalOrphans));
    immutable size_t postV = m.vertices.length, postF = m.faces.length;
    assert(postV == 4 && postF == 2,
        format("the sweep left V=%d F=%d, expected V=4 F=2", postV, postF));

    assertDeclaredScope("cleanupMesh", d);
    assertNoPositionWrite("cleanupMesh", d);

    // THE OP-LOG SHAPE across a multi-stage sweep — and since Stage K this is
    // the one PRODUCTION cell in the tree where an ARMED rewrite and a
    // `RemoveFaces`-recording op share a single batch, which is exactly the
    // pairing the per-rewrite arming scope exists for. `cleanDegenerateFaces`
    // drops its collinear face through `mesh_planes.rewriteFaces` inside a
    // `faceReindexScope()`; `unifyFaces` drops its duplicate through the
    // hooked `Mesh.deleteFacesByMask`, which records `RemoveFaces` itself.
    //
    // ASSERTED AS A KIND *SEQUENCE*, NOT AS COUNTS, and that is task 1903
    // Stage L5-a's own change to this block rather than a style preference.
    // Before L5-a there was exactly ONE `FaceReindex` here and a count
    // discriminated fine. L5-a arms the WELD's rewrite too
    // (`Mesh.applyVertexRemap`), so the honest reading is now TWO — and a
    // count of 2 cannot tell "two arms, one per rewrite" from "one arm leaked
    // across both rewrites", which is exactly the failure the per-rewrite
    // scope exists to prevent (the double revert Stage E1 measured, which
    // lands the face count PAST where it started — plan §5.3 "K's red row";
    // `tests/unit/face_reindex_arming_test.d` drives the same pairing
    // directly). The POSITION is what separates them:
    //
    //   0 FaceReindex  the WELD's rewrite       (Mesh.applyVertexRemap, L5-a)
    //   1 FaceReindex  cleanDegenerateFaces'    (Stage K)
    //   2 RemoveVerts ─┐ cleanDegenerateFaces' internal compaction
    //   3 Reindex     ─┘
    //   4 RemoveFaces  unifyFaces, through the hooked `deleteFacesByMask` —
    //                  which records the drop ITSELF and is therefore NOT armed
    //
    // NO `MeshMapDelta` HERE, and that is a property of THIS stand, stated so
    // the absence is not read as a rule: `dirtySweepStand` carries no
    // PolyVertex map, so `CornerCarry` has nothing to place. The same sweep on
    // a map-carrying stand emits the contractual `[MeshMapDelta, FaceReindex]`
    // pair at each rewrite and a third before the `RemoveFaces` — measured on
    // `makeTaggedGridDirty(3)` and asserted by
    // `tests/unit/undo_parity_l5_test.d`, which is where the payload-adjacency
    // half of this shape is pinned.
    //
    // A leaked arm APPENDS a `FaceReindex` after the `RemoveFaces`; a lost arm
    // on either rewrite drops ITS entry. Neither is a length change alone, which is why
    // this is not `d.log.length == 5` either (памятка W-SHAPE: never a length,
    // never a bare count).
    {
        string got;
        foreach (i, ref e; d.log) { if (i) got ~= ", "; got ~= e.kind.to!string; }
        immutable string want =
            "FaceReindex, FaceReindex, RemoveVerts, Reindex, RemoveFaces";
        assert(got == want,
            format("the sweep's op-log KIND SEQUENCE is\n  [%s]\nexpected\n"
                 ~ "  [%s]\nPosition 0 is the WELD's rewrite (armed at "
                 ~ "`Mesh.applyVertexRemap`, task 1903 Stage L5-a); position 1 "
                 ~ "is `cleanDegenerateFaces`' (Stage K). A `FaceReindex` "
                 ~ "ANYWHERE AFTER the `RemoveFaces` means an arm LEAKED "
                 ~ "across the unify's drop, which `deleteFacesByMask` already "
                 ~ "describes with that `RemoveFaces` — the drop recorded "
                 ~ "twice, and a LIFO revert that lands the face count PAST "
                 ~ "where it started (measured: the `unifyFaces` block above "
                 ~ "reddens with V=4 F=3 against V=4 F=2). A MISSING entry "
                 ~ "means a rewrite lost its scope and its face change is "
                 ~ "unrecorded again", got, want));
    }

    // COMPLETE ON THIS STAND SINCE STAGE L5-a. Stage K closed the degenerate
    // stage's hole; L5-a closed the WELD's, by arming
    // `Mesh.applyVertexRemap`'s rewrite. The two channels below are the ones
    // that were INVERTED before L5-a — they asserted the loss — and they are
    // kept as per-WINDING and per-ARITY compares rather than folded into the
    // count above for the reason that made them worth pre-placing: a weld
    // changes no face count in the general case, so face count, vertex count,
    // edge count and every mark word can all round-trip while `faces[1]` comes
    // back remapped and `revert()` answers `true`.
    const bool reverted = d.revert(m);
    assert(reverted,
        "revert() refused the delta outright — that is a THIRD state, neither "
      ~ "the incomplete revert measured here nor the complete one L5 owes");
    assert(m.vertices.length == preV,
        format("revert restored %d vertices of %d — the VERTEX side of this "
             ~ "delta (RemoveVerts + Reindex) is the half that has been "
             ~ "complete since Stage E1", m.vertices.length, preV));
    assert(m.faces.length == preF,
        format("revert restored %d faces of %d. Since Stage K BOTH drops are "
             ~ "recorded — the unify's through `RemoveFaces` and the "
             ~ "degenerate stage's through `FaceReindex` — so the count must "
             ~ "come back whole. `preF - 1` is the pre-K reading (the "
             ~ "degenerate drop unrecorded); `preF + 1` is the DOUBLE REVERT, "
             ~ "one face re-inserted twice", m.faces.length, preF));
    assert(m.faces[1] == preFace1,
        format("revert() left face 1 at %s; its PRE-WELD winding was %s. The "
             ~ "weld's face-index rewrite goes through `Mesh.applyVertexRemap`, "
             ~ "ARMED since task 1903 Stage L5-a, so the pre-weld winding must "
             ~ "come back. MUTATION THAT REDDENS THIS: delete the "
             ~ "`faceReindexScope()` arm at that rewrite — the face count, the "
             ~ "vertex count, the edge count and every mark word still "
             ~ "round-trip and `revert()` still answers TRUE, and this compare "
             ~ "is the only channel in the block that can see it",
               m.faces[1].to!string, preFace1.to!string));
    assert(m.faces[2].length == 4,
        format("revert() left face 2 at arity %d, expected 4. Face 2 was "
             ~ "[0,1,1,2] and the WELD's remap collapsed its repeated index to "
             ~ "a triangle; since L5-a that collapse is described by the weld's "
             ~ "own `FaceReindex` and the revert must put the 4-corner winding "
             ~ "back. This is the ARITY channel and it is separate from the "
             ~ "winding compare above on purpose: an entry that restores "
             ~ "windings for equal-arity faces only would pass that one and "
             ~ "fail this", m.faces[2].length));
    assert(m.faces[2] == [0u, 1u, 1u, 2u],
        format("face 2's arity came back but its winding did not: %s, expected "
             ~ "[0, 1, 1, 2]. The repeated index IS the thing the weld "
             ~ "collapsed, so an arity-only restore is a restore of the wrong "
             ~ "corners", m.faces[2].to!string));
}
