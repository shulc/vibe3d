// l8_extrude_delta_test — the witnesses stage L8 owes that a frozen plane
// fixture cannot carry: the op-log's KIND SEQUENCE, the refusals, the redo
// arm, and the MEASUREMENT the two declines rest on (task 1903).
//
// `undo_parity_l8_test.d` carries the plane-for-plane oracle; this file
// carries the shapes. The split is stage L7's, verbatim.
//
// LANE. All of it is `dub test --config=tests` (lane U) — `./run_test.d` never
// runs a `tests/unit/**` unittest block. The real UNDO STACK half of the seam
// is in lane S (`tests/test_l8_undo_depth.d`), because a unit cell calls
// `Command.revert()` directly and can say nothing about how many history
// entries a `/api/undo` consumed.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score a mutation that
// reddens two of these cells by running them in isolation.
module tests.unit.l8_extrude_delta_test;

import std.conv   : to;
import std.format : format;

import change_bus : changeBus;
import command;
import mesh;
import math    : Vec3;
import view;
import editmode;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry;

import tests.unit.fixtures : makeTaggedGridBent, dumpMeshPlanes,
                             diffMeshPlanes, explainMeshPlaneDiff;

import commands.mesh.edge_extend    : MeshEdgeExtend;
import commands.mesh.edge_extrude   : MeshEdgeExtrude;
import commands.mesh.face_extrude   : MeshFaceExtrude;
import commands.mesh.smooth_shift   : MeshSmoothShift;
import commands.mesh.stroke_extrude : MeshStrokeExtrude;
import commands.mesh.vertex_extrude : MeshVertexExtrude;

