// undo_parity_l6_test — the FROZEN parity fixture for stage L6, the
// DUPLICATION family (`mesh.array`, `mesh.clone`, `mesh.duplicate`,
// `mesh.mirror`, `mesh.radial_array`), and the reader that makes it an oracle.
//
// WHY IT LANDS BEFORE THE FIRST SOURCE CHANGE THAT ALTERS UNDO (§6.3 rule 1).
// All five classes hold the whole-mesh `MeshSnapshot` that IS the comparison,
// and stages L6-a / -b / -c delete it. From those commits on there is no
// snapshot arm left to compare a delta against.
//
// THE FAMILY HAS NO OTHER ORACLE AT ALL. Unlike L3 there is no live parity
// gate here: none of the five overrides `isOperationInverse()`, so
// `/api/history` reports no inverse for any of them and nothing else in the
// tree compares a duplication's undo against its own pre-op state.
//
// ---------------------------------------------------------------------------
// WHAT THE §5.5 ROW CLAIMED AND WHAT IS ACTUALLY TRUE (measured 2026-08-28)
// ---------------------------------------------------------------------------
//
//   * "align / duplicate" — A MISNOMER. Not one of the four align commands is
//     in this family: `MeshLinearAlign`, `MeshRadialAlign` and
//     `MeshCenterVertices` are stage L0's and `MeshAlign` is L2's. The family
//     is duplication top to bottom, which is why this file's fixture leaf is
//     `duplicate.json` and not the row's `align_dup.json` — a leaf that spells
//     the misnomer re-imports it into every future reader.
//   * "`FaceReindex` (armed at `arrayFacesGrid`)" — WRONG TWICE, and both
//     halves were already in the tree. (i) Stage K measured that arming and
//     left it DISARMED with the numbers at the site: arming makes the revert
//     WORSE (E=45 disarmed against E=48 armed on a 3x3 grid arrayed 2x1x1).
//     (ii) `arrayFacesGrid` is not on ANY of the five commands' call paths —
//     its only production callers are `tools/alignment/array_tool.d`, i.e. the
//     interactive Array TOOL, which is stage M's. `mesh.array` calls
//     `Mesh.arrayFaces`, the 1D line kernel. So L6 arms NOTHING; what it
//     needed was a PUBLISHER, and that is `Mesh.recordBulkAppendRound`.
//   * "corner/UV: none" — FALSE. `appendFaceRaw` exists precisely to grow
//     every PolyVertex map by the appended corners, and the three welding
//     members relocate corners through `applyVertexRemap`.
//   * "needs `FaceReindex`: yes" — only through L5-a's arming of
//     `Mesh.applyVertexRemap`, which this family INHERITS and did not add.
//
// ---------------------------------------------------------------------------
// THE PROSPECTIVE DEFECT THIS STAGE HAD TO NOT SHIP
// ---------------------------------------------------------------------------
// Before `Mesh.recordBulkAppendRound`, TWO of the five reached no tracker hook
// of any kind: `duplicateSelectedFaces` has no weld and no compaction, and
// `MeshClone` pins `weld = 0` so `arrayFaces`' weld branch is unreachable from
// it. A recording batch around either closed with an op-log that was EMPTY
// over a real mutation — which `acceptRecordedEdit` REFUSES, so `apply()`
// would return false, the funnel would throw, and the user would get
// `status:error` over a mesh that really had been duplicated, with no history
// entry. That was PROSPECTIVE, not shipped (all five still held the snapshot),
// and the whole point of ordering the publisher before the migration is that
// it stays that way. Measured on this stand before the publisher: log `[]` for
// `duplicate`, `clone` and both mirror operands.
//
// ---------------------------------------------------------------------------
// WHAT IS INERT ON THIS FAMILY, SAID HERE SO A GREEN IS NOT READ AS COVERAGE
// ---------------------------------------------------------------------------
// The `Kind.RemoveVerts` payloads — the set-mask half (stage L5-b) and the
// Point-domain map-value half (L7-P3, task 2330) — are INERT on every cell in
// this file, and that is a MEASUREMENT that killed a plan prediction rather
// than an omission. §L6.2's P-L6-3 expected L6 to be the second-family witness
// for L5-b ("at least one vertex in a named selection set is welded away and
// one `edgeSetMask` entry loses an endpoint"). Measured on six operands — the
// three welding members, each on both a face-7 and a whole-visible-mesh
// operand, three mirror planes among them — `vertexSetMask` and `edgeSetMask`
// come out of the FORWARD byte-identical every time. The reason is structural
// and not a property of this stand: every weld in this family merges a CLONE
// into an ORIGINAL (`mirrorFacesPlane` enforces it outright with
// `pairsMustCrossBound`), and `compactUnreferenced` then drops only the
// APPENDED slots, which carry no set membership because they were never in a
// set. A cell asserting the loss would be a check that reddens on CORRECT
// code. The second-family witness for those payloads is stage L7-d's vertex
// chamfer (`face_reindex_arming_test.d`'s `bevelVerticesByMask` cell), where
// the consumed vertex IS an original and IS in a named set.
//
// ---------------------------------------------------------------------------
// NO MARKS PUBLISHER IS BUILT — the Select-class residue is
// `commands/mesh/selection_undo.d`'s `DenseSelectionUndo` (§0.1). Measured on
// this stand under a RECORDING batch, the armed-revert residual for ALL NINE
// probed operands is exactly seven planes and every one of them is
// Select-class: `vertexMarks`, `edgeMarks`, `faceMarks`,
// `vertexSelectionOrder`, `edgeSelectionOrder`, `faceSelectionOrder` and
// `orderCounters`. The Subpatch bit on face 1 and the Hide bit on face 5 come
// back inside `faceMarks`, which is how we know the residual is the SELECT bit
// and not "the marks word is lost" — and it is why this family needs no
// `preMarksWord_` belt, unlike `mesh.reduce`.
//
// THE FILE IS IMMUTABLE FROM STAGE L6-a ONWARD, for `undo_parity_l5_test.d`'s
// reason verbatim: once the snapshot arms are gone the only thing that can
// produce a `duplicate.json` is the delta path capturing itself.
//
//   * `postUndo` differs => the migration restores LESS. Fix the code.
//   * `postOp`   differs => the FORWARD changed. Louder, and out of scope.
//   * a legitimate normalisation => a NAMED PER-PLANE EXCEPTION here, argued
//     and reviewed. NOT a re-capture.
//
// A SEPARATE CAPTURE KEY, `VIBE3D_PARITY_CAPTURE_L6`, WRITING EXACTLY ONE
// FILE — see `tests/unit/parity_capture_key_census_test.d`.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l6_test;

