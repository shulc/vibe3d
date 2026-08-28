// l6_duplicate_delta_test — the witnesses stage L6 owes that a frozen plane
// fixture cannot carry (task 1903; `undo_parity_l6_test.d` carries the
// plane-for-plane oracle, this file carries the SHAPE assertions, the refusals
// and the two rate/latency claims).
//
// LANE. All of it is `dub test --config=tests` (lane U) — `./run_test.d` never
// runs a `tests/unit/**` unittest block. The COMMAND-CONSTRUCTOR half of the
// seam, and the real undo STACK, are in lane S
// (`tests/test_l6_undo_depth.d`), because a unit cell that drives the KERNEL
// opens its own batch and stays green with the command still unrecorded.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — score a mutation that
// reddens two of these cells by running them in isolation.
module tests.unit.l6_duplicate_delta_test;

import std.conv   : to;
import std.format : format;

import change_bus : changeBus;
import command;
import math    : Vec3;
import mesh;
import mesh_edit_delta : MeshEditDelta, MeshEditScope, MeshOpEntry;
import view;
import editmode;

import tests.unit.fixtures : makeTaggedGridFull;

import commands.mesh.array_        : MeshArray;
import commands.mesh.clone_        : MeshClone;
import commands.mesh.duplicate_    : MeshDuplicate;
import commands.mesh.mirror_       : MeshMirror;
import commands.mesh.radial_array_ : MeshRadialArray;
import tests.unit.undo_parity_l0_test : setF, setI, setV, setS;

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

private string windingsOf(in Mesh m)
{
    string s;
    foreach (fi, ref f; m.faces) s ~= f.to!string ~ ";";
    return s;
}

// ---------------------------------------------------------------------------
// W-6-a1 — `mesh.duplicate` INSIDE A RECORDING BATCH: the op-log KIND SEQUENCE
// is `[AddVerts, AddFaces]`, `apply()` answers TRUE, `revert()` answers TRUE,
// and the geometry is back.
//
// BOTH THE STATUS AND THE GEOMETRY ARE ASSERTED, and that pairing is the whole
// point of this cell. Delete `Mesh.recordBulkAppendRound`'s call in
// `duplicateSelectedFaces` and the log goes EMPTY over a real mutation;
// `acceptRecordedEdit` refuses that, `apply()` returns FALSE, and the command
// never records a history entry — so a cell that only checked the geometry
// after the "undo" would be asserting about a mesh nobody undid, and would be
// GREEN. The status assert is what reddens.
//
// `emptyDeltaOverMutation` is asserted SEPARATELY from the status, because
// `apply()` answering false covers both the honest refusal (`affected == 0`)
// and the missing publisher, and one assertion cannot tell them apart.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    immutable size_t preV = m.vertices.length, preF = m.faces.length;
    immutable string preW = windingsOf(*m);
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshDuplicate(m, v, EditMode.Polygons);

    assert(c.apply(), "mesh.duplicate refused the stand. If the op-log is "
        ~ "EMPTY over a real duplication, `acceptRecordedEdit` refuses it and "
        ~ "THIS is where that surfaces — as status:error over a changed "
        ~ "document, not as a bad undo");
    assert(changeBus.emptyDeltaOverMutation == e0, format(
        "mesh.duplicate closed a recording batch with an EMPTY delta over a "
      ~ "real mutation (counter +%d)", changeBus.emptyDeltaOverMutation - e0));

    assert(kindsOf(c.recordedDelta()) == "AddVerts AddFaces", format(
        "mesh.duplicate recorded [%s], expected [AddVerts AddFaces]. This "
      ~ "kernel has no weld and no compaction, so those two entries ARE the "
      ~ "whole log — nothing else can be credited for the restore",
        kindsOf(c.recordedDelta())));

    assert(m.vertices.length > preV && m.faces.length > preF,
        "the forward duplicated nothing");

    assert(c.revert(), "mesh.duplicate's revert() answered false");
    assert(m.vertices.length == preV && m.faces.length == preF, format(
        "revert left V=%d F=%d against a pre-op %d/%d",
        m.vertices.length, m.faces.length, preV, preF));
    assert(windingsOf(*m) == preW,
        "revert restored the counts but not every winding");
}

