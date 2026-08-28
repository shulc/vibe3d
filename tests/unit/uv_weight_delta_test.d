// uv_weight_delta_test — task 1903 Stage L1-b. The witnesses for the SIXTEEN
// classes that moved onto `MeshOpEntry.Kind.MapValueDelta` in this stage:
// `weightmap.d` (4 of its 5 — `WeightmapSelect` is `CmdFlags.UI` and writes no
// mesh state), `uv_map_util.d` (4) and the FIVE UV VALUE files (8:
// uv_transform 3, uv_pack 2, uv_project 1, uv_relax 1, uv_unwrap 1).
//
// THERE IS NO SIXTH VALUE FILE. The plan and the brief both say "the six UV
// value files"; the tree holds SIX uv command files in total, one of which
// (`uv_map_util.d`) is this stage's registry group. The five that remain carry
// all eight value classes, which is the number the plan itself states two
// lines later. Recorded here rather than silently obeyed.
//
// LANE U (`dub test --config=tests`) ONLY. `./run_test.d` links the prebuilt
// archive and never RUNS a `source/**` or `tests/unit/**` unittest block, so a
// cell placed there instead of here is a cell that cannot redden. The only
// rows this stage owns in lane S are the three `/api/changes` counters
// (`tests/test_map_delta_counters.d`), which Stage L1-a made real.
//
// ===========================================================================
// WHAT EACH GROUP CAN SHOW THAT THE OTHERS CANNOT
// ===========================================================================
// `morph.d` went first because it is the only group whose PRESENCE channel
// changes, the only one with two shape-identical kinds, and the only one with
// a position write. None of that is repeated here. What IS here is what those
// cells could not see:
//
//   C — `weightmap.d`. The forward writes ONE float (mode A's extreme, 12
//       bytes of arrays against a 20.81 MB whole-mesh capture), and it is the
//       only group whose `commitChange` is DELEGATED into a `Mesh` setter, so
//       the batch has to DEFER a publish the command never makes itself.
//   D — `uv_map_util.d`. `uv.copy` CREATES its target, so its undo owes a map
//       REMOVAL and its redo owes the CONTENT; and `uv.clear`'s forward result
//       is ALL ZEROS, which makes a zero-filling revert indistinguishable from
//       a correct one ON THE FORWARD IMAGE — Stage F1's measured failure in
//       its purest form.
//   E — the five value files. They are the family's only POST-HOC recorders
//       (`recordMapValueDiff` diffs the finished map), which brings three
//       failures nothing else in L1 has: a forward that succeeds while moving
//       NOTHING (an empty delta whose `revert()` must still answer true, or
//       `CommandHistory.undo` discards the entry and its whole trailing
//       suffix — regression 0099); a hybrid that records `Create` or `Values`
//       depending on a branch; and, in `uv.unwrap` alone, a kernel refusal
//       that arrives AFTER a write and must be rolled back by hand.
//
// EVERY CELL MEASURES AN ARMED REVERT, never a forward. Stage F1 measured a
// revert that restored a map's LENGTH while zeroing all its values and
// answered `true`; a forward-only check is green on that. Each cell therefore
// asserts `recordedUndo().armed()` and the log's SHAPE before it asserts
// anything about planes — a command that recorded NOTHING falls back to its
// `MeshSnapshot` and restores every plane correctly, which would make every
// plane assertion here green over a deleted recorder.
//
// THE REGISTRY ORDER OF THE STAND, measured and used by three cells below:
//     0 uv   1 W   2 uv2   3 crease   4 MA   5 MR
// so `mesh.weightmap.remove W` and `uv.delete uv2` both remove a map that is
// NOT last — which is what makes `MeshOpEntry.mapSlot` load-bearing for them.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score mutations per
// cell, in isolation.
// ===========================================================================
module tests.unit.uv_weight_delta_test;

import std.format : format;
import std.json   : parseJSON;

import mesh;
import view;
import editmode;
import change_bus : changeBus;
import http_json  : meshPlanesJson, PlaneDumpMeta;
import mesh_edit_delta : MeshOpEntry;

import command;
import commands.mesh.weightmap    : WeightmapCreate, WeightmapRemove,
                                    WeightmapRename, WeightmapSet;
import commands.mesh.uv_map_util  : UvDelete, UvRename, UvCopy, UvClear;
import commands.mesh.uv_transform : UvFlip, UvMirror, UvRotate;
import commands.mesh.uv_pack      : UvFit, UvPack;
import commands.mesh.uv_project   : UvProject;
import commands.mesh.uv_relax     : UvRelax;
import commands.mesh.uv_unwrap    : UvUnwrap;

import tests.unit.fixtures : makeTaggedGridMaps;
import tests.unit.undo_parity_l0_test : comparePlanes, setS, setI, setF;

private Mesh* stand() {
    auto m = new Mesh;
    *m = makeTaggedGridMaps(3);
    m.buildLoops();
    return m;
}

private View freshView() { return new View(0, 0, 800, 600); }

private string dump(Mesh* m) {
    return meshPlanesJson(*m, PlaneDumpMeta("", "delta", "uv_weight",
                                            "makeTaggedGridMaps(3)"));
}

/// Assert every plane of `after` equals every plane of `before`, NAMING the
/// first that differs. Reuses the frozen oracle's own comparator, so a
/// mutation here reddens with the message shape that fixture produces.
private void planesEqual(string cell, string before, string after) {
    auto b = parseJSON(before);
    comparePlanes("<in-memory pre-op dump>", cell, "postUndo", b, after);
}

/// The one map entry a delta must carry. Fails loudly rather than returning a
/// default, because "no entry" is the shape a deleted recorder takes and every
/// plane assertion downstream is green on it.
private MeshOpEntry oneMapEntry(string cell, const(MeshOpEntry)[] log,
                                MeshOpEntry.MapOp wantOp) {
    assert(log.length == 1, format(
        "%s: the recorded delta holds %d entries, expected exactly 1. A "
      ~ "command that records NOTHING falls back to its MeshSnapshot and "
      ~ "restores every plane correctly, so every assertion below this line "
      ~ "is green over a deleted recorder.", cell, log.length));
    assert(log[0].kind == MeshOpEntry.Kind.MapValueDelta, format(
        "%s: the entry is %s, expected MapValueDelta.", cell, log[0].kind));
    assert(log[0].mapOp == wantOp, format(
        "%s: the entry's arm is %s, expected %s.", cell, log[0].mapOp, wantOp));
    return cast(MeshOpEntry) log[0];
}