private Mesh* stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridBent(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

/// The two-face island the smooth arm needs — see `undo_parity_l8_test.d`'s
/// stand block for why a ONE-face operand on a FLAT grid cannot separate the
/// smooth arm from the rigid one.
private void selectIsland(Mesh* m)
{
    m.clearFaceSelection();
    m.selectFace(4);
    m.selectFace(7);
}

private string kindsOf(ref const MeshEditDelta d)
{
    string t;
    foreach (ref e; d.log) t ~= " " ~ e.kind.to!string;
    return "[" ~ t ~ " ]";
}

private MeshOpEntry.Kind[] kindSeq(ref const MeshEditDelta d)
{
    MeshOpEntry.Kind[] k;
    foreach (ref e; d.log) k ~= e.kind;
    return k;
}

private void assertSeq(string who, ref const MeshEditDelta d,
                       MeshOpEntry.Kind[] want)
{
    assert(kindSeq(d) == want, format(
        "%s recorded %s, expected %s.\n"
      ~ "  A LENGTH would not have caught this: stage J made the "
      ~ "`[MeshMapDelta, FaceReindex]` ADJACENCY contractual, and an entry "
      ~ "interposed between the pair unpairs the corner restore SILENTLY "
      ~ "while the geometry still round-trips.",
        who, kindsOf(d), want.to!string));
}

/// A view, as an LVALUE — every `Command` constructor takes `ref View`.
/// One per process is enough: nothing in this file orbits, frames or projects,
/// and every cell that could care builds its own mesh.
private View gView_;
private ref View v()
{
    if (gView_ is null) gView_ = new View(0, 0, 800, 600);
    return gView_;
}

// ===========================================================================
// 1. THE KIND SEQUENCES OF THE FOUR MIGRATED COMMANDS.
// ===========================================================================

unittest // poly.extrude and mesh.smooth_shift — the two arms of one kernel
{
    alias K = MeshOpEntry.Kind;

    Mesh* m = stand();
    selectIsland(m);
    auto fe = new MeshFaceExtrude(m, v(), EditMode.Polygons);
    assert(fe.apply(), "poly.extrude refused the island — the cell is vacuous");
    assertSeq("poly.extrude", fe.recordedDelta(),
              [K.AddVerts, K.MeshMapDelta, K.FaceReindex]);

    Mesh* m2 = stand();
    selectIsland(m2);
    auto ss = new MeshSmoothShift(m2, v(), EditMode.Polygons);
    assert(ss.apply(), "mesh.smooth_shift refused the island");
    assertSeq("mesh.smooth_shift", ss.recordedDelta(),
              [K.AddVerts, K.MeshMapDelta, K.FaceReindex]);

    // THE TWO ARMS PRODUCE THE SAME KIND SEQUENCE AND A DIFFERENT MESH, and
    // saying both is the point: the sequence assertion above is IDENTICAL for
    // the two commands, so on its own it cannot tell them apart. On a FLAT
    // stand it could not tell them apart at all — `extrudeFacesByMask`'s
    // smooth branch averages the incident face normals, which on a flat sheet
    // IS `regionNormal`, the rigid branch's value. The bent stand is what
    // makes this comparison a check rather than a tautology.
    assert(m.vertices != m2.vertices, format(
        "poly.extrude and mesh.smooth_shift left BYTE-IDENTICAL vertex arrays "
      ~ "on the same island. Either the `smooth` argument is not reaching "
      ~ "`extrudeFacesByMask`, or this stand went flat — a flat sheet cannot "
      ~ "discriminate the two arms and every smooth-arm assertion in this "
      ~ "file and in `undo_parity_l8_test.d` would be measuring the rigid one "
      ~ "twice (V=%d)", m.vertices.length));
}

unittest // mesh.vertexExtrude — the family's only `Kind.SetPos` member
{
    alias K = MeshOpEntry.Kind;

    Mesh* m = stand();
    auto c = new MeshVertexExtrude(m, v(), EditMode.Vertices);
    c.setShift(0.5f);
    c.setWidth(0.25f);
    assert(c.apply(), "mesh.vertexExtrude refused the stand's vertex "
                    ~ "selection with a non-zero width");
    // The `SetPos` is stage H's §5.7 migration of the raw apex-shift write and
    // is INDEPENDENT of the arming: `setVertexPos` self-logs whenever the
    // enclosing batch records. It is the only entry that restores the apex
    // position, and a reverse that dropped it would still round-trip V/F/E.
    assertSeq("mesh.vertexExtrude", c.recordedDelta(),
              [K.AddVerts, K.SetPos, K.MeshMapDelta, K.FaceReindex]);
}

unittest // mesh.strokeExtrude — ONE GROUP PER SPAN, and the pair brackets it
{
    alias K = MeshOpEntry.Kind;
    static immutable Vec3[] p1 = [Vec3(0, 0, 0), Vec3(0, 0.5f, 0)];
    static immutable Vec3[] p3 = [Vec3(0, 0, 0), Vec3(0, 0.4f, 0),
                                  Vec3(0.2f, 0.8f, 0), Vec3(0.5f, 1.0f, 0.2f)];

    static MeshStrokeExtrude run(Mesh* m, immutable(Vec3)[] path)
    {
        auto c = new MeshStrokeExtrude(m, v(), EditMode.Polygons);
        foreach (ref p; c.params())
            if (p.name == "path") { *p.v3aPtr = path.dup; break; }
        assert(c.apply(), "mesh.strokeExtrude refused a "
                        ~ (path.length - 1).to!string ~ "-span path");
        return c;
    }

    auto one   = run(stand(), p1);
    auto three = run(stand(), p3);

    assertSeq("mesh.strokeExtrude (1 span)", one.recordedDelta(),
              [K.AddVerts, K.MeshMapDelta, K.FaceReindex]);

    // THREE GROUPS, IN ORDER — not "three FaceReindex entries". `extrudeAlongPath`
    // calls `extrudePathStep_` once per span and each call opens its OWN
    // `faceReindexScope()`, so the pairing is per group; a reverse that replayed
    // the groups out of order, or a payload that drifted away from its face
    // entry, is invisible to a count and visible here.
    //
    // The spans' `AddVerts` entries deliberately DO NOT coalesce into one:
    // `recordAddVert`'s contiguity test only looks at the LAST entry, and a
    // `FaceReindex` now sits between consecutive appends (stage K). A future
    // change that made them coalesce again would redden here, which is correct
    // — it would mean the per-span face entries had gone.
    assertSeq("mesh.strokeExtrude (3 spans)", three.recordedDelta(),
              [K.AddVerts, K.MeshMapDelta, K.FaceReindex,
               K.AddVerts, K.MeshMapDelta, K.FaceReindex,
               K.AddVerts, K.MeshMapDelta, K.FaceReindex]);
}

// ===========================================================================
// 2. THE REFUSALS — `evaluate` false, NO delta, and `revert()` false.
//
// The command no-op contract (CLAUDE.md): `evaluate` false => `apply` false =>
// the funnel throws => `status:error` and NO history entry. There is no path
// that answers `ok` while recording nothing, so a refused instance must also
// refuse its own `revert()` — a `true` there would be a history entry claiming
// an undo it cannot perform.
// ===========================================================================

unittest // width == 0 is a documented no-op for mesh.vertexExtrude
{
    Mesh* m = stand();
    immutable size_t v0 = m.vertices.length, f0 = m.faces.length;
    immutable ulong  e0 = changeBus.emptyDeltaOverMutation;

    auto c = new MeshVertexExtrude(m, v(), EditMode.Vertices);
    c.setShift(0.5f);          // shift alone is a CONFIRMED no-op (class doc)
    c.setWidth(0.0f);
    assert(!c.apply(), "mesh.vertexExtrude with width=0 must refuse — its own "
                     ~ "doc comment calls that a no-op, and a `true` here "
                     ~ "would record a history entry over an unchanged mesh");
    assert(m.vertices.length == v0 && m.faces.length == f0, format(
        "the refused vertex extrude still changed the mesh (V %d->%d F %d->%d)",
        v0, m.vertices.length, f0, m.faces.length));
    assert(changeBus.emptyDeltaOverMutation == e0, format(
        "the refusal ticked emptyDeltaOverMutation by %d. That counter means "
      ~ "\"a REAL mutation recorded nothing\" — an honest refusal must not "
      ~ "reach it, or the counter stops discriminating the two",
        changeBus.emptyDeltaOverMutation - e0));
    assert(!c.revert(), "a refused mesh.vertexExtrude must refuse its revert: "
                      ~ "it holds an empty delta and a nulled selection image, "
                      ~ "and replaying them would run over a mesh they were "
                      ~ "never sized against");
}

unittest // distance == 0 is a documented no-op for poly.extrude
{
    Mesh* m = stand();
    selectIsland(m);
    immutable size_t f0 = m.faces.length;
    auto c = new MeshFaceExtrude(m, v(), EditMode.Polygons);
    foreach (ref p; c.params()) if (p.name == "distance") *p.fptr = 0.0f;
    assert(!c.apply(), "poly.extrude with distance=0 must refuse");
    assert(m.faces.length == f0, "the refused face extrude still added faces");
    assert(!c.revert(), "a refused poly.extrude must refuse its revert");
}

// ===========================================================================
// 3. THE REDO ARM — `apply()` a SECOND time must not record a SECOND delta.
// ===========================================================================

unittest // CommandHistory.redo re-runs apply(); the first delta must survive
{
    Mesh* m = stand();
    selectIsland(m);
    auto c = new MeshFaceExtrude(m, v(), EditMode.Polygons);

    assert(c.apply(), "the first apply must land");
    immutable string firstKinds = kindsOf(c.recordedDelta());
    immutable size_t firstBytes = c.recordedDelta().byteSize;
    auto postOp = dumpMeshPlanes(*m);

    assert(c.revert(), "the undo must land");
    assert(c.apply(), "the REDO must land — `CommandHistory.redo` calls "
                    ~ "`apply()` again and this arm re-runs the kernel "
                    ~ "batchless");

    assert(kindsOf(c.recordedDelta()) == firstKinds
        && c.recordedDelta().byteSize == firstBytes, format(
        "the redo recorded a SECOND delta over the first: kinds %s -> %s, "
      ~ "byteSize %d -> %d. A second recording run lays a log the next undo "
      ~ "would replay on top of a mesh the first one already described",
        firstKinds, kindsOf(c.recordedDelta()),
        firstBytes, c.recordedDelta().byteSize));

    // …and the redo landed the SAME mesh, not merely a mesh. Stated over the
    // whole plane table rather than over V/F/E: a redo that re-ran the kernel
    // against a differently-selected operand would agree on the counts.
    auto redone = dumpMeshPlanes(*m);
    assert(diffMeshPlanes(postOp, redone) == "", format(
        "the redo did not reproduce the first forward.%s",
        explainMeshPlaneDiff(postOp, redone)));
}

// ===========================================================================
// 4. THE DECLINE — `mesh.edge_extrude` and `mesh.edge_extend`, BOTH HALVES.
//
// This block is what the two declines rest on, and it asserts BOTH halves on
// purpose. A cell that only measured "the delta loses the UV map" would stay
// green if the SNAPSHOT ever stopped restoring it too, and the decline would
// then be resting on a difference that no longer exists — the shape stage L7-d
// found when it INVERTED stage K's refusal on `bevelVerticesByMask`.
// ===========================================================================

private enum size_t kStandUvFloats = 72;   // 9 quads x 4 corners x dim 2

/// The stand's UV map, flattened, so the two halves below compare VALUES and
/// not merely lengths. `makeTaggedGridFull`'s corners are `0, 1, 2, …`, i.e.
/// all distinct — a value restored onto the wrong corner cannot compare equal.
private float[] uvOf(ref Mesh m)
{
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null && uv.domain == MapDomain.PolyVertex,
        "the stand carries no PolyVertex `" ~ kUvMapName ~ "` map — this whole "
      ~ "block is then blind to the plane it exists to measure");
    return uv.data.dup;
}