import std.format : format;

import change_bus : changeBus;
import command;
import mesh;
import math    : Vec3;
import view;
import editmode;
import http_json : meshPlanesJson, PlaneDumpMeta;

import tests.unit.fixtures            : makeTaggedGridFull;
import tests.unit.undo_parity_l0_test : ParityCell, compareOrCapture,
                                        setF, setI, setV, setS;

import commands.mesh.array_        : MeshArray;
import commands.mesh.clone_        : MeshClone;
import commands.mesh.duplicate_    : MeshDuplicate;
import commands.mesh.mirror_       : MeshMirror;
import commands.mesh.radial_array_ : MeshRadialArray;

enum string kL6Family = "duplicate";
enum string kL6Stand  = "makeTaggedGridFull(3)";

/// The tree that PRODUCED the frozen dumps.
///
/// NOT A BARE SHA, for `undo_parity_l5_test.d`'s reason — but here for the
/// weaker of the two: stage L6-P1's publisher is forward-byte-identical (it
/// only writes the op-log, and `Mesh.setFaceWindings` installs the same
/// windings the raw indexed write installed), so no dump below can differ
/// because of it. The token is still compound because the tree these dumps
/// came off is NOT the branch point, and a bare SHA would say it was.
///
/// What the reviewer checks is unchanged: that the L6-P1 commit precedes the
/// freeze and that the freeze precedes L6-a/-b/-c, i.e. that no dump here was
/// produced by the delta path grading its own homework.
enum string kL6ProducedBy = "b1c98ccb+L6-P1";