private struct CounterSnap { ulong mix, refused, bind; }
private CounterSnap counters() {
    return CounterSnap(changeBus.mapDeltaMixRecorded,
                       changeBus.mapDeltaMixRefused,
                       changeBus.mapDeltaBindRefused);
}
/// The three seam counters, as DELTAS — absolutes are process-cumulative and
/// this binary runs many cells.
private void countersUnmoved(string cell, CounterSnap b) {
    const a = counters();
    assert(a.mix == b.mix, format(
        "%s: mapDeltaMixRecorded moved by %d — the recorder saw a map entry "
      ~ "beside an index-space-moving one, which is always a bug in the "
      ~ "command being written.", cell, a.mix - b.mix));
    assert(a.refused == b.refused, format(
        "%s: mapDeltaMixRefused moved by %d — a replay SKIPPED map entries, "
      ~ "so the undo restored less than it reported.", cell, a.refused - b.refused));
    assert(a.bind == b.bind, format(
        "%s: mapDeltaBindRefused moved by %d — an entry could not bind its "
      ~ "map at replay and applied NOTHING while answering true.",
        cell, a.bind - b.bind));
}

// ===========================================================================
// C1 — `mesh.weightmap.set`: ONE element, `Listed`, and an ARMED revert that
// lands on the pre-op planes.
//
// WHY THE ADDRESSING IS ASSERTED AND NOT JUST THE RESULT. This command is
// mode A's extreme in the whole family: 4 bytes of index plus 4 of value each
// way — 12 bytes of arrays — against the 20.81 MB whole-mesh capture it
// replaces (task 2210). Route it through the post-hoc diff door instead and
// every plane assertion below stays green while the payload becomes two whole
// images of the map. The addressing row is the only thing that sees that.
//
// MUTATION: replace the `recordMapValuesOwned` call in `WeightmapSet.setKernel`
// with `ed.recordMapValueDiff(name_, pre, null, MeshEditScope.Material)` over a
// `map.data.dup` — the result is identical and the addressing row reddens.
// ===========================================================================
unittest {
    auto m = stand();
    const before = dump(m);
    const c0 = counters();

    auto v = freshView();
    auto c = new WeightmapSet(m, v, EditMode.Vertices);
    setS(c, "name", "W"); setI(c, "vert", 6); setF(c, "weight", 0.875f);
    assert(c.apply(), "C1: the forward must apply on this stand");
    assert(c.recordedUndo().armed(), "C1: nothing was recorded, so the revert "
                                   ~ "below would be a MeshSnapshot restore");
    auto e = oneMapEntry("C1", c.recordedUndo().delta().log,
                         MeshOpEntry.MapOp.Values);

    assert(e.mapAddr == MeshOpEntry.MapAddressing.Listed, format(
        "C1: the entry addresses `%s`, expected `Listed`. A one-element write "
      ~ "recorded as a whole-array rewrite carries two full images of the map "
      ~ "instead of twelve bytes — the whole of mode A's advantage, thrown "
      ~ "away with no visible change in behaviour.", e.mapAddr));
    assert(e.mapElemIdx == [6u], format(
        "C1: the entry lists elements %s, expected exactly [6].", e.mapElemIdx));
    assert(e.mapValsBefore.length == 1 && e.mapValsAfter.length == 1, format(
        "C1: the entry carries %d before / %d after floats for a dim-1 map "
      ~ "with one listed element.", e.mapValsBefore.length, e.mapValsAfter.length));
    assert(e.mapValsAfter[0] == 0.875f, format(
        "C1: the AFTER image reads %s; it must be read back from the LIVE map "
      ~ "after the setter ran, not reconstructed from the command's own "
      ~ "parameter.", e.mapValsAfter[0]));

    assert(c.revert(), "C1: the undo must succeed");
    planesEqual("C1", before, dump(m));
    countersUnmoved("C1", c0);
}

// ===========================================================================
// C2 — THE DELEGATED COMMIT, and this group is the only one that has one.
// `setVertexWeight` -> `setMeshMapValue` publishes `Material` ITSELF, per
// element; the batch defers those into ONE stamp at `close()`. So the command
// must add no `commitChange` of its own — and, separately, the whole migration
// must not have changed WHICH class this family publishes.
//
// THE CLASS IS A DECISION, RECORDED HERE SO IT CANNOT DRIFT SILENTLY. `Maps`
// exists and would arguably be the better class for a map write, but
// reclassifying a publisher moves `ChangeBus.docRevision()` — the
// unsaved-changes asterisk and the quit-time save prompt — and
// `MeshEditScope.Maps`'s own doc says the pre-existing `setMeshMapValue`
// publishers keep `Material` precisely so no existing consumer changes
// behaviour. Stage L1-b therefore preserves each command's class exactly and
// leaves the reclassification as the open question it already was (Q-L1-3).
//
// MUTATION (a): add `ed.commitChange(MeshEditScope.Material);` at the end of
// `WeightmapSet.setKernel` — a second deferred flag is free, so this row stays
// green and that is HONEST: inside a batch the double publish is invisible.
// What it catches is the migration that forgets the batch. MUTATION (b): drop
// the `MeshEditScope.Material` argument from any `recordMapValueDiff` call in
// the UV files, letting it fall back to its `Maps` default -> the `Maps` row in
// E5 reddens. Both are named where they redden; this cell owns (a)'s honest
// half — that the family publishes ONE class, ONCE.
// ===========================================================================
unittest {
    auto m = stand();
    const mat0 = changeBus.totalMaterial, map0 = changeBus.totalMaps;

    auto v = freshView();
    auto c = new WeightmapSet(m, v, EditMode.Vertices);
    setS(c, "name", "W"); setI(c, "vert", 6); setF(c, "weight", 0.5f);
    assert(c.apply(), "C2: the forward must apply");

    const dMat = changeBus.totalMaterial - mat0;
    const dMap = changeBus.totalMaps - map0;
    assert(dMat == 1, format(
        "C2: `mesh.weightmap.set` published Material %d time(s), expected "
      ~ "exactly 1. `setMeshMapValue` publishes per ELEMENT and the batch is "
      ~ "what folds that into one stamp — a migration that writes through the "
      ~ "setter WITHOUT an open batch publishes once per element, and one that "
      ~ "adds its own commitChange outside the batch publishes twice.", dMat));
    assert(dMap == 0, format(
        "C2: it also published Maps %d time(s). This family has always "
      ~ "published `Material`; moving it to `Maps` changes what "
      ~ "ChangeBus.docRevision() counts, i.e. the unsaved-changes asterisk, "
      ~ "and is carried as the open question Q-L1-3 rather than taken as a "
      ~ "migration side effect.", dMap));
}

