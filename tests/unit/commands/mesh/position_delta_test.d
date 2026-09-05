// position_delta_test — the BEHAVIOURAL half of task 1903 §L0-d.
//
// `tests/unit/commit_seam_census_test.d`'s nine `== 0` rows are the TEXT half:
// they say the nine files hold no raw coordinate write. They are green over a
// command that records NOTHING — one whose kernel runs through
// `MeshEditBatch.unrecorded`, or whose `ed.` prefix was dropped so the write
// lands through `alias mesh this` and produces no op-log entry. In both of
// those states the forward geometry is still correct and the undo still works,
// because the command falls back to its own legacy revert. That legacy fallback
// is A SECOND, UNNAMED GUARD in front of everything this stage changed, and it
// is why the cells below assert the OP-LOG, not only the result.
//
// WHAT EACH CELL IS FOR, so a later reader does not collapse them:
//
//   W-d3d  non-vacuity, asserted FIRST — the forward must MOVE something.
//          `smooth` on a uniform planar grid is the identity, and every design
//          in this file is green on that stand.
//   W-d3a  the op-log shape: exactly `[SetPos]`, `armed()` true.
//   W-d3b  the ARMED-REVERT plane diff, both ways: the named planes DIFFER at
//          the post-op step and are byte-identical after the revert. Measured
//          on the REVERSE — a forward carry says nothing about the inverse.
//   W-d3c  tracker-on / tracker-off parity: the hand-rolled path is the oracle.
//   W-d4   the `posAfter` half, replayed directly on the delta. Nothing on the
//          command path reads it (redo re-runs the kernel), so without this
//          cell `posAfter` is a presence bit.
//   W-d5   redo lands where the first run landed.
//   W-d11  the counters are BLIND, made explicit.
module tests.unit.commands.mesh.position_delta_test;

import std.format : format;
import std.math   : isClose;

import command;
import mesh;
import view;
import editmode;
import math      : Vec3;
import params    : Param;
import http_json : meshPlanesJson;
import mesh_edit_delta : MeshEditDelta, MeshOpEntry, MeshEditScope;
import operator  : VectorStack;
import toolpipe.packets : SubjectPacket;
import commands.mesh.position_undo : PositionUndo;

import commands.mesh.smooth        : MeshSmooth;
import commands.mesh.jitter        : MeshJitter;
import commands.mesh.quantize      : MeshQuantize;
import commands.mesh.magnet        : MeshMagnet;
import commands.mesh.linear_align  : MeshLinearAlign;
import commands.mesh.radial_align  : MeshRadialAlign;
import commands.mesh.vertex_center : MeshCenterVertices;
import commands.mesh.vertex_set    : MeshSetPosition;
import commands.mesh.edge_slide    : MeshEdgeSlide;

// ---------------------------------------------------------------------------
// The stand.
//
// A 4x4 quad grid with ONE VERTEX PUSHED OUT OF PLANE, and the perturbation is
// the whole point rather than flavour: on a uniform planar grid the discrete
// laplacian of an interior vertex IS that vertex, so `mesh.smooth` is the
// identity there and every assertion in this file would hold over any
// implementation at all (CLAUDE.md's "the fixture cannot exhibit the
// phenomenon"). It also breaks collinearity for `linear_align`, whose targets
// on a straight row are the row itself.
// ---------------------------------------------------------------------------
private Mesh* standMesh() {
    auto m = new Mesh;
    *m = makeGridPlane(3);          // side = 4, 16 verts, 9 quads
    m.buildLoops();
    m.syncSelection();
    m.vertices[5].y  += 0.37f;      // interior, out of plane
    m.vertices[6].x  += 0.11f;
    m.vertices[9].y  -= 0.23f;
    return m;
}

private View standView() { return new View(0, 0, 800, 600); }

