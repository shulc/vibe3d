// l2_create_stable_delta_test — task 1903 Stage L2-c … L2-h.
//
// The ten commands stage L2 had left on the whole-mesh `MeshSnapshot` after
// L2-a/L2-b took `flip`, `fixOrientation` and `spinEdge`:
//
//   L2-c  mesh.addPoint      mesh.split_edge     (the corner SPLICE)
//   L2-d  mesh.splitFace                          (the face REINDEX)
//   L2-e  mesh.vertexSplit                        (the corner REPOINT)
//   L2-f  mesh.spikey                             (the in-place fan install)
//   L2-g  mesh.addVertex     mesh.makePolygon     (kernels that already log)
//   L2-h  mesh.thicken       mesh.align           (the two `SetPos` rows)
//
// WHAT EACH CELL MUST BE ABLE TO SEE, because the failure shapes differ by
// group and a single style of assertion covers none of them:
//
//   * the SPLICE and the REPOINT fail LOUDLY when unrecorded — the reverse
//     truncates a vertex that surviving windings still name and `finalize`
//     THROWS out of `buildLoops`. Those cells assert the ABSENCE of the throw
//     explicitly, plus the winding, because "it did not throw" is also true of
//     a revert that did nothing;
//   * `splitFace` fails SILENTLY: its pre-migration op-log was EMPTY, so
//     `revert()` answered `true` with the split still in. A face COUNT is not
//     enough there — §5.3 says so — so the cell asserts the winding of the
//     parent slot as well;
//   * `thicken`'s symmetric arm fails INVISIBLY on the default parameter. Its
//     cell asserts `symmetric` is true BEFORE it asserts anything else;
//   * every op-log assertion below reads the KIND SEQUENCE, never the length:
//     a length is satisfied by a log with an entry interposed, and since Stage
//     J the `[MeshMapDelta, <face entry>]` ADJACENCY is contractual
//     (`CornerCarry.payloadForCount`), so an unpaired payload zeroes a
//     per-corner map SILENTLY while the geometry round-trips.
//
// LANE: `dub test --config=tests` (lane U). `./run_test.d` links the prebuilt
// library and never executes a `tests/unit/**` unittest block.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — when scoring a
// mutation that should redden two cells for two reasons, stub the earlier one.
module tests.unit.l2_create_stable_delta_test;

import std.conv   : to;
import std.format : format;

import mesh;
import mesh_edit_delta;
import view;
import editmode;
import command;
import command_history : CommandHistory;

import commands.mesh.add_point     : MeshAddPoint;
import commands.mesh.split_edge    : MeshSplitEdge;
import commands.mesh.split_face    : MeshSplitFace;
import commands.mesh.vertex_split  : MeshVertexSplit;
import commands.mesh.spikey        : MeshSpikey;
import commands.mesh.vertex_new    : MeshVertexNew;
import commands.mesh.make_polygon  : MeshMakePolygon;
import commands.mesh.thicken       : MeshThicken;
import commands.mesh.polygon_align : MeshAlign;
import math : Vec3;
import params : Param;

import tests.unit.fixtures : makeTaggedGridBent, findEdge;

// ---------------------------------------------------------------------------
// Shared helpers.
// ---------------------------------------------------------------------------

