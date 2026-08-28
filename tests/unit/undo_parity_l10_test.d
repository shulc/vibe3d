// undo_parity_l10_test — the FROZEN parity fixture for stage L10's family
// (the topo-misc, REINDEXING half: thirteen commands whose kernels re-lay the
// vertex and/or face index space), and the reader that makes it an oracle.
//
// WHY IT LANDS BEFORE THE FIRST MIGRATION COMMIT, §6.3 rule 1 plus one ground
// specific to this family: nine of the thirteen commands hold the
// `MeshSnapshot` that IS the comparison, and the migration deletes it. From
// those commits on there is no snapshot arm to compare a delta against, so the
// comparison has to be captured while the arm still exists.
//
// THE THREE THINGS A COUNT CANNOT SEE HERE, which is why every cell is a
// per-plane dump and not a set of numbers:
//
//   * a weld's face rewrite restores its windings REMAPPED — V, F and every
//     mark word round-trip while `faces` names post-weld vertices. That was
//     live on this funnel until stage L10 armed
//     `Mesh.applyVertexRemapAndRebuild`;
//   * an edge-set membership that MERGED onto a survivor is off the restored
//     edge and on the survivor after undo, with EVERY count and every other
//     plane equal and exactly two AA entries different (task 2310);
//   * a re-inserted vertex's Point-domain map VALUE comes back zeroed while
//     the map LENGTH is right (task 2330).
//
// THE TWO DUMPS ARE NOT DECORATION — inherited verbatim from
// `undo_parity_l0_test`'s header. A fixture holding only the post-undo state
// is green for a cell whose FORWARD silently stopped doing anything, and green
// for a cell whose op and undo are both broken in the same direction.
//
// ---------------------------------------------------------------------------
// A SEPARATE CAPTURE KEY, `VIBE3D_PARITY_CAPTURE_L10`, AND IT MAY WRITE
// EXACTLY ONE FILE. `environment` is process-wide and druntime runs every
// unittest module in ONE process, so a shared key silently re-freezes every
// other family's oracle in the same run — which happened, and is why
// `compareOrCapture` takes the key as a parameter and
// `tests/unit/parity_capture_key_census_test.d` asserts the
// reader ↔ key ↔ leaf maps are 1:1. The check that it worked is
// `git status tests/fixtures/undo_parity/` after a capture: exactly one file.
//
// ---------------------------------------------------------------------------
// THE FILE IS IMMUTABLE FROM THE FIRST MIGRATION COMMIT ONWARD. Re-freezing
// presupposes a producer, and once the snapshot arms are gone the only thing
// that can produce a `weld_merge.json` is the delta path capturing itself —
// the migration grading its own homework, indistinguishable from a correct
// freeze. So:
//
//   * `postUndo` differs  ⇒ the migration restores LESS. Fix the code.
//   * `postOp`   differs  ⇒ the FORWARD changed. Louder, and out of scope.
//   * a legitimate normalisation ⇒ a NAMED PER-PLANE EXCEPTION in this reader,
//     reviewed, with its reason at the exception. NOT a new `producedBy`.
//
// L3's `faceSelectionOrder` finding is inherited as a WARNING and not as an
// expectation, exactly as L5 inherited it: if the plane diverges here it takes
// the SAME argument, not a new one — and as a PIN, never a skip.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l10_test;

import std.format : format;
import std.json   : JSONValue, parseJSON;

import command;
import mesh;
import view;
import editmode;
import math      : Vec3;
import http_json : meshPlanesJson, PlaneDumpMeta;
import change_bus : MeshEditScope;

import tests.unit.fixtures            : makeTaggedGridWeldSets;
import tests.unit.undo_parity_l0_test : ParityCell, fixturePath, compareOrCapture,
                                        setF, setB, setI, PlaneException,
                                        assertExceptionTableWellFormed;
import tests.unit.undo_parity_l3_test : checkOrderNormalisation;

import commands.mesh.collapse         : MeshCollapse;
import commands.mesh.vert_join        : MeshVertJoin;
import commands.mesh.vert_merge       : MeshVertMerge;
import commands.mesh.weld_vertex_pair : MeshWeldVertexPair;
import commands.mesh.edge_join        : MeshEdgeJoin;
import commands.mesh.merge            : MeshMergeFaces;
import commands.mesh.triple           : MeshTriple;
import commands.mesh.quadruple        : MeshQuadruple;
import commands.mesh.detriangulate    : MeshDetriangulate;
import commands.mesh.unify            : MeshUnify;
import commands.mesh.reduce           : MeshReduce;

enum string kL10Family = "weld_merge";
enum string kL10Stand  = "makeTaggedGridWeldSets(3)";
enum string kL10Leaf   = "weld_merge.json";

