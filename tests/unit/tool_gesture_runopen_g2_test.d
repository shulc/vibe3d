// tool_gesture_runopen_g2_test — task 1905: the behavioural control the G2
// plane fixture cannot be. One block, and it is a POSITIVE CONTROL.
//
// WHAT IT PINS. That `CommandHistory.record` and `CommandHistory.recordInSession`
// genuinely differ in a way NOTHING a user or an HTTP client can see: both push
// exactly one entry, so on a freshly-cleared stack the depth delta is +1 either
// way and every mesh plane round-trips identically — but only the second leaves
// `runOpen()` true. Plan §5.4's row for this field says so in as many words,
// which is why its "must stay green" column is `undoDelta` and every plane.
// This block re-derives that claim on a live `CommandHistory` instead of
// quoting it.
//
// WHY IT IS HERE AND NOT IN THE FIXTURE. Measured, not assumed:
// `grep -rn runOpen source/http_providers.d source/http_server.d` is EMPTY —
// `runOpen()` has no HTTP surface, so no fixture driven over the wire can read
// it.
//
// WHAT IT CONTROLS FOR, after task 1905 phase C. All five G2 sites now record
// through `Tool.recordGestureEdit(cmd, GestureRecordMode.Plain)`. The
// one-token slip that used to be `history.record(` -> `history.recordInSession(`
// is now `GestureRecordMode.Plain` -> `.InSession`, and the member that catches
// it is the per-file mode triple in
// `tests/unit/tool_commit_seam_census_g2_test.d` (member 3). That member is a
// TEXT count; it is worth nothing unless the two modes actually lead somewhere
// different, and this block is what says they do.
//
// BLOCK 2 IS GONE, DELIBERATELY, AND THIS FILE SAID SO IN ADVANCE. Its own
// header (written by the G0-G2 fixture lane) read: "When that file lands it
// supersedes Block 2; Block 1 is independent of it." Block 2 was a directory
// census counting `history.record(` once per G2 file. After phase C there is no
// `history.record(` left in `source/tools/alignment/` to count — the whole point
// of the migration — so the block would have had to be rewritten into exactly
// the per-family census that now exists, in a file that keys on the WHOLE call
// surface rather than one name, walks the same directory, and carries the
// transform zone's two named zeros. Keeping a second, weaker copy here would be
// two rosters to update and one of them would rot.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g2_test;

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
//   (a) The G2 census asserts every site spells `GestureRecordMode.Plain`. That
//       is worth nothing unless `Plain` and `InSession` reach primitives that
//       actually differ in a way no wire surface shows — so drive BOTH here, on
//       one live history, and require `runOpen()` to answer differently.
//   (b) A `runOpen()` that could never answer `true` — an accessor over a field
//       nobody sets — would make the whole row vacuous. The `recordInSession`
//       arm below is what forbids that.
//
// The depth assertions sit beside them deliberately: depth is the field plan
// §5.4's row predicts stays GREEN under the mutation, and having both in one
// block is what lets a mutation run read the green half off the same output as
// the red one.
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

    // --- the primitive every G2 site is supposed to reach (mode `Plain`).
    immutable size_t d0 = h.undoEntriesVisible().length;
    h.record(mk("Plain"));
    immutable size_t d1 = h.undoEntriesVisible().length;
    assert(d1 == d0 + 1,
        "control: `record` pushed " ~ (d1 - d0).to!string ~ " entr(ies), "
      ~ "expected exactly 1");
    assert(!h.runOpen(),
        "control: `record` left an OPEN run. Then the G2 census's whole premise "
      ~ "is gone: the two primitives would be indistinguishable on the property "
      ~ "this file pins, and its mode triple would be pinning a spelling with no "
      ~ "consequence");

    // --- the primitive a one-token slip would substitute (mode `InSession`).
    auto run = h.nextRun();
    h.recordInSession(mk("InSession"), run);
    immutable size_t d2 = h.undoEntriesVisible().length;
    assert(d2 == d1 + 1,
        "control: `recordInSession` pushed " ~ (d2 - d1).to!string
      ~ " entr(ies), expected exactly 1 — this is the STAYS-GREEN half of plan "
      ~ "§5.4's `runOpen` row: both primitives push once, which is why the "
      ~ "stack depth and every plane of the G2 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion resting on the census's mode triple is satisfied by an "
      ~ "accessor that can only ever answer false — under the mutation as much "
      ~ "as without it");
}