private Mesh stand()
{
    auto m = makeTaggedGridBent(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private float[] uvOf(ref Mesh m)
{
    auto u = m.meshMap(kUvMapName);
    assert(u !is null, "the stand lost its PolyVertex map");
    return u.data.dup;
}

private uint[][] windingsOf(ref Mesh m)
{
    auto r = new uint[][](m.faces.length);
    foreach (fi; 0 .. m.faces.length) r[fi] = m.faces[fi].dup;
    return r;
}

/// The op-log's KIND SEQUENCE, as text. Never the LENGTH — see the header.
private string kindsOf(in MeshEditDelta d)
{
    string s;
    foreach (i, ref e; d.log) s ~= (i ? " " : "") ~ e.kind.to!string;
    return s;
}

/// A compact image of every selection plane the frozen oracle compares, so a
/// cell can say "the selection came back" in one assertion and NAME what
/// differs. Bits AND stamps AND counters: L2-b measured that a restore which
/// puts the bit back and mints a fresh stamp restores LESS than the snapshot.
private string selImage(ref Mesh m)
{
    string s = "V[";
    foreach (i; 0 .. m.vertices.length)
        s ~= format("%d:%d ", m.isVertexSelected(i) ? 1 : 0,
                    i < m.vertexSelectionOrder.length ? m.vertexSelectionOrder[i] : 0);
    // THE EDGE HALF IS KEYED BY NORMALISED ENDPOINTS AND SORTED, not read in
    // array order, and that is a correction this cell earned rather than a
    // stylistic choice. `edges` is DERIVED from `faces` by `rebuildEdges`, and
    // the stand carries one deliberately backwards-wound face (addition 1 of
    // `makeTaggedGridBent`) that was reversed AFTER its edges were first
    // built — so the stand's own `edges` array is stale with respect to its
    // windings, and the FORWARD's `rebuildEdges` re-derives three of face 2's
    // edges with their endpoints the other way round. That is a pre-existing
    // property of the stand, identical on the snapshot and the delta path
    // (both re-derive), and it is not a selection difference: the SELECTED
    // edge kept its index, its bit and its stamp through it. Reading the array
    // order here would report the stand's staleness as a migration defect.
    import std.algorithm.sorting : sort;
    string[] es;
    foreach (i; 0 .. m.edges.length) {
        immutable uint a = m.edges[i][0], b = m.edges[i][1];
        es ~= format("%d-%d:%d:%d ", a < b ? a : b, a < b ? b : a,
                     m.isEdgeSelected(i) ? 1 : 0,
                     i < m.edgeSelectionOrder.length ? m.edgeSelectionOrder[i] : 0);
    }
    es.sort();
    s ~= "] E[";
    foreach (e; es) s ~= e;
    s ~= "] F[";
    foreach (i; 0 .. m.faces.length)
        s ~= format("%d:%d ", m.isFaceSelected(i) ? 1 : 0,
                    i < m.faceSelectionOrder.length ? m.faceSelectionOrder[i] : 0);
    s ~= format("] c=%d,%d,%d", m.vertexSelectionOrderCounter,
                m.edgeSelectionOrderCounter, m.faceSelectionOrderCounter);
    return s;
}

/// Write one `int` param by name, the way the parity reader's `setI` does.
/// The params are the command's own schema and a typo would silently leave the
/// default in place, so the lookup ASSERTS rather than shrugging.
private void setInt(Command c, string name, int v)
{
    foreach (p; c.params())
        if (p.name == name && p.kind == Param.Kind.Int) { *p.iptr = v; return; }
    assert(false, "no int param named '" ~ name ~ "' on " ~ c.name());
}

private void setFloat(Command c, string name, float v)
{
    foreach (p; c.params())
        if (p.name == name && p.kind == Param.Kind.Float) { *p.fptr = v; return; }
    assert(false, "no float param named '" ~ name ~ "' on " ~ c.name());
}

private void setBool(Command c, string name, bool v)
{
    foreach (p; c.params())
        if (p.name == name && p.kind == Param.Kind.Bool) { *p.bptr = v; return; }
    assert(false, "no bool param named '" ~ name ~ "' on " ~ c.name());
}

/// Read a bool param back OUT of the command. The point is the H1 cell: a
/// `setBool` that silently missed (a renamed param) would leave the default in
/// place, and the whole cell would then measure `symmetric:false`.
private bool paramBool(Command c, string name)
{
    foreach (p; c.params())
        if (p.name == name && p.kind == Param.Kind.Bool) return *p.bptr;
    assert(false, "no bool param named '" ~ name ~ "' on " ~ c.name());
}

private uint interiorEdge(ref Mesh m)
{
    immutable int ei = findEdge(m, 5, 6);
    assert(ei >= 0, "the stand has no edge 5-6 — makeGridPlane's vertex "
                  ~ "numbering changed and every edge cell picks at random");
    return cast(uint) ei;
}

private void selectOnlyInteriorEdge(ref Mesh m)
{
    immutable uint ei = interiorEdge(m);
    foreach (i; 0 .. m.edges.length) m.deselectEdge(cast(uint) i);
    m.selectEdge(ei);
}

// ===========================================================================
// L2-c — `mesh.addPoint` + `mesh.split_edge`: the corner SPLICE.
// ===========================================================================

// ---------------------------------------------------------------------------
// C1 — the splice at the KERNEL: the op-log shape, and a revert that neither
// throws nor leaves the splice in.
//
// The pre-L2-c state is `[AddVerts]` with the splices unrecorded, and its
// revert does NOT answer false and does NOT quietly do nothing — it truncates
// the new vertex while every incident winding still names it, and `finalize`
// →`buildLoops` raises `ArrayIndexError`. So this cell asserts the absence of
// the throw by NAME, because a bare `d.revert(m)` in a cell with no assertion
// about it would report the throw as a module crash rather than as a finding.
//
// MUTATION: delete the `cast(void) setFaceWindings(idx, newWind);` in
// `Mesh.insertEdgePoint`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    const pre    = windingsOf(m);
    const preUv  = uvOf(m);
    const preV   = m.vertices.length;
    immutable uint ei = interiorEdge(m);

    // Which faces the splice is about to touch, read BEFORE the mutation: the
    // claim "the windings came back" is vacuous if the splice touched none.
    size_t incident = 0;
    foreach (f; m.facesAroundEdge(ei)) ++incident;
    assert(incident == 2,
        format("C1: edge 5-6 has %d incident face(s), expected 2 — the "
             ~ "splice would touch %d winding(s) and this cell would assert "
             ~ "almost nothing", incident, incident));

    MeshEditDelta d;
    uint vi;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);   // RECORDING
        vi = ed.mesh.addEdgePoint(ei, 0.35f);
        d = ed.close();
    }
    assert(vi != uint.max, "C1: the kernel refused — every claim below is "
                         ~ "vacuous on a forward that did nothing");
    assert(m.vertices.length == preV + 1,
        "C1: the forward did not append the split vertex");

    assert(kindsOf(d) == "AddVerts MeshMapDelta ReshapeFaces",
        format("C1: op-log kinds are [%s], expected [AddVerts MeshMapDelta "
             ~ "ReshapeFaces]. [AddVerts] ALONE is the pre-L2-c state, in "
             ~ "which the reverse truncates the new vertex while the spliced "
             ~ "windings still name it and `finalize` THROWS", kindsOf(d)));

    // The absence of the throw, said out loud.
    bool threw = false;
    try { assert(d.revert(m), "C1: revert() refused the delta outright"); }
    catch (Throwable t) { threw = true; }
    assert(!threw,
        "C1: reverting the splice THREW out of finalize->buildLoops — the "
      ~ "unrecorded-splice shape: the vertex was truncated and the windings "
      ~ "still named it");

    assert(m.vertices.length == preV,
        format("C1: %d vertices after the revert, expected the pre-op %d",
               m.vertices.length, preV));
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("C1: face %d came back as %s, expected its pre-op winding "
                 ~ "%s — a ReshapeFaces that restored the count and not the "
                 ~ "winding lands exactly here", fi, m.faces[fi].to!string,
                   pre[fi].to!string));
    assert(uvOf(m) == preUv,
        "C1: the per-corner plane did not come back — the splice changes the "
      ~ "mesh's TOTAL corner count, so every corner after it renumbers and a "
      ~ "reverse with no payload re-derives them slot-for-slot");
}

