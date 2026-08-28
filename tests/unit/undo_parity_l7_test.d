// undo_parity_l7_test — the FROZEN parity fixture for the FACE HALF of stage
// L7 (`mesh.poly_inset` and `mesh.bevel`, both arms), and the reader that
// makes it an oracle.
//
// WHY IT LANDS BEFORE THE FIRST SOURCE CHANGE THAT ALTERS UNDO (§6.3 rule 1).
// `MeshPolygonInset` and `MeshBevel` hold the `MeshSnapshot` that IS the
// comparison, and stages L7-a / -b / -c delete it. From those commits on there
// is no snapshot arm left to compare a delta against.
//
// ---------------------------------------------------------------------------
// WHAT THE ROW CLAIMED AND WHAT IS ACTUALLY TRUE (measured 2026-08-28)
// ---------------------------------------------------------------------------
// §5.5's L7 row and its note are wrong in four places, and the corrections are
// what this stage is:
//
//   * "`FaceReindex` armed at `bevelEdgesByMask` x2, `bevelVerticesByMask`" —
//     WITHDRAWN. The armed set is NINE kernels and NOT ONE is in this family
//     (`face_reindex_arming_test.d`'s `kArmedSites`), and this stage does not
//     change that: the edge arm's arming is REFUSED, with three measured
//     candidates, at `commands/mesh/bevel.d`'s class doc comment.
//   * "`poly_inset` … clear (append-only)" — FALSE. The family owns FIVE
//     hook-free indexed installs, not three: `insetFacesByMask`'s ring,
//     `bevelFacesByMask`'s cap AND its square splice into an UNSELECTED
//     neighbour, and `bevel_fin`'s two spine rewrites. Stage L7-P2 routes all
//     five through `Mesh.setFaceWindings`.
//   * "corner/UV: none" — FALSE for three of the four kernels.
//   * "flipping this family off the snapshot regresses UV undo unless
//     0830/0901 closes first" (`bevel_vertex_test.d:276`-`:281`) — STALE. That
//     text is E4-era, written before Stages J and K, and describes a tree that
//     no longer exists. It was NOT inherited here; the measurement was redone.
//
// The pre-L7 baseline, measured at the kernel under a RECORDING batch on this
// stand: the inset's op-log was `[AddVerts, AddFaces]` per processed face with
// NO face entry at all, and `revert()` THREW
// (`index [16] is out of bounds for array of length 16`). The polygon bevel
// threw the same way. After L7-P2 both round-trip with an EMPTY residual.
//
// THE EDGE ARM IS NOT IN THIS FILE AND THAT IS DELIBERATE. Its log was
// `[AddVerts, RemoveVerts, Reindex]` and it threw at `index [17]`; its arming
// is REFUSED for three measured reasons (see `commands/mesh/bevel.d`), so it
// keeps its `MeshSnapshot`. A cell for a path that REMAINS the snapshot would
// freeze a snapshot oracle against the snapshot — a check that cannot come out
// differently. The refusal is asserted directly instead, in
// `tests/unit/l7_bevel_inset_delta_test.d`, where it can say what a refusal
// MEANS (no op-log entry, `opInverse` false, and an undo that still works).
//
// ---------------------------------------------------------------------------
// NO MARKS PUBLISHER IS BUILT — the Select-class residue is
// `commands/mesh/selection_undo.d`'s `DenseSelectionUndo`, which stage L2-c
// already shipped. `Kind.SelectionDelta` cannot carry the plane: its restore
// re-selects through `Mesh.selectEdge`, which mints a FRESH order stamp off
// the counter, and no delta kind carries a selection-order stamp at all
// (`l1_declined_census_test.d` asserts the second half). A publisher would be
// a second, lossy writer over a plane the dense image already owns.
//
// ---------------------------------------------------------------------------
// THE FILE IS IMMUTABLE FROM STAGE L7-a ONWARD, for `undo_parity_l5_test.d`'s
// reason verbatim: once the snapshot arms are gone the only thing that can
// produce a `bevel.json` is the delta path capturing itself.
//
//   * `postUndo` differs => the migration restores LESS. Fix the code.
//   * `postOp`   differs => the FORWARD changed. Louder, and out of scope.
//   * a legitimate normalisation => a NAMED PER-PLANE EXCEPTION here, argued
//     and reviewed. NOT a re-capture.
//
// A SEPARATE CAPTURE KEY, `VIBE3D_PARITY_CAPTURE_L7`, WRITING EXACTLY ONE
// FILE — see `tests/unit/parity_capture_key_census_test.d`, which asserts the
// `leaf <-> key` map is 1:1 over every reader. A shared key is why an earlier
// capture run silently re-froze two older fixtures.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l7_test;

