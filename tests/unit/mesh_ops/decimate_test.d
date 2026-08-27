// Module unittests for `mesh_ops.decimate`, moved verbatim out of source/mesh_ops/decimate.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_ops.decimate_test;

import mesh;
import math;
import mesh_ops.decimate;
import mesh_edit_delta : MeshEditScope, MeshEditDelta, MeshOpEntry;

// TASK 1903 Stage D2 — `reduceToTarget` is a free function over
// `ref MeshEditBatch` now, so a test cannot call it on a bare `Mesh` any more:
// that is the point of the receiver, and it is why these three call sites
// changed. The batches below are UNRECORDED for the same reason the two
// production callers' are (see source/mesh_ops/decimate.d's header): nothing
// here reads an op-log, and track 1 is the conversion axis only.
private size_t reduceOnce(ref Mesh m, size_t targetFaces, bool preserveBoundary) {
    auto ed = MeshEditBatch.unrecorded(m, kReduceEditScope);
    const n = ed.reduceToTarget(targetFaces, preserveBoundary);
    ed.close();
    return n;
}

unittest { // reduceToTarget no-op: target >= current face count
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto triMask = new bool[](m.faces.length); triMask[] = true;
    m.triangulateFacesByMask(triMask); // 12 tris
    assert(m.faces.length == 12);
    size_t n = reduceOnce(m, 12, true);
    assert(n == 0, "target==current must return 0, got " ~ n.to!string);
    assert(m.faces.length == 12, "mesh must be unchanged");
}

unittest { // reduceToTarget: tri cube → ~50% faces, manifold, no degenerate
    import std.conv : to;
    Mesh m = makeCube();
    m.buildLoops();
    auto triMask = new bool[](m.faces.length); triMask[] = true;
    m.triangulateFacesByMask(triMask);
    assert(m.faces.length == 12);

    size_t f0 = 12;
    size_t target = 6;
    size_t n = reduceOnce(m, target, false);
    assert(n > 0, "expected at least 1 collapse");
    assert(m.faces.length <= f0, "face count must not increase");
    assert(m.vertices.length < 8, "vertex count must decrease");

    // No degenerate face: every face must have >= 3 distinct corners,
    // and Newell area > 0.
    import std.math : sqrt;
    foreach (fi; 0 .. m.faces.length) {
        const uint[] f = m.faces[fi];
        assert(f.length >= 3, "face " ~ fi.to!string ~ " has fewer than 3 corners");
        bool[uint] seen;
        foreach (vi; f) {
            assert(!(vi in seen), "face " ~ fi.to!string ~ " has duplicate corner");
            seen[vi] = true;
        }
        // Newell area.
        float nx = 0, ny = 0, nz = 0;
        foreach (i; 0 .. f.length) {
            Vec3 a = m.vertices[f[i]];
            Vec3 b = m.vertices[f[(i+1)%f.length]];
            nx += (a.y-b.y)*(a.z+b.z);
            ny += (a.z-b.z)*(a.x+b.x);
            nz += (a.x-b.x)*(a.y+b.y);
        }
        assert(sqrt(nx*nx+ny*ny+nz*nz) > 1e-6f,
               "face " ~ fi.to!string ~ " has near-zero area");
    }

    // Manifold check: every edge appears on at most 2 faces.
    int[ulong] edgeFaceCnt;
    foreach (fi; 0 .. m.faces.length) {
        const uint[] f = m.faces[fi];
        foreach (i; 0 .. f.length) {
            uint a = f[i], b = f[(i+1)%f.length];
            ulong key = a < b ? (cast(ulong)a << 32 | b) : (cast(ulong)b << 32 | a);
            edgeFaceCnt[key]++;
        }
    }
    foreach (key, cnt; edgeFaceCnt)
        assert(cnt <= 2, "edge 0x" ~ key.to!string(16) ~ " on " ~ cnt.to!string ~ " faces");
}