// ===========================================================================
// C3 — THE REGISTRY SLOT, `mesh.weightmap.remove`. `removeMeshMap` SPLICES and
// the reverse's re-registration APPENDS, so without the slot the map comes
// back at the END of `meshMaps`. `meshPlanesJson` reads that array in ORDER
// and `MeshSnapshot.restore` put it back whole, so the migration would restore
// LESS than the snapshot did.
//
// MEASURED, not predicted: with `slot = uint.max` the frozen oracle reddens on
// `[mesh.weightmap.remove/postUndo]: plane 'meshMaps' differs`, first
// difference at character 1139 — index 1 holding `uv2`'s dim-2 data where
// `W`'s dim-1 data belongs.
//
// MUTATION: `slot = mapSlotOf(&ed.mesh(), name_);` -> `slot = uint.max;` in
// `WeightmapRemove.removeKernel`. Reddens this cell AND the oracle; run in
// isolation.
// ===========================================================================
unittest {
    auto m = stand();
    assert(m.meshMaps.length > 2 && m.meshMaps[1].name == "W", format(
        "C3: this cell needs `W` to sit at index 1 with maps after it, or "
      ~ "'restored at the right index' and 'appended at the end' are the same "
      ~ "answer and the cell cannot fail. Registry: %s",
        () { string[] n; foreach (ref mm; m.meshMaps) n ~= mm.name; return n; }()));
    const before = dump(m);
    const c0 = counters();

    auto v = freshView();
    auto c = new WeightmapRemove(m, v, EditMode.Vertices);
    setS(c, "name", "W");
    assert(c.apply(), "C3: the forward must apply");
    assert(c.recordedUndo().armed(), "C3: nothing was recorded");
    auto e = oneMapEntry("C3", c.recordedUndo().delta().log,
                         MeshOpEntry.MapOp.Remove);
    assert(e.mapSlot == 1, format(
        "C3: the entry recorded slot %d, expected 1 — the index `W` occupied "
      ~ "in `meshMaps` BEFORE the splice. `uint.max` means 'append', which "
      ~ "restores the map's CONTENT and loses its POSITION.", e.mapSlot));
    assert(e.mapValsBefore.length == 16, format(
        "C3: the entry carries %d before-floats; a dim-1 Point map on a "
      ~ "16-vertex stand must carry 16, or the reverse re-registers a map of "
      ~ "the wrong length and is refused whole.", e.mapValsBefore.length));

    assert(c.revert(), "C3: the undo must succeed");
    assert(m.meshMaps[1].name == "W", format(
        "C3: after the undo index 1 of `meshMaps` holds `%s`, expected `W`. "
      ~ "The map came back with the right content at the wrong POSITION — a "
      ~ "plane `meshPlanesJson` prints, `.v3d` writes and export reads.",
        m.meshMaps[1].name));
    planesEqual("C3", before, dump(m));
    countersUnmoved("C3", c0);
}

// ===========================================================================
// C4 — THE PRESENCE CHANNEL IS READ OFF THE KIND, and for this family that
// means it must be EMPTY.
//
// `MeshMap.present.length == 0` MEANS "every element is present", so the
// channel is the one plane in this family that a length compare cannot see.
// `patchMapValuesWrite` therefore refuses outright a `Listed` entry that
// carries presence arrays for a kind whose `kindInfo(...).tracksPresence` is
// false — and a refusal applies NOTHING while `revert()` still answers true.
// So this cell asserts both halves: the arrays are empty, and the replay did
// not refuse.
//
// MUTATION: in `WeightmapSet.setKernel`, `tracks ? [presBefore] : null` ->
// `[presBefore]` (and the same for `presAfter`). The entry then carries a
// one-byte channel a `vertexWeight`/`unclassified` map must not have, the bind
// refuses, `mapDeltaBindRefused` moves by 1, and the map keeps its POST-op
// value while the undo reports success — the F1 shape.
// ===========================================================================
unittest {
    auto m = stand();
    assert(!kindInfo(m.meshMap("W").kind).tracksPresence,
        "C4: `W` must be a kind that does NOT track presence, or this cell is "
      ~ "asserting the wrong contract");
    const wBefore = m.meshMap("W").data.dup;
    const c0 = counters();

    auto v = freshView();
    auto c = new WeightmapSet(m, v, EditMode.Vertices);
    setS(c, "name", "W"); setI(c, "vert", 6); setF(c, "weight", 0.875f);
    assert(c.apply(), "C4: the forward must apply");
    assert(m.meshMap("W").data != wBefore,
        "C4: the forward changed nothing, so the revert below cannot "
      ~ "distinguish a restore from a no-op");
    auto e = oneMapEntry("C4", c.recordedUndo().delta().log,
                         MeshOpEntry.MapOp.Values);
    assert(e.presentBefore.length == 0 && e.presentAfter.length == 0, format(
        "C4: the entry carries %d/%d presence bytes for a kind that does not "
      ~ "track presence. `patchMapValuesWrite` refuses such an entry WHOLE, "
      ~ "so the undo would apply nothing and still answer true.",
        e.presentBefore.length, e.presentAfter.length));

    assert(c.revert(), "C4: the undo must succeed");
    countersUnmoved("C4", c0);   // the bind must NOT have refused
    assert(m.meshMap("W").data == wBefore,
        "C4: the undo did not restore the weight values");
}

// ===========================================================================
// C5 — `mesh.weightmap.create` is `Create`/`DefaultInit`, carrying NO array,
// and BOTH directions are faithful.
//
// This is the half of the create split `morph.d` could not use: its ABSOLUTE
// kind is created DENSE, so its content has to ride. A weight map is created
// zero-filled with no presence channel, which is exactly what `mapRegister`
// reproduces from the kind alone — so `DefaultInit` is faithful FORWARD as
// well as backward, and carrying the arrays would pay a payload for content
// that is definitionally zeros.
//
// The forward replay is driven for real, because `MeshSessionEdit`
// (`session_edit.d:140`) replays a delta FORWARD for redo — "redo re-runs the
// kernel" is true of a Command and false of that carrier.
//
// MUTATION: swap `recordMapCreate` for `recordMapCreateFilledOwned(..., m.data.dup,
// m.present.dup)` — the addressing row reddens while every behavioural
// assertion below stays green, which is the point of asserting the shape.
// ===========================================================================
unittest {
    auto m = stand();
    const before = dump(m);
    const c0 = counters();

    auto v = freshView();
    auto c = new WeightmapCreate(m, v, EditMode.Vertices);
    setS(c, "name", "W2");
    assert(c.apply(), "C5: the forward must apply");
    auto made = m.meshMap("W2");
    assert(made !is null && made.kind == MapKind.vertexWeight, format(
        "C5: the forward must register a CLASSIFIED weight map (kind %s)",
        made is null ? MapKind.unclassified : made.kind));
    auto e = oneMapEntry("C5", c.recordedUndo().delta().log,
                         MeshOpEntry.MapOp.Create);
    assert(e.mapAddr == MeshOpEntry.MapAddressing.DefaultInit, format(
        "C5: the entry addresses `%s`, expected `DefaultInit` — the content "
      ~ "`addMeshMapOfKind` produces, carried as nothing at all.", e.mapAddr));
    assert(e.mapValsAfter.length == 0 && e.presentAfter.length == 0, format(
        "C5: a DefaultInit create carries %d floats and %d presence bytes; it "
      ~ "must carry none, or the row leaves mode A for no gain.",
        e.mapValsAfter.length, e.presentAfter.length));

    // FORWARD replay onto a fresh stand — the redo path `MeshSessionEdit` takes.
    auto m2 = stand();
    assert(c.recordedUndo().delta().apply(*m2), "C5: the forward replay must run");
    auto again = m2.meshMap("W2");
    assert(again !is null, "C5: the forward replay must REGISTER the map");
    assert(again.kind == MapKind.vertexWeight && again.dim == 1
        && again.domain == MapDomain.Point, format(
        "C5: the replay produced kind=%s dim=%d domain=%s — `mapRegister` must "
      ~ "take the CLASSIFIED door for a kind that declares a shape, or the "
      ~ "map comes back `unclassified` and no longer answers to "
      ~ "`mapNamesOfKind`.", again.kind, again.dim, again.domain));
    assert(again.data.length == m2.vertices.length, format(
        "C5: the replayed map holds %d floats for %d vertices",
        again.data.length, m2.vertices.length));
    foreach (x; again.data)
        assert(x == 0.0f, "C5: a DefaultInit create must replay ZERO-filled");

    assert(c.revert(), "C5: the undo must succeed");
    assert(m.meshMap("W2") is null, "C5: the undo must un-register the map");
    planesEqual("C5", before, dump(m));
    countersUnmoved("C5", c0);
}