import std.format : format;
import std.json   : JSONValue, parseJSON;

import command;
import mesh;
import view;
import editmode;
import http_json : meshPlanesJson, PlaneDumpMeta;

import tests.unit.fixtures            : makeTaggedGridFull;
import tests.unit.undo_parity_l0_test : ParityCell, comparePlanes, fixturePath,
                                        fixtureJson, setF, setI, setB;

import commands.mesh.poly_inset : MeshPolygonInset;
import commands.mesh.bevel      : MeshBevel;

enum string kL7Family = "bevel";
enum string kL7Stand  = "makeTaggedGridFull(3)";

/// The tree that PRODUCED the frozen dumps.
///
/// NOT A BARE SHA, for `undo_parity_l5_test.d`'s reason: stage L7-P2 changes
/// the FORWARD of one kernel — `bevelFinBundleSpineMultiEdge` now declares its
/// corner provenance, so its per-corner values CARRY where the whole map used
/// to be dropped — so the branch point alone would name a tree whose dumps can
/// differ. None of THIS file's five cells reaches that kernel (a manifold grid
/// has no fin bundle), but the token names the tree honestly rather than
/// relying on that.
///
/// What the reviewer checks is unchanged: that the L7-P2 commit precedes the
/// freeze and that the freeze precedes L7-a/-b, i.e. that no dump here was
/// produced by the delta path grading its own homework.
enum string kL7ProducedBy = "d1cfe53b+L7-P2";

// ===========================================================================
// The stand.
//
// `makeTaggedGridFull(3)` — an OPEN 3x3 grid, and NOT a cube. A closed solid
// has no boundary rim, so the edge bevel's rim arm is unreachable on one and
// the cell would be green over an operand that never ran.
//
// WHAT THIS STAND CANNOT EXHIBIT, said here rather than discovered later: a
// FIN BUNDLE needs an edge shared by three or more faces, which a manifold
// grid does not have, so `bevel_fin`'s two kernels are UNREACHABLE from every
// cell in this file. They are covered at the kernel instead (their own
// round-trip cells), and this reader's edge-bevel cell states in its own
// message that the fin arm is not what it measures.
// ===========================================================================

private Mesh* l7Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

/// Face 7's three neighbours in the grid; used by the stand's own assert that
/// an UNSELECTED face sharing an original edge with it exists at all.
private enum size_t[] kNeighboursOf7 = [4, 6, 8];

unittest // the stand can exhibit everything the roster claims to measure
{
    auto m = l7Stand();

    assert(m.faces.length == 9 && m.vertices.length == 16,
        format("the stand is V=%d F=%d, expected V=16 F=9 — every index "
             ~ "constant in this file names a face at random otherwise",
               m.vertices.length, m.faces.length));

    // ---- 1. per-corner UV values are DISTINCT. A value restored onto the
    // WRONG corner must fail as loudly as one that vanished.
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

    // ---- 2. exactly one face selected, and it has UNSELECTED neighbours.
    // The square splice writes a face NOBODY SELECTED, so a check keyed on
    // the selection cannot see its restore — that is the whole point of the
    // `mesh.bevel/polySquare` cell, and it needs such a neighbour to exist.
    assert(m.isFaceSelected(7),
        "the stand's selected face is not 7 — every cell's operand mask is "
      ~ "derived from the selection");
    foreach (nb; kNeighboursOf7)
        assert(!m.isFaceSelected(nb), format(
            "face %d is selected; the square splice needs an UNSELECTED "
          ~ "neighbour sharing an original edge with face 7, or its cell "
          ~ "degenerates into the selected-face case", nb));

    // ---- 3. faceSelectionOrder is not a function of the Select plane.
    assert(m.faceSelectionOrder[2] != 0 && m.faceSelectionOrder[6] != 0,
        "the stand's faceSelectionOrder is flat outside the selected face — a "
      ~ "revert that drops the order plane would read identical");

    // ---- 4. a HIDDEN face, because every kernel here runs its mask through
    // `maskMinusHiddenFaces` and a stand with none cannot tell that backstop
    // from its absence.
    assert(m.isFaceHidden(5),
        "the stand hides no face — `maskMinusHiddenFaces` is then a no-op on "
      ~ "every cell and the whole-mesh operand path is untested");

    // ---- 5. an interior MANIFOLD edge and a RIM edge both exist, for the
    // edge-bevel cell's two operands.
    size_t interior = 0, rim = 0;
    foreach (ei; 0 .. m.edges.length) {
        size_t inc = 0;
        foreach (ref f; m.faces)
            foreach (k; 0 .. f.length) {
                immutable uint a = f[k], b = f[(k + 1) % f.length];
                if ((a == m.edges[ei][0] && b == m.edges[ei][1])
                 || (a == m.edges[ei][1] && b == m.edges[ei][0])) ++inc;
            }
        if (inc == 2) ++interior;
        if (inc == 1) ++rim;
    }
    assert(interior > 0 && rim > 0, format(
        "the stand has %d interior and %d rim edge(s); the edge-bevel cells "
      ~ "need both — a chamfer span exists only across a manifold edge, and "
      ~ "the rim arm is a different code path", interior, rim));

    // ---- 6. is per cell (V/F/E moved, and for the square cell an UNSELECTED
    // face's winding moved) — see `l7Cells`.
}

