// ===========================================================================
// Task 1903 Stage L1-P1 — the `Kind.MapValueDelta` witnesses that can be
// driven from OUTSIDE `mesh_edit_delta.d`.
//
// LANE: `dub test --config=tests` ONLY. `./run_test.d` links the prebuilt
// `libvibe3d_test.a` and never RUNS a `tests/unit/**` or `source/**` unittest
// block — MEASURED at task 2090: an unconditional hard failure planted in
// `mesh_edit_delta.d`'s own census left `./run_test.d test_falloff_combine`
// green. A cell in the wrong lane is a cell that cannot redden.
//
// EVERY ENTRY HERE IS HAND-BUILT, and that is not a shortcut. At this commit
// the kind has ZERO production recorder callers — its first is Stage L1-a
// (`source/commands/mesh/morph.d`) — so a hand-built `MeshOpEntry` driven
// through `apply`/`revert` is the only way to execute the dispatch. It is
// exactly how `HideDelta`'s three carve-out modules drive `patchHide` today.
//
// THE COUNTERS ARE PROCESS-CUMULATIVE. Every assertion on them is a DELTA
// across the step, never an absolute.
// ===========================================================================
module tests.unit.map_value_delta_test;

import std.algorithm.searching : canFind;
import std.format : format;

import mesh;
import math : Vec3;
import mesh_edit_delta;
import change_bus : changeBus;
import http_json : meshPlanesJson;
import tests.unit.fixtures : makeTaggedGridMaps;

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// A `Values` entry, `Listed`, over one presence-tracked morph map.
private MeshOpEntry morphValuesEntry(string name, MapKind kind, uint[] idx,
                                     float[] before, float[] after,
                                     ubyte[] presBefore, ubyte[] presAfter) {
    MeshOpEntry e;
    e.kind          = MeshOpEntry.Kind.MapValueDelta;
    e.mapOp         = MeshOpEntry.MapOp.Values;
    e.mapAddr       = MeshOpEntry.MapAddressing.Listed;
    e.mapName       = name;
    e.mapDim        = 3;
    e.mapDomain     = MapDomain.Point;
    e.mapKind       = kind;
    e.mapElemIdx    = idx;
    e.mapValsBefore = before;
    e.mapValsAfter  = after;
    e.presentBefore = presBefore;
    e.presentAfter  = presAfter;
    return e;
}

private MeshEditDelta oneEntry(MeshOpEntry e, MeshEditScope sc = MeshEditScope.Maps) {
    MeshEditDelta d;
    d.scope_ = sc;
    d.log    = [e];
    return d;
}

/// The bind-refusal counter's delta across a call, so no cell reads an
/// absolute out of a process-cumulative counter.
private struct BindWatch {
    ulong at;
    static BindWatch open() { BindWatch w; w.at = changeBus.mapDeltaBindRefused; return w; }
    ulong delta() const { return changeBus.mapDeltaBindRefused - at; }
}

