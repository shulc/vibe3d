// undo_parity_l8_test — the FROZEN parity fixture for stage L8, the
// EXTRUDE / EXTEND family, and the reader that makes it an oracle.
//
// WHY IT LANDS BEFORE THE FIRST SOURCE CHANGE THAT ALTERS UNDO (§6.3 rule 1).
// All four classes below hold the whole-mesh `MeshSnapshot` that IS the
// comparison, and stages L8-a / -b / -c delete it. From those commits on there
// is no snapshot arm left to compare a delta against.
//
// ---------------------------------------------------------------------------
// THE FAMILY IS SIX COMMANDS AND THIS FILE HOLDS FOUR — the other two are
// DECLINED, on a measurement, and the decline has its OWN witness
// ---------------------------------------------------------------------------
// `mesh.edge_extrude` and `mesh.edge_extend` keep their `MeshSnapshot`. Their
// kernels make a STATED per-corner drop at their tail
// (`dropCornerProvenance(CornerDrop.SweptSurfaceNoLaw)`, task 0830 — "an EDGE
// extrude's wall is a fresh surface and no capture measures its
// parameterisation"), and the whole-mesh snapshot puts those values back on
// Ctrl+Z while the op-log CANNOT: the replay re-declares a drop
// (`CornerDrop.DeltaReplayDeclined`) and neither kernel's log carries an entry
// whose reverse supplies the pre-op corner values. Measured, both paths, on
// this stand: the delta revert leaves all 72 UV floats ZERO, the snapshot
// revert brings back `0, 1, 2, …`. Migrating them would ship a regression.
// The measurement is pinned by `tests/unit/l8_extrude_delta_test.d`'s decline
// block, NOT here — a cell for a still-snapshot command in this file would
// compare the snapshot against itself and be green under every implementation.
//
// ---------------------------------------------------------------------------
// WHAT THE §5.5 ROW SAID — AND IT SAID NOTHING, WHICH IS THE FINDING
// ---------------------------------------------------------------------------
// L8's row is TEXTUALLY MISSING from the §5.5 table (plan §0.2): the Stage-E2
// amendment was written OVER it, so the row's own claims — kinds, `snapshot
// branch deleted`, reindex, corner/UV, fixture name — are absent from the
// document, and a line without pipes terminates a GFM table, so L9's and
// L10's rows rendered outside it. The row is restored by this stage with the
// values MEASURED here rather than reconstructed from the neighbours.
//
// ---------------------------------------------------------------------------
// WHAT THIS FAMILY DOES NOT NEED, AND IS THE FIRST IN THE TRACK NOT TO
// ---------------------------------------------------------------------------
// A PUBLISHER. Every one of the six kernels already closes a RECORDING batch
// with a NON-EMPTY op-log on this stand — measured before any source change:
//
//   extrudeEdgesByMask     [AddVerts ReshapeFaces AddFaces EdgeSelByEnds]
//   extendEdgesByMask      [AddVerts AddFaces EdgeSelByEnds]
//   extrudeFacesByMask     [AddVerts MeshMapDelta FaceReindex]   (both arms)
//   extrudeVerticesByMask  [AddVerts SetPos MeshMapDelta FaceReindex]
//   extrudeAlongPath       [AddVerts MeshMapDelta FaceReindex] per span
//
// so the empty-delta refusal that stages L6 and L7 had to order around
// (publisher first, freeze second, migrate third) cannot fire here. The
// assertion is kept anyway, in `l8RunOnce` below, because it is the thing that
// would go wrong if a later edit moved a `rewriteFaces` out from under its
// `faceReindexScope()`.
//
// ---------------------------------------------------------------------------
// NO MARKS PUBLISHER IS BUILT — the Select-class residue is
// `commands/mesh/selection_undo.d`'s `DenseSelectionUndo` (§0.1). Measured on
// this stand under a RECORDING batch, the armed-revert residual, reported BOTH
// WAYS, is Select-class and nothing else:
//
//   extrudeFacesByMask (both arms)  edgeMarks faceMarks faceSelectionOrder
//                                   orderCounters vertexMarks
//                                   vertexSelectionOrder
//   extrudeVerticesByMask           edgeMarks faceMarks
//   extrudeAlongPath                the same six as extrudeFacesByMask
//
// `map:uv`, `map:W`, `faceMaterial`, `facePart`, both set masks, the vertex
// positions, the windings and all three counts come back BYTE-IDENTICAL — and
// the Subpatch bit on face 1 and the Hide bit on face 5 come back INSIDE
// `faceMarks`, which is how we know the residual is the SELECT bit and not
// "the marks word is lost". That is why no `preMarksWord_` belt is carried.
//
// ---------------------------------------------------------------------------
// WHAT IS INERT ON WHICH CELL, SAID HERE SO A GREEN IS NOT READ AS COVERAGE
// ---------------------------------------------------------------------------
// The `DenseSelectionUndo` is load-bearing on THREE of the seven cells and
// INERT on the other four — measured, by mutation, not reasoned. Swapping it
// for a bare `SelectionSnapshot` reddens `mesh.strokeExtrude/1span` on
// `faceSelectionOrder` (frozen `[0,0,11,0,0,0,23,1,0]`, bare snapshot
// `[0,0,0,0,0,0,0,1,0]`) and does the same on the `mesh.vertexExtrude/ring`
// cell; the SAME swap on `smooth_shift.d` leaves this whole file GREEN.
//
// The reason is the cells' own arrangement and it is worth knowing before
// adding an eighth: `SelectionSnapshot.restore`'s tail re-zeroes the stamp of
// every element that is NOT selected, and `MeshSnapshot` copied the arrays
// whole — so the two differ only where the pre-op mesh carries a STAMPED,
// UNSELECTED element. The stand has two (faces 2 and 6, ranks 11 and 23), and
// the four face cells DESTROY them before the command runs, because selecting
// the island or clearing the selection re-mints the array. The three cells
// that leave the stand's own selection alone are the ones that can see it.
//
// So the census (`tests/unit/l8_command_undo_census_test.d`) is what covers
// the other four, by NAME rather than by consequence, and its message says so.
//
// THE FILE IS IMMUTABLE FROM STAGE L8-a ONWARD, for `undo_parity_l5_test.d`'s
// reason verbatim: once the snapshot arms are gone the only thing that can
// produce an `extrude_extend.json` is the delta path capturing itself.
//
//   * `postUndo` differs => the migration restores LESS. Fix the code.
//   * `postOp`   differs => the FORWARD changed. Louder, and out of scope.
//   * a legitimate normalisation => a NAMED PER-PLANE EXCEPTION here, argued
//     and reviewed. NOT a re-capture.
//
// A SEPARATE CAPTURE KEY, `VIBE3D_PARITY_CAPTURE_L8`, WRITING EXACTLY ONE
// FILE — see `tests/unit/parity_capture_key_census_test.d`.
//
// LANE: `dub test --config=tests` (lane U) — `./run_test.d` never runs a
// `tests/unit/**` unittest block.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l8_test;