// ===========================================================================
// The roster.
//
// FIVE FROZEN CELLS, all of them on the two MIGRATED paths. The refusals — and
// the edge arm's DECLINE — are asserted directly at the bottom of this
// file and in `tests/unit/l7_bevel_inset_delta_test.d` rather than frozen: a
// refusing command leaves `postOp == postUndo == pre`, which the anti-vacuity
// assert refuses, and a frozen pair of identical dumps is a check that cannot
// come out differently. (Stage L5 took the same decision; this is the repeat
// of that argument.)
//
// `mesh.vertexBevel` HAS NO CELL HERE. It is stage L7-d — the VERTEX half —
// and it is blocked on the Point-domain map-value payload (L7-P3) that
// `removeVertsReverse` still zeroes. A cell for a class that is not migrating
// would freeze a snapshot oracle for a path that REMAINS the snapshot, which
// is a check that cannot come out differently.
// ===========================================================================

/// No `bevelEdge`: the edge arm keeps its `MeshSnapshot` (see the header) and
/// has no cell here. A tag for it would be an invitation to add one.
private enum L7Cmd { inset, bevelPoly }

private struct L7CellSpec {
    string name;
    L7Cmd  which;
    /// Which faces (or edges) the cell selects before running. Empty selects
    /// nothing extra and leaves the stand's own selection in place.
    size_t[] select;
    bool     group;
    bool     square;
}

private immutable L7CellSpec[] kL7Specs = [
    // THE DISCRIMINATING CELL, AND IT GOES FIRST. `mesh.poly_inset` is the
    // only member whose op-log contained NO face entry at all before L7-P2,
    // and it reaches no `compactUnreferenced`, so its log has no
    // `[RemoveVerts, Reindex]` tail and nothing else can be credited for the
    // restore. It is also the only place where an unordered `setFaceWindings`
    // accumulator is SILENT: on this path it leaves V/F/E, every mark word,
    // `faceMaterial`, `facePart` and both set masks BYTE-IDENTICAL and only
    // the windings wrong. In the bevel groups the same defect lands beside a
    // `[RemoveVerts, Reindex]` pair and surfaces as a dangling index or a
    // throw — loud, and therefore attributed to something else.
    L7CellSpec("mesh.poly_inset/one",   L7Cmd.inset,     [7],                    false, false),
    // ALL NINE faces selected and EIGHT processed — face 5 is HIDDEN, and
    // selecting it is what exercises `maskMinusHiddenFaces`, the §3.3 backstop.
    L7CellSpec("mesh.poly_inset/many",  L7Cmd.inset,     [0,1,2,3,4,5,6,7,8],    false, false),
    L7CellSpec("mesh.bevel/polyOne",    L7Cmd.bevelPoly, [7],                    false, false),
    // The GROUP path plus the SQUARE splice — the cell that writes a face
    // NOBODY SELECTED.
    L7CellSpec("mesh.bevel/polySquare", L7Cmd.bevelPoly, [4, 7],                 true,  true),
    // A SECOND polygon-bevel operand, so the family's own cells cannot all be
    // one face: grouped over four faces, which is the path that reaches
    // `compactUnreferenced` and therefore the one the `preMaps_` belt is for.
    L7CellSpec("mesh.bevel/polyGroup",  L7Cmd.bevelPoly, [0, 1, 3, 4],           true,  false),
];

private struct CellRun {
    string postOp, postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
    string preWindings, postWindings;
    string preUnselWindings, postUnselWindings;
}

