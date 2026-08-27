// test_mesh_edit_delta.d — Phase 1 unit tests for the mesh-edit change tracker
// (per-mutation operation-log undo). PURE-D, in-process: builds Meshes directly
// (no HTTP, no GL), drives SYNTHETIC mutation sequences through a manually-opened
// edit batch, and asserts that revert() restores byte-identical pre-batch
// geometry and apply() re-applies. Mirrors the source-backed unittest pattern of
// tests/test_mesh_map.d (run via `./run_test.d mesh_edit_delta`, dmd -unittest -i).
//
// Cases:
//   (a) pure append: addVertex + addFace → revert truncates tail → original;
//       apply() re-creates the post-batch mesh.
//   (b) compaction: delete faces so verts orphan → compactUnreferenced fires
//       (RemoveVerts + Reindex) → revert restores pre-batch vertex INDEXING and
//       positions exactly. The load-bearing Reindex^-1 case.
//   (c) reshape: dissolve a vertex so a quad becomes a tri (ReshapeFaces) →
//       revert restores the original face list.
//   (d) selection / subpatch / material sparse-delta round-trip.
//
// NEGATIVE CONTROL is exercised out-of-band (recompile with
// -version=UndoNegControlReindex / -version=UndoNegControlReshape) — see the
// task report; those stubs live in source/mesh_edit_delta.d.

import std.math : fabs;

import mesh : Mesh, makeCube;
import mesh_edit_delta : MeshEditTracker, MeshEditDelta, MeshEditScope, MeshOpEntry;
import math : Vec3;

void main() {}

// ---------------------------------------------------------------------------
// Geometry equality helpers — "byte-identical" means same vertex count +
// positions and same face vertex-lists. Edges are dedup-derived (re-built by
// finalize) so we compare them too, but they follow deterministically.
// ---------------------------------------------------------------------------
private bool sameVerts(in Vec3[] a, in Vec3[] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (a[i] != b[i]) return false;
    return true;
}

private bool sameFaces(in uint[][] a, in uint[][] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length) {
        if (a[i].length != b[i].length) return false;
        foreach (k; 0 .. a[i].length)
            if (a[i][k] != b[i][k]) return false;
    }
    return true;
}

private bool sameEdges(in uint[2][] a, in uint[2][] b) {
    if (a.length != b.length) return false;
    foreach (i; 0 .. a.length)
        if (a[i][0] != b[i][0] || a[i][1] != b[i][1]) return false;
    return true;
}

// Snapshot the geometry that a revert must restore byte-identically.
private struct Geo {
    Vec3[]    verts;
    uint[][]  faces;
    uint[2][] edges;
    uint[]    vMarks, eMarks, fMarks;
    uint[]    faceMaterial;
}

private Geo capture(ref Mesh m) {
    Geo g;
    g.verts        = m.vertices.dup;
    g.faces        = m.faces.range.dupFaces;
    g.edges        = m.edges.dup;
    g.vMarks       = m.vertexMarks.dup;
    g.eMarks       = m.edgeMarks.dup;
    g.fMarks       = m.faceMarks.dup;
    g.faceMaterial = m.faceMaterial.dup;
    return g;
}

private uint[][] dupFaces(in uint[][] src) {
    uint[][] r;
    r.length = src.length;
    foreach (i, ref f; src) r[i] = f.dup;
    return r;
}

private void assertGeoEq(ref Mesh m, in Geo g, string what) {
    assert(sameVerts(m.vertices, g.verts), what ~ ": vertices differ");
    assert(sameFaces(m.faces.range, g.faces), what ~ ": faces differ");
    assert(sameEdges(m.edges, g.edges), what ~ ": edges differ");
}

// Canonicalise a freshly-built mesh's edge order to the kernel-canonical order
// (rebuildEdges) so the pre-batch baseline matches what revert's finalize
// produces. Mutators all run rebuildEdges, so this makes the baseline honest.
private void canonicalize(ref Mesh m) {
    m.rebuildEdges();
    m.buildLoops();
}

