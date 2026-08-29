// tool_gesture_runopen_g4_test — task 1905: the BEHAVIOURAL half of the
// `runOpen` witness for group G4. Lane G0-G4 built this file with two blocks;
// phase C (lane `gesture-g4-seam`, task 3200) removed the second, and this
// header says why in the place the removal happened.
//
// WHAT REMAINS, AND WHY IT IS NOT REDUNDANT. G4's eleven record sites now write
// through ONE seam, `Tool.recordGestureEdit(cmd, GestureRecordMode.Plain)`,
// whose `Plain` arm dispatches to `CommandHistory.record`. `record`
// CONSOLIDATES an open run and leaves `_runOpen` false; `recordInSession`
// OPENS one and leaves it true. Every text census in the tree — G0-G4's old
// Block 2, and now `tests/unit/tool_commit_seam_census_g4_test.d` — asserts
// that the family spells the FIRST one. That assertion is worth nothing unless
// the two primitives actually differ in a way no wire surface shows, and
// nothing but a live `CommandHistory` can establish that. This block does.
//
// WHY NO WIRE SURFACE SHOWS IT. Measured, not assumed:
// `grep -rn runOpen source/http_providers.d source/http_server.d` is EMPTY —
// `runOpen()` has no HTTP surface, so no fixture driven over the wire can read
// it. And the consequences that DO reach the wire do not separate the two
// branches: `record` and `recordInSession` both call `pushEntry` exactly once
// behind identical gates, so on a freshly-cleared stack the depth delta is +1
// either way and every plane round-trips identically. Plan §5.4's row for this
// field says so in as many words, and it is why the row's "must stay green"
// column is `undoDelta` and every plane. The block below re-derives that claim
// on a live `CommandHistory` instead of quoting it — it is the STAYS-GREEN half
// of the row, and it is what makes the red half meaningful.
//
// WHY THE TEXT HALF LEFT THIS FILE. Not tidiness: two censuses over the same
// eleven files, with two rosters, is the shape lane G0-G1 named as the merge
// hazard — one of the two gets updated and the other silently goes on pinning
// last month's tree. Block 2's own header said the per-family census of plan
// §5.1 supersedes it "when that file lands". It landed. The successor is
// strictly wider: it reads the WHOLE history call surface of the family
// (not just `record`), it counts the seam's call sites and their modes, it
// checks the eleven registrations, and it derives its file set from a
// directory walk instead of a hand-written roster.
//
// WHY THE PIN IS STILL NOT A DRIVEN COMMIT — measured, and it is a real
// difference from the sibling lane G0-G1. There, the create family's commit
// body (`PrimitiveCreateTool.commitEdit`) is `protected`, so a derived probe
// class could call it. In G4 every one of the eight `commitEdit()` bodies sits
// after a `private:` label, and D's `private` is MODULE-scope: no test module
// and no derived class in another module can call them. The remaining three
// sites are a `private` `commitBridgeEdit`, a `private` `commitTackEdit`, and
// a record INLINED in `DragWeldTool.onMouseButtonUp`. The behavioural witness
// of the eleven sites is therefore the frozen plane fixture
// `tests/fixtures/tool_gesture/g4.json` (read by
// `tests/test_tool_gesture_g4.d`), driven over `/api/play-events`.
//
// THE MUTATION THIS FILE ANSWERS TO — and it is this file's OWN mutation, not
// the seam's: make `runOpen()` return a constant. Either arm below reddens with
// its own message, which is what forbids a witness that can only ever answer
// one way.
//
// LANE: `dub test --config=tests`.
module tests.unit.tool_gesture_runopen_g4_test;

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
//    (a) The family census asserts every G4 site reaches the seam's `Plain`
//        arm. That is worth nothing unless `record` and `recordInSession`
//        actually differ in a way no wire surface shows — so drive BOTH here,
//        on one live history, and require `runOpen()` to answer differently.
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

    // --- the primitive every G4 site is supposed to use.
    immutable size_t d0 = h.undoEntriesVisible().length;
    h.record(mk("Plain"));
    immutable size_t d1 = h.undoEntriesVisible().length;
    assert(d1 == d0 + 1,
        "control: `record` pushed " ~ (d1 - d0).to!string ~ " entr(ies), "
      ~ "expected exactly 1");
    assert(!h.runOpen(),
        "control: `record` left an OPEN run. Then the whole premise is gone: "
      ~ "the two primitives would be indistinguishable on the property this "
      ~ "file pins, and `tool_commit_seam_census_g4_test.d` would be pinning a "
      ~ "spelling with no consequence");

    // --- the primitive a one-token slip would substitute.
    auto run = h.nextRun();
    h.recordInSession(mk("InSession"), run);
    immutable size_t d2 = h.undoEntriesVisible().length;
    assert(d2 == d1 + 1,
        "control: `recordInSession` pushed " ~ (d2 - d1).to!string
      ~ " entr(ies), expected exactly 1 — this is the STAYS-GREEN half of plan "
      ~ "§5.4's `runOpen` row: both primitives push once, which is why the "
      ~ "stack depth and every plane of the G4 fixture cannot see the swap");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "therefore cannot distinguish the two record primitives, and every "
      ~ "assertion in this file is satisfied by an accessor that can only ever "
      ~ "answer false — under the mutation as much as without it");
}
