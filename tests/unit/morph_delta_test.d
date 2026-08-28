// morph_delta_test — task 1903 Stage L1-a. The witnesses for the FIRST
// production caller of `MeshOpEntry.Kind.MapValueDelta`.
//
// LANE U (`dub test --config=tests`) ONLY. `./run_test.d` links the prebuilt
// archive and never RUNS a `source/**` or `tests/unit/**` unittest block, so a
// cell placed there instead of here is a cell that cannot redden. The only
// rows this stage owns in lane S are the three `/api/changes` counters
// (`tests/test_map_delta_counters.d`).
//
// ===========================================================================
// WHY THIS GROUP, AND WHAT EACH CELL IS FOR
// ===========================================================================
// `commands/mesh/morph.d` was migrated first of L1's four groups because five
// things are true of it and of no other group. Each is a witness here:
//
//   M1 — the only family whose PRESENCE channel changes. An empty `present`
//        MEANS "all present", so a revert that restores `data` and drops the
//        channel is a legal, WRONG map with every length still matching.
//   M2 — the GEOMETRIC half of M1. `morphAbsolute`'s absent entry means "stay
//        at the base"; a present zero means "go to the origin". M1 alone can
//        be satisfied by writing a present zero.
//   M3 — the only two SHAPE-IDENTICAL `MapKind`s. Name, dim and domain all
//        match between `morphRelative` and `morphAbsolute`, so `mapKind` is
//        the only bind term that can separate them — and this cell drives it
//        through the SHIPPED recorder, which is what proves the recorder puts
//        the real kind in the entry rather than a default.
//   M4 — the only group driving all FOUR `MapOp` arms in production, plus the
//        forward-faithful create (`MeshSessionEdit` replays a delta FORWARD).
//   M5 — the only POSITION write in the family, on `Kind.SetPos`.
//   M6 — the only NON-MESH undo tail: the `morph_target` binding, which no
//        plane dump can see.
//
// Two more rows guard the machinery around them: M7 (the three seam counters
// stay 0 on every happy path, paired with M3 which drives one to 1 — a counter
// only ever asserted zero cannot tell "never refused" from "never ran") and
// M8 (a redo records NOTHING, the §K.5 rule-2 obligation L0-d paid for).
//
// EVERY CELL MEASURES AN **ARMED REVERT**, never a forward. Stage F1 measured a
// revert that restored a map's LENGTH while zeroing all its values and
// answered `true`; a forward-only check is green on that, and so is a check
// that does not first assert the delta path was actually taken. Each cell
// therefore asserts `recordedUndo().armed()` and the log's SHAPE before it
// asserts anything about planes — a command that recorded nothing falls back
// to its `MeshSnapshot` and restores every plane correctly, which would make
// every plane assertion here green over a deleted recorder.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score mutations per
// cell, in isolation.
// ===========================================================================
module tests.unit.morph_delta_test;

import std.format : format;
import std.json   : parseJSON, JSONValue;

import mesh;
import view;
import editmode;
import math       : Vec3;
import change_bus : changeBus;
import http_json  : meshPlanesJson, PlaneDumpMeta;
import mesh_edit_delta : MeshOpEntry;
import mesh_morph : morphApply;
import morph_target;

import commands.mesh.morph : MorphCreate, MorphRemove, MorphRename,
                             MorphSet, MorphClear, MorphApplyCmd;
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
    return meshPlanesJson(*m, PlaneDumpMeta("", "delta", "morph", "makeTaggedGridMaps(3)"));
}

/// Assert every plane of `after` equals every plane of `before`, NAMING the
/// first that differs. Reuses the parity reader's own comparator so a mutation
/// here reddens with the same message shape the frozen oracle produces.
private void planesEqual(string cell, string before, string after) {
    auto b = parseJSON(before);
    comparePlanes("<in-memory pre-op dump>", cell, "postUndo", b, after);
}