// ===========================================================================
// W-K4 — the FAST path is actually taken by a map-only log.
//
// This is the whole point of ruling 1: L1's logs must not re-derive edges and
// loops, must not move `topologyVersion`, and must therefore leave a live
// subpatch preview's layout key alone.
//
// THE CONTROL IS MANDATORY. Three zeros and a `+0` are also what a cell that
// never ran reads, so the same harness is pointed at an index-space-MOVING log
// and required to read the other numbers.
// ===========================================================================
unittest
{
    static struct Run { size_t rebuilds, loops; ulong topoDelta, mutDelta; }

    static Run replay(ref Mesh m, ref MeshEditDelta d) {
        g_rebuildEdgesRuns = 0;
        g_buildLoopsRuns   = 0;
        const ulong t0 = m.topologyVersion, v0 = m.mutationVersion;
        assert(d.revert(m), "replay: revert must answer true");
        return Run(g_rebuildEdgesRuns, g_buildLoopsRuns,
                   m.topologyVersion - t0, m.mutationVersion - v0);
    }

    // ---- the subject: one MapValueDelta, nothing else ----------------------
    Mesh m = makeTaggedGridMaps();
    auto mm = m.meshMap("MR");
    assert(mm !is null && mm.kind == MapKind.morphRelative, "stand: MR must exist");
    const Vec3 was = m.morphEvaluate("MR", 6);

    auto e = morphValuesEntry("MR", MapKind.morphRelative, [6u],
                              [1.0f, 2.0f, 3.0f], [4.0f, 5.0f, 6.0f],
                              [cast(ubyte)1], [cast(ubyte)1]);
    auto d = oneEntry(e);
    const Run r = replay(m, d);

    assert(r.rebuilds == 0 && r.loops == 0, format(
        "W-K4: a MapValueDelta-only log ran rebuildEdges %d times and "
      ~ "buildLoops %d times. It writes only MeshMap.data/present, so no "
      ~ "index space moved and re-deriving edges/loops is a byte-identical "
      ~ "O(mesh) no-op — the carve-out must skip it.", r.rebuilds, r.loops));
    assert(r.topoDelta == 0, format(
        "W-K4: topologyVersion moved by %d. It is the subpatch-preview + GPU "
      ~ "LAYOUT key; a UV or morph undo that bumps it forces a preview "
      ~ "rebuild and a full re-upload for a change that moved no corner.",
        r.topoDelta));
    assert(r.mutDelta >= 1, format(
        "W-K4: mutationVersion moved by %d — a replay that changed map values "
      ~ "and published nothing leaves every version-keyed cache stale",
        r.mutDelta));

    const Vec3 now = m.morphEvaluate("MR", 6);
    assert(now.x == 1.0f && now.y == 2.0f && now.z == 3.0f, format(
        "W-K4 non-vacuity: the entry did not round-trip — vertex 6 of MR "
      ~ "reads (%s, %s, %s) after the revert, expected the recorded BEFORE "
      ~ "image (1, 2, 3). Without a real write the three zeros above are a "
      ~ "dead cell.", now.x, now.y, now.z));
    assert(!(was.x == now.x && was.y == now.y && was.z == now.z),
        "W-K4 non-vacuity: the entry restored the value that was already "
      ~ "there, so nothing distinguishes a write from a no-op");

    // ---- the CONTROL: an index-space-MOVING log through the same harness ---
    Mesh c = makeTaggedGridMaps();
    auto rec = MeshEditTracker();
    c.beginEditBatch(&rec, MeshEditScope.Geometry | MeshEditScope.Marks);
    bool[] mask = new bool[](c.faces.length);
    mask[0] = true;
    c.deleteFacesByMask(mask);
    auto cd = c.endEditBatch();
    const Run rc = replay(c, cd);
    assert(rc.rebuilds >= 1 && rc.loops >= 1, format(
        "W-K4 CONTROL: an index-space-moving log read rebuildEdges=%d "
      ~ "buildLoops=%d. If the moving log ALSO reads zero, the instrument is "
      ~ "dead and the subject's zeros mean nothing.", rc.rebuilds, rc.loops));
    assert(rc.topoDelta >= 1, format(
        "W-K4 CONTROL: topologyVersion moved by %d on a face-removing log; "
      ~ "it must move there, or the subject's +0 is not a measurement",
        rc.topoDelta));
}

// ===========================================================================
// W-K5 / W-K6 — the PRESENCE plane survives an ARMED revert, and the
// GEOMETRIC consequence of losing it.
//
// The two are separate cells because they fail differently. W-K5 reads the RAW
// `present` channel out of the plane dump (`http_json.d` emits it undecoded,
// precisely so a test is not looking through `isPresent`). W-K6 reads
// `morphEvaluate`, because on a `morphAbsolute` map an ABSENT entry means
// "stay at the base" and a PRESENT ZERO does not — so a restore that writes a
// present zero is green on the value plane and moves the vertex.
//
// A FORWARD-ONLY CHECK CANNOT SEE EITHER: the forward is identical whether or
// not `presentBefore` is honoured on the way back.
// ===========================================================================
unittest // W-K5 — the raw presence channel, both directions
{
    Mesh m = makeTaggedGridMaps();
    auto ma = m.meshMap("MA");
    assert(ma !is null && ma.kind == MapKind.morphAbsolute, "stand: MA must exist");
    assert(ma.present.length == m.vertices.length,
        "stand: MA must carry a per-vertex presence channel — an EMPTY one "
      ~ "MEANS all-present and this cell would be measuring nothing");
    assert(ma.present[1] != 0 && ma.present[4] != 0,
        "stand: vertices 1 and 4 of MA must be PRESENT before the op, or "
      ~ "clearing them below changes no presence bit");

    const string pre = meshPlanesJson(m);

    // The op CLEARS vertices 1 and 4: present, non-zero -> absent, zero.
    const size_t b1 = 1 * 3, b4 = 4 * 3;
    auto e = morphValuesEntry("MA", MapKind.morphAbsolute, [1u, 4u],
        [ma.data[b1], ma.data[b1+1], ma.data[b1+2],
         ma.data[b4], ma.data[b4+1], ma.data[b4+2]],
        [0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f],
        [cast(ubyte)1, cast(ubyte)1], [cast(ubyte)0, cast(ubyte)0]);
    auto d = oneEntry(e);

    assert(d.apply(m), "W-K5: apply must answer true");
    const string post = meshPlanesJson(m);
    assert(post != pre,
        "W-K5 non-vacuity: the FORWARD changed no plane the dump can see, so "
      ~ "the round-trip below compares a state with itself");

    assert(d.revert(m), "W-K5: revert must answer true");
    const string back = meshPlanesJson(m);
    assert(back == pre,
        "W-K5: the plane dump after apply+revert is NOT byte-identical to the "
      ~ "pre-op dump. The likeliest plane, by construction, is the RAW "
      ~ "`present` channel — `http_json.d` emits it undecoded exactly so this "
      ~ "cell can see a restore that brought back `data` and dropped presence. "
      ~ "`data` compares equal in that failure and every other plane does too.");
}

