// undo_parity_l3_test — the FROZEN parity fixture for stage L3's family
// (`mesh.delete` / `mesh.remove`), and the reader that makes it an oracle.
//
// WHY THIS FILE EXISTS, and why it had to land BEFORE the fork deletion.
// `MeshDelete` and `MeshRemove` are two of the four classes that still branch
// on `undoTrackerEnabled()`: with the hatch OFF they capture a whole-mesh
// `MeshSnapshot` and restore from it, with it ON (the shipped default) they
// record a `MeshEditDelta` and replay its inverse. Stage L3-b DELETES that
// fork. From that commit on there is no snapshot arm to compare the delta
// against — so the comparison has to be captured while the arm still exists,
// which is what this file does.
//
// AND IT IS STRICTLY WIDER THAN THE GATE IT REPLACES. The live parity gate
// for this family, `tests/test_undo_tracker_delete.d`, ran the op twice in one
// process (`undo.tracker.off` then `.on`) and compared GEOMETRY — vertex and
// face counts plus coincident positions — and a geometric selection key.
// It never compared `faceMaterial`, `facePart`, the mark words,
// `*SelectionOrder`, the selection-set masks or `meshMaps`. Those are exactly
// the planes the burn-in of task 0613 lost (`test_marks_authority` B4 failed
// only under the delta path, recorded verbatim at `commands/mesh/delete.d`'s
// class comment), and a geometry compare cannot see any of them.
//
// THE TWO DUMPS ARE NOT DECORATION — inherited verbatim from
// `undo_parity_l0_test`'s header. A fixture holding only the post-undo state
// is green for a cell whose FORWARD silently stopped doing anything, and green
// for a cell whose op and undo are both broken in the same direction.
//
// ---------------------------------------------------------------------------
// THE RECIPE INVERTS L2's RULE, AND THAT INVERSION IS THE POINT.
//
// L2's plan says `setUndoTrackerEnabled` must NOT appear in a capture recipe —
// measured there as a no-op for every class outside the four hatched ones.
// `MeshDelete` and `MeshRemove` ARE two of those four, so
// `setUndoTrackerEnabled(false)` is the ONLY way to reach the oracle here. A
// recipe without it would capture the delta path and then compare it against
// itself, which is a fixture that cannot come out differently.
//
// THE CAPTURE RUNS EACH CELL UNDER BOTH ARMS AND ASSERTS THE `postOp` DUMPS
// AGREE. `undo_parity_l0_test.runCell` captures with NO recording batch open,
// while the shipped delta path always opens one (`delete.d`'s
// `beginEditBatch`). Anything the batch changes in the FORWARD is therefore
// invisible at capture time and would surface later as "the forward changed —
// out of scope", the one branch of the three-way discrimination below that
// cannot be acted on. The known case is the deferred hide-derive: inside a
// batch every `commitChange` defers, so the derive runs once at the close
// instead of once per element. So each cell runs twice in one process, the two
// `postOp` dumps are asserted identical, and the SNAPSHOT arm's pair is what is
// frozen. A disagreement is a FINDING for the card, never something to route
// around by picking one arm.
//
// COMPARE MODE RUNS ONE ARM: the shipped default, unflipped. After L3-b the
// two arms ARE the same code, so running both then would be a comparison of a
// path against itself — the both-arms agreement belongs to the capture and is
// stated as such.
//
// ---------------------------------------------------------------------------
// THE FILE IS IMMUTABLE FROM STAGE L3-b ONWARD. Re-freezing presupposes a
// producer. Once the fork is gone the only thing that can produce a
// `delete_remove.json` is the delta path capturing itself, which is the
// migration grading its own homework and is indistinguishable from a correct
// freeze. So the three-way discrimination below loses its third branch here:
//
//   * `postUndo` differs  ⇒ the migration restores LESS. Fix the code.
//   * `postOp`   differs  ⇒ the FORWARD changed. Louder, and out of L3's scope.
//   * a legitimate normalisation ⇒ a NAMED PER-PLANE EXCEPTION in this reader,
//     reviewed, with its reason at the exception. NOT a new `producedBy`.
//
// ALL THREE BRANCHES WERE EXERCISED THE FIRST TIME THIS FILE RAN, which is the
// argument for having frozen the oracle at all:
//
//   * `vertexSetMask` and `edgeSetMask` came back EMPTY from the delta arm on
//     every cell that compacts a vertex, while the snapshot arm restored them.
//     A real, user-visible loss on the shipped default path — a named
//     selection set vanishing on Ctrl+Z. FIXED IN THE CODE (the
//     `preVertSetMask_` / `preEdgeSetMask_` / `preFaceSetMask_` belt in
//     `delete.d` and `remove.d`); no exception is recorded for it, and the
//     planes are compared like any other.
//   * `faceSelectionOrder` differs on the six cells that carry a face
//     SELECTION, and it is a NORMALISATION with its argument already written
//     in the tree — see `kL3Exceptions`. It is the one exception this file
//     records.
//   * every `postOp` plane agreed, under both arms and against the frozen
//     capture, on all ten cells.
//
// AN EXCEPTION HERE IS A PIN, NOT A SKIP. A declared plane is still asserted:
// the divergence must STILL BE PRESENT and must still have the recorded SHAPE.
// So a new regression on that plane reddens, and so does FIXING the
// divergence — which is what tells the person who fixed it to retire the
// entry. A widened skip list would do neither.
//
// `kL3ProducedBy` is pinned below and the reader asserts the frozen file still
// carries it, so a re-capture that quietly re-dates the oracle goes red.
//
// ---------------------------------------------------------------------------
// THE HATCH FLAG IS A MODULE GLOBAL AND DRUNTIME RUNS EVERY UNITTEST MODULE IN
// ONE PROCESS. `mesh_edit_delta.g_undoTrackerOn` left flipped steers the other
// fifteen hatched files for the rest of the lane — and it keeps doing so after
// L3-b, because L3 removes two of seventeen branch sites, not the flag. Every
// flip in this file goes through `withHatch` below, whose `scope (exit)` is
// witnessed by its own unittest block.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l3_test;