// Bring all per-element marks/order/material arrays length-correct + edges
// canonical, then clear selection — the consistent starting state the topology
// mutators (and finalize) expect.
private void prep(ref Mesh m) {
    m.rebuildEdges();
    m.resetSelection();
    m.faceMaterial.length = m.faces.length;
    foreach (ref mat; m.faceMaterial) mat = 0u;
    m.buildLoops();
}

// ---------------------------------------------------------------------------
// (a) Pure append: addVertex + addFace round-trip.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    prep(m);
    auto pre = capture(m);
    const v0 = m.vertices.length;
    const f0 = m.faces.length;

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    assert(m.isRecordingEdits());
    // Append three new verts + a triangle referencing them.
    const a = m.addVertex(Vec3(2, 0, 0));
    const b = m.addVertex(Vec3(3, 0, 0));
    const c = m.addVertex(Vec3(2, 1, 0));
    m.addFace([a, b, c]);
    auto delta = m.endEditBatch();
    assert(!m.isRecordingEdits());
    assert(!delta.isEmpty(), "(a) delta must record the append");

    // Capture the post-batch geometry for the apply() re-check.
    auto post = capture(m);
    assert(m.vertices.length == v0 + 3);
    assert(m.faces.length == f0 + 1);

    // revert → back to original.
    delta.revert(m);
    assertGeoEq(m, pre, "(a) revert");

    // apply → re-creates the post-batch mesh.
    delta.apply(m);
    assertGeoEq(m, post, "(a) apply");
}

// ---------------------------------------------------------------------------
// (b) Compaction: a mutation sequence INCLUDING compactUnreferenced. Build a
// mesh of TWO disconnected quads; delete the second quad's face so its 4 verts
// orphan → compactUnreferenced removes them and reindexes. revert must restore
// the pre-batch vertex INDEXING + positions exactly (the Reindex^-1 lock).
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    // Quad A (verts 0..3), Quad B (verts 4..7) — disconnected.
    m.addVertex(Vec3(0, 0, 0)); // 0
    m.addVertex(Vec3(1, 0, 0)); // 1
    m.addVertex(Vec3(1, 1, 0)); // 2
    m.addVertex(Vec3(0, 1, 0)); // 3
    m.addVertex(Vec3(3, 0, 0)); // 4
    m.addVertex(Vec3(4, 0, 0)); // 5
    m.addVertex(Vec3(4, 1, 0)); // 6
    m.addVertex(Vec3(3, 1, 0)); // 7
    m.addFace([0u, 1u, 2u, 3u]);
    m.addFace([4u, 5u, 6u, 7u]);
    prep(m);
    auto pre = capture(m);
    assert(m.vertices.length == 8 && m.faces.length == 2);

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    // Delete quad B → orphans verts 4..7 → compactUnreferenced reindexes.
    bool[] mask = [false, true];
    const removed = m.deleteFacesByMask(mask);
    auto delta = m.endEditBatch();
    assert(removed == 1, "(b) one face removed");

    // The op-log must contain a RemoveVerts + Reindex (the compaction signature)
    // and a RemoveFaces (the deleted quad).
    bool sawReindex, sawRemoveVerts, sawRemoveFaces;
    foreach (ref e; delta.log) {
        final switch (e.kind) with (typeof(e.kind)) {
            case Reindex:        sawReindex = true;     break;
            case RemoveVerts:    sawRemoveVerts = true; break;
            case RemoveFaces:    sawRemoveFaces = true; break;
            case AddVerts: case SetPos: case AddFaces: case ReshapeFaces:
            case SelectionDelta: case SubpatchDelta: case MaterialDelta:
            case EdgeSelByEnds:  case MeshMapDelta:   case HideDelta:
            // task 1902 Stage H: FaceReindex is disarmed by default
            // (MeshEditTracker.wantsFaceReindex == false) and this test's
            // `MeshEditTracker()` never opts in, so it cannot appear in
            // `delta.log` here — added only to satisfy the `final switch`.
            // task 1903 Stage L1-P1: MapValueDelta has no production
            // recorder at this commit and `deleteFacesByMask` records no map
            // values in any case, so it cannot appear here either — added
            // only to satisfy the `final switch`.
            case MapValueDelta: break;
            case FaceReindex: break;
        }
    }
    assert(sawReindex,     "(b) log must contain Reindex");
    assert(sawRemoveVerts, "(b) log must contain RemoveVerts");
    assert(sawRemoveFaces, "(b) log must contain RemoveFaces");

    // Post-delete: 4 verts, 1 face, verts reindexed to 0..3.
    assert(m.vertices.length == 4, "(b) compaction dropped 4 verts");
    assert(m.faces.length == 1);
    // Capture the post-compaction (forward) state so apply() can be re-checked —
    // the compaction RemoveVerts+Reindex pair's FORWARD replay must drop+repack
    // (the Reindex perm is the sole authority; the RemoveVerts forward no-ops so
    // it does not shift indices out from under the perm).
    auto post = capture(m);

    // revert → byte-identical pre-batch INDEXING + positions.
    delta.revert(m);
    assert(m.vertices.length == 8, "(b) revert restores vert count");
    assertGeoEq(m, pre, "(b) revert");
    // Spot-check the index space is EXACTLY restored (quad B's verts back at 4..7).
    assert(m.vertices[4] == Vec3(3, 0, 0), "(b) vert 4 restored to original index");
    assert(m.vertices[7] == Vec3(3, 1, 0), "(b) vert 7 restored to original index");
    assert(m.faces[1] == [4u, 5u, 6u, 7u], "(b) face 1 references original indices");

    // apply (redo) → byte-identical to the post-compaction state. This is the
    // forward-replay-of-a-compaction lock (the latent bug Phase 2's redo found).
    delta.apply(m);
    assert(m.vertices.length == 4, "(b) apply restores post-compaction vert count");
    assertGeoEq(m, post, "(b) apply (forward redo of compaction)");
}

