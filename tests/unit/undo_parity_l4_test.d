// undo_parity_l4_test — the FROZEN parity fixture for stage L4's family
// (`mesh.axisSlice`, `mesh.julienne`, `mesh.screenSlice`, `mesh.edgeSlice`,
// `mesh.cut`), and the reader that makes it an oracle.
//
// WHY IT LANDS BEFORE THE FIRST SOURCE CHANGE THAT ALTERS UNDO (§6.3 rule 1).
// All five classes hold the `MeshSnapshot` that IS the comparison, and stages
// L4-a … L4-d delete it. Unlike stage L3, this family has NO live parity gate
// of any kind — there is no `undo.tracker.off` arm to run it against — so this
// file is the ONLY oracle it will ever have. The two dumps per cell are not
// decoration either (inherited from `undo_parity_l0_test`'s header): a fixture
// holding only the post-undo state is green for a cell whose FORWARD silently
// stopped doing anything.
//
// ---------------------------------------------------------------------------
// THE CAPTURE TREE, AND THE TWO FORWARD COMMITS THAT PRECEDE IT
// ---------------------------------------------------------------------------
// `producedBy` names this lane's branch point. TWO commits sit between it and
// the capture and BOTH touch the forward, so saying so is part of the
// provenance rather than a footnote:
//
//   * **L4-P0** gave `mesh.edgeSlice` and `mesh.cut` the `MeshEditBatch` the
//     other three already had. MEASURED over `/api/command` on this build:
//     `unbatchedGeometryCommits` for `mesh.edgeSlice` 4 -> 0 and for `mesh.cut`
//     2 -> 0, `nestedBatchOpens` and `batchLeaks` 0 on both sides. MEASURED in
//     process, plane by plane: the `meshPlanesJson` FORWARD of both kernels is
//     BYTE-IDENTICAL batched and unbatched. So the stage plan's reason for
//     ordering L4-P0 ahead of this file — "the derives and the delivery count
//     move, and a `postOp` frozen on the unbatched shape reproduces as *the
//     forward changed*" — is TRUE of the counters and FALSE of this dump,
//     which carries none of them. The ordering was kept anyway: it costs
//     nothing and the claim it rests on is now a measurement instead of a
//     prediction.
//   * **L4-P1** gave `Mesh.edgeSliceEx`'s two non-splitting arms the corner
//     declaration they owed. Outside `-debug` that changes NOTHING —
//     `resizePolyVertexMaps`' undeclared branch already zeroed the plane and
//     the `debug assert` compiles out under `-release`. Inside `-debug` it is
//     the difference between a cell that runs and a unit lane that ABORTS: 16
//     operands over face 0 reach the KEEP+FINALIZE arm on this stand and every
//     one of them aborted before that fix. Cell `mesh.edgeSlice/keepFinalize`
//     could not exist without it.
//
// ---------------------------------------------------------------------------
// WHAT THIS FAMILY OWES — MEASURED, AND IT IS **ZERO NEW PUBLISHERS**
// ---------------------------------------------------------------------------
// §5.5's L4 row demands `AddVerts`/`AddFaces`/`ReshapeFaces` and says
// "`FaceReindex`: no". Both halves are stale: stage L2-c routed
// `Mesh.insertEdgePoint`'s splice through `Mesh.setFaceWindings` and stage
// L2-d routed `Mesh.rebuildFacesWithChordSplits`' install through
// `mesh_planes.rewriteFaces` under an armed `faceReindexScope()`. Measured at
// the KERNEL under a RECORDING batch on this stand, 2026-08-28:
//
//   cutByPlane           [AddVerts MeshMapDelta ReshapeFaces
//                         (AddVerts ReshapeFaces) x3  FaceReindex]
//   edgeSliceEx  arm (i) [AddVerts MeshMapDelta ReshapeFaces
//                         AddVerts ReshapeFaces FaceReindex]
//   edgeSliceEx arm (ii) [AddVerts MeshMapDelta ReshapeFaces]  -- no FaceReindex
//   edgeSliceEx arm (iii)[]                                    -- empty
//   deleteFacesByMask    [MeshMapDelta RemoveFaces]  (+ RemoveVerts Reindex
//                                                     when it orphans)
//
// and `revert()` answers true on every one of them. So the family builds NO
// publisher. Its whole content is: open a RECORDING batch, hold a
// `MeshEditDelta` plus two belts, and call `acceptRecordedEdit`.
//
// THE TWO BELTS, AND WHY EXACTLY TWO. Measured by DROPPING each of
// `delete.d`'s four in turn and diffing the result against the
// `MeshSnapshot` oracle on the same forward:
//
//   preSel_  (SelectionSnapshot)  LOAD-BEARING on all five  -- drop it and
//                                 `faceMarks` diverges
//   preMaps_ (the mesh-map set)   LOAD-BEARING on the four SLICES -- drop it
//                                 and `meshMaps` diverges; INERT on
//                                 `mesh.cut`'s kernel, where `RemoveFaces`
//                                 carries its own payload
//   preMarksWord_                 INERT on all five: `FaceReindex` and
//                                 `RemoveFaces` both carry the whole face
//                                 marks word
//   preEdgeEnds_                  INERT on all five, INCLUDING a cell whose
//                                 selected edges are the ones the plane
//                                 CROSSES (measured separately, because
//                                 "inert on edges the cut never touches" is
//                                 not the same claim)
//
// The two inert ones are NOT carried, and that is a ruling rather than
// laziness. A belt runs AFTER `delta_.revert` and OVERWRITES what the replay
// restored, so while it exists the payload's output on this family is
// UNOBSERVABLE — the exact reason stage L5-e deleted three belts from
// `delete.d`. Carrying an inert belt "for safety" makes this fixture unable to
// tell a working payload from a broken one, permanently.
//
// WHY THE PER-CORNER PLANE NEEDS A BELT AT ALL, since a `MeshMapDelta` IS
// recorded: the plane cuts are in the documented per-corner DROP set
// (`Mesh.addEdgePoint`'s comment). The FORWARD zeroes the whole UV plane
// (measured: 96 values, 0 non-zero after one `cutByPlane`), because a splice
// puts the PolyVertex maps OUT OF STEP with `faces`, after which
// `recordPolyVertexPayload` DECLINES — which is visible in the op-log above as
// one `MeshMapDelta` on the FIRST face entry and none on the later ones. The
// shipped `MeshSnapshot` restores the plane; a bare delta replay cannot invent
// it. Without `preMaps_` this migration would be a REGRESSION against the
// shipped path, not a gap.
//
// ---------------------------------------------------------------------------
// THE FILE IS IMMUTABLE FROM STAGE L4-a ONWARD, for `undo_parity_l9_test.d`'s
// reason verbatim: re-freezing presupposes a producer, and once the snapshot
// arms are gone the only thing that can produce a `slice_cut.json` is the
// delta path capturing itself.
//
//   * `postUndo` differs  => the migration restores LESS. Fix the code.
//   * `postOp`   differs  => the FORWARD changed. Louder, and out of scope.
//   * a legitimate normalisation => a NAMED PER-PLANE EXCEPTION in this
//     reader, reviewed, with its reason at the exception. NOT a re-capture.
//
// ---------------------------------------------------------------------------
// A SEPARATE CAPTURE KEY, `VIBE3D_PARITY_CAPTURE_L4`, WRITING EXACTLY ONE
// FILE — `tests/unit/parity_capture_key_census_test.d` asserts the
// `leaf <-> key` map is 1:1 across every reader. The `git status` of
// `tests/fixtures/undo_parity/` after a capture is the check that it worked.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l4_test;

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
                                        fixtureJson, setF, setI;