// ===========================================================================
// D1 — `uv.clear`, AND IT IS THE FAMILY'S PUREST F1 CELL.
//
// The forward result of a clear is ALL ZEROS. So a revert that zero-fills —
// Stage F1 measured exactly that: a map's LENGTH restored, all 48 values
// zeroed, 36 of them non-zero before, and `true` returned — is
// indistinguishable from a correct one ON THE FORWARD IMAGE, and equally
// indistinguishable from it on any length compare. Only comparing the
// RESTORED values against the PRE-OP ones separates them, and only if the
// pre-op values were not zeros to begin with. Both halves are asserted.
//
// MUTATION: in `UvClear.clearKernel`, pass `m.data.dup` (the post-clear image)
// where `before` belongs. Every length still matches, the entry still binds,
// the undo still answers true — and the map comes back zeroed.
// ===========================================================================
unittest {
    auto m = stand();
    const uvBefore = m.meshMap("uv").data.dup;
    size_t nonZero = 0;
    foreach (x; uvBefore) if (x != 0.0f) ++nonZero;
    assert(nonZero >= 8, format(
        "D1: the stand's `uv` map holds only %d non-zero values — a zero-fill "
      ~ "revert would then be indistinguishable from a correct one and this "
      ~ "cell could not fail.", nonZero));
    const before = dump(m);
    const c0 = counters();

    auto v = freshView();
    auto c = new UvClear(m, v, EditMode.Polygons);
    setS(c, "name", "uv");
    assert(c.apply(), "D1: the forward must apply");
    foreach (x; m.meshMap("uv").data)
        assert(x == 0.0f, "D1: the forward must leave the map all zeros");
    auto e = oneMapEntry("D1", c.recordedUndo().delta().log,
                         MeshOpEntry.MapOp.Values);
    assert(e.mapAddr == MeshOpEntry.MapAddressing.WholeArray, format(
        "D1: the entry addresses `%s`, expected `WholeArray`. Every corner of "
      ~ "a non-empty map is a candidate, so the sparse form is strictly LARGER "
      ~ "here — plan §K.5 rule 5 forbids sparsifying a whole-map rewrite.",
        e.mapAddr));
    assert(e.mapValsBefore == uvBefore, format(
        "D1: the entry's BEFORE image is not the pre-op map. %d floats "
      ~ "recorded against %d live. If it is the POST-clear image instead, the "
      ~ "undo zero-fills and answers true, and no length compare sees it.",
        e.mapValsBefore.length, uvBefore.length));

    assert(c.revert(), "D1: the undo must succeed");
    assert(m.meshMap("uv").data == uvBefore,
        "D1: the undo restored a map of the right LENGTH whose values are not "
      ~ "the pre-op ones — the Stage F1 failure, verbatim");
    planesEqual("D1", before, dump(m));
    countersUnmoved("D1", c0);
}

// ===========================================================================
// D2 — `uv.copy` CREATES its target, so its undo owes a map REMOVAL that
// `resizeAllMeshMaps` will not do for you, and its REDO owes the CONTENT.
//
// The redo half is the trap the plan named for this file and it is only
// reachable through the forward replay: `MeshSessionEdit`'s
// `if (useDelta_) delta_.apply(*mesh);` is a shipped consumer, so a
// `DefaultInit` create would bring the map back with the right name, domain,
// dim and LENGTH and every value zero. Nothing throws; nothing looks wrong.
//
// MUTATION: swap `recordMapCreateFilledOwned` for `recordMapCreate` in
// `UvCopy.copyKernel`. The undo half stays green — the reverse only needs a
// name — and the replay half reddens naming the zeros.
// ===========================================================================
unittest {
    auto m = stand();
    const srcData = m.meshMap("uv").data.dup;
    size_t nonZero = 0;
    foreach (x; srcData) if (x != 0.0f) ++nonZero;
    assert(nonZero >= 8, format(
        "D2: the source map holds only %d non-zero values, so a default-init "
      ~ "replay would be indistinguishable from a faithful one", nonZero));
    const before = dump(m);
    const c0 = counters();

    auto v = freshView();
    auto c = new UvCopy(m, v, EditMode.Polygons);
    setS(c, "from", "uv"); setS(c, "to", "uvC");
    assert(c.apply(), "D2: the forward must apply");
    assert(m.meshMap("uvC") !is null, "D2: the forward must create the target");
    auto e = oneMapEntry("D2", c.recordedUndo().delta().log,
                         MeshOpEntry.MapOp.Create);
    assert(e.mapAddr == MeshOpEntry.MapAddressing.WholeArray, format(
        "D2: the entry addresses `%s`, expected `WholeArray` — `uv.copy` fills "
      ~ "what it creates, so a DefaultInit spelling loses the copied channel "
      ~ "on every FORWARD replay.", e.mapAddr));

    // The REDO path, driven for real.
    auto m2 = stand();
    assert(c.recordedUndo().delta().apply(*m2), "D2: the forward replay must run");
    auto copied = m2.meshMap("uvC");
    assert(copied !is null, "D2: the forward replay must REGISTER the target");
    assert(copied.data == srcData, format(
        "D2: the replayed copy holds %d floats that are not the source's. The "
      ~ "map exists with the right name, domain, dim and LENGTH — only its "
      ~ "contents are zeros, which is the failure `session_edit.d:140` makes "
      ~ "reachable.", copied.data.length));

    assert(c.revert(), "D2: the undo must succeed");
    assert(m.meshMap("uvC") is null,
        "D2: the undo must UN-ADD the created map; `resizeAllMeshMaps` only "
      ~ "resizes the maps that are there, it never removes one");
    planesEqual("D2", before, dump(m));
    countersUnmoved("D2", c0);
}