import std.format : format;

import change_bus : changeBus;
import command;
import mesh;
import math    : Vec3;
import view;
import editmode;
import http_json : meshPlanesJson, PlaneDumpMeta;

import tests.unit.fixtures            : makeTaggedGridBent;
import tests.unit.undo_parity_l0_test : ParityCell, compareOrCapture,
                                        setF, setV;

import commands.mesh.face_extrude   : MeshFaceExtrude;
import commands.mesh.smooth_shift   : MeshSmoothShift;
import commands.mesh.stroke_extrude : MeshStrokeExtrude;
import commands.mesh.vertex_extrude : MeshVertexExtrude;

enum string kL8Family = "extrude_extend";
enum string kL8Stand  = "makeTaggedGridBent(3)";

/// The tree that PRODUCED the frozen dumps.
///
/// NOT A BARE SHA, for `undo_parity_l5_test.d`'s reason — and here for the
/// STRONGEST form of it: this stage builds no publisher and arms nothing, so
/// the tree these dumps came off is the branch point with only THIS FILE and
/// its siblings added. What the reviewer checks is that the freeze precedes
/// L8-a/-b/-c, i.e. that no dump here was produced by the delta path grading
/// its own homework.
enum string kL8ProducedBy = "2c2b89e8+L8-0";