private void setF(Command c, string n, float v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.fptr = v; return; }
    assert(false, "no float param `" ~ n ~ "` on " ~ c.name());
}
private void setI(Command c, string n, int v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.iptr = v; return; }
    assert(false, "no int param `" ~ n ~ "` on " ~ c.name());
}
private void setS(Command c, string n, string v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.sptr = v; return; }
    assert(false, "no string param `" ~ n ~ "` on " ~ c.name());
}
private void setV(Command c, string n, Vec3 v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.vptr = v; return; }
    assert(false, "no vec3 param `" ~ n ~ "` on " ~ c.name());
}
private void setB(Command c, string n, bool v) {
    foreach (ref p; c.params()) if (p.name == n) { *p.bptr = v; return; }
    assert(false, "no bool param `" ~ n ~ "` on " ~ c.name());
}

private string planes(Mesh* m) { return meshPlanesJson(*m); }

// Every one of the nine, behind one interface. `make` builds the command AND
// installs its selection/params on the mesh it is handed, so a stand and its
// command cannot drift apart.
private struct Cell {
    string           name;
    EditMode         mode;
    Command function(Mesh*, View) make;
}

private Command mkSmooth(Mesh* m, View v) {
    auto c = new MeshSmooth(m, v, EditMode.Vertices);
    setI(c, "iter", 2); setF(c, "strn", 0.8f);
    return c;
}
private Command mkJitter(Mesh* m, View v) {
    auto c = new MeshJitter(m, v, EditMode.Vertices);
    setF(c, "rangeX", 0.2f); setF(c, "rangeY", 0.2f); setF(c, "rangeZ", 0.2f);
    setI(c, "seed", 7);
    return c;
}
private Command mkQuantize(Mesh* m, View v) {
    auto c = new MeshQuantize(m, v, EditMode.Vertices);
    setF(c, "X", 0.3f); setF(c, "Y", 0.3f); setF(c, "Z", 0.3f);
    return c;
}
private Command mkMagnet(Mesh* m, View v) {
    auto c = new MeshMagnet(m, v, EditMode.Vertices);
    setV(c, "target", Vec3(6, 0, 0));
    setF(c, "strength", 0.5f);
    setF(c, "dist", 100.0f);
    return c;
}
// The align pair needs a CHAIN: a run of selected vertices joined by edges.
// Row i = 1 of the grid is v4..v7, and v5/v6 were pushed off the line by
// `standMesh`, so the aligned targets differ from the source.
private void selectRow(Mesh* m) {
    foreach (vi; [4u, 5u, 6u, 7u]) m.selectVertex(vi);
}
private Command mkLinear(Mesh* m, View v) {
    selectRow(m);
    auto c = new MeshLinearAlign(m, v, EditMode.Vertices);
    setF(c, "weight", 1.0f);
    return c;
}
private Command mkRadial(Mesh* m, View v) {
    selectRow(m);
    auto c = new MeshRadialAlign(m, v, EditMode.Vertices);
    setF(c, "weight", 1.0f);
    return c;
}
private Command mkCenter(Mesh* m, View v) {
    foreach (vi; [1u, 5u, 6u, 9u]) m.selectVertex(vi);
    auto c = new MeshCenterVertices(m, v, EditMode.Vertices);
    setS(c, "axis", "y");
    return c;
}
private Command mkSetPos(Mesh* m, View v) {
    foreach (vi; [1u, 5u, 6u, 9u]) m.selectVertex(vi);
    auto c = new MeshSetPosition(m, v, EditMode.Vertices);
    setS(c, "axis", "z"); setF(c, "value", 0.25f);
    return c;
}
private Command mkSlide(Mesh* m, View v) {
    // An INTERIOR edge, so both flanking faces exist and both endpoints have a
    // rail. index(i,j) = i*4 + j with i along Z, j along X.
    const uint ei = m.edgeIndex(5, 6);
    assert(ei != ~0u, "the stand has no edge 5-6 — makeGridPlane's numbering "
                    ~ "changed and this cell is picking an edge at random");
    m.selectEdge(ei);
    auto c = new MeshEdgeSlide(m, v, EditMode.Edges);
    setF(c, "t", 0.6f);
    return c;
}