/// The one map entry in a delta that must carry exactly one. Fails loudly
/// rather than returning a default, because "no entry" is the shape a deleted
/// recorder takes and every plane assertion downstream is green on it.
private MeshOpEntry oneEntry(string cell, const(MeshOpEntry)[] log,
                             MeshOpEntry.Kind wantKind) {
    assert(log.length == 1, format(
        "%s: the recorded delta holds %d entries, expected exactly 1. A "
      ~ "command that records NOTHING falls back to its MeshSnapshot and "
      ~ "restores every plane correctly, so every assertion below this line "
      ~ "is green over a deleted recorder.", cell, log.length));
    assert(log[0].kind == wantKind, format(
        "%s: the entry is %s, expected %s.", cell, log[0].kind, wantKind));
    return cast(MeshOpEntry) log[0];
}

private struct CounterSnap { ulong mix, refused, bind; }
private CounterSnap counters() {
    return CounterSnap(changeBus.mapDeltaMixRecorded,
                       changeBus.mapDeltaMixRefused,
                       changeBus.mapDeltaBindRefused);
}
/// The three seam counters, as DELTAS. Absolutes are process-cumulative and
/// this binary runs many cells.
private void countersUnmoved(string cell, CounterSnap b) {
    const a = counters();
    assert(a.mix == b.mix, format("%s: mapDeltaMixRecorded moved by %d — the "
        ~ "recorder saw a map entry beside an index-space-moving one, which "
        ~ "is always a bug in the command being written.", cell, a.mix - b.mix));
    assert(a.refused == b.refused, format("%s: mapDeltaMixRefused moved by %d "
        ~ "— a replay SKIPPED map entries, so the undo restored less than it "
        ~ "reports.", cell, a.refused - b.refused));
    assert(a.bind == b.bind, format("%s: mapDeltaBindRefused moved by %d — a "
        ~ "map entry could not bind its map at replay and applied NOTHING, "
        ~ "silently.", cell, a.bind - b.bind));
}

// ===========================================================================
// M1 — THE PRESENCE CHANNEL, on an ARMED REVERT, plane by plane.
//
// `mesh.morph.clear` over vertices that are PRESENT and NON-ZERO. The forward
// zeroes `data` AND drops `present`; the revert must bring both back. A cell
// that restored only `data` leaves them absent, which on `MA` (morphAbsolute)
// is a different vertex position — see M2.
//
// MUTATION: in `MorphClear.clearKernel`, hand `pa` to the recorder where `pb`
// belongs (record the after-image as the before-image). `data` still compares
// equal on every element and every length term still passes; only the raw
// `present` channel differs, at two elements. A FORWARD-only check is green
// under it, because the forward is identical either way.
// ===========================================================================
unittest {
    scope (exit) clearMorphTarget();

    auto m = stand();
    auto v = freshView();
    const c0 = counters();

    // Vertices 1 and 4 are PRESENT with non-zero values on the stand; vertex 3
    // is absent and vertex 2 is present-but-exactly-zero. The stand's own
    // block asserts all three states exist, so this cell cannot be measuring a
    // map that never had a presence channel.
    auto mm = m.meshMap("MA");
    assert(mm !is null && mm.present.length == m.vertices.length,
        "stand: MA must carry a per-vertex presence channel");
    assert(mm.isPresent(1) && mm.isPresent(4),
        "stand: the vertices this clear drops must START present, or the "
      ~ "forward moves no presence bit and the whole cell is vacuous");

    // The selection is made BEFORE the pre-op dump on purpose. `selectVertex`
    // stamps `vertexSelectionOrder` and moves its counter, and a map delta
    // deliberately restores NO selection plane — so a dump taken before the
    // selection would redden on `selectionOrderCounters` for a reason that has
    // nothing to do with this migration. (Measured: 41 -> 43. The frozen
    // oracle's own cells select inside the command factory, i.e. before their
    // first dump, for the same reason.)
    m.selectVertex(1);
    m.selectVertex(4);
    const pre = dump(m);

    auto cmd = new MorphClear(m, v, EditMode.Vertices);
    setS(cmd, "name", "MA");
    assert(cmd.apply(), "M1: the forward must apply on this stand");

    const post = dump(m);
    assert(pre != post,
        "M1: the forward moved no plane this dump can see, so every assertion "
      ~ "about its undo is satisfied by an undo that does nothing");

    // THE DELTA PATH WAS TAKEN, and it carries the presence plane.
    assert(cmd.recordedUndo().armed(),
        "M1: the command did not arm a delta — it fell back to MeshSnapshot "
      ~ "and the plane comparison below says nothing about the migration");
    auto e = oneEntry("M1", cmd.recordedUndo().delta().log,
                      MeshOpEntry.Kind.MapValueDelta);
    assert(e.mapOp == MeshOpEntry.MapOp.Values
        && e.mapAddr == MeshOpEntry.MapAddressing.Listed, format(
        "M1: a clear must record Values/Listed, got %s/%s", e.mapOp, e.mapAddr));
    assert(e.presentBefore.length == e.mapElemIdx.length
        && e.presentAfter.length == e.mapElemIdx.length, format(
        "M1: the entry carries %d/%d presence bytes for %d elements. On a "
      ~ "presence-tracked kind the channel is NOT optional: an absent one is "
      ~ "refused at bind, and a short one is the plane this family loses.",
        e.presentBefore.length, e.presentAfter.length, e.mapElemIdx.length));

    assert(cmd.revert(), "M1: the undo must succeed");
    planesEqual("M1", pre, dump(m));

    countersUnmoved("M1", c0);
}

