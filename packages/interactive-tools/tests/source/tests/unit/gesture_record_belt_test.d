// gesture_record_belt_test — task 1905 phase B: the refusal belt of
// `Tool.recordGestureEdit`, and the run it must not leave open.
//
// WHY THIS FILE EXISTS AT ALL. The belt is expected to be UNREACHABLE in
// production: every tool that reaches the recorder has already filled its
// carrier, and box's live-edit site returns on `sameLiveEdit` before it ever
// builds one. A branch nobody drives, guarded by a counter nobody moves, is
// the shape this project pays for most — green before the fix, green after
// it, green again when the fix is reverted. So the belt gets a cell that
// DRIVES it, on a hand-built carrier, and reads BOTH halves of the contract:
// the counter moved AND the stack did not.
//
// THE FOUR THINGS PINNED, and each one has a mutation that reddens only it:
//
//   1. POSITIVE CONTROL FIRST. A FILLED carrier records: `recordGestureEdit`
//      answers true, the stack grows by exactly one, and neither counter
//      moves. Without this block every "== 0" below is satisfiable by a
//      recorder that refuses everything, and every "did not move" by a stack
//      that never moves.
//        M: delete the `history.record(cmd)` line from `GestureRecordMode.Plain`
//           -> block 1 reddens on the depth assertion.
//
//   2. THE EMPTY CARRIER. A `MeshSessionEdit` that was constructed and never
//      filled answers `hasGesturePayload() == false` (no delta installed, no
//      `after` captured). The belt refuses it, ticks
//      `changeBus.gestureRecordEmptyPayload`, and the stack is untouched.
//        M: change the belt to `if (false)` -> the counter assertion reddens;
//           the depth assertion reddens too, in the same block, and they are
//           separate asserts so the message says which came first.
//
//   3. THE WRONG CLASS. A `Command` that does not implement `GesturePayload`
//      at all is a MIS-BOUND FACTORY, not an empty edit, and it ticks the
//      OTHER counter. Reading a null cast as "empty" would be the worst
//      outcome available here — the mesh is already mutated and the history
//      would be silent about it — so the two counters are asserted
//      independently in both blocks: block 2 must not move this one and block
//      3 must not move that one.
//        M: fold the two counters into one -> block 2's "mismatch stayed 0"
//           or block 3's "empty stayed 0" reddens.
//
//   4. THE RUN THE BELT MUST CLOSE. `replaceInSessionTailWith` closes the open
//      run on EVERY early return of its own (`scope(exit) _runOpen = false`).
//      A belt that refuses BEFORE that call skips the only site that was going
//      to close it. Block 4 opens a real run with `recordInSession`, refuses a
//      `ReplaceRunTail` record through the belt, and asserts `runOpen()` is
//      false afterwards — with a positive control one line above proving the
//      accessor can answer true at all.
//        M: delete the `consolidate` call from `refuseGestureRecord` -> block
//           4's `runOpen()` assertion reddens and nothing else in this file
//           does (blocks 1-3 use `Plain`, which never had a run to close).
//
// LANE: `dub test --config=tests`.
module tests.unit.gesture_record_belt_test;

import change_bus       : changeBus;
import command          : Command, CmdFlags;
import command_history  : CommandHistory;
import commands.mesh.gesture_payload : GesturePayload;
import commands.mesh.session_edit    : MeshSessionEdit;
import editmode         : EditMode;
import math             : Vec3;
import mesh             : Mesh;
import mesh_edit_delta  : MeshEditScope;
import snapshot         : MeshSnapshot;
import tool             : Tool, GestureRecordMode;
import view             : View;

import std.conv : to;

/// The smallest possible `Tool`: it exists only to re-expose the `protected`
/// recorder and the `protected` bindings. No production body is stubbed out —
/// `recordGestureEdit` below IS the shipped one.
private final class ProbeGestureTool : Tool {
    override string name() const { return "probe.gesture"; }

    bool probeRecord(Command cmd, GestureRecordMode mode) {
        return recordGestureEdit(cmd, mode);
    }
}

/// A carrier that does NOT implement `GesturePayload`. Deliberately undoable
/// and otherwise well-formed, so the only thing separating it from a real
/// payload is the missing interface.
private final class NoInterfaceCommand : Command {
    this(Mesh* m, View v, EditMode em) { super(m, v, em); }
    override string name()  const { return "probe.no_interface"; }
    override string label() const { return "Probe No Interface"; }
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect | CmdFlags.UndoForce; }
    protected override bool applyImpl()  { return true; }
    protected override void revertImpl() {}
}

