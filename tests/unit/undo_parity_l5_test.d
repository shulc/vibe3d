// undo_parity_l5_test — the FROZEN parity fixture for stage L5's family
// (`mesh.cleanup`, `mesh.edgeCrease.set`, `mesh.edgeCrease.clear`), and the
// reader that makes it an oracle.
//
// WHY THIS FILE EXISTS, and why it had to land BEFORE the first source change
// that alters undo. Two independent grounds, §6.3 rule 1 and a stronger one
// that is specific to this family:
//
//   * `MeshCleanup` and the two `EdgeCrease*` classes hold the `MeshSnapshot`
//     that IS the comparison, and stages L5-c / L5-d delete it. From those
//     commits on there is no snapshot arm to compare the delta against, so the
//     comparison has to be captured while the arm still exists.
//   * THE WELD STAGE IS OP-LOG-INVISIBLE WITHOUT STAGE L5-a. Measured on
//     `makeTaggedGridDirty(3)` (2026-08-28): a RECORDING batch over
//     `cleanupMesh` with the weld alone enabled closes with an **EMPTY**
//     op-log, `revert()` answers **true**, and NOTHING is restored — face
//     count, vertex count, edge count and every mark word round-trip while
//     `faces` stays post-weld. So "the delta restores what the snapshot
//     restored" is not a nicety here; it is the only statement that separates
//     a correct migration from a `revert()` that answers true and changes
//     nothing.
//
// AND IT IS STRICTLY WIDER THAN ANY GATE IT REPLACES. `mesh.cleanup` had no
// undo gate at all beyond `MeshSnapshot`'s own; `edge_crease.d`'s two
// round-trip unittests compare the crease MAP and nothing else. This file
// compares every plane `meshPlanesJson` emits, on both dumps, on every cell.
//
// THE TWO DUMPS ARE NOT DECORATION — inherited verbatim from
// `undo_parity_l0_test`'s header. A fixture holding only the post-undo state
// is green for a cell whose FORWARD silently stopped doing anything, and green
// for a cell whose op and undo are both broken in the same direction.
//
// ---------------------------------------------------------------------------
// NO `setUndoTrackerEnabled` IN THIS RECIPE, and that is a measured statement
// rather than a copy of L2's rule. `grep -n 'undoTrackerEnabled' ` over
// `commands/mesh/cleanup.d` and `commands/mesh/edge_crease.d` returns NOTHING
// on the capture tree: neither file was ever on the hatch, so both arms of the
// flag run the same code here and flipping it would produce a fixture that
// compares a path against itself. L3's family WAS hatched, which is why its
// reader does the opposite; the difference is per family and is not a style.
//
// WHAT THAT COSTS, stated so it is not discovered later: the "both arms agree
// on the FORWARD" check L3's capture could make is unavailable here. The
// substitute is the same one L4 used — the capture runs with NO batch open
// while the migrated forward always opens one, so anything the batch changes
// in the forward is invisible at capture time. Stage L5-P0 therefore opened
// the axis-0 batches BEFORE this file was frozen, and the reader's three-way
// discrimination keeps "the forward changed" as its own branch.
//
// ---------------------------------------------------------------------------
// THE FILE IS IMMUTABLE FROM STAGE L5-a ONWARD. Re-freezing presupposes a
// producer, and once the snapshot arms are gone the only thing that can
// produce a `cleanup.json` is the delta path capturing itself — the migration
// grading its own homework, indistinguishable from a correct freeze. So:
//
//   * `postUndo` differs  ⇒ the migration restores LESS. Fix the code.
//   * `postOp`   differs  ⇒ the FORWARD changed. Louder, and out of L5's scope.
//   * a legitimate normalisation ⇒ a NAMED PER-PLANE EXCEPTION in this reader,
//     reviewed, with its reason at the exception. NOT a new `producedBy`.
//
// L3's finding is inherited as a WARNING and not as an expectation: its
// `faceSelectionOrder` divergence was a real, correct normalisation
// (`SelectionSnapshot.restore` zeroes the order stamp of every unselected
// element, task 0613 S3). If the same plane diverges here it takes the same
// argument, not a new one — and as a PIN, never a skip.
//
// ---------------------------------------------------------------------------
// A SEPARATE CAPTURE KEY, `VIBE3D_PARITY_CAPTURE_L5`, AND IT MAY WRITE EXACTLY
// ONE FILE. `VIBE3D_PARITY_CAPTURE` is process-wide and druntime runs every
// unittest module in ONE process: L0's and L1's readers both key on the bare
// name, so a shared key would silently re-freeze `position_marks.json` and
// `uv_maps_sets.json` in the same run — which is exactly what those files'
// headers forbid. L3 took a separate key for this reason and recorded the near
// miss; this is the third file to do it, and the `git status` of
// `tests/fixtures/undo_parity/` after a capture is the check that it worked.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l5_test;