unittest // half A: the SNAPSHOT path restores the per-corner map exactly
{
    foreach (which; 0 .. 2) {
        Mesh* m = stand();
        immutable string who = which == 0 ? "mesh.edge_extrude"
                                          : "mesh.edge_extend";
        auto pre   = dumpMeshPlanes(*m);
        auto preUv = uvOf(*m);
        assert(preUv.length == kStandUvFloats, format(
            "%s: the stand's UV map is %d floats, expected %d — the numbers "
          ~ "below are keyed to this stand", who, preUv.length,
            kStandUvFloats));

        Command c = which == 0
            ? cast(Command) new MeshEdgeExtrude(m, v(), EditMode.Edges)
            : cast(Command) new MeshEdgeExtend (m, v(), EditMode.Edges);
        assert(c.apply(), who ~ ": the forward must apply on this stand");

        // THE FORWARD ITSELF ZEROES THE MAP — a STATED loss
        // (`dropCornerProvenance(CornerDrop.SweptSurfaceNoLaw)`, task 0830),
        // and it takes the ORIGINAL faces' corners with it, not only the new
        // ones. Asserted so the next reader does not read half B's zeroes as
        // something the undo broke.
        bool anyNonZero = false;
        foreach (f; uvOf(*m)) if (f != 0.0f) { anyNonZero = true; break; }
        assert(!anyNonZero, who ~ ": the FORWARD kept per-corner values. That "
                          ~ "is good news and it retires this whole block — "
                          ~ "the kernel's `SweptSurfaceNoLaw` drop is gone, so "
                          ~ "re-measure the delta path and lift the decline "
                          ~ "recorded at the class declaration");

        assert(c.revert(), who ~ ": the snapshot undo must succeed");
        assert(uvOf(*m) == preUv, who ~ ": the SNAPSHOT undo did NOT restore "
                                ~ "the per-corner map. If this is true the "
                                ~ "decline is pointless — the delta would lose "
                                ~ "nothing the snapshot keeps — and stage L8-d "
                                ~ "should be re-argued from here");
        assert(diffMeshPlanes(pre, dumpMeshPlanes(*m)) == "", format(
            "%s: the snapshot undo left a residual.%s", who,
            explainMeshPlaneDiff(pre, dumpMeshPlanes(*m))));
    }
}