import commands.mesh.axis_slice   : MeshAxisSlice, MeshJulienne;
import commands.mesh.screen_slice : MeshScreenSlice;
import commands.mesh.edge_slice   : MeshEdgeSlice;
import commands.mesh.cut_         : MeshCut;

enum string kL4Family = "slice_cut";
enum string kL4Stand  = "makeTaggedGridFull(3)";

/// The tree that PRODUCED the frozen dumps: this lane's branch point. See the
/// header for the two forward-touching commits that sit between it and the
/// capture, and the measurement that says neither moves this dump.
enum string kL4ProducedBy = "4e778f3a";

// ===========================================================================
// The stand — and it is `makeTaggedGridFull(3)` UNMODIFIED, which is itself a
// finding.
//
// The stage plan specified a NEW sibling, `makeTaggedGridSolid(3)`, on the
// ground that the shipped grid is FLAT and "`MeshAxisSlice`'s `span < 1e-6f`
// guard and `MeshJulienne`'s second pass refuse it" — inherited from the perf
// lane's `CmdExclusion("mesh.julienne", "refuses the flat grid on both axis
// pairs tried")`. MEASURED on THIS stand instead of inherited (памятка 2 — a
// `CmdExclusion` is a statement about the perf lane's stand, never about
// yours):
//
//   axis 0 (X)  span 2.0000  -> 3 faces split
//   axis 1 (Y)  span 0.0000  -> refuses, correctly: the sheet is flat in Y
//   axis 2 (Z)  span 2.0000  -> 3 faces split
//
// So the grid refuses only its FLAT axis, `mesh.julienne`'s DEFAULT axis pair
// is X and Z, and both cells drive it. A new stand would have bought nothing
// and cost a second thing to keep in step with `makeTaggedGridFull`, which
// `undo_parity_l0_test` and `undo_parity_l3_test` already read. The cells name
// axis 0 explicitly rather than leaning on `MeshAxisSlice`'s default of 1,
// which really would refuse.
//
// WHAT THE STAND CARRIES THAT MATTERS HERE, each traceable to a cell:
//   * a PolyVertex UV map with a DISTINCT value per corner — without it every
//     `preMaps_` assertion is vacuous and a value restored onto the WRONG
//     corner compares equal;
//   * non-uniform `faceMaterial` / `facePart` / `faceSetMask` and a
//     non-monotonic `faceSelectionOrder` — the three planes with no restorer
//     outside `RemoveFaces`, plus the one the chord rebuild reinstalls
//     wholesale;
//   * a face selection (face 7) that SURVIVES every cut, so "the marks were
//     carried" and "there were no marks" are different pictures;
//   * a vertex selection and an EDGE selection, so the Select plane is not one
//     bit wide;
//   * two edges on ONE face (face 0 = [0,1,5,4], its four edges 0..3), which
//     is what makes `mesh.edgeSlice`'s arms (ii) and (iii) reachable BY
//     PARAMETER;
//   * six of nine faces no cut plane touches, so a carried plane on a
//     SURVIVING face is something the assertions can be wrong about.
//
// A CUBE IS SPECIFICALLY WRONG, and not only for the usual reason: on a closed
// solid `mesh.cut`'s orphan cell cannot exist at all — every vertex is shared
// by three faces, so removing one face orphans nothing and the `RemoveVerts` +
// `Reindex` half of the kernel is never reached.
// ===========================================================================