// ===========================================================================
// The stand.
//
// `makeTaggedGridBent(3)` — `makeTaggedGridFull(3)` (an OPEN 3x3 grid, face 7
// selected, face 5 hidden, face 1 subpatch, a distinct-valued PolyVertex UV
// map and a Point-domain weight map) plus TWO INTERIOR VERTICES MOVED OFF THE
// PLANE.
//
// THE BENT STAND IS A FINDING, NOT A PREFERENCE, AND THE FIXTURE'S OWN
// BRACKET IS WHAT FOUND IT. `makeTaggedGridFull(3)` is FLAT, so every face
// normal is the same vector; `extrudeFacesByMask`'s SMOOTH branch averages
// the unit normals of the selected incident faces, and on a flat sheet that
// average IS `regionNormal` — the value the RIGID branch uses. The two arms
// are then BYTE-IDENTICAL, on a one-face operand and on a nine-face one
// alike. The first version of this file used the flat stand and item 2 of
// `l8Cells` reddened on the first capture run, before anything was frozen:
// `poly.extrude` and `mesh.smooth_shift` had left the same post-op state.
// Freezing that would have frozen ONE arm twice and called it two. This is
// памятка 28's shape (a flat grid cannot discriminate `smooth` from a rigid
// extrude) caught by a bracket rather than shipped, and it is the second
// time this stage's own instruments have caught it — stage L6's CTL5 needed
// a cube CORNER for the same reason.
//
// NOT a cube either: this family's face and vertex arms both rewrite the
// whole face array through `mesh_planes.rewriteFaces`, and on a closed solid
// "the rewrite carried the corners" and "the corners happened to be zero" are
// one measurement.
//
// THE STAND IS SHARED with `undo_parity_l2_test.d`, which took it for its own
// two reasons (a reversed winding and a non-planar face). Nothing here
// changes it.
// ===========================================================================

