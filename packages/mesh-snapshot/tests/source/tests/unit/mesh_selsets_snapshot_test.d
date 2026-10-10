module tests.unit.mesh_selsets_snapshot_test;
import std.conv : to;
import std.array : replicate;
import math : Vec3;
import mesh;
import mesh_edit_delta : MeshEditTracker, MeshEditScope;
import mesh_selsets;
import snapshot : MeshSnapshot;
// ---------------------------------------------------------------------------
// Stage 2 — MeshSnapshot must .dup the edgeSetMask associative array. A bare
// `s.edgeSetMask = mesh.edgeSetMask` aliases the live registry (D AAs are
// reference types) — a mutation made to the mesh AFTER capture would then be
// visible through the "captured" snapshot too, and restore() would put back
// the MUTATED state instead of the true pre-capture one. Mirrors
// `meshMaps.dup`'s existing precedent (snapshot.d).
// ---------------------------------------------------------------------------

unittest {
    Mesh m = makeCube();
    m.syncSelection();
    m.selectEdge(0);
    selSetEditEdge(m, "E", SetEditMode.add, m.selectedEdges);

    auto snap = MeshSnapshot.capture(m);

    // Mutate the LIVE mesh's edge-set registry AFTER capture — replace E's
    // membership with a DIFFERENT edge entirely.
    m.clearEdgeSelection();
    m.selectEdge(1);
    selSetEditEdge(m, "E", SetEditMode.replace, m.selectedEdges);

    snap.restore(m);
    m.clearEdgeSelection();
    assert(selSetApplyEdge(m, "E", SetApplyMode.replace));
    assert(m.isEdgeSelected(0) && !m.isEdgeSelected(1),
        "restore() must bring back E's PRE-capture membership (edge 0) — "
      ~ "if capture() aliased the AA instead of .dup-ing it, the live "
      ~ "post-capture mutation (edge 1) would have leaked into the "
      ~ "snapshot and come back instead");
}