import std.format : format;
import std.json   : JSONValue, parseJSON;

import command;
import mesh;
import view;
import editmode;
import math      : Vec3;
import http_json : meshPlanesJson, PlaneDumpMeta;


import tests.unit.fixtures            : makeTaggedGridFull;
import tests.unit.undo_parity_l0_test : ParityCell, comparePlanes, fixturePath,
                                        PlaneException,
                                        compareWithExceptions,
                                        assertExceptionTableWellFormed;

import commands.mesh.delete_ : MeshDelete;
import commands.mesh.remove_ : MeshRemove;

enum string kL3Family = "delete_remove";
enum string kL3Stand  = "makeTaggedGridFull(3)";

/// The tree that PRODUCED the frozen dumps: the branch point of task 2280's
/// lane, i.e. the last commit at which `delete.d` and `remove.d` still hold
/// the `if (undoTrackerEnabled())` fork and the `MeshSnapshot snap` field. A
/// fixture whose `producedBy` is not an ancestor of the migration commit was
/// captured after the fact — against the code it was meant to be independent
/// of. The reviewer checks the ancestry (`git merge-base --is-ancestor`); the
/// reader below checks the field still says this.
enum string kL3ProducedBy = "2f7ef302";

/// The corner quad of a 3x3 `makeGridPlane`. Face index = i*3 + j, vertex
/// index = i*4 + j, so face 0 is `[0, 1, 5, 4]` and vertex 0 is referenced by
/// NO other face. Deleting face 0 therefore orphans vertex 0 — which
/// `mesh.delete` compacts away and `mesh.remove` keeps (`keepOrphans`). That
/// one vertex is the ONLY thing separating the two commands in Polygons mode.
enum int kCornerFace = 0;
enum uint kCornerOnlyVertex = 0;

