// mesh_edge_plane_carry_test — the gate for the per-EDGE plane carry inside
// `Mesh.rebuildEdges` (task 4059, `mesh_planes.kEdgePlanes` /
// `captureEdgePlanes` / `applyEdgePlanes`).
//
// THE LAW UNDER TEST, stated without reference to the implementation: an
// edge's marks belong to the EDGE — to the pair of vertices it joins — and
// not to the slot it happens to occupy in `edges`. `rebuildEdges` re-derives
// `edges` from `faces` in face/corner order, so that slot moves whenever the
// face order or a winding changes. Before this task nothing carried the
// marks across, and the tree's answer was 43 hand-written
// `clearEdgeSelectionResize()` / `resizeEdgeSelection()` calls: the selection
// survived a topology edit only where somebody remembered to throw it away.
// (43 is CALL EXPRESSIONS; the command and why a `grep | wc -l` answers 64
// instead are at `mesh_planes.d`'s "THE 43 IS CALL EXPRESSIONS".)
//
// THE RIG IS BUILT BEFORE ANYTHING IS DRIVEN, and that is the point of the
// first half of each block. An edge whose index does NOT move cannot
// separate a key carry from an index one — both answer "still selected" —
// so each block first asks a THROWAWAY copy of the same fixture which edge
// the operation actually renumbers, and asserts it found one. A hard-coded
// index would go quietly non-discriminating the day the factory changed.
//
// THE CARRY IS OPT-IN, and that is a MEASURED decision rather than caution:
// arming it for every `rebuildEdges` caller moves eight rows of the frozen
// undo-parity corpus, i.e. changes what a user sees selected after eight
// shipped operations. What those eight rows establish is exactly that — that
// arming the carry CHANGES observable behaviour — and no more: all eight are
// SELF-GENERATED from our own replay (`provenance.source == "simulated"`,
// `reference == "vibe3d-selfgen"`), so they are not evidence about the
// reference at all. Which edges an extrude or an inset should leave selected
// is a law we are matching and it is UNMEASURED; that capture is step 0 of
// task 4190. `mesh_planes.EdgePlaneCarry` carries the eight rows and the
// soundness boundary; task 4190 holds the per-op decision.
// So Block A asks for `EdgePlaneCarry.byKey` explicitly, and Blocks B and C
// drive `Mesh.spinEdge`, the one production caller that asks for it today.
//
// MUTATION (task 4059 `## Мутация`): delete the `applyEdgePlanes(this,
// edgeCarry);` line from `Mesh.rebuildEdges` — every block below reddens on
// its "still selected" assertion, naming the two indices.
module tests.unit.mesh_edge_plane_carry_test;

import mesh        : Mesh, makeCube, makeGridPlane;
import mesh_planes : EdgePlaneCarry;
import mesh_topo   : edgeKey;
import std.format  : format;

// ---------------------------------------------------------------------------
// Local helpers. Deliberately not shared with tests/unit/fixtures.d: this
// file's rig must stay readable on its own page, and `findEdge` there answers
// a different question (an index by endpoints, on ONE mesh) from the one asked
// here (has an edge's index MOVED between two states of the same mesh).
// ---------------------------------------------------------------------------

private ulong[] edgeKeysOf(ref Mesh m) {
    ulong[] ks;
    ks.reserve(m.edges.length);
    foreach (e; m.edges) ks ~= edgeKey(e[0], e[1]);
    return ks;
}

private long indexOfKey(in ulong[] ks, ulong k) {
    foreach (i, x; ks) if (x == k) return cast(long) i;
    return -1;
}

private uint[][] rotatedFaceOrder(ref Mesh m) {
    // Same faces, same undirected edge SET, a different DISCOVERY order — the
    // smallest edit that renumbers `edges` and changes nothing else, so a
    // failure here can only be the carry.
    return m.faces[1 .. $].dup ~ m.faces[0 .. 1].dup;
}

// ---------------------------------------------------------------------------
// Block A — `rebuildEdges` itself, over a pure renumbering.
// ---------------------------------------------------------------------------