private string windingsOf(in Mesh m)
{
    import std.conv : to;
    string s;
    foreach (fi, ref f; m.faces) s ~= f.to!string ~ ";";
    return s;
}

/// The ARITIES of every pre-op face, as text — the channel the square splice
/// moves on a face NOBODY SELECTED.
///
/// ARITY AND NOT WINDING, AND THAT IS MEASURED. The `group` path ends in
/// `compactUnreferenced`, which renumbers every vertex, so EVERY winding
/// differs after a grouped forward whether or not the splice ran: a
/// winding-keyed non-vacuity assert here is satisfied by a splice that never
/// happened. Arity is reindex-invariant, and the splice is the only thing in
/// this kernel that changes an UNMASKED face's corner count.
private string unselectedArityOf(in Mesh m)
{
    import std.conv : to;
    string s;
    foreach (fi; 0 .. 9)
        if (fi < m.faces.length) s ~= m.faces[fi].length.to!string ~ ";";
    return s;
}

private void arrange(in L7CellSpec s, Mesh* m)
{
    if (s.select.length == 0) return;
    m.clearFaceSelection();
    foreach (fi; s.select) m.selectFace(cast(int) fi);
}

private Command makeCommand(in L7CellSpec s, Mesh* m, View v)
{
    final switch (s.which) {
        case L7Cmd.inset:
            auto c = new MeshPolygonInset(m, v, EditMode.Polygons);
            setF(cast(Command) c, "inset", 0.1f);
            return cast(Command) c;
        case L7Cmd.bevelPoly:
            auto c = new MeshBevel(m, v, EditMode.Polygons);
            setF(cast(Command) c, "inset",  0.1f);
            setF(cast(Command) c, "shift",  0.05f);
            setB(cast(Command) c, "group",  s.group);
            setB(cast(Command) c, "square", s.square);
            return cast(Command) c;
    }
}

private CellRun l7RunOnce(in L7CellSpec s, in PlaneDumpMeta meta)
{
    auto m = l7Stand();
    arrange(s, m);

    CellRun r;
    r.preVerts         = m.vertices.length;
    r.preFaces         = m.faces.length;
    r.preWindings      = windingsOf(*m);
    r.preUnselWindings = unselectedArityOf(*m);

    auto v = new View(0, 0, 800, 600);
    Command c = makeCommand(s, m, v);

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    r.postVerts         = m.vertices.length;
    r.postFaces         = m.faces.length;
    r.postWindings      = windingsOf(*m);
    r.postUnselWindings = unselectedArityOf(*m);
    r.postOp            = meshPlanesJson(*m, meta);

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);

    return r;
}

ParityCell[] l7Cells()
{
    auto meta = PlaneDumpMeta(kL7ProducedBy, "snapshot", kL7Family, kL7Stand);

    ParityCell[] out_;
    CellRun[string] runs;
    foreach (ref s; kL7Specs) {
        auto r = l7RunOnce(s, meta);
        runs[s.name] = r;
        out_ ~= ParityCell(s.name, "snapshot", r.postOp, r.postUndo);
    }

    // Non-vacuity per cell: the op MOVED something. Every member of this
    // family appends vertices and faces, so the channel is the same for all
    // five and the assertion can be strict.
    foreach (ref s; kL7Specs) {
        auto r = runs[s.name];
        assert(r.postVerts > r.preVerts && r.postFaces > r.preFaces,
            format("%s: the op left V=%d->%d F=%d->%d — every assertion about "
                 ~ "its undo is then satisfied by an undo that does nothing",
                   s.name, r.preVerts, r.postVerts, r.preFaces, r.postFaces));
        assert(r.postWindings != r.preWindings,
            s.name ~ ": no winding moved. This family's whole undo debt is a "
          ~ "WINDING publisher, so a cell whose forward installs no winding "
          ~ "measures nothing it was written for");
    }

    // THE SQUARE-SPLICE CHANNEL. `bevelFacesByMask`'s third install writes an
    // UNSELECTED neighbour, so a check keyed on the selection cannot see its
    // restore. Assert the forward actually reaches it, or the cell is a
    // duplicate of `polyOne` with different parameters.
    {
        auto r = runs["mesh.bevel/polySquare"];
        assert(r.postUnselWindings != r.preUnselWindings, format(
            "mesh.bevel/polySquare changed no UNMASKED face's arity (%s). The "
          ~ "square splice is the only thing in this kernel that can, and "
          ~ "without it this cell measures the same install `polyOne` already "
          ~ "does", r.preUnselWindings));
    }
    // …and the PLAIN cell must NOT reach it, or the two cells are one cell
    // written twice and "the splice's restore" is not attributed to the
    // splice.
    {
        auto r = runs["mesh.bevel/polyOne"];
        assert(r.postUnselWindings == r.preUnselWindings, format(
            "mesh.bevel/polyOne changed an UNMASKED face's arity (%s -> %s). "
          ~ "Without `square`, no splice runs; if one did, the square cell "
          ~ "above is no longer the attribution cell for it",
            r.preUnselWindings, r.postUnselWindings));
    }

    // The two inset cells must differ, or `operandFaceMask` is not reaching
    // the kernel and the eight-face cell is the one-face cell again.
    assert(runs["mesh.poly_inset/one"].postOp
        != runs["mesh.poly_inset/many"].postOp,
        "the one-face and eight-face inset cells left the SAME post-op state "
      ~ "— the selection is not reaching `operandFaceMask`, so the BULK "
      ~ "winding call (one entry for the whole set) is never exercised");
    // …and the many-face cell must be the one that exercises the bulk path.
    assert(runs["mesh.poly_inset/many"].postFaces
         > runs["mesh.poly_inset/one"].postFaces,
        "the eight-face inset produced no more faces than the one-face inset");

    return out_;
}