unittest { // reduceToTarget preserveBoundary=true: boundary positions kept, interior collapses happen
    import std.conv : to;
    import std.math : sqrt;

    // Build a denser open mesh so interior (non-boundary) edges are available for
    // collapse.  facetedSubdivide turns 6 quads → 24 quads (26 verts); triangulate
    // → 48 tris; removing the last tri opens a 3-edge boundary → 47 tris, 3 boundary
    // verts, 23 interior verts with many collapsible interior edges between them.
    Mesh m = makeCube();
    {
        bool[] allF; allF.length = m.faces.length; allF[] = true;
        m = facetedSubdivide(m, allF);   // 26 verts, 24 quads; buildLoops already called
    }
    {
        auto triMask = new bool[](m.faces.length); triMask[] = true;
        m.triangulateFacesByMask(triMask);   // 48 tris
    }
    // Remove the last triangle to open the mesh.
    {
        uint[][] newFaces;
        foreach (fi; 0 .. m.faces.length - 1) newFaces ~= m.faces[fi].dup;
        m.faces = FaceList.init;
        foreach (f; newFaces) m.addFace(f);
        m.buildLoops();
    }
    assert(m.faces.length == 47, "expected 47 tris after removing one from 48");

    // Capture boundary vertex positions before reduce.
    Vec3[] bpos;
    {
        bool[] isBV; isBV.length = m.vertices.length;
        foreach (uint ei; 0 .. cast(uint)m.edges.length) {
            uint va = m.edges[ei][0], vb = m.edges[ei][1];
            // Task 0447: EdgeFaceRange's constructor now needs the fan-order
            // state + CSR — go through the public accessor instead of building
            // the range by hand (its private members aren't reachable here).
            int cnt = 0; foreach (_; m.facesAroundEdge(ei)) ++cnt;
            if (cnt < 2) { isBV[va] = true; isBV[vb] = true; }
        }
        foreach (vi, b; isBV) if (b) bpos ~= m.vertices[vi];
    }
    assert(bpos.length > 0, "open mesh must have boundary verts");

    // Reduce; the dense interior gives plenty of collapsible non-boundary edges.
    size_t n = reduceOnce(m, 40, true);
    assert(n > 0, "expected >0 interior collapses on denser mesh; got 0 -- "
                ~ "preserveBoundary guard may be over-rejecting or fixture is degenerate");

    // Every original boundary position must still exist in the post-reduce mesh.
    foreach (bp; bpos) {
        bool found = false;
        foreach (vp; m.vertices) {
            float dx = vp.x - bp.x, dy = vp.y - bp.y, dz = vp.z - bp.z;
            if (sqrt(dx*dx + dy*dy + dz*dz) < 1e-5f) { found = true; break; }
        }
        assert(found, "boundary position (" ~ bp.x.to!string ~ ","
                    ~ bp.y.to!string ~ "," ~ bp.z.to!string ~ ") lost after reduce");
    }

    // Structural sanity.
    assert(m.faces.length <= 47, "face count must not increase");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi].length >= 3, "degenerate face after reduce");
}


// ===========================================================================
// THE RECORDING BATCH — the only lane in the tree that can see what this
// kernel declares and what it records (task 1903 Stage D2 review, MAJOR-3).
//
// Every production caller opens an UNRECORDED batch (§5.1: track 1 is the
// conversion axis, undo still goes through a whole-mesh `MeshSnapshot`), so
// `kReduceEditScope` reaches nothing but `MeshEditTracker.declare`, and
// `pushEditFrame` only calls that when a recorder exists. Measured: setting
// `kReduceEditScope = 0` left 275 modules and `test_reduce` green. A constant
// no test can read is a constant that can drift to anything.
//
// A recording batch is also `setVertexPositions`' FIRST red-capable
// behavioural witness. Plan §5.7 says "D2 cannot prove `setVertexPositions` is
// load-bearing; only L10 can" — that is true of the production UNDO path, and
// not of a unit-level recording batch, where the raw write's missing op-log
// entry is directly visible.
//
// Mutations:
//   * `enum uint kReduceEditScope = 0;`                    → assertion (a)
//   * `ed.setVertexPositions(setIdx, setTo)` → the raw
//     `foreach (i; 0 .. V) ed.vertices[i] = pos[find(cast(int)i)];`
//                                                          → assertion (b)
// Neither mutation reddens an earlier block in this module (both leave the
// forward result byte-identical), so druntime's stop-at-first-assert does not
// hide either one behind the blocks above.
// ===========================================================================

