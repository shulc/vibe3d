// mesh_selsets — storage-kernel unit tests (task 1060, Stage 1 + Stage 5b).
//
// Stage 1: create/lookup/rename/delete lifecycle, the two kernel caps, name
// validation, multi-membership, and per-domain namespacing — all three
// domains get SOME direct coverage; the vertex domain gets the full
// lifecycle since the three domains share the exact same array-mask engine
// (Vertex/Polygon) or an intentionally analogous one (Edge).
//
// Stage 5b: the edge-set re-key primitive, each test named with the mutation
// it reddens under (doc/selection_sets_plan.md Stage 5b / the mutation
// table). Tests 1/2/6 exercise the REAL mesh kernels (weld, compaction, the
// undo/redo delta replay) so the WIRING into those six call sites is
// covered, not just the primitive in isolation; tests 3/4/5 exercise
// `selSetRekeyEdges` directly, which is the more precise way to pin its own
// three-way branch (drop / collapse / merge) without fighting a weld
// fixture into producing each shape.
module tests.unit.mesh_selsets_test;

import std.conv : to;
import std.array : replicate;
import math : Vec3;
import mesh;
import mesh_edit_delta : MeshEditTracker, MeshEditScope;
import mesh_selsets;
import snapshot : MeshSnapshot;

// ---------------------------------------------------------------------------
// Stage 1 — registry lifecycle (vertex domain, full coverage)
// ---------------------------------------------------------------------------

unittest { // create (via edit/add on a missing name) + lookup + apply + rename + delete
    Mesh m = makeCube();
    m.syncSelection();

    m.selectVertex(0);
    selSetEditVertex(m, "A", SetEditMode.add, m.selectedVertices);
    assert(selSetNamesVertex(m) == ["A"], "editing a missing name must CREATE it");
    assert(selSetOwnsVertex(m, "A"));

    m.clearVertexSelection();
    assert(selSetApplyVertex(m, "A", SetApplyMode.replace), "apply must find the set");
    assert(m.isVertexSelected(0), "apply replace must select the set's own member");

    assert(selSetRenameVertex(m, "A", "B") == 0, "rename must succeed");
    assert(selSetNamesVertex(m) == ["B"]);
    assert(selSetRenameVertex(m, "Nope", "C") == 1, "renaming a missing name must fail");

    m.clearVertexSelection();
    m.selectVertex(1);
    selSetEditVertex(m, "C", SetEditMode.add, m.selectedVertices);
    assert(selSetRenameVertex(m, "B", "C") == 2,
        "renaming onto an EXISTING name must fail, not silently merge");

    assert(selSetDeleteVertex(m, "B"), "delete must find the set");
    assert(!selSetOwnsVertex(m, "B"));
    assert(!selSetApplyVertex(m, "B", SetApplyMode.replace),
        "apply against a deleted name must find no owner");
}

unittest { // delete clears the BIT COLUMN — re-creating the name must NOT resurrect members
    Mesh m = makeCube();
    m.syncSelection();

    m.selectVertex(0);
    selSetEditVertex(m, "B", SetEditMode.add, m.selectedVertices);
    assert(selSetDeleteVertex(m, "B"));

    // Re-create "B" from a DIFFERENT selection — vertex 0's old membership
    // must not resurface. If delete only freed the NAME slot but left
    // vertex 0's old bit standing, applying "B" here would select BOTH
    // vertex 0 (the ghost) and vertex 2 (the real new member).
    m.clearVertexSelection();
    m.selectVertex(2);
    selSetEditVertex(m, "B", SetEditMode.add, m.selectedVertices);

    m.clearVertexSelection();
    assert(selSetApplyVertex(m, "B", SetApplyMode.replace));
    assert(!m.isVertexSelected(0),
        "delete-then-recreate resurrected a member the delete should have purged");
    assert(m.isVertexSelected(2));
}

unittest { // the membership cap is a REFUSAL, not a silent truncation
    Mesh m = makeCube();
    m.syncSelection();
    m.selectVertex(0);
    foreach (i; 0 .. MAX_SELECTION_SETS)
        selSetEditVertex(m, "S" ~ i.to!string, SetEditMode.add, m.selectedVertices);
    assert(selSetNamesVertex(m).length == MAX_SELECTION_SETS);

    bool threw = false;
    try selSetEditVertex(m, "one-too-many", SetEditMode.add, m.selectedVertices);
    catch (Exception e) threw = true;
    assert(threw, "creating set #" ~ to!string(MAX_SELECTION_SETS + 1)
        ~ " must refuse, not corrupt the registry");
    assert(selSetNamesVertex(m).length == MAX_SELECTION_SETS,
        "a refused creation must not have grown the registry");

    // A freed slot IS reusable — the cap is on LIVE sets, not lifetime count.
    assert(selSetDeleteVertex(m, "S0"));
    selSetEditVertex(m, "reuses-the-freed-slot", SetEditMode.add, m.selectedVertices);
    assert(selSetNamesVertex(m).length == MAX_SELECTION_SETS);
}