unittest // W-K6 — and what losing it does to GEOMETRY
{
    Mesh m = makeTaggedGridMaps();
    auto ma = m.meshMap("MA");
    assert(ma !is null, "stand: MA must exist");

    const Vec3 basePos = m.vertices[1];
    const Vec3 pre     = m.morphEvaluate("MA", 1);
    assert(!(pre.x == basePos.x && pre.y == basePos.y && pre.z == basePos.z),
        "stand: vertex 1 of MA must evaluate AWAY from its base position, or "
      ~ "'absent' and 'present' produce the same geometry here and this cell "
      ~ "cannot exhibit the failure");

    const size_t b1 = 1 * 3;
    auto e = morphValuesEntry("MA", MapKind.morphAbsolute, [1u],
        [ma.data[b1], ma.data[b1+1], ma.data[b1+2]],
        [0.0f, 0.0f, 0.0f],
        [cast(ubyte)1], [cast(ubyte)0]);
    auto d = oneEntry(e);
    assert(d.apply(m));
    const Vec3 cleared = m.morphEvaluate("MA", 1);
    assert(cleared.x == basePos.x && cleared.y == basePos.y && cleared.z == basePos.z,
        "W-K6 non-vacuity: clearing the entry must make morphEvaluate fall "
      ~ "back to the BASE position — on a morphAbsolute map an absent entry "
      ~ "means 'stay at the base'");

    assert(d.revert(m));
    const Vec3 back = m.morphEvaluate("MA", 1);
    assert(back.x == pre.x && back.y == pre.y && back.z == pre.z, format(
        "W-K6: after the undo vertex 1 of MA evaluates to (%s, %s, %s), it "
      ~ "was (%s, %s, %s). A revert that restored `data` and left the "
      ~ "presence bit CLEAR leaves the vertex at its base — a silent "
      ~ "GEOMETRIC error. W-K5 alone can be 'fixed' by writing a present "
      ~ "ZERO, which is green on the value plane and wrong here.",
        back.x, back.y, back.z, pre.x, pre.y, pre.z));
}

// ===========================================================================
// W-K7 — `kind` is a REFUSAL term, and it is the only one that can tell the
// two morph kinds apart.
// ===========================================================================
unittest
{
    Mesh m = makeTaggedGridMaps();
    auto ma = m.meshMap("MA");
    assert(ma !is null, "stand: MA must exist");
    const size_t b = 1 * 3;
    auto e = morphValuesEntry("MA", MapKind.morphAbsolute, [1u],
        [7.0f, 8.0f, 9.0f], [ma.data[b], ma.data[b+1], ma.data[b+2]],
        [cast(ubyte)1], [cast(ubyte)1]);
    auto d = oneEntry(e);

    // History drift: the map comes back with the SAME name, dim and domain,
    // and a different KIND. Both are Point/dim 3 and neither reserves a name,
    // so no other mechanism in the tree can tell them apart.
    assert(m.removeMeshMap("MA"), "stand: MA must be removable");
    auto mr2 = m.addMeshMapOfKind(MapKind.morphRelative, "MA");
    assert(mr2 !is null && mr2.dim == 3 && mr2.domain == MapDomain.Point,
        "stand: the replacement must be shape-IDENTICAL — that is the whole "
      ~ "cell; if it differed in dim or domain another term would refuse "
      ~ "first and this one would never be reached");
    const float[] untouched = mr2.data.dup;

    auto w = BindWatch.open();
    assert(d.revert(m), "W-K7: a refused entry must still answer true");
    assert(w.delta() == 1, format(
        "W-K7: mapDeltaBindRefused moved by %d, expected 1. Name, dim and "
      ~ "domain all still match, so `kind` is the ONLY term that refuses — "
      ~ "and without it a morphAbsolute's absolute POSITIONS land in a "
      ~ "relative channel and the vertex moves.", w.delta()));

    auto live = m.meshMap("MA");
    assert(live !is null && live.data == untouched,
        "W-K7: the refused entry wrote into the replacement map. A refusal "
      ~ "applies NOTHING — never partially, never zero-filled.");
}