private Cell[] cells() {
    return [
        Cell("mesh.smooth",         EditMode.Vertices, &mkSmooth),
        Cell("mesh.jitter",         EditMode.Vertices, &mkJitter),
        Cell("mesh.quantize",       EditMode.Vertices, &mkQuantize),
        Cell("mesh.magnet",         EditMode.Vertices, &mkMagnet),
        Cell("mesh.linear_align",   EditMode.Vertices, &mkLinear),
        Cell("mesh.radial_align",   EditMode.Vertices, &mkRadial),
        Cell("mesh.centerVertices", EditMode.Vertices, &mkCenter),
        Cell("mesh.setPosition",    EditMode.Vertices, &mkSetPos),
        Cell("mesh.edge_slide",     EditMode.Edges,    &mkSlide),
    ];
}

// The op-log, reached through the `version (unittest)` accessor each command
// carries. A `Command` reference cannot answer this, so the dispatch is by
// concrete type — which is also what keeps a command that silently lost its
// `PositionUndo` from compiling past this file.
private const(MeshEditDelta)* recorded(Command c) {
    if (auto x = cast(MeshSmooth)c)         return &x.recordedUndo().delta();
    if (auto x = cast(MeshJitter)c)         return &x.recordedUndo().delta();
    if (auto x = cast(MeshQuantize)c)       return &x.recordedUndo().delta();
    if (auto x = cast(MeshMagnet)c)         return &x.recordedUndo().delta();
    if (auto x = cast(MeshLinearAlign)c)    return &x.recordedUndo().delta();
    if (auto x = cast(MeshRadialAlign)c)    return &x.recordedUndo().delta();
    if (auto x = cast(MeshCenterVertices)c) return &x.recordedUndo().delta();
    if (auto x = cast(MeshSetPosition)c)    return &x.recordedUndo().delta();
    if (auto x = cast(MeshEdgeSlide)c)      return &x.recordedUndo().delta();
    assert(false, "no recordedUndo accessor for " ~ c.name());
}
private bool armed(Command c) {
    if (auto x = cast(MeshSmooth)c)         return x.recordedUndo().armed();
    if (auto x = cast(MeshJitter)c)         return x.recordedUndo().armed();
    if (auto x = cast(MeshQuantize)c)       return x.recordedUndo().armed();
    if (auto x = cast(MeshMagnet)c)         return x.recordedUndo().armed();
    if (auto x = cast(MeshLinearAlign)c)    return x.recordedUndo().armed();
    if (auto x = cast(MeshRadialAlign)c)    return x.recordedUndo().armed();
    if (auto x = cast(MeshCenterVertices)c) return x.recordedUndo().armed();
    if (auto x = cast(MeshSetPosition)c)    return x.recordedUndo().armed();
    if (auto x = cast(MeshEdgeSlide)c)      return x.recordedUndo().armed();
    assert(false, "no recordedUndo accessor for " ~ c.name());
}

// ---------------------------------------------------------------------------
// W-d3d + W-d3a — the forward moves something, and the log says [SetPos].
// ---------------------------------------------------------------------------
unittest {

    foreach (cell; cells()) {
        auto m = standMesh();
        auto v = standView();
        auto c = cell.make(m, v);
        immutable pre = planes(m);

        assert(c.apply(), cell.name ~ ": the forward must apply on this stand");

        // W-d3d, FIRST. A cell whose forward moves nothing is green under every
        // design in this file — the delta is empty, the command falls back to
        // its legacy revert, and "the planes came back" is trivially true.
        immutable post = planes(m);
        assert(post != pre,
            cell.name ~ ": the forward moved NOTHING on this stand, so every "
          ~ "assertion below is vacuous. The stand perturbs three interior "
          ~ "vertices precisely so that `smooth` and `linear_align` are not "
          ~ "the identity here; if this reddens, the stand stopped exhibiting "
          ~ "the phenomenon, it is not the command that broke.");

        // W-d3a. THIS CELL RUNS ON A NON-EMPTY OPERAND. `edge_slide` — and
        // `smooth`/`jitter`/`quantize` after task 2110 — deliberately leave
        // `armed()` FALSE on an EMPTY edit and fall back to the legacy no-op
        // revert: that is §R2.1's ruling and `tests/test_edge_slide.d:296`'s
        // 0099 guard, not a bug to fix by making this assert pass. Do not
        // remove those empty arms to satisfy this line.
        assert(armed(c),
            cell.name ~ ": the command recorded NO delta and silently fell "
          ~ "back to its legacy revert. The forward geometry is still correct "
          ~ "and the census row for this file is still `== 0` — the legacy "
          ~ "fallback is a second, unnamed guard in front of everything L0-d "
          ~ "changed, and this is the assert that sees past it.");

        auto d = recorded(c);
        assert(d.log.length >= 1,
            cell.name ~ ": the recorded op-log is empty while `armed()` is "
          ~ "true — PositionUndo.arm's emptiness test and MeshEditDelta.isEmpty "
          ~ "disagree.");
        foreach (i, ref e; d.log)
            assert(e.kind == MeshOpEntry.Kind.SetPos,
                format("%s: op-log entry %d is `%s`, expected SetPos. A "
                     ~ "position command must record ONLY SetPos: any other "
                     ~ "kind makes `indexSpaceStable` answer false and the "
                     ~ "undo takes the SLOW finalize path, which is exactly "
                     ~ "the win L0-P1 carved out (and the topology counter "
                     ~ "then moves, which no other cell in this file reads).",
                       cell.name, i, e.kind));
    }
}