unittest { // name validation
    assert(validateSetName("") !is null, "empty name must be rejected");
    assert(validateSetName("ok name") is null, "spaces are allowed (measured: \"B B\")");
    string longName = replicate("x", MAX_SET_NAME_LEN + 1);
    assert(validateSetName(longName) !is null, "over-long name must be rejected");
    string maxName = replicate("x", MAX_SET_NAME_LEN);
    assert(validateSetName(maxName) is null, "exactly the cap must be accepted");
    assert(validateSetName("has;semicolon") !is null,
        "';' is the reserved interchange separator and must be rejected");
    assert(validateSetName("has\x01control") !is null,
        "a control byte must be rejected");
}

unittest { // multi-membership — an element can belong to more than one set
    Mesh m = makeCube();
    m.syncSelection();

    m.selectVertex(0); m.selectVertex(1);
    selSetEditVertex(m, "A", SetEditMode.add, m.selectedVertices);
    m.clearVertexSelection();
    m.selectVertex(1); m.selectVertex(2);
    selSetEditVertex(m, "B", SetEditMode.add, m.selectedVertices);   // vertex 1 in BOTH

    m.clearVertexSelection();
    selSetApplyVertex(m, "A", SetApplyMode.replace);
    assert(m.isVertexSelected(0) && m.isVertexSelected(1) && !m.isVertexSelected(2));
    selSetApplyVertex(m, "B", SetApplyMode.select);   // union
    assert(m.isVertexSelected(0) && m.isVertexSelected(1) && m.isVertexSelected(2),
        "vertex 1's membership in BOTH sets must survive independently");

    // deselect removes exactly B's members, leaving A's alone
    selSetApplyVertex(m, "B", SetApplyMode.deselect);
    assert(m.isVertexSelected(0) && !m.isVertexSelected(1) && !m.isVertexSelected(2));
}

unittest { // per-domain namespaces — the SAME name may exist once per domain
    Mesh m = makeCube();
    m.syncSelection();

    m.selectVertex(0);
    selSetEditVertex(m, "Same", SetEditMode.add, m.selectedVertices);
    m.clearVertexSelection();
    m.selectFace(0);
    selSetEditPolygon(m, "Same", SetEditMode.add, m.selectedFaces);

    assert(selSetOwnsVertex(m, "Same"));
    assert(selSetOwnsPolygon(m, "Same"));
    assert(!selSetOwnsEdge(m, "Same"), "a name in one domain must not leak into another");

    // Deleting one domain's "Same" must not touch the other's.
    assert(selSetDeletePolygon(m, "Same"));
    assert(selSetOwnsVertex(m, "Same"), "deleting the polygon set must not delete the vertex set");
}

unittest { // edge + polygon domain smoke test — the same lifecycle, briefly
    Mesh m = makeCube();
    m.syncSelection();

    // edge
    m.selectEdge(0);
    selSetEditEdge(m, "E", SetEditMode.add, m.selectedEdges);
    assert(selSetNamesEdge(m) == ["E"]);
    m.clearEdgeSelection();
    assert(selSetApplyEdge(m, "E", SetApplyMode.replace));
    assert(m.isEdgeSelected(0));
    assert(selSetRenameEdge(m, "E", "E2") == 0);
    assert(selSetDeleteEdge(m, "E2"));
    assert(!selSetOwnsEdge(m, "E2"));

    // polygon
    m.selectFace(3);
    selSetEditPolygon(m, "P", SetEditMode.add, m.selectedFaces);
    assert(selSetNamesPolygon(m) == ["P"]);
    m.clearFaceSelection();
    assert(selSetApplyPolygon(m, "P", SetApplyMode.replace));
    assert(m.isFaceSelected(3));
    assert(selSetRenamePolygon(m, "P", "P2") == 0);
    assert(selSetDeletePolygon(m, "P2"));
    assert(!selSetOwnsPolygon(m, "P2"));
}

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

private double[3] pos(Mesh m, uint vi) {
    return [m.vertices[vi].x, m.vertices[vi].y, m.vertices[vi].z];
}
private bool near(double[3] a, double[3] b) {
    import std.math : abs;
    return abs(a[0]-b[0]) < 1e-6 && abs(a[1]-b[1]) < 1e-6 && abs(a[2]-b[2]) < 1e-6;
}