import std.format : format;
import std.json   : JSONValue, parseJSON;

import command;
import mesh;
import view;
import editmode;
import math      : Vec3;
import http_json : meshPlanesJson, PlaneDumpMeta;

import tests.unit.fixtures            : makeTaggedGridDirty;
import tests.unit.undo_parity_l0_test : ParityCell, comparePlanes, fixturePath,
                                        fixtureJson, setF, setB,
                                        PlaneException, compareWithExceptions,
                                        assertExceptionTableWellFormed;
import tests.unit.undo_parity_l3_test : checkOrderNormalisation;

import commands.mesh.cleanup     : MeshCleanup;
import commands.mesh.edge_crease : EdgeCreaseSet, EdgeCreaseClear;

enum string kL5Family = "cleanup";
enum string kL5Stand  = "makeTaggedGridDirty(3)";

/// The tree that PRODUCED the frozen dumps.
///
/// NOT A BARE SHA, and the reason is a property of THIS stage rather than a
/// convenience. The other three parity fixtures name their lane's branch point
/// because nothing in the freezing commit changed the FORWARD. L5's does:
/// stage L5-P0 fixed a forward defect this very stand exposed — the weld
/// declares a corner-provenance relocation and rebuilds only EDGES, so on a
/// sweep where no later stage calls `buildLoops` (the weld-only cell, exactly)
/// the declaration was left outstanding across the command boundary and the
/// per-corner values stayed in the PRE-weld corner space. Freezing before that
/// fix would have frozen the bug as the oracle. So the capture tree is the
/// branch point PLUS L5-P0, and the token says so instead of naming a commit
/// whose dumps would differ.
///
/// What the reviewer checks is unchanged in substance: that the L5-P0 commit
/// precedes the freeze and that the freeze precedes L5-a/-c/-d, i.e. that no
/// dump here was produced by the delta path grading its own homework. The
/// reader below checks the field still says this, which is what makes a quiet
/// re-capture loud.
enum string kL5ProducedBy = "ed0e1ed7+L5-P0";

// ===========================================================================
// The stand, and the non-vacuity it owes BEFORE any cell runs.
//
// The stand's own four injections are asserted in `tests/unit/fixtures.d`,
// beside the function that builds them — three stages by COUNT and the fourth
// by its observable consequence (one `RemoveVerts` entry plus a vertex-count
// drop), because `r.orphans` reads 0 on a correct stand and an
// `orphans >= 1` assertion would redden on correct code. What is asserted HERE
// is what THIS FILE's cells read.
// ===========================================================================