private Mesh* l8Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridBent(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

private enum L8Cmd { faceExtrude, smoothShift, vertexExtrude, strokeExtrude }

private struct L8CellSpec {
    string name;
    L8Cmd  which;
    /// When true the face selection is CLEARED first, so `operandFaceMask()`
    /// falls back to the whole visible mesh — a rewrite of every face rather
    /// than of one face's neighbourhood.
    bool   wholeMesh;
    /// Faces to select before running; empty leaves the stand's own selection
    /// (face 7) in place. Ignored when `wholeMesh`.
    immutable(size_t)[] select;
    float  amount;      // `distance` / `shift` / vertex-extrude `shift`
    float  width;       // vertex extrude only
    /// Path for the stroke; empty for the other three.
    immutable(Vec3)[] path;
}

private enum immutable(Vec3)[] kPath1 = [Vec3(0, 0, 0), Vec3(0, 0.5f, 0)];
private enum immutable(Vec3)[] kPath3 = [Vec3(0, 0, 0), Vec3(0, 0.4f, 0),
                                   Vec3(0.2f, 0.8f, 0), Vec3(0.5f, 1.0f, 0.2f)];

/// The two-face operand the SMOOTH arm needs.
///
/// MEASURED, and it killed the obvious cell. On a SINGLE selected face
/// `extrudeFacesByMask`'s smooth branch and its rigid branch produce a
/// BYTE-IDENTICAL result: the smooth arm's ring term is a function of the
/// selected island's boundary, and a one-face island has no interior edge for
/// it to act on. The first version of this file selected face 7 for both arms
/// and the bracket in `l8Cells` (item 2) reddened on the very first capture
/// run — which is what that bracket is for. Faces 4 and 7 are VERTICALLY
/// ADJACENT on the 3x3 grid, so the island has one shared interior edge and
/// the two arms diverge.
private enum immutable(size_t)[] kIsland = [4, 7];

private immutable L8CellSpec[] kL8Specs = [
    // THE TWO ARMS OF ONE KERNEL, AND THEY GO FIRST. `poly.extrude` and
    // `mesh.smooth_shift` both call `extrudeFacesByMask`; the ONLY difference
    // is its third argument (`smooth`). Freezing one of them and not the other
    // would leave the smooth arm's ring term — the one law in this family with
    // a captured reference (`math.d`'s note on the smooth branch, scored 8/8
    // over the frozen orbit corpus) — with no oracle at all. The pair is
    // bracketed in `l8Cells` below: their post-op dumps MUST differ, or the
    // flag is not reaching the kernel and one cell is a duplicate of the other.
    L8CellSpec("poly.extrude/island",       L8Cmd.faceExtrude,   false, kIsland, 0.5f,  0.0f, null),
    L8CellSpec("mesh.smooth_shift/island",  L8Cmd.smoothShift,   false, kIsland, 0.5f,  0.0f, null),

    // …and the same two over the WHOLE VISIBLE MESH, which is a different
    // shape and not a bigger one: with two faces selected the rewrite re-emits
    // seven untouched faces by identity, and with none selected it re-emits
    // none. `faceReindexScope()`'s payload covers every old face either way,
    // so this is the cell that would catch a carry that only works when most
    // faces are unchanged.
    L8CellSpec("poly.extrude/wholeMesh",      L8Cmd.faceExtrude, true,  null, 0.5f,  0.0f, null),
    L8CellSpec("mesh.smooth_shift/wholeMesh", L8Cmd.smoothShift, true,  null, 0.4f,  0.0f, null),

    // `mesh.vertexExtrude` — the `Kind.SetPos` member. Its op-log is the only
    // one in the family with FOUR kinds ([AddVerts, SetPos, MeshMapDelta,
    // FaceReindex]); the `SetPos` is Stage H's §5.7 migration of the raw apex
    // write and its reverse is the only thing that restores the apex position.
    // `width` MUST be non-zero: `width == 0` is a documented no-op (the class
    // doc comment) and the command REFUSES, which `compareOrCapture`'s
    // anti-vacuity assert would catch — but as "postOp == postUndo", i.e. as
    // the wrong diagnosis.
    L8CellSpec("mesh.vertexExtrude/ring",   L8Cmd.vertexExtrude, false, null, 0.5f,  0.25f, null),

    // `mesh.strokeExtrude` — ONE span and THREE spans, and the pair is not
    // redundant. `extrudeAlongPath` runs `extrudePathStep_` once per span and
    // each step opens its OWN `faceReindexScope()`, so a 3-span log is three
    // `[AddVerts, MeshMapDelta, FaceReindex]` GROUPS whose `AddVerts` entries
    // deliberately no longer coalesce (Stage K's note: a `FaceReindex` now
    // sits between consecutive appends). A one-span cell cannot see a reverse
    // that replays the groups in the wrong ORDER.
    L8CellSpec("mesh.strokeExtrude/1span",  L8Cmd.strokeExtrude, false, null, 0.0f,  0.0f, kPath1),
    L8CellSpec("mesh.strokeExtrude/3span",  L8Cmd.strokeExtrude, false, null, 0.0f,  0.0f, kPath3),
];

private struct CellRun {
    string postOp, postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
    string preWindings, postWindings;
}

private string windingsOf(in Mesh m)
{
    import std.conv : to;
    string s;
    foreach (fi, ref f; m.faces) s ~= f.to!string ~ ";";
    return s;
}

private void arrange(in L8CellSpec s, Mesh* m)
{
    if (s.wholeMesh) { m.clearFaceSelection(); return; }
    if (s.select.length == 0) return;
    m.clearFaceSelection();
    foreach (fi; s.select) m.selectFace(cast(int) fi);
}

private Command makeCommand(in L8CellSpec s, Mesh* m, View v)
{
    final switch (s.which) {
        case L8Cmd.faceExtrude: {
            auto c = new MeshFaceExtrude(m, v, EditMode.Polygons);
            setF(cast(Command) c, "distance", s.amount);
            return cast(Command) c;
        }
        case L8Cmd.smoothShift: {
            auto c = new MeshSmoothShift(m, v, EditMode.Polygons);
            setF(cast(Command) c, "shift", s.amount);
            return cast(Command) c;
        }
        case L8Cmd.vertexExtrude: {
            auto c = new MeshVertexExtrude(m, v, EditMode.Vertices);
            setF(cast(Command) c, "shift", s.amount);
            setF(cast(Command) c, "width", s.width);
            return cast(Command) c;
        }
        case L8Cmd.strokeExtrude: {
            auto c = new MeshStrokeExtrude(m, v, EditMode.Polygons);
            foreach (ref p; c.params())
                if (p.name == "path") { *p.v3aPtr = s.path.dup; break; }
            return cast(Command) c;
        }
    }
}

private CellRun l8RunOnce(in L8CellSpec s, in PlaneDumpMeta meta)
{
    auto m = l8Stand();
    arrange(s, m);

    CellRun r;
    r.preVerts    = m.vertices.length;
    r.preFaces    = m.faces.length;
    r.preWindings = windingsOf(*m);

    auto v = new View(0, 0, 800, 600);
    Command c = makeCommand(s, m, v);

    // THE EMPTY-DELTA COUNTER, READ AS A DELTA ACROSS THE FORWARD AND
    // ASSERTED INDEPENDENTLY OF THE STATUS. `acceptRecordedEdit` answers
    // `false` AND ticks this counter for a real mutation that recorded
    // nothing, so `apply()` returning false covers BOTH the honest refusal and
    // a missing publisher — one status assertion cannot tell them apart.
    //
    // THIS FAMILY NEEDS NO PUBLISHER (see the header), so on a correct tree
    // this counter cannot move here in EITHER direction — before the migration
    // the batch is unrecorded and nothing is offered to `acceptRecordedEdit`
    // at all, after it every kernel's log is non-empty. It is asserted because
    // that is exactly what a later edit moving a `rewriteFaces` out from under
    // its `faceReindexScope()` would break, and it would break it silently.
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    assert(changeBus.emptyDeltaOverMutation == e0, format(
        "%s: the command closed a RECORDING batch with an EMPTY delta over a "
      ~ "real mutation (emptyDeltaOverMutation moved by %d). Every kernel in "
      ~ "this family was measured to publish before stage L8 began, so this "
      ~ "means an arming or a record was removed, not that a publisher is "
      ~ "missing", s.name, changeBus.emptyDeltaOverMutation - e0));

    r.postVerts    = m.vertices.length;
    r.postFaces    = m.faces.length;
    r.postWindings = windingsOf(*m);
    r.postOp       = meshPlanesJson(*m, meta);

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);
    return r;
}

