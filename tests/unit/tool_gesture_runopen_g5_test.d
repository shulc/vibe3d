// tool_gesture_runopen_g5_test — task 1905, lane G0-G5: the `runOpen` witness
// the HTTP plane fixture cannot be, for group G5 — and the NAMED census row
// that keeps this family's one legal non-recorder legible.
//
// WHAT IT PINS, and G5 is the group where that is two things rather than one.
//
//   (1) All THREE G5 record sites write through `CommandHistory.record` — the
//       primitive plan §3(B) calls `RecordMode.Plain`. `record` CONSOLIDATES an
//       open run and leaves `_runOpen` false; `recordInSession` OPENS one and
//       leaves it true. The two are one token apart at the call site, and
//       swapping them changes the SHAPE of the history without changing
//       anything a user or an HTTP client can see through the surfaces
//       `tests/test_tool_gesture_g5.d` reads.
//
//   (2) `invalidateRedo` is called FOUR times in this family — three in
//       `edge_slice_tool.d` (`latchFirstPoint`, `armChain`, `rebuildPreview`),
//       one in `loop_slice_tool.d` (`rebuildCut`) — and it is DELIBERATE, the
//       task-0429 primitive: a standing preview writes into the real mesh
//       outside the history, so a redo stepping the stack under it would replay
//       onto a mesh nobody recorded. It STAYS, and it is carried here as a
//       roster row WITH ITS COUNT, per file. A bare "there are some
//       `invalidateRedo` calls in the slice family" is indistinguishable from
//       someone having added a fifth, or having deleted the fourth; a count per
//       file is not.
//
// WHY IT IS HERE AND NOT IN THE FIXTURE. Measured, not assumed:
// `grep -rn runOpen source/http_providers.d source/http_server.d` is EMPTY —
// `runOpen()` has no HTTP surface. And the consequences that DO reach the wire
// do not separate the two record primitives: both call `pushEntry` exactly once
// behind identical gates, so on a freshly-cleared stack the depth delta is +1
// either way and every plane round-trips identically. Plan §5.4's row for this
// field says so in as many words, and it is why that row's "must stay green"
// column is `undoDelta` and every plane. Block 1 re-derives it on a live
// `CommandHistory` instead of quoting it.
//
// WHY THE CELL IS A SOURCE CENSUS AND NOT A DRIVEN COMMIT — measured, and the
// same answer the sibling lane G0-G4 reached. All three G5 commit bodies
// (`EdgeSliceTool.commitChain`, `LoopSliceTool.commitEdit`,
// `SliceTool.commitCurrentSlice`) sit after a `private:` label, and two of the
// three classes are `final` besides; D's `private` is MODULE-scope, so no test
// module and no derived class in another module can call them. Driving them
// would mean re-building the suite fixture in a unit test.
//
// WHAT THE COUNT ROW CANNOT DO, said plainly. It witnesses that the call
// EXISTS, not that it works. Block 1's second half supplies the behavioural
// half on a live history (`invalidateRedo` really empties a redo stack and
// really leaves the undo stack alone), and
// `tests/test_tool_gesture_g5.d`'s Block 2 supplies it at the earliest of the
// four SITES — the first interactive latch, which fires before the tool has
// written a vertex. The other three sites are not independently witnessable by
// behaviour: `armChain` has the shipped `tests/test_standing_preview_redo.d`
// scenario A' and `rebuildCut` its scenario A, while `rebuildPreview` cannot be
// isolated at all, because by the time any scrub runs the latch has already
// emptied the redo stack. That is why the SET is pinned by a count here.
//
// BLOCK 2 IS GONE — SUPERSEDED, AS THIS FILE SAID IT WOULD BE (task 1905,
// phase C). It counted `history.record(` per G5 file and required exactly one
// each, and it carried the `invalidateRedo` roster. All three sites now record
// through `Tool.recordGestureEdit`, so that record count is legitimately ZERO
// and the row would have been a check that cannot come out differently. The
// per-family call-surface census this file always named as its successor has
// landed — `tests/unit/tool_commit_seam_census_g5_test.d` — and it CARRIES THE
// `invalidateRedo` ROWS FORWARD, per file (3 and 1) plus the family total (4),
// with the task-0429 reason beside each and the total in the same accumulator
// rather than in front of it. It also sees strictly more than the old regex:
// `recordInSession`, `replaceInSessionTailWith`, `consolidate` and any sixth
// primitive.
//
// THE TWO MUTATIONS THIS FILE ANSWERS TO, in the NEW spelling:
//     any of the three tools, at its single seam call:
//         recordGestureEdit(cmd, GestureRecordMode.Plain);
//     ->  recordGestureEdit(cmd, GestureRecordMode.InSession);
//     any of the four legal non-recorder calls:
//         if (history !is null) history.invalidateRedo();   ->  deleted
// Expected: the census reddens — member 3 with both mode tuples for the first,
// member 2 with the file's count AND the family total for the second; Block 1
// below stays green in both cases; the plane fixture stays green on every
// plane, on `undoDelta` and on both residuals for the first, and (for the
// deletion of `latchFirstPoint`'s call) `tests/test_tool_gesture_g5.d`'s Block
// 2 reddens too. Block 1 is what stops either of those greens from being
// indifference: it re-derives on a live history that the two primitives really
// differ only in `runOpen()`, and that `invalidateRedo` really has a
// consequence.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g5_test;

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
// 1. POSITIVE CONTROL, and it is load-bearing three times over.
//
//    (a) The census next door asserts all three G5 sites dispatch
//        `GestureRecordMode.Plain`. That is worth nothing unless `record` and
//        `recordInSession` — the two primitives those modes reach — actually
//        differ in a way no wire surface shows, so drive BOTH here, on one live
//        history, and require `runOpen()` to answer differently.
//    (b) A `runOpen()` that could never answer `true` — an accessor over a
//        field nobody sets — would make the whole row vacuous. The
//        `recordInSession` arm forbids that.
//    (c) The census also carries a COUNT of `invalidateRedo`, per file and in
//        total, and two of those four sites have no behavioural witness
//        anywhere and cannot get one. A count row over a primitive that does
//        nothing would be a spelling gate, so the third arm drives
//        `invalidateRedo` on a live history and requires it to empty the redo
//        stack AND to leave the undo stack untouched. This block is the
//        non-vacuity floor UNDER that count, and it lives in a different module
//        from it deliberately: the count is text, this is behaviour.
//
//    The depth assertions sit beside them deliberately: depth is the field plan
//    §5.4's `runOpen` row predicts stays GREEN under the record-primitive
//    mutation, and having both in one block is what lets a mutation run read
//    the green half off the same output as the red one.
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

    // --- the primitive all three G5 sites are supposed to use.
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
      ~ "`tests/unit/tool_commit_seam_census_g5_test.d` would be pinning a "
      ~ "spelling with no consequence");

    // --- the primitive a one-token slip would substitute.
    auto run = h.nextRun();
    h.recordInSession(mk("InSession"), run);
    immutable size_t d2 = h.undoEntriesVisible().length;
    assert(d2 == d1 + 1,
        "control: `recordInSession` pushed " ~ (d2 - d1).to!string
      ~ " entr(ies), expected exactly 1 — this is the STAYS-GREEN half of plan "
      ~ "§5.4's `runOpen` row: both primitives push once, which is why the "
      ~ "stack depth and every plane of the G5 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion in this file is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");

    // --- the LEGAL NON-RECORDER, on a live history: it must have a consequence
    //     or the count row in Block 2 is a spelling gate.
    auto h2 = new CommandHistory();
    h2.record(mk("ToUndo"));
    assert(!h2.canRedo(),
        "control: a history with nothing undone already reports canRedo — the "
      ~ "field cannot then witness an invalidation");
    assert(h2.undo(),
        "control: undo() refused the entry just recorded, so the redo timeline "
      ~ "this arm needs was never created");
    assert(h2.canRedo(),
        "control: after an undo the redo timeline is EMPTY. Then "
      ~ "`invalidateRedo()` has nothing to kill and the assertion below is "
      ~ "satisfied for free");
    immutable size_t undoDepthBefore = h2.undoEntriesVisible().length;
    h2.invalidateRedo();
    assert(!h2.canRedo(),
        "CONTROL: `invalidateRedo()` left the redo timeline ALIVE. The four "
      ~ "calls counted by `tests/unit/tool_commit_seam_census_g5_test.d` would "
      ~ "then be a spelling with no consequence, and its named row — the ONLY "
      ~ "pin two of those four sites have — would pin nothing");
    assert(h2.undoEntriesVisible().length == undoDepthBefore,
        "control: `invalidateRedo()` also moved the UNDO stack (from "
      ~ undoDepthBefore.to!string ~ " to "
      ~ h2.undoEntriesVisible().length.to!string ~ "). It is a redo-only "
      ~ "primitive; if that changed, every slice-family gesture silently loses "
      ~ "undo entries and the plane fixture's `undoDelta` is the wrong oracle");
}