// ===========================================================================
// M2 — THE GEOMETRIC HALF of M1, and it is a separate cell for a reason.
//
// M1 can be "fixed" by a revert that writes a PRESENT ZERO instead of
// restoring absence, and stays green — the raw dump would differ, but a
// reviewer reading only "the values came back" would not. This cell reads the
// map the way the deformer does: through `isPresent` + `morphApply`. On
// `morphAbsolute` an absent entry means "stay at the base" and a present zero
// means "go to the origin", so the two answers are metres apart.
//
// MUTATION: the same one as M1. Run the two IN ISOLATION — druntime stops the
// module at M1's first failed assert and M2 never executes.
// ===========================================================================
unittest {
    scope (exit) clearMorphTarget();

    auto m = stand();
    auto v = freshView();

    static Vec3 deformed(Mesh* m, string map, size_t vi) {
        auto mm = m.meshMap(map);
        if (mm is null || !mm.isPresent(vi)) return m.vertices[vi];
        return morphApply(m.vertices[vi], mm.entryOr(vi, Vec3(0, 0, 0)),
                          mm.kind, 1.0f);
    }

    const Vec3 pre1 = deformed(m, "MA", 1);
    const Vec3 base1 = m.vertices[1];
    assert(pre1.x != base1.x || pre1.y != base1.y || pre1.z != base1.z,
        "stand: vertex 1 must actually be DISPLACED by MA before the clear, "
      ~ "or 'the deformed position came back' is true of every candidate undo");

    m.selectVertex(1);
    auto cmd = new MorphClear(m, v, EditMode.Vertices);
    setS(cmd, "name", "MA");
    assert(cmd.apply(), "M2: the forward must apply");
    assert(cmd.recordedUndo().armed(), "M2: the delta path must be taken");

    const Vec3 cleared = deformed(m, "MA", 1);
    assert(cleared.x == base1.x && cleared.y == base1.y && cleared.z == base1.z,
        "M2: after the clear vertex 1 must sit at its BASE — that is what "
      ~ "'absent' means for morphAbsolute, and it is what the undo has to undo");

    assert(cmd.revert(), "M2: the undo must succeed");
    const Vec3 back = deformed(m, "MA", 1);
    assert(back.x == pre1.x && back.y == pre1.y && back.z == pre1.z, format(
        "M2: after the undo vertex 1 evaluates to (%s, %s, %s); it was "
      ~ "(%s, %s, %s). A revert that restored `data` and left the entry ABSENT "
      ~ "— or wrote a present ZERO — puts the vertex at its base instead, "
      ~ "which is a GEOMETRIC error and not a cosmetic one.",
        back.x, back.y, back.z, pre1.x, pre1.y, pre1.z));
}

