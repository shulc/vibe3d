// undo_parity_l9_test — the FROZEN parity fixture for stage L9's family
// (`mesh.loopSlice`, `mesh.addLoop`), and the reader that makes it an oracle.
//
// WHY IT LANDS BEFORE THE FIRST SOURCE CHANGE THAT ALTERS UNDO (§6.3 rule 1).
// `MeshAddLoop` and `MeshLoopSlice` hold the `MeshSnapshot` that IS the
// comparison, and stages L9-a / L9-b delete it. From those commits on there is
// no snapshot arm left to compare a delta against, so the comparison has to be
// captured while the arm still exists. The two dumps per cell are not
// decoration either (inherited from `undo_parity_l0_test`'s header): a fixture
// holding only the post-undo state is green for a cell whose FORWARD silently
// stopped doing anything.
//
// ---------------------------------------------------------------------------
// WHAT THIS FAMILY OWES — MEASURED, AND IT IS **ZERO NEW PUBLISHERS**
// ---------------------------------------------------------------------------
// §5.5's L9 row demands three. Measured on 2026-08-28 on this stand, at the
// KERNEL, under a RECORDING batch, for N = 1 and N = 3 — the op-log comes out
// `[AddVerts, MeshMapDelta, FaceReindex]` both times, `revert()` answers true,
// and the EXACT residual (both ways: nothing missing that is not listed, and
// nothing extra) is SEVEN planes and all seven are Select-class:
//
//     edgeMarks, edgeSelectionOrder, faceMarks (the Select bit of face 7
//     alone — Subpatch and Hide come back), faceSelectionOrder,
//     orderCounters, vertexMarks, vertexSelectionOrder
//
// `meshMaps` (the per-corner UV) round-trips BYTE-IDENTICAL — Stage J's
// `recordPolyVertexPayload` beside the face entry — and `vertexSetMask` comes
// back at the pre-op LENGTH, which is Stage L2-c's `finalize` fix. Those are
// the F1 loss list's rows 9 and 8, and they are closed. The remaining seven
// are exactly `SelectionSnapshot`'s field list, i.e. what
// `commands/mesh/selection_undo.d`'s `DenseSelectionUndo` already restores.
// So the family's whole content is: stop capturing a `MeshSnapshot`, hold a
// `MeshEditDelta` + a `DenseSelectionUndo`, call `acceptRecordedEdit`.
//
// NO MARKS PUBLISHER IS BUILT, and that is a ruling rather than a deferral.
// `Kind.SelectionDelta` cannot carry the plane — its restore mints a FRESH
// order stamp off the counter and no delta kind carries a selection-order
// stamp (`selection_undo.d`'s own header, and `l1_declined_census_test.d`
// asserts the second half). A publisher for `setFaceMarksFrom`'s Select clear
// at `mesh_ops/loop_slice.d:1630` would be a SECOND writer over a plane the
// dense image already owns, which is the shape the restore ORDER exists to
// prevent.
//
// ---------------------------------------------------------------------------
// THE FILE IS IMMUTABLE FROM STAGE L9-a ONWARD, for `undo_parity_l5_test.d`'s
// reason verbatim: re-freezing presupposes a producer, and once the snapshot
// arms are gone the only thing that can produce a `loop_slice.json` is the
// delta path capturing itself.
//
//   * `postUndo` differs  => the migration restores LESS. Fix the code.
//   * `postOp`   differs  => the FORWARD changed. Louder, and out of scope.
//   * a legitimate normalisation => a NAMED PER-PLANE EXCEPTION in this
//     reader, reviewed, with its reason at the exception. NOT a re-capture.
//
// THE EXCEPTION TABLE IS EMPTY HERE, and that is a claim and not an omission:
// L3 and L5 both carry a `faceSelectionOrder` normalisation because their
// commands restore through a bare `SelectionSnapshot`, whose tail re-zeroes
// the order stamp of every unselected element. `DenseSelectionUndo` copies the
// three order arrays back WHOLESALE after that tail, so the stand's synthetic
// stamps on faces 2 and 6 survive verbatim and there is nothing to normalise.
// A cell block below asserts the table is empty rather than leaving it silent.
//
// ---------------------------------------------------------------------------
// A SEPARATE CAPTURE KEY, `VIBE3D_PARITY_CAPTURE_L9`, WRITING EXACTLY ONE
// FILE. The process-wide `VIBE3D_PARITY_CAPTURE` re-froze two older fixtures
// once already; stage L9-0 turned that key into a parameter of
// `compareOrCapture` and `tests/unit/parity_capture_key_census_test.d` asserts
// the `leaf <-> key` map is 1:1. The `git status` of
// `tests/fixtures/undo_parity/` after a capture is the check that it worked.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l9_test;