// ---------------------------------------------------------------------------
// (c) ReshapeFaces: dissolve a vertex so a quad shrinks to a tri. revert must
// restore the original (quad) face list.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    // A single pentagon so dissolving one vert leaves a valid quad (>= 3),
    // exercising ReshapeFaces without dropping the face.
    m.addVertex(Vec3(0, 0, 0));   // 0
    m.addVertex(Vec3(2, 0, 0));   // 1
    m.addVertex(Vec3(3, 1, 0));   // 2 (the one we dissolve)
    m.addVertex(Vec3(2, 2, 0));   // 3
    m.addVertex(Vec3(0, 2, 0));   // 4
    m.addFace([0u, 1u, 2u, 3u, 4u]);
    prep(m);
    auto pre = capture(m);

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    bool[] mask = [false, false, true, false, false]; // dissolve vert 2
    const n = m.dissolveVerticesByMask(mask);
    auto delta = m.endEditBatch();
    assert(n == 1, "(c) one vert dissolved");

    bool sawReshape;
    foreach (ref e; delta.log)
        if (e.kind == typeof(e.kind).ReshapeFaces) sawReshape = true;
    assert(sawReshape, "(c) log must contain ReshapeFaces");

    // Post-dissolve: pentagon → quad, vert 2 compacted out (4 verts).
    assert(m.faces.length == 1 && m.faces[0].length == 4, "(c) quad after dissolve");
    assert(m.vertices.length == 4);

    // revert → original pentagon, original indexing.
    delta.revert(m);
    assert(m.vertices.length == 5, "(c) revert restores vert count");
    assertGeoEq(m, pre, "(c) revert");
    assert(m.faces[0] == [0u, 1u, 2u, 3u, 4u], "(c) pentagon restored");
}