/// The two interior vertices of the row `i == 1`. The edge between them is
/// shared by faces 1 and 4, so it is dissolvable; a BOUNDARY edge is not, and
/// `removeEdgesByMask` would return 0 on one, freezing a cell that recorded a
/// refusal.
enum uint kInteriorEdgeA = 5;
enum uint kInteriorEdgeB = 6;

/// The Vertices cells' operand.
///
/// A DEVIATION FROM THE PLAN, taken deliberately and measured rather than
/// assumed. The plan's Vertices cells use the stand's own vertex selection,
/// `{2, 9}` — and vertex 9 IS a corner of face 7, the only face the stand
/// SELECTS (face index i*3+j, vertex index i*4+j, so face 7 is `[9, 10, 14,
/// 13]`). With that operand the dissolve destroys every selected face and item
/// 3 of the non-vacuity list — "a face selected but NOT deleted" — is
/// unreachable: the Select plane becomes a function of the operand and a
/// revert that restored geometry while dropping the Select bits would read the
/// same. `{2, 5}` touches faces 0..4 and leaves face 7 alive, still selected.
enum uint[] kVertOperand = [2u, 5u];

// ===========================================================================
// The hatch guard, and its own witness.
// ===========================================================================

// `withHatch` AND ITS WITNESS ARE GONE (task 1903 stage N). The helper flipped
// the `VIBE3D_UNDO_TRACKER` module global under a `scope (exit)` because
// druntime runs every unittest module in ONE process, so a cell that left the
// flag set steered the other fifteen hatched files. The flag no longer exists,
// so neither does the hazard, and the one block that witnessed the restore is
// declared in `tests/unit/census_ledger.txt`.
//
// The capture arm this file's `l3RunCell` used it for went with it — see that
// function.

// ===========================================================================
// The stand, and the four non-vacuity asserts it owes.
// ===========================================================================

private Mesh* l3Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