// ===========================================================================
// The stand.
//
// `makeTaggedGridFull(3)` — an OPEN 3x3 grid spanning x,z in [-1,1] with a
// vertex pitch of 2/3, which is what makes every operand below a READ off the
// geometry rather than a guess. NOT a cube: a closed solid mirrored about its
// own symmetry plane has EVERY image coincident with an original, so "the weld
// merged the seam" and "the weld merged everything" become one measurement —
// the closed-solid trap in its mirror form.
//
// THE STAND IS SHARED with `undo_parity_l0/l3/l5/l7/l9/l10_test.d`. Nothing
// here changes it.
// ===========================================================================

private Mesh* l6Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

/// The grid's vertex pitch — `makeGridPlane(3)` spans [-1, 1] in three cells.
/// Every offset and mirror plane below is a multiple of it, so the coincidence
/// each weld cell needs is exact rather than within a tolerance.
private enum float kPitch = 2.0f / 3.0f;

// ===========================================================================
// The roster. EIGHT FROZEN CELLS, in FOUR weld/no-weld PAIRS plus the two
// members that have no weld at all.
//
// The pairing is the non-vacuity instrument, not decoration: a weld cell whose
// weld silently stopped firing keeps producing a perfectly good dump, and only
// a comparison against the same operand with `weld = 0` can say so. See
// `l6Cells`' bracket assertions.
//
// REFUSALS ARE NOT FROZEN. A refusing command leaves `postOp == postUndo ==
// pre`, which `compareOrCapture`'s anti-vacuity assert refuses outright, and a
// frozen pair of identical dumps is a check that cannot come out differently.
// They are asserted directly in `tests/unit/l6_duplicate_delta_test.d`, where
// the cell can say what a refusal MEANS. (Stages L5, L7, L9 and L10 all took
// this decision; this is the repeat of that argument, not a new one.)
// ===========================================================================

private enum L6Cmd { duplicate, clone, array, mirror, radial }

private struct L6CellSpec {
    string name;
    L6Cmd  which;
    /// Faces to select before running; empty leaves the stand's own selection
    /// (face 7) in place.
    size_t[] select;
    float  weld;
    Vec3   vec;      // `offset` for array/clone, `center` for mirror/radial
    int    count;
    /// The cell's own expectation about its weld, asserted by the bracket in
    /// `l6Cells` against the SAME operand run with `weld = 0`.
    bool   weldMustFire;
}

private immutable L6CellSpec[] kL6Specs = [
    // THE DISCRIMINATING PAIR, AND IT GOES FIRST. `mesh.duplicate` and
    // `mesh.clone` are the only two members whose op-log is EMPTY over a real
    // mutation with NO condition attached — the other three at least emit
    // `[MeshMapDelta, FaceReindex, RemoveVerts, Reindex]` when their weld
    // fires, so the cheapest assertion anyone writes ("the log is non-empty")
    // is green on them and says nothing. On these two it is the whole finding,
    // and the failure it guards is not a wrong undo but `status:error` over a
    // mutated document.
    L6CellSpec("mesh.duplicate",        L6Cmd.duplicate, [],  0.0f,   Vec3(0, 0, 0),      0, false),
    // `weld` is PINNED to 0 inside `MeshClone` (`clone_.d`) and is not a
    // parameter — that pin is the only thing distinguishing this command from
    // `mesh.array{count:2}`, and it is what makes this cell isolate the append
    // publisher with no weld path to credit for the restore.
    L6CellSpec("mesh.clone",            L6Cmd.clone,     [],  0.0f,   Vec3(1, 0, 0),      0, false),

    // `mesh.array` — the DETACH path (a strict subset of the faces), which is
    // the only place in the family that rewrites an EXISTING face's winding.
    // Offset = one grid pitch, so the marched copy's near column lands exactly
    // on the source column.
    L6CellSpec("mesh.array/weld",       L6Cmd.array,     [],  0.001f, Vec3(kPitch, 0, 0), 2, true),
    L6CellSpec("mesh.array/noweld",     L6Cmd.array,     [],  0.0f,   Vec3(kPitch, 0, 0), 2, false),

    // `mesh.mirror` — the plane through the operand's own EDGE column, so
    // exactly the shared column coincides. NOT through the stand's centre:
    // that is the mirror form of the closed-solid trap.
    L6CellSpec("mesh.mirror/weld",      L6Cmd.mirror,    [],  0.001f, Vec3(kPitch/2, 0, 0), 0, true),
    // …and the same command with the plane CLEAR of the mesh, where nothing
    // can coincide. Measured, not assumed: the weld is on (0.001) and simply
    // never fires, which is what makes this the no-weld half of the bracket
    // rather than a second way of spelling `weld = 0`.
    L6CellSpec("mesh.mirror/noweld",    L6Cmd.mirror,    [],  0.001f, Vec3(5, 0, 0),      0, false),

    // `mesh.radial_array` — GETS A CELL WHATEVER ITS WELD DOES (§L6.8
    // decision 6: a class silently absent from a fixture is indistinguishable
    // from a class that passes). A weld-firing operand DOES exist: four copies
    // about the grid's far corner, where each step's image shares exactly one
    // column with its predecessor. Measured: 28 verts un-welded, 26 welded.
    L6CellSpec("mesh.radialArray/weld", L6Cmd.radial,    [],  0.001f, Vec3(1, 0, 1),      4, true),
    // Three copies about a centre two grid-widths away: no image can coincide
    // with anything.
    L6CellSpec("mesh.radialArray/noweld", L6Cmd.radial,  [],  0.001f, Vec3(3, 0, 0),      3, false),
];

