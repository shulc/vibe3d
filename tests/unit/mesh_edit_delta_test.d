// Module unittests for `mesh_edit_delta`, moved verbatim out of source/mesh_edit_delta.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.mesh_edit_delta_test;

import std.array : insertInPlace;
import mesh;            // Mesh, Marks, edgeKey (mutual import — see note below)
import math : Vec3;
import mesh_edit_delta;

// ---------------------------------------------------------------------------
// Vertex-mark permutation gap (doc/hide_geometry_plan.md §4.2/S1 — "the
// vertex-mark permutation gap at applyReindex*/removeVertsForward/Reverse").
// A LOOSE vertex's Hide bit is the ONE per-vertex Hide state that is NOT
// self-healed by refreshHiddenDerived() every geometry commit (a face-bound
// vertex's bit IS re-derived from faceMarks; a loose vertex has no incident
// face to derive from, so its own bit must physically ride the same
// permutation its position does, or it silently lands on whichever vertex
// now occupies its old slot).
//
// Constructed delta (not a real kernel run — for full control of the exact
// permutation, the same style as T-OBJ4 above). Pre-compaction space had 5
// verts [v0..v4]: v0 was dropped, v1..v4 shift down to new indices 0..3.
// `m` starts at the POST-compaction state: a triangle [0,1,2] (old v1,v2,v3)
// plus a LOOSE, HIDDEN vertex 3 (old v4). Reverting (undo) must re-open v0's
// gap AND land v4's Hide bit back at its PRE-compaction index 4 — not leave
// it stranded at its post-compaction index 3, which is now a REAL,
// face-referenced triangle corner (old v3) in the restored mesh.
unittest {
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(5, 5, 5)];
    m.addFace([0, 1, 2]);
    m.buildLoops();
    m.syncSelection();
    m.setVertexHidden(3, true);   // the loose point, at its POST-compaction index
    assert(m.isVertexHidden(3));
    // S3 code review: give a DIFFERENT (non-hidden — Select ∧ Hide = ∅ means
    // a hidden vertex cannot legally carry a selection-order stamp) vertex a
    // manual selection-order stamp, independent of the Select bit machinery,
    // to test the order-array permutation on its own. Vertex 1 here is old
    // v2 at its post-compaction index.
    m.vertexSelectionOrder[1] = 7;

    MeshOpEntry removeEntry;
    removeEntry.kind = MeshOpEntry.Kind.RemoveVerts;
    removeEntry.vIdx = [0u];                    // OLD (pre-compaction) index of the dropped vert
    removeEntry.pos  = [Vec3(-1, -1, -1)];       // its original position

    MeshOpEntry reindexEntry;
    reindexEntry.kind = MeshOpEntry.Kind.Reindex;
    reindexEntry.perm = [~0u, 0u, 1u, 2u, 3u];   // old->new: v0 dropped, v1..v4 -> 0..3

    MeshEditDelta delta;
    delta.log = [removeEntry, reindexEntry];     // forward order: drop-before-permute (LIFO undo: Reindex^-1 then RemoveVerts^-1)

    assert(delta.revert(m));

    assert(m.vertices.length == 5, "the dropped vertex must be re-inserted");
    // NOTE (code review NIT): this assertion is a SANITY check, not a
    // discriminator — index 3 is a face-bound vertex (a real triangle
    // corner) in the restored mesh, and refreshHiddenDerived() recomputes a
    // face-bound vertex's Hide bit from its incident faces' state on every
    // commit regardless of whatever stale word the (possibly buggy)
    // permutation left behind. It would read false even without the fix
    // below, so it does not by itself prove the permutation moved anything.
    assert(!m.isVertexHidden(3),
        "vertex-mark permutation: old v3 (now a real triangle corner in the "
        ~ "restored mesh) must NOT read hidden");
    // This is the ONE assertion that actually discriminates: vertex 4 is the
    // LOOSE point, whose Hide bit is authoritative (not derived — no
    // incident face to derive it from), so it only lands correctly if the
    // permutation fix physically moved it. Without the fix it reads false
    // (stranded at, or overwritten by, the wrong slot).
    assert(m.isVertexHidden(4),
        "vertex-mark permutation: the loose vertex's Hide bit must land back at "
        ~ "its PRE-compaction index (4), not stay stranded at its post-compaction "
        ~ "index (3)");

    // S3 code review: the selection-order stamp must ride the SAME reverse
    // permutation as the mark word — old v2's stamp must land back at its
    // PRE-compaction index (2), not stay behind at its post-compaction index
    // (1), which is now a DIFFERENT vertex (old v1).
    assert(m.vertexSelectionOrder[2] == 7,
        "S3: old v2's selection-order stamp must land back at its "
        ~ "PRE-compaction index (2)");
    assert(m.vertexSelectionOrder[1] == 0,
        "S3: old v1 (now at post-revert index 1) must NOT inherit v2's "
        ~ "stale stamp");
}