// ---------------------------------------------------------------------------
// W-d3b — the ARMED revert restores the pre-op planes, byte for byte.
// Asserted BOTH WAYS: differ at post, identical after the revert. Measured on
// the REVERSE, because a correct forward says nothing about its inverse.
// ---------------------------------------------------------------------------
unittest {

    foreach (cell; cells()) {
        auto m = standMesh();
        auto v = standView();
        auto c = cell.make(m, v);
        immutable pre = planes(m);
        assert(c.apply(), cell.name ~ ": forward");
        immutable post = planes(m);
        assert(post != pre, cell.name ~ ": vacuous stand (see W-d3d)");
        assert(armed(c),    cell.name ~ ": nothing recorded (see W-d3a)");

        assert(c.revert(), cell.name ~ ": the delta revert must answer true");
        immutable back = planes(m);
        assert(back == pre,
            cell.name ~ ": the recorded undo did NOT restore the pre-op "
          ~ "planes. `/api/mesh/planes` is plane-COMPLETE, so this compares "
          ~ "vertices, faces, marks, materials, parts and the map planes in "
          ~ "one string — the first divergence is what to read.\n  pre : "
          ~ pre[0 .. pre.length > 400 ? 400 : pre.length]
          ~ "\n  back: "
          ~ back[0 .. back.length > 400 ? 400 : back.length]);
        assert(back != post,
            cell.name ~ ": the post-op and post-revert dumps are IDENTICAL, "
          ~ "so the revert had nothing to undo and the `back == pre` assert "
          ~ "above is satisfied by a forward that did nothing.");
    }
}

