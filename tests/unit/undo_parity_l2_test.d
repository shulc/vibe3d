// undo_parity_l2_test — the FROZEN parity fixture for stage L2's family
// (create + index-stable topo-misc), and the reader that makes it an oracle.
//
// WHY IT IS OWED, and why it had to be captured BEFORE the first migration.
// The twelve commands of §5.5's L2 row hold the `MeshSnapshot` that IS the
// comparison; the first migration commit deletes one of them, and after that
// "the delta restores what the snapshot restored" has nothing left to be
// measured against. Stage L0 shipped without freezing its fixture and L1 had to
// go back to a pre-migration SHA to get one. Plan §6.3 rule 1, and L2.6.
//
// AND FOR THIS FAMILY THE FIXTURE IS NOT A NICETY. NINE of the twelve have an
// EMPTY or short op-log on the pre-migration tree, which means their delta-path
// `revert()` answers `true` and either changes nothing or leaves the mesh
// half-reverted. A count check cannot tell those from a correct undo. For
// `mesh.flip` / `mesh.fixOrientation` nothing but the per-corner map plane can:
// a revert that restores the winding but not the corner PERMUTATION leaves
// `vertices`, `faces`, every mark word and every count byte-identical.
//
// THE STAND IS `makeTaggedGridBent`, AND THAT IS A FINDING, NOT A DETAIL.
// Measured on this tree (2026-08-27, not read off a plan row): on the shipped
// `makeTaggedGridFull(3)`, `computeOrientationFlipMask` names ZERO faces and
// `alignFacesByMask` returns ZERO in all four operand configurations, so
// `mesh.fixOrientation` and `mesh.align` both REFUSE and both cells would
// freeze a pair of identical dumps. `makeTaggedGridBent` adds exactly the two
// things that fix that, with their own non-vacuity unittest in `fixtures.d`.
//
// A CUBE WOULD BE WRONG IN TWO SEPARATE WAYS, both of which matter here.
// It carries no per-corner map, no non-uniform material/part, no set masks — so
// the whole L2-a phenomenon (corners permuted, geometry identical) is invisible
// on it; and `mesh.thicken`'s rim bridge only runs on BOUNDARY loops, which a
// closed solid does not have, so the one prerequisite that command owns is
// unreachable. The stand is OPEN, and `fixtures.d` asserts that by name.
//
// TWO DUMPS PER CELL, and the reason is the same as L0's: a fixture holding
// only the post-undo state compares the stand against itself, so a cell whose
// FORWARD silently stopped working is green. `compareOrCapture`'s per-cell
// `postOp != postUndo` assert is the structural anti-vacuity guard, and
// `runCell` additionally asserts that `apply()` and `revert()` both answered
// true — a refusing command would otherwise freeze a fixture of nothing.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l2_test;

import command;
import mesh;
import view;
import editmode;
import math : Vec3;

import tests.unit.fixtures            : makeTaggedGridBent, findEdge;
import tests.unit.undo_parity_l0_test : ParityCell, runCell, compareOrCapture,
                                        setS, setI, setF, setV, setB;

import commands.mesh.vertex_new      : MeshVertexNew;
import commands.mesh.add_point       : MeshAddPoint;
import commands.mesh.flip            : MeshFlip;
import commands.mesh.polygon_align   : MeshAlign;
import commands.mesh.spikey          : MeshSpikey;
import commands.mesh.spin_edge       : MeshSpinEdge;
import commands.mesh.split_edge      : MeshSplitEdge;
import commands.mesh.split_face      : MeshSplitFace;
import commands.mesh.vertex_split    : MeshVertexSplit;
import commands.mesh.make_polygon    : MeshMakePolygon;
import commands.mesh.fix_orientation : MeshFixOrientation;
import commands.mesh.thicken         : MeshThicken;

enum string kL2Family = "create_stable";
enum string kL2Stand  = "makeTaggedGridBent(3)";