// ---------------------------------------------------------------------------
// Task 0833 — the settled-mesh precondition on `restoreSelectedEdgeEnds` is
// LIVE, i.e. it CAN fail.
//
// 0724 measured that no caller can trip it today (every stale-leaving mutator
// ends in a terminal `buildLoops()` before any reader). This constructs the
// stale read those callers never produce, so the guard is demonstrated rather
// than argued — a check that cannot fail is indistinguishable from one that is
// absent.
//
// Why THIS twin and not `applyEdgeSelByEnds` (the private one, same body):
// this function is module-PUBLIC, so its caller set is open and a test can
// reach it without widening anything. The private twin has exactly one caller,
// the delta finalizer, which runs rebuildEdges()+buildLoops() on the lines
// above it — see the note left at that assert.
//
// Legal sequence: `addFaceFast` is the importers' append primitive
// (io/scene_ir.d, io/native.d, remesh) — it fills `edges` from the CALLER's
// scratch lookup and defers the canonical map to a terminal `buildLoops()`.
//
// The failure it stands in for is silent: a stale map resolves an endpoint
// pair to whatever edge index the PREVIOUS topology had, so the restore
// selects the WRONG edge instead of failing.
//
// `debug`-wrapped because `assertEdgeMapValid` is a `debug assert` — this
// proves the guard is live in the builds that carry it (dub test / dub build).
// It is stripped from `-release`, so it is not a runtime guarantee in the
// shipped binary.
// ---------------------------------------------------------------------------
unittest {
    debug {
        import core.exception : AssertError;
        import std.exception  : assertThrown;

        Mesh m;
        uint[ulong] scratch;
        m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1)];
        m.addFaceFast(scratch, [0u, 1u, 2u, 3u]);
        assert(m.edges.length == 4,
            "setup: addFaceFast must still append the quad's four edges");
        assert(!m.edgeMapUsable(),
            "setup: addFaceFast defers the canonical map, so it must read unusable");

        assertThrown!AssertError(restoreSelectedEdgeEnds(m, [0u, 1u]),
            "restoreSelectedEdgeEnds must refuse a mesh whose edgeIndexMap was "
            ~ "never rebuilt -- if this stops throwing, the precondition has "
            ~ "become decoration");

        // ...and the SAME call lands the selection once the caller settles the
        // mesh: the assert discriminates between two states, it does not refuse
        // the restore outright.
        m.buildLoops();
        m.resizeEdgeSelection();
        assert(m.edgeMapUsable(), "setup: buildLoops must restore the map");
        restoreSelectedEdgeEnds(m, [0u, 1u]);
        const uint ei = m.edgeIndex(0, 1);
        assert(ei != ~0u, "setup: the rebuilt map must know edge (0,1)");
        assert((m.edgeMarks[ei] & Mesh.Marks.Select) != 0,
            "the endpoint pair (0,1) must come back selected through the "
            ~ "rebuilt map");
    }
}