// ---------------------------------------------------------------------------
// (d) Selection / subpatch / material sparse-delta round-trip. Drive the
// record* methods directly (these are the hooks Ph2 wires at the kernel
// selection/material write sites) and assert revert/apply round-trip.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    prep(m);
    // Pre-batch: face 0 unselected, not subpatch, material 0.
    auto pre = capture(m);
    const preSel0 = m.isFaceSelected(0);
    const preSub0 = m.isFaceSubpatch(0);
    const preMat0 = m.faceMaterial[0];

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Marks | MeshEditScope.Material);
    // Record a sparse selection / subpatch / material change on face 0, then
    // actually apply the change to the live mesh (mirrors a kernel writing the
    // value and logging before/after).
    rec.recordSelectionDelta(MeshOpEntry.SelDomain.Face,
        [0u], [preSel0 ? 1u : 0u], [1u]);
    m.selectFace(0);
    rec.recordSubpatchDelta([0u], [preSub0 ? 1u : 0u], [1u]);
    m.setFaceSubpatch(0, true);
    rec.recordMaterialDelta([0u], [preMat0], [3u]);
    m.faceMaterial[0] = 3u;
    auto delta = m.endEditBatch();

    assert(m.isFaceSelected(0) && m.isFaceSubpatch(0) && m.faceMaterial[0] == 3u);
    auto post = capture(m);
    const postSel0 = m.isFaceSelected(0);

    // revert → original marks/material.
    delta.revert(m);
    assert(m.isFaceSelected(0) == preSel0, "(d) selection reverted");
    assert(m.isFaceSubpatch(0) == preSub0, "(d) subpatch reverted");
    assert(m.faceMaterial[0]   == preMat0, "(d) material reverted");

    // apply → re-applies.
    delta.apply(m);
    assert(m.isFaceSelected(0) == postSel0, "(d) selection re-applied");
    assert(m.isFaceSubpatch(0), "(d) subpatch re-applied");
    assert(m.faceMaterial[0] == 3u, "(d) material re-applied");
}

// ---------------------------------------------------------------------------
// (e) HP5 no-op: run the same mutation sequence with NO batch open → the
// tracker is inert (no log) and the mesh is unaffected by the tracker.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeCube();
    prep(m);
    // No beginEditBatch — hooks must be inert.
    assert(!m.isRecordingEdits());
    m.addVertex(Vec3(9, 9, 9));
    m.addFace([0u, 1u, 2u]);
    // The mesh changed (the mutations ran), but no tracker state exists; verify
    // a fresh batch over zero mutations yields an empty delta.
    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.None);
    auto delta = m.endEditBatch();
    assert(delta.isEmpty(), "(e) empty batch → empty delta");
}

// ---------------------------------------------------------------------------
// (f) TWO faces dropped by ONE entry — the face ORDER lock (task 0703).
//
// `RemoveFaces.fIdx` is inverted by inserting ascending at the recorded index,
// which reconstructs the original array only if the indices are in the space
// of `faces` as it stood BEFORE the removal. `removeEdgesByMask` used to record
// the POST-drop slot instead (`keptFaces.length` at the moment of the drop);
// the two spaces coincide only when a SINGLE face is dropped, so every earlier
// test — all of which drop one — passed while a two-face drop came back
// reversed.
//
// Fixture: two triangles sharing an edge. Dissolving the shared edge merges
// both into one quad, so BOTH component faces land in one RemoveFaces entry and
// both used to be recorded at index 0 ⇒ insertInPlace(0) twice ⇒ [f1, f0].
// The face SET survives either way; only the ORDER distinguishes them, and the
// order is the key selection / faceMaterial / facePart / per-corner maps hang
// off. So assert positionally, never as a set.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));   // 0
    m.addVertex(Vec3(1, 0, 0));   // 1
    m.addVertex(Vec3(0, 1, 0));   // 2
    m.addVertex(Vec3(1, 1, 0));   // 3
    m.addFace([0u, 1u, 2u]);      // f0 — shares edge (1,2) with f1
    m.addFace([1u, 3u, 2u]);      // f1
    prep(m);
    auto pre = capture(m);
    assert(m.faces.length == 2);

    // The interior edge (1,2).
    int sharedEdge = -1;
    foreach (i, e; m.edges)
        if ((e[0] == 1 && e[1] == 2) || (e[0] == 2 && e[1] == 1)) sharedEdge = cast(int)i;
    assert(sharedEdge >= 0, "(f) shared edge not found");

    // Distinguishable per-face payload, so a reversal is visible in more than
    // the vertex lists (these are exactly the arrays a wrong order corrupts).
    m.faceMaterial[0] = 7u;
    m.faceMaterial[1] = 9u;
    m.facePart.length = 2;
    m.facePart[0] = 11u;
    m.facePart[1] = 13u;
    pre = capture(m);

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    bool[] emask;
    emask.length = m.edges.length;
    emask[sharedEdge] = true;
    const n = m.removeEdgesByMask(emask);
    auto delta = m.endEditBatch();
    assert(n == 1, "(f) one edge dissolved");
    assert(m.faces.length == 1, "(f) the two triangles merged into one polygon");

    delta.revert(m);
    assert(m.faces.length == 2, "(f) revert restores both faces");
    assert(m.faces[0] == [0u, 1u, 2u],
        "(f) face 0 must come back at index 0 — RemoveFaces.fIdx is a PRE-drop "
        ~ "index space and its inverse inserts ascending; recording the "
        ~ "post-drop slot reverses the pair");
    assert(m.faces[1] == [1u, 3u, 2u], "(f) face 1 must come back at index 1");
    assertGeoEq(m, pre, "(f) revert");
    assert(m.faceMaterial[0] == 7u && m.faceMaterial[1] == 9u,
        "(f) faceMaterial follows its own face back");
    assert(m.facePart[0] == 11u && m.facePart[1] == 13u,
        "(f) facePart follows its own face back");
}