// ===========================================================================
// D3 — THE REGISTRY SLOT, `uv.delete`. Same shape as C3 and measured the same
// way: with `slot = uint.max` the frozen oracle reddens on
// `[uv.delete/postUndo]: plane 'meshMaps' differs`, first difference at
// character 1295 — index 2 holding `crease` where `uv2` belongs.
//
// It is a SEPARATE cell from C3 and not a parameterisation of it, because the
// two commands record the slot at different sites and Stage L1-a's finding was
// exactly that the fix does not generalise by being written once: the entry
// carries it, but each recorder has to pass it.
//
// MUTATION: `slot = mapSlotOf(&ed.mesh(), name_);` -> `slot = uint.max;` in
// `UvDelete.deleteKernel`. Isolate — it reddens the oracle too.
// ===========================================================================
unittest {
    auto m = stand();
    assert(m.meshMaps.length > 3 && m.meshMaps[2].name == "uv2", format(
        "D3: this cell needs `uv2` at index 2 with maps after it, or "
      ~ "'restored in place' and 'appended' are the same answer. Registry: %s",
        () { string[] n; foreach (ref mm; m.meshMaps) n ~= mm.name; return n; }()));
    const before = dump(m);
    const c0 = counters();

    auto v = freshView();
    auto c = new UvDelete(m, v, EditMode.Polygons);
    setS(c, "name", "uv2");
    assert(c.apply(), "D3: the forward must apply");
    auto e = oneMapEntry("D3", c.recordedUndo().delta().log,
                         MeshOpEntry.MapOp.Remove);
    assert(e.mapSlot == 2, format(
        "D3: the entry recorded slot %d, expected 2.", e.mapSlot));

    assert(c.revert(), "D3: the undo must succeed");
    assert(m.meshMaps[2].name == "uv2", format(
        "D3: after the undo index 2 holds `%s`, expected `uv2` — the map came "
      ~ "back with the right content at the wrong POSITION.",
        m.meshMaps[2].name));
    planesEqual("D3", before, dump(m));
    countersUnmoved("D3", c0);
}

// ===========================================================================
// E1 — A FORWARD THAT SUCCEEDS WHILE MOVING NOTHING, and its `revert()` must
// answer **true**. This is regression 0099's shape and NOTHING ELSE IN L1 HAS
// IT: every other migrated command records unconditionally once its guards
// pass, so its delta is never empty. The post-hoc door does not — it records
// only when an element actually moved, bitwise.
//
// `uv.rotate` by 0 degrees about the centroid is the cell: the affine is the
// identity, every corner is written back with its own bits, the diff finds
// nothing, and the delta comes back EMPTY. Before the migration this path
// captured a snapshot and its `revert()` was a no-op that answered true; a
// `false` here makes `CommandHistory.undo` discard the entry AND its whole
// trailing suffix (`tests/test_edge_slide.d`).
//
// AND THE OTHER DIRECTION, IN THE SAME CELL, BECAUSE IT WAS A REAL DEFECT.
// The first version of `revertMapEditEmptyOk` answered true whenever the
// holder was empty — which is ALSO the state of a command whose forward
// REFUSED or was never applied at all. It went green on every cell written
// for it in this lane and reddened only in lane S, on three shipped cells that
// have asserted the false answer since long before this stage
// (`test_uv_transform.d:346` "revert without apply must return false",
// `test_uv_pack.d:319`, `test_uv_project.d:257`). The two states are told
// apart by a bit the forward sets, not by the holder, and the (b) half below
// is what keeps that separation in this file rather than only in lane S.
//
// MUTATION: `revertMapEditEmptyOk` -> `revertMapEdit` in `UvRotate.revert`
// reddens (a); dropping the `forwardSucceeded` term from
// `revertMapEditEmptyOk` and returning a bare `true` reddens (b). Either one
// reddens all eight value commands at once — isolate.
// ===========================================================================
unittest {
    auto m = stand();
    const before = dump(m);

    auto v = freshView();
    auto c = new UvRotate(m, v, EditMode.Polygons);
    setF(c, "angle", 0.0f); setS(c, "pivot", "centroid");
    assert(c.apply(), "E1: a zero-angle rotate must still SUCCEED — the "
                    ~ "command did not refuse, so the history holds an entry "
                    ~ "for it");
    assert(!c.recordedUndo().armed(), format(
        "E1: the delta is NOT empty (%d entries), so this cell is measuring "
      ~ "the ordinary path and the 0099 arm is untested. A zero-angle rotate "
      ~ "must write every corner back bit-identically.",
        c.recordedUndo().delta().log.length));
    planesEqual("E1/forward", before, dump(m));

    assert(c.revert(), format(
        "E1a: `uv.rotate`'s revert answered FALSE on an empty edit. "
      ~ "`CommandHistory.undo` discards an entry whose revert answers false "
      ~ "AND the whole trailing suffix after it (regression 0099), and before "
      ~ "the migration this path answered true through a no-op snapshot "
      ~ "restore."));
    planesEqual("E1/undo", before, dump(m));

    // (b) …and a command that was NEVER APPLIED must still answer false. Same
    // holder state, opposite answer — see the note above.
    auto m2 = stand();
    auto v2 = freshView();
    auto never = new UvRotate(m2, v2, EditMode.Polygons);
    setF(never, "angle", 37.0f);
    assert(!never.revert(), format(
        "E1b: `revert()` answered TRUE on a command that was never applied. "
      ~ "'the forward refused' and 'the forward succeeded and moved nothing' "
      ~ "are both an empty holder, so a helper that reads only the holder "
      ~ "cannot tell them apart and reports success for an undo that undid "
      ~ "nothing. Three shipped suite cells assert this false answer."));
}

// ===========================================================================
// E2 — A SECOND `apply()` ON AN ARMED COMMAND MUST NOT RECORD OVER THE FIRST
// (plan §K.5 rule 2, the obligation L0-d paid for). `CommandHistory.redo`
// re-runs `apply()`, and `applyOrRefire` re-fires a live command without
// reverting it first, so the armed arm has to re-run the kernel UNRECORDED.
//
// THE OBVIOUS CELL FOR THIS IS INERT AND WAS MEASURED SO. apply -> revert ->
// apply, then comparing entry COUNTS or before-images, is green under the
// mutation: the revert has already put the map back, so the second recording
// captures the same before-image as the first and the log is still one entry
// long. Both candidate behaviours agree on every number that cell reads.
//
// What separates them is a second apply WITHOUT an intervening revert. The
// map is then at its post-op values, so a second recording captures THOSE as
// its before-image — and the single revert that follows lands on the
// once-rotated map instead of the original. That is the real damage, stated as
// a plane: an undo that restores the state it is undoing.
//
// MUTATION: `if (undo.armed())` -> `if (false)` in
// `commands/mesh/map_edit_undo.runMapEdit`. Reddens every migrated group;
// isolate.
// ===========================================================================
unittest {
    auto m = stand();
    const before = dump(m);
    const uvA = m.meshMap(kUvMapName).data.dup;

    auto v = freshView();
    auto c = new UvRotate(m, v, EditMode.Polygons);
    setF(c, "angle", 37.0f); setS(c, "pivot", "centroid");
    assert(c.apply(), "E2: the forward must apply");
    assert(c.recordedUndo().armed(), "E2: nothing was recorded");
    const bef1 = c.recordedUndo().delta().log[0].mapValsBefore.dup;
    assert(m.meshMap(kUvMapName).data != uvA,
        "E2: the forward moved nothing, so a second recording could not "
      ~ "differ from the first and this cell could not fail");

    // The SECOND apply, on a mesh that is already at the post-op values.
    assert(c.apply(), "E2: the re-fire must apply");
    assert(c.recordedUndo().delta().log.length == 1, format(
        "E2: the command now holds %d entries",
        c.recordedUndo().delta().log.length));
    assert(c.recordedUndo().delta().log[0].mapValsBefore == bef1, format(
        "E2: the second apply RECORDED, replacing the first delta's pre-op "
      ~ "image with the once-rotated values. The next undo then restores the "
      ~ "state it is undoing."));

    // ONE revert must land on the ORIGINAL, not on the once-rotated map.
    assert(c.revert(), "E2: the undo must succeed");
    assert(m.meshMap(kUvMapName).data == uvA,
        "E2: the undo landed on the once-rotated map, not the original");
    planesEqual("E2", before, dump(m));
}