unittest // the stand can exhibit everything the roster claims to measure
{
    // MUTATION: build the stand on `makeCube()`. Items 1 and 2 both fail by
    // name — a cube shares every vertex between three faces, so removing one
    // face orphans nothing and `mesh.delete` and `mesh.remove` become
    // byte-identical, which kills the only distinction this family has.
    auto m = l3Stand();

    assert(m.faces.length == 9 && m.vertices.length == 16,
        "the stand is not a 3x3 grid — every index constant in this file "
      ~ "names a face or a vertex at random");

    // ---- 1. the corner quad ORPHANS a vertex under delete and KEEPS it under
    // remove. Asserted structurally here (vertex 0 is referenced by face 0 and
    // by nothing else); asserted again by COUNT, both ways, once the cells have
    // run — see `l3Cells`.
    size_t refs = 0;
    foreach (fi; 0 .. m.faces.length)
        foreach (vi; m.faces[fi])
            if (vi == kCornerOnlyVertex) ++refs;
    assert(refs == 1,
        format("vertex %d is referenced by %d faces, expected exactly 1 — the "
             ~ "corner cell then orphans nothing and `keepOrphans` stops being "
             ~ "observable", kCornerOnlyVertex, refs));

    // ---- 2. a live PolyVertex map whose per-corner values are DISTINCT. A
    // value restored onto the WRONG corner must fail as loudly as one that
    // vanished; `remove_test.d` states that rule for this exact family.
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null, "the stand carries no `" ~ kUvMapName ~ "` map — the "
                      ~ "per-corner plane this family loses first is absent");
    assert(uv.domain == MapDomain.PolyVertex,
        "the stand's uv map is not PolyVertex — the per-CORNER carry is a "
      ~ "different code path from the per-VERTEX one");
    assert(uv.data.length >= 8, "the uv map is too small to key corners with");
    bool[float] seenU;
    foreach (k; 0 .. uv.data.length / uv.dim) {
        immutable float u = uv.data[k * uv.dim];
        assert((u in seenU) is null,
            format("uv corner %d repeats the value %s — a value restored onto "
                 ~ "the wrong corner would compare EQUAL", k, u));
        seenU[u] = true;
    }

    // ---- 3. "restored the selection" and "restored everything" are different
    // pictures. The stand selects exactly face 7; the Vertices cell's operand
    // is vertices 2 and 9, whose incident faces do NOT include face 7. So that
    // cell destroys faces that carried no Select bit and leaves a face that
    // did.
    size_t selFaces = 0;
    foreach (fi; 0 .. m.faces.length) if (m.isFaceSelected(fi)) ++selFaces;
    assert(selFaces == 1 && m.isFaceSelected(7),
        "the stand's face selection is not exactly {7} — item 3 of the "
      ~ "non-vacuity list names that face");
    size_t touched = 0;
    bool touchesSeven = false;
    foreach (fi; 0 .. m.faces.length) {
        bool hit = false;
        foreach (vi; m.faces[fi])
            foreach (op; kVertOperand) if (vi == op) { hit = true; break; }
        if (!hit) continue;
        ++touched;
        if (fi == 7) touchesSeven = true;
    }
    assert(touched > 0 && !touchesSeven,
        format("the Vertices operand touches %d faces (face 7 among them: %s) "
             ~ "— the cell needs faces it destroys that were NOT selected AND "
             ~ "a selected face that survives, or selection restore and "
             ~ "geometry restore are the same picture", touched, touchesSeven));

    // ---- 3b. `faceSelectionOrder` carries values on faces that are NOT the
    // selected one, so the order plane and the Select plane are independent.
    assert(m.faceSelectionOrder[2] != 0 && m.faceSelectionOrder[6] != 0,
        "the stand's faceSelectionOrder is flat outside the selected face — a "
      ~ "revert that drops the order plane would read identical");

    // ---- 4 is per cell: every cell asserts its op actually moved something.
    // See `l3RunOnce`.

    // The interior edge the Edges cells name.
    assert(m.edgeIndex(kInteriorEdgeA, kInteriorEdgeB) != ~0u,
        format("the stand has no edge %d-%d — makeGridPlane's numbering "
             ~ "changed and the Edges cells would select at random",
               kInteriorEdgeA, kInteriorEdgeB));
}

// ===========================================================================
// The roster.
// ===========================================================================

/// What a cell does to the stand before the command runs. A `function` (not a
/// delegate) so the spec table can be a module-level immutable.
private alias Arrange = void function(Mesh*);

private struct L3CellSpec {
    string   name;
    bool     isDelete;     // false ⇒ mesh.remove
    EditMode mode;
    Arrange  arrange;
}

/// Name the two vertices of `kVertOperand` — see that constant for why the
/// stand's own `{2, 9}` cannot serve here.
private void arrStandVerts(Mesh* m)
{
    m.clearVertexSelection();
    foreach (vi; kVertOperand) m.selectVertex(cast(int)vi);
}

/// Clear the stand's edge selection and name ONE interior edge instead.
///
/// A DEVIATION FROM THE PLAN, taken deliberately: the plan's Edges cells use
/// "the stand's selected operand", and the stand selects edges 0 and 3, which
/// on `makeGridPlane(3)` may be BOUNDARY edges. `removeEdgesByMask` merges the
/// two faces either side of an edge and affects nothing on a boundary edge, so
/// such a cell would freeze a refusal — `runCell`'s apply assert catches it,
/// but only after the roster has been written. Naming the edge is the same
/// discipline `undo_parity_l0_test`'s `mesh.edge_slide` cell already uses.
private void arrInteriorEdge(Mesh* m)
{
    m.clearEdgeSelection();
    immutable uint ei = m.edgeIndex(kInteriorEdgeA, kInteriorEdgeB);
    assert(ei != ~0u, "the interior edge vanished from the stand");
    m.selectEdge(cast(int)ei);
}