import std.format : format;
import std.json   : JSONValue, parseJSON;

import command;
import mesh;
import view;
import editmode;
import http_json : meshPlanesJson, PlaneDumpMeta;

import tests.unit.fixtures            : makeTaggedGridFull;
import tests.unit.undo_parity_l0_test : ParityCell, comparePlanes, fixturePath,
                                        fixtureJson, setF, setI;

import commands.mesh.loop_slice : MeshAddLoop, MeshLoopSlice;

enum string kL9Family = "loop_slice";
enum string kL9Stand  = "makeTaggedGridFull(3)+selectFace(0)";

/// The tree that PRODUCED the frozen dumps: this lane's branch point. Unlike
/// L5's, no commit in this stage changes the FORWARD — L9 flips two batch
/// constructors and deletes two snapshots, and the kernel is untouched — so a
/// bare SHA names a tree whose dumps are the ones in the file.
enum string kL9ProducedBy = "d1cfe53b";

// ===========================================================================
// The stand.
//
// `makeTaggedGridFull(3)` — an OPEN 3x3 grid, and a cube is WRONG here for a
// reason this family owns: on a closed cube every edge ring is a CLOSED loop,
// so the open-ring termination arm (the last fragment has no successor, and a
// non-split neighbour must ABSORB the terminating midpoint) is unreachable and
// half the fragment-ordering logic never runs. Measured on this stand: every
// one of the 24 edges reports `closed == false` and a ring of 3 edges.
//
// PLUS ONE INJECTION over the shared fixture: face 0 is selected as well as
// face 7. Without it the stand has exactly ONE selected face and "the cut
// consumed the selected face" and "the cut left the selected face alone" are
// the same picture, so the `faceMarks`/`faceSelectionOrder` channel cannot
// tell a restore that works from one that happens to agree.
// ===========================================================================

private Mesh* l9Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    // The second selected face — see the block comment above. Face 0 is in the
    // left column, which is the ring the boundary seed (edge 0) cuts; face 7
    // is in the middle row and survives that cut.
    m.selectFace(0);
    return m;
}

/// Which edges a cut seeded at `seed` would cross, as face indices.
private size_t[] cutFaces(ref Mesh m, uint seed)
{
    import mesh_ops.loop_slice : collectEdgeRing;
    bool closed;
    auto ring = collectEdgeRing(m, seed, closed);
    bool[size_t] seen;
    foreach (ref e; ring) seen[e.fi] = true;
    size_t[] outv;
    foreach (k; seen.byKey) outv ~= k;
    return outv;
}

