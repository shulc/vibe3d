// l7d_vertex_bevel_delta_test — the witnesses the VERTEX half of stage L7
// owes that a frozen plane fixture cannot carry (task 1903;
// `undo_parity_l7d_test.d` carries the plane-for-plane oracle, this file
// carries the SHAPE assertions and the refusals).
//
// LANE. All of it is `dub test --config=tests` (lane U). The COMMAND
// CONSTRUCTOR's seam counters and the real undo STACK are lane S
// (`tests/test_vertex_bevel.d`, `tests/test_l6_undo_depth.d`), because a unit
// cell that drives the KERNEL opens its own batch and stays green with the
// command still unrecorded.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score a mutation that
// reddens two of these cells by running them in isolation.
module tests.unit.l7d_vertex_bevel_delta_test;

import std.conv   : to;
import std.format : format;

import change_bus : changeBus;
import command;
import mesh;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry;
import view;
import editmode;

import tests.unit.fixtures : makeTaggedGridFull;
import tests.unit.undo_parity_l0_test : setF;
import commands.mesh.vertex_bevel : MeshVertexBevel;

private Mesh* stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private string kindsOf(in MeshEditDelta d)
{
    string s;
    foreach (i, ref e; d.log) s ~= (i ? " " : "") ~ e.kind.to!string;
    return s;
}

private MeshVertexBevel bevelAt(Mesh* m, uint[] verts, float amount)
{
    if (verts.length) {
        m.clearVertexSelection();
        foreach (vi; verts) m.selectVertex(cast(int) vi);
    }
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshVertexBevel(m, v, EditMode.Vertices);
    setF(cast(Command) c, "amount", amount);
    return c;
}

// ---------------------------------------------------------------------------
// W-7-d-SHAPE — the op-log is a KIND SEQUENCE, and the
// `[MeshMapDelta, FaceReindex]` PAIR is contractual.
//
// `[AddVerts, MeshMapDelta, FaceReindex, RemoveVerts, Reindex]` — the appended
// chamfer points, the corner payload and the face rewrite it belongs to (stage
// L7-d's arming of `bevelVerticesByMask`), and the tail compaction's pair.
//
// ASSERTED AS A SEQUENCE, NEVER A LENGTH. `CornerCarry.payloadForCount` binds
// a payload to the face entry IMMEDIATELY after it; an interposed entry
// unpairs them, and the reverse then finds no payload for the `FaceReindex` it
// replays and zeroes the per-corner map SILENTLY while every count, every
// position and every winding still round-trip. A length check cannot see that,
// and neither can the frozen fixture's `counts` plane.
//
// MUTATION: drop the `faceReindexScope()` arm in
// `source/mesh_ops/bevel_vertex.d`. The sequence loses its `FaceReindex`, the
// delta stops restoring the face array, and the parity fixture reddens on
// `counts`.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    auto c = bevelAt(m, [5u], 0.2f);
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;

    assert(c.apply(), "mesh.vertexBevel refused vertex 5 on this stand");
    assert(changeBus.emptyDeltaOverMutation == e0, format(
        "mesh.vertexBevel closed a recording batch with an EMPTY delta over a "
      ~ "real mutation (counter +%d)", changeBus.emptyDeltaOverMutation - e0));

    assert(kindsOf(c.recordedDelta())
        == "AddVerts MeshMapDelta FaceReindex RemoveVerts Reindex", format(
        "mesh.vertexBevel recorded [%s], expected [AddVerts MeshMapDelta "
      ~ "FaceReindex RemoveVerts Reindex]. A MISSING FaceReindex means the "
      ~ "`faceReindexScope()` arm in mesh_ops/bevel_vertex.d is gone and the "
      ~ "face array has no restorer at all; an entry BETWEEN the MeshMapDelta "
      ~ "and its FaceReindex unpairs the corner carry and zeroes the "
      ~ "per-corner map silently while the geometry still round-trips",
        kindsOf(c.recordedDelta())));

    // ONE payload for ONE face entry. Two `FaceReindex` against one payload is
    // exactly the shape that keeps `bevelEdgesByMask` unarmed.
    size_t reindexes, payloads;
    foreach (ref e; c.recordedDelta().log) {
        if (e.kind == MeshOpEntry.Kind.FaceReindex)  ++reindexes;
        if (e.kind == MeshOpEntry.Kind.MeshMapDelta) ++payloads;
    }
    assert(reindexes == 1 && payloads == 1, format(
        "%d FaceReindex against %d MeshMapDelta — the vertex chamfer performs "
      ~ "ONE face rewrite under ONE corner-rewrite handle, and the 1:1 pairing "
      ~ "is what separates it from the edge chamfer, which is still declined "
      ~ "for having two rewrites under one handle", reindexes, payloads));
}