// ---------------------------------------------------------------------------
// TASK 0831 — the index space is in the TYPE, and here is the proof it bites.
//
// Task 0703's defect was that `RemoveFaces.fIdx` was a bare `uint` and two
// kernels filled it with a position in the array they were BUILDING
// (`keptFaces.length` / `newFaces.length`) instead of the live index. Both
// spellings were `uint`, both compiled, and they read IDENTICALLY whenever
// exactly one face is dropped — so the whole suite stayed green while an edge
// dissolve came back with its faces reversed. The fix could only write the
// rule in a comment. This block is the same rule, checked by the compiler.
//
// It is `static assert(!__traits(compiles, …))`, so it costs nothing at
// runtime and fails at BUILD time — which is the point: the defect must stop
// being expressible, not merely be detected once it has been written.
//
// The three checks are a set and only mean something together:
//   (1) the 0703 expression must NOT compile;
//   (2) the live mint MUST compile — without this, deleting `faceIndices`
//       outright would leave (1) trivially green;
//   (3) the SAME expression on a plain `uint[]` MUST compile — without this,
//       (1) could be passing because the expression is malformed rather than
//       because the type refuses it.
//
// A live mutation is wired at the real call site as well: build with
//   dub build --config=modeling --d-version=MutateIndexSpace0831
// and `source/mesh.d` fails to compile on the restored 0703 line.
unittest {
    // (1) the defect, verbatim: a position in the array being built.
    static assert(!__traits(compiles, {
        FaceIdx[] recorded;
        uint[][]  keptFaces;
        recorded ~= cast(uint)keptFaces.length;
    }), "task 0831: recording a scratch-array position as a face index must be "
      ~ "a COMPILE error — that expression is the 0703 defect verbatim");

    // (2) positive control: the ordinary live mint still works, so (1) is a
    //     refusal of the wrong thing rather than of everything.
    static assert(__traits(compiles, {
        Mesh m;
        FaceIdx[] recorded;
        foreach (fi; m.faceIndices) recorded ~= fi;
    }), "task 0831: iterating the live face-index space must still be the "
      ~ "ordinary, ceremony-free way to record an index");

    // (3) discriminator: the refusal is the TYPE's, not the expression's.
    static assert(__traits(compiles, {
        uint[]   recorded;
        uint[][] keptFaces;
        recorded ~= cast(uint)keptFaces.length;
    }), "task 0831: the same expression on a plain uint[] must compile — "
      ~ "otherwise check (1) proves nothing about FaceIdx");

    // And the escape is deliberate, named, and greppable: an AddFaces tail
    // base genuinely IS a scratch-array length, so it has to remain sayable.
    static assert(__traits(compiles, {
        FaceIdx[] recorded;
        uint[][]  keptFaces;
        recorded ~= FaceIdx.assumeFaceSpace(keptFaces.length);
    }), "task 0831: `assumeFaceSpace` is the one explicit conversion and must "
      ~ "stay available — the criterion is 'not without an explicit "
      ~ "conversion', not 'never'");
}