// ---------------------------------------------------------------------------
// W-6-a2 — `mesh.clone`'s `weld = 0` PIN, asserted at the cell.
//
// MUTATION: change the pin in `commands/mesh/clone_.d` to `mesh.array`'s
// default 0.001. The class silently acquires a weld path, its op-log grows the
// `[MeshMapDelta, FaceReindex, RemoveVerts, Reindex]` tail, and the cell stops
// isolating the APPEND publisher and starts measuring the WELD publisher. The
// KIND SEQUENCE is what sees that; a zero-offset geometry check alone would
// too, so both are here — the sequence names the cause and the geometry names
// the effect.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    immutable size_t preV = m.vertices.length;
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshClone(m, v, EditMode.Polygons);
    setV(cast(Command) c, "offset", Vec3(0, 0, 0));   // ZERO offset

    assert(c.apply(), "mesh.clone refused a zero-offset clone");
    assert(kindsOf(c.recordedDelta()) == "AddVerts AddFaces", format(
        "mesh.clone recorded [%s], expected [AddVerts AddFaces]. A "
      ~ "`RemoveVerts` in there means the `weld = 0` pin in "
      ~ "commands/mesh/clone_.d is gone and this cell now measures the WELD "
      ~ "publisher instead of the APPEND publisher",
        kindsOf(c.recordedDelta())));
    assert(m.vertices.length == preV + 4, format(
        "a ZERO-offset clone of one face left V=%d, expected %d — the pin is "
      ~ "what keeps the coincident copy rather than folding it back",
        m.vertices.length, preV + 4));
    assert(c.revert() && m.vertices.length == preV,
        "mesh.clone's revert did not truncate the appended verts");
}

// ---------------------------------------------------------------------------
// W-6-a3 — THE APPEND RECORD IS PER ROUND, NEVER PER ELEMENT.
//
// `mesh.array` with `count = 8` over the whole visible mesh appends 7 copies of
// 8 faces = 56 faces and their vertices. The op-log must still carry ONE
// `AddVerts` and ONE `AddFaces` for the march round (plus the detach round's
// own `AddVerts` and its `[MeshMapDelta, ReshapeFaces]` pair).
//
// MUTATION: move the record inside the append loop (one `recordAddVert` /
// `recordAddFace` per element). The counts below become the appended-element
// counts, and `recordPolyVertexPayload`'s ordered sweep over `faces` runs once
// per element — card 2260 measured that shape at 31x (3 600 faces) and 66x
// (10 000).
//
// COUNTED, NOT TIMED, IN THIS CELL. The time claim is card 2260's and is not
// re-measured here: a wall-clock assertion inside the unit lane is a flake
// generator on a loaded host, and the ENTRY COUNT is the thing that makes the
// time what it is. What this cell owns is the shape; the card owns the number.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    m.clearFaceSelection();          // ⇒ every VISIBLE face is the operand
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshArray(m, v, EditMode.Polygons);
    setI(cast(Command) c, "count",  8);
    setV(cast(Command) c, "offset", Vec3(4, 0, 0));   // far apart: no weld
    setF(cast(Command) c, "weld",   0.0f);

    immutable size_t preF = m.faces.length;
    assert(c.apply(), "mesh.array count=8 refused the stand");
    assert(m.faces.length >= preF + 7 * 8, format(
        "the array appended only %d face(s); this cell is about a BULK round "
      ~ "and needs a big one", m.faces.length - preF));

    size_t addVerts, addFaces;
    foreach (ref e; c.recordedDelta().log) {
        if (e.kind == MeshOpEntry.Kind.AddVerts) ++addVerts;
        if (e.kind == MeshOpEntry.Kind.AddFaces) ++addFaces;
    }
    // TWO `AddVerts`: the detach round and the march round, recorded either
    // side of the detach's `Mesh.setFaceWindings` entry so the LIFO reverse
    // restores the original windings BEFORE truncating the seam duplicates.
    // ONE `AddFaces`: only the march round appends faces.
    assert(addVerts == 2 && addFaces == 1, format(
        "mesh.array count=8 recorded %d AddVerts and %d AddFaces entr(ies), "
      ~ "expected 2 and 1 — one per ROUND. A number near the appended-element "
      ~ "count means the record moved inside the append loop, which is the "
      ~ "31x/66x shape card 2260 measured. Log: [%s]",
        addVerts, addFaces, kindsOf(c.recordedDelta())));
}