private Mesh makeTri() {
    Mesh m;
    m.addVertex(Vec3(0, 0, 0));
    m.addVertex(Vec3(1, 0, 0));
    m.addVertex(Vec3(0, 1, 0));
    m.addFace([0, 1, 2]);
    m.buildLoops();
    return m;
}

private MeshSessionEdit blankCarrier(Mesh* m, View v) {
    return new MeshSessionEdit(m, v, EditMode.Vertices,
                               "probe.session_edit", "Probe",
                               MeshEditScope.Geometry);
}

private string s(T)(T n) { return n.to!string; }

// ---------------------------------------------------------------------------
// 0. POSITIVE CONTROL FIRST — a FILLED carrier goes all the way through.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    auto t = new ProbeGestureTool();
    t.setGestureBindings(h, () => cast(Command) blankCarrier(&m, v));

    auto cmd = blankCarrier(&m, v);
    auto pre = MeshSnapshot.capture(m);
    m.addVertex(Vec3(2, 0, 0));
    m.buildLoops();
    auto post = MeshSnapshot.capture(m);
    cmd.setSnapshots(pre, post, "Probe");

    assert(cmd.hasGesturePayload(),
        "CONTROL: a carrier holding a captured before/after pair answers "
      ~ "`hasGesturePayload() == false`. The predicate cannot then distinguish "
      ~ "a filled carrier from an empty one, and every refusal below is "
      ~ "satisfied by a belt that refuses everything");

    immutable ulong empty0    = changeBus.gestureRecordEmptyPayload;
    immutable ulong mismatch0 = changeBus.gestureCarrierMismatch;
    immutable size_t depth0   = h.undoEntriesVisible().length;

    assert(t.probeRecord(cmd, GestureRecordMode.Plain),
        "CONTROL: `recordGestureEdit` refused a FILLED carrier. Nothing below "
      ~ "measures a belt then — it measures a recorder that never records");

    assert(h.undoEntriesVisible().length == depth0 + 1,
        "CONTROL: the filled carrier moved the stack by "
      ~ s(h.undoEntriesVisible().length - depth0) ~ ", expected exactly 1 — "
      ~ "the 'stack did not move' assertions below are worthless over a stack "
      ~ "that never moves");
    assert(changeBus.gestureRecordEmptyPayload == empty0,
        "CONTROL: recording a filled carrier ticked the EMPTY-PAYLOAD counter");
    assert(changeBus.gestureCarrierMismatch == mismatch0,
        "CONTROL: recording a filled carrier ticked the CARRIER-MISMATCH counter");
}

// ---------------------------------------------------------------------------
// 1. THE BELT — an unfilled carrier is refused, counted, and does not move the
//    stack.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    auto t = new ProbeGestureTool();
    t.setGestureBindings(h, () => cast(Command) blankCarrier(&m, v));

    auto cmd = blankCarrier(&m, v);   // constructed, never filled
    assert(!cmd.hasGesturePayload(),
        "CONTROL: a carrier with neither a delta nor a captured `after` "
      ~ "answers `hasGesturePayload() == true`. Then this block drives the "
      ~ "SUCCESS path and its refusal assertions are vacuous");

    immutable ulong empty0    = changeBus.gestureRecordEmptyPayload;
    immutable ulong mismatch0 = changeBus.gestureCarrierMismatch;
    immutable size_t depth0   = h.undoEntriesVisible().length;

    assert(!t.probeRecord(cmd, GestureRecordMode.Plain),
        "the belt ACCEPTED a carrier that holds nothing to roll back");

    assert(changeBus.gestureRecordEmptyPayload == empty0 + 1,
        "the empty-payload belt refused without counting: the counter moved by "
      ~ s(changeBus.gestureRecordEmptyPayload - empty0) ~ ", expected 1. A "
      ~ "silent refusal here is an edit with no undo entry and nothing that "
      ~ "says so — the mesh is already mutated by the time a tool commits");
    assert(changeBus.gestureCarrierMismatch == mismatch0,
        "an EMPTY payload was counted as a MIS-BOUND FACTORY. Two different "
      ~ "faults with two different fixes; summing them makes both unreadable");
    assert(h.undoEntriesVisible().length == depth0,
        "the belt refused and the stack still moved by "
      ~ s(h.undoEntriesVisible().length - depth0)
      ~ " — 'refuse' has to mean the history is untouched");
}