// E3 — THE HYBRID. `uv.project` records `MapOp.Create` when it made the map
// and `MapOp.Values` when it did not, and the created branch's undo must leave
// NO ORPHAN MAP.
//
// The branch is invisible after the fact — once the write has run the map
// exists either way — which is why `created` is a local decided at the create
// and not re-derived. The failure it guards is concrete: route the created
// branch through the diff door and `dataBefore` is empty while the live map is
// not, so `recordMapValueDiff` returns false having recorded NOTHING, the
// delta is empty, and the undo leaves a map the document never had.
//
// MUTATION: in `UvProject.kernel`, drop the `created` branch and always call
// `ed.recordMapValueDiff(...)`. Cell (b) below reddens on the orphan.
// ===========================================================================
unittest {
    const c0 = counters();

    // (a) the map EXISTS -> Values, recorded post-hoc.
    {
        auto m = stand();
        const before = dump(m);
        auto v = freshView();
        auto c = new UvProject(m, v, EditMode.Polygons);
        setF(c, "size", 2.0f);
        assert(c.apply(), "E3a: the forward must apply");
        assert(c.recordedUndo().armed(), "E3a: nothing was recorded");
        auto e = oneMapEntry("E3a", c.recordedUndo().delta().log,
                             MeshOpEntry.MapOp.Values);
        assert(e.mapAddr != MeshOpEntry.MapAddressing.DefaultInit,
            "E3a: a Values entry may not carry the Create arm's addressing");
        assert(c.revert(), "E3a: the undo must succeed");
        planesEqual("E3a", before, dump(m));
    }

    // (b) the map is ABSENT -> Create/WholeArray, and the undo un-adds it.
    {
        auto m = stand();
        assert(m.removeMeshMap(kUvMapName),
            "E3b: the stand must start with a `uv` map for this to remove");
        const before = dump(m);
        auto v = freshView();
        auto c = new UvProject(m, v, EditMode.Polygons);
        setF(c, "size", 2.0f);
        assert(c.apply(), "E3b: the forward must apply");
        assert(c.recordedUndo().armed(), format(
            "E3b: the create branch recorded NOTHING. Routing it through the "
          ~ "post-hoc diff door does exactly this — the pre-op image is empty "
          ~ "while the live map is not, so the diff refuses and returns false "
          ~ "— and the undo below then leaves an orphan map."));
        auto e = oneMapEntry("E3b", c.recordedUndo().delta().log,
                             MeshOpEntry.MapOp.Create);
        assert(e.mapAddr == MeshOpEntry.MapAddressing.WholeArray, format(
            "E3b: the entry addresses `%s`; a projection that created its map "
          ~ "must carry the projected content or a FORWARD replay brings the "
          ~ "map back full of zeros.", e.mapAddr));
        assert(e.mapValsAfter.length == m.loops.length * 2, format(
            "E3b: the entry carries %d floats for %d corners",
            e.mapValsAfter.length, m.loops.length));

        // the REDO half, for real
        auto want = m.meshMap(kUvMapName).data.dup;
        auto m2 = stand();
        assert(m2.removeMeshMap(kUvMapName));
        assert(c.recordedUndo().delta().apply(*m2), "E3b: the replay must run");
        assert(m2.meshMap(kUvMapName) !is null
            && m2.meshMap(kUvMapName).data == want,
            "E3b: the forward replay did not reproduce the projected UVs");

        assert(c.revert(), "E3b: the undo must succeed");
        assert(m.meshMap(kUvMapName) is null,
            "E3b: the undo left an ORPHAN map — the document now carries a "
          ~ "`uv` channel it never had");
        planesEqual("E3b", before, dump(m));
    }
    countersUnmoved("E3", c0);
}

// ===========================================================================
// E4 — `uv.unwrap` IS THE ONLY COMMAND IN THE FAMILY WHOSE KERNEL CAN REFUSE
// **AFTER** IT HAS WRITTEN, and the rollback is its own.
//
// The seed is projected first, then `uvUnwrap` runs and may answer false (no
// pinned class on a closed mesh with no seams; nothing relaxable). Before the
// migration that was undone by `snap.restore` — a whole-mesh restore. There is
// no snapshot on the delta path, so the kernel keeps its own image and undoes
// exactly what it wrote.
//
// WITHOUT THE ROLLBACK THE FAILURE IS THE WORST ONE THIS PLAN NAMES: `apply`
// answers false, so the dispatcher reports `status:error` and records NO
// history entry — while the mesh keeps the seed. "Answers error and changed
// everything" (plan §K.1.3a). No plane fixture sees it, because the fixture's
// cells only freeze commands that SUCCEED.
//
// THE STAND IS A CUBE, NOT `makeTaggedGridMaps`. It has to be: the refusal
// needs a CLOSED mesh (every loop has a twin) with `seams=boundary`, so that
// the pinned-class count is zero. The grid is open, so on it `uvUnwrap`
// succeeds and this cell would be measuring the happy path — the "fixture
// cannot exhibit the phenomenon" shape.
//
// MUTATION: delete the `if (created) ... else map.data[] = preData[];` pair
// from `UvUnwrap.kernel`'s refusal arm. Both halves below redden, each naming
// its own branch.
// ===========================================================================
unittest {
    const c0 = counters();

    // (a) the map was CREATED by this command -> the rollback un-registers it.
    {
        auto m = new Mesh;
        *m = makeCube();
        m.buildLoops();
        assert(m.meshMap(kUvMapName) is null,
            "E4a: the cube must start WITHOUT a uv map");
        auto v = freshView();
        auto c = new UvUnwrap(m, v, EditMode.Polygons);
        setI(c, "iter", 3); setS(c, "seams", "boundary");
        assert(!c.apply(), "E4a: a closed mesh with no seams has zero pinned "
                         ~ "classes, so uvUnwrap must refuse — if it applies, "
                         ~ "this cell is exercising the happy path");
        assert(m.meshMap(kUvMapName) is null, format(
            "E4a: the refused command left a `uv` map behind. `apply` answered "
          ~ "FALSE, so the dispatcher reports status:error and records no "
          ~ "history entry — the mesh is mutated with nothing to undo it."));
        assert(m.meshMaps.length == 0, format(
            "E4a: the cube carries %d map(s) after a refused unwrap",
            m.meshMaps.length));
    }

    // (b) the map EXISTED -> the rollback restores its values, bit for bit.
    {
        auto m = new Mesh;
        *m = makeCube();
        m.buildLoops();
        auto uv = m.addMeshMap(kUvMapName, 2, MapDomain.PolyVertex);
        assert(uv !is null);
        foreach (i; 0 .. uv.data.length) uv.data[i] = 0.125f * cast(float)(i + 1);
        const want = uv.data.dup;

        auto v = freshView();
        auto c = new UvUnwrap(m, v, EditMode.Polygons);
        setI(c, "iter", 3); setS(c, "seams", "boundary");
        assert(!c.apply(), "E4b: uvUnwrap must refuse on a closed seamless mesh");
        assert(m.meshMap(kUvMapName).data == want,
            "E4b: the refused command left the SEED write in the map. The "
          ~ "command answered false, so nothing will ever undo it.");
    }
    countersUnmoved("E4", c0);
}