/// The stand, fresh per cell.
///
/// `syncSelection` after `buildLoops`, matching `l0Stand`: the tagging in
/// `makeTaggedGridFull` writes the selection planes directly and the derived
/// per-element arrays have to be sized to match before a command reads them.
private Mesh* l2Stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridBent(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

// ---------------------------------------------------------------------------
// The interior edge every edge-domain cell drives.
//
// NAMED rather than "the first selected edge", and the difference is not
// stylistic: `makeTaggedGridFull` selects edges 0 and 3 by INDEX, and an edge
// index is a position in a derived array that `rebuildEdges` re-lays. Which
// two edges those are is therefore a fact about `makeGridPlane`'s edge
// ordering, not about the stand's intent — and `mesh.spinEdge` REFUSES a
// boundary edge (`spinEdgeRings_`'s `nFaces != 2`), so a cell that inherits
// the tagged selection is one edge-ordering change away from freezing a
// refusal. `findEdge` resolves by ENDPOINTS, which is stable.
//
// 5-6 is interior on a 3x3 grid: vertices 5 and 6 are both interior and the
// edge between them is shared by faces 1 and 4.
private uint interiorEdge(Mesh* m)
{
    immutable int ei = findEdge(*m, 5, 6);
    assert(ei >= 0, "the stand has no edge 5-6 — makeGridPlane's vertex "
                  ~ "numbering changed and every edge cell below picks at "
                  ~ "random");
    return cast(uint) ei;
}

/// Replace the stand's inherited edge selection with the one named edge.
private void selectOnlyInteriorEdge(Mesh* m)
{
    immutable uint ei = interiorEdge(m);
    foreach (i; 0 .. m.edges.length) m.deselectEdge(cast(uint) i);
    m.selectEdge(ei);
    assert(m.hasAnySelectedEdges(), "the edge selection did not take");
}

/// Every L2 cell, in a fixed order.
///
/// `path` WAS `"snapshot"` for all twelve when the fixture was frozen at
/// `2f7ef302`, and that was a measurement rather than a default: all twelve
/// declared `private MeshSnapshot snap;` and all twelve opened `revert()` with
/// the identical `if (!snap.filled) return false; snap.restore(*mesh); return
/// true;`. Stages L2-a…L2-h moved every one of them, so the value below is now
/// what each command's `revert()` actually does.
///
/// `"dense-inline"` FOR EIGHT AND `"delta"` FOR FOUR, and the split is the
/// stage's finding rather than book-keeping. Eight of the twelve destroy
/// selection state on their forward — `resetSelection`, `repointToNothing`,
/// `repointToFaces`, `dropConsumedFaces`, `clearVertexSelection`, the appended
/// fan's `selectFace`, `syncSelection` — so they restore their TOPOLOGY from
/// the op-log and their SELECTION from a dense image the command holds beside
/// it (`commands/mesh/selection_undo.d`). No delta kind carries a
/// selection-order stamp, and L2-b measured against this very fixture that
/// adopting `Kind.SelectionDelta` restores LESS than the snapshot did. The four
/// that are pure `"delta"` touch no selection plane at all: `mesh.flip` and
/// `mesh.fixOrientation` only reverse windings, `mesh.align` only moves
/// vertices, and `mesh.addPoint` leaves the selection alone by contract.
///
/// THE FIELD IS RECORDED, NOT COMPARED: `meshPlanesJson` puts it in
/// `provenance`, and `comparePlanes` skips that object precisely so a capture
/// SHA does not redden every cell. So this value is documentation the reader
/// carries, and the frozen JSON still says `"snapshot"` — which is the point,
/// since the fixture must predate every migration commit.
ParityCell[] l2Cells(string sha)
{
    ParityCell[] out_;

    void cell(string name, string path, Command delegate(Mesh*, View) mk) {
        out_ ~= runCell(name, path, kL2Family, kL2Stand, sha, &l2Stand, mk);
    }

    // ---- L2-a, the discriminating pair ----------------------------------
    // `mesh.flip`'s operand is `operandFaceMask()` — the stand's selection is
    // face 7, so this flips ONE face. Deliberately one and not the whole mesh:
    // a whole-mesh flip is self-inverse, so a revert that installs the
    // AFTER-image instead of the BEFORE-image produces the same windings and
    // the cell cannot see the transposition. One face, and the mesh around it
    // unchanged, is what makes the dump discriminate.
    cell("mesh.flip", "delta", (m, v) =>
        cast(Command) new MeshFlip(m, v, EditMode.Polygons));
    cell("mesh.fixOrientation", "delta", (m, v) =>
        cast(Command) new MeshFixOrientation(m, v, EditMode.Polygons));

    // ---- L2-b -----------------------------------------------------------
    cell("mesh.spinEdge", "dense-inline", (m, v) {
        selectOnlyInteriorEdge(m);
        return cast(Command) new MeshSpinEdge(m, v, EditMode.Edges); });

    // ---- L2-c -----------------------------------------------------------
    cell("mesh.addPoint", "delta", (m, v) {
        selectOnlyInteriorEdge(m);
        auto c = new MeshAddPoint(m, v, EditMode.Edges);
        // 0.35, not the 0.5 default: at the midpoint the new vertex is the
        // average of the two endpoints, which is also what a WRONG restore of
        // a symmetric splice produces. An asymmetric t makes the position a
        // channel.
        setF(c, "t", 0.35f);
        return cast(Command)c; });
    cell("mesh.split_edge", "dense-inline", (m, v) {
        selectOnlyInteriorEdge(m);
        return cast(Command) new MeshSplitEdge(m, v, EditMode.Edges); });

    // ---- L2-d -----------------------------------------------------------
    // Explicit params rather than a vertex selection: `split_face` needs two
    // NON-ADJACENT vertices on one face, and naming them removes the
    // dependency on which qualifying face `findQualifyingFace` happens to
    // pick. Face 4 is the interior quad [5, 6, 10, 9]; 5 and 10 are its
    // diagonal.
    cell("mesh.splitFace", "dense-inline", (m, v) {
        auto c = new MeshSplitFace(m, v, EditMode.Vertices);
        setI(c, "face", 4); setI(c, "a", 5); setI(c, "b", 10);
        return cast(Command)c; });

    // ---- L2-e -----------------------------------------------------------
    // Vertex 5 is interior — four incident faces, so the split produces
    // several copies and the corner REPOINT is exercised on more than one
    // face. The stand's inherited vertex selection (2 and 9) is cleared first:
    // vertex 2 is on the boundary and would make the cell's operand a mix of
    // two shapes.
    cell("mesh.vertexSplit", "dense-inline", (m, v) {
        foreach (i; 0 .. m.vertices.length) m.deselectVertex(cast(uint) i);
        m.selectVertex(5);
        return cast(Command) new MeshVertexSplit(m, v, EditMode.Vertices); });

    // ---- L2-f -----------------------------------------------------------
    cell("mesh.spikey", "dense-inline", (m, v) {
        auto c = new MeshSpikey(m, v, EditMode.Polygons);
        setF(c, "amount", 0.4f);
        return cast(Command)c; });

    // ---- L2-g -----------------------------------------------------------
    cell("mesh.addVertex", "dense-inline", (m, v) {
        auto c = new MeshVertexNew(m, v, EditMode.Vertices);
        // Off every existing vertex and off the sheet's plane, so the position
        // is a channel of its own rather than a coincidence with a grid node.
        setV(c, "pos", Vec3(0.73f, 0.91f, -0.37f));
        return cast(Command)c; });
    cell("mesh.makePolygon", "dense-inline", (m, v) {
        // Four boundary vertices that do NOT already bound a face together, so
        // the new polygon is genuinely new. 0, 1, 2, 3 is the whole first row
        // of the vertex grid; the faces above it are quads 0/1/2, none of
        // which has all four.
        foreach (i; 0 .. m.vertices.length) m.deselectVertex(cast(uint) i);
        foreach (vi; [0u, 1u, 2u, 3u]) m.selectVertex(vi);
        return cast(Command) new MeshMakePolygon(m, v, EditMode.Vertices); });

    // ---- L2-h -----------------------------------------------------------
    // `symmetric: true`, NOT the default. The symmetric arm is the one that
    // moves every pre-existing vertex (`mesh.d`'s `vertices[i] = orig[i] +
    // vn[i] * (thickness * 0.5f)`), and it is the half a delta migration that
    // records only the appends silently loses. On the default `false` that arm
    // never runs, so a fixture cell frozen there would be green under exactly
    // the bug L2-h has to avoid.
    cell("mesh.thicken", "dense-inline", (m, v) {
        auto c = new MeshThicken(m, v, EditMode.Polygons);
        setF(c, "thickness", 0.25f); setB(c, "symmetric", true);
        return cast(Command)c; });

    cell("mesh.align", "delta", (m, v) =>
        cast(Command) new MeshAlign(m, v, EditMode.Polygons));

    return out_;
}

// ---------------------------------------------------------------------------
// THE READER.
//
// MUTATION THAT REDDENS IT: perturb one recorded plane value in
// `tests/fixtures/undo_parity/create_stable.json` — see the card. The message
// names the cell, which of the two dumps, and the plane.
// ---------------------------------------------------------------------------
unittest
{
    import std.process : environment;
    immutable sha = environment.get("VIBE3D_PARITY_SHA", "");
    compareOrCapture("create_stable.json", kL2Family, sha, kL2Stand,
                     l2Cells(sha), "VIBE3D_PARITY_CAPTURE_L2");
}