unittest // half B: the DELTA path would NOT — which is why the two are declined
{
    import mesh_edit_delta : MeshEditScope;
    import mesh_ops.extrude : kExtrudeEditScope;

    foreach (which; 0 .. 2) {
        Mesh* m = stand();
        immutable string who = which == 0 ? "extrudeEdgesByMask"
                                          : "extendEdgesByMask";
        auto preUv = uvOf(*m);

        bool[] mask = new bool[](m.edges.length);
        foreach (i; 0 .. m.edges.length)
            if (m.isEdgeSelected(i)) mask[i] = true;
        bool any = false;
        foreach (b; mask) if (b) { any = true; break; }
        assert(any, who ~ ": the stand has no selected edge, so the kernel "
                  ~ "would refuse and this cell would measure nothing");

        size_t n;
        MeshEditDelta d;
        {
            auto ed = MeshEditBatch(*m, kExtrudeEditScope);   // RECORDING
            n = which == 0
                ? ed.extrudeEdgesByMask(mask, 0.2f, 0.1f)
                : ed.extendEdgesByMask(mask, 0.1f, 0.15f, Vec3(0, 0, 0),
                                       Vec3(0, 0, 0), Vec3(1, 1, 1), 1,
                                       Vec3(0, 0, 0));
            d = ed.close();
        }
        assert(n > 0, who ~ ": the kernel refused the stand");

        // The op-log is NOT empty, and that is worth saying: this family needs
        // no publisher and the decline is NOT "there is nothing in the log".
        assert(d.log.length > 0, who ~ ": the op-log is EMPTY. That is a "
                               ~ "DIFFERENT defect from the one this block "
                               ~ "records and it must not be read as this one");

        assert(d.revert(*m), who ~ ": the recorded revert refused outright — a "
                           ~ "third state, neither the clean restore nor the "
                           ~ "corner loss this cell measures");

        auto postUv = uvOf(*m);
        assert(postUv.length == preUv.length, format(
            "%s: the recorded revert left the map at %d floats against a "
          ~ "pre-op %d — a LENGTH loss, which is a different failure from the "
          ~ "VALUE loss below", who, postUv.length, preUv.length));
        assert(postUv != preUv, format(
            "%s: the RECORDED revert restored the per-corner map exactly. "
          ~ "That retires stage L8-d's decline — re-measure and migrate "
          ~ "`mesh.%s` onto the delta, deleting the reason recorded at its "
          ~ "class declaration", who,
            which == 0 ? "edge_extrude" : "edge_extend"));

        // …and it is a ZEROING, not a permutation. Stated because "the values
        // differ" is satisfied by a carry that put them on the wrong corners,
        // which would be a different diagnosis and a different fix.
        bool allZero = true;
        foreach (f; postUv) if (f != 0.0f) { allZero = false; break; }
        assert(allZero, format(
            "%s: the recorded revert left the map DIFFERENT but not ZERO. The "
          ~ "decline is argued on a wholesale drop "
          ~ "(`CornerDrop.DeltaReplayDeclined`); values on the wrong corners "
          ~ "are a carry defect and belong to stage J, not here", who));
    }
}