// ---------------------------------------------------------------------------
// W-7-d1 — THE VALUE ROUND-TRIP, which is the whole ground of Stage K's
// refusal made executable.
//
// The chamfer CONSUMES vertex 5. It is a member of the stand's named vertex set
// "V", it carries a non-zero Point-domain `W` value, and it is an endpoint of a
// named edge-set entry. After the revert all three must be back.
//
// THE CELL ASSERTS ITS OWN NON-VACUITY FIRST, because all three of those are
// properties of the STAND and a stand that lost any of them makes the whole
// cell green under every implementation of the payload.
//
// MUTATION (the point-map arm): disable the Point-map capture at its single
// production publisher, `Mesh.compactUnreferenced`. Positions, windings, counts
// and every mark word compare EQUAL — only the `W` value differs.
// MUTATION (the set-mask arm): disable the `vertSetMaskBefore` /
// `edgeSetKeyDropped` capture at the same site. Only the two set planes differ.
// The two arms are scored by two different mutations and are asserted
// separately below for that reason.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();

    // ---- non-vacuity of the stand -----------------------------------------
    assert((m.vertexSetMask[5] & 1UL) != 0,
        "the stand's vertex 5 is not in a named vertex set — the set-mask arm "
      ~ "of the RemoveVerts payload is INERT and this cell measures nothing "
      ~ "about stage L5-b");
    auto wm = m.meshMap("W");
    assert(wm !is null && wm.dim == 1 && wm.data.length > 5,
        "the stand carries no dim-1 Point-domain `W` map");
    immutable float w5 = wm.data[5];
    assert(w5 != 0.0f,
        "the stand's `W` value at vertex 5 is 0 — a payload that dropped it "
      ~ "would restore 0 and compare EQUAL, so this cell could not tell a "
      ~ "carried value from a lost one");
    size_t incidentSetEdges;
    foreach (k, wrd; m.edgeSetMask) {
        immutable uint a = cast(uint)(k >> 32), b = cast(uint)(k & 0xffff_ffffUL);
        if (a == 5 || b == 5) ++incidentSetEdges;
    }
    assert(incidentSetEdges > 0,
        "no named edge-set entry has vertex 5 as an endpoint — the EDGE half "
      ~ "of the set-mask payload is INERT here");

    immutable ulong[] preVertSet = m.vertexSetMask.idup;
    ulong[ulong] preEdgeSet;
    foreach (k, wrd; m.edgeSetMask) preEdgeSet[k] = wrd;

    auto c = bevelAt(m, [5u], 0.2f);
    assert(c.apply(), "mesh.vertexBevel refused vertex 5");

    // The chamfer really CONSUMED vertex 5 — the compaction dropped it, which
    // is the only way `Kind.RemoveVerts` gets a payload to carry at all.
    size_t removeVerts;
    foreach (ref e; c.recordedDelta().log)
        if (e.kind == MeshOpEntry.Kind.RemoveVerts) ++removeVerts;
    assert(removeVerts == 1,
        "the chamfer recorded no RemoveVerts entry, so no vertex was consumed "
      ~ "and BOTH payload arms are inert on this operand");

    assert(c.revert(), "mesh.vertexBevel's revert() answered false");

    // ---- the Point-map arm -------------------------------------------------
    auto wm2 = m.meshMap("W");
    assert(wm2 !is null && wm2.data.length > 5, "the `W` map vanished");
    assert(wm2.data[5] == w5, format(
        "the consumed vertex came back with W=%s, expected %s. The Point-domain "
      ~ "map-value arm of the `Kind.RemoveVerts` payload (task 2330) is what "
      ~ "carries it; without it `removeVertsReverse` re-inserts the vertex with "
      ~ "its map values ZEROED — and that lost VALUE is the exact ground Stage "
      ~ "K refused this arming on", wm2.data[5], w5));

    // ---- the set-mask arm --------------------------------------------------
    assert(m.vertexSetMask.length == preVertSet.length, format(
        "vertexSetMask came back %d long against a pre-op %d",
        m.vertexSetMask.length, preVertSet.length));
    foreach (i, wrd; preVertSet)
        assert(m.vertexSetMask[i] == wrd, format(
            "vertexSetMask[%d] came back %d, expected %d — the set-mask arm of "
          ~ "the RemoveVerts payload (stage L5-b) did not carry it",
            i, m.vertexSetMask[i], wrd));
    assert(m.edgeSetMask.length == preEdgeSet.length, format(
        "edgeSetMask came back with %d entr(ies), expected %d",
        m.edgeSetMask.length, preEdgeSet.length));
    foreach (k, wrd; preEdgeSet)
        assert((k in m.edgeSetMask) !is null && m.edgeSetMask[k] == wrd, format(
            "the named edge-set entry keyed %d did not come back — its "
          ~ "endpoint was consumed by the chamfer and the EDGE half of the "
          ~ "set-mask payload is what re-keys it", k));
}