// ---------------------------------------------------------------------------
// W-d3c IS GONE, AND ITS OBSERVABLE IS NOT (task 1903 Stage N).
//
// The cell that stood here ran every command TWICE in one process — once with
// `VIBE3D_UNDO_TRACKER` on and once off — and asserted the two post-revert
// plane dumps agreed. Its value was that the OFF arm was an INDEPENDENT data
// path: the command's own stored pre-op arrays, never the op-log's
// `posBefore`. That is what caught a `posBefore` captured after part of the
// forward had already run.
//
// Stage N deleted the hatch, so there is no second in-process path left to
// compare against; keeping the cell would have made it flip the flag to the
// value it already has and compare a path to itself — green before a defect
// and green after it. It is DELETED, not weakened, and declared in
// `tests/unit/unittest_census_ledger.txt`.
//
// WHAT STILL SEES THE DEFECT IT CAUGHT, so this is a removal and not a hole:
// the FROZEN parity oracle `tests/fixtures/undo_parity/position_marks.json`,
// read by `tests/unit/undo_parity_l0_test.d`. It was captured on the snapshot
// arm before that arm was deleted and it does not change, so it is the same
// independent reference this cell was — with the extra property that it
// cannot be re-derived from the code it judges. The neighbouring cell above
// keeps the round-trip half (`back == pre` and `back != post`).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// W-d4 — the `posAfter` half has ONE consumer, and it is not the command.
//
// `CommandHistory.redo` re-runs the kernel (see each command's `undo_.armed()`
// arm), so NOTHING on the command path ever reads `posAfter`. Every cell above
// is therefore green under a delta whose `after` values are garbage. This pins
// the PRIMITIVE: a direct forward replay of the recorded delta must land on the
// post-op mesh.
// ---------------------------------------------------------------------------
unittest {

    foreach (cell; cells()) {
        auto m = standMesh();
        auto v = standView();
        auto c = cell.make(m, v);
        immutable pre = planes(m);
        assert(c.apply(), cell.name ~ ": forward");
        immutable post = planes(m);
        assert(armed(c), cell.name ~ ": nothing recorded");
        // Copy the delta out before touching the mesh: `revert` is `const`, but
        // the holder belongs to a command whose next `apply` would replace it.
        // A const POINTER, not a copy: `MeshEditDelta` holds slices, so a
        // by-value const copy is refused, and both `apply` and `revert` are
        // `const` anyway. The command is not re-applied in this cell, so the
        // holder it points into does not move under us.
        auto d = recorded(c);

        assert(d.revert(*m), cell.name ~ ": delta.revert");
        assert(planes(m) == pre, cell.name ~ ": delta.revert must land on pre");
        assert(d.apply(*m), cell.name ~ ": delta.apply");
        assert(planes(m) == post,
            cell.name ~ ": replaying the recorded delta FORWARD does not land "
          ~ "on the post-op mesh. `posAfter` is wrong. No cell on the command "
          ~ "path can see this — redo re-runs the kernel — so without this "
          ~ "assert `posAfter` is a presence bit (памятка 22).");
        assert(d.revert(*m), cell.name ~ ": delta.revert (second)");
        assert(planes(m) == pre,
            cell.name ~ ": the delta is not idempotent under apply/revert "
          ~ "round-tripping.");
    }
}

// ---------------------------------------------------------------------------
// W-d5 — redo lands where the first run landed.
// ---------------------------------------------------------------------------
unittest {

    foreach (cell; cells()) {
        auto m = standMesh();
        auto v = standView();
        auto c = cell.make(m, v);
        immutable pre = planes(m);
        assert(c.apply(), cell.name ~ ": forward");
        immutable post = planes(m);
        assert(c.revert(), cell.name ~ ": undo");
        assert(planes(m) == pre, cell.name ~ ": undo must land on pre");

        assert(c.apply(), cell.name ~ ": redo must answer true");
        assert(planes(m) == post,
            cell.name ~ ": REDO did not land where the first run landed. The "
          ~ "redo arm re-runs the kernel UNRECORDED from the restored pre-op "
          ~ "mesh; a `return true` that forgets to re-run leaves the mesh at "
          ~ "the PRE-op state and a dump-vs-nothing assert would be green.");
        assert(planes(m) != pre,
            cell.name ~ ": the redo left the mesh at the pre-op state.");

        // And the second undo still works, replaying the FIRST delta.
        assert(c.revert(), cell.name ~ ": the second undo");
        assert(planes(m) == pre,
            cell.name ~ ": the second undo replayed the first delta onto a "
          ~ "mesh the redo had moved, and did not land on pre. The redo arm "
          ~ "must be deterministic given its params and the restored mesh.");
    }
}