/// Use the stand's own face selection (face 7 — an interior quad whose removal
/// orphans nothing, so this cell is where `delete` and `remove` AGREE).
private void arrStandFace(Mesh* m) { }

/// Empty selection everywhere ⇒ the "whole mesh" convention. Every geometry
/// type must be cleared, not just the acting one: `effectiveDeleteMode`
/// redirects to Polygons > Edges > Vertices whenever the active mode is empty
/// and another type is not, so clearing only faces would silently run the
/// Edges kernel.
private void arrWholeMesh(Mesh* m)
{
    m.clearVertexSelection();
    m.clearEdgeSelection();
    m.clearFaceSelection();
}

/// The corner quad alone — the pair that separates `keepOrphans` from
/// `compactUnreferenced`.
private void arrCornerFace(Mesh* m)
{
    m.clearFaceSelection();
    m.selectFace(kCornerFace);
}

private immutable L3CellSpec[] kL3Specs = [
    L3CellSpec("mesh.delete/vertices", true,  EditMode.Vertices, &arrStandVerts),
    L3CellSpec("mesh.delete/edges",    true,  EditMode.Edges,    &arrInteriorEdge),
    L3CellSpec("mesh.delete/polygons", true,  EditMode.Polygons, &arrStandFace),
    L3CellSpec("mesh.remove/vertices", false, EditMode.Vertices, &arrStandVerts),
    L3CellSpec("mesh.remove/edges",    false, EditMode.Edges,    &arrInteriorEdge),
    L3CellSpec("mesh.remove/polygons", false, EditMode.Polygons, &arrStandFace),
    L3CellSpec("mesh.delete/whole",    true,  EditMode.Polygons, &arrWholeMesh),
    L3CellSpec("mesh.remove/whole",    false, EditMode.Polygons, &arrWholeMesh),
    L3CellSpec("mesh.delete/corner",   true,  EditMode.Polygons, &arrCornerFace),
    L3CellSpec("mesh.remove/corner",   false, EditMode.Polygons, &arrCornerFace),
];

/// What one run of one cell produced, dumps plus the counts the non-vacuity
/// asserts read.
private struct CellRun {
    string postOp;
    string postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
}

/// `stand → arrange → op → undo`, dumping after the op and again after the
/// undo. `apply()` and `revert()` are asserted, not merely called: a command
/// that refuses on the stand freezes a pair of identical dumps, which is a
/// green fixture recording nothing.
private CellRun l3RunOnce(in L3CellSpec s, in PlaneDumpMeta meta)
{
    auto m = l3Stand();
    s.arrange(m);

    CellRun r;
    r.preVerts = m.vertices.length;
    r.preFaces = m.faces.length;

    auto v = new View(0, 0, 800, 600);
    Command c = s.isDelete
        ? cast(Command) new MeshDelete(m, v, s.mode)
        : cast(Command) new MeshRemove(m, v, s.mode);

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    r.postVerts = m.vertices.length;
    r.postFaces = m.faces.length;
    r.postOp    = meshPlanesJson(*m, meta);

    // Non-vacuity item 4: the op ACTUALLY moved something. `apply()` returning
    // true is the command's own word for it; this is the mesh's.
    assert(r.postFaces < r.preFaces || r.postVerts < r.preVerts,
        format("%s: the op left %d faces / %d vertices, same as before — "
             ~ "every assertion about its undo is then satisfied by an undo "
             ~ "that does nothing", s.name, r.postFaces, r.postVerts));

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);

    return r;
}