// ===========================================================================
// E5 — THE PUBLISH CLASS IS `Material` FOR EVERY MIGRATED UV COMMAND, and
// `Maps` does not move.
//
// This pins a DECISION rather than a discovery, which is why it is asserted in
// both directions. `MeshEditBatch.recordMapValueDiff` publishes, and its class
// is a PARAMETER precisely so the recorded arm's stamp equals the redo and
// hatch arms' — a hard-coded `Maps` there would OR a second bit into one arm
// only, making the commit seam depend on `VIBE3D_UNDO_TRACKER` and moving
// `ChangeBus.docRevision()` — the unsaved-changes asterisk — by a different
// amount on each. Reclassifying this family from `Material` to `Maps` is the
// open question Q-L1-3 and is not taken as a migration side effect.
//
// MUTATION: drop the `MeshEditScope.Material` argument from any
// `recordMapValueDiff` call site, letting the default `Maps` apply. The `Maps`
// row reddens for that command.
// ===========================================================================
unittest {

    static struct Row { string name; Command delegate(Mesh*, View) mk; }
    auto rows = [
        Row("uv.flip", (Mesh* m, View v) {
            auto c = new UvFlip(m, v, EditMode.Polygons);
            setS(c, "axis", "u"); setS(c, "pivot", "unit"); return cast(Command)c; }),
        Row("uv.mirror", (Mesh* m, View v) {
            auto c = new UvMirror(m, v, EditMode.Polygons);
            setS(c, "axis", "v"); return cast(Command)c; }),
        Row("uv.rotate", (Mesh* m, View v) {
            auto c = new UvRotate(m, v, EditMode.Polygons);
            setF(c, "angle", 37.0f); return cast(Command)c; }),
        Row("uv.fit", (Mesh* m, View v) {
            auto c = new UvFit(m, v, EditMode.Polygons);
            setS(c, "keepAspect", "stretch"); return cast(Command)c; }),
        Row("uv.pack", (Mesh* m, View v) {
            auto c = new UvPack(m, v, EditMode.Polygons);
            setF(c, "gutter", 0.02f); return cast(Command)c; }),
        Row("uv.project", (Mesh* m, View v) {
            auto c = new UvProject(m, v, EditMode.Polygons);
            setF(c, "size", 2.0f); return cast(Command)c; }),
        Row("uv.unwrap", (Mesh* m, View v) {
            auto c = new UvUnwrap(m, v, EditMode.Polygons);
            setI(c, "iter", 3); return cast(Command)c; }),
        Row("uv.relax", (Mesh* m, View v) {
            m.deselectFace(7);
            auto c = new UvRelax(m, v, EditMode.Polygons);
            setI(c, "iter", 3); setF(c, "strn", 0.7f); return cast(Command)c; }),
    ];
    assert(rows.length == 8, format(
        "E5: the value-file roster holds %d rows; the five UV value files "
      ~ "declare EIGHT mutating classes (uv_transform 3, uv_pack 2, "
      ~ "uv_project 1, uv_relax 1, uv_unwrap 1). A missing row is a command "
      ~ "whose publish class nobody is checking.", rows.length));

    foreach (ref r; rows) {
        auto m = stand();
        const mat0 = changeBus.totalMaterial, map0 = changeBus.totalMaps;
        auto c = r.mk(m, freshView());
        assert(c.apply(), r.name ~ ": the forward must apply on this stand");
        const dMat = changeBus.totalMaterial - mat0;
        const dMap = changeBus.totalMaps - map0;
        assert(dMat >= 1, format(
            "E5/%s published Material %d time(s) — a map value write must "
          ~ "reach `DisplayRefreshMask` or the edit is never redrawn.",
            r.name, dMat));
        assert(dMap == 0, format(
            "E5/%s published Maps %d time(s). This family has always published "
          ~ "`Material`; `Maps` is counted separately by "
          ~ "ChangeBus.docRevision(), so switching classes changes the "
          ~ "unsaved-changes asterisk. It is question Q-L1-3, not a migration "
          ~ "side effect — the likeliest cause is a `recordMapValueDiff` call "
          ~ "that dropped its explicit MeshEditScope argument.", r.name, dMap));
    }
}

/// The concrete command plus two closures over it, because `recordedUndo()` is
/// declared per class and `Command` has no such member — deliberately: it is a
/// `version (unittest)` accessor, not an API.
private struct Made {
    Command cmd;
    bool delegate() armed;
    const(MeshOpEntry)[] delegate() log;
}