// ---------------------------------------------------------------------------
// C2 — `mesh.split_edge` through the REAL undo stack: the topology comes back
// from the delta and the SELECTION comes back from the dense image beside it.
//
// The step count is asserted because a witness in an earlier group of this task
// was inert twice: its undo went through a command id that does not exist and
// ten "undos" were ten silent no-ops. `CommandHistory.undoEpoch` moves once per
// SUCCESSFUL undo and by nothing else.
//
// MUTATION 1: `MeshSplitEdge.revert`'s `if (undo_.armed()) preSel_.restore(...)`
//             -> `if (false)`.
// MUTATION 2: delete the `setFaceWindings` call in `Mesh.insertEdgePoint`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    selectOnlyInteriorEdge(m);
    m.selectFace(7);                 // a second domain, so the "all three
    m.selectVertex(2);               // domains" claim is not about edges alone

    const pre     = windingsOf(m);
    const preUv   = uvOf(m);
    const preSel  = selImage(m);
    const preV    = m.vertices.length;
    const preSetM = m.vertexSetMask.length;

    auto hist = new CommandHistory();
    auto c = new MeshSplitEdge(&m, v, EditMode.Edges);
    assert(c.apply(), "C2: mesh.split_edge must apply on this stand");
    assert(m.vertices.length == preV + 1, "C2: the forward added no vertex");
    assert(!m.hasAnySelectedEdges() && !m.hasAnySelectedFaces()
           && !m.hasAnySelectedVertices(),
        "C2: the forward is supposed to RESET the selection — if it no longer "
      ~ "does, the restore below is asserting that nothing happened");
    assert(c.isOperationInverse(),
        "C2: the command reports a snapshot undo — it is meant to be on the "
      ~ "delta path here (the tracker hatch is off by default)");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "C2: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("C2: %d undo step(s) actually took effect, expected exactly 1",
               hist.undoEpoch() - epoch0));

    assert(m.vertices.length == preV,
        format("C2: %d vertices after the undo, expected %d",
               m.vertices.length, preV));
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("C2: face %d did not come back through the history undo", fi));
    assert(uvOf(m) == preUv, "C2: the per-corner plane did not come back");
    assert(selImage(m) == preSel,
        format("C2: the pre-op SELECTION did not come back.\n  before: %s\n"
             ~ "  after : %s\n  `resetSelection()` clears all three domains "
             ~ "and no op-log kind carries a selection-order stamp, so this "
             ~ "plane is the command's own dense image", preSel, selImage(m)));

    // The length sync the frozen oracle found, asserted here as well so the
    // finding is executable outside the fixture. `selSetMembersVertex` walks
    // the MASK, not `m.vertices`, so an over-long mask puts an out-of-range
    // vertex id into `/api/model` and the `.v3d` writer, and the loader's own
    // bounds guard then drops the WHOLE named set on reload.
    assert(m.vertexSetMask.length == m.vertices.length,
        format("C2: vertexSetMask is %d long over %d vertices (pre-op %d) — "
             ~ "MeshEditDelta.finalize's blanket length sync is missing this "
             ~ "plane", m.vertexSetMask.length, m.vertices.length, preSetM));
}