private Mesh* l4Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

unittest // the stand can exhibit everything the roster claims to measure
{
    // MUTATION: build the stand on `Mesh.cube()`. Items 1, 3 and 5 fail by
    // name — a cube has no flat axis, no orphanable corner face and no
    // per-corner map.
    auto m = l4Stand();

    assert(m.faces.length == 9 && m.vertices.length == 16
        && m.edges.length == 24,
        format("the stand is V=%d F=%d E=%d, expected V=16 F=9 E=24 — every "
             ~ "index constant in this file names a face or an edge at random "
             ~ "otherwise", m.vertices.length, m.faces.length, m.edges.length));

    // ---- 1. EXTENT ON EXACTLY TWO AXES. Both halves are the assertion: with
    // extent on three, the axis-1 refusal recorded in the header stops being
    // true and the cells' explicit `axis: 0` stops being load-bearing; with
    // extent on one, `mesh.julienne`'s second pass refuses and its cell
    // measures a single cut wearing two names.
    {
        float[3] lo = [float.max, float.max, float.max];
        float[3] hi = [-float.max, -float.max, -float.max];
        foreach (v; m.vertices) {
            immutable float[3] c = [v.x, v.y, v.z];
            foreach (a; 0 .. 3) {
                if (c[a] < lo[a]) lo[a] = c[a];
                if (c[a] > hi[a]) hi[a] = c[a];
            }
        }
        assert(hi[0] - lo[0] > 1e-6f && hi[2] - lo[2] > 1e-6f,
            format("the stand has no extent on X (%g) or Z (%g) — "
                 ~ "`MeshAxisSlice`'s `span < 1e-6f` guard refuses both cells "
                 ~ "and `mesh.julienne` refuses outright",
                   hi[0] - lo[0], hi[2] - lo[2]));
        assert(hi[1] - lo[1] <= 1e-6f,
            format("the stand now has Y extent (%g). It was FLAT in Y when "
                 ~ "these cells were written, which is why they name `axis: 0` "
                 ~ "explicitly instead of taking `MeshAxisSlice`'s default of "
                 ~ "1. If the stand grew a third axis, say so at the cells "
                 ~ "rather than letting the default quietly start working",
                   hi[1] - lo[1]));
    }

    // ---- 2. face 0 is a QUAD with four distinct edges, which is what makes
    // `mesh.edgeSlice`'s three arms addressable by parameter.
    assert(m.faces[0].length == 4,
        format("face 0 has %d corner(s); the edgeSlice cells address its edges "
             ~ "0..3 by index", m.faces[0].length));
    foreach (k; 0 .. 4)
        assert((*m).edgeIndexOfVerts(m.faces[0][k], m.faces[0][(k + 1) % 4]) == k,
            format("face 0's edge %d is not at index %d — the edgeSlice cells "
                 ~ "name edge indices, and a re-numbered stand would silently "
                 ~ "drive different edges", k, k));

    // ---- 3. an ORPHANABLE corner face: deleting face 0 must leave at least
    // one vertex face-unreferenced, or `mesh.cut/orphan` is `mesh.cut/selected`
    // written twice and the `RemoveVerts` + `Reindex` half is never reached.
    {
        auto probe = l4Stand();
        probe.clearFaceSelection();
        probe.selectFace(0);
        immutable size_t preV = probe.vertices.length;
        cast(void) probe.deleteFacesByMask(probe.selectedFaces);
        assert(probe.vertices.length < preV,
            format("deleting the stand's corner face 0 orphaned NO vertex "
                 ~ "(V stayed %d) — `mesh.cut/orphan` then produces the same "
                 ~ "op-log as `mesh.cut/selected` and the compaction half of "
                 ~ "the kernel is untested", preV));
    }

    // ---- 4. a SELECTED face that no cut consumes, and a non-flat marks
    // plane. Without the first, "restored the selection" and "restored
    // nothing" look the same.
    assert(m.isFaceSelected(7), "the stand's face 7 is not selected");
    assert(m.faceSelectionOrder[2] != 0 && m.faceSelectionOrder[6] != 0,
        "the stand's faceSelectionOrder is flat outside the selected face — "
      ~ "these two synthetic stamps are what the standing per-plane exception "
      ~ "below normalises, and with them gone that exception describes "
      ~ "nothing");
    assert(m.isFaceSubpatch(1) && m.isFaceHidden(5),
        "the stand's Subpatch/Hide bits are flat — the marks word then "
      ~ "round-trips for free");

    // ---- 5. per-corner UV values are DISTINCT. A value restored onto the
    // WRONG corner must fail as loudly as one that vanished.
    auto uv = m.meshMap(kUvMapName);
    assert(uv !is null && uv.domain == MapDomain.PolyVertex,
        "the stand carries no PolyVertex `" ~ kUvMapName ~ "` map — the "
      ~ "per-corner plane this family's forward zeroes is absent, and every "
      ~ "`preMaps_` assertion is vacuous");
    bool[float] seenU;
    foreach (k; 0 .. uv.data.length / uv.dim) {
        immutable float u = uv.data[k * uv.dim];
        assert((u in seenU) is null, format(
            "uv corner %d repeats the value %s — a value restored onto the "
          ~ "wrong corner would compare EQUAL", k, u));
        seenU[u] = true;
    }
}