// ===========================================================================
// 5. `/api/history`'s `opInverse` FIELD — four true, two false, BY MEASUREMENT.
//
// Both halves, for the same reason as block 4: a cell asserting only the four
// `true`s would be green if the base default flipped, and one asserting only
// the two `false`s would be green if nobody had migrated anything.
// ===========================================================================

unittest
{
    Mesh* m = stand();
    selectIsland(m);
    auto fe = new MeshFaceExtrude(m, v(), EditMode.Polygons);
    assert(!fe.isOperationInverse(), "an instance that has not run yet holds "
                                   ~ "no inverse at all — a literal `true` "
                                   ~ "here would be a lie about a command "
                                   ~ "whose evaluate refused");
    assert(fe.apply());
    assert(fe.isOperationInverse(), "poly.extrude restores from an op-log and "
                                  ~ "must not report itself snapshot-backed");

    Mesh* m2 = stand();
    auto ee = new MeshEdgeExtrude(m2, v(), EditMode.Edges);
    assert(ee.apply());
    assert(!ee.isOperationInverse(), "mesh.edge_extrude is DECLINED at stage "
                                   ~ "L8-d and still restores from a whole-"
                                   ~ "mesh MeshSnapshot; reporting an "
                                   ~ "operation inverse would make "
                                   ~ "`/api/history` lie about it");
}