// ===========================================================================
// W-K8 — the refusal is OBSERVED. A revert that refuses and answers `true`
// is indistinguishable from a correct restore on every plane; only the
// counter separates them.
// ===========================================================================
unittest
{
    Mesh m = makeTaggedGridMaps();
    auto ma = m.meshMap("MA");
    assert(ma !is null);
    const size_t b = 1 * 3;
    auto e = morphValuesEntry("MA", MapKind.morphAbsolute, [1u],
        [7.0f, 8.0f, 9.0f], [ma.data[b], ma.data[b+1], ma.data[b+2]],
        [cast(ubyte)1], [cast(ubyte)1]);
    auto d = oneEntry(e);

    assert(m.removeMeshMap("MA"), "the map is GONE between record and replay");
    const string pre = meshPlanesJson(m);

    auto w = BindWatch.open();
    const bool ok = d.revert(m);
    assert(ok,
        "W-K8: `revert` returned FALSE on a refused entry. A false revert is "
      ~ "not a quiet refusal — `Command.revert` fails, the funnel throws, and "
      ~ "the history entry is popped off BOTH stacks and lost. The channel "
      ~ "for 'this entry did nothing' is the counter, not the return value.");
    assert(w.delta() == 1, format(
        "W-K8: mapDeltaBindRefused moved by %d, expected 1. Without the tick "
      ~ "a refusal that answers true and moves nothing looks exactly like a "
      ~ "correct restore on every plane the dump reads.", w.delta()));
    assert(meshPlanesJson(m) == pre,
        "W-K8: the refused entry moved a plane anyway");
}

// ===========================================================================
// W-K9 / W-K9b — `owesTopologyBump`'s CREASE arm, and why the filter is
// NAME-**or**-kind.
// ===========================================================================
private ulong topoDeltaOf(ref Mesh m, ref MeshEditDelta d) {
    const ulong t0 = m.topologyVersion;
    assert(d.revert(m), "topoDeltaOf: revert must answer true");
    return m.topologyVersion - t0;
}

private MeshOpEntry creaseEntry(string name, MapKind kind, float before, float after) {
    MeshOpEntry e;
    e.kind          = MeshOpEntry.Kind.MapValueDelta;
    e.mapOp         = MeshOpEntry.MapOp.Values;
    e.mapAddr       = MeshOpEntry.MapAddressing.Listed;
    e.mapName       = name;
    e.mapDim        = 1;
    e.mapDomain     = MapDomain.Edge;
    e.mapKind       = kind;
    e.mapElemIdx    = [0u];
    e.mapValsBefore = [before];
    e.mapValsAfter  = [after];
    return e;
}

unittest // W-K9 — the classified crease map, three rows
{
    // ROW 1: a real change on the crease channel OWES the bump. A crease
    // weight is an input to the LIMIT SURFACE, and `topologyVersion` is the
    // subpatch-preview + GPU layout key — `Mesh.setCreaseWeight` carries the
    // bump explicitly for exactly this reason.
    {
        Mesh m = makeTaggedGridMaps();
        auto cw = m.meshMap(kCreaseWeightMapName);
        assert(cw !is null && cw.kind == MapKind.creaseWeight,
            "stand: the CLASSIFIED crease map must be there");
        auto d = oneEntry(creaseEntry(kCreaseWeightMapName, MapKind.creaseWeight,
                                      0.75f, cw.data[0]));
        const ulong got = topoDeltaOf(m, d);
        assert(got == 1, format(
            "W-K9 row 1: topologyVersion moved by %d on a crease undo, "
          ~ "expected 1. Without it the subpatch preview keeps a stale layout "
          ~ "key and the undone weight presents as 'does nothing'.", got));
        assert(m.meshMap(kCreaseWeightMapName).data[0] == 0.75f,
            "W-K9 row 1 non-vacuity: the entry did not write, so the bump "
          ~ "above is not attributable to a crease change");
    }
    // ROW 2: the SAME entry with before == after owes NOTHING. Every live
    // writer in this family guards on an actual flip, precisely so a no-op
    // gesture cannot force a preview rebuild and a GPU re-upload.
    {
        Mesh m = makeTaggedGridMaps();
        auto cw = m.meshMap(kCreaseWeightMapName);
        auto d = oneEntry(creaseEntry(kCreaseWeightMapName, MapKind.creaseWeight,
                                      cw.data[0], cw.data[0]));
        const ulong got = topoDeltaOf(m, d);
        assert(got == 0, format(
            "W-K9 row 2: a before == after crease entry bumped "
          ~ "topologyVersion by %d. The recorders guard only on an empty index "
          ~ "list, so a no-op entry IS representable.", got));
    }
    // ROW 3: a NON-crease map owes nothing, AND this row must survive the
    // mutation that deletes the crease arm. Without it the cell is satisfied
    // by "everything bumps".
    {
        Mesh m = makeTaggedGridMaps();
        auto e = morphValuesEntry("MR", MapKind.morphRelative, [6u],
                                  [1.0f, 2.0f, 3.0f], [4.0f, 5.0f, 6.0f],
                                  [cast(ubyte)1], [cast(ubyte)1]);
        auto d = oneEntry(e);
        const ulong got = topoDeltaOf(m, d);
        assert(got == 0, format(
            "W-K9 row 3: a MORPH undo bumped topologyVersion by %d. Only the "
          ~ "crease channel owes it; bumping for every map value undo re-uploads "
          ~ "the whole mesh on every UV edit.", got));
    }
}