// ---------------------------------------------------------------------------
// 2. THE WRONG CLASS — a carrier that never declared `GesturePayload`.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    auto t = new ProbeGestureTool();
    t.setGestureBindings(h, () => cast(Command) blankCarrier(&m, v));

    auto cmd = new NoInterfaceCommand(&m, v, EditMode.Vertices);
    assert((cast(GesturePayload) cmd) is null,
        "CONTROL: the probe command implements `GesturePayload` after all, so "
      ~ "this block drives the empty-payload arm instead of the mismatch one");

    immutable ulong empty0    = changeBus.gestureRecordEmptyPayload;
    immutable ulong mismatch0 = changeBus.gestureCarrierMismatch;
    immutable size_t depth0   = h.undoEntriesVisible().length;

    assert(!t.probeRecord(cmd, GestureRecordMode.Plain),
        "the recorder ACCEPTED a command that does not declare "
      ~ "`GesturePayload`. It cannot have asked whether the payload is there");

    assert(changeBus.gestureCarrierMismatch == mismatch0 + 1,
        "a mis-bound carrier was not counted: the mismatch counter moved by "
      ~ s(changeBus.gestureCarrierMismatch - mismatch0) ~ ", expected 1");
    assert(changeBus.gestureRecordEmptyPayload == empty0,
        "a MIS-BOUND FACTORY was counted as an EMPTY PAYLOAD. Reading a null "
      ~ "cast as 'nothing to record' is the one outcome worse than a loud "
      ~ "refusal — the registration is wrong and the number says the edit was");
    assert(h.undoEntriesVisible().length == depth0,
        "the mismatch refusal still moved the stack by "
      ~ s(h.undoEntriesVisible().length - depth0));
}

// ---------------------------------------------------------------------------
// 3. THE RUN THE BELT MUST CLOSE (round 4, fix 3).
//
//    `replaceInSessionTailWith` starts with `scope(exit) _runOpen = false`, so
//    every one of ITS early returns closes the run. A belt that refuses before
//    that call is therefore the only path that can leave a run standing open —
//    and an open run is not inert: the next foreign `record` consolidates INTO
//    a gesture that was never committed.
// ---------------------------------------------------------------------------
unittest {
    auto m = makeTri();
    auto v = new View(0, 0, 800, 600);
    auto h = new CommandHistory();
    auto t = new ProbeGestureTool();
    t.setGestureBindings(h, () => cast(Command) blankCarrier(&m, v));

    assert(!h.runOpen(),
        "CONTROL: a fresh CommandHistory already reports an OPEN run — the "
      ~ "accessor is not reading the flag this block pins");

    // Open a real run the way box's live ladder does: an in-session record.
    auto run  = h.nextRun();
    auto live = blankCarrier(&m, v);
    auto pre  = MeshSnapshot.capture(m);
    m.addVertex(Vec3(3, 0, 0));
    m.buildLoops();
    live.setSnapshots(pre, MeshSnapshot.capture(m), "Probe live");
    assert(t.probeRecord(live, GestureRecordMode.InSession),
        "CONTROL: the in-session record was refused, so no run is open and "
      ~ "the assertion below cannot tell a closing belt from a no-op");
    assert(h.runOpen(),
        "CONTROL: `recordInSession` did NOT leave the run open. `runOpen()` "
      ~ "then cannot answer `true` at all, and the `== false` below is "
      ~ "satisfied for free — under the mutation as much as without it");

    immutable size_t depth0 = h.undoEntriesVisible().length;

    // Now the splice refuses at the belt.
    auto empty = blankCarrier(&m, v);
    assert(!t.probeRecord(empty, GestureRecordMode.ReplaceRunTail),
        "the belt accepted an empty carrier on the splice path");

    assert(!h.runOpen(),
        "the belt refused a `ReplaceRunTail` record and LEFT THE RUN OPEN. "
      ~ "The primitive it skipped closes the run on every early return of its "
      ~ "own (`scope(exit) _runOpen = false`), so refusing above that call is "
      ~ "the only way to leak one — and the next foreign `record` will "
      ~ "consolidate itself into a gesture that was never committed");

    assert(h.undoEntriesVisible().length == depth0,
        "closing the run on refusal moved the stack by "
      ~ s(h.undoEntriesVisible().length - depth0) ~ ", expected 0. `consolidate` "
      ~ "is used here precisely because it only closes and re-tags what is "
      ~ "already on the stack; calling the splice primitive instead would take "
      ~ "its APPEND arm and push an entry for an empty payload");

    assert(run == h.currentRunId,
        "the refusal path advanced the run id; it must close the run, not "
      ~ "start a new one");
}