// ===========================================================================
// M3 — `mapKind` IS A REFUSAL TERM, and the shipped recorder writes the real
// one.
//
// `MA` (morphAbsolute) and `MR` (morphRelative) are Point / dim 3 / no
// reserved name: name, dim and domain all match, so every OTHER bind term
// passes and `mapKind` is the only one that can separate them. Between record
// and replay this cell removes `MA` and re-creates a map of the SAME name with
// the OTHER kind — history drift the replay must refuse whole.
//
// This is `map_value_delta_test`'s W-K7 driven through the SHIPPED command
// rather than a hand-built entry, which is a different claim: that
// `MorphSet.setKernel` puts the map's ACTUAL kind in the payload. A recorder
// that wrote `MapKind.unclassified` would make this refusal fire on every
// replay, and one that copied the kind from a constant would make it never
// fire; only driving both directions separates those.
//
// MUTATION (a): in `mesh_edit_delta.bindMapForEntry`, drop the
// `live.kind != e.mapKind` term -> the absolute values land in a relative
// channel and the counter does not move.
// MUTATION (b): in `MorphSet.setKernel`, record `MapKind.morphRelative`
// instead of `mm.kind` -> the SECOND cell below (the happy path) reddens
// because a correct replay now refuses. Two mutations, two rows, isolated.
// ===========================================================================
unittest {
    scope (exit) clearMorphTarget();

    auto m = stand();
    auto v = freshView();

    auto cmd = new MorphSet(m, v, EditMode.Vertices);
    setS(cmd, "name", "MA"); setI(cmd, "vert", 3);
    setF(cmd, "x", 0.7f); setF(cmd, "y", -0.3f); setF(cmd, "z", 0.25f);
    assert(cmd.apply(), "M3: the forward must apply");
    assert(cmd.recordedUndo().armed(), "M3: the delta path must be taken");
    auto e = oneEntry("M3", cmd.recordedUndo().delta().log,
                      MeshOpEntry.Kind.MapValueDelta);
    assert(e.mapKind == MapKind.morphAbsolute, format(
        "M3: the recorder wrote kind %s into the entry; MA is morphAbsolute. "
      ~ "A recorder that writes a constant makes the bind term below either "
      ~ "always or never fire, and the cell cannot tell which.", e.mapKind));

    // HISTORY DRIFT: same name, same dim, same domain, OTHER kind.
    assert(m.removeMeshMap("MA"), "M3: the drift setup must remove the map");
    auto impostor = m.addMeshMapOfKind(MapKind.morphRelative, "MA");
    assert(impostor !is null && impostor.dim == e.mapDim
        && impostor.domain == e.mapDomain, format(
        "M3: the impostor must match on dim and domain, or the refusal below "
      ~ "could be any of the other bind terms firing"));
    const before = impostor.data.dup;

    const c0 = counters();
    assert(cmd.revert(),
        "M3: a REFUSED entry must still answer TRUE — a false revert makes "
      ~ "Command.revert fail, the funnel throw and the history entry be "
      ~ "discarded, which TRUNCATES the undo stack");
    const c1 = counters();

    assert(c1.bind - c0.bind == 1, format(
        "M3: mapDeltaBindRefused moved by %d, expected exactly 1. Name, dim "
      ~ "and domain all still match, so with the kind term gone the absolute "
      ~ "positions land in a RELATIVE channel and the vertex moves — the one "
      ~ "cell in the family where two maps are shape-identical.",
        c1.bind - c0.bind));
    assert(m.meshMap("MA").data == before,
        "M3: a refused entry must write NOTHING — refuse the entry WHOLE, "
      ~ "never partially and never as a zero-fill (the Stage F1 failure)");
}

unittest { // M3's control: with no drift the SAME command refuses nothing.
    scope (exit) clearMorphTarget();

    auto m = stand();
    auto v = freshView();
    const pre = dump(m);

    auto cmd = new MorphSet(m, v, EditMode.Vertices);
    setS(cmd, "name", "MA"); setI(cmd, "vert", 3);
    setF(cmd, "x", 0.7f); setF(cmd, "y", -0.3f); setF(cmd, "z", 0.25f);
    const c0 = counters();
    assert(cmd.apply(), "M3-control: the forward must apply");
    assert(cmd.recordedUndo().armed(), "M3-control: the delta path must be taken");
    assert(dump(m) != pre, "M3-control: the forward must move a plane");
    assert(cmd.revert(), "M3-control: the undo must succeed");
    planesEqual("M3-control", pre, dump(m));
    countersUnmoved("M3-control", c0);
}