unittest // W-K9b — the LEGACY crease map: named `crease`, kind `unclassified`
{
    // THE SHIPPED STAND CANNOT EXHIBIT THIS. `makeTaggedGridMaps` registers
    // its crease map through `addMeshMapOfKind`, so `kind` is SET and the
    // name-only path is never exercised. This cell therefore builds its own
    // map through the RAW `addMeshMap` door — which is what a pre-1069 `.v3d`
    // and every legacy caller produce. Do not "simplify" it back onto the
    // stand: that deletes the only cell where the disjunction matters.
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    m.buildLoops();
    auto cw = m.addMeshMap(kCreaseWeightMapName, 1, MapDomain.Edge);
    assert(cw !is null, "stand: the raw crease map must register");
    assert(cw.kind == MapKind.unclassified,
        "stand: a map created through the RAW door must read back "
      ~ "`unclassified` — that IS the legacy shape this cell is about");
    cw.data[0] = 0.25f;

    auto d = oneEntry(creaseEntry(kCreaseWeightMapName, MapKind.unclassified,
                                  0.9f, 0.25f));
    const ulong got = topoDeltaOf(m, d);
    assert(got == 1, format(
        "W-K9b: topologyVersion moved by %d on a LEGACY crease map's undo, "
      ~ "expected 1. The map is Edge / dim 1 / named `crease` and every other "
      ~ "term matches, so a filter written as `mapKind == creaseWeight` ALONE "
      ~ "answers false here and the subpatch preview keeps a stale layout key. "
      ~ "`MapKind.unclassified`'s own doc says every filter that excludes a "
      ~ "kind must be written NEGATIVELY, and `creaseWeightMap()` resolves the "
      ~ "channel BY NAME.", got));
}

// ===========================================================================
// W-K10 — `owesDisplayRefresh` + `finalize`'s quantified guard.
// ===========================================================================
unittest
{
    import core.exception : AssertError;

    Mesh m = makeTaggedGridMaps();
    // A batch declaring `Marks` ALONE. `Marks` is deliberately outside
    // `DisplayRefreshMask` (it would re-upload the whole mesh on every
    // selection click), so a map edit published under it is never redrawn —
    // the failure MEASURED at `mesh.d`'s `setFaceHiddenFrom`, where a
    // Marks-only hide left `/api/gpu/face-vbo`'s faceVertCount at 36.
    auto e = morphValuesEntry("MR", MapKind.morphRelative, [6u],
                              [1.0f, 2.0f, 3.0f], [4.0f, 5.0f, 6.0f],
                              [cast(ubyte)1], [cast(ubyte)1]);
    auto d = oneEntry(e, MeshEditScope.Marks);

    bool threw = false;
    string msg;
    try
        d.revert(m);
    catch (AssertError err) {
        threw = true;
        msg = err.msg;
    }
    assert(threw,
        "W-K10: a fast-path replay carrying a MapValueDelta published `Marks` "
      ~ "alone and said nothing. Either the kind's `owesDisplayRefresh` arm "
      ~ "answers false, or the guard is not quantified over it.");
    assert(msg.canFind("publish only Marks"), "the throw came from somewhere else: " ~ msg);

    // POTENCY CONTROL: the same entry under a class INSIDE the mask must NOT
    // throw. Without this row the cell is satisfied by a guard that aborts on
    // every fast-path replay.
    Mesh ok = makeTaggedGridMaps();
    auto d2 = oneEntry(e, MeshEditScope.Maps);
    assert(d2.revert(ok), "W-K10 control: `Maps` is inside DisplayRefreshMask "
                        ~ "and must replay cleanly");
}

// ===========================================================================
// W-K13 / W-K20 — `Create`, both addressings.
//
// The arm is FORWARD-FAITHFUL because a forward-replay consumer SHIPS:
// `commands/mesh/session_edit.d` does `if (useDelta_) delta_.apply(*mesh);`
// for redo, and `MeshSessionEdit` is the generic carrier many factories are
// built on. A reverse-faithful-only `Create` would redo into an EMPTY map —
// losing a morphAbsolute's dense base snapshot or a copied UV channel,
// silently, because the map exists with the right name and the right length.
// ===========================================================================
unittest // W-K13 — DefaultInit means DEFAULT, and it is READ, not inferred
{
    Mesh m = makeTaggedGridMaps();
    assert(m.meshMap("NEW") is null, "stand: the target name must be free");

    MeshOpEntry e;
    e.kind      = MeshOpEntry.Kind.MapValueDelta;
    e.mapOp     = MeshOpEntry.MapOp.Create;
    e.mapAddr   = MeshOpEntry.MapAddressing.DefaultInit;
    e.mapName   = "NEW";
    e.mapDim    = 3;
    e.mapDomain = MapDomain.Point;
    e.mapKind   = MapKind.morphRelative;
    auto d = oneEntry(e);

    assert(d.apply(m), "W-K13: apply must answer true");
    auto live = m.meshMap("NEW");
    assert(live !is null, "W-K13: the forward must REGISTER the map");
    assert(live.dim == 3 && live.domain == MapDomain.Point
        && live.kind == MapKind.morphRelative,
        "W-K13: the created map must carry the recorded shape");
    assert(live.data.length == m.vertices.length * 3,
        "W-K13: the created map must be sized to its domain");
    foreach (v; live.data)
        assert(v == 0.0f, "W-K13: a DefaultInit create must produce ZEROED data");
    assert(live.present.length == m.vertices.length,
        "W-K13: a presence-tracked kind must get its channel");
    foreach (p; live.present)
        assert(p == 0, "W-K13: a DefaultInit create must produce ABSENT presence");

    assert(d.revert(m), "W-K13: revert must answer true");
    assert(m.meshMap("NEW") is null,
        "W-K13: the reverse of a create must UN-REGISTER the map");
}

