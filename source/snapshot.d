module snapshot;

import std.algorithm.iteration : map;
import std.array : array;

import mesh;
import math;
import change_bus : MeshChangeAll;

// ---------------------------------------------------------------------------
// MeshSnapshot — full pre-apply mesh + selection + subpatch state, used by
// commands whose revert() needs to restore "whatever the mesh looked like
// before". Captures everything via .dup so subsequent mesh mutations don't
// alias the snapshot.
//
// Heavyweight (~MB for large meshes); commands that only mutate a small
// slice (e.g. mesh.move_vertex, subpatch_toggle) should snapshot only the
// affected fields instead of using this helper.
//
// Note: Command instances hold their editMode by value (not ref), so
// the snapshot doesn't capture or restore edit mode here. If a command
// changes editMode (none currently do — that's a tool / app.d concern),
// it must handle that separately.
// ---------------------------------------------------------------------------

struct MeshSnapshot {
    Vec3[]   vertices;
    uint[2][] edges;
    uint[][] faces;
    // Packed per-element flag words (selection + subpatch + any future
    // reserved bits) — the same representation the mesh stores. faceMarks
    // carries both the Select and Subpatch bits, so subpatch round-trips
    // automatically and new mark bits need no snapshot change.
    uint[]   vertexMarks;
    uint[]   edgeMarks;
    uint[]   faceMarks;
    int[]    vertexSelectionOrder;
    int[]    edgeSelectionOrder;
    int[]    faceSelectionOrder;
    int      vertexSelectionOrderCounter;
    int      edgeSelectionOrderCounter;
    int      faceSelectionOrderCounter;
    Surface[] surfaces;
    uint[]    faceMaterial;
    uint[]    facePart;
    MeshMap[] meshMaps;
    bool     filled = false;

    static MeshSnapshot capture(in Mesh mesh) {
        MeshSnapshot s;
        s.vertices             = mesh.vertices.dup;
        s.edges                = mesh.edges.dup;
        // .range needed because the templated `map!` instantiation
        // through `alias this` can't carry const(FaceList) cleanly.
        s.faces                = mesh.faces.range.map!(f => f.dup).array;
        s.vertexMarks          = mesh.vertexMarks.dup;
        s.edgeMarks            = mesh.edgeMarks.dup;
        s.faceMarks            = mesh.faceMarks.dup;
        s.vertexSelectionOrder = mesh.vertexSelectionOrder.dup;
        s.edgeSelectionOrder   = mesh.edgeSelectionOrder.dup;
        s.faceSelectionOrder   = mesh.faceSelectionOrder.dup;
        s.vertexSelectionOrderCounter = mesh.vertexSelectionOrderCounter;
        s.edgeSelectionOrderCounter   = mesh.edgeSelectionOrderCounter;
        s.faceSelectionOrderCounter   = mesh.faceSelectionOrderCounter;
        s.surfaces             = mesh.surfaces.dup;
        s.faceMaterial         = mesh.faceMaterial.dup;
        s.facePart             = mesh.facePart.dup;
        // Deep-dup each map (its `data` too) so later mesh mutations don't
        // alias the snapshot — MeshMap.dup dups the float[] data.
        s.meshMaps             = mesh.meshMaps.map!(mm => mm.dup).array;
        s.filled               = true;
        return s;
    }

    void restore(ref Mesh mesh) const {
        mesh.vertices                    = vertices.dup;
        mesh.edges                       = edges.dup;
        mesh.faces                       = faces.map!(f => f.dup).array;
        // Whole-word restore: faceMarks carries Select + Subpatch (+ any
        // reserved bits) together, so this restores the full per-element
        // flag state. Lengths match the geometry restored just above
        // because they were captured alongside it.
        mesh.vertexMarks                 = vertexMarks.dup;
        mesh.edgeMarks                   = edgeMarks.dup;
        mesh.faceMarks                   = faceMarks.dup;
        mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
        mesh.faceSelectionOrder          = faceSelectionOrder.dup;
        mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
        mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
        mesh.surfaces                    = surfaces.dup;
        mesh.faceMaterial                = faceMaterial.dup;
        mesh.facePart                    = facePart.dup;
        // Restore the map registry (deep-dup so the live mesh doesn't alias
        // the snapshot's data). buildLoops below rebuilds loops/edges; the
        // restored maps' lengths already match the restored geometry because
        // they were captured alongside it, but resizeAllMeshMaps keeps them
        // correct if buildLoops were ever to change an element count.
        mesh.meshMaps                    = meshMaps.map!(mm => mm.dup).array;
        mesh.buildLoops();
        mesh.resizeAllMeshMaps();
        // Snapshot restore rebuilds the WHOLE mesh — geometry, topology, marks
        // and materials may all have changed across the undo/redo. Emit the
        // bulk All mask (which includes Geometry, so commitChange bumps both
        // mutationVersion and topologyVersion exactly as the old two lines did).
        mesh.commitChange(MeshChangeAll);
    }