/// One cell, on the one arm that exists.
///
/// THIS FUNCTION USED TO TAKE A `captureMode` FORK. Capture mode ran the cell
/// under BOTH hatch arms and asserted their `postOp` dumps agreed; the frozen
/// fixture was the SNAPSHOT arm's. Task 1903 stage N deleted the hatch, so
/// there is no snapshot arm to capture and `compareOrCaptureL3` now REFUSES to
/// re-capture rather than quietly writing the delta path's own output over the
/// oracle it is judged by. The parameter is gone with the fork.
private ParityCell l3RunCell(in L3CellSpec s, out CellRun chosen)
{
    auto meta = PlaneDumpMeta(kL3ProducedBy, "delta", kL3Family, kL3Stand);
    chosen = l3RunOnce(s, meta);
    return ParityCell(s.name, "delta", chosen.postOp, chosen.postUndo);
}

/// Every L3 cell, in a fixed order, plus the cross-cell `keepOrphans` assert
/// that no single cell can make.
ParityCell[] l3Cells()
{
    ParityCell[] out_;
    CellRun[string] runs;

    foreach (ref s; kL3Specs) {
        CellRun r;
        out_ ~= l3RunCell(s, r);
        runs[s.name] = r;
    }

    // Non-vacuity item 1, BY COUNT, both ways: the corner quad orphans a
    // vertex under `delete` and keeps it under `remove`. If these two are
    // equal the two commands did the same thing and five of the ten cells are
    // duplicates of the other five.
    auto dCorner = runs["mesh.delete/corner"];
    auto rCorner = runs["mesh.remove/corner"];
    assert(dCorner.postVerts < rCorner.postVerts,
        format("the corner cell does not separate the two commands: "
             ~ "mesh.delete left %d vertices and mesh.remove left %d, and "
             ~ "`keepOrphans` is the ONLY thing that distinguishes them in "
             ~ "Polygons mode", dCorner.postVerts, rCorner.postVerts));
    assert(rCorner.postVerts == rCorner.preVerts,
        format("mesh.remove/corner dropped %d vertices — it is supposed to "
             ~ "keep every orphan (keepOrphans=true)",
               rCorner.preVerts - rCorner.postVerts));

    // …and the interior-face cell is where they AGREE, which is what makes the
    // corner cell's disagreement a property of the geometry and not of the
    // harness.
    assert(runs["mesh.delete/polygons"].postVerts
        == runs["mesh.remove/polygons"].postVerts,
        "mesh.delete and mesh.remove disagree on an INTERIOR face, where no "
      ~ "vertex is orphaned — either the stand's face 7 is not interior or one "
      ~ "of the two kernels changed");

    return out_;
}

// ===========================================================================
// Compare, or capture.
//
// A SEPARATE capture switch from L0's and L1's `VIBE3D_PARITY_CAPTURE`, and
// that is a decision with a reason: the shared switch would re-freeze
// `position_marks.json` and `uv_maps_sets.json` in the same process, and a
// re-capture is exactly what those files' own headers forbid.
// ===========================================================================

// `PlaneException` and `compareWithExceptions` MOVED to
// `undo_parity_l0_test` at task 1903 Stage L5, unchanged in behaviour. Stage
// L5's family hit the IDENTICAL `faceSelectionOrder` divergence for the
// identical reason, and the plan's rule for that case is "the same argument,
// not a new one" — so the struct and the driver are shared and the ARGUMENT
// stays here, at `checkOrderNormalisation`, which L5's reader imports rather
// than restates.