unittest // a recording reduce declares kReduceEditScope and records the SetPos
{
    import std.format : format;

    // A stand dense enough to collapse a lot: subdivideCube(2) triangulated is
    // V=98 / F=192, and target = F/2 makes 48 collapses.
    Mesh m = subdivideCube(2);
    {
        auto k = new bool[](m.faces.length); k[] = true;
        m.triangulateFacesByMask(k);
    }
    immutable size_t preV = m.vertices.length;
    immutable size_t preF = m.faces.length;

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, kReduceEditScope);   // RECORDING
        n = ed.reduceToTarget(preF / 2, false);
        d = ed.close();
    }

    // Anti-vacuity: a stand that does not collapse would satisfy (a) and (c)
    // trivially and could not exhibit (b) at all.
    assert(n > 0, "the stand did not collapse — every assertion below would be "
                ~ "vacuous on it");
    assert(m.faces.length < preF,
        format("reduce left the face count at %d — nothing was dropped",
               m.faces.length));
    immutable size_t postF = m.faces.length;

    // (a) THE DECLARED SCOPE, spelled out from the enum and NOT compared
    //     against `kReduceEditScope` itself.
    //
    //     `d.scope_` IS `kReduceEditScope` fed through
    //     `MeshEditTracker.declare`, so `d.scope_ == kReduceEditScope` is the
    //     measurement judging itself: set the constant to 0 and that equality
    //     is still true. Measured — the first draft of this block asserted
    //     exactly that and stayed green under `enum uint kReduceEditScope = 0;`,
    //     which is the same inertness the review found in the constant to begin
    //     with. The expectation below is written from what the kernel DOES:
    //     it drops faces (Polygons), welds vertices away (Points), rewrites
    //     selection / subpatch / hide words in the weld (Marks) and moves every
    //     cluster member onto its representative (Position). `MeshEditDelta`'s
    //     `finalize` reads `scope_` back on a revert to decide what to bump and
    //     rebuild, so a wrong constant is a wrong invalidation at L10, not a
    //     cosmetic mismatch.
    immutable uint kExpectedScope = MeshEditScope.Points | MeshEditScope.Polygons
                                  | MeshEditScope.Marks  | MeshEditScope.Position;
    assert(cast(uint)d.scope_ == kExpectedScope,
        format("a recording reduce declared scope 0x%x, expected 0x%x "
             ~ "(Points|Polygons|Marks|Position). Missing: 0x%x. Unexpected: "
             ~ "0x%x. (task 1903 Stage D2)",
               cast(uint)d.scope_, kExpectedScope,
               kExpectedScope & ~cast(uint)d.scope_,
               cast(uint)d.scope_ & ~kExpectedScope));

    //     …and THEN the link: the constant is what the callers pass and what
    //     reaches the delta. This one cannot see a wrong constant (see above);
    //     it sees a broken `declare`/`close` path.
    assert(cast(uint)d.scope_ == kReduceEditScope,
        format("the delta's scope_ (0x%x) is not the kReduceEditScope the "
             ~ "batch was opened with (0x%x) — the declared scope is not "
             ~ "reaching MeshEditDelta.scope_ at all",
               cast(uint)d.scope_, kReduceEditScope));

    // (b) THE RECORDED FINALISE WRITE. A raw `ed.vertices[i] = …` moves the
    //     same coordinates and records NOTHING; this is the assertion that can
    //     tell the two apart today.
    size_t setPosEntries;
    foreach (ref e; d.log)
        if (e.kind == MeshOpEntry.Kind.SetPos) ++setPosEntries;
    assert(setPosEntries == 1,
        format("the op-log carries %d Kind.SetPos entries, expected exactly 1 "
             ~ "— the finalise that coincides every cluster member onto its "
             ~ "representative must go through "
             ~ "MeshEditBatch.setVertexPositions. A raw `vertices[i] = …` "
             ~ "write compiles inside a recording batch (`alias mesh this`) "
             ~ "and produces no entry, so a delta undo would restore the "
             ~ "topology and leave every coordinate at its post-collapse "
             ~ "value (task 1903 §2.5, §5.7 M-D2)", setPosEntries));

    // (c) KNOWN-INCOMPLETE, AND L10 FLIPS THIS. Reverting the delta restores
    //     the VERTEX side and not the FACE side: the dropped faces leave
    //     through weldVerticesByMask → Mesh.applyVertexRemapAndRebuild →
    //     mesh_planes.rewriteFaces, whose op-log publisher is gated on
    //     `MeshEditTracker.wantsFaceReindex` (`rewriteFaces`'s own
    //     `m.wantsFaceReindexRecording()` gate) —
    //     default false and armed by no production code. So `revert()` answers
    //     TRUE over a mesh that has lost half its faces, which is exactly the
    //     shape Stage B named as the precondition for the `&rw` site: a kernel
    //     migrating to a delta must ARM FaceReindex or REFUSE to write one.
    //
    //     This assertion is written to REDDEN when that is fixed. When L10
    //     arms the face side, `revert` will restore preF and the line below
    //     fails with the message naming itself — flip it to
    //     `assert(m.faces.length == preF)` then, and delete this paragraph.
    const bool reverted = d.revert(m);
    assert(reverted,
        "revert() refused the delta outright — that is a THIRD state, neither "
      ~ "the incomplete revert measured at D2 nor the complete one L10 owes; "
      ~ "re-measure before changing this block");
    assert(m.vertices.length == preV,
        format("revert restored %d vertices of %d — the vertex side of this "
             ~ "delta (RemoveVerts + Reindex + SetPos) is the half that IS "
             ~ "complete today", m.vertices.length, preV));
    assert(m.faces.length == postF && m.faces.length != preF,
        format("L10 FLIPS THIS. revert() restored %d faces (pre-reduce %d, "
             ~ "post-reduce %d). At Stage D2 the face side of a reduce delta "
             ~ "is NOT recorded — rewriteFaces' FaceReindex publisher is "
             ~ "disarmed by default — so revert leaves the post-reduce face "
             ~ "count and still answers true. If this line just went red "
             ~ "because the faces came back, that is L10 landing: change this "
             ~ "to `m.faces.length == preF`, and update decision (3) in "
             ~ "source/mesh_ops/decimate.d's header, which says L10 owes this "
             ~ "family a face-side publisher decision rather than a "
             ~ "constructor flip", m.faces.length, preF, postF));
}