// ---------------------------------------------------------------------------
// THE REFUSAL CONTRACT. `evaluate` false ⇒ `apply` false ⇒ no history entry.
// Three assertions plus the counter, for `l6_duplicate_delta_test.d`'s reasons.
// ---------------------------------------------------------------------------
unittest // outside Vertices mode
{
    auto m = stand();
    immutable size_t preV = m.vertices.length, preF = m.faces.length;
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshVertexBevel(m, v, EditMode.Polygons);
    setF(cast(Command) c, "amount", 0.2f);

    assert(!c.apply(), "mesh.vertexBevel applied in Polygons mode");
    assert(m.vertices.length == preV && m.faces.length == preF,
        "a REFUSED mesh.vertexBevel changed the mesh");
    assert(changeBus.emptyDeltaOverMutation == e0,
        "the mode refusal ticked emptyDeltaOverMutation — that counter means "
      ~ "MUTATED-AND-RECORDED-NOTHING, which a pre-kernel gate cannot be");
    assert(!c.revert(),
        "a REFUSED MeshVertexBevel answered true from revert()");

    // THE CONTROL, on the same stand: without it the three above are satisfied
    // by a stand that cannot chamfer at all.
    auto ok = bevelAt(m, [5u], 0.2f);
    assert(ok.apply(),
        "the CONTROL refused too, so the assertions above say the stand is "
      ~ "broken rather than anything about the mode gate");
}

unittest // amount = 0 is the kernel's own no-op refusal
{
    auto m = stand();
    immutable size_t preV = m.vertices.length;
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;

    auto c = bevelAt(m, [5u], 0.0f);
    assert(!c.apply(),
        "mesh.vertexBevel applied at amount=0 — the kernel processes no vertex "
      ~ "and `acceptRecordedEdit(0, …)` is what turns that into a refusal");
    assert(m.vertices.length == preV, "an amount=0 chamfer changed the mesh");
    assert(changeBus.emptyDeltaOverMutation == e0, format(
        "the amount=0 refusal ticked emptyDeltaOverMutation (+%d). It must "
      ~ "not: `affected == 0` is the FIRST arm of `acceptRecordedEdit` and it "
      ~ "returns before the empty-delta arm",
        changeBus.emptyDeltaOverMutation - e0));

    auto ok = bevelAt(m, [5u], 0.2f);
    assert(ok.apply(), "the CONTROL refused too");
}
