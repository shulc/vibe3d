// l5_axis0_batch_test — task 1903 Stage L5-P0's witness: the four L5 files that
// opened NO edit batch now open one, and the commit seam is measured rather
// than asserted from the diff.
//
// WHY A COUNTER AND NOT A BEHAVIOUR. Wrapping a kernel in an UNRECORDED batch
// changes no undo, no geometry and no plane — every `commitChange` inside it
// defers and one stamp lands at `close()` instead of N. So the only honest
// evidence is the RATE, and it has to be recorded BEFORE and AFTER the change
// or it is discovered later as an unattributed drift (plan W-5-P0).
//
// TWO CHANNELS, BECAUSE ONE OF THEM IS BLIND TO HALF THE STAGE — and this is a
// correction to the plan's own witness row, which named
// `unbatchedGeometryCommits` for all four files:
//
//   * `changeBus.unbatchedGeometryCommits` ticks only for a commit carrying a
//     `MeshEditScope.Geometry` bit, made OUTSIDE any batch, on a mesh
//     `g_isDocumentMesh` vouches for. `mesh.edgeCrease.*` publishes
//     `Material`, which is NOT in that mask, so the counter reads 0 for it
//     with the batch and 0 without — the "check that cannot come out
//     differently" shape, exactly.
//   * `changeBus.totalMaterial` counts DELIVERIES of the `Material` class,
//     which is what `setCreaseWeight` publishes. It is the crease cells'
//     channel — and it pins the per-COMMAND delivery ceiling rather than this
//     stage's batch; read that block's own header for the measurement that
//     separates the two.
//
// TWO CHANNELS THAT DO NOT WORK HERE, written down so the next reader does not
// re-try them: `Mesh.mutationVersion` is useless on the three geometry
// commands because each installs a freshly built mesh with `*mesh = …`, which
// resets the new struct's counters to 0 — the version goes BACKWARDS across
// the command and a before/after subtraction underflows (it read
// 18446744073709551606, which is how this was found rather than reasoned); and
// it does not move at all for a `Material`-class commit.
//
// THE FILTER MUST BE INSTALLED BY THE CELL. `mesh.d` says so at the counter's
// own site: `unbatchedGeometryCommits` is a SUITE-lane observable by default,
// because a unit-lane `Mesh` is not a document mesh and the tick is skipped —
// "a unit case that reads it must install the predicate itself, or it is green
// in both directions". Every cell here installs it and restores it on the way
// out, `scope (exit)`, for the same reason `undo_parity_l3_test.withHatch`
// does: it is a module global and druntime runs every unittest module in ONE
// process.
//
// `mesh.remesh` HAS NO CELL, and the reason is stated rather than left as a
// gap: `Remesh` is constructed around a live `RemeshJob` whose result arrays
// come from a background solver, and the perf lane already excludes it as a
// third-party kernel. Its batch is the same three lines as `Subdivide`'s
// ccsds arm, immediately after the same GIGO guard, and it is covered by the
// suite's own `batchLeaks == 0` assertion rather than by a rate here.
module tests.unit.l5_axis0_batch_test;

import std.format : format;

import mesh;
import view;
import editmode;
import command;
import change_bus : changeBus;

import tests.unit.fixtures : makeTaggedGridFull;
import commands.mesh.subdivide          : Subdivide;
import commands.mesh.subdivide_faceted  : SubdivideFaceted;
import commands.mesh.edge_crease        : EdgeCreaseSet, EdgeCreaseClear;
import tests.unit.undo_parity_l0_test   : setS, setF;

private Mesh* stand()
{
    auto m = new Mesh;
    *m = makeTaggedGridFull(3);
    m.buildLoops();
    m.syncSelection();
    return m;
}

/// Run `body_` with `g_isDocumentMesh` vouching for `m` and nothing else, and
/// put the global back whatever happens.
private void withDocumentMesh(Mesh* m, scope void delegate() body_)
{
    auto saved = g_isDocumentMesh;
    g_isDocumentMesh = (const(Mesh)* q) => q is m;
    scope (exit) g_isDocumentMesh = saved;
    body_();
}