private Mesh* l5Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridDirty(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

unittest // the stand can exhibit everything the roster claims to measure
{
    // MUTATION: build the stand on `makeTaggedGridFull(3)`. Item 1 fails by
    // name — `mesh.cleanup` REFUSES a clean grid (`anyAffected() == false`,
    // measured on this tree and on the perf lane's own exclusion list), so
    // every cell would go green under any implementation of the undo.
    auto m = l5Stand();

    assert(m.faces.length == 12 && m.vertices.length == 19,
        format("the stand is V=%d F=%d, expected V=19 F=12 — every index "
             ~ "constant in this file names a face or a vertex at random",
               m.vertices.length, m.faces.length));

    // ---- 1. the sweep must actually have work to do. Asserted through the
    // COMMAND rather than the kernel, because the command is what the cells
    // drive and `evaluate`'s `!anyAffected()` arm is what would refuse.
    {
        auto v = new View(0, 0, 800, 600);
        auto c = new MeshCleanup(m, v, EditMode.Polygons);
        assert(c.apply(),
            "mesh.cleanup REFUSED the stand — every cell below then freezes a "
          ~ "pair of identical dumps, which is a fixture recording nothing");
        assert(c.revert(), "…and its undo must succeed");
    }
    auto n = l5Stand();

    // ---- 2. a live PolyVertex map whose per-corner values are DISTINCT. A
    // value restored onto the WRONG corner must fail as loudly as one that
    // vanished.
    auto uv = n.meshMap(kUvMapName);
    assert(uv !is null && uv.domain == MapDomain.PolyVertex,
        "the stand carries no PolyVertex `" ~ kUvMapName ~ "` map — the "
      ~ "per-corner plane a face rewrite loses first is absent");
    bool[float] seenU;
    foreach (k; 0 .. uv.data.length / uv.dim) {
        immutable float u = uv.data[k * uv.dim];
        assert((u in seenU) is null,
            format("uv corner %d repeats the value %s — a value restored onto "
                 ~ "the wrong corner would compare EQUAL", k, u));
        seenU[u] = true;
    }

    // ---- 3. one face SELECTED and dropped, one SELECTED and surviving, and a
    // faceSelectionOrder that is not a function of the Select plane.
    assert(n.isFaceSelected(7) && n.isFaceSelected(9),
        "the stand's face selection is not {7, 9} — face 9 is the duplicate "
      ~ "the unify stage drops and face 7 the interior quad that survives. "
      ~ "With only one of the two, 'restored the selection' and 'restored "
      ~ "everything' are the same picture");
    assert(n.faceSelectionOrder[2] != 0 && n.faceSelectionOrder[6] != 0,
        "the stand's faceSelectionOrder is flat outside the selected faces — a "
      ~ "revert that drops the order plane would read identical");

    // ---- 4. a vertex IN A NAMED SET that the sweep welds away, and an
    // edge-set entry whose ENDPOINT disappears. Without both, stage L5-b's
    // whole subject is unreachable and its cells are vacuous.
    import mesh_selsets : selSetMembersVertex, selSetMembersEdge;
    auto vm = selSetMembersVertex(*n, "V");
    bool sawWeldedMember = false;
    foreach (vi; vm) if (vi == 16u) sawWeldedMember = true;
    assert(sawWeldedMember,
        format("vertex set \"V\" is %s and does not name vertex 16, the "
             ~ "coincident vertex the weld removes — `vertSetMaskBefore` then "
             ~ "has nothing to restore and L5-b's cells are vacuous", vm));
    auto em = selSetMembersEdge(*n, "E");
    bool sawVanishingEndpoint = false;
    foreach (pr; em) if (pr[0] == 17u || pr[1] == 17u) sawVanishingEndpoint = true;
    assert(sawVanishingEndpoint,
        format("edge set \"E\" is %s and names no edge with endpoint 17 — that "
             ~ "is the vertex the degenerate drop orphans, so no `edgeSetMask` "
             ~ "entry is dropped and L5-b's EDGE half is unreachable", em));

    // ---- 5. is per cell: every cell asserts its op actually moved something.
    // See `l5RunOnce`.

    // ---- the crease cells need a non-empty EDGE selection, or both refuse
    // pre-flight and freeze a refusal.
    size_t selEdges = 0;
    foreach (ei; 0 .. n.edges.length) if (n.isEdgeSelected(ei)) ++selEdges;
    assert(selEdges >= 2,
        format("the stand selects %d edge(s); the two crease cells need at "
             ~ "least two, or `mesh.edgeCrease.*` refuses on an empty "
             ~ "selection and its cell records nothing", selEdges));
}

// ===========================================================================
// The roster.
//
// SIX CELLS, and the plan's seventh — the REFUSAL — is deliberately NOT one of
// them. A refusing command leaves `postOp == postUndo == pre`, which is the
// exact shape `compareOrCaptureL5`'s anti-vacuity assert refuses, and freezing
// a pair of identical dumps is a check that cannot come out differently. The
// refusal is asserted directly instead, in its own block at the bottom of this
// file, where it can say what a refusal MEANS (false from `apply()`, no
// history entry, no batch leak, a byte-identical mesh).
//
// THE THREE AXIS-2-DECLINED CLASSES GET NO CELLS AT ALL. `Remesh`,
// `Subdivide` and `SubdivideFaceted` keep their `MeshSnapshot` by §6.6 (each
// builds a fresh `Mesh` and installs it wholesale, and two of them additionally
// use `snap.restore` as a FORWARD GIGO rollback, which a delta cannot serve).
// Freezing a snapshot oracle for a path that REMAINS the snapshot is a check
// that cannot come out differently.
// ===========================================================================

/// What a cell does to the stand before the command runs.
private alias Arrange = void function(Mesh*);

/// Which command a cell drives. A tagged enum rather than a delegate, so the
/// spec table can be a module-level immutable.
private enum L5Cmd { cleanup, creaseSet, creaseClear }

private struct L5CellSpec {
    string   name;
    L5Cmd    which;
    Arrange  arrange;
    // `mesh.cleanup`'s five stage toggles, in `CleanupOptions` order.
    bool     mergeVerts;
    bool     dropDegenerate;
    bool     unify;
    bool     removeOrphans;
    bool     dissolve2Valent;
}

private void arrNothing(Mesh* m) { }

/// The clear cell needs something to clear. Written through `setCreaseWeight`
/// DIRECTLY — outside the command under test — so the cell measures the clear
/// and not a set followed by a clear.
private void arrPreCrease(Mesh* m)
{
    size_t written = 0;
    foreach (ei; 0 .. m.edges.length) {
        if (!m.isEdgeSelected(ei)) continue;
        immutable ok = m.setCreaseWeight(ei, 0.625f);
        assert(ok, "the crease pre-write failed — the clear cell would then "
                 ~ "clear a map of zeroes and record nothing");
        ++written;
    }
    assert(written >= 2,
        "the crease pre-write touched fewer than two edges — a single-edge "
      ~ "crease plane is uniform and a restore onto the wrong edge compares "
      ~ "EQUAL");
}

private immutable L5CellSpec[] kL5Specs = [
    // Weld ALONE. The attribution cell for stage L5-a: with every other stage
    // off, anything this cell's undo restores is the weld's rewrite and
    // nothing else. Disarmed it froze an EMPTY op-log and a `revert()` that
    // answered true and changed nothing.
    L5CellSpec("mesh.cleanup/weld",       L5Cmd.cleanup, &arrNothing,
               true,  false, false, false, false),
    // Degenerate ALONE — the stage that was ALREADY armed at Stage K, present
    // so the two arms can be told apart rather than measured together.
    L5CellSpec("mesh.cleanup/degenerate", L5Cmd.cleanup, &arrNothing,
               false, true,  false, false, false),
    // The default sweep: four stages in one batch, one op-log.
    L5CellSpec("mesh.cleanup/full",       L5Cmd.cleanup, &arrNothing,
               true,  true,  true,  true,  false),
    // …and the opt-in sixth stage, which no other cell reaches.
    L5CellSpec("mesh.cleanup/dissolve",   L5Cmd.cleanup, &arrNothing,
               true,  true,  true,  true,  true),
    L5CellSpec("mesh.edgeCrease.set",     L5Cmd.creaseSet,   &arrNothing,
               false, false, false, false, false),
    L5CellSpec("mesh.edgeCrease.clear",   L5Cmd.creaseClear, &arrPreCrease,
               false, false, false, false, false),
];

/// What one run of one cell produced.
private struct CellRun {
    string postOp;
    string postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
    /// The whole face array rendered, before and after the op. The WELD's own
    /// cell needs it: a weld merges corners INSIDE existing windings and drops
    /// a face only when one falls below three distinct corners, so on the
    /// weld-only cell no count moves at all and a count-based non-vacuity
    /// assert would redden on CORRECT code. That is the same disease as a
    /// vacuous check, from the other side.
    string preWindings, postWindings;
}

private string windingsOf(in Mesh m)
{
    import std.conv : to;
    string s;
    foreach (fi, ref f; m.faces) s ~= f.to!string ~ ";";
    return s;
}

private Command makeCommand(in L5CellSpec s, Mesh* m, View v)
{
    final switch (s.which) {
        case L5Cmd.cleanup:
            auto c = new MeshCleanup(m, v, EditMode.Polygons);
            setB(c, "mergeVerts",      s.mergeVerts);
            setB(c, "dropDegenerate",  s.dropDegenerate);
            setB(c, "unify",           s.unify);
            setB(c, "removeOrphans",   s.removeOrphans);
            setB(c, "dissolve2Valent", s.dissolve2Valent);
            return cast(Command) c;
        case L5Cmd.creaseSet:
            auto c = new EdgeCreaseSet(m, v, EditMode.Edges);
            setF(c, "weight", 0.375f);
            return cast(Command) c;
        case L5Cmd.creaseClear:
            return cast(Command) new EdgeCreaseClear(m, v, EditMode.Edges);
    }
}

/// `stand → arrange → op → undo`, dumping after the op and again after the
/// undo. `apply()` and `revert()` are asserted, not merely called: a command
/// that refuses on the stand freezes a pair of identical dumps, which is a
/// green fixture recording nothing.
private CellRun l5RunOnce(in L5CellSpec s, in PlaneDumpMeta meta)
{
    auto m = l5Stand();
    s.arrange(m);

    CellRun r;
    r.preVerts    = m.vertices.length;
    r.preFaces    = m.faces.length;
    r.preWindings = windingsOf(*m);

    auto v = new View(0, 0, 800, 600);
    Command c = makeCommand(s, m, v);

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    r.postVerts    = m.vertices.length;
    r.postFaces    = m.faces.length;
    r.postWindings = windingsOf(*m);
    r.postOp       = meshPlanesJson(*m, meta);

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);

    return r;
}