// ---------------------------------------------------------------------------
// W-6-b2 — THE DETACH PATH'S WINDING INSTALL ROUND-TRIPS.
//
// `Mesh.arrayFaces`' detach pass repoints every SOURCE face at freshly
// duplicated verts. It is arity-PRESERVING, so V, F, E, every mark word,
// `faceMaterial`, `facePart` and both set masks round-trip whether or not the
// repoint is restored — ONLY a per-winding compare can see it.
//
// TWO MUTATIONS, TWO DIFFERENT REDS — AND NEITHER IS THE SILENT ONE §5.5
// PREDICTED. Both were run; what they actually produce is written here rather
// than what the row expected:
//   * put the raw `faces[fi][k] = seamMap[vid];` back (no `setFaceWindings`
//     call at all): the forward is byte-identical and the log becomes
//     `[AddVerts AddVerts AddFaces]` — the `[MeshMapDelta, ReshapeFaces]` pair
//     is gone. The KIND SEQUENCE below is what reddens FIRST. With that
//     assertion suppressed, the revert does NOT quietly leave the wrong
//     windings: it THROWS out of `finalize` -> `buildLoops`
//     (`index [16] is out of bounds for array of length 16`), because the
//     `AddVerts` reverse truncates away the seam duplicates the unrestored
//     windings still point at. So the missing publisher is LOUD here, exactly
//     as task 2320 measured for `insetFacesByMask`.
//   * hand the accumulator DESCENDING: `Mesh.setFaceWindings` carries an
//     ALWAYS-ON ascending assert and dies at the door —
//     "`idx` must be strictly ascending". §L6.7's W-6-b2 predicted a SILENT
//     decline leaving "only the windings wrong"; that is false of this door.
//
// THE WINDING COMPARE BELOW IS THEREFORE THE CONSEQUENCE, NOT THE
// DISCRIMINATOR, and is labelled as such: it states what correct code must
// satisfy, while the kind sequence is what a mutation moves.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();                 // face 7 selected ⇒ a strict SUBSET
    immutable string preW = windingsOf(*m);
    immutable size_t preV = m.vertices.length;

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshArray(m, v, EditMode.Polygons);
    setI(cast(Command) c, "count",  2);
    setV(cast(Command) c, "offset", Vec3(4, 0, 0));   // far apart: NO weld
    setF(cast(Command) c, "weld",   0.0f);

    assert(c.apply(), "mesh.array refused the subset stand");

    // The detach really ran: the source face's winding MOVED on the forward.
    assert(m.faces[7] != [9u, 10u, 14u, 13u], format(
        "face 7 is still %s after a subset array — `detachSubsetSource` did "
      ~ "not fire, so this cell measures no repoint at all",
        m.faces[7].to!string));

    assert(kindsOf(c.recordedDelta())
        == "AddVerts MeshMapDelta ReshapeFaces AddVerts AddFaces", format(
        "mesh.array recorded [%s], expected [AddVerts MeshMapDelta "
      ~ "ReshapeFaces AddVerts AddFaces]. The `[MeshMapDelta, ReshapeFaces]` "
      ~ "PAIR is the detach's winding install; without it the revert leaves "
      ~ "every source face repointed at its duplicate while V/F/E and every "
      ~ "mark word round-trip", kindsOf(c.recordedDelta())));

    assert(c.revert(), "mesh.array's revert() answered false");
    assert(m.vertices.length == preV, "revert left appended verts behind");
    // The CONSEQUENCE (see the block comment): correct code must satisfy this,
    // and no mutation tried here reaches it without tripping something louder
    // first.
    assert(windingsOf(*m) == preW, format(
        "revert restored the counts but NOT the detached source windings.\n"
      ~ "  pre : %s\n  post: %s", preW, windingsOf(*m)));
}