    // -------------------------------------------------------------------------
    // restoreGeometryKeepSelection — geometry-only revert for the T-SEP undo
    // path (class-aware stepping).
    //
    // Under T-SEP, selection is a SEPARATE timeline: a geometry-move undo must
    // NOT overwrite the live selection with the pre-move snapshot's selection.
    // This method restores positions, edges, faces, surfaces, faceMaterial, and
    // meshMaps — but KEEPS the current selection marks (vertexMarks, edgeMarks,
    // faceMarks) and selection-order counters.
    //
    // Topology-safety rule: keeping the current marks is only correct when the
    // op did NOT change element counts (a pure transform leaves vertex/edge/face
    // counts identical to the snapshot). If counts DIFFER (topology-changing op
    // — e.g. edge.extrude / edge.extend that adds vertices), the live marks
    // would index out-of-bounds or address the wrong elements after the revert,
    // so we fall back to the full snapshot marks in that case.
    //
    // Consequence: topology-changing tools that go through ToolDoApplyCommand
    // (edge.extrude, edge.extend) still restore the pre-apply selection when
    // class-aware stepping is on, because their vertex/face counts change.
    // That is intentional and correct: there is no "current" selection that is
    // valid against the reverted (smaller) mesh.
    // -------------------------------------------------------------------------
    void restoreGeometryKeepSelection(ref Mesh mesh) const {
        // Capture current marks from the live mesh BEFORE we alter the mesh,
        // so we can re-apply them if topology matches.
        auto liveVertexMarks          = mesh.vertexMarks.dup;
        auto liveEdgeMarks            = mesh.edgeMarks.dup;
        auto liveFaceMarks            = mesh.faceMarks.dup;
        auto liveVertexSelOrder       = mesh.vertexSelectionOrder.dup;
        auto liveEdgeSelOrder         = mesh.edgeSelectionOrder.dup;
        auto liveFaceSelOrder         = mesh.faceSelectionOrder.dup;
        int  liveVertexSelOrderCtr    = mesh.vertexSelectionOrderCounter;
        int  liveEdgeSelOrderCtr      = mesh.edgeSelectionOrderCounter;
        int  liveFaceSelOrderCtr      = mesh.faceSelectionOrderCounter;

        // Restore geometry (positions, topology, materials, maps).
        mesh.vertices     = vertices.dup;
        mesh.edges        = edges.dup;
        mesh.faces        = faces.map!(f => f.dup).array;
        mesh.surfaces     = surfaces.dup;
        mesh.faceMaterial = faceMaterial.dup;
        mesh.facePart     = facePart.dup;
        mesh.meshMaps     = meshMaps.map!(mm => mm.dup).array;
        mesh.buildLoops();
        mesh.resizeAllMeshMaps();

        // Topology-safety check: keep current marks only when element counts
        // are unchanged (pure transform — no elements added or removed).
        // If topology changed, the snapshot marks are the safe fallback.
        //
        // IMPORTANT: compare the PRE-RESTORE live counts (captured above in
        // liveXxxMarks.length) against the snapshot counts — NOT mesh.xxx.length
        // after the restore.  After restore, mesh.xxx.length trivially equals
        // xxx.length (we just wrote from the snapshot), so the post-restore
        // comparison would always report "unchanged" even for topology-shrinking
        // ops like mesh.reduce, making the live-marks loop walk out-of-bounds
        // when the reduced mesh had fewer elements than the snapshot.
        bool topologyUnchanged =
            liveVertexMarks.length == vertices.length &&
            liveEdgeMarks.length   == edges.length    &&
            liveFaceMarks.length   == faces.length;

        if (topologyUnchanged) {
            // Pure transform: splice the live selection marks back in,
            // preserving the selection that was current when the undo fired.
            mesh.vertexMarks                 = liveVertexMarks;
            mesh.edgeMarks                   = liveEdgeMarks;
            // For faceMarks, preserve the live SELECT bits but restore the
            // SUBPATCH bits from the snapshot (subpatch is geometry-class
            // state that reverts with the geometry, not a selection).
            auto restoredFaceMarks = liveFaceMarks.dup;
            foreach (i; 0 .. mesh.faces.length) {
                // Replace subpatch bit from snapshot; keep live select bit.
                restoredFaceMarks[i] =
                    (restoredFaceMarks[i] & ~Mesh.Marks.Subpatch)
                    | (faceMarks[i] & Mesh.Marks.Subpatch);
            }
            mesh.faceMarks = restoredFaceMarks;
            mesh.vertexSelectionOrder        = liveVertexSelOrder;
            mesh.edgeSelectionOrder          = liveEdgeSelOrder;
            mesh.faceSelectionOrder          = liveFaceSelOrder;
            mesh.vertexSelectionOrderCounter = liveVertexSelOrderCtr;
            mesh.edgeSelectionOrderCounter   = liveEdgeSelOrderCtr;
            mesh.faceSelectionOrderCounter   = liveFaceSelOrderCtr;
        } else {
            // Topology changed: fall back to snapshot marks (safe against
            // changed element counts).
            mesh.vertexMarks                 = vertexMarks.dup;
            mesh.edgeMarks                   = edgeMarks.dup;
            mesh.faceMarks                   = faceMarks.dup;
            mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
            mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
            mesh.faceSelectionOrder          = faceSelectionOrder.dup;
            mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
            mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
            mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
        }

        mesh.commitChange(MeshChangeAll);
    }
}