/// The normalisation: `faceSelectionOrder` on a face that is NOT selected.
///
/// WHY IT IS A NORMALISATION AND NOT A LOSS, and the argument is not this
/// file's — it is written at `source/snapshot.d`'s
/// `SelectionSnapshot.restore`, lines that re-zero the order entry of every
/// element the bulk setter did not end up selecting. That re-zero was added by
/// task 0613's S3 code review for a stated reason: a wholesale order-array
/// overwrite captured BEFORE a refusal can resurrect a stale nonzero stamp for
/// an element that is not selected, which is the same corruption class fixed
/// in `mesh.d`'s `selectVerticesFrom` / `selectEdgesFrom` / `selectFacesFrom`.
///
/// `MeshSnapshot.restore` does NOT go through `SelectionSnapshot`, so the
/// snapshot arm puts the stand's synthetic stamps on faces 2 and 6 back
/// verbatim — faces that are not selected, and whose order value therefore has
/// no meaning. The delta arm reaches `SelectionSnapshot.restore` and zeroes
/// them. **The delta arm is the MORE correct of the two**, which is why this
/// is recorded as a normalisation rather than fixed: "fixing" it would mean
/// reintroducing the stale stamps the cited review removed.
///
/// The pin: every UNSELECTED face's order must be 0, and every SELECTED face's
/// order must match the frozen oracle exactly. A revert that dropped a real
/// selected face's stamp is NOT covered by this entry and still reddens.
void checkOrderNormalisation(string cell, in JSONValue frozenDump,
                             in JSONValue freshDump)
{
    auto fzMarks = frozenDump["faceMarks"].array;
    auto frMarks = freshDump["faceMarks"].array;
    auto fzOrd   = frozenDump["faceSelectionOrder"].array;
    auto frOrd   = freshDump["faceSelectionOrder"].array;

    assert(fzMarks.length == frMarks.length && fzOrd.length == frOrd.length
        && fzOrd.length == fzMarks.length,
        format("%s: faceMarks/faceSelectionOrder lengths disagree (%d/%d vs "
             ~ "%d/%d) — the exception cannot be scored", cell,
               fzMarks.length, fzOrd.length, frMarks.length, frOrd.length));

    bool sawZeroed = false;
    foreach (i; 0 .. fzOrd.length) {
        immutable bool selected = (frMarks[i].integer & 1) != 0;   // Marks.Select
        if (selected) {
            assert(frOrd[i].integer == fzOrd[i].integer,
                format("%s: face %d IS selected and its selection-order stamp "
                     ~ "is %d, the oracle says %d. This exception covers "
                     ~ "UNSELECTED faces only — a selected face's stamp is real "
                     ~ "data and losing it is a defect", cell, i,
                       frOrd[i].integer, fzOrd[i].integer));
        } else {
            assert(frOrd[i].integer == 0,
                format("%s: face %d is NOT selected but carries selection-order "
                     ~ "stamp %d. `SelectionSnapshot.restore` re-zeroes exactly "
                     ~ "these, so a nonzero one here means the revert did not "
                     ~ "go through it", cell, i, frOrd[i].integer));
            if (fzOrd[i].integer != 0) sawZeroed = true;
        }
    }
    // Anti-vacuity: the entry must still be EARNING its place. If the frozen
    // oracle has no stale stamp left to zero, this exception is describing
    // nothing and must be retired rather than left as a standing licence.
    assert(sawZeroed,
        format("%s: the frozen oracle carries no selection-order stamp on any "
             ~ "unselected face, so this exception normalises nothing. Retire "
             ~ "the entry — a standing exception that cannot fire is a blind "
             ~ "spot with a comment on it", cell));
}

private immutable PlaneException[] kL3Exceptions = [
    PlaneException("mesh.delete/vertices", "postUndo", "faceSelectionOrder",
        "SelectionSnapshot.restore re-zeroes an unselected element's order "
      ~ "stamp (snapshot.d, task 0613 S3); MeshSnapshot.restore does not",
        &checkOrderNormalisation),
    PlaneException("mesh.delete/edges", "postUndo", "faceSelectionOrder",
        "as mesh.delete/vertices", &checkOrderNormalisation),
    PlaneException("mesh.delete/polygons", "postUndo", "faceSelectionOrder",
        "as mesh.delete/vertices", &checkOrderNormalisation),
    PlaneException("mesh.remove/vertices", "postUndo", "faceSelectionOrder",
        "as mesh.delete/vertices", &checkOrderNormalisation),
    PlaneException("mesh.remove/edges", "postUndo", "faceSelectionOrder",
        "as mesh.delete/vertices", &checkOrderNormalisation),
    PlaneException("mesh.remove/polygons", "postUndo", "faceSelectionOrder",
        "as mesh.delete/vertices", &checkOrderNormalisation),
];

