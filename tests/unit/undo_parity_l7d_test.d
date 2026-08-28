// undo_parity_l7d_test — the FROZEN parity fixture for the VERTEX HALF of
// stage L7 (`mesh.vertexBevel`), and the reader that makes it an oracle.
//
// WHY IT IS A SECOND FILE AND NOT THREE MORE CELLS IN `bevel.json`. That
// fixture is declared IMMUTABLE from stage L7-a onward by its own reader's
// header, and adding a cell to it is a re-capture — the one thing that header
// forbids. Task 2320 froze it with the vertex half explicitly excluded and
// said why: at the time `mesh.vertexBevel` was blocked on the Point-domain
// map-value payload, so a cell for it would have frozen a snapshot oracle for
// a path that REMAINED the snapshot. The block has since lifted (task 2330),
// so the class migrates and gets its own leaf and its own capture key.
//
// WHY IT LANDS BEFORE THE FIRST SOURCE CHANGE THAT ALTERS UNDO (§6.3 rule 1).
// `MeshVertexBevel` holds the whole-mesh `MeshSnapshot` that IS the
// comparison, and stage L7-d deletes it.
//
// ---------------------------------------------------------------------------
// THE ROW STAGE K REFUSED, AND WHY IT IS ARMED NOW
// ---------------------------------------------------------------------------
// Stage K measured `bevelVerticesByMask` armed on 2026-08-27 and left it
// DISARMED under one stated rule — *do not arm when a VALUE is lost*. Its
// residual then held three planes that are not Select bits: `meshMaps["W"]`
// (a Point-domain map VALUE) zeroed at the bevelled vertex, the `vertexSetMask`
// bit of that vertex cleared, and one of the two `edgeSetMask` entries gone.
// All three ride `compactUnreferenced`'s `[RemoveVerts, Reindex]` pair, which
// at the time restored positions and nothing else per vertex.
//
// What changed is that OTHER entry, not this kernel: `Kind.RemoveVerts` gained
// the set-mask payload at stage L5-b and the Point-domain map-value payload at
// L7-P3 (task 2330). Re-measured here before arming, three operands, EXACT
// residual both ways: the armed revert's residual is FIVE planes and every one
// of them is Select-class (`vertexMarks`, `vertexSelectionOrder`, `edgeMarks`,
// `faceMarks`, `orderCounters`). The per-vertex weight map, both set masks,
// the per-corner UV map, every position, every winding and all three counts
// come back BYTE-IDENTICAL. The residual row lives in
// `tests/unit/face_reindex_arming_test.d`'s `bevelVerticesByMask` cell.
//
// THIS FAMILY IS THE SECOND-FAMILY WITNESS FOR BOTH `RemoveVerts` PAYLOADS,
// and it inherited that job from stage L6 by measurement. §L6.2's P-L6-3
// expected the duplication family to be it; measured, no weld in that family
// ever drops an ORIGINAL vertex (every one of them merges a CLONE into an
// original), so both payload arms are INERT there. Here the consumed vertex IS
// an original, IS in the named vertex set "V", and IS an endpoint of a named
// edge-set entry. The cells assert all three, BEFORE comparing anything.
//
// ---------------------------------------------------------------------------
// NO MARKS PUBLISHER IS BUILT — the Select-class residue is
// `commands/mesh/selection_undo.d`'s `DenseSelectionUndo` (§0.1).
//
// THE FILE IS IMMUTABLE FROM STAGE L7-d ONWARD.
//
//   * `postUndo` differs => the migration restores LESS. Fix the code.
//   * `postOp`   differs => the FORWARD changed. Louder, and out of scope.
//   * a legitimate normalisation => a NAMED PER-PLANE EXCEPTION here, argued
//     and reviewed. NOT a re-capture.
//
// A SEPARATE CAPTURE KEY, `VIBE3D_PARITY_CAPTURE_L7D`, WRITING EXACTLY ONE
// FILE — see `tests/unit/parity_capture_key_census_test.d`.
//
// DRUNTIME STOPS A MODULE AT ITS FIRST FAILING ASSERT — run the cells in
// isolation when scoring a mutation.
module tests.unit.undo_parity_l7d_test;