// ===========================================================================
// M4 — ALL FOUR `MapOp` ARMS, from production recorders.
//
// One row per arm, each asserting the arm AND the addressing, because the two
// create spellings differ only in the addressing and that difference is
// whether a redo restores a morphAbsolute's dense base or replaces it with
// zeros.
//
// MUTATION: in `MorphCreate.createKernel`, call `recordMapCreate` on the
// absolute branch instead of `recordMapCreateFilledOwned` -> the create row's
// addressing reads `DefaultInit`, and the FORWARD-replay row below reddens on
// the content.
// ===========================================================================
unittest {
    scope (exit) clearMorphTarget();
    auto v = freshView();

    // ---- Create, filled (absolute) ---------------------------------------
    {
        auto m = stand();
        auto c = new MorphCreate(m, v, EditMode.Vertices);
        setS(c, "name", "MB"); setS(c, "kind", "absolute");
        assert(c.apply(), "M4/create: the forward must apply");
        assert(c.recordedUndo().armed(), "M4/create: the delta path must be taken");
        auto e = oneEntry("M4/create", c.recordedUndo().delta().log,
                          MeshOpEntry.Kind.MapValueDelta);
        assert(e.mapOp == MeshOpEntry.MapOp.Create, format(
            "M4/create: recorded %s", e.mapOp));
        assert(e.mapAddr == MeshOpEntry.MapAddressing.WholeArray, format(
            "M4/create: an ABSOLUTE morph map is created DENSE (an entry per "
          ~ "vertex, holding its base position), so its create must carry the "
          ~ "content — `MeshSessionEdit` replays a delta FORWARD for redo and "
          ~ "a DefaultInit create would silently bring the map back with every "
          ~ "vertex at the base. Recorded %s.", e.mapAddr));
        assert(e.mapValsAfter.length == m.vertices.length * 3, format(
            "M4/create: the carried content is %d floats for %d vertices",
            e.mapValsAfter.length, m.vertices.length));
    }

    // ---- Create, default-init (relative) ---------------------------------
    {
        auto m = stand();
        auto c = new MorphCreate(m, v, EditMode.Vertices);
        setS(c, "name", "MB"); setS(c, "kind", "relative");
        assert(c.apply(), "M4/create-rel: the forward must apply");
        auto e = oneEntry("M4/create-rel", c.recordedUndo().delta().log,
                          MeshOpEntry.Kind.MapValueDelta);
        assert(e.mapAddr == MeshOpEntry.MapAddressing.DefaultInit, format(
            "M4/create-rel: a RELATIVE morph map is created EMPTY, so the "
          ~ "faithful spelling carries no array at all. Recorded %s.", e.mapAddr));
        assert(e.mapValsAfter.length == 0,
            "M4/create-rel: DefaultInit must carry no content");
    }

    // ---- Remove ----------------------------------------------------------
    {
        auto m = stand();
        auto c = new MorphRemove(m, v, EditMode.Vertices);
        setS(c, "name", "MA");
        assert(c.apply(), "M4/remove: the forward must apply");
        auto e = oneEntry("M4/remove", c.recordedUndo().delta().log,
                          MeshOpEntry.Kind.MapValueDelta);
        assert(e.mapOp == MeshOpEntry.MapOp.Remove, format("M4/remove: %s", e.mapOp));
        assert(e.mapValsBefore.length == m.vertices.length * 3
            && e.presentBefore.length == m.vertices.length, format(
            "M4/remove: the reverse RE-REGISTERS the map, so the whole content "
          ~ "is the payload — both channels. Got %d floats / %d presence bytes.",
            e.mapValsBefore.length, e.presentBefore.length));
        assert(e.mapSlot == 4, format(
            "M4/remove: the registry SLOT must be recorded — MA sits at index "
          ~ "4 of `uv W uv2 crease MA MR` on this stand (measured), i.e. NOT "
          ~ "at the end, which is the only arrangement that can exhibit the "
          ~ "failure. Got %d. "
          ~ "`removeMeshMap` splices and the re-registration APPENDS, so "
          ~ "without the slot the undo brings the map back in the wrong place "
          ~ "and `meshPlanesJson` — which reads `meshMaps` in ARRAY ORDER — "
          ~ "sees it.", e.mapSlot));
    }

    // ---- Rename ----------------------------------------------------------
    {
        auto m = stand();
        auto c = new MorphRename(m, v, EditMode.Vertices);
        setS(c, "from", "MA"); setS(c, "to", "MZ");
        assert(c.apply(), "M4/rename: the forward must apply");
        auto e = oneEntry("M4/rename", c.recordedUndo().delta().log,
                          MeshOpEntry.Kind.MapValueDelta);
        assert(e.mapOp == MeshOpEntry.MapOp.Rename, format("M4/rename: %s", e.mapOp));
        assert(e.mapName == "MA" && e.mapNameTo == "MZ", format(
            "M4/rename: the arm exists so this payload is TWO STRINGS rather "
          ~ "than the whole map (measured: 3.05 MB against ~500 B). Got "
          ~ "`%s` -> `%s`.", e.mapName, e.mapNameTo));
        assert(e.mapValsBefore.length == 0 && e.mapValsAfter.length == 0, format(
            "M4/rename: a rename that carries arrays is a Remove+Create in "
          ~ "disguise and moves four classes of this family out of mode A"));
    }
}