unittest // W-K20 — a WholeArray create replays its CONTENT forward
{
    Mesh m = makeTaggedGridMaps();
    const size_t nv = m.vertices.length;

    // A dense base snapshot, the shape `mesh.morph.create` produces for the
    // absolute kind: an entry per vertex, every one PRESENT.
    auto data    = new float[](nv * 3);
    auto present = new ubyte[](nv);
    foreach (i; 0 .. nv) {
        data[i * 3 + 0] = m.vertices[i].x + 0.5f;
        data[i * 3 + 1] = m.vertices[i].y + 0.5f;
        data[i * 3 + 2] = m.vertices[i].z + 0.5f;
        present[i] = 1;
    }

    MeshOpEntry e;
    e.kind         = MeshOpEntry.Kind.MapValueDelta;
    e.mapOp        = MeshOpEntry.MapOp.Create;
    e.mapAddr      = MeshOpEntry.MapAddressing.WholeArray;
    e.mapName      = "MB";
    e.mapDim       = 3;
    e.mapDomain    = MapDomain.Point;
    e.mapKind      = MapKind.morphAbsolute;
    e.mapValsAfter = data;
    e.presentAfter = present;
    auto d = oneEntry(e);

    assert(d.apply(m), "W-K20: apply must answer true");
    auto live = m.meshMap("MB");
    assert(live !is null, "W-K20: the forward must register the map");
    assert(live.data == data, format(
        "W-K20: the FORWARD replay of a filled create produced different data. "
      ~ "The map exists with the right name, domain, dim and LENGTH — only its "
      ~ "contents are wrong, and for a morphAbsolute map all-zeros with "
      ~ "all-absent presence means every vertex 'stays at the base'. This is "
      ~ "the path session_edit.d takes for REDO."));
    assert(live.present == present,
        "W-K20: the forward replay dropped the PRESENCE channel");
    bool anyNonZero = false;
    foreach (v; live.data) if (v != 0.0f) { anyNonZero = true; break; }
    assert(anyNonZero,
        "W-K20 non-vacuity: the carried content is all zeros, which is what a "
      ~ "default-init create produces too — the cell could not tell them apart");

    assert(d.revert(m), "W-K20: revert must answer true");
    assert(m.meshMap("MB") is null, "W-K20: the reverse must un-register");
}

// ===========================================================================
// W-K14 / W-K18 — addressing and the presence bind are never INFERRED.
// ===========================================================================
unittest // W-K14 — a `Listed` entry with no indices is REFUSED, not "all"
{
    Mesh m = makeTaggedGridMaps();
    auto mr = m.meshMap("MR");
    assert(mr !is null);
    const float[] untouched = mr.data.dup;

    auto e = morphValuesEntry("MR", MapKind.morphRelative, [6u],
                              [1.0f, 2.0f, 3.0f], [4.0f, 5.0f, 6.0f],
                              [cast(ubyte)1], [cast(ubyte)1]);
    e.mapElemIdx = null;            // the index list is DROPPED
    auto d = oneEntry(e);

    auto w = BindWatch.open();
    assert(d.revert(m), "W-K14: a refused entry still answers true");
    assert(w.delta() == 1, format(
        "W-K14: mapDeltaBindRefused moved by %d, expected 1. If "
      ~ "`mapElemIdx.length == 0` were read as 'all elements', a DROPPED "
      ~ "index list would silently rewrite the ENTIRE map with this entry's "
      ~ "values — a legal wrong answer on every plane.", w.delta()));
    assert(m.meshMap("MR").data == untouched,
        "W-K14: the refused entry wrote into the map anyway");
}