// ===========================================================================
// L2-d — `mesh.splitFace`: the face REINDEX.
// ===========================================================================

// ---------------------------------------------------------------------------
// D1 — the chord split at the KERNEL.
//
// THE TWO ASSERTIONS ON THE LOG ARE A PAIR AND NEITHER IS SPARE. `FaceReindex`
// == 1 says the rewrite is recorded at all; `ReshapeFaces` == 0 says it is
// recorded ONCE. §5.3's measured hazard for an armed rewrite is the DOUBLE
// description — an op whose face change is published both by the primitive and
// by a second, hand-rolled entry, whose LIFO revert then overshoots its own
// starting state (`unifyFaces` landed on F=3 against a pre-op F=2). A single
// `> 0` assertion on the reindex cannot see that.
//
// AND THE THREE PLANES ARE ASSERTED BY NAME. `faceMaterial`, `facePart` and
// `faceSetMask` have no restorer outside `Kind.RemoveFaces`, so the cheaper
// `AddFaces + ReshapeFaces` route would return them SHIFTED BY ONE — every
// count right, every winding right, and every material on the wrong face.
//
// MUTATION 1: drop the `auto arm = faceReindexScope();` (leave the
//             `rewriteFaces` call) -> the log carries no FaceReindex.
// MUTATION 2: put `faces._store = newFacesArr;` back in front of the
//             `rewriteFaces` call -> the forward still works and the revert
//             restores the count over a mesh whose planes never moved.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    const preFaces = windingsOf(m);
    const preUv    = uvOf(m);
    const preMat   = m.faceMaterial.dup;
    const prePart  = m.facePart.dup;
    const preSetM  = m.faceSetMask.dup;
    const preF     = m.faces.length;

    // Face 4 is the interior quad [5, 6, 10, 9]; 5 and 10 are its diagonal.
    // NON-ADJACENT is the whole precondition — an adjacent pair is refused.
    assert(m.faces[4] == [5u, 6u, 10u, 9u],
        format("D1: face 4 is %s, expected the interior quad [5,6,10,9] — the "
             ~ "chord below would name a random pair", m.faces[4].to!string));
    // The three planes must be NON-UNIFORM across the split point, or a
    // shift-by-one restores the same values and the cell cannot see it.
    assert(preMat[4] != preMat[5] || prePart[4] != prePart[5]
           || preSetM[4] != preSetM[5],
        "D1: faces 4 and 5 carry identical material/part/set-mask — a "
      ~ "restore that shifts the whole plane by one would be INVISIBLE here");

    MeshEditDelta d;
    size_t n;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);   // RECORDING
        n = ed.mesh.splitFaceByVertices(4, 5, 10);
        d = ed.close();
    }
    assert(n == 1, format("D1: the kernel split %d face(s), expected 1", n));
    assert(m.faces.length == preF + 1, "D1: the forward emitted no extra face");

    size_t nReindex = 0, nReshape = 0;
    foreach (ref e; d.log) {
        if (e.kind == MeshOpEntry.Kind.FaceReindex)   ++nReindex;
        if (e.kind == MeshOpEntry.Kind.ReshapeFaces)  ++nReshape;
    }
    assert(nReindex == 1,
        format("D1: op-log kinds are [%s] — expected exactly ONE FaceReindex. "
             ~ "An EMPTY log is the pre-L2-d state, in which revert() answers "
             ~ "true and the split stays in", kindsOf(d)));
    assert(nReshape == 0,
        format("D1: op-log kinds are [%s] — the face change is described "
             ~ "TWICE. A LIFO revert then re-applies it twice and overshoots "
             ~ "the pre-op state (§5.3's `unifyFaces` measurement: F=3 against "
             ~ "a pre-op F=2)", kindsOf(d)));

    assert(d.revert(m), "D1: revert() refused the delta outright");
    assert(m.faces.length == preF,
        format("D1: %d faces after the revert, expected the pre-op %d",
               m.faces.length, preF));
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == preFaces[fi],
            format("D1: face %d came back as %s, expected %s — a count-only "
                 ~ "assertion is green on this failure", fi,
                   m.faces[fi].to!string, preFaces[fi].to!string));
    assert(m.faceMaterial == preMat,
        format("D1: faceMaterial came back as %s, expected %s — the plane is "
             ~ "SHIFTED, which is what a route without FaceReindex produces",
               m.faceMaterial.to!string, preMat.to!string));
    assert(m.facePart == prePart, "D1: facePart did not come back");
    assert(m.faceSetMask == preSetM,
        format("D1: faceSetMask came back as %s, expected %s",
               m.faceSetMask.to!string, preSetM.to!string));
    assert(uvOf(m) == preUv, "D1: the per-corner plane did not come back");
}