// ===========================================================================
// NO EXCEPTION TABLE — see `undo_parity_l9_test.d`'s block of the same name
// for the full argument. In short: L3's and L5's `faceSelectionOrder`
// normalisation arises from restoring through a bare `SelectionSnapshot`, and
// `DenseSelectionUndo` copies the three order arrays back WHOLESALE after
// that tail, so there is nothing here to normalise. Measured: this reader
// compares plane-for-plane through `comparePlanes` with no licence of any
// kind and is green. An empty `PlaneException[]` would be worse than none —
// `assertExceptionTableWellFormed` refuses one outright, because an empty
// table makes the exception machinery dead code no mutation can score.
// ===========================================================================

private void compareOrCaptureL7(ParityCell[] cells)
{
    import std.file    : exists, readText, write, mkdirRecurse;
    import std.path    : dirName;
    import std.process : environment;

    assert(cells.length == kL7Specs.length && cells.length == 5,
        format("the recipe produced %d cells, the roster declares %d and the "
             ~ "migrated face half owes 5 — the EDGE arm is declined and has "
             ~ "no cell here on purpose", cells.length, kL7Specs.length));
    foreach (ref c; cells)
        assert(c.postOp != c.postUndo,
               kL7Family ~ ": cell '" ~ c.name ~ "' has postOp == postUndo, so "
             ~ "its forward moved no plane this dump can see. Every assertion "
             ~ "about its undo is then satisfied by an undo that does nothing.");

    immutable path = fixturePath("bevel.json");

    if (environment.get("VIBE3D_PARITY_CAPTURE_L7", "") == "1") {
        mkdirRecurse(dirName(path));
        write(path, fixtureJson(kL7Family, kL7ProducedBy, kL7Stand, cells));
        return;
    }

    assert(exists(path),
           "missing parity fixture " ~ path ~ " — it must be frozen BEFORE the "
         ~ "`MeshSnapshot` arms are deleted from commands/mesh/poly_inset.d "
         ~ "and commands/mesh/bevel.d; re-capturing on a tree that no longer "
         ~ "HAS them would be the delta path grading its own homework");

    auto frozen = parseJSON(readText(path));

    assert(frozen["producedBy"].str == kL7ProducedBy,
           format("%s: producedBy is '%s', expected '%s'. This fixture is "
                ~ "IMMUTABLE from stage L7-a onward — a legitimate "
                ~ "normalisation is a NAMED PER-PLANE EXCEPTION in this "
                ~ "reader, argued and reviewed, never a re-capture",
                  path, frozen["producedBy"].str, kL7ProducedBy));
    assert(frozen["stand"].str == kL7Stand,
           format("%s: stand is '%s', expected '%s'", path,
                  frozen["stand"].str, kL7Stand));

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
// MUTATION THAT REDDENS IT: hand `insetFacesByMask`'s accumulator to
// `setFaceWindings` UNSORTED. `setFaceWindings` declines SILENTLY — V/F/E,
// every mark word, `faceMaterial`, `facePart` and both set masks compare
// EQUAL and only the `faces` plane differs, on the `mesh.poly_inset/*` cells.
// A count-only or geometry-only cell is green under it.
// ---------------------------------------------------------------------------
unittest
{
    compareOrCaptureL7(l7Cells());
}