unittest // W-K18 — the LIVE presence channel's own length is a bind term
{
    Mesh m = makeTaggedGridMaps();
    auto ma = m.meshMap("MA");
    assert(ma !is null);
    const size_t b = 1 * 3;
    auto e = morphValuesEntry("MA", MapKind.morphAbsolute, [1u],
        [7.0f, 8.0f, 9.0f], [ma.data[b], ma.data[b+1], ma.data[b+2]],
        [cast(ubyte)1], [cast(ubyte)0]);
    auto d = oneEntry(e);

    // The LIVE channel is emptied — which on a `MeshMap` is not "broken", it
    // is the legal value meaning "every element is present".
    ma.present = null;
    const float[] untouched = ma.data.dup;

    auto w = BindWatch.open();
    assert(d.revert(m), "W-K18: a refused entry still answers true");
    assert(w.delta() == 1, format(
        "W-K18: mapDeltaBindRefused moved by %d, expected 1. Without the "
      ~ "`live.present.length == elementCount(domain)` term the restore writes "
      ~ "`data`, guards `i < present.length` on an EMPTY array, and drops the "
      ~ "presence half with every other length compare still passing and no "
      ~ "counter moving. `data` then compares equal to the recorded values, so "
      ~ "W-K5 does not see it either.", w.delta()));
    assert(m.meshMap("MA").data == untouched,
        "W-K18: the refused entry wrote into `data` anyway — a refusal applies "
      ~ "NOTHING, it is not a partial restore");
}

// ===========================================================================
// W-K19 — `Rename` and `Remove`'s own bind terms. Three rows, three
// different failures, none of which any other term catches.
// ===========================================================================
private MeshOpEntry renameEntry(string from, string to, ubyte dim,
                                MapDomain dom, MapKind kind) {
    MeshOpEntry e;
    e.kind      = MeshOpEntry.Kind.MapValueDelta;
    e.mapOp     = MeshOpEntry.MapOp.Rename;
    e.mapAddr   = MeshOpEntry.MapAddressing.DefaultInit;
    e.mapName   = from;
    e.mapNameTo = to;
    e.mapDim    = dim;
    e.mapDomain = dom;
    e.mapKind   = kind;
    return e;
}

unittest // W-K19a — a DUPLICATE source name refuses
{
    Mesh m = makeTaggedGridMaps();
    // Forge the duplicate directly: `addMeshMap` refuses one, which is why a
    // duplicate can only arrive through a raw registry write or a file — and
    // why the rename arm cannot assume it away.
    auto src = m.meshMap("MR");
    assert(src !is null);
    m.meshMaps ~= src.dup;
    size_t matches = 0;
    foreach (ref mm; m.meshMaps) if (mm.name == "MR") ++matches;
    assert(matches == 2, "stand: the duplicate must actually exist");

    auto d = oneEntry(renameEntry("MR", "MR_RENAMED", 3, MapDomain.Point,
                                  MapKind.morphRelative));
    auto w = BindWatch.open();
    assert(d.apply(m), "W-K19a: a refused entry still answers true");
    assert(w.delta() == 1, format(
        "W-K19a: mapDeltaBindRefused moved by %d, expected 1. `Mesh.meshMap()` "
      ~ "and `Mesh.removeMeshMap()` each take the FIRST name match, so with a "
      ~ "duplicate present a rename picks one arbitrarily and leaves the other "
      ~ "permanently unreachable.", w.delta()));
    assert(m.meshMap("MR_RENAMED") is null, "W-K19a: nothing may be renamed");
}

unittest // W-K19b — a TAKEN target name refuses
{
    Mesh m = makeTaggedGridMaps();
    assert(m.meshMap("MA") !is null && m.meshMap("MR") !is null);
    auto d = oneEntry(renameEntry("MR", "MA", 3, MapDomain.Point,
                                  MapKind.morphRelative));
    auto w = BindWatch.open();
    assert(d.apply(m), "W-K19b: a refused entry still answers true");
    assert(w.delta() == 1, format(
        "W-K19b: mapDeltaBindRefused moved by %d, expected 1. Names are unique "
      ~ "per mesh and the shipped rename command THROWS on a taken target; "
      ~ "this arm must not quietly undercut it.", w.delta()));
    auto ma = m.meshMap("MA");
    assert(ma !is null && ma.kind == MapKind.morphAbsolute,
        "W-K19b: the existing map must be untouched");
    assert(m.meshMap("MR") !is null, "W-K19b: the source must keep its name");
}