// ===========================================================================
// E6 — THE ROSTER. All SIXTEEN migrated classes, each driven end to end:
// apply -> the delta is ARMED -> the recorded ENTRY SHAPE -> revert -> every
// plane back -> the three seam counters unmoved.
//
// WHY A ROSTER AND NOT SIXTEEN MORE HAND-WRITTEN CELLS. The cells above each
// exist for one failure that is invisible everywhere else. This one exists for
// the failure that is invisible in ALL of them: a class that quietly stops
// recording. Its `MeshSnapshot` is still in the tree as the hatch's arm, so a
// command whose recorder is deleted falls back to it and restores every plane
// correctly — every result-shaped assertion in this file stays green, and only
// `armed()` plus the log's shape can tell.
//
// THE PAYLOAD COLUMN IS THE STAGE'S OWN MEASUREMENT, frozen. `arrayBytes` is
// what the entry's five arrays cost on `makeTaggedGridMaps(3)` — 36 corners,
// 16 vertices, one face selected — and it is the number the card quotes per
// file. It is asserted EXACTLY, so a row that silently changes addressing (the
// mode A -> mode C accident C1 describes) reddens here as well.
//
// The struct's own `MeshOpEntry.sizeof` is NOT in this column: `byteSize`
// charges it once per entry and it is the same for every kind, so including it
// would flatten the very differences the column exists to show.
//
// MUTATION: delete the recorder call from any one migrated kernel — the row's
// `armed()` assertion reddens naming the command. A mutation that changes the
// ADDRESSING instead reddens the shape columns, which is the half a
// result-shaped assertion cannot see.
// ===========================================================================
unittest {

    static struct Row {
        string name;
        MeshOpEntry.MapOp op;
        MeshOpEntry.MapAddressing addr;
        size_t bytes;      // idx*4 + (before+after)*4 + presence bytes
        uint   slot;       // uint.max unless the arm carries one
        Made delegate(Mesh*, View) mk;
    }
    enum uint NA = uint.max;
    alias Op   = MeshOpEntry.MapOp;
    alias Addr = MeshOpEntry.MapAddressing;

    auto rows = [
        // ---- uv_transform.d — the selected face's four corners.
        Row("uv.flip",   Op.Values, Addr.Listed, 80, NA, (Mesh* m, View v) {
            auto c = new UvFlip(m, v, EditMode.Polygons);
            setS(c, "axis", "u"); setS(c, "pivot", "unit");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("uv.mirror", Op.Values, Addr.Listed, 80, NA, (Mesh* m, View v) {
            auto c = new UvMirror(m, v, EditMode.Polygons);
            setS(c, "axis", "v");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("uv.rotate", Op.Values, Addr.Listed, 80, NA, (Mesh* m, View v) {
            auto c = new UvRotate(m, v, EditMode.Polygons);
            setF(c, "angle", 37.0f);
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        // ---- uv_pack.d
        Row("uv.fit",    Op.Values, Addr.Listed, 80, NA, (Mesh* m, View v) {
            auto c = new UvFit(m, v, EditMode.Polygons);
            setS(c, "keepAspect", "stretch");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("uv.pack",   Op.Values, Addr.Listed, 80, NA, (Mesh* m, View v) {
            auto c = new UvPack(m, v, EditMode.Polygons);
            setF(c, "gutter", 0.02f);
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        // ---- the two create-if-absent hybrids, on the branch where the map
        //      EXISTS. Their CREATED branches are E3b and E4a.
        Row("uv.project", Op.Values, Addr.Listed, 80, NA, (Mesh* m, View v) {
            auto c = new UvProject(m, v, EditMode.Polygons);
            setF(c, "size", 2.0f);
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("uv.unwrap",  Op.Values, Addr.Listed, 80, NA, (Mesh* m, View v) {
            auto c = new UvUnwrap(m, v, EditMode.Polygons);
            setI(c, "iter", 3);
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        // ---- uv_relax.d, in WHOLE-MAP mode: 16 of the 36 corners move.
        Row("uv.relax",   Op.Values, Addr.Listed, 320, NA, (Mesh* m, View v) {
            m.deselectFace(7);
            auto c = new UvRelax(m, v, EditMode.Polygons);
            setI(c, "iter", 3); setF(c, "strn", 0.7f);
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        // ---- uv_map_util.d — the registry group.
        Row("uv.clear",  Op.Values, Addr.WholeArray, 576, NA, (Mesh* m, View v) {
            auto c = new UvClear(m, v, EditMode.Polygons);
            setS(c, "name", "uv");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("uv.delete", Op.Remove, Addr.WholeArray, 288, 2, (Mesh* m, View v) {
            auto c = new UvDelete(m, v, EditMode.Polygons);
            setS(c, "name", "uv2");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("uv.copy",   Op.Create, Addr.WholeArray, 288, NA, (Mesh* m, View v) {
            auto c = new UvCopy(m, v, EditMode.Polygons);
            setS(c, "from", "uv"); setS(c, "to", "uvC");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("uv.rename", Op.Rename, Addr.DefaultInit, 0, NA, (Mesh* m, View v) {
            auto c = new UvRename(m, v, EditMode.Polygons);
            setS(c, "from", "uv2"); setS(c, "to", "uv3");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        // ---- weightmap.d — Point domain, dim 1, no presence channel.
        Row("mesh.weightmap.create", Op.Create, Addr.DefaultInit, 0, NA,
            (Mesh* m, View v) {
            auto c = new WeightmapCreate(m, v, EditMode.Vertices);
            setS(c, "name", "W2");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("mesh.weightmap.remove", Op.Remove, Addr.WholeArray, 64, 1,
            (Mesh* m, View v) {
            auto c = new WeightmapRemove(m, v, EditMode.Vertices);
            setS(c, "name", "W");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        Row("mesh.weightmap.rename", Op.Rename, Addr.DefaultInit, 0, NA,
            (Mesh* m, View v) {
            auto c = new WeightmapRename(m, v, EditMode.Vertices);
            setS(c, "from", "W"); setS(c, "to", "W9");
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
        // mode A's EXTREME: one index, one float each way. Twelve bytes.
        Row("mesh.weightmap.set", Op.Values, Addr.Listed, 12, NA,
            (Mesh* m, View v) {
            auto c = new WeightmapSet(m, v, EditMode.Vertices);
            setS(c, "name", "W"); setI(c, "vert", 6); setF(c, "weight", 0.875f);
            return Made(c, () => c.recordedUndo().armed(),
                           () => c.recordedUndo().delta().log); }),
    ];

    assert(rows.length == 16, format(
        "E6: the roster holds %d rows; Stage L1-b migrated SIXTEEN classes "
      ~ "(weightmap 4, uv_map_util 4, the five value files 8). A missing row "
      ~ "is a command nothing in this file drives.", rows.length));

    foreach (ref r; rows) {
        auto m = stand();
        auto made = r.mk(m, freshView());
        const c0 = counters();
        const before = dump(m);

        assert(made.cmd.apply(), r.name ~ ": the forward must apply on this stand");
        assert(made.armed(), format(
            "E6/%s: the command recorded NOTHING, so its `revert()` below "
          ~ "falls back to the MeshSnapshot the hatch still holds and restores "
          ~ "every plane correctly. Every result-shaped assertion in this file "
          ~ "is green over a deleted recorder; this one is not.", r.name));
        auto e = oneMapEntry("E6/" ~ r.name, made.log(), r.op);
        assert(e.mapAddr == r.addr, format(
            "E6/%s: the entry addresses `%s`, the roster says `%s`.",
            r.name, e.mapAddr, r.addr));
        assert(e.mapSlot == r.slot, format(
            "E6/%s: the entry carries registry slot %d, the roster says %d "
          ~ "(uint.max = 'append'). Only the Remove arm has a position to "
          ~ "restore.", r.name, e.mapSlot, r.slot));
        const size_t bytes = e.mapElemIdx.length * 4
                           + (e.mapValsBefore.length + e.mapValsAfter.length) * 4
                           + e.presentBefore.length + e.presentAfter.length;
        assert(bytes == r.bytes, format(
            "E6/%s: the entry's arrays cost %d bytes on this stand; the frozen "
          ~ "measurement is %d. This column is the stage's own payload number "
          ~ "and the card quotes it — a silent change of addressing or of what "
          ~ "the recorder gathers moves it while every plane assertion stays "
          ~ "green.", r.name, bytes, r.bytes));

        assert(made.cmd.revert(), r.name ~ ": the undo must succeed");
        planesEqual("E6/" ~ r.name, before, dump(m));
        countersUnmoved("E6/" ~ r.name, c0);
    }
}