// ---------------------------------------------------------------------------
// TASK 0922 — `removeFacesForward` (the FORWARD/redo half of a RemoveFaces
// entry) filtered `faces` and `faceMarks` by the drop mask but left
// `faceMaterial` / `facePart` / `faceSelectionOrder` untouched entirely; only
// `finalize()`'s tail `.length = m.faces.length` ever resized them — a raw
// truncate/grow, not a compaction, so a face dropped anywhere but the array's
// tail left every survivor after it wearing a neighbour's material/part/
// pick-order stamp. Reachable through redo of any MeshSessionEdit-backed
// operation (bevel, loop-slice, reduce, topology-pen-remove —
// commands/mesh/session_edit.d:108).
//
// Fixture measured by task 0831: three triangles, `RemoveFaces` drops face 0
// (not the tail — a tail drop makes truncation and a correct filter agree,
// the same trap task 0703 hid behind), forward (redo) replay.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;

    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                  Vec3(2, 0, 0), Vec3(3, 0, 0), Vec3(2, 1, 0),
                  Vec3(4, 0, 0), Vec3(5, 0, 0), Vec3(4, 1, 0)];
    m.addFace([0u, 1u, 2u]);
    m.addFace([3u, 4u, 5u]);
    m.addFace([6u, 7u, 8u]);
    m.buildLoops();
    m.syncSelection();
    m.faceMaterial       = [100u, 111u, 122u];
    m.facePart            = [10u, 11u, 12u];
    m.faceSelectionOrder = [1, 2, 3];

    MeshOpEntry removeEntry;
    removeEntry.kind     = MeshOpEntry.Kind.RemoveFaces;
    removeEntry.fIdx     = [FaceIdx.assumeFaceSpace(0)];   // pre-drop index, ascending
    removeEntry.faceLists = [m.faces[0].dup];
    removeEntry.faceMat  = [100u];
    removeEntry.facePrt  = [10u];
    removeEntry.faceSub  = [0u];

    MeshEditDelta delta;
    delta.scope_ = MeshEditScope.Polygons;
    delta.log    = [removeEntry];

    assert(delta.apply(m), "forward replay must succeed");
    assert(m.faces.length == 2, "setup: face 0 must be dropped");

    assert(m.faceMaterial == [111u, 122u],
        "removeFacesForward: surviving faces must keep their OWN material, "
      ~ "not a stale-position truncate/grow of the pre-drop array — got "
      ~ m.faceMaterial.to!string);
    assert(m.facePart == [11u, 12u],
        "removeFacesForward: surviving faces must keep their OWN part id — "
      ~ "got " ~ m.facePart.to!string);
    assert(m.faceSelectionOrder == [2, 3],
        "removeFacesForward: surviving faces must keep their OWN pick-order "
      ~ "stamp — got " ~ m.faceSelectionOrder.to!string);
}