// ===========================================================================
// M4b — the CREATE arm's FORWARD is faithful, driven from the production
// recorder. `session_edit.d:140` (`if (useDelta_) delta_.apply(*mesh);`) is a
// shipped forward-replay consumer, so a reverse-faithful create is a silent
// data loss for every factory built on that carrier.
//
// MUTATION: as M4's — record the absolute create as `DefaultInit`. The map
// then exists on the replay with the right name, domain, dim AND LENGTH, and
// only its contents are zeros with every entry absent, which for
// `morphAbsolute` means every vertex "stays at the base".
// ===========================================================================
unittest {
    scope (exit) clearMorphTarget();

    auto m = stand();
    auto v = freshView();
    auto c = new MorphCreate(m, v, EditMode.Vertices);
    setS(c, "name", "MB"); setS(c, "kind", "absolute");
    assert(c.apply(), "M4b: the forward must apply");
    auto created = m.meshMap("MB");
    assert(created !is null, "M4b: the forward must register the map");
    const wantData = created.data.dup;
    const wantPres = created.present.dup;
    bool anyPresent = false;
    foreach (b; wantPres) if (b) { anyPresent = true; break; }
    assert(anyPresent && wantData.length > 0,
        "M4b: an ABSOLUTE create must land DENSE, or 'the content came back' "
      ~ "is true of a default-init replay too and this cell is vacuous");

    // A FRESH stand, replayed FORWARD — the redo path `MeshSessionEdit` takes.
    auto m2 = stand();
    assert(c.recordedUndo().delta().apply(*m2), "M4b: the forward replay must run");
    auto replayed = m2.meshMap("MB");
    assert(replayed !is null, "M4b: the forward replay must REGISTER the map");
    assert(replayed.data == wantData, format(
        "M4b: the forward replay produced different data — the map exists "
      ~ "with the right name, domain, dim and LENGTH, and only its contents "
      ~ "are wrong, which for morphAbsolute means every vertex 'stays at the "
      ~ "base'. %d floats differ in length or value.", replayed.data.length));
    assert(replayed.present == wantPres,
        "M4b: the forward replay lost the presence channel");
}