private struct CellRun {
    string postOp, postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
    /// The same forward with the weld disabled — the other half of the
    /// bracket. `~0` when the member has no weld to disable.
    size_t noWeldVerts;
    string preWindings, postWindings;
}

private string windingsOf(in Mesh m)
{
    import std.conv : to;
    string s;
    foreach (fi, ref f; m.faces) s ~= f.to!string ~ ";";
    return s;
}

private void arrange(in L6CellSpec s, Mesh* m)
{
    if (s.select.length == 0) return;
    m.clearFaceSelection();
    foreach (fi; s.select) m.selectFace(cast(int) fi);
}

/// Build the command for a cell. `weldOverride < 0` means "use the cell's own
/// weld"; a value >= 0 replaces it, which is how the bracket run below asks
/// the SAME operand what it does with no weld.
private Command makeCommand(in L6CellSpec s, Mesh* m, View v, float weldOverride)
{
    immutable float w = weldOverride >= 0.0f ? weldOverride : s.weld;
    final switch (s.which) {
        case L6Cmd.duplicate:
            return cast(Command) new MeshDuplicate(m, v, EditMode.Polygons);
        case L6Cmd.clone: {
            auto c = new MeshClone(m, v, EditMode.Polygons);
            setV(cast(Command) c, "offset", s.vec);
            return cast(Command) c;
        }
        case L6Cmd.array: {
            auto c = new MeshArray(m, v, EditMode.Polygons);
            setI(cast(Command) c, "count",  s.count);
            setV(cast(Command) c, "offset", s.vec);
            setF(cast(Command) c, "weld",   w);
            return cast(Command) c;
        }
        case L6Cmd.mirror: {
            auto c = new MeshMirror(m, v, EditMode.Polygons);
            setS(cast(Command) c, "axis",   "X");
            setV(cast(Command) c, "center", s.vec);
            setF(cast(Command) c, "weld",   w);
            return cast(Command) c;
        }
        case L6Cmd.radial: {
            auto c = new MeshRadialArray(m, v, EditMode.Polygons);
            setI(cast(Command) c, "count",  s.count);
            setS(cast(Command) c, "axis",   "Y");
            setV(cast(Command) c, "center", s.vec);
            setF(cast(Command) c, "weld",   w);
            return cast(Command) c;
        }
    }
}

/// Run the SAME operand with the weld disabled and report the resulting vertex
/// count — the other half of every weld cell's bracket.
private size_t noWeldVertsOf(in L6CellSpec s)
{
    if (s.which == L6Cmd.duplicate || s.which == L6Cmd.clone) return size_t.max;
    auto m = l6Stand();
    arrange(s, m);
    auto v = new View(0, 0, 800, 600);
    Command c = makeCommand(s, m, v, 0.0f);
    assert(c.apply(), s.name ~ ": the weld-disabled bracket run refused the "
                    ~ "stand, so the pair below compares against nothing");
    return m.vertices.length;
}