import std.format : format;

import change_bus : changeBus;
import command;
import mesh;
import view;
import editmode;
import http_json : meshPlanesJson, PlaneDumpMeta;

import tests.unit.fixtures            : makeTaggedGridFull;
import tests.unit.undo_parity_l0_test : ParityCell, compareOrCapture, setF;

import commands.mesh.vertex_bevel : MeshVertexBevel;

enum string kL7dFamily = "vertex_bevel";
enum string kL7dStand  = "makeTaggedGridFull(3)";

/// The tree that PRODUCED the frozen dumps.
///
/// NOT A BARE SHA (`undo_parity_l5_test.d`'s convention), even though the arm
/// this token names is forward-INERT for these dumps: `MeshVertexBevel` still
/// opens an `unrecorded` batch at capture time, so `faceReindexScope()`
/// captures a null tracker and does nothing at all. The token is compound
/// because the tree is not the branch point, and a bare SHA would claim it
/// was.
enum string kL7dProducedBy = "b1c98ccb+L7-d-arm";

// ===========================================================================
// The stand. `makeTaggedGridFull(3)` — an OPEN 3x3 grid.
//
// NOT A CUBE, and for this family the reason is sharper than usual:
// `bevelVerticesByMask` accepts INTERIOR-MANIFOLD vertices, and on a closed
// solid every vertex is one, so a cube cannot separate "the kernel skipped the
// rim" from "the kernel processed everything". The grid has both kinds.
// ===========================================================================

private Mesh* l7dStand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

/// Vertex 5 — an INTERIOR vertex of the 3x3 grid, a member of the stand's
/// named vertex set "V", and the carrier of a non-zero Point-domain "W" value.
/// It is the vertex Stage K's own refusal was measured on.
private enum uint kSetMemberVertex = 5;

// ===========================================================================
// The roster. THREE FROZEN CELLS.
//
// The REFUSALS are not frozen — a refusing command leaves
// `postOp == postUndo == pre`, which `compareOrCapture`'s anti-vacuity assert
// rejects outright, and a frozen pair of identical dumps is a check that
// cannot come out differently. They are asserted directly in
// `tests/unit/l7d_vertex_bevel_delta_test.d`.
// ===========================================================================

private struct L7dCellSpec {
    string name;
    /// Vertices to select; EMPTY leaves the stand's own selection in place,
    /// and `[uint.max]` means "clear the selection", i.e. the whole-mesh
    /// greedy-subset path.
    uint[] select;
    float  amount;
}

private immutable L7dCellSpec[] kL7dSpecs = [
    // THE DISCRIMINATING CELL, AND IT GOES FIRST. One interior vertex that is
    // simultaneously a named-set member and the carrier of a Point-map value,
    // so a revert that restores the geometry and drops either one reddens HERE
    // and nowhere else in the tree.
    L7dCellSpec("mesh.vertexBevel/setMember", [kSetMemberVertex],  0.2f),
    // The stand's OWN selection (vertices 2 and 9), which is the operand every
    // other reader on this stand uses, and TWO processed vertices rather than
    // one — so a kernel that only ever handles the first is not green here.
    L7dCellSpec("mesh.vertexBevel/standPair", [],                  0.2f),
    // EMPTY selection => whole mesh, the greedy vertex-disjoint subset. The
    // only cell that exercises `operandVertexMask`'s fallback, and the only one
    // whose processed set the test does not name.
    L7dCellSpec("mesh.vertexBevel/whole",     [uint.max],          0.15f),
];

private struct CellRun {
    string postOp, postUndo;
    size_t preVerts, postVerts;
    size_t preFaces, postFaces;
}