// ===========================================================================
// The roster.
//
// EIGHT FROZEN CELLS, and the plan's ninth — `mesh.edgeSlice`'s REFUSAL arm —
// is deliberately not one of them: a refusing command leaves
// `postOp == postUndo == pre`, which is the exact shape the anti-vacuity
// assert refuses, and freezing a pair of identical dumps is a check that
// cannot come out differently. The refusal is asserted directly instead, in
// its own block at the bottom of this file, with the three assertions a
// refusal needs. (Stages L5 and L9 took the same decision for the same
// reason; this is the repeat of that argument, not a new one.)
// ===========================================================================

private enum L4Cmd { axisSlice, julienne, screenSlice, edgeSlice, cut }

private struct L4CellSpec {
    string name;
    L4Cmd  which;
    int    axisA, countA, axisB, countB;   // axisSlice / julienne
    int    edgeA, edgeB;                   // edgeSlice
    float  tA, tB;                         // edgeSlice
    int    cutFace;                        // cut: the single face to select
    float  ax, ay, bx, by;                 // screenSlice
}

private immutable L4CellSpec[] kL4Specs = [
    // ONE plane. The control for the ladder cell below it: with a single cut
    // "the delta describes the whole ladder" and "the delta describes the last
    // cut" are the same claim.
    L4CellSpec("mesh.axisSlice/x1", L4Cmd.axisSlice, 0, 1, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0),
    // THREE planes in ONE batch. `MeshAxisSlice` opens its batch around the
    // whole ladder, so a delta that carried only the last cut round-trips the
    // COUNTS (every cut adds faces) and fails only here.
    L4CellSpec("mesh.axisSlice/x3", L4Cmd.axisSlice, 0, 3, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0),
    // TWO AXES. The cell `MeshJulienne`'s batch lift exists for: before the
    // lift the class opened a batch PER AXIS, so the delta described the
    // SECOND axis alone — and face count, vertex count, edge count and
    // `opInverse` are all green under that, because both axes add faces.
    // `changeBus.nestedBatchOpens` and `batchLeaks` do not move either: the
    // two opens were SEQUENTIAL, not nested.
    L4CellSpec("mesh.julienne/xz", L4Cmd.julienne, 0, 1, 2, 1, 0, 0, 0, 0, 0,
               0, 0, 0, 0),
    // The camera-plane arm. Same kernel as `mesh.axisSlice`, reached through
    // `cameraPlaneFromScreenLine` — present so the class is not silently
    // absent from the fixture (L6.8 item 6), and the cross-cell assert below
    // requires its post-op state to differ from the axis cells'.
    L4CellSpec("mesh.screenSlice", L4Cmd.screenSlice, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               200, 100, 600, 500),
    // arm (i): a real chord split across face 0's two OPPOSITE edges.
    L4CellSpec("mesh.edgeSlice/split", L4Cmd.edgeSlice, 0, 0, 0, 0, 0, 2,
               0.5f, 0.5f, 0, 0, 0, 0, 0),
    // arm (ii), KEEP + FINALIZE, and it is the cell this stage nearly shipped
    // without. Two ADJACENT edges of face 0: `tA = 0.5` splices a real vertex
    // in, `tB = 0` reuses the shared corner, the two land ADJACENT in the
    // winding, `rebuildFacesWithChordSplits`' adjacent-hit guard splits
    // nothing, and the kernel runs its finalize tail by hand. The op-log is
    // `[AddVerts MeshMapDelta ReshapeFaces]` with NO `FaceReindex` — the only
    // place in this family where appends occur without a Pass-2 entry.
    L4CellSpec("mesh.edgeSlice/keepFinalize", L4Cmd.edgeSlice, 0, 0, 0, 0, 0, 1,
               0.5f, 0.0f, 0, 0, 0, 0, 0),
    // `mesh.cut` on the stand's own selection — face 7, an interior face whose
    // removal orphans nothing. `[MeshMapDelta RemoveFaces]`.
    L4CellSpec("mesh.cut/selected", L4Cmd.cut, 0, 0, 0, 0, 0, 0, 0, 0, 7,
               0, 0, 0, 0),
    // …and on the CORNER face, which orphans its outer vertex and reaches the
    // compaction half: `[MeshMapDelta RemoveFaces RemoveVerts Reindex]`. The
    // pair is what separates the two halves of one kernel.
    L4CellSpec("mesh.cut/orphan", L4Cmd.cut, 0, 0, 0, 0, 0, 0, 0, 0, 0,
               0, 0, 0, 0),
];