// ---------------------------------------------------------------------------
// TASK 0922 — the neighbouring asymmetry in the REVERSE half.
// `removeFacesReverse` inserted `facePart`/`faceMarks` under `fi <= length`
// (the correct bound — `insertInPlace` accepts a tail index equal to the
// array's current length) but `faceMaterial` under the stricter `fi < length`,
// which silently skips exactly the tail-reinsertion case: a face dropped from
// the END of the pre-drop mesh comes back on undo with `finalize()`'s tail pad
// (`0`) instead of its recorded material. `faceSelectionOrder` was not
// reinserted at all — the comment claimed SelectionDelta restores it, but
// SelectionDelta only ever patches the Select BIT (see `patchSelection`), not
// the pick-order stamp.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;

    // `m` starts in the POST-drop state (2 faces): the third (tail) triangle
    // of a 3-triangle mesh was already removed.
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                  Vec3(2, 0, 0), Vec3(3, 0, 0), Vec3(2, 1, 0)];
    m.addFace([0u, 1u, 2u]);
    m.addFace([3u, 4u, 5u]);
    m.buildLoops();
    m.syncSelection();
    m.faceMaterial       = [100u, 111u];
    m.facePart            = [10u, 11u];
    m.faceSelectionOrder = [1, 2];

    MeshOpEntry removeEntry;
    removeEntry.kind      = MeshOpEntry.Kind.RemoveFaces;
    removeEntry.fIdx      = [FaceIdx.assumeFaceSpace(2)];   // the TAIL of the pre-drop, 3-face mesh
    removeEntry.faceLists = [[6u, 7u, 8u]];
    removeEntry.faceMat   = [122u];
    removeEntry.facePrt   = [12u];
    removeEntry.faceSub   = [0u];

    MeshEditDelta delta;
    delta.scope_ = MeshEditScope.Polygons;
    delta.log    = [removeEntry];

    // Extend `vertices` first so the re-inserted face's vertex ids resolve —
    // this test targets the FACE-plane insert bounds only, not vertex revert.
    m.vertices ~= [Vec3(4, 0, 0), Vec3(5, 0, 0), Vec3(4, 1, 0)];

    assert(delta.revert(m), "reverse replay must succeed");
    assert(m.faces.length == 3, "setup: the tail face must come back");

    assert(m.faceMaterial == [100u, 111u, 122u],
        "removeFacesReverse: a face re-inserted at the array's TAIL "
      ~ "(fi == length) must still receive its recorded material — `<` "
      ~ "silently skips exactly that case, `facePart` right below already "
      ~ "uses the correct `<=` — got " ~ m.faceMaterial.to!string);
    assert(m.facePart == [10u, 11u, 12u],
        "removeFacesReverse: facePart's own tail re-insert — got " ~
        m.facePart.to!string);
    assert(m.faceSelectionOrder == [1, 2, 0],
        "removeFacesReverse: faceSelectionOrder must shift in lockstep with "
      ~ "faceMarks and, with no `faceOrd` carried on THIS entry (it is left "
      ~ "unset/empty above), fall back to inserting 0 — the documented "
      ~ "fallback for an entry recorded before task 1902 Stage H (or a "
      ~ "hand-built fixture with no ord), not the general rule — not be "
      ~ "left to finalize()'s tail length-grow which pads the array's OWN "
      ~ "new tail instead of the index the face actually landed at — got " ~
        m.faceSelectionOrder.to!string);

    // Task 1902 Stage H, review finding B1: when `faceOrd` IS carried, the
    // re-inserted face must get its OWN recorded rank instead of the
    // unconditional-0 fallback exercised just above. Same tail-reinsertion
    // shape, fresh mesh + entry so the two cases stay independent (`m`
    // above has already been mutated by the first revert).
    Mesh m2;
    m2.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                   Vec3(2, 0, 0), Vec3(3, 0, 0), Vec3(2, 1, 0)];
    m2.addFace([0u, 1u, 2u]);
    m2.addFace([3u, 4u, 5u]);
    m2.buildLoops();
    m2.syncSelection();
    m2.faceMaterial       = [100u, 111u];
    m2.facePart            = [10u, 11u];
    m2.faceSelectionOrder = [1, 2];

    MeshOpEntry removeEntryOrd;
    removeEntryOrd.kind      = MeshOpEntry.Kind.RemoveFaces;
    removeEntryOrd.fIdx      = [FaceIdx.assumeFaceSpace(2)];   // the TAIL of the pre-drop, 3-face mesh
    removeEntryOrd.faceLists = [[6u, 7u, 8u]];
    removeEntryOrd.faceMat   = [122u];
    removeEntryOrd.facePrt   = [12u];
    removeEntryOrd.faceSub   = [0u];
    removeEntryOrd.faceOrd   = [7];   // the dropped face's own recorded rank

    MeshEditDelta deltaOrd;
    deltaOrd.scope_ = MeshEditScope.Polygons;
    deltaOrd.log    = [removeEntryOrd];

    m2.vertices ~= [Vec3(4, 0, 0), Vec3(5, 0, 0), Vec3(4, 1, 0)];

    assert(deltaOrd.revert(m2), "reverse replay must succeed");
    assert(m2.faces.length == 3, "setup: the tail face must come back");
    assert(m2.faceSelectionOrder == [1, 2, 7],
        "removeFacesReverse: when `faceOrd` IS carried, a re-inserted face "
      ~ "must restore its OWN recorded faceSelectionOrder rank (task 1902 "
      ~ "Stage H, review finding B1) — not the earlier unconditional-0 "
      ~ "insert — got " ~ m2.faceSelectionOrder.to!string);
}