private CellRun l6RunOnce(in L6CellSpec s, in PlaneDumpMeta meta)
{
    auto m = l6Stand();
    arrange(s, m);

    CellRun r;
    r.preVerts    = m.vertices.length;
    r.preFaces    = m.faces.length;
    r.preWindings = windingsOf(*m);

    auto v = new View(0, 0, 800, 600);
    Command c = makeCommand(s, m, v, -1.0f);

    // THE EMPTY-DELTA COUNTER, READ AS A DELTA ACROSS THE FORWARD AND
    // ASSERTED INDEPENDENTLY OF THE STATUS. `acceptRecordedEdit` answers
    // `false` AND ticks this counter for a non-empty mutation that recorded
    // nothing, so `apply()` returning false covers BOTH the honest refusal and
    // the missing publisher — one status assertion cannot tell them apart, and
    // leaning on status alone has failed twice in this track. This is the
    // assertion that names the second one.
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    assert(changeBus.emptyDeltaOverMutation == e0, format(
        "%s: the command closed a recording batch with an EMPTY delta over a "
      ~ "real mutation (emptyDeltaOverMutation moved by %d). That is the "
      ~ "prospective defect stage L6 exists to not ship — with no publisher at "
      ~ "the appends the log is empty, `apply()` returns false and the user "
      ~ "gets status:error over a duplicated mesh", s.name,
        changeBus.emptyDeltaOverMutation - e0));
    r.postVerts    = m.vertices.length;
    r.postFaces    = m.faces.length;
    r.postWindings = windingsOf(*m);
    r.postOp       = meshPlanesJson(*m, meta);

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);

    r.noWeldVerts = noWeldVertsOf(s);
    return r;
}

ParityCell[] l6Cells()
{
    auto meta = PlaneDumpMeta(kL6ProducedBy, "snapshot", kL6Family, kL6Stand);

    ParityCell[] out_;
    CellRun[string] runs;
    foreach (ref s; kL6Specs) {
        auto r = l6RunOnce(s, meta);
        runs[s.name] = r;
        out_ ~= ParityCell(s.name, "snapshot", r.postOp, r.postUndo);
    }

    // ---- 1. every cell's forward MOVED something -------------------------
    // Every member of this family appends vertices and faces, so the channel
    // is the same for all eight and the assertion can be strict.
    foreach (ref s; kL6Specs) {
        auto r = runs[s.name];
        assert(r.postFaces > r.preFaces,
            format("%s: the op left F=%d->%d — every assertion about its undo "
                 ~ "is then satisfied by an undo that does nothing",
                   s.name, r.preFaces, r.postFaces));
        assert(r.postWindings != r.preWindings,
            s.name ~ ": the face plane did not move at all");
    }

    // ---- 2. THE WELD BRACKET --------------------------------------------
    // Stated over an OBSERVABLE CONSEQUENCE (the vertex count against the same
    // operand with the weld off), never over an intermediate: a weld cell that
    // stopped welding still produces a perfectly good dump, and no plane
    // comparison in this file can tell that from a correct one.
    foreach (ref s; kL6Specs) {
        if (s.which == L6Cmd.duplicate || s.which == L6Cmd.clone) continue;
        auto r = runs[s.name];
        if (s.weldMustFire)
            assert(r.postVerts < r.noWeldVerts,
                format("%s: the weld did NOT fire — V=%d with the weld and "
                     ~ "V=%d with it disabled, on the same operand. This cell "
                     ~ "exists to exercise `weldCoincidentVertices` + "
                     ~ "`compactUnreferenced` and stage L5-a's arming of "
                     ~ "`Mesh.applyVertexRemap`; without the weld it is a "
                     ~ "second copy of the no-weld cell and every assertion "
                     ~ "about the weld's restore is vacuous",
                       s.name, r.postVerts, r.noWeldVerts));
        else
            assert(r.postVerts == r.noWeldVerts,
                format("%s: the weld DID fire — V=%d with the weld and V=%d "
                     ~ "with it disabled. This is the no-weld half of a "
                     ~ "bracket; if it welds, the pair no longer brackets "
                     ~ "anything", s.name, r.postVerts, r.noWeldVerts));
    }

    // ---- 3. the two hook-free members are the ones with no weld path -----
    // `mesh.clone` pins `weld = 0` in its own source. If that pin were ever
    // relaxed to `mesh.array`'s default, this cell would silently start
    // measuring the WELD publisher instead of the APPEND publisher, and the
    // family would lose its only unconditional witness for the latter.
    {
        auto r = runs["mesh.clone"];
        auto m = l6Stand();
        auto v = new View(0, 0, 800, 600);
        auto c = new MeshClone(m, v, EditMode.Polygons);
        setV(cast(Command) c, "offset", Vec3(0, 0, 0));
        assert(c.apply(), "mesh.clone refused a ZERO offset");
        assert(m.vertices.length == 20, format(
            "a ZERO-offset `mesh.clone` left V=%d, expected 20 — its `weld = 0`"
          ~ " pin (commands/mesh/clone_.d) is what keeps the coincident copy "
          ~ "rather than folding it back into the original. With the pin "
          ~ "relaxed this whole cell measures the weld publisher instead of "
          ~ "the append publisher, and the family loses its only "
          ~ "UNCONDITIONAL witness for the appends", m.vertices.length));
        assert(r.postFaces == r.preFaces + 1,
            "mesh.clone appended more or fewer than one face");
    }

    // ---- 4. the per-corner UV values are DISTINCT ------------------------
    // A value restored onto the WRONG corner must fail as loudly as one that
    // vanished. `appendFaceRaw` grows this map by the appended corners, so the
    // appended corners must be distinguishable from the originals.
    {
        auto m = l6Stand();
        auto uv = m.meshMap(kUvMapName);
        assert(uv !is null && uv.domain == MapDomain.PolyVertex,
            "the stand carries no PolyVertex `" ~ kUvMapName ~ "` map — the "
          ~ "plane `appendFaceRaw` exists to protect is absent");
        bool[float] seenU;
        foreach (k; 0 .. uv.data.length / uv.dim) {
            immutable float u = uv.data[k * uv.dim];
            assert((u in seenU) is null, format(
                "uv corner %d repeats the value %s — a value restored onto the "
              ~ "wrong corner would compare EQUAL", k, u));
            seenU[u] = true;
        }
        // …and a HIDDEN face and a SUBPATCH face, because `faceMarks` is the
        // plane whose Select bit this family loses to `DenseSelectionUndo` and
        // whose OTHER bits it must keep. Without both, "faceMarks came back"
        // is satisfied by a revert that restored only the Select bit.
        assert(m.isFaceHidden(5) && m.isFaceSubpatch(1),
            "the stand hides no face or marks none subpatch — `faceMarks`'s "
          ~ "non-Select bits are then all zero and a revert that dropped them "
          ~ "would read identical");
    }

    // ---- 5. the two array cells differ, so the DETACH is really reached ---
    assert(runs["mesh.array/weld"].postOp != runs["mesh.array/noweld"].postOp,
        "the welding and non-welding array cells left the SAME post-op state "
      ~ "— the weld parameter is not reaching the kernel");

    return out_;
}