/// What one run of one cell produced.
private struct CellRun {
    string postOp, postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
}

private Command makeCommand(in L4CellSpec s, Mesh* m, View v)
{
    final switch (s.which) {
        case L4Cmd.axisSlice:
            auto c = new MeshAxisSlice(m, v, EditMode.Polygons);
            setI(cast(Command) c, "axis",  s.axisA);
            setI(cast(Command) c, "count", s.countA);
            return cast(Command) c;
        case L4Cmd.julienne:
            auto c = new MeshJulienne(m, v, EditMode.Polygons);
            setI(cast(Command) c, "axisA",  s.axisA);
            setI(cast(Command) c, "countA", s.countA);
            setI(cast(Command) c, "axisB",  s.axisB);
            setI(cast(Command) c, "countB", s.countB);
            return cast(Command) c;
        case L4Cmd.screenSlice:
            auto c = new MeshScreenSlice(m, v, EditMode.Polygons);
            setF(cast(Command) c, "ax", s.ax);
            setF(cast(Command) c, "ay", s.ay);
            setF(cast(Command) c, "bx", s.bx);
            setF(cast(Command) c, "by", s.by);
            return cast(Command) c;
        case L4Cmd.edgeSlice:
            auto c = new MeshEdgeSlice(m, v, EditMode.Edges);
            setEdges(cast(Command) c, [cast(uint) s.edgeA, cast(uint) s.edgeB]);
            setF(cast(Command) c, "tA", s.tA);
            setF(cast(Command) c, "tB", s.tB);
            return cast(Command) c;
        case L4Cmd.cut:
            return cast(Command) new MeshCut(m, v, EditMode.Polygons);
    }
}

/// `setI`'s missing sibling: `edges` is an IntArray param and
/// `undo_parity_l0_test` has no setter for one. Asserts rather than refuses,
/// for that file's stated reason — a renamed param must STOP the capture, not
/// leave the command at its default and freeze a dump of an operation nobody
/// performed. `MeshEdgeSlice` refuses outright on `edges.length != 2`, so a
/// silent miss here would make every edgeSlice cell a refusal.
private void setEdges(Command c, uint[] v)
{
    foreach (ref p; c.params()) if (p.name == "edges") { *p.uiaPtr = v; return; }
    assert(false, "no IntArray param `edges` on " ~ c.name());
}