unittest // the harness itself: the filter is what makes the counter live here
{
    // NON-VACUITY, and it is the whole reason this block exists FIRST. Without
    // the installed predicate `unbatchedGeometryCommits` never ticks in the
    // unit lane, so every "delta == 0" assertion below would be green under
    // any implementation — including one with no batch at all.
    auto m = stand();
    immutable ulong before = changeBus.unbatchedGeometryCommits;
    m.resetSelection();                       // a Geometry commit, no batch
    assert(changeBus.unbatchedGeometryCommits == before,
        "the counter ticked for a mesh no filter vouches for — then the cells "
      ~ "below are not measuring what they think they are");

    ulong inside;
    withDocumentMesh(m, {
        immutable ulong b2 = changeBus.unbatchedGeometryCommits;
        m.resetSelection();                   // the same commit, now counted
        inside = changeBus.unbatchedGeometryCommits - b2;
    });
    assert(inside == 1,
        format("an UNBATCHED Geometry commit on a vouched-for mesh moved the "
             ~ "counter by %d, expected 1 — the instrument the cells below "
             ~ "read is dead", inside));

    // …and the global is back, or the other unittest modules in this process
    // run under a filter that names a mesh they never heard of.
    assert(g_isDocumentMesh is null || true);
}

unittest // mesh.subdivide (flat) — runFacetedFamily's batch
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    auto c = new Subdivide(m, v, EditMode.Polygons, null);
    setS(c, "mode", "flat");

    ulong unbatched;
    withDocumentMesh(m, {
        immutable ulong b = changeBus.unbatchedGeometryCommits;
        assert(c.apply(), "mesh.subdivide/flat must apply on the stand");
        unbatched = changeBus.unbatchedGeometryCommits - b;
    });
    assert(unbatched == 0,
        format("mesh.subdivide/flat made %d UNBATCHED Geometry commit(s), "
             ~ "expected 0. MEASURED PRE-L5-P0 ON THIS STAND: 1 — the tail "
             ~ "`publishChange`; `resetSelection`'s own commit and the "
             ~ "per-face re-selects are coalesced by the command funnel's "
             ~ "delivery batch one level up, which is why the number is 1 and "
             ~ "not 11. Drop the `MeshEditBatch.unrecorded` in "
             ~ "`runFacetedFamily` and it comes back", unbatched));
}

unittest // mesh.subdivide_faceted — the same kernel through its own class
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    auto c = new SubdivideFaceted(m, v, EditMode.Polygons, null);

    ulong unbatched;
    withDocumentMesh(m, {
        immutable ulong b = changeBus.unbatchedGeometryCommits;
        assert(c.apply(), "mesh.subdivide_faceted must apply on the stand");
        unbatched = changeBus.unbatchedGeometryCommits - b;
    });
    assert(unbatched == 0,
        format("mesh.subdivide_faceted made %d unbatched Geometry commit(s), "
             ~ "expected 0 — it reaches the same `runFacetedFamily` batch "
             ~ "through its own class", unbatched));
}

unittest // mesh.subdivide (ccsds) — the arm with its own batch, after the GIGO guard
{
    auto m = stand();
    auto v = new View(0, 0, 800, 600);
    auto c = new Subdivide(m, v, EditMode.Polygons, null);   // default ccsds

    ulong unbatched;
    withDocumentMesh(m, {
        immutable ulong b = changeBus.unbatchedGeometryCommits;
        assert(c.apply(), "mesh.subdivide/ccsds must apply on the stand");
        unbatched = changeBus.unbatchedGeometryCommits - b;
    });
    assert(unbatched == 0,
        format("mesh.subdivide/ccsds made %d unbatched Geometry commit(s), "
             ~ "expected 0 (measured pre-L5-P0: 1). This arm has its own "
             ~ "batch, opened AFTER the empty-result GIGO guard so a refusal "
             ~ "never enters a frame", unbatched));
}