/// Every L5 cell, in a fixed order, plus the cross-cell asserts no single cell
/// can make.
ParityCell[] l5Cells()
{
    auto meta = PlaneDumpMeta(kL5ProducedBy, "snapshot", kL5Family, kL5Stand);

    ParityCell[] out_;
    CellRun[string] runs;
    foreach (ref s; kL5Specs) {
        auto r = l5RunOnce(s, meta);
        runs[s.name] = r;
        out_ ~= ParityCell(s.name, "snapshot", r.postOp, r.postUndo);
    }

    // Non-vacuity item 5, per cell — and the channel is chosen PER CELL,
    // because the four `cleanup` cells do not all move a count.
    //
    // THE THREE THAT DROP SOMETHING, by count. `apply()` returning true is the
    // command's own word for it; this is the mesh's.
    foreach (nm; ["mesh.cleanup/degenerate", "mesh.cleanup/full",
                  "mesh.cleanup/dissolve"]) {
        auto r = runs[nm];
        assert(r.postFaces < r.preFaces || r.postVerts < r.preVerts,
            format("%s: the op left %d faces / %d vertices, same as before — "
                 ~ "every assertion about its undo is then satisfied by an "
                 ~ "undo that does nothing", nm, r.postFaces, r.postVerts));
    }
    // THE WELD-ONLY CELL, by WINDING — and the count assertion is inverted for
    // it rather than omitted. `weldCoincidentVertices` merges corners inside
    // existing windings and does NOT compact: with `removeOrphans` off the
    // welded-away vertex is simply left unreferenced, so V, F and E are all
    // unchanged and the ONLY visible effect is that two faces now name vertex
    // 1 where they named vertex 16. Measured, and it is the whole reason the
    // stage exists: face count, vertex count, edge count and every mark word
    // round-trip while `faces` does not, which is what a count-only revert
    // assertion cannot see.
    {
        auto r = runs["mesh.cleanup/weld"];
        assert(r.postFaces == r.preFaces && r.postVerts == r.preVerts,
            format("mesh.cleanup/weld moved a COUNT (%d/%d faces, %d/%d "
                 ~ "vertices). With every stage but the weld off, and the weld "
                 ~ "not compacting, nothing may be dropped — if something was, "
                 ~ "a stage toggle is not reaching the kernel and this cell is "
                 ~ "no longer the weld's attribution cell",
                   r.preFaces, r.postFaces, r.preVerts, r.postVerts));
        assert(r.postWindings != r.preWindings,
            "mesh.cleanup/weld left every winding where it found it — the weld "
          ~ "fired on nothing, and since it moves no count either, this cell "
          ~ "then records a forward that did NOTHING while `apply()` answered "
          ~ "true");
    }
    // …and the two crease cells move NO count at all, which is precisely why
    // their `postOp != postUndo` check (below, in `compareOrCaptureL5`) is the
    // only non-vacuity they can have: a map-value edit is invisible to every
    // count on the mesh.
    foreach (nm; ["mesh.edgeCrease.set", "mesh.edgeCrease.clear"]) {
        auto r = runs[nm];
        assert(r.postFaces == r.preFaces && r.postVerts == r.preVerts,
            format("%s moved a geometry COUNT (%d/%d faces, %d/%d vertices). "
                 ~ "It writes one Edge-domain map and must move none — if it "
                 ~ "does, this cell is measuring something else", nm,
                   r.preFaces, r.postFaces, r.preVerts, r.postVerts));
    }

    // The two `cleanup` attribution cells must NOT agree, or the roster's
    // first two rows are one cell written twice and "the weld's own effect" is
    // not separated from the degenerate stage's.
    assert(runs["mesh.cleanup/weld"].postOp
        != runs["mesh.cleanup/degenerate"].postOp,
        "the weld-only and degenerate-only cells left the SAME post-op state — "
      ~ "the stage toggles are not reaching the kernel, so neither cell "
      ~ "attributes anything");
    // …and the dissolve cell must differ from the default sweep, or the sixth
    // stage is off in both and the fourth cell is a duplicate of the third.
    assert(runs["mesh.cleanup/dissolve"].postOp
        != runs["mesh.cleanup/full"].postOp,
        "the dissolve cell left the same post-op state as the default sweep — "
      ~ "`dissolve2Valent` did not reach the kernel and that cell measures "
      ~ "nothing the one above it does not");

    return out_;
}