unittest // the stand can exhibit everything the roster claims to measure
{
    // MUTATION: build the stand on a cube (`Mesh.cube`). Item 1 fails by
    // name — every ring on a closed solid comes back `closed == true`.
    auto m = l9Stand();

    assert(m.faces.length == 9 && m.vertices.length == 16
        && m.edges.length == 24,
        format("the stand is V=%d F=%d E=%d, expected V=16 F=9 E=24 — every "
             ~ "index constant in this file names a face or an edge at random "
             ~ "otherwise", m.vertices.length, m.faces.length, m.edges.length));

    // ---- 1. the cut must cross AT LEAST TWO faces, or the ring walk did
    // nothing and the fragment logic never ran. And the ring must be OPEN,
    // which is the arm a cube cannot reach.
    import mesh_ops.loop_slice : collectEdgeRing;
    foreach (uint seed; [kBoundarySeed, kInteriorSeed]) {
        bool closed;
        auto ring = collectEdgeRing(*m, seed, closed);
        assert(ring.length >= 2, format(
            "seed edge %d has a ring of %d edge(s); a cut that crosses fewer "
          ~ "than two faces never builds a second fragment and every "
          ~ "multi-fragment assertion below is vacuous", seed, ring.length));
        assert(!closed, format(
            "seed edge %d's ring came back CLOSED — this stand is supposed to "
          ~ "be an OPEN grid, and on a closed ring the terminating-fragment "
          ~ "arm is unreachable", seed));
    }

    // ---- 2. a SELECTED face among those the boundary-seed cut CONSUMES, and
    // another SELECTED face that SURVIVES it. Without the first, the
    // `faceMarks` Select row is unreachable and the whole `DenseSelectionUndo`
    // channel is vacuous; without the second, "restored the selection" and
    // "restored nothing but rebuilt the same mesh" look identical.
    {
        auto cut = cutFaces(*m, kBoundarySeed);
        bool selConsumed = false, selSurvived = false;
        foreach (fi; 0 .. m.faces.length) {
            if (!m.isFaceSelected(fi)) continue;
            bool inCut = false;
            foreach (c; cut) if (c == fi) inCut = true;
            if (inCut) selConsumed = true; else selSurvived = true;
        }
        assert(selConsumed, format(
            "the boundary-seed cut crosses faces %s and NONE of them is "
          ~ "selected — `setFaceMarksFrom(newWord, ~Marks.Select)` at "
          ~ "mesh_ops/loop_slice.d then clears a bit nothing was carrying",
            cut));
        assert(selSurvived,
            "every selected face is inside the boundary-seed cut — with no "
          ~ "surviving selected face, a revert that restores nothing and one "
          ~ "that restores everything produce the same selection plane");
    }

    // ---- 3. faceSelectionOrder is NOT a function of the Select plane, so a
    // revert that drops the order arrays cannot read identical.
    assert(m.faceSelectionOrder[2] != 0 && m.faceSelectionOrder[6] != 0,
        "the stand's faceSelectionOrder is flat outside the selected faces — "
      ~ "these two synthetic stamps are the only thing that separates "
      ~ "`DenseSelectionUndo`'s wholesale order copy from a plain "
      ~ "`SelectionSnapshot.restore`, which re-zeroes them");

    // ---- 4. per-corner UV values are DISTINCT. A value restored onto the
    // WRONG corner must fail as loudly as one that vanished — which is the
    // whole subject of the N=3 cell.
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null && uv.domain == MapDomain.PolyVertex,
        "the stand carries no PolyVertex `" ~ kUvMapName ~ "` map — the "
      ~ "per-corner plane a face rewrite loses first is absent");
    bool[float] seenU;
    foreach (k; 0 .. uv.data.length / uv.dim) {
        immutable float u = uv.data[k * uv.dim];
        assert((u in seenU) is null, format(
            "uv corner %d repeats the value %s — a value restored onto the "
          ~ "wrong corner would compare EQUAL", k, u));
        seenU[u] = true;
    }

    // ---- 5. is per cell (V/F/E actually moved) — see `l9Cells`.
}

// ===========================================================================
// The roster.
//
// FIVE FROZEN CELLS, and the plan's sixth — the REFUSAL — is deliberately not
// one of them: a refusing command leaves `postOp == postUndo == pre`, which is
// the exact shape the anti-vacuity assert refuses, and freezing a pair of
// identical dumps is a check that cannot come out differently. The refusal is
// asserted directly instead, in its own block at the bottom of this file.
// (Stage L5 took the same decision for the same reason; this is the repeat of
// that argument, not a new one.)
// ===========================================================================

/// Edge 0 (`[0, 1]`) has ONE incident face — a boundary seed.
private enum uint kBoundarySeed = 0;
/// Edge 1 (`[1, 5]`) has TWO — an interior seed.
private enum uint kInteriorSeed = 1;

private enum L9Cmd { loopSlice, addLoop }