/// `stand -> select -> op -> undo`, dumping after the op and again after the
/// undo. `apply()` and `revert()` are ASSERTED, not merely called.
private CellRun l4RunOnce(in L4CellSpec s, in PlaneDumpMeta meta)
{
    auto m = l4Stand();
    if (s.which == L4Cmd.cut) {
        // `MeshCut` reads `mesh.selectedFaces` RAW — not `operandFaceMask()` —
        // so the empty-selection whole-mesh convention does not apply and the
        // cell must name its face.
        m.clearFaceSelection();
        m.selectFace(cast(uint) s.cutFace);
        assert(m.isFaceSelected(cast(uint) s.cutFace),
            format("%s: the stand refused to select face %d", s.name, s.cutFace));
    }

    CellRun r;
    r.preVerts = m.vertices.length;
    r.preFaces = m.faces.length;

    auto v = new View(0, 0, 800, 600);
    Command c = makeCommand(s, m, v);

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    r.postVerts = m.vertices.length;
    r.postFaces = m.faces.length;
    r.postOp    = meshPlanesJson(*m, meta);

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);

    return r;
}

/// Every L4 cell, in a fixed order, plus the cross-cell asserts no single cell
/// can make.
ParityCell[] l4Cells()
{
    auto meta = PlaneDumpMeta(kL4ProducedBy, "snapshot", kL4Family, kL4Stand);

    ParityCell[] out_;
    CellRun[string] runs;
    foreach (ref s; kL4Specs) {
        auto r = l4RunOnce(s, meta);
        runs[s.name] = r;
        out_ ~= ParityCell(s.name, "snapshot", r.postOp, r.postUndo);
    }

    // ---- non-vacuity, PER CELL, and the channel differs by cell, which is
    // why this is not one loop with one predicate. The four slice cells GROW
    // the face count; `mesh.cut` SHRINKS it; and `mesh.edgeSlice/keepFinalize`
    // grows the VERTEX count while leaving the face count alone, which is the
    // whole point of that arm.
    foreach (nm; ["mesh.axisSlice/x1", "mesh.axisSlice/x3", "mesh.julienne/xz",
                  "mesh.screenSlice", "mesh.edgeSlice/split"]) {
        auto r = runs[nm];
        assert(r.postFaces > r.preFaces,
            format("%s: F %d -> %d — a slice that splits no face means every "
                 ~ "assertion about its undo is satisfied by an undo that does "
                 ~ "nothing", nm, r.preFaces, r.postFaces));
    }
    {
        auto r = runs["mesh.edgeSlice/keepFinalize"];
        assert(r.postFaces == r.preFaces && r.postVerts == r.preVerts + 1,
            format("mesh.edgeSlice/keepFinalize left F %d -> %d and V %d -> %d, "
                 ~ "expected F unchanged and V + 1. That signature IS the arm: "
                 ~ "a face count that moved means Pass 2 split something and "
                 ~ "this cell is `mesh.edgeSlice/split` written twice; a vertex "
                 ~ "count that did not move means Pass 1 reused a corner and "
                 ~ "the cell fell through to the TRUE no-op arm, which refuses",
                   r.preFaces, r.postFaces, r.preVerts, r.postVerts));
    }
    foreach (nm; ["mesh.cut/selected", "mesh.cut/orphan"]) {
        auto r = runs[nm];
        assert(r.postFaces == r.preFaces - 1,
            format("%s: F %d -> %d, expected exactly one face removed",
                   nm, r.preFaces, r.postFaces));
    }
    // …and the two `mesh.cut` cells must differ in the half that matters: the
    // orphan cell COMPACTS, the selected cell does not. Without this the pair
    // is one cell twice and the `RemoveVerts` + `Reindex` half is untested.
    assert(runs["mesh.cut/selected"].postVerts == runs["mesh.cut/selected"].preVerts,
        "mesh.cut/selected compacted a vertex — it is supposed to be the "
      ~ "NON-orphaning half of the pair");
    assert(runs["mesh.cut/orphan"].postVerts < runs["mesh.cut/orphan"].preVerts,
        "mesh.cut/orphan compacted NOTHING — the `RemoveVerts` + `Reindex` "
      ~ "half of the kernel is not reached and this cell duplicates its "
      ~ "sibling");

    // ---- the ladder really is a ladder: three planes must cut strictly more
    // than one. A delta that described only the last cut would still round-trip
    // the counts, which is why this lives here and the real check is the frozen
    // dump.
    assert(runs["mesh.axisSlice/x3"].postFaces > runs["mesh.axisSlice/x1"].postFaces,
        format("mesh.axisSlice at count 3 produced %d face(s) and at count 1 "
             ~ "produced %d — `count` is not reaching the loop, so the "
             ~ "one-batch-per-ladder cell is the single-cut cell twice",
               runs["mesh.axisSlice/x3"].postFaces,
               runs["mesh.axisSlice/x1"].postFaces));

    // ---- every class is DISTINGUISHABLE. A class whose post-op state equals
    // another's is effectively absent from the fixture (L6.8 item 6).
    static immutable string[] distinct = [
        "mesh.axisSlice/x1", "mesh.julienne/xz", "mesh.screenSlice",
        "mesh.edgeSlice/split", "mesh.cut/selected",
    ];
    foreach (i, a; distinct)
        foreach (b; distinct[i + 1 .. $])
            assert(runs[a].postOp != runs[b].postOp,
                format("%s and %s left the SAME post-op state — one of the two "
                     ~ "classes is not actually being driven and its cell "
                     ~ "cannot fail", a, b));

    return out_;
}