private void arrange(in L7dCellSpec s, Mesh* m)
{
    if (s.select.length == 0) return;
    m.clearVertexSelection();
    if (s.select.length == 1 && s.select[0] == uint.max) return;
    foreach (vi; s.select) m.selectVertex(cast(int) vi);
}

private CellRun l7dRunOnce(in L7dCellSpec s, in PlaneDumpMeta meta)
{
    auto m = l7dStand();
    arrange(s, m);

    CellRun r;
    r.preVerts = m.vertices.length;
    r.preFaces = m.faces.length;

    auto v = new View(0, 0, 800, 600);
    auto c = new MeshVertexBevel(m, v, EditMode.Vertices);
    setF(cast(Command) c, "amount", s.amount);

    // Read as a DELTA across the forward and asserted INDEPENDENTLY of the
    // status: `acceptRecordedEdit` answers `false` AND ticks this counter for
    // a non-empty mutation that recorded nothing, so `apply()` returning true
    // does not by itself say the delta is non-empty for the right reason.
    immutable ulong e0 = changeBus.emptyDeltaOverMutation;

    assert(c.apply(), s.name ~ ": the forward must apply on this stand — a "
                    ~ "refusing command freezes a fixture of nothing");
    assert(changeBus.emptyDeltaOverMutation == e0, format(
        "%s: the command closed a recording batch with an EMPTY delta over a "
      ~ "real mutation (emptyDeltaOverMutation moved by %d)", s.name,
        changeBus.emptyDeltaOverMutation - e0));
    r.postVerts = m.vertices.length;
    r.postFaces = m.faces.length;
    r.postOp    = meshPlanesJson(*m, meta);

    assert(c.revert(), s.name ~ ": the undo must succeed on this stand");
    r.postUndo = meshPlanesJson(*m, meta);
    return r;
}