// ---------------------------------------------------------------------------
// D2 — `mesh.splitFace` through the REAL undo stack, with the selection.
//
// MUTATION: `MeshSplitFace.revert`'s `if (undo_.armed()) preSel_.restore(...)`
//           -> `if (false)`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    m.selectFace(4);                 // the face about to be split, so
    m.selectFace(6);                 // `dropConsumedFaces` has something to drop

    const preFaces = windingsOf(m);
    const preSel   = selImage(m);
    const preF     = m.faces.length;

    auto hist = new CommandHistory();
    auto c = new MeshSplitFace(&m, v, EditMode.Vertices);
    setInt(c, "face", 4); setInt(c, "a", 5); setInt(c, "b", 10);
    assert(c.apply(), "D2: mesh.splitFace must apply on this stand");
    assert(m.faces.length == preF + 1, "D2: the forward split nothing");
    assert(!m.isFaceSelected(4) && !m.isFaceSelected(5),
        "D2: the forward is supposed to DROP the two halves' Select bits — if "
      ~ "it no longer does, the restore below asserts that nothing happened");
    assert(c.isOperationInverse(),
        "D2: the command reports a snapshot undo — it is meant to be on the "
      ~ "delta path here");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "D2: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("D2: %d undo step(s) actually took effect, expected exactly 1",
               hist.undoEpoch() - epoch0));

    assert(m.faces.length == preF, "D2: the face count did not come back");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == preFaces[fi],
            format("D2: face %d did not come back through the history undo", fi));
    assert(selImage(m) == preSel,
        format("D2: the pre-op SELECTION did not come back.\n  before: %s\n"
             ~ "  after : %s", preSel, selImage(m)));
}

// ===========================================================================
// L2-e — `mesh.vertexSplit`: the corner REPOINT.
// ===========================================================================

// ---------------------------------------------------------------------------
// E1 — the unweld at the KERNEL.
//
// The repoint is neither a permutation (L2-a) nor a splice (L2-c): the corner
// keeps its slot AND its arity and changes its VALUE to a newly-appended
// vertex. Unrecorded, the reverse truncates those copies while the surviving
// windings still name them, so this cell asserts the absence of the throw by
// name and then the winding, because "it did not throw" is also true of a
// revert that did nothing.
//
// THE POINT-DOMAIN MAP IS ASSERTED SEPARATELY, and that half is Q-L2-3 made
// executable: the kernel copies weight values onto the appended vertices by
// writing `MeshMap.data` directly, and the claim is that the reverse needs no
// payload for them because `resizeAllMeshMaps` shrinks the array with the
// vertices. A LENGTH assertion alone would be green over a shrink that kept
// the wrong values, so the VALUES are compared too.
//
// MUTATION: delete the `cast(void) setFaceWindings(idx, newWind);` in
// `Mesh.splitVerticesByMask`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    const pre   = windingsOf(m);
    const preV  = m.vertices.length;
    const preUv = uvOf(m);

    auto wm0 = m.meshMap("W");
    assert(wm0 !is null && wm0.domain == MapDomain.Point,
        "E1: the stand must carry the Point-domain map 'W' — without it the "
      ~ "Q-L2-3 half of this cell is vacuous");
    const preW = wm0.data.dup;

    // Vertex 5 is interior: four incident faces, so the split repoints corners
    // on MORE THAN ONE face. A boundary vertex would exercise one repoint and
    // the "every touched winding came back" claim would be about a single face.
    bool[] sel = new bool[](m.vertices.length);
    sel[5] = true;
    size_t incident = 0;
    foreach (fi; 0 .. m.faces.length)
        foreach (v; m.faces[fi]) if (v == 5) { ++incident; break; }
    assert(incident == 4,
        format("E1: vertex 5 is incident to %d face(s), expected the 4 an "
             ~ "interior grid vertex has — fewer means the repoint touches "
             ~ "fewer windings than this cell claims to check", incident));

    MeshEditDelta d;
    size_t copies;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Geometry);   // RECORDING
        copies = ed.mesh.splitVerticesByMask(sel);
        d = ed.close();
    }
    assert(copies == 3,
        format("E1: the kernel made %d copies, expected 3 (four incident "
             ~ "faces, the lowest-indexed one keeps the original)", copies));
    assert(m.vertices.length == preV + 3, "E1: the forward appended no copies");

    assert(kindsOf(d) == "AddVerts MeshMapDelta ReshapeFaces",
        format("E1: op-log kinds are [%s], expected [AddVerts MeshMapDelta "
             ~ "ReshapeFaces]. [AddVerts] ALONE is the pre-L2-e state, in "
             ~ "which the reverse truncates the copies while three windings "
             ~ "still name them and `finalize` THROWS", kindsOf(d)));

    bool threw = false;
    try { assert(d.revert(m), "E1: revert() refused the delta outright"); }
    catch (Throwable t) { threw = true; }
    assert(!threw,
        "E1: reverting the unweld THREW out of finalize->buildLoops — the "
      ~ "unrecorded-repoint shape");

    assert(m.vertices.length == preV,
        format("E1: %d vertices after the revert, expected %d",
               m.vertices.length, preV));
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("E1: face %d came back as %s, expected %s — every corner "
                 ~ "the split repointed must name vertex 5 again", fi,
                   m.faces[fi].to!string, pre[fi].to!string));

    // Q-L2-3: the Point-map rows go with the vertices, VALUES and all.
    auto wm1 = m.meshMap("W");
    assert(wm1 !is null && wm1.data == preW,
        format("E1: the Point-domain map came back as %s, expected %s — the "
             ~ "copies' rows are appended, so `resizeAllMeshMaps` removes "
             ~ "them on the shrink and no `Kind.MapValueDelta` payload is "
             ~ "owed", wm1 is null ? "<gone>" : wm1.data.to!string,
               preW.to!string));
    assert(uvOf(m) == preUv, "E1: the per-corner plane did not come back");
}