// ===========================================================================
// The ONE standing exception, and it is L3's — imported, not restated.
//
// `faceSelectionOrder` on a face that is NOT selected. The frozen snapshot
// oracle puts the stand's synthetic stamps on faces 2 and 6 back verbatim
// (`MeshSnapshot.restore` does not go through `SelectionSnapshot`); the
// migrated path reaches `SelectionSnapshot.restore`, which deliberately
// re-zeroes the order entry of every element that did not end up selected —
// task 0613's S3 code review, against resurrecting a stale stamp. THE
// MIGRATED PATH IS THE MORE CORRECT OF THE TWO, so this is a normalisation
// and not a loss, and "fixing" it would reintroduce exactly the corruption
// class that review removed.
//
// STAGE L3 FOUND THIS FIRST, ON A DIFFERENT FAMILY, AND THE PLAN'S RULE FOR
// THE REPEAT IS "the same argument, not a new one". So this reader imports
// `checkOrderNormalisation` from `undo_parity_l3_test` rather than writing a
// second copy of the reasoning that could drift from it. The predicted repeat
// was written down before the migration ran and the divergence came out
// exactly where predicted — on the four `mesh.cleanup` cells, whose kernels
// re-lay the face index space, and NOT on the two crease cells, which move no
// index space at all.
//
// IT IS A PIN, NOT A SKIP. The declared plane is still asserted: every
// UNSELECTED face's stamp must be 0 and every SELECTED face's must match the
// oracle exactly, and the entry must still have something to normalise. So a
// new regression on this plane reddens, and so does FIXING the divergence —
// which is what tells whoever fixed it to retire the entry.
private immutable PlaneException[] kL5Exceptions = [
    PlaneException("mesh.cleanup/weld", "postUndo", "faceSelectionOrder",
        "SelectionSnapshot.restore re-zeroes an unselected element's order "
      ~ "stamp (snapshot.d, task 0613 S3); MeshSnapshot.restore does not",
        &checkOrderNormalisation),
    PlaneException("mesh.cleanup/degenerate", "postUndo", "faceSelectionOrder",
        "as mesh.cleanup/weld", &checkOrderNormalisation),
    PlaneException("mesh.cleanup/full", "postUndo", "faceSelectionOrder",
        "as mesh.cleanup/weld", &checkOrderNormalisation),
    PlaneException("mesh.cleanup/dissolve", "postUndo", "faceSelectionOrder",
        "as mesh.cleanup/weld", &checkOrderNormalisation),
];