/// The tree that PRODUCED the frozen dumps.
///
/// NOT A BARE SHA, for the reason L5's `kL5ProducedBy` records: the freezing
/// commit is preceded, in this same lane, by a change that alters the FORWARD
/// of every command that welds — stage L10's arming of
/// `Mesh.applyVertexRemapAndRebuild`'s `rewriteFaces`. That arm changes what
/// the op-log contains, not what the forward mesh looks like, so in principle
/// the post-op dumps are identical either way; the token nevertheless names it,
/// because a reviewer's question is "could this file have been produced by the
/// path it grades?" and the honest answer needs the whole recipe, not a commit
/// that happens to precede it.
///
/// What the reviewer checks: that L10-P2 (the arm) and L10-P0 (the axis-0
/// batches) precede this freeze, and that this freeze precedes every migration
/// commit. The reader below asserts the field still says this, which is what
/// makes a quiet re-capture loud.
enum string kL10ProducedBy = "3e68adcb+L10-P0+L10-P2";

// ===========================================================================
// The stand, and the non-vacuity it owes BEFORE any cell runs.
//
// The stand's own injections are asserted in `tests/unit/fixtures.d`, beside
// the function that builds them. What is asserted HERE is what THIS FILE's
// cells read.
//
// NOTE THE ONE ASSERTION THAT IS *NOT* MADE, and why: not `orphans > 0`, and
// not any count of what the weld leaves dangling. L5's review measured that to
// be ZERO on a stand that carries an orphan, because the kernels compact
// inside themselves — so an `orphans >= 1` assertion REDDENS ON CORRECT CODE,
// which is the same disease as a vacuous check seen from the other side. The
// weld's firing is asserted through its OBSERVABLE CONSEQUENCE instead: a
// vertex-count drop, per cell, in `runOnce`.
// ===========================================================================