unittest // W-K19c — a `Remove` reverse at the MAX_MESH_MAPS ceiling refuses
{
    Mesh m = makeGridPlane(3);
    m.resetSelection();
    m.buildLoops();

    // The entry: a map that was removed, whose reverse must re-register it.
    MeshOpEntry e;
    e.kind          = MeshOpEntry.Kind.MapValueDelta;
    e.mapOp         = MeshOpEntry.MapOp.Remove;
    e.mapAddr       = MeshOpEntry.MapAddressing.WholeArray;
    e.mapName       = "GONE";
    e.mapDim        = 1;
    e.mapDomain     = MapDomain.Point;
    e.mapKind       = MapKind.vertexWeight;
    e.mapValsBefore = new float[](m.vertices.length);
    auto d = oneEntry(e);

    // Fill the registry to its ceiling, so the re-registration cannot succeed.
    size_t made = 0;
    while (m.meshMaps.length < MAX_MESH_MAPS) {
        auto p = m.addMeshMap(format("fill%d", made), 1, MapDomain.Point);
        assert(p !is null, "stand: the filler maps must register");
        ++made;
    }
    assert(m.meshMaps.length == MAX_MESH_MAPS,
        "stand: the registry must be AT the ceiling, or the reverse succeeds "
      ~ "and this cell measures nothing");

    auto w = BindWatch.open();
    assert(d.revert(m), "W-K19c: a refused entry still answers true");
    assert(w.delta() == 1, format(
        "W-K19c: mapDeltaBindRefused moved by %d, expected 1. `addMeshMap` "
      ~ "returns NULL at the MAX_MESH_MAPS ceiling: a reverse that "
      ~ "dereferences it crashes, and one that ignores it restores nothing "
      ~ "and answers true.", w.delta()));
    assert(m.meshMap("GONE") is null, "W-K19c: nothing may have been registered");
}

// ===========================================================================
// The `MeshEditBatch.recordMapValueDiff` door — the post-hoc recorder for
// kernels that have already written the map.
// ===========================================================================
unittest // it records what a foreign writer did, and pays NOTHING when off
{
    // ---- the UNRECORDED path costs nothing and records nothing -------------
    {
        Mesh m = makeTaggedGridMaps();
        auto before = m.meshMap("MR").data.dup;
        auto ed = MeshEditBatch.unrecorded(m, MeshEditScope.Maps);
        m.meshMap("MR").data[0] = 42.0f;      // a foreign writer
        assert(!ed.recordMapValueDiff("MR", before, m.meshMap("MR").present),
            "the unrecorded path must record nothing — the early-out precedes "
          ~ "every allocation and the O(N) compare, which is what keeps the "
          ~ "redo and preview arms free");
        ed.close();
    }

    // ---- the RECORDED path: one entry, and it round-trips ------------------
    Mesh m = makeTaggedGridMaps();
    const float[] pre = m.meshMap("MR").data.dup;
    const ubyte[] preP = m.meshMap("MR").present.dup;
    MeshEditDelta d;
    bool whole = true;
    {
        auto ed = MeshEditBatch(m, MeshEditScope.Maps);
        // A foreign writer: three components on one vertex, through the raw
        // array exactly as `uvRelax` / `applyUvAffine` / `uvUnwrap` do.
        auto live = m.meshMap("MR");
        live.data[6 * 3 + 0] = 1.25f;
        live.data[6 * 3 + 1] = -2.5f;
        live.data[6 * 3 + 2] = 3.75f;
        live.present[6] = 1;
        // `MeshEditScope.Maps` is passed EXPLICITLY since Stage L1-b made the
        // publish class a parameter: every command that calls this primitive
        // already publishes something of its own, and the class had to stop
        // being hard-coded so the recorded arm's stamp could equal the redo
        // and hatch arms'. `Maps` is still the default and is what this cell
        // was written against.
        assert(ed.recordMapValueDiff("MR", pre, preP, MeshEditScope.Maps, &whole),
            "the diff recorder must record a real write — an anti-vacuity "
          ~ "assert, because everything below is about WHAT it recorded");
        d = ed.close();
    }
    assert(!whole, "one moved element out of a whole map must choose the "
                 ~ "SPARSE spelling; that choice is the measurement 2210's "
                 ~ "harness printed, which is why it is reported at all");
    assert(d.log.length == 1, format(
        "the diff recorder must produce exactly ONE entry, got %d", d.log.length));
    assert(d.log[0].kind == MeshOpEntry.Kind.MapValueDelta
        && d.log[0].mapOp == MeshOpEntry.MapOp.Values
        && d.log[0].mapAddr == MeshOpEntry.MapAddressing.Listed,
        "the diff recorder produced the wrong entry shape");
    assert(d.log[0].mapElemIdx == [6u],
        "the diff recorder must list exactly the element that moved");

    assert(d.revert(m), "the recorded entry must revert");
    assert(m.meshMap("MR").data == pre,
        "the diff recorder's entry did not restore the value plane");
    assert(m.meshMap("MR").present == preP,
        "the diff recorder's entry did not restore the presence plane");

    // ---- a write that changes nothing records nothing ----------------------
    {
        Mesh q = makeTaggedGridMaps();
        const float[] qp = q.meshMap("MR").data.dup;
        const ubyte[] qpp = q.meshMap("MR").present.dup;
        auto ed = MeshEditBatch(q, MeshEditScope.Maps);
        assert(!ed.recordMapValueDiff("MR", qp, qpp),
            "a diff over an UNCHANGED map must record no entry — an empty "
          ~ "entry is a shape the replay can only refuse");
        auto dd = ed.close();
        assert(dd.log.length == 0, "and it must leave the log empty");
    }
}