unittest { // THE WITNESS: reduceToTarget's collapse heap must not allocate
    // quadratically (task 2130/2240).
    //
    // Same defect shape task 2130 fixed at four sibling stack walks, but on a
    // BINARY MIN-HEAP rather than a plain stack: the old heapPop() did `heap[0]
    // = heap[$ - 1]; heap.length--;` (pop by shrinking the slice) and heapPush()
    // did `heap ~= e;` (push by appending) — the GC's in-place-append invariant
    // needs `ptr + length` to match the used-length recorded in the block, and
    // the shrink breaks exactly that, so the first heapPush after EVERY
    // heapPop reallocated and copied the whole heap. The main collapse loop
    // calls heapPop then (usually) several heapPush calls per iteration, so a
    // reduction with many collapses is exactly the interleaved pop/push
    // pattern task 2130 measured elsewhere.
    //
    // Fixed with an explicit length pointer (`hlen`) rather than `heap.length`
    // — see the comment above `heap` in source/mesh_ops/decimate.d for why this
    // is safe for a HEAP specifically: every read/write only ever touches an
    // index below the CURRENT `hlen`, so the pop order (and therefore the
    // downstream collapse order / final geometry) is bit-identical to before.
    import core.memory : GC;
    import std.format  : format;

    Mesh m = makeGridPlane(60); // 61x61 = 3721 verts, 3600 quads
    auto triMask = new bool[](m.faces.length); triMask[] = true;
    m.triangulateFacesByMask(triMask);
    immutable size_t f0 = m.faces.length; // 7200 triangles
    immutable size_t target = f0 / 4;     // force ~thousands of collapses

    // Measured on this rig, 2026-08-27, with the same instrument, 2760
    // collapses from 7200 faces:
    //   shrink-then-append (before the fix) ....  1 502 695 600 B (1433.08 MB)
    //   explicit length pointer (after) ........     16 851 120 B (  16.07 MB)
    // Unlike connected_mask/falloff's isolated walk, `reduceToTarget` also
    // allocates for the union-find / alive / incident-face / candidate-face
    // scratch that has nothing to do with the heap, so the achievable gap is
    // narrower (~89x total, not ~2000x) — the bound sits inside it with ~4x
    // headroom over the fixed code and ~22x under the broken code, not
    // derived from either measurement.
    enum ulong kBoundBytes = 64UL * 1024 * 1024;

    immutable ulong before = GC.allocatedInCurrentThread;
    size_t n = reduceOnce(m, target, false);
    immutable ulong used = GC.allocatedInCurrentThread - before;

    // Anti-vacuity: prove the rig actually did a large number of collapses,
    // not a no-op or a handful.
    assert(n > 1000,
        format("expected thousands of collapses from %d faces to target %d, "
             ~ "got %d — the rig cannot exhibit a heap-churn defect with too "
             ~ "few", f0, target, n));
    assert(m.faces.length <= f0, "face count must not increase");

    assert(used < kBoundBytes,
        format("reduceToTarget allocated %s B (%.2f MB) doing %d collapses "
             ~ "from %d faces; the bound is %s B (%.2f MB). This is the "
             ~ "shrink-then-append defect (task 2130/2240): heapPop's "
             ~ "`heap.length--` breaks the GC's in-place-append invariant, so "
             ~ "the first heapPush after every heapPop reallocates and copies "
             ~ "the whole heap. Use an explicit length pointer — never shrink "
             ~ "the slice.",
               used, used / (1024.0 * 1024.0), n, f0,
               kBoundBytes, kBoundBytes / (1024.0 * 1024.0)));
}