private struct L9CellSpec {
    string name;
    L9Cmd  which;
    uint   seed;
    int    count;      // loopSlice only
    float  position;   // addLoop only
}

private immutable L9CellSpec[] kL9Specs = [
    // N = 1: every fragment can be restored slot-for-slot, so a
    // payload-pairing or fragment-ORDERING defect is invisible here. Present
    // as the CONTROL for the cell below it, not as its own witness.
    L9CellSpec("mesh.loopSlice/N1",           L9Cmd.loopSlice, kInteriorSeed, 1, 0),
    // N = 3: one old quad becomes FOUR fragments, and the corner on the far
    // rail lives in the LAST fragment, not the first. This is the cell the
    // stage exists for.
    L9CellSpec("mesh.loopSlice/N3",           L9Cmd.loopSlice, kInteriorSeed, 3, 0),
    // The open-ring termination arm, seeded on the boundary — and the cell
    // whose cut consumes a SELECTED face.
    L9CellSpec("mesh.loopSlice/boundarySeed", L9Cmd.loopSlice, kBoundarySeed, 3, 0),
    L9CellSpec("mesh.addLoop/interior",       L9Cmd.addLoop,   kInteriorSeed, 0, 0.5f),
    L9CellSpec("mesh.addLoop/boundary",       L9Cmd.addLoop,   kBoundarySeed, 0, 0.25f),
];

/// What one run of one cell produced.
private struct CellRun {
    string postOp, postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
    size_t preEdges, postEdges;
    size_t cutFaceCount;
}

/// Seed the command: the two classes both take the FIRST selected edge, so the
/// cell's seed is expressed as an edge selection and nothing else.
private void seedOnly(Mesh* m, uint seed)
{
    m.clearEdgeSelection();
    m.selectEdge(seed);
    assert(m.isEdgeSelected(seed),
        format("the stand refused to select edge %d — the cell would then "
             ~ "drive whichever edge happened to be selected first", seed));
}

private Command makeCommand(in L9CellSpec s, Mesh* m, View v)
{
    final switch (s.which) {
        case L9Cmd.loopSlice:
            auto c = new MeshLoopSlice(m, v, EditMode.Edges);
            setI(cast(Command) c, "count", s.count);
            return cast(Command) c;
        case L9Cmd.addLoop:
            auto c = new MeshAddLoop(m, v, EditMode.Edges);
            setF(cast(Command) c, "position", s.position);
            return cast(Command) c;
    }
}

/// `stand -> seed -> op -> undo`, dumping after the op and again after the
/// undo. `apply()` and `revert()` are ASSERTED, not merely called.
private CellRun l9RunOnce(in L9CellSpec s, in PlaneDumpMeta meta)
{
    auto m = l9Stand();
    seedOnly(m, s.seed);

    CellRun r;
    r.preVerts     = m.vertices.length;
    r.preFaces     = m.faces.length;
    r.preEdges     = m.edges.length;
    r.cutFaceCount = cutFaces(*m, s.seed).length;

    auto v = new View(0, 0, 800, 600);
    Command c = makeCommand(s, m, v);

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    r.postVerts = m.vertices.length;
    r.postFaces = m.faces.length;
    r.postEdges = m.edges.length;
    r.postOp    = meshPlanesJson(*m, meta);

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);

    return r;
}