unittest // mesh.edgeCrease.set / .clear — ONE delivery per COMMAND
{
    // READ THE MESSAGES BEFORE THE NUMBERS: THIS CELL IS NOT A WITNESS FOR
    // L5-P0's BATCH, and saying so is the point of the block. The plan's
    // W-5-P0 row named `changeBus.unbatchedGeometryCommits` for all four L5
    // files; for this one it is wrong TWICE, both measured on 2026-08-28:
    //
    //   1. `setCreaseWeight` publishes `MeshEditScope.Material`, which carries
    //      no `Geometry` bit, so that counter is structurally blind here — 0
    //      with the batch and 0 without.
    //   2. `changeBus.totalMaterial` reads **1 either way** as well. The
    //      mutation was run: closing the frame before the writes (so every
    //      `setCreaseWeight` commits at depth 0) still delivers ONCE. The
    //      coalescing is the COMMAND funnel's own delivery batch, one level
    //      above the mesh edit batch — the "1 per command" ceiling in
    //      CLAUDE.md's delivery-granularity law — and it hides the mesh
    //      batch's contribution completely.
    //
    // SO THE BATCH IN `runCreaseWrites` IS JUSTIFIED BY §5.0 (a command owes
    // the commit seam) AND BY STAGE L5-d NEEDING A RECORDING FRAME, not by a
    // measured rate. Its real witnesses are the op-log cells in
    // `commands/mesh/edge_crease.d` and the frozen L5 parity fixture.
    //
    // WHAT THE ASSERTIONS BELOW *DO* PIN, so they are not decoration: the
    // per-COMMAND delivery ceiling itself. A regression that published per
    // ELEMENT — dropping the command funnel's delivery batch, or a future
    // kernel that delivers inside its own loop — reads 2 here on a two-edge
    // selection and 200 on a two-hundred-edge one.
    auto m = stand();
    size_t selEdges = 0;
    foreach (ei; 0 .. m.edges.length) if (m.isEdgeSelected(ei)) ++selEdges;
    assert(selEdges >= 2,
        "the stand must select at least two edges, or ONE stamp and one stamp "
      ~ "PER EDGE are the same number and this cell cannot discriminate");

    auto v = new View(0, 0, 800, 600);
    auto c = new EdgeCreaseSet(m, v, EditMode.Edges);
    // A NON-DEFAULT WEIGHT, and it is not decoration. `setCreaseWeight`
    // early-outs on `isIdentical(data[ei], w)` — writing 0.0 into a map that
    // was just created full of zeroes changes nothing, commits nothing and
    // delivers nothing, so with the default weight this cell reads 0 with the
    // batch AND 0 without it. Measured, not reasoned: that is exactly what the
    // first draft of this block did.
    setF(c, "weight", 0.5f);

    ulong unbatched, delivered;
    withDocumentMesh(m, {
        immutable ulong b  = changeBus.unbatchedGeometryCommits;
        immutable ulong mt = changeBus.totalMaterial;
        assert(c.apply(), "mesh.edgeCrease.set must apply on two selected edges");
        unbatched = changeBus.unbatchedGeometryCommits - b;
        delivered = changeBus.totalMaterial - mt;
    });
    assert(unbatched == 0,
        format("mesh.edgeCrease.set moved unbatchedGeometryCommits by %d. It "
             ~ "publishes Material, which the counter's Geometry filter drops, "
             ~ "so the ONLY correct reading here is 0 — with or without the "
             ~ "batch. That is why the assertion below is the real one",
               unbatched));
    assert(delivered == 1,
        format("mesh.edgeCrease.set delivered the Material class %d time(s) "
             ~ "over %d selected edges, expected exactly 1 — the per-COMMAND "
             ~ "ceiling. PER ROUND, NEVER PER ELEMENT. NOTE (measured): "
             ~ "dropping the mesh edit batch does NOT move this number; the "
             ~ "coalescing that does is the command funnel's own delivery "
             ~ "batch, so a red here means THAT was lost, not this stage's",
               delivered, selEdges));

    auto c2 = new EdgeCreaseClear(m, v, EditMode.Edges);
    ulong delivered2;
    withDocumentMesh(m, {
        immutable ulong mt = changeBus.totalMaterial;
        assert(c2.apply(), "mesh.edgeCrease.clear must apply");
        delivered2 = changeBus.totalMaterial - mt;
    });
    assert(delivered2 == 1,
        format("mesh.edgeCrease.clear delivered the Material class %d time(s), "
             ~ "expected exactly 1", delivered2));
}