private Mesh* l10Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridWeldSets(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

/// `makeTaggedGridDirty`'s three appended vertices, derived rather than
/// hard-coded so a change to the parent stand moves these together.
private uint vCoinOf(in Mesh m) { return cast(uint) m.vertices.length - 3; }
private uint vColOf (in Mesh m) { return cast(uint) m.vertices.length - 2; }

unittest // the stand can exhibit everything the roster claims to measure
{
    import mesh_selsets : selSetMembersVertex, selSetMembersEdge;

    auto m = l10Stand();
    immutable vCoin = vCoinOf(*m);

    assert(m.faces.length == 12 && m.vertices.length == 19,
        format("the stand is V=%d F=%d, expected V=19 F=12 — every index "
             ~ "constant in this file names a face or a vertex at random",
               m.vertices.length, m.faces.length));

    // ---- 1. THE WELD MUST FIRE. Asserted as a coincidence, which is the
    // property the kernels key on, and not as a count of what it leaves —
    // see the note above.
    assert(m.vertices[vCoin] == m.vertices[1],
        format("the stand's vertex %d is not coincident with vertex 1, so "
             ~ "`weldVerticesByMask` welds NOTHING and every weld cell below "
             ~ "records a refusal", vCoin));

    // ---- 2. THE MERGE-CASE EDGE, both halves of its pre-op image. This is
    // the ONE plane no earlier stand can exhibit and the reason this stand
    // exists; without it the whole family's cells cover the DROP and RENUMBER
    // halves of the edge-set payload and silently not the MERGE half.
    auto em = selSetMembersEdge(*m, "M");
    bool sawMergeEdge = false, sawSurvivor = false;
    foreach (pr; em) {
        if ((pr[0] == 0 && pr[1] == vCoin) || (pr[0] == vCoin && pr[1] == 0))
            sawMergeEdge = true;
        if ((pr[0] == 0 && pr[1] == 1) || (pr[0] == 1 && pr[1] == 0))
            sawSurvivor = true;
    }
    assert(sawMergeEdge,
        format("edge set \"M\" is %s and does not name the edge (0,%d) whose "
             ~ "key MERGES onto (0,1) when vertex %d welds into 1 — the merge "
             ~ "half of the payload is then unreachable and its cells are "
             ~ "vacuous", em, vCoin, vCoin));
    assert(!sawSurvivor,
        format("edge set \"M\" ALREADY names the survivor edge (0,1) before "
             ~ "the weld, so the SPURIOUS-GAIN half of the loss is invisible: "
             ~ "an undo that leaves membership on (0,1) would compare EQUAL to "
             ~ "the pre-op image. %s", em));

    // ---- 3. a vertex IN A NAMED SET that the weld consumes.
    auto vm = selSetMembersVertex(*m, "V");
    bool sawWeldedMember = false;
    foreach (vi; vm) if (vi == vCoin) sawWeldedMember = true;
    assert(sawWeldedMember,
        format("vertex set \"V\" is %s and does not name vertex %d, the one "
             ~ "the weld consumes — `vertSetMaskBefore` then has nothing to "
             ~ "restore on this stand", vm, vCoin));

    // ---- 4. a live PolyVertex map whose per-corner values are DISTINCT. A
    // value restored onto the WRONG corner must fail as loudly as one that
    // vanished.
    auto uv = m.meshMap(kUvMapName);
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

    // ---- 5. a live POINT-domain map, likewise distinct: this is the plane
    // task 2330's payload restores, and the second family that witnesses it.
    auto wm = m.meshMap("W");
    assert(wm !is null && wm.domain == MapDomain.Point && wm.dim > 0,
        "the stand carries no Point-domain `W` map — the plane a re-inserted "
      ~ "vertex used to come back ZEROED on is absent, and this family is its "
      ~ "second witness");
    assert(wm.data[vCoin * wm.dim] != 0.0f,
        format("the Point map's value at the CONSUMED vertex %d is already 0, "
             ~ "so a revert that zeroes it compares EQUAL and the payload's "
             ~ "witness here is vacuous", vCoin));

    // ---- 6. is per cell: every cell asserts its op actually moved something.
    // See `runOnce`.
}

// ===========================================================================
// The roster.
//
// TWELVE CELLS on ELEVEN of the thirteen classes. What is here, what is not,
// and why — stated rather than left to a reader counting rows:
//
//   * `mesh.collapse` gets THREE cells, one per mode (vertex / edge /
//     polygon). They are three different kernels behind one class, and §6.2's
//     "MeshCollapse x3" was a miscount of CLASSES that is a correct count of
//     BEHAVIOURS.
//   * `mesh.bridge` and `mesh.sweep` have NO cell, and that is a measured
//     absence rather than an omission: both need an operand this stand cannot
//     present (two bridgeable loops / a profile plus a path), and a cell built
//     on a second stand would be measuring that stand, not this family's
//     shared weld. They keep their own kernel-level oracles
//     (`tests/unit/mesh_ops/bridge_test.d`, `revolve_test.d`) and their
//     command halves are named in the card as NOT covered by this fixture.
//   * The REFUSAL cells the plan asked for are deliberately NOT frozen. A
//     refusing command leaves `postOp == postUndo`, which is the exact shape
//     `compareOrCapture`'s anti-vacuity assert refuses; freezing a pair of
//     identical dumps is a check that cannot come out differently. The
//     refusals are asserted directly at the bottom of this file, where they
//     can say what a refusal MEANS.
// ===========================================================================

/// What a cell does to the stand before the command runs.
private alias Arrange = void function(Mesh*);

private enum L10Cmd {
    collapseV, collapseE, collapseP,
    vertJoin, vertMerge, weldPair, edgeJoin,
    mergeFaces, triple, quadruple, detriangulate, unify, reduce
}

private struct L10CellSpec {
    string   name;
    L10Cmd   which;
    Arrange  arrange;
    EditMode mode;
}

// --- arrangements ----------------------------------------------------------
//
// Each one selects the operand the command needs and asserts it got it. An
// arrangement that silently selects nothing turns its cell into a frozen
// refusal, which is the failure this whole file exists to refuse.

/// The two coincident vertices, and NOTHING else — so `vert.merge`'s cluster
/// is exactly the weld this stage is about.
private void arrCoincidentPair(Mesh* m)
{
    m.clearVertexSelection();
    m.selectVertex(1);
    m.selectVertex(cast(int) vCoinOf(*m));
    size_t n;
    foreach (vi; 0 .. m.vertices.length) if (m.isVertexSelected(vi)) ++n;
    assert(n == 2,
        format("arrCoincidentPair selected %d vertices, expected 2 — "
             ~ "vert.merge refuses on fewer and this cell freezes a "
             ~ "refusal", n));
}

/// Three vertices of one interior quad — `collapse` (vertex mode) and
/// `vert.join` both need at least two, and three makes the centroid differ
/// from every input position so a restore onto the wrong vertex is visible.
private void arrThreeVerts(Mesh* m)
{
    m.clearVertexSelection();
    m.selectVertex(5);
    m.selectVertex(6);
    m.selectVertex(9);
    size_t n;
    foreach (vi; 0 .. m.vertices.length) if (m.isVertexSelected(vi)) ++n;
    assert(n == 3, format("arrThreeVerts selected %d vertices, expected 3", n));
}

/// One interior edge.
private void arrOneEdge(Mesh* m)
{
    m.clearEdgeSelection();
    immutable ei = m.edgeIndex(5, 6);
    assert(ei != cast(uint)~0u, "arrOneEdge: edge (5,6) is not in the stand");
    m.selectEdge(ei);
}

/// The degenerate face's two edges, which share the 2-VALENT vertex `vCol` —
/// the only shape `mesh.edgeJoin` accepts, and it exists on this stand only
/// because `makeTaggedGridDirty` appended the collinear triangle `[0,1,vCol]`.
private void arrTwoEdgesAtValent2(Mesh* m)
{
    m.clearEdgeSelection();
    immutable vCol = vColOf(*m);
    immutable a = m.edgeIndex(0, vCol);
    immutable b = m.edgeIndex(1, vCol);
    assert(a != cast(uint)~0u && b != cast(uint)~0u,
        "arrTwoEdgesAtValent2: the collinear triangle's two edges are not in "
      ~ "the stand — mesh.edgeJoin then refuses on the degree guard");
    m.selectEdge(a);
    m.selectEdge(b);
}

/// Two ADJACENT interior quads — `mesh.mergeFaces` dissolves nothing on a
/// disjoint pair and would freeze a refusal.
private void arrTwoAdjacentFaces(Mesh* m)
{
    m.clearFaceSelection();
    m.selectFace(0);
    m.selectFace(1);
}

/// One interior quad.
private void arrOneFace(Mesh* m)
{
    m.clearFaceSelection();
    m.selectFace(4);
}

/// `mesh.detriangulate` needs a PAIR of triangles sharing an edge, and
/// `mesh.quadruple` needs an operand that is NOT already a quad. The stand is
/// a quad sheet with one lone triangle, so both arrangements triangulate it
/// first — OUTSIDE the command under test, so each cell measures its own
/// command and not a triple followed by it.
///
/// MEASURED, AND IT IS WHY NEITHER CELL USES `arrOneFace`. `quadruple` is not
/// a splitter — it MERGES adjacent coplanar TRIANGLE pairs into quads through
/// `removeEdgesByMask`, so on a quad sheet its accept predicate matches
/// nothing. Run on face 4 of the bare stand it USED TO answer `apply() == true`
/// and leave every winding and every count exactly as it found them.
///
/// THAT WAS A HISTORY ENTRY OVER A NO-OP, which the project's command contract
/// forbids (`evaluate` false ⇒ `apply` false ⇒ no entry). `MeshQuadruple`,
/// `MeshTriple` and `MeshDetriangulate` all returned true unconditionally
/// after their kernel, and all three kernels return a COUNT they discarded.
/// Stage L10-c/-d FIXED it, and the fix was forced rather than chosen: the
/// post-close ruling is `acceptRecordedEdit`, and a fabricated non-zero
/// `affected` over an empty delta ticks `changeBus.emptyDeltaOverMutation`,
/// which both gate lanes assert stays 0. So the count is read and the three
/// refuse honestly.
///
/// THE ARRANGEMENT IS UNCHANGED BY THAT, and deliberately: it triangulates
/// first because these two cells must measure their OWN command against the
/// frozen dumps, not a refusal. The dumps themselves are untouched — the
/// forward on THIS operand always did work.
private void arrTriangulated(Mesh* m)
{
    immutable preF = m.faces.length;
    uint[] origin;
    {
        auto ed = MeshEditBatch.unrecorded(*m,
                      MeshEditScope.Geometry | MeshEditScope.Marks);
        ed.triangulateFacesByMask(m.visibleFaceMask(), &origin);
        ed.close();
    }
    assert(m.faces.length > preF,
        format("arrTriangulated did not add faces (%d -> %d) — the "
             ~ "detriangulate cell then has no adjacent triangle pair and "
             ~ "freezes a refusal", preF, m.faces.length));
    m.clearFaceSelection();
}



/// `mesh.unify` drops faces with a DUPLICATE vertex set, and the stand has no
/// duplicate pair until the weld makes one: `[0,vCoin,5,4]` becomes
/// `[0,1,5,4]`, which is face 0. So the arrangement welds FIRST, outside the
/// command under test.
private void arrWelded(Mesh* m)
{
    immutable vCoin = vCoinOf(*m);
    auto mask = new bool[](m.vertices.length);
    mask[1] = true;
    mask[vCoin] = true;
    size_t welded;
    {
        auto ed = MeshEditBatch.unrecorded(*m,
                      MeshEditScope.Geometry | MeshEditScope.Marks);
        welded = ed.weldVerticesByMask(mask, 1e-9);
        ed.close();
    }
    assert(welded == 1,
        format("arrWelded welded %d vertex/vertices, expected 1 — mesh.unify "
             ~ "then has no duplicate face pair and freezes a refusal",
               welded));
    m.clearFaceSelection();
}

private void arrNothing(Mesh* m) { }

private immutable L10CellSpec[] kL10Specs = [
    // THE DISCRIMINATING CELL, AND IT IS FIRST. `vert.merge` is the only
    // member whose entire op-log comes from the weld — `weldVerticesByMask`
    // and nothing else — so a defect in the twin's arming or in the edge-set
    // merge record cannot be attributed to another kernel here. Everywhere
    // else the same failure arrives mixed with a collapse or a face drop and
    // reads as that.
    L10CellSpec("vert.merge",             L10Cmd.vertMerge,     &arrCoincidentPair, EditMode.Vertices),
    L10CellSpec("mesh.collapse/vertex",   L10Cmd.collapseV,     &arrThreeVerts,     EditMode.Vertices),
    L10CellSpec("mesh.collapse/edge",     L10Cmd.collapseE,     &arrOneEdge,        EditMode.Edges),
    L10CellSpec("mesh.collapse/polygon",  L10Cmd.collapseP,     &arrOneFace,        EditMode.Polygons),
    L10CellSpec("vert.join",              L10Cmd.vertJoin,      &arrThreeVerts,     EditMode.Vertices),
    L10CellSpec("mesh.weldVertexPair",    L10Cmd.weldPair,      &arrNothing,        EditMode.Vertices),
    L10CellSpec("mesh.edgeJoin",          L10Cmd.edgeJoin,      &arrTwoEdgesAtValent2, EditMode.Edges),
    L10CellSpec("mesh.mergeFaces",        L10Cmd.mergeFaces,    &arrTwoAdjacentFaces, EditMode.Polygons),
    L10CellSpec("mesh.triple",            L10Cmd.triple,        &arrOneFace,        EditMode.Polygons),
    L10CellSpec("mesh.quadruple",         L10Cmd.quadruple,     &arrTriangulated,   EditMode.Polygons),
    L10CellSpec("mesh.detriangulate",     L10Cmd.detriangulate, &arrTriangulated,   EditMode.Polygons),
    L10CellSpec("mesh.unify",             L10Cmd.unify,         &arrWelded,         EditMode.Polygons),
    L10CellSpec("mesh.reduce",            L10Cmd.reduce,        &arrNothing,        EditMode.Polygons),
];

/// The `onTopologyChange` callback four of these classes take. A MODULE-level
/// delegate, not a nested `void nop() { }` in `makeCommand`: a delegate to a
/// nested function carries a pointer to the enclosing frame, and `makeCommand`
/// has returned by the time `apply()` calls it. The body is empty either way,
/// so it would not have crashed — which is exactly why it needed saying.
private __gshared void delegate() kNopTopology;
shared static this() { kNopTopology = () { }; }

/// Which undo mechanism the cell's class uses TODAY. The fixture records it
/// per cell so a migration that lands without moving this string is visible:
/// the frozen dumps were produced on `"snapshot"` for every cell, and a cell
/// that now says `"delta"` is asserting that the two agree plane for plane.
private string pathOf(L10Cmd w)
{
    final switch (w) {
        case L10Cmd.vertMerge: case L10Cmd.weldPair:
        case L10Cmd.collapseV: case L10Cmd.collapseE: case L10Cmd.collapseP:
        case L10Cmd.vertJoin:  case L10Cmd.edgeJoin:
        case L10Cmd.triple:    case L10Cmd.unify:
        case L10Cmd.mergeFaces: case L10Cmd.quadruple:
        case L10Cmd.detriangulate: case L10Cmd.reduce:
            return "delta";
    }
}

private Command makeCommand(in L10CellSpec s, Mesh* m, View v)
{
    final switch (s.which) {
        case L10Cmd.collapseV: case L10Cmd.collapseE: case L10Cmd.collapseP:
            return cast(Command) new MeshCollapse(m, v, s.mode);
        case L10Cmd.vertJoin:
            return cast(Command) new MeshVertJoin(m, v, s.mode);
        case L10Cmd.vertMerge:
            return cast(Command) new MeshVertMerge(m, v, s.mode);
        case L10Cmd.weldPair: {
            auto c = new MeshWeldVertexPair(m, v, s.mode);
            // The consumed vertex is the COINCIDENT one, so this cell drives
            // the same funnel `vert.merge` does through a different door
            // (`weldVertexPairs`, not `weldVerticesByMask`) — which is the
            // point of having both.
            setI(cast(Command) c, "source", cast(int) vCoinOf(*m));
            setI(cast(Command) c, "target", 1);
            return cast(Command) c;
        }
        case L10Cmd.edgeJoin:
            return cast(Command) new MeshEdgeJoin(m, v, s.mode);
        case L10Cmd.mergeFaces:
            return cast(Command) new MeshMergeFaces(m, v, s.mode, kNopTopology);
        case L10Cmd.triple:
            return cast(Command) new MeshTriple(m, v, s.mode, kNopTopology);
        case L10Cmd.quadruple:
            return cast(Command) new MeshQuadruple(m, v, s.mode, kNopTopology);
        case L10Cmd.detriangulate:
            return cast(Command) new MeshDetriangulate(m, v, s.mode, kNopTopology);
        case L10Cmd.unify:
            return cast(Command) new MeshUnify(m, v, s.mode);
        case L10Cmd.reduce: {
            auto c = new MeshReduce(m, v, s.mode);
            setF(cast(Command) c, "ratio", 0.5f);
            // `preserveBoundary` OFF, and it is not a taste: this stand is an
            // OPEN sheet, so every one of its edges is a boundary edge and the
            // default-on guard refuses every collapse — `reduceToTarget`
            // returns 0 and the command refuses. Measured on this stand.
            setB(cast(Command) c, "preserveBoundary", false);
            return cast(Command) c;
        }
    }
}

/// What one run of one cell produced.
private struct CellRun {
    string postOp;
    string postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
    /// The whole face array rendered, before and after. Some members of this
    /// family move NO count — a weld merges corners inside existing windings
    /// and drops a face only when one falls below three distinct corners — so
    /// a count-only non-vacuity assert would redden on CORRECT code for them.
    /// The windings are the channel that works for every member.
    string preWindings, postWindings;
    /// How many vertices sit at the stand's COINCIDENT position, before and
    /// after. This is the channel that tells a WELD from the stand's orphan
    /// compaction: every kernel here compacts, so a vertex-count drop of one
    /// is what a CORRECT non-welding member does too.
    size_t preCoin, postCoin;
}

/// Vertices at `p`. The stand plants exactly two.
private size_t coincidentCount(in Mesh m, Vec3 p)
{
    size_t n;
    foreach (ref v; m.vertices) if (v == p) ++n;
    return n;
}

private string windingsOf(in Mesh m)
{
    import std.conv : to;
    string s;
    foreach (ref f; m.faces) s ~= f.to!string ~ ";";
    return s;
}

/// `stand → arrange → op → undo`, dumping after the op and again after the
/// undo. `apply()` and `revert()` are asserted, not merely called: a command
/// that refuses on the stand freezes a pair of identical dumps, which is a
/// green fixture recording nothing.
private CellRun runOnce(in L10CellSpec s, in PlaneDumpMeta meta)
{
    auto m = l10Stand();
    s.arrange(m);

    CellRun r;
    r.preVerts    = m.vertices.length;
    r.preFaces    = m.faces.length;
    r.preWindings = windingsOf(*m);
    immutable Vec3 coinPos = m.vertices[1];
    r.preCoin = coincidentCount(*m, coinPos);

    auto v = new View(0, 0, 800, 600);
    Command c = makeCommand(s, m, v);

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    r.postVerts    = m.vertices.length;
    r.postFaces    = m.faces.length;
    r.postWindings = windingsOf(*m);
    r.postCoin     = coincidentCount(*m, coinPos);
    r.postOp       = meshPlanesJson(*m, meta);

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);

    return r;
}