/// Every L9 cell, in a fixed order, plus the cross-cell asserts no single cell
/// can make.
ParityCell[] l9Cells()
{
    auto meta = PlaneDumpMeta(kL9ProducedBy, "snapshot", kL9Family, kL9Stand);

    ParityCell[] out_;
    CellRun[string] runs;
    foreach (ref s; kL9Specs) {
        auto r = l9RunOnce(s, meta);
        runs[s.name] = r;
        out_ ~= ParityCell(s.name, "snapshot", r.postOp, r.postUndo);
    }

    // Non-vacuity item 5, per cell: the op MOVED something. Every cell in this
    // family adds vertices, faces AND edges, so the channel is the same for
    // all five and the assertion can be strict.
    foreach (ref s; kL9Specs) {
        auto r = runs[s.name];
        assert(r.postVerts > r.preVerts && r.postFaces > r.preFaces
            && r.postEdges > r.preEdges,
            format("%s: the op left V=%d->%d F=%d->%d E=%d->%d — a cut that "
                 ~ "grows nothing means every assertion about its undo is "
                 ~ "satisfied by an undo that does nothing", s.name,
                   r.preVerts, r.postVerts, r.preFaces, r.postFaces,
                   r.preEdges, r.postEdges));
    }

    // THE MULTI-FRAGMENT ASSERT, and it is the reason `mesh.loopSlice/N3`
    // exists. A cut at N positions turns each crossed face into N+1
    // fragments, so `postFaces == preFaces + N * cutFaceCount`. At N = 1 the
    // fragments restore SLOT FOR SLOT and a corner-payload pairing defect is
    // invisible; the cell below must carry at least THREE fragments per
    // crossed face, i.e. at least two more faces than the crossed count.
    foreach (nm; ["mesh.loopSlice/N3", "mesh.loopSlice/boundarySeed"]) {
        auto r = runs[nm];
        assert(r.cutFaceCount >= 2, format(
            "%s crossed %d face(s)", nm, r.cutFaceCount));
        immutable size_t frags =
            (r.postFaces - r.preFaces) / r.cutFaceCount + 1;
        assert(frags >= 3, format(
            "%s produced %d fragment(s) per crossed face (F %d -> %d over %d "
          ~ "crossed face(s)). At fewer than three the corner on the far rail "
          ~ "still lands in the FIRST fragment, every fragment restores "
          ~ "slot-for-slot, and a multi-fragment corner mismatch cannot fail "
          ~ "visibly — which is exactly what this cell is for", nm, frags,
            r.preFaces, r.postFaces, r.cutFaceCount));
    }
    // …and the N=1 control must NOT reach that count, or the two cells are one
    // cell written twice and the split is not measuring the fragment logic.
    {
        auto r = runs["mesh.loopSlice/N1"];
        immutable size_t frags =
            (r.postFaces - r.preFaces) / r.cutFaceCount + 1;
        assert(frags == 2, format(
            "mesh.loopSlice/N1 produced %d fragment(s) per crossed face, "
          ~ "expected exactly 2 — `count` is not reaching the kernel and this "
          ~ "cell is not the single-fragment control the N=3 cell is "
          ~ "contrasted against", frags));
    }

    // The two seeds must not produce the same post-op state, or the boundary
    // arm is not being exercised and its cell is a duplicate.
    assert(runs["mesh.loopSlice/N3"].postOp
        != runs["mesh.loopSlice/boundarySeed"].postOp,
        "the interior-seed and boundary-seed cuts left the SAME post-op "
      ~ "state — the seed is not reaching the ring walk, so the open-ring "
      ~ "termination arm is untested");
    assert(runs["mesh.addLoop/interior"].postOp
        != runs["mesh.addLoop/boundary"].postOp,
        "mesh.addLoop's two cells left the same post-op state — `position` "
      ~ "and the seed are not reaching the kernel");
    // …and `mesh.addLoop` must NOT be `mesh.loopSlice` at count 1 with the
    // same position, or the second class is silently absent from the fixture
    // (L6.8 item 6: "a class silently absent is indistinguishable from a class
    // that passes"). They differ here by the POSITION alone: addLoop/interior
    // cuts at 0.5, loopSlice/N1 at 1/(1+1) = 0.5 — so this pair would AGREE,
    // and the assertion is on the `boundary` cell, which cuts at 0.25.
    assert(runs["mesh.addLoop/boundary"].postOp
        != runs["mesh.loopSlice/boundarySeed"].postOp,
        "mesh.addLoop/boundary and mesh.loopSlice/boundarySeed left the same "
      ~ "post-op state — the two classes are not distinguishable in this "
      ~ "fixture and one of them is effectively absent");

    return out_;
}