unittest // an edge selected before a renumbering is still selected after it
{
    // --- the rig, before anything is driven ---------------------------------
    ulong movedKey = 0;
    long  fromIdx = -1, toIdx = -1;
    {
        Mesh probe = makeCube();
        probe.syncSelection();
        const beforeKeys = edgeKeysOf(probe);
        probe.faces = rotatedFaceOrder(probe);
        probe.rebuildEdges(EdgePlaneCarry.byKey);
        const afterKeys = edgeKeysOf(probe);
        foreach (i, k; beforeKeys) {
            const long j = indexOfKey(afterKeys, k);
            if (j >= 0 && j != cast(long) i) { movedKey = k; fromIdx = cast(long) i; toIdx = j; break; }
        }
    }
    assert(fromIdx >= 0,
           "the rig cannot discriminate: rotating the cube's face order "
         ~ "renumbered NO edge, so a carry BY INDEX would satisfy every "
         ~ "assertion below. Pick an edit that moves an edge before trusting "
         ~ "a green here.");

    // --- the run ------------------------------------------------------------
    Mesh m = makeCube();
    m.syncSelection();
    foreach (i; 0 .. m.edges.length) m.deselectEdge(cast(uint) i);
    m.selectEdge(cast(int) fromIdx);
    const int ordBefore = m.edgeSelectionOrder[cast(size_t) fromIdx];
    assert(ordBefore != 0,
           "fixture: the selected edge must carry a non-zero order stamp, or "
         ~ "the stamp assertion below asserts nothing");

    m.faces = rotatedFaceOrder(m);
    m.rebuildEdges(EdgePlaneCarry.byKey);

    const afterKeys = edgeKeysOf(m);
    const long now = indexOfKey(afterKeys, movedKey);
    assert(now == toIdx,
           format("fixture: the edge moved %d -> %d on the probe but %d -> %d "
                ~ "on the run; the two must be the same mesh",
                  fromIdx, toIdx, fromIdx, now));

    assert(m.isEdgeSelected(cast(int) now),
           format("the selected edge moved from index %d to index %d and lost "
                ~ "its Select bit — rebuildEdges is carrying the edge planes "
                ~ "by INDEX, or not at all", fromIdx, now));
    assert(m.edgeSelectionOrder[cast(size_t) now] == ordBefore,
           format("the edge came back selected but with order stamp %d instead "
                ~ "of %d — `edgeSelectionOrder` is in kEdgePlanes and must ride "
                ~ "with `edgeMarks`",
                  m.edgeSelectionOrder[cast(size_t) now], ordBefore));

    // Exactly ONE edge selected: a carry that smeared the bit over the array
    // would satisfy both assertions above.
    size_t selCount = 0;
    foreach (i; 0 .. m.edges.length) if (m.isEdgeSelected(cast(int) i)) ++selCount;
    assert(selCount == 1,
           format("%d edges are selected after the rebuild, expected exactly 1",
                  selCount));

    // The length invariant the `byKey` arm also holds: the `leaveIndexed`
    // default (and every call site before task 4059) leaves these at the
    // PREVIOUS edge count and lets the caller's `resizeEdgeSelection()` fix
    // it up.
    assert(m.edgeMarks.length == m.edges.length,
           format("edgeMarks is %d against %d edges", m.edgeMarks.length, m.edges.length));
    assert(m.edgeSelectionOrder.length == m.edges.length,
           format("edgeSelectionOrder is %d against %d edges",
                  m.edgeSelectionOrder.length, m.edges.length));
}

// ---------------------------------------------------------------------------
// Block B — a real operation. `Mesh.spinEdge` rewrites two windings and calls
// `rebuildEdges()`, and it is one of the paths that does NOT clear the edge
// selection afterwards, so it exercises the carry end to end rather than the
// primitive in isolation.
// ---------------------------------------------------------------------------

private int interiorEdge(ref Mesh m) {
    foreach (i, e; m.edges) {
        int n = 0;
        foreach (f; m.faces)
            foreach (k; 0 .. f.length)
                if ((f[k] == e[0] && f[(k + 1) % f.length] == e[1])
                 || (f[k] == e[1] && f[(k + 1) % f.length] == e[0])) ++n;
        if (n == 2) return cast(int) i;
    }
    return -1;
}