/// Every L10 cell, in a fixed order, plus the cross-cell asserts no single
/// cell can make.
ParityCell[] l10Cells()
{
    auto meta = PlaneDumpMeta(kL10ProducedBy, "snapshot", kL10Family, kL10Stand);

    ParityCell[] out_;
    CellRun[string] runs;
    foreach (ref s; kL10Specs) {
        auto r = runOnce(s, meta);
        runs[s.name] = r;
        out_ ~= ParityCell(s.name, pathOf(s.which), r.postOp, r.postUndo);
    }

    // Non-vacuity, per cell, on the channel that WORKS for that cell.
    //
    // THE WINDINGS ARE THE UNIVERSAL ONE and the counts are not: a weld that
    // merges two corners inside a quad leaves V, F and E untouched. So every
    // cell owes a winding change, and only the cells that genuinely drop
    // something owe a count change.
    foreach (ref s; kL10Specs) {
        auto r = runs[s.name];
        assert(r.postWindings != r.preWindings,
            format("%s: the op left every winding where it found it. Its "
                 ~ "`apply()` answered true, so this is not a refusal — it is "
                 ~ "a forward that moved nothing this dump can attribute, and "
                 ~ "every assertion about its undo is then satisfied by an "
                 ~ "undo that does nothing", s.name));
    }

    // THE COINCIDENT PAIR IS THE CHANNEL, NOT THE VERTEX COUNT, and that is a
    // MEASUREMENT rather than a preference. Every kernel in this family ends
    // in `compactUnreferenced`, and the stand carries a floating ORPHAN, so a
    // vertex-count drop of ONE is what a CORRECT NON-welding member does:
    // `mesh.triple` measured 19 -> 18 with no weld anywhere near it. An
    // assertion of the shape "a non-welding cell consumes no vertex" therefore
    // REDDENS ON CORRECT CODE — the same disease as a vacuous check, from the
    // other side, and it is the assertion L5's review was caught by.
    //
    // What DOES discriminate is how many vertices remain at the stand's
    // planted coincident POSITION: two before, one after, if and only if the
    // weld consumed one of them.
    foreach (nm; ["vert.merge", "mesh.weldVertexPair", "mesh.reduce"]) {
        auto r = runs[nm];
        assert(r.preCoin == 2 && r.postCoin == 1,
            format("%s: the stand's coincident pair went %d -> %d, expected "
                 ~ "2 -> 1. This cell is one of the three that CONSUME the "
                 ~ "planted duplicate, which is what loads the two payload "
                 ~ "arms this stage is about — the edge-set MERGE record and "
                 ~ "the Point-domain map values on the re-inserted vertex. "
                 ~ "Without the consumption both are INERT here and this "
                 ~ "cell's green means nothing about either",
                   nm, r.preCoin, r.postCoin));
    }

    // …and the members that leave the pair alone say so, in their own message,
    // so their green cannot be read as coverage of those arms (witness
    // W-10-INERT). `mesh.unify`'s arrangement welds BEFORE the command runs,
    // so its pair is already 1 on entry — asserted as `preCoin == postCoin`
    // rather than as a literal, which is what makes the row true for both
    // shapes without weakening either.
    foreach (nm; ["mesh.triple", "mesh.quadruple", "mesh.detriangulate",
                  "mesh.unify", "mesh.mergeFaces", "mesh.edgeJoin"]) {
        auto r = runs[nm];
        assert(r.postCoin == r.preCoin,
            format("%s consumed a coincident vertex (%d -> %d). This cell is "
                 ~ "recorded as a NON-welding member: the edge-set MERGE "
                 ~ "record and the Point-domain map payload are INERT on its "
                 ~ "path, and its green is stated to say nothing about them. "
                 ~ "If it now welds, that sentence is false and this roster's "
                 ~ "attribution is wrong", nm, r.preCoin, r.postCoin));
    }
    {
        auto r = runs["mesh.unify"];
        assert(r.preCoin == 1,
            format("mesh.unify's arrangement did not weld before the command "
                 ~ "ran (coincident pair is %d, expected 1) — `unifyFaces` "
                 ~ "drops faces with a DUPLICATE vertex set and the stand has "
                 ~ "no duplicate pair until the weld makes one, so this cell "
                 ~ "would freeze a refusal", r.preCoin));
    }

    // THE COLLAPSE GROUP welds its OWN selected set rather than the planted
    // pair, so the channel above cannot see it. What can: a vertex drop
    // STRICTLY LARGER than the orphan compaction alone, whose size is the
    // measured 1.
    foreach (nm; ["mesh.collapse/vertex", "mesh.collapse/edge",
                  "mesh.collapse/polygon", "vert.join"]) {
        auto r = runs[nm];
        assert(r.preVerts - r.postVerts >= 2,
            format("%s: V went %d -> %d, a drop of %d. The stand's orphan "
                 ~ "accounts for 1 of that on EVERY member of this family "
                 ~ "(measured on mesh.triple), so a drop of 1 or 0 means this "
                 ~ "cell's own collapse consumed nothing and its weld tail "
                 ~ "never ran", nm, r.preVerts, r.postVerts,
                   r.preVerts - r.postVerts));
    }

    // Two cells that must NOT agree, or the roster has one behaviour written
    // twice. `vert.merge` and `mesh.weldVertexPair` reach the SAME tail
    // (`applyVertexRemapAndRebuild`) through two different doors, and
    // `vert.join` adds a collapse in front of the weld.
    assert(runs["vert.merge"].postOp != runs["vert.join"].postOp,
        "vert.merge and vert.join left the SAME post-op state — vert.join's "
      ~ "collapse is not reaching the mesh and the two cells measure one "
      ~ "behaviour");
    assert(runs["mesh.collapse/vertex"].postOp != runs["mesh.collapse/edge"].postOp,
        "mesh.collapse's vertex and edge modes left the same post-op state — "
      ~ "`editMode` is not reaching `evaluate`'s switch and the three collapse "
      ~ "cells are one cell written three times");
    assert(runs["mesh.collapse/edge"].postOp != runs["mesh.collapse/polygon"].postOp,
        "mesh.collapse's edge and polygon modes left the same post-op state — "
      ~ "see above");
    // `quadruple` and `detriangulate` are two of the three members that route
    // through `removeEdgesByMask`, on the SAME arrangement. If they agreed
    // they would be one cell written twice. Measured: 22 faces in, 13 out for
    // quadruple (its accept predicate demands a CONVEX COPLANAR quad and a
    // MATCHING pass) against 5 for detriangulate.
    assert(runs["mesh.quadruple"].postOp != runs["mesh.detriangulate"].postOp,
        "mesh.quadruple and mesh.detriangulate left the SAME post-op state on "
      ~ "the same triangulated stand — their accept predicates have converged "
      ~ "and one of the two cells measures nothing the other does not");

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
// STAGES L3 AND L5 FOUND THIS FIRST, ON TWO OTHER FAMILIES, AND THE PLAN'S
// RULE FOR THE REPEAT IS "the same argument, not a new one". So this reader
// imports `checkOrderNormalisation` from `undo_parity_l3_test` rather than
// writing a third copy of the reasoning that could drift from it. Measured
// here on 2026-08-28: frozen `[0,0,11,0,0,0,23,1,0,2,0,0]` against
// `[0,0,0,0,0,0,0,1,0,2,0,0]` — the two synthetic stamps on the UNSELECTED
// faces 2 and 6 are zeroed and the two on the SELECTED faces 7 and 9 are not,
// which is exactly the shape the normalisation predicts.
//
// IT IS A PIN, NOT A SKIP. The declared plane is still asserted: every
// UNSELECTED face's stamp must be 0 and every SELECTED face's must match the
// oracle exactly, and the entry must still have something to normalise. So a
// new regression on this plane reddens, and so does FIXING the divergence —
// which is what tells whoever fixed it to retire the entry.
//
// ONE ENTRY, NOT THIRTEEN, AND THAT IS A MEASUREMENT THAT CONTRADICTS THE
// STAGE'S OWN PREDICTION. Card 2340 wrote: *"the expected divergence for each
// of them is `faceSelectionOrder` (the L3 normalisation); the row in
// `kL10Exceptions` is added in the same commit"*. Stage L10-b…-f then migrated
// the other twelve and NOT ONE of them needed a row.
//
// WHY, and it is one line of `commands/mesh/selection_undo.d`: the twelve hold
// a `DenseSelectionUndo`, whose `restore` puts the three order arrays back
// WHOLESALE and re-zeroes only the entries the bulk setter REFUSED. So an
// unselected element keeps its stamp — exactly what `MeshSnapshot.restore`
// did, which is what the oracle froze. `vert_merge.d` is the one member that
// does not: it holds a bare `SelectionSnapshot`, whose tail re-zeroes EVERY
// unselected element's stamp, and that is the divergence this entry pins.
// `tests/unit/l10_command_undo_census_test.d` asserts that 12-of-13 split by
// NAME, so moving `vert_merge` onto the dense image reddens there and tells
// whoever did it to retire this entry.
//
// A row added for a cell that does NOT diverge reddens on
// `compareWithExceptions`'s "now AGREES" assert.
private immutable PlaneException[] kL10Exceptions = [
    PlaneException("vert.merge", "postUndo", "faceSelectionOrder",
        "SelectionSnapshot.restore re-zeroes an unselected element's order "
      ~ "stamp (snapshot.d, task 0613 S3); MeshSnapshot.restore does not",
        &checkOrderNormalisation),
];

unittest // the exception table is well-formed and cannot silence a whole cell
{
    string[] roster;
    foreach (ref sp; kL10Specs) roster ~= sp.name;
    assertExceptionTableWellFormed(kL10Family, kL10Exceptions, roster);

    // …and it must not reach a cell that is still on the SNAPSHOT path: those
    // compare the frozen snapshot dumps against themselves, so an exception
    // there would be a licence over a plane that in fact agrees — the blind
    // spot the "now AGREES" assert exists to refuse.
    foreach (ref e; kL10Exceptions) {
        bool onDelta = false;
        foreach (ref sp; kL10Specs)
            if (sp.name == e.cell && pathOf(sp.which) == "delta") onDelta = true;
        assert(onDelta,
            "exception on cell '" ~ e.cell ~ "' which is still on the "
          ~ "SNAPSHOT path — it compares the frozen dumps against themselves "
          ~ "and cannot diverge, so the entry silences a plane that agrees");
    }
}

// ===========================================================================
// Compare, or capture.
// ===========================================================================

unittest
{
    auto cells = l10Cells();

    assert(cells.length == kL10Specs.length && cells.length == 13,
        format("the recipe produced %d cells and the roster declares %d; the "
             ~ "stage owes 13 — eleven classes, with mesh.collapse counted "
             ~ "three times for its three modes, and mesh.bridge / mesh.sweep "
             ~ "deliberately absent (see the roster's header)",
               cells.length, kL10Specs.length));

    compareOrCapture(kL10Leaf, kL10Family, kL10ProducedBy, kL10Stand, cells,
                     "VIBE3D_PARITY_CAPTURE_L10", kL10Exceptions);
}

// ===========================================================================
// The REFUSALS, asserted rather than frozen.
//
// A refusing command leaves the mesh where it found it, so its two dumps are
// identical and a frozen pair of them cannot come out differently. What CAN
// come out differently is what the refusal DOES: `apply()` answers false,
// nothing is left mutated, and no edit frame is left open — the last of which
// is exactly what stage L10-P0's new batches put at risk, since a batch opened
// on a path that then refuses is a leaked frame and every later commitChange
// on that mesh defers forever.
// ===========================================================================

unittest // the GIGO rollback sites: refuse, roll back, leak nothing
{
    import tests.unit.fixtures : dumpMeshPlanes, diffMeshPlanes;
    import change_bus          : changeBus;

    // Each of these refuses on the stand for its OWN reason, named per row so
    // a red says which guard fired:
    //   * mesh.collapse   — one selected vertex is a no-op (`count < 2`)
    //   * vert.join       — likewise (`ordered.length < 2`)
    //   * mesh.mergeFaces — two NON-adjacent faces dissolve to nothing
    //   * mesh.edgeJoin   — two edges with no shared 2-valent vertex
    static struct Row { string name; }

    foreach (row; ["mesh.collapse", "vert.join", "mesh.mergeFaces",
                   "mesh.edgeJoin"]) {
        auto m = l10Stand();
        auto pre = dumpMeshPlanes(*m);
        immutable ulong leaks0 = changeBus.batchLeaks;
        auto v = new View(0, 0, 800, 600);

        Command c;
        void nop() { }
        switch (row) {
            case "mesh.collapse":
                m.clearVertexSelection(); m.selectVertex(5);
                c = cast(Command) new MeshCollapse(m, v, EditMode.Vertices);
                break;
            case "vert.join":
                m.clearVertexSelection(); m.selectVertex(5);
                c = cast(Command) new MeshVertJoin(m, v, EditMode.Vertices);
                break;
            case "mesh.mergeFaces":
                m.clearFaceSelection(); m.selectFace(0); m.selectFace(8);
                c = cast(Command) new MeshMergeFaces(m, v, EditMode.Polygons, &nop);
                break;
            default:
                m.clearEdgeSelection();
                m.selectEdge(m.edgeIndex(5, 6));
                m.selectEdge(m.edgeIndex(9, 10));
                c = cast(Command) new MeshEdgeJoin(m, v, EditMode.Edges);
                break;
        }
        // The selection edits above are not the subject; re-baseline after
        // them so a Select-plane difference is not read as a mutation.
        pre = dumpMeshPlanes(*m);

        assert(!c.apply(),
            row ~ " APPLIED on an operand it must refuse — it then lands a "
          ~ "history entry describing no change, and the next Ctrl+Z spends "
          ~ "itself on it");
        auto post = dumpMeshPlanes(*m);
        assert(diffMeshPlanes(pre, post) == "",
            row ~ " refused and still moved the mesh: planes ["
          ~ diffMeshPlanes(pre, post) ~ "]. A partial edit behind a refusal has "
          ~ "no undo entry to blame it on");
        assert(changeBus.batchLeaks == leaks0,
            format("%s's refusal leaked %d edit frame(s) — stage L10-P0 opened "
                 ~ "a batch on this path and the refusal returns before "
                 ~ "`close()`, so every later commitChange on this mesh defers "
                 ~ "forever", row, changeBus.batchLeaks - leaks0));
    }
}