// ===========================================================================
// NO EXCEPTION TABLE, and that is a measured claim rather than an omission.
//
// L3 and L5 both carry a `faceSelectionOrder` normalisation, because their
// commands restore through a bare `SelectionSnapshot` whose tail re-zeroes the
// order stamp of every element that did not end up selected (task 0613 S3), so
// the migrated path legitimately restores LESS on that one plane than
// `MeshSnapshot` did. `DenseSelectionUndo` runs that same tail and then copies
// the three order arrays back WHOLESALE (`selection_undo.d`'s
// `m.faceSelectionOrder = sel_.faceSelectionOrder.dup`, and the two siblings),
// so the stand's synthetic stamps on faces 2 and 6 survive verbatim and there
// is nothing here to normalise. Measured: the reader compares plane-for-plane
// through `comparePlanes` with no licence of any kind and is green.
//
// So this reader deliberately does NOT reach for `compareWithExceptions`. An
// empty `PlaneException[]` would be worse than none: `assertExceptionTableWell-
// Formed` refuses one outright, precisely because an empty table makes the
// exception machinery dead code that no mutation can score. If a plane starts
// diverging here, the answer is a code fix, or an argued and reviewed table
// introduced together with its own well-formedness cell — never a re-capture.
// ===========================================================================

// ===========================================================================
// Compare, or capture.
// ===========================================================================

private void compareOrCaptureL9(ParityCell[] cells)
{
    import std.file    : exists, readText, write, mkdirRecurse;
    import std.path    : dirName;
    import std.process : environment;

    // ---- anti-vacuity, BEFORE anything is compared or written -------------
    assert(cells.length == kL9Specs.length && cells.length == 5,
        format("the recipe produced %d cells, the roster declares %d and the "
             ~ "stage owes 5", cells.length, kL9Specs.length));
    foreach (ref c; cells)
        assert(c.postOp != c.postUndo,
               kL9Family ~ ": cell '" ~ c.name ~ "' has postOp == postUndo, so "
             ~ "its forward moved no plane this dump can see. Every assertion "
             ~ "about its undo is then satisfied by an undo that does nothing.");

    immutable path = fixturePath("loop_slice.json");

    if (environment.get("VIBE3D_PARITY_CAPTURE_L9", "") == "1") {
        mkdirRecurse(dirName(path));
        write(path, fixtureJson(kL9Family, kL9ProducedBy, kL9Stand, cells));
        return;
    }

    assert(exists(path),
           "missing parity fixture " ~ path ~ " — it must be frozen BEFORE the "
         ~ "`MeshSnapshot` arms are deleted from commands/mesh/loop_slice.d; "
         ~ "re-capturing on a tree that no longer HAS them would be the delta "
         ~ "path grading its own homework");

    auto frozen = parseJSON(readText(path));

    // The immutability pin. `producedBy` is not merely non-empty here — it
    // must still name the capture tree, because from stage L9-a on nothing
    // legitimate can re-produce this file.
    assert(frozen["producedBy"].str == kL9ProducedBy,
           format("%s: producedBy is '%s', expected '%s'. This fixture is "
                ~ "IMMUTABLE from stage L9-a onward — a legitimate "
                ~ "normalisation is a NAMED PER-PLANE EXCEPTION in this "
                ~ "reader, argued and reviewed, never a re-capture",
                  path, frozen["producedBy"].str, kL9ProducedBy));
    assert(frozen["stand"].str == kL9Stand,
           format("%s: stand is '%s', expected '%s'", path,
                  frozen["stand"].str, kL9Stand));

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
        comparePlanes(path, c.name, "postOp",   fc["postOp"],   c.postOp);
        comparePlanes(path, c.name, "postUndo", fc["postUndo"], c.postUndo);
    }
}

// ---------------------------------------------------------------------------
// THE READER.
//
// MUTATION THAT REDDENS IT: delete the `preSel_.restore(*mesh)` call from
// `MeshLoopSlice.revert`. `vertices`, `faces`, `edges`, every winding,
// `faceMaterial`, `facePart`, both set masks, the Hide/Subpatch bits and
// `meshMaps["uv"]` all compare EQUAL, and only the seven Select-class rows
// differ — which is the F1 loss list made executable (witness W-9-a1).
// ---------------------------------------------------------------------------
unittest
{
    compareOrCaptureL9(l9Cells());
}