unittest // the exception table is well-formed and cannot silence a whole cell
{
    string[] roster;
    foreach (ref sp; kL5Specs) roster ~= sp.name;
    assertExceptionTableWellFormed(kL5Family, kL5Exceptions, roster);

    // …and it must NOT reach the two crease cells. They write ONE Edge-domain
    // map value and move no index space, so `SelectionSnapshot.restore` has
    // nothing to normalise there — an entry for them would be a licence over a
    // plane that in fact agrees, which is the blind spot the "now AGREES"
    // assert exists to refuse.
    foreach (ref e; kL5Exceptions)
        assert(e.cell != "mesh.edgeCrease.set" && e.cell != "mesh.edgeCrease.clear",
            "the crease cells carry no normalisation — an exception on one of "
          ~ "them would be silencing a plane that agrees");
}

// ===========================================================================
// Compare, or capture.
// ===========================================================================

private void compareOrCaptureL5(ParityCell[] cells)
{
    import std.file    : exists, readText, write, mkdirRecurse;
    import std.path    : dirName;
    import std.process : environment;

    // ---- anti-vacuity, BEFORE anything is compared or written -------------
    assert(cells.length == kL5Specs.length && cells.length == 6,
        format("the recipe produced %d cells, the roster declares %d and the "
             ~ "stage owes 6", cells.length, kL5Specs.length));
    foreach (ref c; cells)
        assert(c.postOp != c.postUndo,
               kL5Family ~ ": cell '" ~ c.name ~ "' has postOp == postUndo, so "
             ~ "its forward moved no plane this dump can see. Every assertion "
             ~ "about its undo is then satisfied by an undo that does nothing.");

    immutable path = fixturePath("cleanup.json");

    if (environment.get("VIBE3D_PARITY_CAPTURE_L5", "") == "1") {
        mkdirRecurse(dirName(path));
        write(path, fixtureJson(kL5Family, kL5ProducedBy, kL5Stand, cells));
        return;
    }

    assert(exists(path),
           "missing parity fixture " ~ path ~ " — it must be frozen BEFORE the "
         ~ "`MeshSnapshot` arms are deleted from cleanup.d / edge_crease.d; "
         ~ "re-capturing on a tree that no longer HAS them would be the delta "
         ~ "path grading its own homework");

    auto frozen = parseJSON(readText(path));

    // The immutability pin. `producedBy` is not merely non-empty here — it
    // must still name the capture tree, because from L5-a on nothing
    // legitimate can re-produce this file.
    assert(frozen["producedBy"].str == kL5ProducedBy,
           format("%s: producedBy is '%s', expected '%s'. This fixture is "
                ~ "IMMUTABLE from stage L5-a onward — a legitimate "
                ~ "normalisation is a NAMED PER-PLANE EXCEPTION in this "
                ~ "reader, argued and reviewed, never a re-capture",
                  path, frozen["producedBy"].str, kL5ProducedBy));
    assert(frozen["stand"].str == kL5Stand,
           format("%s: stand is '%s', expected '%s'", path,
                  frozen["stand"].str, kL5Stand));

    auto fcells = frozen["cells"].array;
    assert(fcells.length == cells.length,
           format("%s: fixture holds %d cells, the recipe produced %d — a cell "
                ~ "added or removed without re-freezing", path, fcells.length,
                  cells.length));

    foreach (i, ref c; cells) {
        auto fc = fcells[i];
        assert(fc["name"].str == c.name,
               format("%s: cell %d is '%s' in the fixture and '%s' now — the "
                    ~ "roster was reordered", path, i, fc["name"].str, c.name));
        compareWithExceptions(path, c.name, "postOp",   fc["postOp"],
                              c.postOp,  kL5Exceptions);
        compareWithExceptions(path, c.name, "postUndo", fc["postUndo"],
                              c.postUndo, kL5Exceptions);
    }
}