// ---------------------------------------------------------------------------
// E2 — `mesh.vertexSplit` through the REAL undo stack, with the selection.
//
// MUTATION: `MeshVertexSplit.revert`'s `if (undo_.armed()) preSel_.restore(...)`
//           -> `if (false)`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    foreach (i; 0 .. m.vertices.length) m.deselectVertex(cast(uint) i);
    m.selectVertex(5);
    m.selectFace(7);                 // a second domain — `repointToNothing`
                                     // clears all three, not just vertices

    const pre    = windingsOf(m);
    const preSel = selImage(m);
    const preV   = m.vertices.length;

    auto hist = new CommandHistory();
    auto c = new MeshVertexSplit(&m, v, EditMode.Vertices);
    assert(c.apply(), "E2: mesh.vertexSplit must apply on this stand");
    assert(m.vertices.length == preV + 3, "E2: the forward unwelded nothing");
    assert(!m.hasAnySelectedVertices() && !m.hasAnySelectedFaces(),
        "E2: `repointToNothing` is supposed to clear ALL THREE domains — if "
      ~ "it no longer does, the restore below asserts that nothing happened");
    assert(c.isOperationInverse(),
        "E2: the command reports a snapshot undo — it is meant to be on the "
      ~ "delta path here");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "E2: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("E2: %d undo step(s) actually took effect, expected exactly 1",
               hist.undoEpoch() - epoch0));

    assert(m.vertices.length == preV, "E2: the vertex count did not come back");
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("E2: face %d did not come back through the history undo", fi));
    assert(selImage(m) == preSel,
        format("E2: the pre-op SELECTION did not come back.\n  before: %s\n"
             ~ "  after : %s", preSel, selImage(m)));
}

// ===========================================================================
// L2-f — `mesh.spikey`: the in-place fan install, through the COMMAND.
//
// The kernel half is pinned elsewhere and deliberately so: the four op-log
// cells in `tests/unit/mesh_ops/poly_bevel_test.d` (whose spike row L2-f
// inverted from `ReshapeFaces == 0` to `== 1` and which now CALLS `revert()`),
// and `tests/test_poly_bevel_seam_counters.d` in the SUITE lane, which is the
// only row in either lane that sees this command's own constructor. What is
// here is the half neither of those covers: the selection.
// ===========================================================================