// ===========================================================================
// NO EXCEPTION TABLE — see `undo_parity_l7_test.d`'s block of the same name.
// L3's and L5's `faceSelectionOrder` normalisation arises from restoring
// through a bare `SelectionSnapshot`; `DenseSelectionUndo` copies the three
// order arrays back WHOLESALE, so there is nothing here to normalise.
// Measured: this reader compares plane-for-plane with no licence of any kind
// and is green. An EMPTY `PlaneException[]` would be worse than none —
// `assertExceptionTableWellFormed` refuses one outright, because an empty
// table makes the exception machinery dead code no mutation can score.
// ===========================================================================

// ---------------------------------------------------------------------------
// THE READER.
//
// MUTATION THAT REDDENS IT (W-6-a1): delete the `recordBulkAppendRound` call
// in `Mesh.duplicateSelectedFaces`. The op-log goes EMPTY,
// `acceptRecordedEdit` refuses it, `MeshDuplicate.apply()` returns false and
// the cell reddens on the STATUS assert above — not on the geometry, which is
// the point: a cell that only checked the geometry after a refused command
// would be asserting about a mesh nobody undid.
//
// MUTATION THAT REDDENS IT (W-6-b2): hand `Mesh.setFaceWindings` the detach
// accumulator DESCENDING in `Mesh.arrayFaces`. The door carries an always-on
// ascending assert, so this one is loud at the door rather than silent.
// ---------------------------------------------------------------------------
unittest
{
    compareOrCapture("duplicate.json", kL6Family, kL6ProducedBy, kL6Stand,
                     l6Cells(), "VIBE3D_PARITY_CAPTURE_L6");
}