unittest // a spin renumbers the edge array and the selection follows the endpoints
{
    // --- the rig ------------------------------------------------------------
    ulong movedKey = 0;
    long  fromIdx = -1, toIdx = -1;
    int   spinIdx = -1;
    {
        Mesh probe = makeGridPlane(3);
        probe.buildLoops();
        probe.syncSelection();
        spinIdx = interiorEdge(probe);
        assert(spinIdx >= 0, "fixture: the grid must have an edge shared by two faces");
        const beforeKeys = edgeKeysOf(probe);
        uint[2] product;
        assert(probe.spinEdge(cast(uint) spinIdx, product),
               "fixture: the spin must apply, or this block measures nothing");
        const afterKeys = edgeKeysOf(probe);
        foreach (i, k; beforeKeys) {
            if (cast(long) i == spinIdx) continue;      // the spun edge is GONE by design
            const long j = indexOfKey(afterKeys, k);
            if (j >= 0 && j != cast(long) i) { movedKey = k; fromIdx = cast(long) i; toIdx = j; break; }
        }
    }
    assert(fromIdx >= 0,
           "the rig cannot discriminate: the spin renumbered no SURVIVING edge, "
         ~ "so a carry by index would pass. Choose a different op or a bigger "
         ~ "grid before trusting a green here.");

    // --- the run ------------------------------------------------------------
    Mesh m = makeGridPlane(3);
    m.buildLoops();
    m.syncSelection();
    foreach (i; 0 .. m.edges.length) m.deselectEdge(cast(uint) i);
    m.selectEdge(cast(int) fromIdx);

    uint[2] product;
    assert(m.spinEdge(cast(uint) spinIdx, product), "the spin must apply");

    const afterKeys = edgeKeysOf(m);
    const long now = indexOfKey(afterKeys, movedKey);
    assert(now == toIdx,
           format("fixture: probe and run disagree about where the edge went "
                ~ "(%d vs %d)", toIdx, now));
    assert(m.isEdgeSelected(cast(int) now),
           format("after mesh.spinEdge the selected edge moved from index %d to "
                ~ "index %d and is no longer selected — the edge planes did not "
                ~ "survive the rebuild", fromIdx, now));

    size_t selCount = 0;
    foreach (i; 0 .. m.edges.length) if (m.isEdgeSelected(cast(int) i)) ++selCount;
    assert(selCount == 1,
           format("%d edges selected after the spin, expected exactly 1", selCount));
}

// ---------------------------------------------------------------------------
// Block C — an edge the rebuild DROPS must not leave its marks on whatever
// edge inherits its slot. This is the half a "still selected" assertion
// cannot see: carrying too much is as wrong as carrying too little, and a
// stale SET Hide bit at a live index is the failure `rebuildEdges`'s own
// comment describes ("makes selectEdge refuse silently and permanently").
// ---------------------------------------------------------------------------

unittest // a dropped edge's marks do not land on the edge that takes its slot
{
    Mesh m = makeGridPlane(3);
    m.buildLoops();
    m.syncSelection();

    const int spun = interiorEdge(m);
    assert(spun >= 0, "fixture: the grid must have an interior edge");
    const ulong goneKey = edgeKey(m.edges[spun][0], m.edges[spun][1]);

    foreach (i; 0 .. m.edges.length) m.deselectEdge(cast(uint) i);
    m.selectEdge(spun);
    assert(m.isEdgeSelected(spun), "fixture: the edge to be destroyed must start selected");

    uint[2] product;
    assert(m.spinEdge(cast(uint) spun, product), "the spin must apply");

    assert(indexOfKey(edgeKeysOf(m), goneKey) < 0,
           "fixture: the spun edge must be GONE from the rebuilt array, or this "
         ~ "block is not about a dropped edge at all");

    size_t selCount = 0;
    foreach (i; 0 .. m.edges.length) if (m.isEdgeSelected(cast(int) i)) ++selCount;
    assert(selCount == 0,
           format("%d edge(s) are selected after the only selected edge was "
                ~ "destroyed — a dropped edge's marks were inherited by "
                ~ "whatever now occupies index %d", selCount, spun));
}