// ===========================================================================
// M5 — THE POSITION WRITE. `mesh.morph.apply` bakes the map into the base, so
// its payload is `Kind.SetPos` and NOT a map kind: the map is left exactly as
// it was (measured, `freeze_deform_keeps_the_map`).
//
// MUTATION: replace `ed.setVertexPositions(...)` in `MorphApplyCmd.applyKernel`
// with a raw `ed.mesh.vertices[i] = …` loop. A raw coordinate write records
// NOTHING under an open batch, so the delta comes back EMPTY, the holder stays
// disarmed and `revert()` answers false — the first assertion below reddens
// and names it.
// ===========================================================================
unittest {
    scope (exit) clearMorphTarget();

    auto m = stand();
    auto v = freshView();
    const pre = dump(m);
    const c0 = counters();

    auto c = new MorphApplyCmd(m, v, EditMode.Vertices);
    setS(c, "name", "MA"); setF(c, "amount", 1.0f);
    assert(c.apply(), "M5: the forward must apply");
    assert(dump(m) != pre, "M5: the bake must move the vertex plane");

    assert(c.recordedUndo().armed(),
        "M5: mesh.morph.apply recorded NO delta. A raw `vertices[i] = …` write "
      ~ "is invisible to the batch's hooks, so the undo would restore the map "
      ~ "planes (there are none here) and leave the coordinates at their "
      ~ "post-op values");
    auto e = oneEntry("M5", c.recordedUndo().delta().log, MeshOpEntry.Kind.SetPos);
    assert(e.vIdx.length > 0 && e.posBefore.length == e.vIdx.length, format(
        "M5: SetPos must carry one before-image per touched vertex; got %d "
      ~ "indices and %d images", e.vIdx.length, e.posBefore.length));
    assert(e.mapName.length == 0, format(
        "M5: this command writes POSITIONS and leaves the map untouched, so "
      ~ "its entry must carry no map identity at all — got `%s`", e.mapName));

    assert(c.revert(), "M5: the undo must succeed");
    planesEqual("M5", pre, dump(m));
    countersUnmoved("M5", c0);
}

// ===========================================================================
// M6 — THE NON-MESH UNDO TAIL. Creating a map STEALS the routing target
// (measured, `new_map_steals_the_selection`) and the undo drops it; a rename
// RETARGETS and its undo re-points at the old name. `morph_target` is app
// state, so NO plane dump — the frozen parity oracle included — can see any of
// this, which is why it needs its own cell.
//
// MUTATION: delete `forgetMorphTargetIfNamed(name_)` from `MorphCreate.revert`
// -> the first block reddens with a binding that outlived its map. Delete the
// retarget from `MorphRename.revert` -> the second does. Isolated runs.
// ===========================================================================
unittest {
    scope (exit) clearMorphTarget();
    auto v = freshView();

    {   // create steals; undo leaves nothing bound to a map that is gone
        auto m = stand();
        clearMorphTarget();
        auto c = new MorphCreate(m, v, EditMode.Vertices);
        setS(c, "name", "MB"); setS(c, "kind", "relative");
        assert(c.apply(), "M6/create: the forward must apply");
        assert(morphTargetName() == "MB",
            "M6/create: creating a map must STEAL the routing target, or the "
          ~ "undo below has nothing to release");
        assert(c.revert(), "M6/create: the undo must succeed");
        assert(m.meshMap("MB") is null, "M6/create: the undo must drop the map");
        assert(morphTargetName() != "MB", format(
            "M6/create: the routing target still names `%s` after the undo "
          ~ "removed it. Every later edit routes into a map that does not "
          ~ "exist, and no plane dump can see this.", morphTargetName()));
    }

    {   // rename retargets; undo re-points at the old name
        auto m = stand();
        clearMorphTarget();
        setMorphTarget("MA", MapKind.morphAbsolute);
        auto c = new MorphRename(m, v, EditMode.Vertices);
        setS(c, "from", "MA"); setS(c, "to", "MZ");
        assert(c.apply(), "M6/rename: the forward must apply");
        assert(morphTargetName() == "MZ",
            "M6/rename: the map the user is editing did not go away, it "
          ~ "changed name — the forward must retarget or the undo is vacuous");
        assert(c.revert(), "M6/rename: the undo must succeed");
        assert(morphTargetName() == "MA", format(
            "M6/rename: after the undo the target names `%s`, expected `MA`. "
          ~ "The tail reads the mesh AFTER the restore, so the order of the "
          ~ "two statements in revert() is load-bearing.", morphTargetName()));
    }
}