// ---------------------------------------------------------------------------
// W-6-c1 — `mesh.mirror`'s `isEmpty()` ROLLBACK ARM, and the CHANNEL that can
// actually see it.
//
// WHAT THE ARM IS. `Mesh.mirrorFacesPlane` restores fifteen arrays by direct
// assignment when a weld collapses the whole document, WHILE the weld's
// `[MeshMapDelta, FaceReindex, RemoveVerts, Reindex]` entries survive in the
// op-log. If it ever runs inside a recording batch, the reverse replays those
// entries against geometry that was already put back — and no invariant
// counter fires, because the batch still opens once and closes once.
//
// THE ARM IS MEASURED UNREACHABLE from this command. `pairsMustCrossBound`
// keeps every original alive, so `faces` can never empty: a 480-cell sweep —
// two operand scopes x fifteen weld values up to 1e6 x four planes x both
// `flipNormals` settings — never entered it, against a positive control that
// entered it 224 times with the guard forced true.
//
// THE PLAN'S OWN CHANNEL FOR THIS CANNOT COME OUT DIFFERENTLY, and that is
// measured, not argued. §L6.7's W-6-c1 says to assert that `vertices.length`
// comes back "EXACTLY, not above it". It cannot come back above it: the
// reverse of `Kind.AddVerts` is `m.vertices.length = v0` and of
// `Kind.AddFaces` is `m.faces.length = f0` — TRUNCATIONS TO AN ABSOLUTE BASE,
// replayed LAST because they were recorded FIRST. Whatever the middle entries
// do, V and F land on the pre-op values. Measured: with the guard forced to
// `true`, the forward leaves V=32 (the un-welded mirror) and the revert still
// lands on 16/9/24 at every weld value. A count assertion here is green on the
// broken code.
//
// WHAT DOES REDDEN IS THE PER-CORNER MAP, and only at a weld that actually
// collapsed something before the rollback undid it. Measured with the guard
// forced true: at weld 0.001 the residual is unchanged (five Select-class
// planes), and at weld 100 it gains `map:uv` — the orphaned `FaceReindex`
// reverse relocating corners the rollback had already put back. So the cell
// asserts the counts as a CONSEQUENCE (they must hold) and the per-corner map
// as the DISCRIMINATOR (it is what moves), and says which is which.
// ---------------------------------------------------------------------------
private string uvOf(in Mesh m)
{
    auto uv = m.meshMap(kUvMapName);
    if (uv is null) return "<no map>";
    string s;
    foreach (i, f; uv.data) s ~= (i ? "," : "") ~ format("%.9g", f);
    return s;
}

unittest
{
    foreach (weld; [0.001f, 1.0f, 100.0f, 1.0e6f]) {
        auto m = stand();
        m.clearFaceSelection();          // whole visible mesh
        immutable size_t preV = m.vertices.length;
        immutable size_t preF = m.faces.length;
        immutable size_t preE = m.edges.length;
        immutable string preUv = uvOf(*m);

        auto v = new View(0, 0, 800, 600);
        auto c = new MeshMirror(m, v, EditMode.Polygons);
        setS(cast(Command) c, "axis",   "X");
        setV(cast(Command) c, "center", Vec3(1, 0, 0));
        setF(cast(Command) c, "weld",   weld);

        assert(c.apply(), format("mesh.mirror refused at weld=%g", weld));
        assert(m.faces.length > 0 && m.vertices.length > 0, format(
            "mesh.mirror emptied the mesh at weld=%g and still answered ok",
            weld));

        assert(c.revert(), format("mesh.mirror revert() false at weld=%g", weld));

        // THE CONSEQUENCE. Kept, and labelled: these three CANNOT come back
        // wrong for this kernel (see the block comment), so they are here to
        // hold the contract, not to discriminate.
        assert(m.vertices.length == preV && m.faces.length == preF
            && m.edges.length == preE, format(
            "weld=%g: the revert landed on V=%d F=%d E=%d against a pre-op "
          ~ "%d/%d/%d", weld, m.vertices.length, m.faces.length,
            m.edges.length, preV, preF, preE));

        // THE DISCRIMINATOR. Forcing the `isEmpty()` arm to run reddens HERE
        // and nowhere else in this file, at weld 100 and 1e6.
        assert(uvOf(*m) == preUv, format(
            "weld=%g: the per-corner UV map did not come back. That is the "
          ~ "`isEmpty()` rollback arm's signature: it restores fifteen arrays "
          ~ "by direct assignment while the weld's [MeshMapDelta, FaceReindex, "
          ~ "RemoveVerts, Reindex] entries SURVIVE in the op-log, so the "
          ~ "reverse relocates corners that were already put back. No counter "
          ~ "fires on it — the batch still opens once and closes once.\n"
          ~ "  pre : %s\n  post: %s", weld, preUv, uvOf(*m)));
    }
}

// ---------------------------------------------------------------------------
// THE REFUSAL CONTRACT, per class. `evaluate` false ⇒ `apply` false ⇒ the
// funnel throws ⇒ `status:error` and NO history entry.
//
// NOT FROZEN IN THE FIXTURE, deliberately: a refusal leaves
// `postOp == postUndo == pre`, which `compareOrCapture`'s anti-vacuity assert
// rejects — and a frozen pair of identical dumps is a check that cannot come
// out differently.
//
// THREE ASSERTIONS PER ROW, because `apply() == false` and "the mesh did not
// change" are BOTH satisfied by a stand that was never built: the refusal, the
// unchanged mesh, AND a control on the same stand that applies. Plus a fourth
// this stage owes specifically — `emptyDeltaOverMutation` must NOT move, since
// the counter is what separates "refused honestly" from "mutated and recorded
// nothing", and only the second is a defect.
// ---------------------------------------------------------------------------
private void assertRefuses(string row, Command c, Mesh* m, ulong e0)
{
    immutable string preW = windingsOf(*m);
    immutable size_t preV = m.vertices.length, preF = m.faces.length;

    assert(!c.apply(), row ~ ": expected a refusal, got a successful apply");
    assert(m.vertices.length == preV && m.faces.length == preF
        && windingsOf(*m) == preW,
        row ~ ": a REFUSED command changed the mesh");
    assert(changeBus.emptyDeltaOverMutation == e0, format(
        "%s: the refusal ticked emptyDeltaOverMutation (+%d). That counter "
      ~ "means MUTATED-AND-RECORDED-NOTHING, which is a defect; an honest "
      ~ "`affected == 0` refusal must not touch it",
        row, changeBus.emptyDeltaOverMutation - e0));
}