// ---------------------------------------------------------------------------
// Task 1902 Stage H, review finding B1 — PRODUCTION WITNESS. The two blocks
// above prove `removeFacesReverse`'s own carry logic against a HAND-BUILT
// `MeshOpEntry`; they say nothing about whether any real producer actually
// passes `ord` into `recordRemoveFaces`. A call site that dropped the
// argument (`deleteFacesByMask`, `dissolveVerticesByMask`,
// `removeEdgesByMask`, `mesh_ops.extrude.extrudeEdgesByMask`) would leave
// every hand-built fixture green while every real delete lost its
// `faceSelectionOrder` rank on undo. Drive the REAL producer instead:
// `Mesh.deleteFacesByMask` wrapped in `beginEditBatch`/`endEditBatch` — the
// same shape `commands/mesh/delete.d` uses under the tracker — on an open
// (non-manifold-closed) fixture where the DROPPED face carries a non-zero
// `faceSelectionOrder` rank.
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;

    // Open fixture: two disjoint triangles, no shared edges.
    Mesh m;
    m.vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0),
                  Vec3(2, 0, 0), Vec3(3, 0, 0), Vec3(2, 1, 0)];
    m.addFace([0u, 1u, 2u]);
    m.addFace([3u, 4u, 5u]);
    m.buildLoops();
    m.syncSelection();
    // Face 1 (about to be dropped) carries a non-zero pick-order rank; face 0
    // (the survivor) stays at 0 so the assertion below cannot pass by both
    // slots coincidentally holding the same value.
    m.faceSelectionOrder = [0, 9];

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Polygons);
    const removed = m.deleteFacesByMask([false, true]);
    auto delta = m.endEditBatch();
    assert(removed == 1, "setup: exactly the second triangle must drop");
    assert(m.faces.length == 1, "setup: one face survives the delete");

    assert(delta.revert(m), "reverse replay must succeed");
    assert(m.faces.length == 2, "undo must re-insert the dropped face");
    assert(m.faceSelectionOrder == [0, 9],
        "production witness: Mesh.deleteFacesByMask's recordRemoveFaces call "
      ~ "must pass the dropped face's OWN faceSelectionOrder rank through to "
      ~ "the MeshOpEntry (task 1902 Stage H, review finding B1) — dropping "
      ~ "the `ord` argument at the call site restores 0 here instead of the "
      ~ "recorded rank 9, and no hand-built fixture would catch it — got " ~
        m.faceSelectionOrder.to!string);
}