// ===========================================================================
// M7 — THE CARVE-OUT IS TAKEN, with its control.
//
// A `MapValueDelta`-only log is index-space stable, so the replay must skip
// `rebuildEdges` / `buildLoops` entirely and must not move `topologyVersion`.
// The control is the SAME harness over `mesh.morph.apply`'s `SetPos` log,
// which is equally stable — and a topology op, which is not.
//
// MUTATION: classify `MapValueDelta` UNSTABLE in `kindHoldsIndexSpace` -> the
// counters read 1/1 here. Without the control rows the zeros are a dead cell.
// ===========================================================================
unittest {
    version (unittest) {
        scope (exit) clearMorphTarget();

        auto m = stand();
        auto v = freshView();
        auto c = new MorphSet(m, v, EditMode.Vertices);
        setS(c, "name", "MA"); setI(c, "vert", 3); setF(c, "x", 0.5f);
        assert(c.apply(), "M7: the forward must apply");
        assert(c.recordedUndo().armed(), "M7: the delta path must be taken");

        const rb0 = g_rebuildEdgesRuns, bl0 = g_buildLoopsRuns;
        const tv0 = m.topologyVersion, mv0 = m.mutationVersion;
        assert(c.revert(), "M7: the undo must succeed");

        assert(g_rebuildEdgesRuns == rb0 && g_buildLoopsRuns == bl0, format(
            "M7: a MapValueDelta-only undo ran rebuildEdges %d time(s) and "
          ~ "buildLoops %d time(s); both must be 0. The whole point of the "
          ~ "carve-out is that a map write moves no index space.",
            g_rebuildEdgesRuns - rb0, g_buildLoopsRuns - bl0));
        assert(m.topologyVersion == tv0, format(
            "M7: topologyVersion moved by %d on a map-value undo. It is the "
          ~ "subpatch-preview and GPU layout key; only the crease channel owes "
          ~ "a bump.", m.topologyVersion - tv0));
        assert(m.mutationVersion > mv0,
            "M7: the undo published nothing — a map plane changed and every "
          ~ "map-value cache keys on mutationVersion");

        // THE CONTROL, in the same harness: a real topology edit DOES rebuild.
        // Without it the three zeros above are satisfied by a replay that
        // never ran.
        auto m2 = stand();
        const rb1 = g_rebuildEdgesRuns;
        m2.rebuildEdges();
        assert(g_rebuildEdgesRuns == rb1 + 1,
            "M7 control: the instrument does not count — the zeros above are "
          ~ "a dead cell");
    }
}

// ===========================================================================
// M8 — A REDO RECORDS NOTHING. `CommandHistory.redo` re-runs `apply()`, and an
// armed command must re-run its kernel UNRECORDED and keep the FIRST delta:
// §K.5 rule 2, the obligation L0-d paid for when element-wise bookkeeping on
// an unrecorded path made four commands twice as slow.
//
// Measured through `changeBus.opLogEntriesRecorded`, which `closeEditFrame`
// advances by the log length of every batch that closes — so this row sees a
// second recording even though the second delta would have the same SHAPE as
// the first and no result-shaped assertion could tell them apart.
//
// MUTATION: delete the `undo.armed()` arm from `runMapEdit` -> the redo opens
// a RECORDING batch and the counter moves by 1.
// ===========================================================================
unittest {
    scope (exit) clearMorphTarget();

    auto m = stand();
    auto v = freshView();
    auto c = new MorphSet(m, v, EditMode.Vertices);
    setS(c, "name", "MA"); setI(c, "vert", 3); setF(c, "x", 0.5f);

    const n0 = changeBus.opLogEntriesRecorded;
    assert(c.apply(), "M8: the forward must apply");
    const n1 = changeBus.opLogEntriesRecorded;
    assert(n1 - n0 == 1, format(
        "M8: the FIRST apply recorded %d op-log entries, expected 1 — the "
      ~ "instrument is not counting and the redo row below is vacuous",
        n1 - n0));

    assert(c.revert(), "M8: the undo must succeed");
    assert(c.apply(), "M8: the REDO must apply");
    const n2 = changeBus.opLogEntriesRecorded;
    assert(n2 == n1, format(
        "M8: the redo recorded %d further op-log entries. An armed command "
      ~ "must re-run its kernel through an UNRECORDED batch: a second delta "
      ~ "over the first costs the whole payload again and leaves the history "
      ~ "holding an image of the wrong moment.", n2 - n1));
    assert(c.recordedUndo().armed() && c.recordedUndo().delta().log.length == 1,
        "M8: the FIRST delta must survive the redo");
}
