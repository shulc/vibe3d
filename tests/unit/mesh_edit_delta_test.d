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
