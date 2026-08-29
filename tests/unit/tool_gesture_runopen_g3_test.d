// tool_gesture_runopen_g3_test — task 1905, lane G0-G3: the `runOpen` witness
// the HTTP plane fixture cannot be, for group G3.
//
// WHAT IT PINS. Both G3 record sites write through `CommandHistory.record` —
// the primitive plan §3(B) calls `RecordMode.Plain`. `record` CONSOLIDATES an
// open run and leaves `_runOpen` false; `recordInSession` OPENS one and leaves
// it true. The two are one token apart at the call site, and swapping them
// changes the SHAPE of the history without changing anything a user or an HTTP
// client can see through the surfaces `tests/test_tool_gesture_g3.d` reads.
//
// WHY IT IS HERE AND NOT IN THE FIXTURE. Measured, not assumed:
// `grep -rn runOpen source/http_providers.d source/http_server.d` is EMPTY —
// `runOpen()` has no HTTP surface, so no fixture driven over the wire can read
// it. And the consequences that DO reach the wire do not separate the two
// branches: `record` and `recordInSession` both call `pushEntry` exactly once
// behind identical gates, so on a freshly-cleared stack the depth delta is +1
// either way and every plane round-trips identically. Plan §5.4's row for this
// field says so in as many words, and it is why the row's "must stay green"
// column is `undoDelta` and every plane. Block 1 below re-derives that claim on
// a live `CommandHistory` instead of quoting it.
//
// WHY THE CELL IS A SOURCE CENSUS AND NOT A DRIVEN COMMIT — measured, and it
// is the same answer the sibling lane G0-G4 reached for its own group. Both
// G3 commit bodies (`SmoothShiftTool.commitEdit`,
// `StrokeExtrudeTool.commitEdit`) sit after a `private:` label, and D's
// `private` is MODULE-scope: no test module and no derived class in another
// module can call them. Driving them would mean re-building the suite fixture
// in a unit test. So this file pins the PRIMITIVE at both sites by reading
// them, and Block 1 supplies the behavioural half the reading cannot: that
// `record` and `recordInSession` really do differ in `runOpen()`, and really
// do agree on the stack depth.
//
// BLOCK 2 IS GONE — SUPERSEDED, AS THIS FILE SAID IT WOULD BE (task 1905,
// phase C). It counted `history.record(` per G3 file and required exactly one
// each. Both sites now record through `Tool.recordGestureEdit`, so that count
// is legitimately ZERO and the row would have been a check that cannot come out
// differently. The per-family call-surface census this file always named as its
// successor has landed — `tests/unit/tool_commit_seam_census_g3_test.d` — and it
// keys on the WHOLE `history.<NAME>(` multiset over the deform directory plus
// `source/tool.d`, per file, with a reason per rostered name. It sees strictly
// more: `recordInSession`, `replaceInSessionTailWith`, `consolidate` and any
// sixth primitive, none of which the old regex knew.
//
// THE MUTATION THIS FILE ANSWERS TO, in the NEW spelling:
//     either G3 tool, at its single seam call:
//         recordGestureEdit(cmd, GestureRecordMode.Plain);
//     ->  recordGestureEdit(cmd, GestureRecordMode.InSession);
// Expected: the census's member 3 reddens with both mode tuples; Block 1 below
// stays green; `tests/test_tool_gesture_g3.d` stays green on every plane, on
// `undoDelta` and on both residuals — which is the whole reason Block 1 exists,
// because that green is not indifference, it is the measured fact that no wire
// surface separates the two primitives.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g3_test;

import std.conv    : to;

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
// 1. POSITIVE CONTROL, and it is load-bearing twice over.
//
//    (a) The census next door asserts both G3 sites dispatch
//        `GestureRecordMode.Plain`. That is worth nothing unless `record` and
//        `recordInSession` — the two primitives those modes reach — actually
//        differ in a way no wire surface shows, so drive BOTH here, on one live
//        history, and require `runOpen()` to answer differently.
//    (b) A `runOpen()` that could never answer `true` — an accessor over a
//        field nobody sets — would make the whole row vacuous. The
//        `recordInSession` arm below is what forbids that.
//
//    The depth assertions sit beside them deliberately: depth is the field
//    plan §5.4's row predicts stays GREEN under the mutation, and having both
//    in one block is what lets a mutation run read the green half off the same
//    output as the red one.
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

    // --- the primitive both G3 sites are supposed to use.
    immutable size_t d0 = h.undoEntriesVisible().length;
    h.record(mk("Plain"));
    immutable size_t d1 = h.undoEntriesVisible().length;
    assert(d1 == d0 + 1,
        "control: `record` pushed " ~ (d1 - d0).to!string ~ " entr(ies), "
      ~ "expected exactly 1");
    assert(!h.runOpen(),
        "control: `record` left an OPEN run. Then the whole premise is gone: "
      ~ "the two primitives would be indistinguishable on the property this "
      ~ "file pins, and the mode roster in "
      ~ "`tests/unit/tool_commit_seam_census_g3_test.d` would be pinning a "
      ~ "spelling with no consequence");

    // --- the primitive a one-token slip would substitute.
    auto run = h.nextRun();
    h.recordInSession(mk("InSession"), run);
    immutable size_t d2 = h.undoEntriesVisible().length;
    assert(d2 == d1 + 1,
        "control: `recordInSession` pushed " ~ (d2 - d1).to!string
      ~ " entr(ies), expected exactly 1 — this is the STAYS-GREEN half of plan "
      ~ "§5.4's `runOpen` row: both primitives push once, which is why the "
      ~ "stack depth and every plane of the G3 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion in this file is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");
}