ParityCell[] l8Cells()
{
    auto meta = PlaneDumpMeta(kL8ProducedBy, "snapshot", kL8Family, kL8Stand);

    ParityCell[] out_;
    CellRun[string] runs;
    foreach (ref s; kL8Specs) {
        auto r = l8RunOnce(s, meta);
        runs[s.name] = r;
        out_ ~= ParityCell(s.name, "snapshot", r.postOp, r.postUndo);
    }

    // ---- 1. every cell's forward MOVED something -------------------------
    // Every member of this family appends vertices AND faces, so the channel
    // is the same for all seven and the assertion can be strict.
    foreach (ref s; kL8Specs) {
        auto r = runs[s.name];
        assert(r.postFaces > r.preFaces && r.postVerts > r.preVerts,
            format("%s: the op left V=%d->%d F=%d->%d — every assertion about "
                 ~ "its undo is then satisfied by an undo that does nothing",
                   s.name, r.preVerts, r.postVerts, r.preFaces, r.postFaces));
        assert(r.postWindings != r.preWindings,
            s.name ~ ": the face plane did not move at all");
    }

    // ---- 2. THE SMOOTH FLAG REACHES THE KERNEL ---------------------------
    // Stated over an observable consequence of the two commands on the SAME
    // operand, never over an intermediate. `MeshFaceExtrude` and
    // `MeshSmoothShift` differ by one boolean argument to one kernel; if that
    // argument stopped reaching it, both cells would still produce perfectly
    // good dumps and this file would be freezing one arm twice.
    assert(runs["poly.extrude/island"].postOp
        != runs["mesh.smooth_shift/island"].postOp,
        "poly.extrude and mesh.smooth_shift left the SAME post-op state on the "
      ~ "same operand — the `smooth` argument is not reaching "
      ~ "`extrudeFacesByMask`, and one of these two cells is a duplicate of "
      ~ "the other rather than the second arm it is written to be");
    assert(runs["poly.extrude/wholeMesh"].postOp
        != runs["mesh.smooth_shift/wholeMesh"].postOp,
        "the same, on the whole-mesh operand");

    // ---- 3. the whole-mesh operand really is a DIFFERENT operand ---------
    assert(runs["poly.extrude/wholeMesh"].postFaces
         > runs["poly.extrude/island"].postFaces,
        format("the whole-mesh extrude produced F=%d against the single-face "
             ~ "cell's F=%d — `operandFaceMask()` did not fall back to the "
             ~ "visible mesh and the two cells are one cell",
               runs["poly.extrude/wholeMesh"].postFaces,
               runs["poly.extrude/island"].postFaces));

    // ---- 4. the 3-span stroke really ran three spans ---------------------
    // `extrudeAlongPath` clamps and can silently take fewer spans than the
    // path has points. A one-span and a three-span cell that produced the same
    // vertex count would mean the pair brackets nothing.
    assert(runs["mesh.strokeExtrude/3span"].postVerts
         > runs["mesh.strokeExtrude/1span"].postVerts,
        format("the 3-span stroke left V=%d against the 1-span cell's V=%d — "
             ~ "the extra spans did not run, so nothing here exercises the "
             ~ "per-span `faceReindexScope()` groups or the order their "
             ~ "reverses must replay in",
               runs["mesh.strokeExtrude/3span"].postVerts,
               runs["mesh.strokeExtrude/1span"].postVerts));

    // ---- 5. the planes this family must NOT lose are NON-TRIVIAL ---------
    // A value restored onto the WRONG corner must fail as loudly as one that
    // vanished, and "faceMarks came back" must not be satisfied by a revert
    // that restored only the Select bit.
    {
        auto m = l8Stand();
        auto uv = m.meshMap(kUvMapName);
        assert(uv !is null && uv.domain == MapDomain.PolyVertex,
            "the stand carries no PolyVertex `" ~ kUvMapName ~ "` map — the "
          ~ "plane Stage J's `[MeshMapDelta, FaceReindex]` pair exists to "
          ~ "restore is absent, and every cell here is blind to it");
        bool[float] seenU;
        foreach (k; 0 .. uv.data.length / uv.dim) {
            immutable float u = uv.data[k * uv.dim];
            assert((u in seenU) is null, format(
                "uv corner %d repeats the value %s — a value restored onto the "
              ~ "wrong corner would compare EQUAL", k, u));
            seenU[u] = true;
        }
        assert(m.isFaceHidden(5) && m.isFaceSubpatch(1),
            "the stand hides no face or marks none subpatch — `faceMarks`'s "
          ~ "non-Select bits are then all zero and a revert that dropped them "
          ~ "would read identical to one that kept them");
    }

    return out_;
}

