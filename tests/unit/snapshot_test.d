// Module unittests for `snapshot`, moved verbatim out of source/snapshot.d by task 0706.
// Blocks keep their original order and text. Blocks that read a module-
// private symbol stayed behind -- see the task for the count.
module tests.unit.snapshot_test;

import std.algorithm.iteration : map;
import std.array : array;
import mesh;
import math;
import change_bus : MeshChangeAll;
import snapshot;

unittest { // S3 — code review, task 0613: a snapshot restore must not
    // resurrect a stale nonzero order stamp for an element that became
    // hidden AFTER the snapshot was captured (the production path this
    // covers: select.* commands' revert(), e.g. select-then-undo across an
    // intervening hide).
    auto m = makeCube();
    m.syncSelection();
    m.selectVertex(0);   // legal — vertex 0 is visible at capture time
    assert(m.vertexSelectionOrder[0] != 0);
    auto snap = SelectionSnapshot.capture(m);
    assert(snap.selectedVertices[0] && snap.vertexSelectionOrder[0] != 0);

    // Vertex 0 becomes hidden AFTER the snapshot: hide its three incident
    // faces (f0, f2, f5 — see the makeCube() face table comment above the
    // T-S0 unittests in mesh.d). refreshHiddenDerived()'s own BLOCKER fix
    // clears its Select bit and order stamp right here, independent of this
    // snapshot.
    m.setFaceHidden(0, true);
    m.setFaceHidden(2, true);
    m.setFaceHidden(5, true);
    assert(m.isVertexHidden(0));
    assert(!m.isVertexSelected(0) && m.vertexSelectionOrder[0] == 0);

    // Restore the stale snapshot. setVerticesSelectedFrom's Select ∧ Hide = ∅
    // guard refuses vertex 0 (still hidden) — but the snapshot's OWN
    // vertexSelectionOrder[0] is still nonzero (captured before the hide).
    // Discriminator: without the S3 fix, the wholesale
    // `mesh.vertexSelectionOrder = vertexSelectionOrder.dup;` a few lines up
    // in restore() resurrects that stale nonzero stamp even though
    // isVertexSelected(0) correctly reads false — a wrong implementation
    // reads order[0] != 0 here.
    snap.restore(m);
    assert(!m.isVertexSelected(0), "restore must not resurrect Select on a now-hidden vertex");
    assert(m.vertexSelectionOrder[0] == 0,
        "restore must not resurrect a stale order stamp for a refused (hidden) element");
}

// ---------------------------------------------------------------------------
// T-S6a — `restoreGeometryKeepSelection` keeps Hide LIVE and restores Subpatch
// from the snapshot (doc/hide_geometry_plan.md §1.5, §6 S6.1, §7 T-S6a).
//
// NO CODE CHANGE backs this test. The splice above already does the right
// thing, because Hide is neither Select nor Subpatch and therefore rides the
// live word untouched. That is exactly why it needs pinning: "the default
// happens to be correct" is the kind of fact that rots the first time somebody
// widens the mask "for symmetry with Subpatch".
//
// The plan's discriminator, and it is what makes this test non-vacuous: the
// two assertions pull in OPPOSITE directions off ONE call.
//   * A splice that restored the whole word from the snapshot (i.e. the
//     `topologyUnchanged` branch deleted, or `~Marks.Subpatch` widened to
//     `~(Marks.Subpatch | Marks.Hide)`) reads isFaceHidden(2) == FALSE.
//   * A splice that kept the whole word live (i.e. the Subpatch re-splice
//     loop deleted) reads isFaceSubpatch(3) == FALSE.
// Neither "restore everything" nor "keep everything" satisfies both, so the
// pair pins the SPLIT and not merely the presence of a restore. A test that
// asserted only the Hide half would pass the keep-everything implementation,
// which is the wrong law for content-class state.
unittest {
    auto m = makeCube();
    m.syncSelection();

    // Snapshot-time state: face 3 IS a subpatch; nothing is hidden.
    m.setFaceSubpatch(3, true);
    assert(m.isFaceSubpatch(3) && !m.isFaceHidden(2), "T-S6a fixture");
    auto snap = MeshSnapshot.capture(m);

    // LIVE drift after the capture, deliberately in both directions so the
    // restore has something to disagree with on each plane:
    //   * face 2 becomes hidden      — a VIEW onto the mesh, must be KEPT
    //   * face 3 stops being subpatch — CONTENT, must be RESTORED
    m.setFaceHidden(2, true);
    m.setFaceSubpatch(3, false);
    assert(m.isFaceHidden(2) && !m.isFaceSubpatch(3), "T-S6a drift");

    // Geometry is untouched between capture and restore, so this takes the
    // `topologyUnchanged` splice branch — the one under test.
    snap.restoreGeometryKeepSelection(m);

    assert(m.isFaceHidden(2),
        "T-S6a: restoreGeometryKeepSelection must keep the LIVE Hide bit — "
        ~ "Hide is a view onto the mesh (§1.5), like Select, not content like "
        ~ "Subpatch. Reading false here means the splice restored the whole "
        ~ "word from the snapshot.");
    assert(m.isFaceSubpatch(3),
        "T-S6a: the same call must RESTORE the snapshot's Subpatch bit. "
        ~ "Reading false here means the splice kept the whole live word — "
        ~ "which would pass a Hide-only assertion, and is why both halves are "
        ~ "asserted off one restore.");

    // And the plane the splice does not name at all still tracks the face
    // plane it derives from: face 2 alone hides no cube vertex (every corner
    // still touches two visible faces), so nothing derived may have flipped.
    foreach (vi; 0 .. m.vertices.length)
        assert(!m.isVertexHidden(vi),
            "T-S6a: hiding one cube face derives no hidden vertex");
}
