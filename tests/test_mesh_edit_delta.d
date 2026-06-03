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
            case EdgeSelByEnds:  case MeshMapDelta:   break;
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