/// The fixture Stage-5b tests 1 and 2 share: three quads. Quad A (v0-3) is
/// the weld TARGET; quad C (v4-7) DUPLICATES v0's position at v4 so a
/// position-weld collapses v4 into v0; quad B (v8-11) is UNRELATED to the
/// weld and sits after the dropped slot, so compaction shifts its indices
/// down by one — the "renumbering weld" the plan's test 1 needs, and the
/// site test 2 needs an edge touching v4 itself for.
private Mesh weldFixture() {
    Vec3[] verts = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),   // A: 0-3
        Vec3(0,0,0), Vec3(1,0,1), Vec3(1,1,1), Vec3(0,1,1),   // C: 4-7 (v4 dupes v0)
        Vec3(0,0,5), Vec3(1,0,5), Vec3(1,1,5), Vec3(0,1,5),   // B: 8-11
    ];
    Mesh m;
    foreach (v; verts) m.addVertex(v);
    m.addFace([0u,1u,2u,3u]);
    m.addFace([4u,5u,6u,7u]);
    m.addFace([8u,9u,10u,11u]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

unittest { // test 1 — the RENUMBERING weld: an unrelated survivor shifts index
    Mesh m = weldFixture();
    const ei = m.edgeIndex(8, 9);
    m.selectEdge(ei);
    selSetEditEdge(m, "E", SetEditMode.add, m.selectedEdges);

    auto want0 = pos(m, 8), want1 = pos(m, 9);   // (0,0,5) / (1,0,5)

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true; mask[4] = true;   // coincident at (0,0,0)
    const welded = m.weldVerticesByMask(mask, 1e-12);
    assert(welded == 1, "setup: exactly v4 must weld into v0");
    assert(m.vertices.length == 11, "setup: compaction must drop the now-unreferenced v4");

    m.clearEdgeSelection();
    assert(selSetApplyEdge(m, "E", SetApplyMode.replace));
    size_t nSel = 0; size_t foundAt = size_t.max;
    foreach (i; 0 .. m.edges.length) if (m.isEdgeSelected(i)) { ++nSel; foundAt = i; }
    assert(nSel == 1,
        "the renumbering weld must leave EXACTLY one edge tagged — got " ~ to!string(nSel));
    const a = pos(m, m.edges[foundAt][0]), b = pos(m, m.edges[foundAt][1]);
    assert((near(a, want0) && near(b, want1)) || (near(a, want1) && near(b, want0)),
        "the surviving member must resolve to the SAME geometric edge by position, "
      ~ "not merely some edge with the stale numeric key");
}

unittest { // test 2 — the MERGE weld: an edge whose OWN endpoint welds away
    Mesh m = weldFixture();
    const ei = m.edgeIndex(4, 5);   // touches v4, the vertex that will weld away
    m.selectEdge(ei);
    selSetEditEdge(m, "E", SetEditMode.add, m.selectedEdges);

    auto wantMerged = pos(m, 0);    // v4 merges INTO v0 (lowest index survives)
    auto wantOther  = pos(m, 5);    // the edge's other endpoint, untouched

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true; mask[4] = true;
    m.weldVerticesByMask(mask, 1e-12);

    m.clearEdgeSelection();
    assert(selSetApplyEdge(m, "E", SetApplyMode.replace));
    size_t nSel = 0; size_t foundAt = size_t.max;
    foreach (i; 0 .. m.edges.length) if (m.isEdgeSelected(i)) { ++nSel; foundAt = i; }
    assert(nSel == 1,
        "the merge weld must leave the membership attached to exactly one edge "
      ~ "(it must FOLLOW to the merged pair, not vanish) — got " ~ to!string(nSel));
    const a = pos(m, m.edges[foundAt][0]), b = pos(m, m.edges[foundAt][1]);
    assert((near(a, wantMerged) && near(b, wantOther))
        || (near(a, wantOther) && near(b, wantMerged)),
        "the surviving member must be the MERGED pair, not the old (dropped) one");
}

unittest { // test 2b — the COINCIDENT-VERTEX weld funnel: weldCoincidentVertices -> applyVertexRemap
    // Same merge shape as test 2 (an edge whose OWN endpoint welds away), but
    // driven through the SIBLING funnel `weldCoincidentVertices` ->
    // `applyVertexRemap`, not `weldVerticesByMask` -> `applyVertexRemapAndRebuild`.
    // Review blocker (task 1060): `applyVertexRemap` carried the face mask
    // through the collapse (`faceSetMask = newSetMask`) but never re-keyed the
    // edge-set AA — this funnel silently dropped the membership while the
    // mask-based funnel (test 2) kept it. Same fixture, same merge, two
    // spellings, and (pre-fix) two different answers.
    Mesh m = weldFixture();
    const ei = m.edgeIndex(4, 5);   // touches v4, the vertex that will weld away
    m.selectEdge(ei);
    selSetEditEdge(m, "E", SetEditMode.add, m.selectedEdges);

    auto wantMerged = pos(m, 0);    // v4 merges INTO v0 (lowest index survives)
    auto wantOther  = pos(m, 5);    // the edge's other endpoint, untouched

    const welded = m.weldCoincidentVertices(1e-12);
    assert(welded == 1, "setup: exactly v4 must weld into v0 through this funnel too");

    m.clearEdgeSelection();
    assert(selSetApplyEdge(m, "E", SetApplyMode.replace));
    size_t nSel = 0; size_t foundAt = size_t.max;
    foreach (i; 0 .. m.edges.length) if (m.isEdgeSelected(i)) { ++nSel; foundAt = i; }
    assert(nSel == 1,
        "the coincident-vertex weld funnel must leave the membership attached to "
      ~ "exactly one edge (it must FOLLOW to the merged pair, not vanish) — got "
      ~ to!string(nSel));
    const a = pos(m, m.edges[foundAt][0]), b = pos(m, m.edges[foundAt][1]);
    assert((near(a, wantMerged) && near(b, wantOther))
        || (near(a, wantOther) && near(b, wantMerged)),
        "the surviving member must be the MERGED pair, not the old (dropped) one");
}

// ---------------------------------------------------------------------------
// Task 2310 — THE MERGE HALF, THROUGH `revert()`.
//
// Tests 2 and 2b above stop one line short: both drive a MERGE weld and both
// assert the FORWARD only. The file's undo cell (test 6) drives the compaction
// alone, whose remap is injective on survivors, so it exercises the RENUMBER
// and DROP halves of `selSetRekeyEdges` and never the MERGE half.
//
// WHY THE FIXTURE IS NOT `weldFixture()`. Under that fixture the survivor key
// (0,5) names no edge at all before the weld, so a post-undo membership sitting
// on it is a stale AA entry — real, but invisible to anything a user drives.
// The face `[0,5,1]` below makes edge (0,5) EXIST and be a NON-member before
// the op, so the wrong answer is a different, EXISTING edge wearing the set —
// and `selSetApplyEdge` then selects exactly ONE edge either way. That is the
// property that makes this class need a per-plane witness: the COUNT is equal
// on both answers, and so are V, F, E and every other plane.
//
// v0 and v4 are COINCIDENT by construction (that is what makes them weld), so
// edges (4,5) and (0,5) are geometrically identical and `pos()` cannot tell
// them apart. These cells identify the edge by INDEX for that reason.
private Mesh mergeWeldFixture() {
    Vec3[] verts = [
        Vec3(0,0,0), Vec3(1,0,0), Vec3(1,1,0), Vec3(0,1,0),   // A: 0-3
        Vec3(0,0,0), Vec3(1,0,1), Vec3(1,1,1), Vec3(0,1,1),   // C: 4-7 (v4 dupes v0)
        Vec3(0,-1,0), Vec3(1,-1,1),                           // D: 8-9, the survivor face
    ];
    Mesh m;
    foreach (v; verts) m.addVertex(v);
    m.addFace([0u,1u,2u,3u]);
    m.addFace([4u,5u,6u,7u]);
    // The survivor face, and its WINDING is `5,0,…` for a reason: post-weld it
    // shares edge (0,5) with `[0,5,6,7]`, which traverses 0->5, so this one must
    // traverse 5->0 or `buildLoops` reports an inconsistently-wound pair and the
    // fixture's vertex fans stop being usable. It shares no edge with `[0,1,2,3]`
    // (only vertex 0), so the pre-weld mesh is consistent too.
    m.addFace([5u,0u,8u,9u]);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private bool edgeSetHasKey(ref Mesh m, uint a, uint b) {
    if (auto p = edgeKey(a, b) in m.edgeSetMask) return *p != 0;
    return false;
}

private string mergePlaneReport(ref Mesh m) {
    return "plane `edgeSetMask`: edge (4,5) member=" ~ to!string(edgeSetHasKey(m, 4, 5))
         ~ ", edge (0,5) member=" ~ to!string(edgeSetHasKey(m, 0, 5));
}

unittest { // test 2c — the MERGE weld through UNDO, funnel A: weldVerticesByMask -> applyVertexRemapAndRebuild
    Mesh m = mergeWeldFixture();
    const ei = m.edgeIndex(4, 5);
    assert(ei != cast(uint)~0u, "setup: the tagged edge (4,5) must exist");
    assert(m.edgeIndex(0, 5) != cast(uint)~0u,
        "setup: the SURVIVOR edge (0,5) must EXIST before the weld — without it "
      ~ "the spurious half of this loss is only a stale key and the cell is weaker "
      ~ "than the defect");
    m.selectEdge(ei);
    selSetEditEdge(m, "E", SetEditMode.add, m.selectedEdges);
    m.clearEdgeSelection();

    // The pre-op image of the ONE plane this cell is about, both halves, so a
    // post-undo red cannot be read as "the fixture never had it".
    assert(edgeSetHasKey(m, 4, 5), "setup: " ~ mergePlaneReport(m));
    assert(!edgeSetHasKey(m, 0, 5), "setup: " ~ mergePlaneReport(m));
    const preV = m.vertices.length;
    const preE = m.edges.length;
    const preF = m.faces.length;

    bool[] mask = new bool[](m.vertices.length);
    mask[0] = true; mask[4] = true;

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    const welded = m.weldVerticesByMask(mask, 1e-12);
    auto delta = m.endEditBatch();
    assert(welded == 1, "setup: exactly v4 must weld into v0");
    assert(m.vertices.length == preV - 1,
        "setup: the forward must actually change the mesh — a cell whose forward "
      ~ "is a no-op reverts nothing and passes for the wrong reason");
    assert(!delta.isEmpty,
        "setup: the batch recorded NOTHING, so `revert()` below would answer true "
      ~ "over an empty log and this cell would be inert");

    // `revert()` answers TRUE on a refusal and on a no-op alike, so its return
    // is a precondition here, never the witness.
    assert(delta.revert(m), "reverse replay must succeed");
    assert(m.vertices.length == preV && m.faces.length == preF,
        "the revert must restore V and F — and it ALREADY DID before this commit: "
      ~ "every count that CAN round-trip on this funnel is equal across the defect, "
      ~ "which is why the two rows below are the only ones that can see it");
    // CLOSED BY STAGE L10 (2026-08-28), and the flip is recorded here with its
    // arithmetic. This row read `preE - 1` while `applyVertexRemapAndRebuild`'s
    // `rewriteFaces` was the twin L5-a deliberately left UNARMED: no
    // `FaceReindex` entered the log, the pre-weld windings were never
    // reinstalled, and `rebuildEdges` re-derived **11** edges from the
    // post-weld faces against a pre-op **12**. L10 wrapped that one rewrite in
    // `faceReindexScope()` and E came back whole. The row reddened BY DESIGN
    // in that commit, which is what the sentence it replaced asked for.
    assert(m.edges.length == preE,
        "E after revert is " ~ to!string(m.edges.length) ~ ", expected " ~ to!string(preE)
      ~ ". This funnel's face rewrite is ARMED as of stage L10 "
      ~ "(`Mesh.applyVertexRemapAndRebuild`); deleting that arm returns E to "
      ~ preE.to!string ~ " - 1 while `revert()` still answers TRUE and V and F "
      ~ "still round-trip.");

    // THE WITNESS. Both directions, both values printed, because the failure is
    // symmetric: the membership must come BACK to (4,5) and must be GONE from
    // the survivor (0,5) it followed on the way forward.
    assert(edgeSetHasKey(m, 4, 5),
        "undo lost the edge-set membership of edge (4,5): the weld re-keyed it "
      ~ "onto the survivor through a MERGE map and nothing recorded the merge, so "
      ~ "the reverse had nothing to invert. " ~ mergePlaneReport(m));
    assert(!edgeSetHasKey(m, 0, 5),
        "undo left a SPURIOUS edge-set membership on the survivor edge (0,5), "
      ~ "which was not a member before the weld. " ~ mergePlaneReport(m));

    // The user-visible tail. Until stage L10 armed this funnel's rewrite, edge
    // (4,5) did not EXIST after the revert (see the E row above), so no
    // selection-based check could run here at all and test 2d — on the funnel
    // whose rewrite was already armed — carried this half alone. It exists
    // again now, so the membership is checked the way a user would see it:
    // through `selSetApplyEdge`, not only through the registry AA.
    m.clearEdgeSelection();
    selSetApplyEdge(m, "E", SetApplyMode.replace);
    const eBack = m.edgeIndex(4, 5);
    assert(eBack != cast(uint)~0u,
        "the armed revert must bring edge (4,5) back into the edge array — "
      ~ "without it the row above is the only witness and this tail is inert");
    assert(m.isEdgeSelected(eBack),
        "selecting set \"E\" after the revert must select edge (4,5): the "
      ~ "registry AA and the user-visible selection must agree, and a "
      ~ "membership that only the AA can see is not the plane a user has.");
}

unittest { // test 2d — the MERGE weld through UNDO, funnel B: weldCoincidentVertices -> applyVertexRemap
    // The SHIPPED shape: `mesh_ops/cleanup.cleanupMesh` runs exactly this pair
    // (weld, then compact) inside `MeshCleanup`'s recording batch, and reverts
    // through the delta. Funnel A above is the OTHER remap (`weldVertexPairs`,
    // `weldVerticesByMask`); the two sites are separate code and a green on one
    // says nothing about the other.
    Mesh m = mergeWeldFixture();
    const ei = m.edgeIndex(4, 5);
    assert(ei != cast(uint)~0u, "setup: the tagged edge (4,5) must exist");
    m.selectEdge(ei);
    selSetEditEdge(m, "E", SetEditMode.add, m.selectedEdges);
    m.clearEdgeSelection();

    assert(edgeSetHasKey(m, 4, 5), "setup: " ~ mergePlaneReport(m));
    assert(!edgeSetHasKey(m, 0, 5), "setup: " ~ mergePlaneReport(m));
    const preV = m.vertices.length;
    const preE = m.edges.length;
    const preF = m.faces.length;

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    const welded = m.weldCoincidentVertices(1e-12);
    const removed = m.compactUnreferenced();
    auto delta = m.endEditBatch();
    assert(welded == 1, "setup: exactly v4 must weld into v0 through this funnel too");
    assert(removed == 1, "setup: the compaction must drop the now-unreferenced v4");
    assert(m.vertices.length == preV - 1, "setup: the forward must actually change the mesh");
    assert(!delta.isEmpty, "setup: the batch recorded NOTHING — this cell would be inert");

    assert(delta.revert(m), "reverse replay must succeed");
    assert(m.vertices.length == preV && m.edges.length == preE && m.faces.length == preF,
        "the revert must restore V/F/E");

    assert(edgeSetHasKey(m, 4, 5),
        "undo lost the edge-set membership of edge (4,5) on the `weldCoincidentVertices` "
      ~ "funnel — the one `MeshCleanup` ships. " ~ mergePlaneReport(m));
    assert(!edgeSetHasKey(m, 0, 5),
        "undo left a SPURIOUS edge-set membership on the survivor edge (0,5) on the "
      ~ "`weldCoincidentVertices` funnel. " ~ mergePlaneReport(m));

    // The user-visible consequence of the same two rows, and it is why a count
    // cannot see this: exactly one edge carries the set either way — a DIFFERENT
    // one. This funnel's rewrite IS armed (L5-a), so edge (4,5) is back and the
    // selection can be resolved.
    m.clearEdgeSelection();
    assert(selSetApplyEdge(m, "E", SetApplyMode.replace));
    size_t nSel = 0; size_t foundAt = size_t.max;
    foreach (i; 0 .. m.edges.length) if (m.isEdgeSelected(i)) { ++nSel; foundAt = i; }
    assert(nSel == 1, "exactly one edge must carry the set after undo — got " ~ to!string(nSel));
    const ea = m.edges[foundAt][0], eb = m.edges[foundAt][1];
    assert((ea == 4 && eb == 5) || (ea == 5 && eb == 4),
        "after undo the set names edge (" ~ to!string(ea) ~ "," ~ to!string(eb) ~ ") — "
      ~ "the pre-op member was (4,5). v0 and v4 are COINCIDENT, so the wrong edge is "
      ~ "geometrically identical to the right one and no position-based check can "
      ~ "tell them apart.");

    // REDO — the half that keeps `Kind.EdgeSetRekey`'s FORWARD arm from being
    // dead code. `MeshSessionEdit` replays a delta forward for redo, and with a
    // no-op forward the keys this cell just restored would be dropped OUTRIGHT
    // by the following `Reindex` (endpoint 4 does not exist in the compacted
    // space), i.e. the fix for undo would have bought a loss on redo.
    // Post-compaction the survivor pair is (0,4): v4 is gone, so old v5 is new v4.
    assert(delta.apply(m), "forward replay must succeed");
    assert(m.vertices.length == preV - 1, "redo must re-apply the weld");
    assert(edgeSetHasKey(m, 0, 4),
        "redo lost the membership: the forward arm of Kind.EdgeSetRekey did not "
      ~ "re-run the weld's merge, so `Reindex` forward dropped the pre-weld key "
      ~ "whose endpoint no longer exists. plane `edgeSetMask`: edge (0,4) member="
      ~ to!string(edgeSetHasKey(m, 0, 4)) ~ ", edge (4,5) member="
      ~ to!string(edgeSetHasKey(m, 4, 5)));
    assert(!edgeSetHasKey(m, 4, 5),
        "redo left the PRE-weld key (4,5) live in the compacted space");
}

unittest { // test 3 — the COLLAPSE: both endpoints map to the same new vertex
    Mesh m;
    m.edgeSetMask[edgeKey(4, 12)] = 1UL;
    selSetRekeyEdges(m, (uint v) => (v == 4 || v == 12) ? 0u : v);
    assert(m.edgeSetMask.length == 0,
        "both endpoints collapsing onto one vertex must drop the entry — "
      ~ "a degenerate self-key must never survive");
}

unittest { // test 4 — the COLLISION merge: two DIFFERENT tagged edges collapse onto one
    Mesh m;
    m.edgeSetMask[edgeKey(1, 2)] = 1UL;   // set "A" — bit 0
    m.edgeSetMask[edgeKey(5, 6)] = 2UL;   // set "B" — bit 1, a DIFFERENT edge
    uint nu(uint v) {
        if (v == 1 || v == 5) return 0;
        if (v == 2 || v == 6) return 3;
        return v;
    }
    selSetRekeyEdges(m, &nu);
    const k = edgeKey(0, 3);
    assert((k in m.edgeSetMask) !is null, "the survivor key must exist");
    assert(m.edgeSetMask[k] == 3UL,
        "the survivor must carry BOTH sets' bits via OR-merge (conservative arm — "
      ~ "membership is never lost on a collision) — got " ~ to!string(m.edgeSetMask[k]));
    assert(m.edgeSetMask.length == 1, "the two old keys must collapse into exactly one entry");
}

unittest { // test 5 — the VANISH prune: a dropped key must not resurrect later
    Mesh m;
    m.edgeSetMask[edgeKey(2, 3)] = 1UL;
    selSetRekeyEdges(m, (uint v) => v == 2 ? uint.max : v);   // vertex 2 gone
    assert(m.edgeSetMask.length == 0, "an endpoint going away must drop the entry");

    // A later re-key that happens to be identity must not bring anything
    // back — selSetRekeyEdges only ever transforms what is IN the AA right
    // now; nothing "remembers" a pruned key.
    selSetRekeyEdges(m, (uint v) => v);
    assert(m.edgeSetMask.length == 0,
        "a pruned key must not come back to life under a later, unrelated re-key");
}

unittest { // test 6 — undo/redo (the four mesh_edit_delta.d replay sites)
    // Byte-identical topology shape to the task-0930 fixture this mirrors
    // (tests/unit/mesh_edit_delta_test.d): 7 vertices, triangle [0,1,2], a
    // hanging (unreferenced) vertex 3 — a MIDDLE drop, not a tail drop — and
    // a second triangle [4,5,6]. The tagged edge lives in the SECOND
    // triangle, untouched by the drop itself but renumbered by it.
    Mesh m;
    foreach (i; 0 .. 7) m.addVertex(Vec3(cast(float) i, 0, 0));
    m.addFace([0u, 1u, 2u]);
    m.addFace([4u, 5u, 6u]);
    m.buildLoops();
    m.syncSelection();

    const ei = m.edgeIndex(4, 5);
    m.selectEdge(ei);
    selSetEditEdge(m, "E", SetEditMode.add, m.selectedEdges);

    bool memberIsPositions(double[3] p0, double[3] p1) {
        size_t nSel = 0; size_t foundAt = size_t.max;
        foreach (i; 0 .. m.edges.length) if (m.isEdgeSelected(i)) { ++nSel; foundAt = i; }
        if (nSel != 1) return false;
        const a = pos(m, m.edges[foundAt][0]), b = pos(m, m.edges[foundAt][1]);
        return (near(a, p0) && near(b, p1)) || (near(a, p1) && near(b, p0));
    }

    auto want0 = Vec3(4,0,0), want1 = Vec3(5,0,0);
    double[3] w0 = [want0.x, want0.y, want0.z];
    double[3] w1 = [want1.x, want1.y, want1.z];

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Points);
    const removed = m.compactUnreferenced();
    auto delta = m.endEditBatch();
    assert(removed == 1, "setup: only the hanging vertex 3 is unreferenced");
    assert(m.vertices.length == 6);

    m.clearEdgeSelection();
    selSetApplyEdge(m, "E", SetApplyMode.replace);
    assert(memberIsPositions(w0, w1),
        "direct compactUnreferenced must have already re-keyed the edge set "
      ~ "(this is the Stage-5a/5b live-path assertion, not the replay one yet)");

    // Undo: Reindex^-1 + RemoveVerts^-1 restore the pre-compaction index
    // space. The edge-set entry must re-key BACK to the pre-compaction pair.
    assert(delta.revert(m), "reverse replay must succeed");
    assert(m.vertices.length == 7);
    m.clearEdgeSelection();
    selSetApplyEdge(m, "E", SetApplyMode.replace);
    assert(memberIsPositions(w0, w1),
        "applyReindexReverse/removeVertsReverse must re-key the edge set back "
      ~ "to the pre-compaction pair, not leave it stale or drop it");

    // Redo: must reproduce the direct kernel's re-key through the SAME
    // permutation compactUnreferenced used, not by coincidence.
    assert(delta.apply(m), "forward replay must succeed");
    assert(m.vertices.length == 6);
    m.clearEdgeSelection();
    selSetApplyEdge(m, "E", SetApplyMode.replace);
    assert(memberIsPositions(w0, w1),
        "applyReindexForward/removeVertsForward must re-key the edge set on redo");
}

unittest { // test 7 — review SHOULD-FIX 4: face-delete undo must restore SET
           // membership, not just material/part
    // The four `recordRemoveFaces` call sites (Mesh.deleteFacesByMask,
    // Mesh.dissolveVerticesByMask, the merge path, extrudeFacesByMask) all
    // populate `facePrt`, so `facePart`'s "not carried" fallback in
    // mesh_edit_delta.d's removeFacesReverse is dead in practice — a face
    // delete's undo always restores material/part correctly. Before this
    // fix, `faceSetMask` had no capture field on `MeshOpEntry` at all, so it
    // ALWAYS took the "not carried" 0-insert arm — every face-delete undo
    // silently dropped the restored face's set membership even though its
    // material/part came back. Exercises the REAL kernel
    // (`deleteFacesByMask`), not a hand-built `MeshOpEntry`.
    Mesh m = makeCube();
    m.syncSelection();

    m.selectFace(3);
    selSetEditPolygon(m, "S", SetEditMode.add, m.selectedFaces);
    assert(selSetMembersPolygon(m, "S") == [3u]);

    MeshEditTracker rec;
    m.beginEditBatch(&rec, MeshEditScope.Geometry);
    bool[] mask = new bool[](m.faces.length);
    mask[3] = true;
    const removed = m.deleteFacesByMask(mask);
    auto delta = m.endEditBatch();
    assert(removed == 1, "setup: exactly face 3 dropped");
    assert(m.faces.length == 5);
    assert(selSetMembersPolygon(m, "S").length == 0,
        "setup: the deleted face's own membership goes with it");

    assert(delta.revert(m), "undo must succeed");
    assert(m.faces.length == 6, "the deleted face must be re-inserted");
    assert(selSetMembersPolygon(m, "S") == [3u],
        "undo of a face delete must restore the face's OWN selection-set "
      ~ "membership, the same way it already restores material/part "
      ~ "(task 1060 review SHOULD-FIX 4)");
}

unittest { // test 8 — review SHOULD-FIX 5: selSetMembersEdge must be
           // ascending by key, not AA iteration order
    // `selSetMembersVertex`/`selSetMembersPolygon` walk a DENSE array in
    // index order, so their result is ascending by construction.
    // `selSetMembersEdge` walks `edgeSetMask`, an associative array whose
    // iteration order is unspecified and rehash-dependent — feeding both the
    // `.v3d` writer and `/api/model` straight off that walk meant
    // save→load→save was not byte-stable. Insert in DESCENDING key order: if
    // the walk is not explicitly sorted, the returned order tracks the AA's
    // own (unspecified) bucket order instead of ascending, and five distinct
    // keys make a coincidental ascending match implausible.
    Mesh m;
    m.edgeSetNames = ["S"];   // slot 0 -> bit 0
    m.edgeSetMask[edgeKey(9, 10)] = 1UL;
    m.edgeSetMask[edgeKey(7, 8)]  = 1UL;
    m.edgeSetMask[edgeKey(5, 6)]  = 1UL;
    m.edgeSetMask[edgeKey(3, 4)]  = 1UL;
    m.edgeSetMask[edgeKey(1, 2)]  = 1UL;

    auto members = selSetMembersEdge(m, "S");
    uint[2][] expected = [[1u,2u], [3u,4u], [5u,6u], [7u,8u], [9u,10u]];
    assert(members == expected,
        "selSetMembersEdge must return members ascending by key — "
      ~ "save/load/save stability and a byte comparison of a document with "
      ~ "edge sets both depend on it; got " ~ to!string(members));
}