unittest // the exception table is well-formed and cannot silence a whole cell
{
    string[] roster;
    foreach (ref sp; kL3Specs) roster ~= sp.name;
    assertExceptionTableWellFormed(kL3Family, kL3Exceptions, roster);
}

private void compareOrCaptureL3(ParityCell[] cells)
{
    import std.file    : exists, readText;
    import std.process : environment;

    // ---- anti-vacuity, BEFORE anything is compared or written -------------
    assert(cells.length == kL3Specs.length && cells.length == 10,
        format("the recipe produced %d cells, the roster declares %d and the "
             ~ "plan owes 10", cells.length, kL3Specs.length));
    foreach (ref c; cells)
        assert(c.postOp != c.postUndo,
               kL3Family ~ ": cell '" ~ c.name ~ "' has postOp == postUndo, so "
             ~ "its forward moved no plane this dump can see. Every assertion "
             ~ "about its undo is then satisfied by an undo that does nothing.");

    immutable path = fixturePath("delete_remove.json");

    // RE-CAPTURE IS REFUSED, not merely discouraged (task 1903 stage N).
    // The frozen file is the SNAPSHOT arm's output, and stage N deleted the
    // snapshot arm: nothing in this tree can produce it again. A
    // `VIBE3D_PARITY_CAPTURE_L3=1` run would write the delta path's own dump
    // over the oracle that judges it — the migration grading its own homework,
    // which the module header has forbidden in words since L3-b and which is
    // now unrepresentable.
    assert(environment.get("VIBE3D_PARITY_CAPTURE_L3", "") != "1",
           "VIBE3D_PARITY_CAPTURE_L3=1 is refused: " ~ path ~ " was captured "
         ~ "on the `VIBE3D_UNDO_TRACKER=0` snapshot arm, and task 1903 stage N "
         ~ "deleted that arm. There is no producer for this fixture any more. "
         ~ "A legitimate normalisation is a NAMED PER-PLANE EXCEPTION in the "
         ~ "reader below, argued and reviewed — never a re-capture.");

    assert(exists(path),
           "missing parity fixture " ~ path ~ " — it was frozen BEFORE the "
         ~ "`undoTrackerEnabled()` fork was deleted from delete.d / remove.d, "
         ~ "and nothing can re-freeze it");

    auto frozen = parseJSON(readText(path));

    // The immutability pin. `producedBy` is not merely non-empty here — it
    // must still name the capture tree, because from L3-b on nothing legitimate
    // can re-produce this file.
    assert(frozen["producedBy"].str == kL3ProducedBy,
           format("%s: producedBy is '%s', expected '%s'. This fixture is "
                ~ "IMMUTABLE from stage L3-b onward — a legitimate "
                ~ "normalisation is a NAMED PER-PLANE EXCEPTION in this "
                ~ "reader, argued and reviewed, never a re-capture",
                  path, frozen["producedBy"].str, kL3ProducedBy));
    assert(frozen["stand"].str == kL3Stand,
           format("%s: stand is '%s', expected '%s'", path,
                  frozen["stand"].str, kL3Stand));

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
                              c.postOp,  kL3Exceptions);
        compareWithExceptions(path, c.name, "postUndo", fc["postUndo"],
                              c.postUndo, kL3Exceptions);
    }
}

// ---------------------------------------------------------------------------
// THE READER.
//
// MUTATION THAT REDDENS IT: delete the `preMaps_` restore in
// `MeshDelete.revert` — `vertices`, `faces`, every mark word, every count and
// `faceMaterial` all compare EQUAL and only the `meshMaps` plane differs. The
// geometry gate this file replaces is green under exactly that.
// ---------------------------------------------------------------------------
unittest
{
    compareOrCaptureL3(l3Cells());
}