// ---------------------------------------------------------------------------
// THE READER.
//
// MUTATION THAT REDDENS IT: delete the `preMaps_` restore in
// `MeshCleanup.revert` — `vertices`, `faces`, every mark word, every count and
// `faceMaterial` all compare EQUAL and only the `meshMaps` plane differs. Or
// delete the `faceReindexScope()` arm at `Mesh.applyVertexRemap`, which the
// weld-only cell names by the `faces` plane while every count round-trips.
// ---------------------------------------------------------------------------
unittest
{
    compareOrCaptureL5(l5Cells());
}

// ---------------------------------------------------------------------------
// The REFUSAL, asserted rather than frozen.
//
// A refusing command leaves the mesh where it found it, so its two dumps are
// identical and a frozen pair of them cannot come out differently. What CAN
// come out differently is what the refusal DOES: `apply()` must answer false,
// nothing may be left mutated, and no edit frame may be left open.
// ---------------------------------------------------------------------------
unittest
{
    import tests.unit.fixtures : makeTaggedGridFull, dumpMeshPlanes,
                                 diffMeshPlanes;
    import change_bus          : changeBus;

    auto m = new Mesh;
    *m = makeTaggedGridFull(3);          // the CLEAN stand — nothing to clean
    m.buildLoops();
    m.syncSelection();
    auto pre = dumpMeshPlanes(*m);

    immutable ulong leaks0 = changeBus.batchLeaks;
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshCleanup(m, v, EditMode.Polygons);

    assert(!c.apply(),
        "mesh.cleanup APPLIED on a mesh with nothing to clean. `evaluate`'s "
      ~ "`!anyAffected()` arm is the refusal, and a command that answers true "
      ~ "here lands a history entry describing no change");
    auto post = dumpMeshPlanes(*m);
    assert(diffMeshPlanes(pre, post) == "",
        "mesh.cleanup refused and still moved the mesh: planes ["
      ~ diffMeshPlanes(pre, post) ~ "]. A partial sweep that reports nothing "
      ~ "affected would leave a mutated mesh behind a refusal, with no undo "
      ~ "entry to blame it on");
    assert(changeBus.batchLeaks == leaks0,
        format("mesh.cleanup's refusal leaked %d edit frame(s) — the batch was "
             ~ "opened and not closed on the refusal path, and every later "
             ~ "commitChange on this mesh defers forever",
               changeBus.batchLeaks - leaks0));
    // …and the refusal must NOT be spelled as a false `revert()`: that pops
    // the entry off BOTH history stacks and truncates the suffix after it
    // (regression 0099, `command_history.d`). A command whose `evaluate`
    // refused holds no undo image and its `revert()` answers false — which is
    // correct here ONLY because the funnel never records the entry.
    assert(!c.revert(),
        "mesh.cleanup's revert() answered TRUE after a refused forward — it "
      ~ "would then replay belts that were never captured");
}