// ===========================================================================
// NO EXCEPTION TABLE — see `undo_parity_l6_test.d`'s block of the same name.
// All four migrated commands hold a `DenseSelectionUndo`, whose `restore` puts
// the three order arrays back WHOLESALE, so they agree with the frozen
// snapshot oracle and there is nothing to normalise. Measured: this reader
// compares plane-for-plane with no licence of any kind and is green. An EMPTY
// `PlaneException[]` would be worse than none — `assertExceptionTableWellFormed`
// refuses one outright, because an empty table makes the exception machinery
// dead code no mutation can score.
// ===========================================================================

// ---------------------------------------------------------------------------
// THE READER.
//
// MUTATION THAT REDDENS IT (W-8-a1): delete `preSel_.restore(*mesh)` from
// `MeshFaceExtrude.revert`. The geometry still round-trips — the op-log does
// that — and only the Select-class planes come back wrong, which is precisely
// the half a geometry-only check cannot see.
//
// MUTATION THAT REDDENS IT (W-8-c1): remove the `faceReindexScope()` around
// `extrudePathStep_`'s `rewriteFaces` call. The stroke cells' `revert()` goes
// back to THROWING out of `buildLoops`.
// ---------------------------------------------------------------------------
unittest
{
    compareOrCapture("extrude_extend.json", kL8Family, kL8ProducedBy, kL8Stand,
                     l8Cells(), "VIBE3D_PARITY_CAPTURE_L8");
}