// ---------------------------------------------------------------------------
// SelectionSnapshot — lightweight: captures selection arrays + counters
// without touching geometry. Used by select.* commands and any future
// command that only mutates selection state.
// ---------------------------------------------------------------------------

struct SelectionSnapshot {
    bool[] selectedVertices;
    bool[] selectedEdges;
    bool[] selectedFaces;
    int[]  vertexSelectionOrder;
    int[]  edgeSelectionOrder;
    int[]  faceSelectionOrder;
    int    vertexSelectionOrderCounter;
    int    edgeSelectionOrderCounter;
    int    faceSelectionOrderCounter;
    bool   filled = false;

    static SelectionSnapshot capture(in Mesh mesh) {
        SelectionSnapshot s;
        s.selectedVertices     = mesh.selectedVertices.dup;
        s.selectedEdges        = mesh.selectedEdges.dup;
        s.selectedFaces        = mesh.selectedFaces.dup;
        s.vertexSelectionOrder = mesh.vertexSelectionOrder.dup;
        s.edgeSelectionOrder   = mesh.edgeSelectionOrder.dup;
        s.faceSelectionOrder   = mesh.faceSelectionOrder.dup;
        s.vertexSelectionOrderCounter = mesh.vertexSelectionOrderCounter;
        s.edgeSelectionOrderCounter   = mesh.edgeSelectionOrderCounter;
        s.faceSelectionOrderCounter   = mesh.faceSelectionOrderCounter;
        s.filled               = true;
        return s;
    }

    void restore(ref Mesh mesh) const {
        mesh.setVerticesSelectedFrom(selectedVertices);
        mesh.setEdgesSelectedFrom(selectedEdges);
        mesh.setFacesSelectedFrom(selectedFaces);
        mesh.vertexSelectionOrder        = vertexSelectionOrder.dup;
        mesh.edgeSelectionOrder          = edgeSelectionOrder.dup;
        mesh.faceSelectionOrder          = faceSelectionOrder.dup;
        // Hide (code review, task 0613 — S3): the bulk setters above may
        // have silently refused a now-hidden element (Mesh's own Select ∧
        // Hide = ∅ invariant, doc/hide_geometry_plan.md §3.1 — their guard
        // zeroes that element's order entry when it refuses). The wholesale
        // order-array overwrite just above was captured BEFORE any refusal,
        // so it can resurrect a stale nonzero stamp for an element that the
        // setter just refused to select — same corruption class fixed at
        // mesh.d's selectVerticesFrom/selectEdgesFrom/selectFacesFrom. Re-zero
        // here too, keyed off the mesh's actual (post-refusal) selection
        // state, not the snapshot's.
        foreach (i; 0 .. mesh.vertexSelectionOrder.length)
            if (!mesh.isVertexSelected(i)) mesh.vertexSelectionOrder[i] = 0;
        foreach (i; 0 .. mesh.edgeSelectionOrder.length)
            if (!mesh.isEdgeSelected(i)) mesh.edgeSelectionOrder[i] = 0;
        foreach (i; 0 .. mesh.faceSelectionOrder.length)
            if (!mesh.isFaceSelected(i)) mesh.faceSelectionOrder[i] = 0;
        mesh.vertexSelectionOrderCounter = vertexSelectionOrderCounter;
        mesh.edgeSelectionOrderCounter   = edgeSelectionOrderCounter;
        mesh.faceSelectionOrderCounter   = faceSelectionOrderCounter;
    }
}

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