// ---------------------------------------------------------------------------
// TASK 0930 — `applyReindexForward`/`applyReindexReverse` correctly permute
// `vertices` / `vertexMarks` / `vertexSelectionOrder` by the recorded `perm`
// (task 0613 §4.2/S3 — the already-correct siblings) but never touched
// `m.meshMaps` at all: a Point-domain map (vertex weight, vertex color) was
// left entirely to `finalize()`'s tail `resizeAllMeshMaps()` — a raw
// truncate/grow, not a permutation. The exact class `compactUnreferenced`
// itself carried before task 0920 fixed it on the FORWARD kernel; this pins
// the same gather on the undo/redo REPLAY side of that identical compaction.
// `removeVertsForward`/`removeVertsReverse` had the same gap.
//
// Fixture: byte-identical to 0920's (tests/unit/mesh_test.d) — 7 vertices, a
// triangle [0,1,2], a hanging (unreferenced) vertex 3, a second triangle
// [4,5,6]; a weight map filled value == index. Built through the REAL
// producer (`beginEditBatch`/`endEditBatch` around a live
// `compactUnreferenced()` call) — not a hand-built `MeshOpEntry` — so the
// fixture exercises the actual recorder, not an assumption about its shape.
//
// `compactUnreferenced` drops only v3 — a MIDDLE drop, not a tail drop: a
// tail drop would make truncation and permutation agree and prove nothing
// (the same "one dropped face" trap task 0703 hid behind).
// ---------------------------------------------------------------------------
unittest {
    import std.conv : to;

    Mesh m;
    foreach (i; 0 .. 7) m.addVertex(Vec3(cast(float)i, 0, 0));
    m.addFace([0u, 1u, 2u]);
    m.addFace([4u, 5u, 6u]);
    m.buildLoops();
    m.syncSelection();

    m.addWeightMap("w");
    foreach (i; 0 .. 7) m.setVertexWeight("w", i, cast(float)i);

    float[] weights() {
        float[] w;
        foreach (i; 0 .. m.vertices.length) w ~= m.vertexWeight("w", i);
        return w;
    }

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Points);
    const removed = m.compactUnreferenced();
    auto delta = m.endEditBatch();
    assert(removed == 1, "setup: only the hanging vertex 3 is unreferenced");
    assert(m.vertices.length == 6);

    // The direct (already-fixed, task 0920) kernel's own result — the
    // reference this replay's redo must reproduce genuinely, not by luck.
    assert(weights() == [0f, 1f, 2f, 4f, 5f, 6f],
        "setup: direct compactUnreferenced must have already permuted the "
      ~ "weight map (task 0920) — got " ~ weights().to!string);

    // Undo (revert): Reindex^-1 restores the pre-compaction index space,
    // perm-gathering the Point-map value of every KEPT vertex back to its
    // own pre-compaction slot; RemoveVerts^-1 then fills the re-opened gap
    // at index 3.
    //
    // THE GAP'S OWN WEIGHT USED TO BE THE ONE VALUE THIS CELL EXPECTED TO
    // LOSE, and task 1903 Stage L7-P3 is what changed that. This expectation
    // was `[0, 1, 2, 0, 4, 5, 6]` — a documented limit shared with
    // `vertexMarks`, on the ground that `MeshOpEntry.RemoveVerts` recorded
    // only `vIdx` + `pos`. It now records the dropped vertices' Point-domain
    // map values as well (`mapDims` / `mapVals` / `presentBefore`; see the
    // fields' own doc), so vertex 3 comes back carrying **3**, not 0. The
    // change is the point of that stage, not a side effect: a weight or morph
    // value silently coming back as zero is a legal-looking wrong answer, and
    // it was the last blocker under an armed `bevelEdgesByMask` (card 2320).
    //
    // WHAT THIS CELL STILL GUARDS, unchanged and separately: the KEPT
    // vertices must carry their OWN weights back to their OWN pre-compaction
    // slots. That is `applyReindexReverse`'s un-permutation, and it is a
    // different mechanism from the gap fill — before task 0920's fix
    // `m.meshMaps` was untouched by the replay entirely and the array stayed
    // at its post-compaction values with a trailing zero pad (measured:
    // [0,1,2,4,5,6,0]). Both claims are in the one array below, so read a red
    // by WHICH slot moved: index 3 is L7-P3's payload, the others are 0920's
    // permutation.
    assert(delta.revert(m), "reverse replay must succeed");
    assert(m.vertices.length == 7);
    assert(weights() == [0f, 1f, 2f, 3f, 4f, 5f, 6f],
        "applyReindexReverse/removeVertsReverse: every KEPT vertex "
      ~ "(0,1,2,4,5,6) must carry its OWN weight back to its pre-compaction "
      ~ "slot (task 0920's un-permutation), AND the dropped vertex 3 must "
      ~ "come back carrying its own weight 3 rather than a zero (task 1903 "
      ~ "Stage L7-P3's `RemoveVerts` Point-map payload). A 0 at index 3 "
      ~ "alone means the payload; a shifted tail means the permutation "
      ~ "— got " ~ weights().to!string);

    // Redo (apply): must reproduce the direct kernel's result through a
    // GENUINE gather (applyReindexForward now permutes `m.meshMaps` too),
    // not by coincidence of the data never having moved — before this fix
    // the redo step matched the direct result only because neither replay
    // direction had touched `m.meshMaps` at all across the whole round trip.
    assert(delta.apply(m), "forward replay must succeed");
    assert(m.vertices.length == 6);
    assert(weights() == [0f, 1f, 2f, 4f, 5f, 6f],
        "applyReindexForward: redo must reproduce the direct kernel's "
      ~ "compaction through the SAME perm-gather compactUnreferenced uses, "
      ~ "not merely leave stale data untouched — got " ~ weights().to!string);
}