ParityCell[] l7dCells()
{
    auto meta = PlaneDumpMeta(kL7dProducedBy, "snapshot", kL7dFamily, kL7dStand);

    // ---- non-vacuity of the STAND, before any cell runs -------------------
    {
        auto m = l7dStand();
        assert(m.faces.length == 9 && m.vertices.length == 16,
            format("the stand is V=%d F=%d, expected V=16 F=9 — every index "
                 ~ "constant in this file names a vertex at random otherwise",
                   m.vertices.length, m.faces.length));

        // 1. THE SET-MASK ARM of the `RemoveVerts` payload (stage L5-b). The
        // chamfered vertex must be in a named vertex set, or the arm is inert
        // and this file is not the witness it claims to be.
        assert((m.vertexSetMask[kSetMemberVertex] & 1UL) != 0, format(
            "the stand's vertex %d is not in a named vertex set — the "
          ~ "set-mask arm of the `Kind.RemoveVerts` payload is then INERT on "
          ~ "every cell here, and a green says nothing about stage L5-b",
            kSetMemberVertex));

        // 2. …and at least one named EDGE-set entry must have that vertex as
        // an endpoint, which is the arm's edge half.
        size_t incidentSetEdges = 0;
        foreach (k, w; m.edgeSetMask) {
            immutable uint a = cast(uint)(k >> 32), b = cast(uint)(k & 0xffff_ffffUL);
            if (a == kSetMemberVertex || b == kSetMemberVertex) ++incidentSetEdges;
        }
        assert(incidentSetEdges > 0, format(
            "no named edge-set entry has vertex %d as an endpoint — the EDGE "
          ~ "half of the set-mask payload (`edgeSetKeyDropped` / "
          ~ "`edgeSetWordDropped`) is then INERT here", kSetMemberVertex));

        // 3. THE POINT-MAP ARM (L7-P3, task 2330). A zero value is
        // indistinguishable from a zeroed one — the exact shape the payload's
        // all-zero discard makes free — so the value must be non-zero.
        auto wm = m.meshMap("W");
        assert(wm !is null && wm.domain == MapDomain.Point && wm.dim == 1,
            "the stand carries no dim-1 Point-domain `W` map");
        assert(wm.data.length > kSetMemberVertex
            && wm.data[kSetMemberVertex] != 0.0f, format(
            "the stand's `W` value at vertex %d is 0 — a payload that dropped "
          ~ "it would restore 0 and compare EQUAL, so this cell could not tell "
          ~ "a carried value from a lost one", kSetMemberVertex));

        // 4. The per-corner UV values are DISTINCT, so a value restored onto
        // the WRONG corner fails as loudly as one that vanished.
        auto uv = m.meshMap(kUvMapName);
        assert(uv !is null && uv.domain == MapDomain.PolyVertex,
            "the stand carries no PolyVertex `" ~ kUvMapName ~ "` map");
        bool[float] seenU;
        foreach (k; 0 .. uv.data.length / uv.dim) {
            immutable float u = uv.data[k * uv.dim];
            assert((u in seenU) is null, format(
                "uv corner %d repeats the value %s", k, u));
            seenU[u] = true;
        }

        // 5. `faceMarks` carries non-Select bits — a HIDDEN face and a
        // SUBPATCH face — so "faceMarks came back" is not satisfied by a
        // revert that restored the Select bit alone.
        assert(m.isFaceHidden(5) && m.isFaceSubpatch(1),
            "the stand hides no face or marks none subpatch");
    }

    ParityCell[] out_;
    CellRun[string] runs;
    foreach (ref s; kL7dSpecs) {
        auto r = l7dRunOnce(s, meta);
        runs[s.name] = r;
        out_ ~= ParityCell(s.name, "snapshot", r.postOp, r.postUndo);
    }

    // ---- per-cell non-vacuity: the forward MOVED something ---------------
    foreach (ref s; kL7dSpecs) {
        auto r = runs[s.name];
        assert(r.postVerts > r.preVerts && r.postFaces > r.preFaces, format(
            "%s: the op left V=%d->%d F=%d->%d — every assertion about its "
          ~ "undo is then satisfied by an undo that does nothing",
            s.name, r.preVerts, r.postVerts, r.preFaces, r.postFaces));
    }

    // The three cells must be three DIFFERENT operands, or two of them are one
    // cell written twice and the "whole mesh" fallback is untested.
    assert(runs["mesh.vertexBevel/setMember"].postOp
        != runs["mesh.vertexBevel/standPair"].postOp,
        "the one-vertex and stand-pair cells left the SAME post-op state — the "
      ~ "selection is not reaching `operandVertexMask`");
    assert(runs["mesh.vertexBevel/whole"].postFaces
         > runs["mesh.vertexBevel/standPair"].postFaces,
        "the whole-mesh cell chamfered no more vertices than the two-vertex "
      ~ "cell — `operandVertexMask`'s empty-selection fallback is not reached");

    return out_;
}

// ---------------------------------------------------------------------------
// THE READER.
//
// MUTATION THAT REDDENS IT (W-7-d1): disable the Point-map arm of the
// `Kind.RemoveVerts` payload at its single production publisher
// (`Mesh.compactUnreferenced`). Positions, windings, all three counts, both
// face-attribute planes and every mark word still compare EQUAL — only the
// `meshMaps` plane differs, on the `setMember` cell. This is Stage K's stated
// do-not-arm ground made executable.
//
// MUTATION THAT REDDENS IT (W-7-d2): drop the `faceReindexScope()` arm from
// `bevelVerticesByMask`. The op-log loses its `FaceReindex`, the delta
// restores no face array, and the cell reddens on `counts`.
// ---------------------------------------------------------------------------
unittest
{
    compareOrCapture("vertex_bevel.json", kL7dFamily, kL7dProducedBy,
                     kL7dStand, l7dCells(), "VIBE3D_PARITY_CAPTURE_L7D");
}