// ---------------------------------------------------------------------------
// F1 — spikey through the REAL undo stack.
//
// MUTATION: `MeshSpikey.revert`'s `if (undo_.armed()) preSel_.restore(...)`
//           -> `if (false)`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    foreach (i; 0 .. m.faces.length) m.deselectFace(cast(uint) i);
    m.selectFace(4);                 // one face; an empty selection would spike
                                     // the whole mesh and drown the assertion
    const pre     = windingsOf(m);
    const preSel  = selImage(m);
    const preV    = m.vertices.length;
    const preF    = m.faces.length;

    auto hist = new CommandHistory();
    auto c = new MeshSpikey(&m, v, EditMode.Polygons);
    setFloat(c, "amount", 0.4f);
    assert(c.apply(), "F1: mesh.spikey must apply on this stand");
    assert(m.vertices.length == preV + 1 && m.faces.length == preF + 3,
        format("F1: the forward left V=%d F=%d, expected %d/%d (one apex, one "
             ~ "quad becomes four fan triangles)", m.vertices.length,
               m.faces.length, preV + 1, preF + 3));
    assert(m.isFaceSelected(cast(uint)(preF)),
        "F1: the kernel is supposed to SELECT its appended fan triangles — if "
      ~ "it no longer does, the restore below asserts that nothing happened");
    assert(c.isOperationInverse(),
        "F1: the command reports a snapshot undo — it is meant to be on the "
      ~ "delta path here");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "F1: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("F1: %d undo step(s) actually took effect, expected exactly 1",
               hist.undoEpoch() - epoch0));

    assert(m.vertices.length == preV && m.faces.length == preF,
        format("F1: the undo left V=%d F=%d, expected the pre-op %d/%d",
               m.vertices.length, m.faces.length, preV, preF));
    foreach (fi; 0 .. m.faces.length)
        assert(m.faces[fi] == pre[fi],
            format("F1: face %d came back as %s, expected %s — face 4 is the "
                 ~ "PARENT SLOT the fan replaced, and it is the one publisher "
                 ~ "P7 restores", fi, m.faces[fi].to!string, pre[fi].to!string));
    assert(selImage(m) == preSel,
        format("F1: the pre-op SELECTION did not come back.\n  before: %s\n"
             ~ "  after : %s", preSel, selImage(m)));
}

// ===========================================================================
// L2-g — `mesh.addVertex` + `mesh.makePolygon`: the kernels that already log.
//
// Neither needed a publisher, so neither cell below asserts a NEW kind. What
// they assert is the half the op-log has never carried: the selection these
// two destroy. A cell that only read the op-log would be green over both
// migrations on the day they were written and green over a revert of the
// selection image forever after.
// ===========================================================================

// ---------------------------------------------------------------------------
// G1 — `mesh.addVertex`.
//
// MUTATION: `MeshVertexNew.revert`'s `if (undo_.armed()) preSel_.restore(...)`
//           -> `if (false)`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    const preSel = selImage(m);
    const preV   = m.vertices.length;
    assert(m.hasAnySelectedVertices(),
        "G1: the stand must arrive with a vertex selection — `addVertex` "
      ~ "CLEARS it, and with nothing to clear this cell asserts nothing");

    auto hist = new CommandHistory();
    auto c = new MeshVertexNew(&m, v, EditMode.Vertices);
    c.setPos(Vec3(0.73f, 0.91f, -0.37f));
    assert(c.apply(), "G1: mesh.addVertex must apply");
    assert(m.vertices.length == preV + 1, "G1: no vertex was appended");
    assert(c.isOperationInverse(), "G1: the command is not on the delta path");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "G1: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("G1: %d undo step(s) took effect, expected 1",
               hist.undoEpoch() - epoch0));
    assert(m.vertices.length == preV, "G1: the vertex was not truncated");
    assert(selImage(m) == preSel,
        format("G1: the pre-op SELECTION did not come back — `addVertex` "
             ~ "clears the vertex layer and selects its product, and the "
             ~ "op-log carries no selection.\n  before: %s\n  after : %s",
               preSel, selImage(m)));
}

// ---------------------------------------------------------------------------
// G2 — `mesh.makePolygon`.
//
// MUTATION: `MeshMakePolygon.revert`'s
//           `if (undo_.armed()) preSel_.restore(...)` -> `if (false)`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    foreach (i; 0 .. m.vertices.length) m.deselectVertex(cast(uint) i);
    foreach (vi; [0u, 1u, 2u, 3u]) m.selectVertex(vi);
    const preSel = selImage(m);
    const preF   = m.faces.length;

    auto hist = new CommandHistory();
    auto c = new MeshMakePolygon(&m, v, EditMode.Vertices);
    assert(c.apply(), "G2: mesh.makePolygon must apply on this stand");
    assert(m.faces.length == preF + 1, "G2: no face was appended");
    assert(!m.hasAnySelectedVertices() && m.hasAnySelectedFaces(),
        "G2: the forward is supposed to re-point at the PRODUCT — if it no "
      ~ "longer does, the restore below asserts that nothing happened");
    assert(c.isOperationInverse(), "G2: the command is not on the delta path");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "G2: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("G2: %d undo step(s) took effect, expected 1",
               hist.undoEpoch() - epoch0));
    assert(m.faces.length == preF, "G2: the face was not truncated");
    assert(selImage(m) == preSel,
        format("G2: the pre-op SELECTION did not come back.\n  before: %s\n"
             ~ "  after : %s", preSel, selImage(m)));
}

// ===========================================================================
// L2-h — `mesh.thicken` + `mesh.align`: the two `Kind.SetPos` rows.
// ===========================================================================