// ---------------------------------------------------------------------------
// W-d11 — the counters are BLIND, made explicit.
//
// After the L0-P1 carve-out a correct fast-path undo and the hand-rolled revert
// it replaced are INDISTINGUISHABLE on `mutationVersion` and `topologyVersion`:
// both read +1 / +0. So anyone who ships a version-counter cell believing it
// witnesses THIS MIGRATION is measuring nothing.
//
// THE CLAIM IS SCOPED, and it is scoped because the drill caught an earlier
// draft of it over-claiming. The version rows are blind to "delta or legacy?";
// they are NOT blind to "fast or slow finalize?" — a defeated carve-out reads
// `+2 / +2`. The counter that answers the FIRST question is the derive count:
// 1 on the delta path, 0 on the legacy one, 2 on a defeated carve-out. All
// three numbers measured on this stand.
// ---------------------------------------------------------------------------
unittest {
    import mesh : g_hideDeriveRuns, g_rebuildEdgesRuns, g_buildLoopsRuns;


    foreach (cell; cells()) {
        auto m = standMesh();
        auto v = standView();
        auto c = cell.make(m, v);
        assert(c.apply(), cell.name ~ ": forward");
        assert(armed(c),  cell.name ~ ": nothing recorded");

        const ulong mv0 = m.mutationVersion;
        const ulong tv0 = m.topologyVersion;
        g_hideDeriveRuns    = 0;
        g_rebuildEdgesRuns  = 0;
        g_buildLoopsRuns    = 0;

        assert(c.revert(), cell.name ~ ": undo");

        // THE ROWS THAT ARE NOT BLIND, and they go FIRST because they are the
        // reason this block exists.
        assert(g_rebuildEdgesRuns == 0,
            format("%s: the undo ran `rebuildEdges` %d time(s). An "
                 ~ "index-space-stable log takes L0-P1's fast path and skips "
                 ~ "the rebuildEdges+buildLoops pair; a non-zero here means "
                 ~ "`indexSpaceStable` answered false, i.e. this command's log "
                 ~ "carries a kind other than SetPos (which W-d3a's cell reads "
                 ~ "directly) — or the carve-out was defeated.",
                   cell.name, g_rebuildEdgesRuns));
        assert(g_buildLoopsRuns == 0,
            format("%s: the undo ran `buildLoops` %d time(s) — same cause as "
                 ~ "the rebuildEdges row above; they are skipped as a PAIR and "
                 ~ "removing either alone is inert.",
                   cell.name, g_buildLoopsRuns));
        assert(g_hideDeriveRuns == 1,
            format("%s: the undo ran the hide derive %d time(s), expected "
                 ~ "exactly 1. TWO means the slow path ran: `rebuildEdges` "
                 ~ "publishes its own `commitChange(Polygons)`, which is a "
                 ~ "Geometry class and drags a SECOND derive behind it. ZERO "
                 ~ "means the revert never reached `finalize` at all — the "
                 ~ "command fell back to its legacy loop, which runs no derive "
                 ~ "(measured: the tracker-off path reads 0 on this same "
                 ~ "stand). THIS is the counter that separates the DELTA path "
                 ~ "from the LEGACY one; the two version rows below cannot.",
                   cell.name, g_hideDeriveRuns));

        // THE TWO THAT ARE BLIND TO THE MIGRATION — and the note is scoped,
        // because an earlier draft of it over-claimed and the drill caught it.
        //
        // What they CANNOT see: whether this undo was served by the recorded
        // delta or by the command's own legacy loop. Both give `+1 / +0`, so a
        // version-counter cell is green before AND after L0-d and green under
        // every mutation that deletes a recorder (W-d2, W-d3a — both measured).
        //
        // What they CAN see, and what the first draft of this comment wrongly
        // denied: a DEFEATED CARVE-OUT. `indexSpaceStable -> false` sends the
        // undo down the slow `finalize`, where `rebuildEdges` publishes
        // `Polygons` and the tail bump fires, and these read `+2 / +2` (P0-1's
        // R1 row). Measured — this assert is what reddened first under that
        // mutation before the rows above were moved ahead of it.
        assert(m.mutationVersion == mv0 + 1,
            format("%s: the undo moved mutationVersion by %d, expected 1. "
                 ~ "A `+2` is the SLOW finalize path (see the note above); it "
                 ~ "is NOT evidence about whether anything was recorded.",
                   cell.name, m.mutationVersion - mv0));
        assert(m.topologyVersion == tv0,
            format("%s: the undo moved topologyVersion by %d, expected 0. A "
                 ~ "SetPos-only log owes no topology bump (`owesTopologyBump`) "
                 ~ "and rebuilds no edges, so the tail bump is not taken. Same "
                 ~ "scoping as the row above: the hand-rolled revert also moved "
                 ~ "it by 0, so this says nothing about recording.",
                   cell.name, m.topologyVersion - tv0));
    }
}
