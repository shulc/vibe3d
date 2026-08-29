// tool_gesture_runopen_g7_test — task 1905, group G7 (the topology-pen family):
// the BEHAVIOURAL witness the HTTP plane fixture cannot be.
//
// WHAT THIS FILE PINS, AND WHY IT IS THE ONLY BLOCK LEFT. Both G7 record sites
// — the RAW one in `TopologyPenTool.placeVertexAt` and the shared tail
// `TopologyPenTool.recordSnapshotUndo` — go through
// `Tool.recordGestureEdit(cmd, GestureRecordMode.Plain)`, which dispatches to
// `CommandHistory.record`. `record` CONSOLIDATES an open run and leaves
// `_runOpen` false; `recordInSession` OPENS one and leaves it true. The two are
// one enum member apart at the call site, and swapping them changes the SHAPE
// of the history without changing anything a user or an HTTP client can see
// through the surfaces `tests/test_tool_gesture_g7.d` reads.
//
// WHY THAT IS HERE AND NOT IN THE FIXTURE. Measured, not assumed:
// `grep -rn runOpen source/http_providers.d source/http_server.d` is EMPTY —
// `runOpen()` has no HTTP surface, so no fixture driven over the wire can read
// it. And the consequences that DO reach the wire do not separate the two
// branches: `record` and `recordInSession` both call `pushEntry` exactly once
// behind identical gates, so on a freshly-cleared stack the depth delta is +1
// either way and every plane round-trips identically. Plan §5.4's row for this
// field says so in as many words, and it is why the row's "must stay green"
// column is `undoDelta` and every plane. Lane G0-G7 then ran that mutation and
// measured the fixture GREEN under it (`Total: 1 Passed: 1`, all six cells, all
// fields). The block below re-derives the claim on a live `CommandHistory`
// instead of quoting it.
//
// WHAT LEFT, AND WHERE IT WENT (task 1905 phase D, group G7's migration lane).
// This file shipped with three blocks; two of them were text censuses and both
// now live in `tests/unit/tool_commit_seam_census_g7_test.d`:
//
//   * Block 2 — "the package calls `history.record(` exactly twice, both in
//     tool.d" — is SUPERSEDED by that file's members 2 and 3, exactly as this
//     header always said it would be ("when that file lands it supersedes Block
//     2"). The successor is strictly wider: the whole history call surface with
//     a reason beside every legal name, plus the seam's own call sites AND
//     their modes, instead of one hand-written name.
//   * Block 3 — the positional binding of the thirteen factories — MOVED to
//     that file's member 7. This header used to call it "independent"; phase D
//     disagreed for a measured reason. The binder it parses
//     (`setUndoBindings` -> `setPenFactories`) is the declaration phase D
//     reshaped, so the two files had to be edited in step anyway, and two
//     rosters over ONE binding surface is precisely the merge hazard that made
//     the census per-family in the first place. Nothing was weakened: member 7
//     carries the same composed chain, the same thirteen frozen triples, the
//     same swap probe — with its three anti-vacuity controls folded INTO the
//     accumulator instead of standing as bare asserts ahead of the raise, where
//     they would abort the module and swallow the position rows they exist to
//     accompany.
//
// THE MUTATION THIS FILE ANSWERS TO, and it is the block's own premise rather
// than a claim about the pen: make `runOpen()` unable to answer `true` — an
// accessor over a field nobody sets. Then the census's mode roster is pinning a
// spelling with no consequence, and the CONTROL assert below is the only thing
// in either lane that says so.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g7_test;

import std.conv : to;

import command_history : CommandHistory;
import commands.mesh.session_edit : MeshSessionEdit;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh;
import mesh_edit_delta : MeshEditScope;
import snapshot : MeshSnapshot;
import view : View;

private Mesh makeQuad() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(1, 0, 1));
    m.addVertex(Vec3(0, 0, 1));
    m.addFace([0u, 1u, 2u, 3u]);
    m.buildLoops();
    return m;
}

// ---------------------------------------------------------------------------
// POSITIVE CONTROL, and it is load-bearing twice over.
//
//    (a) The G7 census asserts both seam sites carry `GestureRecordMode.Plain`.
//        That is worth nothing unless `record` and `recordInSession` actually
//        differ in a way no wire surface shows — so drive BOTH here, on one live
//        history, and require `runOpen()` to answer differently.
//    (b) A `runOpen()` that could never answer `true` — an accessor over a
//        field nobody sets — would make the whole row vacuous. The
//        `recordInSession` arm below is what forbids that.
//
//    The depth assertions sit beside them deliberately: depth is the field plan
//    §5.4's row predicts stays GREEN under the mutation, and having both in one
//    block is what lets a mutation run read the green half off the same output
//    as the red one.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeQuad();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();

    assert(!h.runOpen(),
        "control: a fresh CommandHistory reports an OPEN run — the accessor is "
      ~ "not reading the flag this file pins");

    MeshSessionEdit mk(string label) {
        auto cmd = new MeshSessionEdit(&m, v, EditMode.Polygons,
                                       "probe.session_edit", label,
                                       MeshEditScope.Geometry);
        auto pre = MeshSnapshot.capture(m);
        m.addVertex(Vec3(2, 0, 0));
        auto post = MeshSnapshot.capture(m);
        cmd.setSnapshots(pre, post, label);
        return cmd;
    }

    // --- the primitive both G7 sites are supposed to use.
    immutable size_t d0 = h.undoEntriesVisible().length;
    h.record(mk("Plain"));
    immutable size_t d1 = h.undoEntriesVisible().length;
    assert(d1 == d0 + 1,
        "control: `record` pushed " ~ (d1 - d0).to!string ~ " entr(ies), "
      ~ "expected exactly 1");
    assert(!h.runOpen(),
        "control: `record` left an OPEN run. Then the G7 census's mode roster "
      ~ "has lost its premise: the two primitives would be indistinguishable on "
      ~ "the property this file pins, and that roster would be pinning a "
      ~ "spelling with no consequence");

    // --- the primitive a one-member slip would substitute.
    auto run = h.nextRun();
    h.recordInSession(mk("InSession"), run);
    immutable size_t d2 = h.undoEntriesVisible().length;
    assert(d2 == d1 + 1,
        "control: `recordInSession` pushed " ~ (d2 - d1).to!string
      ~ " entr(ies), expected exactly 1 — this is the STAYS-GREEN half of plan "
      ~ "§5.4's `runOpen` row: both primitives push once, which is why the "
      ~ "stack depth and every plane of the G7 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion in this file is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");
}