// ---------------------------------------------------------------------------
// H1 — `mesh.thicken` with `symmetric: true`.
//
// THE PARAMETER IS ASSERTED FIRST AND BY VALUE. On the default `false` the arm
// that moves every pre-existing vertex never runs, so a migration that recorded
// only the appends is green on every default cell while an undo of a SYMMETRIC
// thicken leaves the original surface at `orig + n·t/2`. A cell that merely SET
// the flag and did not check it would be one silent param-name typo away from
// measuring the default.
//
// MUTATION: in `Mesh.thickenSurface`'s symmetric arm, replace the
//           `setVertexPositions(idx, to)` with the raw
//           `foreach (i; 0 .. V0) vertices[i] = to[i];` it used to be.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    const preV    = m.vertices.length;
    const preF    = m.faces.length;
    auto  prePos  = m.vertices[0 .. preV].dup;

    auto hist = new CommandHistory();
    auto c = new MeshThicken(&m, v, EditMode.Polygons);
    setFloat(c, "thickness", 0.25f);
    setBool(c, "symmetric", true);
    assert(paramBool(c, "symmetric"),
        "H1: `symmetric` did not take — on the default `false` the "
      ~ "whole-mesh position shift never runs and this cell is green under "
      ~ "exactly the defect it exists to catch");

    assert(c.apply(), "H1: mesh.thicken must apply on this stand");
    assert(m.vertices.length == 2 * preV && m.faces.length > preF,
        format("H1: the forward left V=%d F=%d, expected V=%d and F>%d",
               m.vertices.length, m.faces.length, 2 * preV, preF));
    // The symmetric arm must actually have MOVED the originals, or the
    // restore claim below is about a shift that never happened.
    bool anyMoved = false;
    foreach (i; 0 .. preV) if (m.vertices[i] != prePos[i]) anyMoved = true;
    assert(anyMoved,
        "H1: the symmetric arm moved no pre-existing vertex — the `SetPos` "
      ~ "half of this cell would be vacuous");
    assert(c.isOperationInverse(), "H1: the command is not on the delta path");
    hist.record(c);

    immutable ulong epoch0 = hist.undoEpoch();
    assert(hist.undo(), "H1: undo() refused");
    assert(hist.undoEpoch() == epoch0 + 1,
        format("H1: %d undo step(s) took effect, expected 1",
               hist.undoEpoch() - epoch0));

    assert(m.vertices.length == preV && m.faces.length == preF,
        format("H1: the undo left V=%d F=%d, expected the pre-op %d/%d",
               m.vertices.length, m.faces.length, preV, preF));
    foreach (i; 0 .. preV)
        assert(m.vertices[i] == prePos[i],
            format("H1: vertex %d came back at (%g, %g, %g), expected its "
                 ~ "pre-op (%g, %g, %g) — the topology round-tripped and the "
                 ~ "POSITIONS did not, which is what a delta recording only "
                 ~ "the appends produces", i, m.vertices[i].x, m.vertices[i].y,
                   m.vertices[i].z, prePos[i].x, prePos[i].y, prePos[i].z));
}

// ---------------------------------------------------------------------------
// H2 — `mesh.align` at the KERNEL: the op-log kind its §5.5 row does not name.
//
// MUTATION: put the three raw writes back in `Mesh.alignFacesByMask`
//           (`vertices[vi].x -= d * pl.n.x;` and friends) instead of the
//           `setVertexPositions` call.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto prePos = m.vertices.dup;

    bool[] all = new bool[](m.faces.length);
    all[] = true;

    MeshEditDelta d;
    size_t moved;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Position);   // RECORDING
        moved = ed.mesh.alignFacesByMask(all);
        d = ed.close();
    }
    assert(moved > 0,
        "H2: `alignFacesByMask` moved nothing — the stand is planar, which "
      ~ "`makeTaggedGridBent`'s second addition exists to prevent, and every "
      ~ "claim below would be vacuous");

    assert(kindsOf(d) == "SetPos",
        format("H2: op-log kinds are [%s], expected [SetPos]. An EMPTY log is "
             ~ "the pre-L2-h state: `mesh.align` is a POSITION command whose "
             ~ "§5.5 row names only the create kinds, and its three raw "
             ~ "`vertices[vi].x -= …` writes reached no hook at all",
               kindsOf(d)));

    assert(d.revert(m), "H2: revert() refused the delta outright");
    foreach (i; 0 .. m.vertices.length)
        assert(m.vertices[i] == prePos[i],
            format("H2: vertex %d came back at (%g, %g, %g), expected its "
                 ~ "pre-op (%g, %g, %g)", i, m.vertices[i].x, m.vertices[i].y,
                   m.vertices[i].z, prePos[i].x, prePos[i].y, prePos[i].z));
}