// ---------------------------------------------------------------------------
// (g) The vertex-dissolve twin of (f), plus the ReshapeFaces interaction.
//
// Dissolving one vertex can DROP faces (shrunk below 3 corners) and RESHAPE
// others in the same call. Both entries used to be recorded in the POST-shrink
// space, which is wrong twice over: the two drops collide on one index (as in
// (f)), and the reshape index is read AFTER `RemoveFaces⁻¹` has already put the
// dropped faces back — i.e. against an array that is once again in the ORIGINAL
// space. Recording both in the pre-op space makes the LIFO revert consistent:
// RemoveFaces⁻¹ restores the original length and order, then ReshapeFaces⁻¹
// addresses the reshaped face at the index it always had.
//
// Fixture: vertex 0 is shared by two triangles (both degenerate after the
// dissolve ⇒ dropped) and one quad (⇒ reshaped to a triangle, survives). The
// two drops precede the survivor, so the post-shrink index of the reshape is 0
// while its true index is 2.
// ---------------------------------------------------------------------------
unittest {
    Mesh m;
    m.addVertex(Vec3( 0,  0, 0));   // 0 — dissolved
    m.addVertex(Vec3( 1,  0, 0));   // 1
    m.addVertex(Vec3( 1,  1, 0));   // 2
    m.addVertex(Vec3( 0,  1, 0));   // 3
    m.addVertex(Vec3(-1,  1, 0));   // 4
    m.addVertex(Vec3(-1,  0, 0));   // 5
    m.addFace([0u, 1u, 2u]);        // f0 — → [1,2], dropped
    m.addFace([0u, 2u, 3u]);        // f1 — → [2,3], dropped
    m.addFace([0u, 3u, 4u, 5u]);    // f2 — → [3,4,5], reshaped
    prep(m);
    m.faceMaterial[0] = 7u;
    m.faceMaterial[1] = 9u;
    m.faceMaterial[2] = 5u;
    auto pre = capture(m);

    auto rec = MeshEditTracker();
    m.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    bool[] vmask;
    vmask.length = m.vertices.length;
    vmask[0] = true;
    const n = m.dissolveVerticesByMask(vmask);
    auto delta = m.endEditBatch();
    assert(n == 1, "(g) one vert dissolved");
    assert(m.faces.length == 1, "(g) two degenerate faces dropped, one survives");

    delta.revert(m);
    assert(m.faces.length == 3, "(g) revert restores all three faces");
    assert(m.faces[0] == [0u, 1u, 2u], "(g) dropped face 0 back at index 0");
    assert(m.faces[1] == [0u, 2u, 3u], "(g) dropped face 1 back at index 1");
    assert(m.faces[2] == [0u, 3u, 4u, 5u],
        "(g) the RESHAPED face must be restored at its own index — a reshape "
        ~ "index recorded in the post-shrink space lands on a re-inserted "
        ~ "dropped face instead");
    assertGeoEq(m, pre, "(g) revert");
    assert(m.faceMaterial[0] == 7u && m.faceMaterial[1] == 9u
        && m.faceMaterial[2] == 5u, "(g) faceMaterial follows its own face back");
}