unittest // mesh.duplicate refuses with no face selected; the control applies
{
    auto m = stand();
    m.clearFaceSelection();
    auto v = new View(0, 0, 800, 600);
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;
    assertRefuses("mesh.duplicate/empty",
                  cast(Command) new MeshDuplicate(m, v, EditMode.Polygons),
                  m, e0);

    // THE CONTROL, on the same stand. Without it, every assertion above is
    // satisfied by a stand that cannot run anything at all.
    auto ok = new MeshClone(m, v, EditMode.Polygons);
    assert(ok.apply(),
        "mesh.duplicate/empty: the CONTROL refused too, so the assertions "
      ~ "above say the stand is broken rather than anything about the refusal");
}

unittest // mesh.array refuses at count <= 1 — a PRE-KERNEL gate
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshArray(m, v, EditMode.Polygons);
    setI(cast(Command) c, "count", 1);
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;
    assertRefuses("mesh.array/count1", cast(Command) c, m, e0);

    auto ok = new MeshArray(m, v, EditMode.Polygons);
    setI(cast(Command) ok, "count", 2);
    assert(ok.apply(), "mesh.array/count1: the CONTROL refused too");
}

unittest // mesh.mirror refuses an invalid axis
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshMirror(m, v, EditMode.Polygons);
    setS(cast(Command) c, "axis", "Q");
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;
    assertRefuses("mesh.mirror/badAxis", cast(Command) c, m, e0);

    auto ok = new MeshMirror(m, v, EditMode.Polygons);
    setS(cast(Command) ok, "axis", "X");
    assert(ok.apply(), "mesh.mirror/badAxis: the CONTROL refused too");
}

unittest // mesh.radial_array refuses at count <= 1
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshRadialArray(m, v, EditMode.Polygons);
    setI(cast(Command) c, "count", 1);
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;
    assertRefuses("mesh.radial_array/count1", cast(Command) c, m, e0);

    auto ok = new MeshRadialArray(m, v, EditMode.Polygons);
    setI(cast(Command) ok, "count", 4);
    assert(ok.apply(), "mesh.radial_array/count1: the CONTROL refused too");
}

// ---------------------------------------------------------------------------
// A REFUSED INSTANCE'S `revert()` ANSWERS FALSE — and that is CORRECT here,
// not a violation of §S-5's "revert returns true on a no-op or a refusal".
//
// The rule is about `MeshEditDelta.revert`, which answers `true` over an empty
// log by construction, and about not adding
// `if (delta_.log.length == 0) return false;` to it. A COMMAND whose
// `evaluate` refused is a different thing: the funnel records NO history entry
// for it, so nothing ever calls its `revert()`, and answering `false` from a
// state where `preSel_` was never sized against this mesh is the honest
// answer. The primitive is asserted separately, right below.
// ---------------------------------------------------------------------------
unittest
{
    auto m = stand();
    m.clearFaceSelection();
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshDuplicate(m, v, EditMode.Polygons);
    assert(!c.apply(), "the stand must make mesh.duplicate refuse");
    assert(!c.revert(),
        "a REFUSED MeshDuplicate answered true from revert(). It holds no "
      ~ "delta and a nulled selection image; replaying that would run "
      ~ "`preSel_.restore` over a mesh it was never sized against");

    // THE PRIMITIVE, which must answer the other way. A `false` from a Model
    // entry's revert pops the entry off BOTH stacks and truncates the suffix
    // behind it (regression 0099), so an empty delta MUST answer true.
    MeshEditDelta empty;
    assert(empty.revert(*m),
        "MeshEditDelta.revert answered FALSE over an empty log. Nothing in "
      ~ "this stage may add `if (log.length == 0) return false;` to it");
}