// ===========================================================================
// NO EXCEPTION TABLE, and that is a measured claim rather than an omission.
//
// L3 and L5 both carry a `faceSelectionOrder` normalisation, because their
// commands restore through a bare `SelectionSnapshot`, whose tail re-zeroes the
// order stamp of every element that did not end up selected (task 0613 S3) —
// so on that ONE plane the migrated path legitimately restores LESS than
// `MeshSnapshot` did, and the fixture needs a licence for it.
//
// This family holds a `DenseSelectionUndo` instead, which runs that same tail
// and then copies the three order arrays back WHOLESALE. The stand's synthetic
// stamps on the unselected faces 2 and 6 therefore survive verbatim and there
// is nothing to normalise. That was the reason for choosing the dense image
// over the bare snapshot: measured, the bare one made all seven non-`orphan`
// cells diverge on `faceSelectionOrder` and would have bought this reader a
// seven-row exception table over a plane nobody was then comparing.
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

private void compareOrCaptureL4(ParityCell[] cells)
{
    import std.file    : exists, readText, write, mkdirRecurse;
    import std.path    : dirName;
    import std.process : environment;

    // ---- anti-vacuity, BEFORE anything is compared or written -------------
    assert(cells.length == kL4Specs.length && cells.length == 8,
        format("the recipe produced %d cells, the roster declares %d and the "
             ~ "stage owes 8", cells.length, kL4Specs.length));
    foreach (ref c; cells)
        assert(c.postOp != c.postUndo,
               kL4Family ~ ": cell '" ~ c.name ~ "' has postOp == postUndo, so "
             ~ "its forward moved no plane this dump can see. Every assertion "
             ~ "about its undo is then satisfied by an undo that does nothing.");

    immutable path = fixturePath("slice_cut.json");

    if (environment.get("VIBE3D_PARITY_CAPTURE_L4", "") == "1") {
        mkdirRecurse(dirName(path));
        write(path, fixtureJson(kL4Family, kL4ProducedBy, kL4Stand, cells));
        return;
    }

    assert(exists(path),
           "missing parity fixture " ~ path ~ " — it must be frozen BEFORE the "
         ~ "`MeshSnapshot` arms are deleted from the five slice/cut commands; "
         ~ "re-capturing on a tree that no longer HAS them would be the delta "
         ~ "path grading its own homework");

    auto frozen = parseJSON(readText(path));

    // The immutability pin. `producedBy` is not merely non-empty here — it
    // must still name the capture tree, because from stage L4-a on nothing
    // legitimate can re-produce this file.
    assert(frozen["producedBy"].str == kL4ProducedBy,
           format("%s: producedBy is '%s', expected '%s'. This fixture is "
                ~ "IMMUTABLE from stage L4-a onward — a legitimate "
                ~ "normalisation is a NAMED PER-PLANE EXCEPTION in this "
                ~ "reader, argued and reviewed, never a re-capture",
                  path, frozen["producedBy"].str, kL4ProducedBy));
    assert(frozen["stand"].str == kL4Stand,
           format("%s: stand is '%s', expected '%s'", path,
                  frozen["stand"].str, kL4Stand));

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
// MUTATIONS THAT REDDEN IT, both observed:
//   * delete the `preMaps_` restore from any slice `revert()` — `vertices`,
//     `faces`, every winding, `faceMaterial`, `facePart`, both set masks and
//     every mark word compare EQUAL, and only `meshMaps` differs;
//   * delete the `preSel_.restore(*mesh)` — only `faceMarks` differs.
// ---------------------------------------------------------------------------
unittest
{
    compareOrCaptureL4(l4Cells());
}

// ===========================================================================
// THE REFUSAL — `Mesh.edgeSliceEx`'s arm (iii), the TRUE no-op.
//
// Not a frozen cell, for the reason given at the roster. It gets THREE
// assertions instead of one, because `postOp == postUndo == pre` is what a
// CORRECT refusal and a NEVER-RAN cell both produce:
//
//   1. `apply()` returned FALSE;
//   2. the mesh is byte-identical to entry, on every plane;
//   3. a CONTROL on the same stand, differing only in `tB`, returns TRUE —
//      without which assertion 1 is satisfied by a command that refuses
//      everything.
//
// WHY THE OPERAND IS `tA = 0, tB = 1` AND NOT `tA = 0, tB = 0`. MEASURED over
// face 0's four edges and a 3x3 t-grid: `(edge 0, edge 2, 0, 0)` REUSES both
// corners and still SPLITS — the two reused corners land non-adjacent in the
// winding, so Pass 2 chord-splits and the command succeeds with an op-log of
// `[MeshMapDelta FaceReindex]` and no `AddVerts` at all. Only `tB = 1` puts
// the second reused corner adjacent to the first.
//
// AND THE ARM'S OWN COMMENT WAS WRONG, WHICH IS THIS BLOCK'S SECOND SUBJECT.
// `mesh.d` carried, verbatim: *"Pass 1's `addVertex` also fires
// `editRecorder_.recordAddVert` when a change-batch is open; this rollback does
// NOT un-record it. Safe today because no caller wraps `edgeSliceEx` in
// `beginEditBatch` … A future batched caller must add a matching un-record
// here."* Stage L4 IS that caller. Read under the arm's own guard the hazard is
// unreachable — the arm is entered only when `vertices.length ==
// vertsBeforePass1`, i.e. when no `addVertex` ran — and MEASURING it says the
// same: the op-log under a RECORDING batch is EMPTY. The comment was corrected
// in the same commit; this assertion is what keeps the correction honest.
// ===========================================================================
unittest
{
    import mesh_edit_delta : MeshEditDelta;
    import mesh_ops.cut    : kCutEditScope;

    // ---- 2 (taken first, so the "before" exists) --------------------------
    auto m = l4Stand();
    immutable pre = meshPlanesJson(*m);
    immutable size_t preV = m.vertices.length, preF = m.faces.length;

    // ---- 1 -----------------------------------------------------------------
    auto v = new View(0, 0, 800, 600);
    auto c = new MeshEdgeSlice(m, v, EditMode.Edges);
    setEdges(cast(Command) c, [0u, 2u]);
    setF(cast(Command) c, "tA", 0.0f);
    setF(cast(Command) c, "tB", 1.0f);
    assert(!c.apply(),
        format("mesh.edgeSlice at tA=0 tB=1 APPLIED (V %d -> %d, F %d -> %d). "
             ~ "That operand snaps both cuts to existing corners which land "
             ~ "ADJACENT in face 0's winding, so `edgeSliceEx` takes its TRUE "
             ~ "no-op arm and the command must refuse", preV,
               m.vertices.length, preF, m.faces.length));
    assert(meshPlanesJson(*m) == pre,
        "mesh.edgeSlice refused and still moved a plane — the kernel's own "
      ~ "rollback and the command's refusal disagree, which is the one thing "
      ~ "this family can express that no other member can");

    // ---- 3, the control: the SAME stand, the SAME edges, `tB` alone moved --
    auto m2 = l4Stand();
    auto c2 = new MeshEdgeSlice(m2, v, EditMode.Edges);
    setEdges(cast(Command) c2, [0u, 2u]);
    setF(cast(Command) c2, "tA", 0.0f);
    setF(cast(Command) c2, "tB", 0.0f);
    assert(c2.apply(),
        "the CONTROL refused too: `mesh.edgeSlice` on the same stand and the "
      ~ "same edges at tA=0 tB=0 must SUCCEED. Without it, the refusal above "
      ~ "is satisfied by a command that refuses everything — a broken `edges` "
      ~ "param, a stand with no such edge, a guard that fires first");
    assert(m2.faces.length == preF + 1,
        format("the control applied but split nothing (F %d -> %d)",
               preF, m2.faces.length));

    // ---- and the delta the refusal leaves behind is EMPTY, which is what
    // makes the migrated refusal safe: there is nothing to un-record, so the
    // arm needs no un-record. Driven at the KERNEL because the command's own
    // delta is private.
    auto m3 = l4Stand();
    MeshEditDelta d;
    {
        auto ed = MeshEditBatch(*m3, kCutEditScope);   // RECORDING
        cast(void) ed.edgeSliceEx(0, 2, 0.0f, 1.0f);
        d = ed.close();
    }
    assert(d.log.length == 0,
        format("`edgeSliceEx`'s TRUE no-op arm recorded %d op-log entr(ies) "
             ~ "under a RECORDING batch. The arm restores `faces` and "
             ~ "`vertices` with RAW writes and un-records nothing, so any "
             ~ "entry here is a delta describing a mutation that no longer "
             ~ "exists — `revert()` would then truncate `vertices` BELOW the "
             ~ "pre-op length on an operation the user experienced as a "
             ~ "no-op. `mesh.d`'s own comment predicted this and its guard "
             ~ "prevents it; if this fires, the guard moved and the command "
             ~ "owes the un-record after all", d.log.length));
    assert(d.revert(*m3),
        "reverting `edgeSliceEx`'s empty no-op delta answered FALSE — "
      ~ "`revert` returns true on a no-op");
}
