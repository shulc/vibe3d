// tool_session_steps_test — slice M3 of the tool session model
// (doc/tool_session_model_plan_2026-09-24.md R4.3, R4.5, R2.2): the session's
// own steps, driven through the PRODUCTION `EditSession` bound to a stand-in
// tool exactly as the arm door binds one (`noteArm`).
//
// (1) `armDoorFor` over every arm transition (the door of C-H1-door, gap 300).
// (2) Steps: the first gesture opens the window (`firstPress`); later gestures
//     are image steps; undo restores the image a step started from (H2) and
//     rebuilds once; redo returns it live (H4); a new step clears the redo.
// (3) The first group: with no activation row of this arm on top (a script
//     arm, or rule K) the tool stays and the image goes back to the window's
//     open image; with a key-door row of this arm, the row is popped with it,
//     and the NAVIGATE redo replays the group once (S7: a raw undo between two
//     navigate redos gets a bare re-arm).
// (4) `OpensAt.arm`: the arm is the first group; the rest of the arming press
//     is a step only if it changed the image; a second arm starts afresh.
// (5) Closes: an Action parameter write is its own step (C-H2-ls-insert); the
//     tool's own Enter goes through the one close routine; a tool-reported end
//     drops the account.
// (6) `Param.PodArray`: raw snapshot/restore by element size, a GC pointer
//     inside an element survives a collection, the kind is not injectable, is
//     not sticky, reads back as its count; and every consumer site of the
//     array kinds has a PodArray arm (opponent R3 C4).
// (7) Slice M4: a close marks the row it WROTE with the closing session's token
//     (the door's row under a switch, nothing when nothing was written — C2);
//     that session's first-operation record pops with the activation row it
//     carries, and redoes with it (not across a new session, a script row or a
//     non-carrying policy); a restored predecessor adopts its token;
//     `keepAliveOnCancel` is data; Shift through the session closes and resets
//     the haul; `ifChanged` steps.
// Fast loop: tools/local/ut-standalone.sh tests/unit/tool_session_steps_test.d
module tests.unit.tool_session_steps_test;

import command_history : CommandHistory, HistoryFlags, UndoState;
import commands.tool.lifecycle : ToolActivationCommand, ToolTaskClearCommand;
import edit_session : DropRowSpec, EditSession, ParameterChangeSource, ParameterChangePhase;
import editmode : EditMode;
import mesh : Mesh, makeCube;
import math : Vec3;
import params;
import tool : AttrImage, OpensAt, PressActivation, PressKind, StepOrigin, Tool, ToolSessionPolicy,
    TopologyStepClient;
import command : Command;
import snapshot : MeshSnapshot;
import tool_activation_ownership;
import view : View;

import std.algorithm : canFind, count;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.traits : EnumMembers;

// Wave plan 8646 §9.25 [A13-2], restore-copies: the premise the session's
// image reuse rests on (cells at the end of this module). First in the module
// so an aliasing `restore` reddens HERE, not in a later cell's symptom.
unittest { // restore-copies: `restore` never aliases the image
    Mesh m = makeCube();
    auto snap = MeshSnapshot.capture(m);
    m.vertices[0].y += 1.0f;
    snap.restore(m);
    assert(snap.matches(m), "8646 restore: rig floor, the restore put the image back");
    assert(m.vertices.ptr !is snap.vertices.ptr && m.edges.ptr !is snap.edges.ptr,
        "8646 restore: the mesh must not alias the snapshot it was restored from");
    m.vertices[0].y += 1.0f;
    assert(!snap.matches(m), "8646 restore: a write to the mesh must not reach the snapshot");
}

// ---- (1) the arm door -------------------------------------------------------

unittest {
    assert(armDoorFor(ToolTransition.interactiveArm, false) == ArmDoor.key);
    assert(armDoorFor(ToolTransition.commandArm, true) == ArmDoor.key,
           "M3 arm door: a UI-door command (the typed command line) is the key door");
    assert(armDoorFor(ToolTransition.commandArm, false) == ArmDoor.script,
           "M3 arm door: a script-door command is its own row (C-H1-door-es-api)");
    assert(armDoorFor(ToolTransition.replayArm, true) == ArmDoor.none
           && armDoorFor(ToolTransition.resetRearm, false) == ArmDoor.none);
    size_t arms;
    foreach (t; EnumMembers!ToolTransition) if (isArm(t)) ++arms;
    assert(arms == 4, format("M3 arm door: %s arm transitions, measured 4", arms));
}

// ---- the stand-in ------------------------------------------------------------

private struct Pt { int a; float b; int[] tail; }

/// A tool whose session owns its steps; `v` and `arr` are its image, `act` an
/// Action trigger that moves `v`.
private class StepTool : Tool {
    int v;
    Pt[] arr;
    bool act;
    int rebuilds, commits, cancels, resumes, imageNotified;
    OpensAt opens = OpensAt.firstPress;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy first = { activationRow: true, sessionSteps: true,
            opensAt: OpensAt.firstPress, imageAttrs: ["v", "arr"], haulAttrs: ["v"] };
        static immutable ToolSessionPolicy armed = { activationRow: true, sessionSteps: true,
            opensAt: OpensAt.arm, imageAttrs: ["v", "arr"], haulAttrs: ["v"] };
        return opens == OpensAt.firstPress ? first : armed;
    }
    override Param[] params() {
        return [Param.int_("v", "V", &v, 0), Param.podArray_("arr", "Arr", &arr),
                Param.bool_("act", "Act", &act, false).action()];
    }
    override void onParamChanged(string n) {
        if (n == "act") v += 100;
        if (n == "v" || n == "arr") ++imageNotified;
    }
    override void rebuildPreviewFromAttrs() { ++rebuilds; }
    // Its live edit is a function of its image, as the cutting tools' are.
    override bool hasUncommittedEdit() const { return arr.length > 0; }
    override void cancelUncommittedEdit() { ++cancels; arr = null; }
    override bool commitOperation() { ++commits; arr = null; return true; }
    override void resumeAfterClose(bool rearm) { ++resumes; }
    // A gesture that writes the image: v = to, and one more element.
    void gesture(int to, PressKind k = PressKind.plain) {
        sessionStepBegins(k);
        v = to;
        arr ~= Pt(to, to * 0.5f, [to, to]);
        sessionStepEnds();
    }
    void armIt(int to) {
        sessionStepBegins();
        v = to;
        arr ~= Pt(to, 0, null);
        sessionOperationArmed();
    }
    void endRelease() { sessionStepEnds(); }
    void enter() { closeOwnOperation(true); }
    void discard() { closeOwnOperation(false); }
    void gestureBegins() { sessionStepBegins(); }
    void gestureEnds() { sessionStepEnds(); }
    void ended() { arr = null; sessionOperationEnded(); }
}

private final class Rig {
    StepTool t;
    Tool active;
    CommandHistory history;
    EditSession session;
    bool dropped;
    this(OpensAt opens = OpensAt.firstPress) {
        t = new StepTool;
        t.opens = opens;
        active = t;
        history = new CommandHistory();
        session = new EditSession(() => active, history, () { dropped = true; });
        session.noteArm("t.step", 1);
    }
    long steps() { return session.sessionStateJson()["steps"].integer; }
    bool isLive() { return session.sessionStateJson()["live"].boolean; }
}

private Rig rig(OpensAt opens = OpensAt.firstPress) { return new Rig(opens); }
private long steps(Rig r) { return r.steps(); }
private bool isLive(Rig r) { return r.isLive(); }

// ---- (2) steps -------------------------------------------------------------------

unittest {
    auto r = rig();
    assert(!isLive(r) && steps(r) == 0, "M3 steps: a fresh arm has an operation");
    r.t.gesture(1);
    assert(isLive(r) && steps(r) == 0, "M3 steps: the first gesture is the first group, not a step");
    r.t.gesture(2);
    r.t.gesture(3);
    assert(steps(r) == 2, format("M3 steps: %s steps after three gestures, expected 2", steps(r)));
    const rb = r.t.rebuilds;
    assert(r.session.navigate(true));
    assert(r.t.v == 2 && r.t.arr.length == 2 && r.t.arr[1].a == 2 && r.t.arr[1].tail == [2, 2],
           format("M3 steps: undo did not restore the step's image: v %s, arr %s", r.t.v, r.t.arr));
    assert(r.t.rebuilds == rb + 1, "M3 steps: an undo must rebuild exactly once");
    assert(r.t.imageNotified == 0, "M3 steps: a raw restore fired onParamChanged");
    assert(steps(r) == 1 && r.t.commits == 0 && !r.dropped);
    // H4: the redo returns the popped step live.
    assert(r.session.navigate(false));
    assert(r.t.v == 3 && r.t.arr.length == 3 && steps(r) == 2,
           format("M3 steps: redo did not return the step live: v %s, steps %s", r.t.v, steps(r)));
    // A new step clears the redo.
    assert(r.session.navigate(true) && r.t.v == 2);
    r.t.gesture(7);
    assert(steps(r) == 2);
    const vBefore = r.t.v;
    r.session.navigate(false);
    assert(r.t.v == vBefore, "M3 steps: a redo survived a new step");
}

// ---- (3) the first group ---------------------------------------------------------

unittest { // no activation row of this arm on top: the tool stays, the image opens
    auto r = rig();
    r.t.v = 5;
    r.t.gesture(6);
    assert(r.session.navigate(true));
    assert(r.t.v == 5 && r.t.arr.length == 0 && !isLive(r) && !r.dropped && r.history.undoEntries().length == 0,
           format("M3 first group: rule K / script door: v %s, live %s, dropped %s", r.t.v, isLive(r), r.dropped));
    // Its redo stash re-opens it (H4 for the first group).
    assert(r.session.navigate(false) && r.t.v == 6 && isLive(r) && steps(r) == 0,
           "M3 first group: the redo did not re-open the first group live");
}

private ToolActivationCommand row(Mesh* m, string id, bool joins) {
    auto v = new View(0, 0, 1, 1);
    return new ToolActivationCommand(m, v, EditMode.Vertices, id, "", true, joins);
}

unittest { // a key-door row of THIS arm joins the group; the navigate redo replays once
    Mesh m = makeCube();
    auto r = rig();
    r.history.recordToolLifecycle(row(&m, "t.step", true));
    r.t.gesture(11);
    assert(r.history.undoEntries().length == 1);
    assert(r.session.navigate(true));
    assert(r.history.undoEntries().length == 0 && r.history.redoEntries().length == 1,
           "M3 first group: a key-door row of this arm was not popped with the first group");
    assert(r.t.v == 0, "M3 first group: the image did not go back to the window's open image");
    assert(r.session.navigate(false));
    assert(r.t.v == 11 && isLive(r) && steps(r) == 0,
           format("M3 replay: the navigate redo did not re-seat the first group: v %s", r.t.v));
    // S7: a raw undo between two navigate redos — the second redo is bare.
    assert(r.history.undo());
    r.t.v = 0;
    assert(r.session.navigate(false));
    assert(r.t.v == 0, "M3 replay: the first group was replayed twice (S7)");
}

private class Stub : imported!"command".Command {
    import command : CmdFlags;
    import view : View;
    View v;
    this(View view) { v = view; super(null, v, EditMode.Vertices); }
    override string name() const { return "stub"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    protected override bool applyImpl() { return true; }
    protected override void revertImpl() {}
}

unittest { // the held group is for the NEXT navigate step only
    Mesh m = makeCube();
    auto r = rig();
    r.history.recordToolLifecycle(row(&m, "t.step", true));
    r.t.gesture(21);
    assert(r.session.navigate(true));          // ends the group with its row: held
    assert(!r.session.navigate(true));         // a navigate step with nothing to undo
    assert(r.session.navigate(false));         // redo the activation row: the hold expired
    assert(r.t.v == 0 && !isLive(r),
           format("M3 replay: the hold outlived the navigate step after its undo: v %s", r.t.v));
}

unittest { // ...and only on the redo of its own row
    Mesh m = makeCube();
    auto r = rig();
    auto prior = new Stub(new View(0, 0, 1, 1));
    assert(prior.apply());
    r.history.record(prior);
    r.history.recordToolLifecycle(row(&m, "t.step", true));
    r.t.gesture(22);
    assert(r.session.navigate(true));          // ends the group with its row: held
    assert(r.history.undo());                  // a RAW undo: the redo head is now the prior row
    assert(r.session.navigate(false));         // redo the prior row
    assert(r.t.v == 0, "M3 replay: the held group was replayed on another row's redo");
}

unittest { // the first group's stash is bound to the history position it was made at
    // (review B1): no activation row joins the group (K1 / script door), so
    // its undo stashes it — valid only while the undo top is unchanged.
    import command : CmdFlags;
    { // R1: a command recorded after the group's undo — the group stays gone
        auto r = rig();
        r.t.gesture(6);
        assert(r.session.navigate(true) && r.t.v == 0 && !isLive(r));
        auto later = new Stub(new View(0, 0, 1, 1));
        assert(later.apply());
        r.history.record(later);
        r.session.navigate(false);
        assert(r.t.v == 0 && !isLive(r),
               format("M3 stash: the group came back live over a later command: v %s", r.t.v));
    }
    { // R2: an older row undone after the group — redo is that row's
        auto r = rig();
        auto prior = new Stub(new View(0, 0, 1, 1));
        assert(prior.apply());
        r.history.record(prior);
        r.t.gesture(6);
        assert(r.session.navigate(true) && !isLive(r));
        assert(r.session.navigate(true) && r.history.redoEntries().length == 1,
               "M3 stash rig: the older row was not undone");
        assert(r.session.navigate(false));
        assert(r.t.v == 0 && !isLive(r) && r.history.redoEntries().length == 0
               && r.history.undoEntries().length == 1,
               format("M3 stash: redo replayed the group instead of the older row: v %s, "
                      ~ "live %s, redo %s", r.t.v, isLive(r), r.history.redoEntries().length));
    }
    { // control: nothing moved — the stash still returns the group live (H4)
        auto r = rig();
        r.t.gesture(6);
        r.session.navigate(true);
        r.session.navigate(false);
        assert(r.t.v == 6 && isLive(r), "M3 stash control: an unmoved stash did not re-open");
    }
}

unittest { // a mesh changed since the group ended: the redo re-arms bare
    Mesh m = makeCube();
    auto r = rig();
    r.history.recordToolLifecycle(row(&m, "t.step", true));
    r.t.gesture(31);
    assert(r.session.navigate(true));
    m.addVertex(Vec3(5, 5, 5));
    assert(r.session.navigate(false));
    assert(r.t.v == 0 && !isLive(r),
           format("M3 replay: a group was re-seated on a changed mesh: v %s", r.t.v));
}

unittest { // another tool's row, or a script-door row, is not this group's
    Mesh m = makeCube();
    foreach (joins; [false, true]) {
        auto r = rig();
        r.history.recordToolLifecycle(row(&m, joins ? "t.other" : "t.step", joins));
        r.t.gesture(3);
        assert(r.session.navigate(true));
        assert(r.history.undoEntries().length == 1 && !r.dropped && r.t.v == 0,
               format("M3 first group: a %s row was popped with the group",
                      joins ? "foreign" : "script-door"));
    }
}

// ---- (4) OpensAt.arm -----------------------------------------------------------------

unittest {
    auto r = rig(OpensAt.arm);
    r.t.gesture(1);
    assert(!isLive(r), "M3 arm: a gesture before the arm opened an arm-opened window");
    r.t.armIt(4);
    assert(isLive(r) && steps(r) == 0, "M3 arm: the arm did not open the window");
    r.t.endRelease();
    assert(steps(r) == 0, "M3 arm: a motionless rest of the arming press became a step");
    r.t.armIt(5);          // a second arm (after an unreported end) starts afresh
    r.t.v = 6;
    r.t.endRelease();
    assert(steps(r) == 1, format("M3 arm: the moved rest of the arming press is %s steps", steps(r)));
    assert(r.session.navigate(true) && r.t.v == 5, "M3 arm: the step did not restore the arm-time image");
    // The window of the SECOND arm opened from the image before its press (4),
    // not from the first arm's (1): a new arm is a new operation.
    assert(r.session.navigate(true) && r.t.v == 4 && !isLive(r),
           format("M3 arm: the first group's undo went back to %s, not the second arm's "
                  ~ "pre-arm image 4", r.t.v));
}

// ---- (5) closes and Action writes ------------------------------------------------------

unittest {
    auto r = rig();
    r.t.gesture(1);
    r.session.orchestrateParameterChange(r.t, "act", ParameterChangeSource.ScriptedValue,
                                         ParameterChangePhase.ValueWritten);
    assert(r.t.v == 101 && steps(r) == 1, format("M3 Action: v %s, steps %s", r.t.v, steps(r)));
    r.session.navigate(true);
    assert(r.t.v == 1, "M3 Action: the undo of an Action write did not restore the image");
    // A non-Action write is no step.
    r.session.orchestrateParameterChange(r.t, "v", ParameterChangeSource.ScriptedValue,
                                         ParameterChangePhase.ValueWritten);
    assert(steps(r) == 0);
    // Enter: the one close routine, once; the account ends.
    r.t.gesture(2);
    r.t.enter();
    assert(r.t.commits == 1 && !isLive(r) && steps(r) == 0, "M3 Enter: not closed through the session");
    // Enter resumes nothing: a later door's finish must not resume the tool.
    r.session.finishClose();
    assert(r.t.resumes == 0, "M3 Enter: the tool's own close left a resume pending");
    // A tool-reported end drops the account.
    r.t.gesture(3);
    r.t.gesture(4);
    r.t.ended();
    assert(!isLive(r) && steps(r) == 0, "M3 end: the session kept an ended operation's steps");
    // The tool's own discard (RMB) cancels through the session and ends it.
    r.t.gesture(5);
    r.t.gesture(6);
    const cancels = r.t.cancels;
    r.t.discard();
    assert(r.t.cancels == cancels + 1 && !isLive(r) && steps(r) == 0,
           "M3 discard: the tool's own cancel did not end the session's account");
}

unittest { // an idle bound tool: the session has nothing to undo; a re-arm starts afresh
    auto r = rig();
    assert(!r.session.navigate(true) && !isLive(r) && r.t.rebuilds == 0,
           "M3 idle: an undo with no operation touched the tool's image");
    r.t.gesture(1);
    r.t.gesture(2);
    r.t.endRelease();                          // an end with no step in flight: nothing
    assert(steps(r) == 1, format("M3 steps: an unmatched end pushed a step (%s)", steps(r)));
    r.session.noteArm("t.step", 2);            // a re-arm: a fresh account
    assert(!isLive(r) && steps(r) == 0, "M3 arm: a re-arm inherited the previous account");
    // The panel's (interactive) door is the same Action rule.
    r.t.gesture(3);
    r.session.orchestrateParameterChange(r.t, "act", ParameterChangeSource.InteractiveValue,
                                         ParameterChangePhase.ValueWritten);
    assert(steps(r) == 1 && r.t.v == 103, "M3 Action: the panel door's Action write was no step");
}

unittest { // the step stack is bounded; the oldest is dropped
    auto r = rig();
    foreach (i; 0 .. 300) r.t.gesture(i);
    assert(steps(r) == 256, format("M3 steps: %s steps after 300 gestures, cap 256", steps(r)));
    foreach (_; 0 .. 256) r.session.navigate(true);
    assert(isLive(r) && steps(r) == 0 && r.t.v == 43,
           format("M3 steps: after 256 undos v %s (the oldest kept step starts at 43)", r.t.v));
}

unittest { // a `firstPress` tool's arm report opens nothing: its gesture's end does
    auto r = rig();
    r.t.armIt(4);
    assert(!isLive(r), "M3 arm: a firstPress tool opened its window at an arm report");
    r.t.endRelease();
    assert(isLive(r) && steps(r) == 0, "M3 arm: the firstPress gesture did not open the window");
}

unittest { // openOperation: Middle clones the haul attributes from the given end, unless noClone
    auto t = new StepTool;
    t.v = 1;
    AttrImage prev;
    { auto u = new StepTool; u.v = 9; u.arr = [Pt(9, 0, null)]; prev = u.captureAttrImage(); }
    t.openOperation(PressKind.middle, prev);
    assert(t.v == 9 && t.arr.length == 0 && t.rebuilds == 1,
           format("M3 openOperation: Middle cloned %s / %s (haul is v only)", t.v, t.arr));
    t.openOperation(PressKind.plain, AttrImage.init);
    assert(t.v == 9 && t.rebuilds == 1, "M3 openOperation: a plain press changed the image");
    t.openOperation(PressKind.shift, AttrImage.init);
    assert(t.v == 0 && t.rebuilds == 2, "M3 openOperation: Shift did not reset the haul to defaults");
    // A no-clone tool's Middle press is a boundary only (Edge Slice, C-H5-es-mmb).
    static final class NoCloneTool : StepTool {
        override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
            static immutable ToolSessionPolicy p = { sessionSteps: true, noClone: true,
                imageAttrs: ["v", "arr"], haulAttrs: ["v"] };
            return p;
        }
    }
    auto nc = new NoCloneTool;
    nc.v = 1;
    nc.openOperation(PressKind.middle, prev);
    assert(nc.v == 1 && nc.rebuilds == 0, "M3 openOperation: a no-clone tool cloned on Middle");
    // M3b: a no-clone tool's Middle applies nothing; every other press does.
    assert(!nc.pressAppliesOperation(PressKind.middle) && nc.pressAppliesOperation(PressKind.shift)
           && nc.pressAppliesOperation(PressKind.plain) && t.pressAppliesOperation(PressKind.middle),
           "M3b pressAppliesOperation: the no-clone Middle rule is not the only exception");
    // An empty image restores nothing and still rebuilds once.
    t.v = 5;
    t.applyAttrImage(AttrImage.init);
    assert(t.v == 5 && t.rebuilds == 2, "M3 applyAttrImage: an empty image wrote or rebuilt");
}

unittest { // the session reports for the tool it BOUND only
    auto r = rig();
    r.t.gesture(1);
    r.t.gesture(2);
    auto other = new StepTool;             // published without the arm door's noteArm
    other.v = 7;
    r.active = other;
    r.session.navigate(true);
    assert(other.v == 7 && other.rebuilds == 0,
           format("M3 bound: an unbound active tool received the session's image: v %s", other.v));
    assert(r.session.sessionStateJson().type == JSONType.null_,
           "M3 bound: the state of an unbound tool was reported");
}

// ---- (6) PodArray -------------------------------------------------------------------

unittest {
    Pt[] store = [Pt(1, 2.5f, [7, 8, 9]), Pt(3, 4.5f, [])];
    auto p = Param.podArray_("pts", "Pts", &store);
    assert(p.kind == Param.Kind.PodArray && p.podElemSize == Pt.sizeof && p.hidden_ && p.transient_);
    auto raw = p.snapshotRaw();
    assert(raw.length == 2 * Pt.sizeof, format("M3 PodArray: %s bytes for 2 elements", raw.length));
    // The copy is a SCANNED block (a collection alone may not reach the case:
    // a conservative stack word can keep the inner array alive).
    import core.memory : GC;
    assert((GC.getAttr(cast(void*) raw.ptr) & GC.BlkAttr.NO_SCAN) == 0,
           "M3 PodArray: the raw image is a NO_SCAN block; a GC slice inside it is not traced");
    const probe = p.snapshotRaw();
    p.restoreRaw(probe);
    assert((GC.getAttr(cast(void*) store.ptr) & GC.BlkAttr.NO_SCAN) == 0,
           "M3 PodArray: the restored array is a NO_SCAN block");
    store = [Pt(9, 9, [1])];
    // Collect with the only reference to [7, 8, 9] held inside the raw image.
    foreach (_; 0 .. 3) { GC.collect(); auto junk = new int[](64); junk[] = 0x5A5A5A5A; }
    p.restoreRaw(raw);
    assert(store.length == 2 && store[0].a == 1 && store[0].b == 2.5f && store[0].tail == [7, 8, 9]
           && store[1].a == 3, format("M3 PodArray: restored %s", store));
    store ~= Pt(5, 0, null);   // the restored slice stays an ordinary array
    assert(store.length == 3);
    p.restoreRaw(null);
    assert(store.length == 0);

    assert(!isStickyCapturable(p) && paramToJson(p) == JSONValue(0));
    store = [Pt(1, 1, null)];
    assert(paramToJson(p).integer == 1 && isUserSet(p));
    // Never a replayable argument: the serializer skips it even when set.
    import argstring : serializeParams;
    assert(serializeParams([p]) == "", "M3 PodArray: the argstring serializer emitted it");
    auto pj = parseJSON(`{"pts":[1,2]}`);
    bool refused;
    try injectParamsInto([p], pj); catch (Exception e) refused = e.msg.canFind("not injectable");
    assert(refused, "M3 PodArray: injection was not refused by name");
    assert(store.length == 1);
}

unittest { // every consumer site of the array kinds has a PodArray arm (opponent R3 C4)
    import tests.unit.census_symbols : blankNonCode;
    size_t vec3Sites, podSites;
    string[] missing;
    foreach (e; dirEntries("source", "*.d", SpanMode.depth)) {
        const code = blankNonCode(readText(e.name));
        const v = code.count("Kind.Vec3Array"), pd = code.count("Kind.PodArray");
        vec3Sites += v;
        podSites += pd;
        if (v > 0 && pd < v) missing ~= format("%s (%s Vec3Array, %s PodArray)", e.name, v, pd);
    }
    assert(missing.length == 0, format("M3 PodArray: a consumer site has no PodArray arm: %s", missing));
    // Measured on the M3 tree (this loop): every code mention of the array
    // kind, the raw snapshot/restore pair included; PodArray has one more, the
    // argstring loop's skip.
    assert(vec3Sites == 18 && podSites == 19,
           format("M3 PodArray: %s Vec3Array / %s PodArray code sites, measured 18 / 19",
                  vec3Sites, podSites));
}

// ---- slice M3b -----------------------------------------------------------------

unittest { // a boundary step restores the image the new operation STARTED from (H2, 283)
    auto r = rig();
    r.t.gesture(1);
    r.t.gesture(5);
    r.t.gesture(7, PressKind.shift);    // Shift resets v to 0, then the gesture writes 7
    assert(r.t.v == 7 && steps(r) == 2, format("M3b boundary floor: v %s, steps %s", r.t.v, steps(r)));
    r.session.navigate(true);
    assert(r.t.v == 0, format("M3b boundary: the undo of a Shift step must restore the reset start "
                              ~ "(0), not the previous operation's end (5): v %s", r.t.v));
}

/// A stand-in whose arm applies it (`armAttr`), as Polygon Bevel's does.
private final class ArmTool : StepTool {
    bool on;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy p = { sessionSteps: true, opensAt: OpensAt.arm,
            imageAttrs: ["v", "on"], haulAttrs: ["v"], armAttr: "on" };
        return p;
    }
    override Param[] params() {
        return [Param.int_("v", "V", &v, 0), Param.bool_("on", "On", &on, false)];
    }
    override bool hasUncommittedEdit() const { return on; }
}

unittest { // the arm raises `armAttr` as the window's first group; a history-step arm is bare
    auto t = new ArmTool;
    Tool active = t;
    auto h = new CommandHistory();
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.arm");
    auto j = s.sessionStateJson();
    assert(t.on && t.rebuilds == 1 && j["live"].boolean && j["steps"].integer == 0,
           format("M3b arm: the arm did not apply as the first group: on %s, rebuilds %s, %s",
                  t.on, t.rebuilds, j));
    s.navigate(true);   // no activation row: rule K, the tool stays with its group undone
    assert(!t.on && active is t && !s.sessionStateJson()["live"].boolean,
           format("M3b arm: the first group's undo must lower the arm attribute: on %s", t.on));

    auto b = new ArmTool;
    active = b;
    h.setState(UndoState.Suspend);
    s.noteArm("t.arm");
    h.setState(UndoState.Active);
    assert(!b.on && b.rebuilds == 0 && !s.sessionStateJson()["live"].boolean,
           format("M3b arm: an arm under a history step must be bare: on %s, rebuilds %s",
                  b.on, b.rebuilds));
}

unittest { // an arm attribute applies only on an arm-opened tool (opensAt, not armAttr alone)
    static final class FirstTool : StepTool {
        bool on;
        override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
            static immutable ToolSessionPolicy p = { sessionSteps: true, opensAt: OpensAt.firstPress,
                imageAttrs: ["v", "on"], armAttr: "on" };
            return p;
        }
        override Param[] params() {
            return [Param.int_("v", "V", &v, 0), Param.bool_("on", "On", &on, false)];
        }
    }
    auto t = new FirstTool;
    Tool active = t;
    auto s = new EditSession(() => active, new CommandHistory(), () {});
    s.noteArm("t.first");
    assert(!t.on && t.rebuilds == 0 && !s.sessionStateJson()["live"].boolean,
           format("M3b arm: a first-press tool's arm applied its arm attribute: on %s", t.on));
}

// ---- (7) Slice M4: the session token, the record that carries its activation,
// ---- the restored predecessor, keep-alive as data, Shift through the session -

/// A tool whose FIRST operation's closing record carries its activation row
/// (Edge Extend's policy), and whose in-place commit writes a row.
private class CarryTool : StepTool {
    bool carries = true;
    CommandHistory writeTo;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy yes = { activationRow: true, sessionSteps: true,
            opensAt: OpensAt.firstPress, imageAttrs: ["v", "arr"], haulAttrs: ["v"],
            recordCarriesActivation: true };
        static immutable ToolSessionPolicy no = { activationRow: true, sessionSteps: true,
            opensAt: OpensAt.firstPress, imageAttrs: ["v", "arr"], haulAttrs: ["v"] };
        return carries ? yes : no;
    }
    override bool commitUncommittedEdit() {
        if (arr.length == 0) return false;
        writeRow();
        arr = null;
        return true;
    }
    bool refuseRedo;
    Stub writeRow() {
        auto s = refuseRedo ? new OnceStub(new View(0, 0, 1, 1)) : new Stub(new View(0, 0, 1, 1));
        assert(s.apply());
        writeTo.record(s);
        return s;
    }
    void quietGesture() { sessionStepBegins(); sessionStepEnds(true); }
    void loudGesture() { sessionStepBegins(); sessionStepEnds(false); }
}

/// A record that applies once and refuses its redo.
private final class OnceStub : Stub {
    int applies;
    this(View view) { super(view); }
    protected override bool applyImpl() { return ++applies == 1; }
}

private ToolActivationCommand tokenRow(Mesh* m, string id, string prev, bool joins,
                                       bool carries, ulong token, ulong prevToken = 0) {
    auto v = new View(0, 0, 1, 1);
    return new ToolActivationCommand(m, v, EditMode.Vertices, id, prev, true, joins,
                                     carries, token, prevToken);
}

private long tokenOf(Rig r) { return r.session.sessionStateJson()["token"].integer; }

unittest { // M4 marks: the row a close WROTE carries the closing session's token
    Mesh m = makeCube();
    auto r = rig();
    auto t = new CarryTool;
    t.writeTo = r.history;
    r.active = t;
    r.session.noteArm("t.carry", 7);
    // An earlier record, so the close starts from a non-empty top (the row it
    // wrote is the first ABOVE that top, not the stack's first).
    auto earlier = new Stub(new View(0, 0, 1, 1));
    assert(earlier.apply());
    r.history.record(earlier);
    // A switch: the door writes the outgoing row, then the incoming arm row
    // lands ABOVE it; the mark goes to the door's row, with the OUTGOING token.
    r.session.closeOperation(CloseReason.switch_);
    auto doorRow = t.writeRow();
    auto incoming = tokenRow(&m, "t.next", "t.carry", true, false, 8, 7);
    r.history.recordToolLifecycle(incoming);
    r.active = new StepTool;
    r.session.noteArm("t.next", 8);
    r.session.finishClose();
    assert(doorRow.sessionToken() == 7 && incoming.sessionToken() == 8,
           format("M4 mark: the switch marked door %s / incoming %s (want 7 / 8)",
                  doorRow.sessionToken(), incoming.sessionToken()));
    assert(r.session.lastClosedRow() is doorRow, "M4 mark: the closed row is not the door's");
    // Opponent R3 C2: a command close that commits NOTHING marks nothing — not
    // the row that happened to be on top.
    auto quiet = new StepTool;          // commitOperation writes no row
    quiet.arr = [Pt(1, 0, null)];       // an open edit, so the uiDoor close commits
    r.active = quiet;
    r.session.noteArm("t.quiet", 9);
    const top = r.history.undoEntries()[$ - 1].cmd;
    const o = r.session.closeOperation(CloseReason.command, CommandDoor.ui);
    assert(r.session.lastClosedRow() is null && top.sessionToken() == 8,
           format("M4 mark: a close that wrote nothing marked the top (token %s, closed %s)",
                  top.sessionToken(), r.session.lastClosedRow() !is null));
    assert(!o.dropsTool, "M4 mark rig: the command close dropped the tool");
}

unittest { // M4 pair: the record that closed THIS session's first operation pops with its row
    import command : Command;
    Mesh m = makeCube();
    // (a) the law: key-door row + this session's record -> one undo step, one redo step
    {
        auto r = rig();
        auto t = new CarryTool;
        t.writeTo = r.history;
        r.active = t;
        auto act = tokenRow(&m, "t.carry", "", true, true, 5);
        act.onDeactivate = () { r.active = null; };
        act.onActivate = (string id) { r.active = t; r.session.noteArm(id, 55); };
        r.history.recordToolLifecycle(act);
        r.session.noteArm("t.carry", 5);
        t.arr = [Pt(1, 0, null)];
        assert(r.session.applyAndContinue(), "M4 pair rig: the in-place commit refused");
        const rec = r.history.undoEntries()[$ - 1].cmd;
        assert(rec.sessionToken() == 5, format("M4 pair rig: record token %s", rec.sessionToken()));
        assert(r.session.navigate(true));
        assert(r.history.undoEntries().length == 0 && r.active is null,
               format("M4 pair: the record did not pop with its activation row: depth %s, tool %s",
                      r.history.undoEntries().length, r.active !is null));
        assert(r.session.navigate(false));
        assert(r.history.undoEntries().length == 2 && r.active is t && tokenOf(r) == 5,
               format("M4 pair: the redo did not bring the row and its record back as one step "
                      ~ "in the row's session: depth %s, token %s", r.history.undoEntries().length,
                      tokenOf(r)));
    }
    // (b) m4c: the same tool re-armed as a NEW session (token 6) — the old
    // session's record pops ALONE (class would pair it; the token does not).
    // (c) a script-door row (not joined) and (d) a policy that does not carry.
    foreach (cell; ["new session", "script door", "no carry"]) {
        auto r = rig();
        auto t = new CarryTool;
        t.writeTo = r.history;
        t.carries = cell != "no carry";
        r.active = t;
        auto act = tokenRow(&m, "t.carry", "", cell != "script door", t.carries, 5);
        act.onDeactivate = () { r.active = null; };
        r.history.recordToolLifecycle(act);
        r.session.noteArm("t.carry", 5);
        t.arr = [Pt(1, 0, null)];
        assert(r.session.applyAndContinue());
        if (cell == "new session") r.session.noteArm("t.carry", 6);
        assert(r.session.navigate(true));
        assert(r.history.undoEntries().length == 1 && r.active is t,
               format("M4 pair (%s): the record popped its activation row too: depth %s",
                      cell, r.history.undoEntries().length));
    }
}

unittest { // M4 restorePredecessor: undoing the successor's row hands the predecessor its token
    Mesh m = makeCube();
    auto r = rig();
    auto pred = new CarryTool;
    auto succ = new StepTool;
    r.active = succ;
    auto act = tokenRow(&m, "t.succ", "t.pred", true, false, 9, 5);
    act.onActivate = (string id) { r.active = pred; r.session.noteArm(id, 10); };
    r.history.recordToolLifecycle(act);
    r.session.noteArm("t.succ", 9);
    assert(r.session.navigate(true));
    assert(r.active is pred && tokenOf(r) == 5,
           format("M4 restore: the restored predecessor holds token %s, not its own session's 5",
                  tokenOf(r)));
}

unittest { // M4 keepAliveOnCancel is data: the whole-edit cancel keeps or drops by the policy
    import tool : ToolSessionPolicy;
    static class OpenTool : Tool {
        bool open = true, keep;
        override bool hasUncommittedEdit() const { return open; }
        override void cancelUncommittedEdit() { open = false; }
        override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
            static immutable ToolSessionPolicy k = { keepAliveOnCancel: true };
            return keep ? k : ToolSessionPolicy.init;
        }
    }
    foreach (keep; [true, false]) {
        auto t = new OpenTool;
        t.keep = keep;
        Tool held = t;
        bool dropped;
        auto es = new EditSession(() => held, new CommandHistory(), () { dropped = true; });
        assert(es.navigate(true) && !t.open);
        assert(dropped == !keep, format("M4 keep-alive: keep %s dropped %s", keep, dropped));
    }
}

unittest { // M4 Shift through the session: the commit is a close, the next operation opens as Shift
    auto r = rig();
    auto t = new CarryTool;
    t.writeTo = r.history;
    r.active = t;
    r.session.noteArm("t.carry", 3);
    t.gesture(4);
    assert(isLive(r) && t.v == 4);
    assert(r.session.applyAndContinue());
    assert(!isLive(r) && steps(r) == 0, "M4 Shift: the session kept the closed operation's account");
    assert(r.history.undoEntries()[$ - 1].cmd.sessionToken() == 3,
           "M4 Shift: the committed row does not carry the session");
    assert(t.v == 0, format("M4 Shift: the haul attribute was not reset for the next operation: v %s", t.v));
    // A tool that refuses the in-place commit: false, nothing marked or reset.
    auto s = new StepTool;
    r.active = s;
    r.session.noteArm("t.step", 4);
    s.v = 7;
    s.arr = [Pt(1, 0, null)];
    const depth = r.history.undoEntries().length;
    assert(!r.session.applyAndContinue() && s.v == 7 && r.history.undoEntries().length == depth,
           "M4 Shift: a refused in-place commit changed the tool or the history");
}

unittest { // M4 steps only on change, when the tool asks (Edge Extend's gestures)
    auto r = rig();
    auto t = new CarryTool;
    r.active = t;
    r.session.noteArm("t.carry", 1);
    t.quietGesture();                   // the opening gesture is the first group regardless
    assert(isLive(r) && steps(r) == 0);
    t.quietGesture();
    assert(steps(r) == 0, "M4 steps: a gesture that changed nothing became a step (ifChanged)");
    t.loudGesture();
    assert(steps(r) == 1, "M4 steps control: without ifChanged an unchanged gesture is a step");
}

unittest { // M4 marks, the other half: a switch whose door wrote NOTHING marks nothing
    Mesh m = makeCube();
    auto r = rig();
    r.session.noteArm("t.step", 7);            // StepTool: an idle switch writes no row
    r.session.closeOperation(CloseReason.switch_);
    auto incoming = tokenRow(&m, "t.next", "t.step", true, false, 8, 7);
    r.history.recordToolLifecycle(incoming);
    r.active = new StepTool;
    r.session.noteArm("t.next", 8);
    r.session.finishClose();
    assert(r.session.lastClosedRow() is null && incoming.sessionToken() == 8,
           "M4 mark: an idle switch counted the incoming activation row as the row it wrote");
}

unittest { // M4 pair: the row below must carry the RECORD's token, and redo pairs only a carrying row
    import command : Command;
    Mesh m = makeCube();
    { // a record of session 5 above the carrying row of session 4: not its row
        auto r = rig();
        auto t = new CarryTool;
        t.writeTo = r.history;
        r.active = t;
        auto act = tokenRow(&m, "t.carry", "", true, true, 4);
        act.onDeactivate = () { r.active = null; };
        r.history.recordToolLifecycle(act);
        r.session.noteArm("t.carry", 5);
        t.arr = [Pt(1, 0, null)];
        assert(r.session.applyAndContinue());
        assert(r.session.navigate(true));
        assert(r.history.undoEntries().length == 1 && r.active is t,
               "M4 pair: a record popped an activation row of ANOTHER session");
    }
    { // a non-carrying row: two raw undos, then a navigate redo re-arms only the row
        auto r = rig();
        auto t = new CarryTool;
        t.writeTo = r.history;
        t.carries = false;
        r.active = t;
        auto act = tokenRow(&m, "t.carry", "", true, false, 5);
        act.onDeactivate = () { r.active = null; };
        act.onActivate = (string id) { r.active = t; r.session.noteArm(id, 50); };
        r.history.recordToolLifecycle(act);
        r.session.noteArm("t.carry", 5);
        t.arr = [Pt(1, 0, null)];
        assert(r.session.applyAndContinue());
        assert(r.history.undo() && r.history.undo() && r.history.redoEntries().length == 2,
               "M4 pair rig: the raw undos did not leave the row and its record in redo");
        assert(r.session.navigate(false));
        assert(r.history.undoEntries().length == 1 && r.history.redoEntries().length == 1,
               format("M4 pair: a non-carrying row redid its session's record with it: undo %s, redo %s",
                      r.history.undoEntries().length, r.history.redoEntries().length));
    }
}

unittest { // M4 pair, boundary (not captured): with its session gone, a record pops alone
    // The record carries its activation row only while THAT session is the
    // active one; after the tool dropped (no tool, token 0) the record is its
    // own step and the row stays (gap 378 names the uncaptured half).
    Mesh m = makeCube();
    auto r = rig();
    auto t = new CarryTool;
    t.writeTo = r.history;
    r.active = t;
    auto act = tokenRow(&m, "t.carry", "", true, true, 5);
    r.history.recordToolLifecycle(act);
    r.session.noteArm("t.carry", 5);
    t.arr = [Pt(1, 0, null)];
    assert(r.session.applyAndContinue());
    r.active = null;                           // dropped, no re-arm
    assert(r.session.navigate(true));
    assert(r.history.undoEntries().length == 1,
           format("M4 pair: a record of a session that is gone popped its row: depth %s",
                  r.history.undoEntries().length));
}

unittest { // M4 review: a pair whose row refuses its undo is reported, the record's step stands
    Mesh m = makeCube();
    static final class RefusingRow : ToolActivationCommand {
        // A predecessor of the same id with another token: a split pair must
        // not hand it over (the row was NOT undone).
        this(Mesh* m, View v) { super(m, v, EditMode.Vertices, "t.carry", "t.carry", true, true, true, 5, 9); }
        protected override void revertImpl() { failRevert("refused (test)"); }
    }
    auto r = rig();
    auto t = new CarryTool;
    t.writeTo = r.history;
    r.active = t;
    r.history.recordToolLifecycle(new RefusingRow(&m, new View(0, 0, 1, 1)));
    r.session.noteArm("t.carry", 5);
    t.arr = [Pt(1, 0, null)];
    assert(r.session.applyAndContinue());
    assert(r.session.navigate(true), "M4 split pair: the record's undo step was not reported as taken");
    assert(r.history.undoEntries().length == 0 && r.history.redoEntries().length == 1 && r.active is t,
           format("M4 split pair: undo %s, redo %s", r.history.undoEntries().length,
                  r.history.redoEntries().length));
    assert(tokenOf(r) == 5, format("M4 split pair: the refused row's predecessor token was adopted: %s",
                                   tokenOf(r)));
}

unittest { // M4 review: a key-door row over an UNCLASSIFIED predecessor keeps its redo (§22)
    Mesh m = makeCube();
    auto v = new View(0, 0, 1, 1);
    auto h = new CommandHistory();
    auto overPlain = new ToolActivationCommand(&m, v, EditMode.Vertices, "t.step", "t.plain",
                                               true, true, false, 3, 2, false);
    auto overRow = new ToolActivationCommand(&m, v, EditMode.Vertices, "t.step", "t.emitter",
                                             true, true, false, 4, 3, true);
    assert(overPlain.carriesRedoAfterUndo() && !overRow.carriesRedoAfterUndo(),
           "M4 review: the redo of a row depends on whether its predecessor writes rows, not on "
           ~ "whether it restores one");
}

unittest { // M4 review: a pair whose record refuses its redo leaves the row redone, reported
    Mesh m = makeCube();
    auto r = rig();
    auto t = new CarryTool;
    t.writeTo = r.history;
    t.refuseRedo = true;
    r.active = t;
    auto act = tokenRow(&m, "t.carry", "", true, true, 5);
    act.onDeactivate = () { r.active = null; };
    act.onActivate = (string id) { r.active = t; r.session.noteArm(id, 55); };
    r.history.recordToolLifecycle(act);
    r.session.noteArm("t.carry", 5);
    t.arr = [Pt(1, 0, null)];
    assert(r.session.applyAndContinue());
    assert(r.session.navigate(true) && r.history.undoEntries().length == 0);
    assert(r.session.navigate(false), "M4 split redo: the row's redo was not reported as taken");
    assert(r.history.undoEntries().length == 1 && r.history.redoEntries().length == 1
           && r.active is t && tokenOf(r) == 5,
           format("M4 split redo: undo %s, redo %s, token %s", r.history.undoEntries().length,
                  r.history.redoEntries().length, tokenOf(r)));
}

private final class DormantRefusalTool : Tool, TopologyStepClient {
    Mesh* m;
    Command carrier;
    int v;
    bool dormant;
    bool refuse;

    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true,
            historyTopologySteps: true,
            opensAt: OpensAt.arm, imageAttrs: ["v"]
        };
        return policy;
    }
    override Param[] params() { return [Param.int_("v", "V", &v, 0)]; }
    override Mesh* topologyStepMesh() { return m; }
    override MeshSnapshot topologyStepBasis() { return MeshSnapshot.capture(*m); }
    override Command topologyStepCarrier() { return carrier; }
    override bool recordTopologyStep(Command cmd) { return !refuse; }
    override string topologyStepLabel() { return "Dormant Refusal"; }
    override void setTopologyDormant(bool value) { dormant = value; }
    override void rebaseTopologyStep(MeshSnapshot basis) {}
    override void restoreTopologyStep(in AttrImage attrs, MeshSnapshot basis) {
        restoreRecordedAttrs(attrs);
    }
    void writeStep() {
        sessionStepBegins();
        v = 9;
        m.vertices[0].x += 1;
        sessionStepEnds();
    }
    void cancelPendingStep() {
        sessionStepBegins();
        v = 7;
        m.vertices[0].x += 1;
        closeOwnOperation(false);
    }
}

unittest { // 7990 refusal: null carrier and refused record restore both images.
    foreach (refuse; [false, true]) {
        Mesh m = makeCube();
        auto h = new CommandHistory();
        auto t = new DormantRefusalTool;
        t.m = &m;
        Tool active = t;
        auto s = new EditSession(() => active, h, () { active = null; });
        auto arm = tokenRow(&m, "t.dormant", "", true, false, 1);
        arm.markDormantTopology();
        h.recordToolLifecycle(arm);
        if (refuse) { t.carrier = arm; t.refuse = true; }
        h.setState(UndoState.Suspend);
        s.noteArm("t.dormant", 1);
        h.setState(UndoState.Active);
        assert(t.dormant && s.sessionStateJson()["dormant"].boolean,
            "7990 refusal fixture did not enter dormant topology mode");
        auto before = MeshSnapshot.capture(m);
        const depth = h.undoEntries().length;
        t.writeStep();
        assert(before.matches(m) && t.v == 0 && h.undoEntries().length == depth,
            refuse ? "7990 refused history left dormant mesh or attrs changed"
                   : "7990 null carrier left dormant mesh or attrs changed");
        t.cancelPendingStep();
        assert(before.matches(m) && t.v == 0 && h.undoEntries().length == depth,
            "7990 dormant pending cancel restored an invalid topology basis");
    }
}

// ---- Polygon S2: completed topology attrs belong to an identity/session ---

private final class OwnedPolyAttrTool : Tool {
    int shift;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            imageAttrs: ["polyShift"]
        };
        return policy;
    }
    override Param[] params() {
        return [Param.int_("polyShift", "Polygon Shift", &shift, 0)];
    }
}

private final class OwnedEdgeAttrTool : Tool {
    int offset;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            imageAttrs: ["edgeOffset"]
        };
        return policy;
    }
    override Param[] params() {
        return [Param.int_("edgeOffset", "Edge Offset", &offset, 0)];
    }
}

private OwnedPolyAttrTool undoToOwnedPoly(EditSession s, CommandHistory h,
                                          ref Tool active, ref Mesh m,
                                          ulong previousToken) {
    auto v = new View(0, 0, 1, 1);
    auto act = new ToolActivationCommand(&m, v, EditMode.Vertices,
        "t.edge", "t.poly", true, false, false, 9, previousToken, true, true);
    OwnedPolyAttrTool restored;
    act.onActivate = (string id) {
        assert(id == "t.poly", "owned-attrs rig restored the wrong predecessor id");
        restored = new OwnedPolyAttrTool;
        active = restored;
        // The replay arm is fresh. navigate() adopts `previousToken` only
        // after the lifecycle callback returns.
        s.noteArm(id, 50);
    };
    h.recordToolLifecycle(act);
    auto successor = new OwnedEdgeAttrTool;
    active = successor;
    s.noteArm("t.edge", 9);
    assert(s.navigate(true), "owned-attrs rig could not undo the successor activation");
    return restored;
}

unittest { // The identity half rejects a foreign image even under the same token.
    Mesh m = makeCube();
    auto h = new CommandHistory;
    Tool active;
    auto s = new EditSession(() => active, h, () { active = null; });
    auto poly = new OwnedPolyAttrTool;
    poly.shift = 17;
    active = poly;
    s.noteArm("t.poly", 5);
    auto foreign = new OwnedEdgeAttrTool;
    foreign.offset = 23;
    active = foreign;
    s.noteArm("t.foreign-edge", 5);

    auto restored = undoToOwnedPoly(s, h, active, m, 5);
    assert(restored.shift == 17,
        format("topology attr ownership ignored predecessor identity: restored %s, expected 17",
               restored.shift));
}

unittest { // The predecessor restore takes the tool's NEWEST remembered values, not its session's.
    // Expectation edit backed by capture C9-4 (findings §19, `rearm_smooth_ui/s08_Z.attrs`):
    // the reference restores the tool's stored copy, whatever run wrote it last.
    Mesh m = makeCube();
    auto h = new CommandHistory;
    Tool active;
    auto s = new EditSession(() => active, h, () { active = null; });
    auto first = new OwnedPolyAttrTool;
    first.shift = 17;
    active = first;
    s.noteArm("t.poly", 5);
    auto newer = new OwnedPolyAttrTool;
    newer.shift = 29;
    active = newer;
    s.noteArm("t.poly", 7);

    auto restored = undoToOwnedPoly(s, h, active, m, 5);
    assert(restored.shift == 29,
        format("predecessor restore did not take the tool's newest values: restored %s, expected 29 (C9-4)",
               restored.shift));
}

unittest { // Law 4 seed (9020 F): a REFUSED drop undo leaves the remembered image as it was.
    static final class RefusingPolyRow : ToolActivationCommand {
        bool refuse = true;
        this(Mesh* m, View v) {
            super(m, v, EditMode.Vertices, "t.poly", "", true, true, false, 5);
        }
        protected override void revertImpl() {
            if (refuse) failRevert("refused (test)");
            else super.revertImpl();
        }
    }
    Mesh m = makeCube();
    auto h = new CommandHistory;
    Tool active;
    auto s = new EditSession(() => active, h, () { active = null; });
    auto poly = new OwnedPolyAttrTool;
    poly.shift = 17;
    active = poly;
    auto row = new RefusingPolyRow(&m, new View(0, 0, 1, 1));
    h.recordToolLifecycle(row);
    s.noteArm("t.poly", 5);
    poly.shift = 41;                // the live image the refused drop would remember
    // A refused revert drops the entry and writes no redo (CommandHistory.undo).
    assert(!s.navigate(true) && h.undoEntries().length == 0 && h.redoEntries().length == 0
           && active is poly && row.revertFailureReason() == "refused (test)",
        format("seed-refusal rig: the drop undo was not refused (undo %s, redo %s, tool %s)",
               h.undoEntries().length, h.redoEntries().length, active is poly));
    auto restored = undoToOwnedPoly(s, h, active, m, 5);
    assert(restored.shift == 17,
        format("law 4 seed: a refused drop undo overwrote the remembered image: restored %s, expected 17",
               restored.shift));
}

unittest { // Law 4 seed (9020 F): the drop image is keyed BEFORE the undo re-arms a predecessor.
    Mesh m = makeCube();
    auto h = new CommandHistory;
    Tool active;
    auto s = new EditSession(() => active, h, () { active = null; });
    auto poly = new OwnedPolyAttrTool;
    poly.shift = 17;
    active = poly;
    s.noteArm("t.poly", 5);
    auto v = new View(0, 0, 1, 1);
    auto act = new ToolActivationCommand(&m, v, EditMode.Vertices,
        "t.edge", "t.poly", true, false, false, 9, 5, true, true);
    OwnedEdgeAttrTool recreated;
    act.onActivate = (string id) {
        if (id == "t.poly") { active = new OwnedPolyAttrTool; s.noteArm(id, 50); }
        else { recreated = new OwnedEdgeAttrTool; active = recreated; s.noteArm(id, 51); }
    };
    h.recordToolLifecycle(act);
    auto edge = new OwnedEdgeAttrTool;
    active = edge;
    s.noteArm("t.edge", 9);
    edge.offset = 23;               // the live value at the drop (no row of its own)
    assert(s.navigate(true) && cast(OwnedPolyAttrTool)active !is null,
        "seed-key rig: the successor's activation undo did not restore the predecessor");
    assert(s.navigate(false) && recreated !is null && active is recreated,
        "seed-key rig: the redo did not re-create the successor");
    assert(recreated.offset == 23,
        format("law 4 seed: the drop image was keyed after the undo re-armed the predecessor: "
               ~ "re-created offset %s, expected 23", recreated.offset));
}

// ---- 8290: a held widget is ONE topology step --------------------------------

private class ScrubTopologyTool : Tool, TopologyStepClient {
    Mesh* m;
    CommandHistory h;
    View view;
    float shift = 0.0f;
    MeshSnapshot basis;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.firstPress, imageAttrs: ["shift"]
        };
        return policy;
    }
    override Param[] params() { return [Param.float_("shift", "Offset", &shift, 0.0f)]; }
    // The kernel stand-in: the layer re-evaluated from the operation's basis.
    override void onParamChanged(string) {
        basis.restore(*m);
        m.vertices[0].y += shift;
    }
    override Mesh* topologyStepMesh() { return m; }
    override MeshSnapshot topologyStepBasis() { return basis; }
    override Command topologyStepCarrier() {
        import commands.mesh.session_edit : MeshSessionEdit;
        return new MeshSessionEdit(m, view, EditMode.Polygons, "t.scrub", "Scrub");
    }
    override bool recordTopologyStep(Command cmd) { h.record(cmd); return true; }
    override string topologyStepLabel() { return "Scrub"; }
    override void setTopologyDormant(bool) {}
    override void rebaseTopologyStep(MeshSnapshot) {}
    override void restoreTopologyStep(in AttrImage attrs, MeshSnapshot b) {
        basis = b;
        restoreRecordedAttrs(attrs);
    }
    void discard() { closeOwnOperation(false); }
    void gestureBegins() { sessionStepBegins(); }
    void gestureEnds() { sessionStepEnds(); }
    // A viewport gesture of the same tool: its own step, begun and ended.
    void haulStep(float to) {
        sessionStepBegins();
        shift = to;
        onParamChanged("shift");
        sessionStepEnds();
    }
}

unittest { // a scrub (held widget) records one row; discrete writes record one each
    foreach (held; [true, false]) {
        Mesh m = makeCube();
        auto h = new CommandHistory();
        auto t = new ScrubTopologyTool;
        t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
        t.basis = MeshSnapshot.capture(m);
        Tool active = t;
        auto s = new EditSession(() => active, h, () { active = null; });
        s.noteArm("t.scrub", 1);
        const depth = h.undoEntries().length;
        const writes = held ? 5 : 2;
        foreach (i; 0 .. writes) {
            auto before = t.captureAttrImage();
            t.shift = 0.1f * (i + 1);
            s.orchestrateParameterChange(t, "shift",
                ParameterChangeSource.InteractiveValue,
                ParameterChangePhase.ValueWritten, before, held);
            s.orchestrateParameterChange(t, "",
                ParameterChangeSource.InteractiveValue,
                ParameterChangePhase.BatchComplete);
            if (held)
                assert(s.parameterStepHeld(t, "shift")
                    && h.undoEntries().length == depth,
                    "8290: a held write closed its step before the widget let go");
        }
        s.releaseParameterStep();
        const rows = h.undoEntries().length - depth;
        assert(rows == (held ? 1 : writes),
            format("8290: %s writes (held=%s) recorded %s rows, expected %s",
                   writes, held, rows, held ? 1 : writes));
        assert(!s.parameterStepHeld(t, "shift"), "8290: release left the step held");
    }
}

unittest { // a gesture that begins while a widget holds a step closes it first
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new ScrubTopologyTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.scrub", 1);
    const depth = h.undoEntries().length;
    auto before = t.captureAttrImage();
    t.shift = 0.3f;
    s.orchestrateParameterChange(t, "shift", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.ValueWritten, before, true);
    s.orchestrateParameterChange(t, "", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.BatchComplete);
    assert(s.parameterStepHeld(t, "shift") && h.undoEntries().length == depth,
        "8290 takeover rig: the held write did not stay open");
    t.haulStep(0.7f);
    assert(!s.parameterStepHeld(t, "shift"),
        "8290: a gesture step left the widget's step held");
    s.releaseParameterStep();   // the widget lets go AFTER the gesture
    const rows = h.undoEntries().length - depth;
    assert(rows == 2, format("8290: held write + gesture recorded %s rows, expected 2 "
        ~ "(the release must not close the gesture's step)", rows));
    assert(m.vertices[0].y > 0.19f && m.vertices[0].y < 0.21f, // cube y -0.5 + 0.7
        format("8290: the gesture's geometry was lost: y=%s", m.vertices[0].y));
}

unittest { // an operation that ends under a held widget forgets the hold
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new ScrubTopologyTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.scrub", 1);
    const depth = h.undoEntries().length;
    void heldWrite(float v) {
        auto before = t.captureAttrImage();
        t.shift = v;
        s.orchestrateParameterChange(t, "shift", ParameterChangeSource.InteractiveValue,
            ParameterChangePhase.ValueWritten, before, true);
        s.orchestrateParameterChange(t, "", ParameterChangeSource.InteractiveValue,
            ParameterChangePhase.BatchComplete);
    }
    heldWrite(0.3f);
    t.discard();                 // RMB: the pending step is discarded
    assert(h.undoEntries().length == depth, "8290 discard rig recorded a row");
    heldWrite(0.4f);             // a NEW hold must open its own step
    s.releaseParameterStep();
    const rows = h.undoEntries().length - depth;
    assert(rows == 1, format("8290: a hold that outlived its discarded operation "
        ~ "swallowed the next write: %s rows, expected 1", rows));
}

unittest { // a field write that lands inside a gesture's step joins that step
    Mesh m = makeCube();
    const base = MeshSnapshot.capture(m);
    auto h = new CommandHistory();
    auto t = new ScrubTopologyTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.scrub", 1);
    const depth = h.undoEntries().length;
    t.gestureBegins();
    t.shift = 0.5f; t.onParamChanged("shift");
    auto before = t.captureAttrImage();
    t.shift = 0.6f;
    s.orchestrateParameterChange(t, "shift", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.ValueWritten, before, false);
    s.orchestrateParameterChange(t, "", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.BatchComplete);
    t.shift = 0.7f; t.onParamChanged("shift");
    t.gestureEnds();
    const rows = h.undoEntries().length - depth;
    assert(rows == 1, format("8290: a write inside a gesture split it into %s rows", rows));
    h.undo();
    assert(base.matches(m),
        "8290: undo of the gesture did not return to its start — the write "
        ~ "inside it re-based the gesture's step mid-flight");
}

// ---- plan 8646 [R1-8, R2-2]: the press flag is decided by the DOOR ---------
//
// Only the tool's own link door (`Tool.sessionStepBegins`) is a press; every
// internal `stepBegins` — the arm-apply, an Action write, a topology parameter
// write — passes `false`. The flag is recorded on the row
// (`MeshSessionEdit.stepOpenedByPress`) and reported as `pendingPress`.

private class PressFlagTool : Tool, TopologyStepClient {
    Mesh* m;
    CommandHistory h;
    View view;
    float v = 0.0f;
    bool act;
    MeshSnapshot basis;
    JSONValue delegate() state;   // the session's report, read mid-step
    JSONValue seen;               // `pendingPress` as the step's write saw it
    bool nullCarrier;             // the carrier is not wired
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.firstPress, imageAttrs: ["v"]
        };
        return policy;
    }
    override Param[] params() {
        return [Param.float_("v", "V", &v, 0.0f),
                Param.bool_("act", "Act", &act, false).action()];
    }
    override void onParamChanged(string) {
        if (state !is null) seen = state()["pendingPress"];
        m.vertices[0].y += 1.0f;
    }
    override Mesh* topologyStepMesh() { return m; }
    override MeshSnapshot topologyStepBasis() { return basis; }
    override Command topologyStepCarrier() {
        import commands.mesh.session_edit : MeshSessionEdit;
        if (nullCarrier) return null;
        return new MeshSessionEdit(m, view, EditMode.Polygons, "t.press", "Press");
    }
    override bool recordTopologyStep(Command cmd) { h.record(cmd); return true; }
    override string topologyStepLabel() { return "Press"; }
    override void setTopologyDormant(bool) {}
    override void rebaseTopologyStep(MeshSnapshot) {}
    override void restoreTopologyStep(in AttrImage attrs, MeshSnapshot b) {
        basis = b;
        restoreRecordedAttrs(attrs);
    }
    void pressBegins() { sessionStepBegins(); }
    PressActivation pa() { return sessionPressActivation(); }
    void pressEnds() { sessionStepEnds(); }
    void middleBegins() { sessionStepBegins(PressKind.middle); }
    MeshSnapshot openImage() { return sessionStepOpenImage(); }
}

private bool lastRowByPress(CommandHistory h) {
    import commands.mesh.session_edit : MeshSessionEdit;
    auto row = cast(const MeshSessionEdit) h.undoEntries()[$ - 1].cmd;
    assert(row !is null && row.isTopologyStep(), "8646 press flag: the top row is no topology step");
    return row.stepOpenedByPress();
}

unittest { // a press through the link is a press; a parameter write and an Action are not
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new PressFlagTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.press", 1);
    t.state = () => s.sessionStateJson();

    // Positive half first: the link door opens a press, reported and recorded.
    t.pressBegins();
    assert(s.sessionStateJson()["pendingPress"].type == JSONType.true_,
        "8646 press flag: a step opened through the tool's link must report pendingPress");
    m.vertices[0].y += 1.0f;
    t.pressEnds();
    assert(h.undoEntries().length == 1 && lastRowByPress(h),
        "8646 press flag: the link press's row must say stepOpenedByPress");

    // A topology parameter step: not a press, while pending and on its row.
    auto before = t.captureAttrImage();
    t.v = 0.5f;
    s.orchestrateParameterChange(t, "v", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.ValueWritten, before);
    s.orchestrateParameterChange(t, "", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.BatchComplete);
    assert(t.seen.type == JSONType.false_,
        format("8646 press flag: a parameter step reported pendingPress %s", t.seen));
    assert(h.undoEntries().length == 2 && !lastRowByPress(h),
        "8646 press flag: a parameter step's row must not say stepOpenedByPress");

    // An Action write (`actionStepBegins`): not a press while its step is open.
    // Written through the UI door: a SCRIPTED write first ends the operation
    // (task 8930, M-PS — the half below), and its step is then attribute-only.
    t.seen = JSONValue.init;
    t.act = true;
    s.orchestrateParameterChange(t, "act", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.ValueWritten);
    s.orchestrateParameterChange(t, "", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.BatchComplete);
    assert(t.seen.type == JSONType.false_ && h.undoEntries().length == 3
           && !lastRowByPress(h),
        format("8646 press flag: an Action step reported pendingPress %s (rows %s)",
               t.seen, h.undoEntries().length));

    // Task 8930, M-PS: a scripted write while armed ends the operation with no
    // row: the post mode disarms, the operation closes, the history stays.
    assert(s.sessionStateJson()["operationOpen"].type == JSONType.true_
           && s.sessionStateJson()["armed"].type == JSONType.true_,
        "S2b M-PS rig: the operation is not open and armed before the scripted write");
    t.act = false;
    s.orchestrateParameterChange(t, "act", ParameterChangeSource.ScriptedValue,
        ParameterChangePhase.ValueWritten);
    s.orchestrateParameterChange(t, "", ParameterChangeSource.ScriptedValue,
        ParameterChangePhase.BatchComplete);
    assert(s.sessionStateJson()["operationOpen"].type == JSONType.false_
           && s.sessionStateJson()["armed"].type == JSONType.false_
           && h.undoEntries().length == 3,
        format("S2b M-PS: a scripted write left operationOpen %s armed %s (rows %s)",
               s.sessionStateJson()["operationOpen"], s.sessionStateJson()["armed"],
               h.undoEntries().length));
}

/// A topology stand-in whose ARM applies it (`opensAt: arm` + `armAttr`): the
/// arm-apply step is pending exactly while the arm attribute is applied, so the
/// report is read there.
private final class ArmTopologyTool : Tool, TopologyStepClient {
    Mesh* m;
    View view;
    bool on;
    JSONValue delegate() state;
    JSONValue seen;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.arm, imageAttrs: ["on"], armAttr: "on"
        };
        return policy;
    }
    override Param[] params() { return [Param.bool_("on", "On", &on, false)]; }
    override void rebuildPreviewFromAttrs() {
        if (state !is null) seen = state()["pendingPress"];
    }
    override Mesh* topologyStepMesh() { return m; }
    override MeshSnapshot topologyStepBasis() { return MeshSnapshot.init; }
    override Command topologyStepCarrier() { return null; }
    override bool recordTopologyStep(Command) { return false; }
    override string topologyStepLabel() { return "Arm"; }
    override void setTopologyDormant(bool) {}
    override void rebaseTopologyStep(MeshSnapshot) {}
    override void restoreTopologyStep(in AttrImage attrs, MeshSnapshot) {
        restoreRecordedAttrs(attrs);
    }
    void pressBegins() { sessionStepBegins(); }
    void pressEnds() { sessionStepEnds(); }
}

unittest { // the arm-apply entry (`opensAt: arm` + `armAttr`) is not a press
    Mesh m = makeCube();
    auto t = new ArmTopologyTool;
    t.m = &m; t.view = new View(0, 0, 1, 1);
    Tool active = t;
    auto h = new CommandHistory();
    auto s = new EditSession(() => active, h, () { active = null; });
    t.state = () => s.sessionStateJson();
    s.noteArm("t.armtopo");
    assert(t.on && t.seen.type == JSONType.false_,
        format("8646 press flag: the arm-apply step reported pendingPress %s (on %s)", t.seen, t.on));
}

unittest { // plan 8646 [R1-m]: the press image is the session's own, handed out shared
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new PressFlagTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    assert(!t.openImage().filled, "8646 open image: an unbound tool has none");
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.press", 1);
    assert(!t.openImage().filled, "8646 open image: no step open, no image");
    t.pressBegins();
    auto a = t.openImage(), b = t.openImage();
    assert(a.filled && a.matches(m) && a.vertices.ptr is b.vertices.ptr,
        "8646 open image: the open step's image must be the mesh at the press, one shared capture");
    m.vertices[0].y += 1.0f;
    assert(t.openImage().vertices[0].y != m.vertices[0].y,
        "8646 open image: the image must not alias the live mesh");
    t.pressEnds();
    assert(!t.openImage().filled, "8646 open image: an ended step has no image");
}

unittest { // the open image is the PENDING step's: none after a step that recorded nothing
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new PressFlagTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    t.nullCarrier = true;
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.press", 1);
    t.pressBegins();
    assert(t.openImage().filled, "8646 open image: rig floor, the press opened a step");
    t.pressEnds();
    assert(h.undoEntries().length == 0 && !t.openImage().filled,
        "8646 open image: a step that ended with no carrier still has no open image");
}

unittest { // a stale instance gets no image of the tool the session now tracks
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto a = new PressFlagTool, b = new PressFlagTool;
    foreach (t; [a, b]) {
        t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
        t.basis = MeshSnapshot.capture(m);
    }
    Tool active = a;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.press", 1);
    active = b;
    s.noteArm("t.press", 2);
    b.pressBegins();
    assert(b.openImage().filled && !a.openImage().filled,
        "8646 open image: only the instance the session tracks may read its open image");
    b.pressEnds();
}

// ---- wave plan 8646 §9.25 [A13-2]: a no-op row reuses the session's images --
//
// `ToolSession.stepEnds` takes `after` as the pending image when the mesh
// still `matches` it, and `stepBegins` takes the last recorded row's `after`
// as the next pending image on the same test, so a motionless press holds no
// fresh copy. The identity reads go through the PRODUCTION carrier's own
// fields (`.tupleof`, which ignores protection): the images the history row
// replays, not a stand-in's.

/// The `before` (`which == "before"`) or `after` image a recorded
/// `MeshSessionEdit` row replays.
private const(MeshSnapshot) rowImage(CommandHistory h, size_t k, string which) {
    import commands.mesh.session_edit : MeshSessionEdit;
    auto row = cast(const MeshSessionEdit) h.undoEntries()[k].cmd;
    assert(row !is null, format("8646 reuse: row %d is no MeshSessionEdit", k));
    foreach (i, ref f; row.tupleof)
        static if (__traits(identifier, MeshSessionEdit.tupleof[i]) == "before"
                   || __traits(identifier, MeshSessionEdit.tupleof[i]) == "after")
            if (__traits(identifier, MeshSessionEdit.tupleof[i]) == which) return f;
    assert(0, "8646 reuse: MeshSessionEdit has no field " ~ which);
}

private struct ReuseRig {
    Mesh* m;
    CommandHistory h;
    PressFlagTool t;
    EditSession s;
    void step(scope void delegate() body_ = null) {
        t.pressBegins();
        if (body_ !is null) body_();
        t.pressEnds();
    }
}

private ReuseRig reuseRig() {
    ReuseRig r;
    r.m = new Mesh;
    *r.m = makeCube();
    r.h = new CommandHistory();
    r.t = new PressFlagTool;
    r.t.m = r.m; r.t.h = r.h; r.t.view = new View(0, 0, 1, 1);
    r.t.basis = MeshSnapshot.capture(*r.m);
    Tool active = r.t;
    r.s = new EditSession(() => active, r.h, () { active = null; });
    r.s.noteArm("t.press", 1);
    return r;
}

unittest { // noop-rows-share: motionless rows share storage within and across rows
    auto r = reuseRig();
    assert(r.h.undoEntries().length == 0, "8646 reuse: rig headroom, the history starts empty");
    foreach (k; 0 .. 20) r.step();
    assert(r.h.undoEntries().length == 20,
        format("8646 reuse: 20 motionless steps recorded %d rows", r.h.undoEntries().length));
    size_t within, across;
    foreach (k; 0 .. 20) {
        assert(rowImage(r.h, k, "before").vertices.ptr is rowImage(r.h, k, "after").vertices.ptr,
            format("8646 reuse: no-op row %d holds two copies (before and after do not share)", k));
        ++within;
        if (k + 1 < 20) {
            assert(rowImage(r.h, k, "after").vertices.ptr
                   is rowImage(r.h, k + 1, "before").vertices.ptr,
                format("8646 reuse: row %d's after does not share with row %d's before", k, k + 1));
            ++across;
        }
    }
    assert(within == 20 && across == 19, "8646 reuse: the share population is 20 + 19");
}

unittest { // moved-row-not-shared: a moved row holds its own after; undo/redo are exact
    auto r = reuseRig();
    auto a0 = MeshSnapshot.capture(*r.m);
    r.step();                                   // row 0: no-op
    r.step(() { r.m.vertices[0].y += 1.0f; });  // row 1: moved
    auto moved = MeshSnapshot.capture(*r.m);
    r.step();                                   // row 2: no-op on the moved image
    assert(r.h.undoEntries().length == 3, "8646 reuse: three steps, three rows");
    // Behaviour first (the replayed images), storage after it.
    foreach (k; 0 .. 3) assert(r.h.undo(), format("8646 reuse: undo %d refused", k));
    assert(a0.matches(*r.m), "8646 reuse: undo of every row must restore the arm image bit for bit");
    assert(r.h.redo() && a0.matches(*r.m), "8646 reuse: redo of the no-op row is the arm image");
    assert(r.h.redo() && moved.matches(*r.m),
        "8646 reuse: redo of the moved row must restore the MOVED image");
    assert(rowImage(r.h, 1, "before").vertices.ptr !is rowImage(r.h, 1, "after").vertices.ptr,
        "8646 reuse: the moved row's before and after must not share");
    // An image the history put back between two steps: the next step's before
    // is that image, not the last recorded after it no longer matches.
    assert(r.h.undo() && a0.matches(*r.m), "8646 reuse: undo of the moved row again");
    r.step();                                   // a fresh no-op row on a0 (drops the redo)
    assert(r.h.undoEntries().length == 2 && rowImage(r.h, 1, "before").matches(*r.m),
        "8646 reuse: a step after an undo must start from the restored image");
    assert(r.h.undo() && a0.matches(*r.m),
        "8646 reuse: undo of the step after an undo must restore the image it started from");
}

unittest { // a re-arm releases the reused image (§9.25 N3: ~25 MB a 50k-vertex row)
    auto r = reuseRig();
    r.step();
    assert(r.h.undoEntries().length == 1, "8646 reuse: rig floor, one row");
    r.s.noteArm("t.press", 2);
    r.step();
    assert(r.h.undoEntries().length == 2, "8646 reuse: the second arm's step is a row");
    assert(rowImage(r.h, 0, "after").vertices.ptr !is rowImage(r.h, 1, "before").vertices.ptr,
        "8646 reuse: a new operation must not keep the last one's image alive");
}

// (8) Wave plan 8640 S6 (§9.6 D6'): a user drop writes a drop row for exactly
// the three user exits, over EVERY transition (the population is the enum's
// compile-time length, never a literal).
unittest {
    size_t visited;
    ToolTransition[] writes;
    foreach (t; EnumMembers!ToolTransition) {
        ++visited;
        if (dropWritesRowFor(t)) writes ~= t;
    }
    assert(visited == EnumMembers!ToolTransition.length,
        format("S6 dropWritesRowFor: visited %s of %s transitions", visited,
               EnumMembers!ToolTransition.length));
    assert(writes == [ToolTransition.explicitDrop, ToolTransition.sameIdToggleDrop,
                      ToolTransition.selTypeFlipDrop],
        format("S6 dropWritesRowFor: rows for %s, expected the three user exits", writes));
}

// (9) S6 [A6-1], L32: a drop row's undo empties the redo stack through the
// existing CommandHistory.undo rule — its stored bit wins over the
// predecessor-topology term that keeps a switch row's redo.
unittest {
    Mesh m = makeCube();
    auto v = new View(0, 0, 1, 1);
    auto h = new CommandHistory();
    auto keep = new ToolActivationCommand(&m, v, EditMode.Vertices, "t.other", "t.pen",
        false, false, false, 0, 0, true, true);
    auto drop = new ToolActivationCommand(&m, v, EditMode.Vertices, "", "t.pen",
        false, false, false, 0, 0, true, true, false, true);
    assert(keep.carriesRedoAfterUndo() && !keep.dropRow(),
        "S6 control: a switch row over a topology predecessor keeps its redo");
    assert(!drop.carriesRedoAfterUndo() && drop.dropRow() && drop.label() == "Tool Drop",
        "S6: a drop row must not carry its redo after its undo (L32)");
    h.recordToolLifecycle(keep);
    assert(h.undo() && h.redoEntries().length == 1, "S6 control: the switch row's undo keeps redo");
    h.recordToolLifecycle(drop);   // a new record clears the switch row's redo
    assert(h.undoEntries().length == 1 && h.redoEntries().length == 0, "S6 rig: one drop row");
    // The Esc rung's task row above it: its undo keeps redo (X-esc-r R-task).
    h.recordToolLifecycle(new ToolTaskClearCommand(&m, v, EditMode.Vertices));
    assert(h.undo() && h.redoEntries().length == 1, "S6: the task row's undo must keep its redo");
    assert(h.undo() && h.redoEntries().length == 0,
        format("S6: undoing the drop row must empty the redo stack, %s left",
               h.redoEntries().length));
}

// (10) S6 review: a drop row is written only by the close that took it. An
// aborted drop (its door threw before `finishClose`) leaves it pending; a held-
// button refusal of the command close that follows must not let the funnel's
// `finishClose` write it late, and the door's own `abandonDropRow` drops it.
unittest {
    import held_gesture_buttons : g_heldGestureButtons;
    auto r = rig();
    size_t drops, tasks;
    r.session.installDropRows(
        (const DropRowSpec s) { ++drops; return cast(Command) null; },
        () { ++tasks; return cast(Command) null; });
    DropContext esc;
    esc.clearsTask = true;
    // Control: a drop that runs to `finishClose` writes its row (and the Esc
    // rung's task row), once.
    r.session.closeOperation(CloseReason.drop, CommandDoor.ui, true, esc);
    r.session.finishClose();
    assert(drops == 1 && tasks == 1,
           format("S6 abort control: a completed drop wrote %s drop / %s task rows, expected 1 / 1",
                  drops, tasks));
    // An aborted drop, then a held-button command close and its funnel finish.
    r.session.noteArm("t.step", 2);
    r.session.closeOperation(CloseReason.drop, CommandDoor.ui, true, esc);
    g_heldGestureButtons.press(1);
    scope (exit) g_heldGestureButtons.clear();
    const o = r.session.closeOperation(CloseReason.command, CommandDoor.ui);
    g_heldGestureButtons.clear();
    r.session.finishClose();
    assert(!o.dropsTool && drops == 1,
           format("S6 abort: a refused command close let the funnel write a stale drop row (%s rows)",
                  drops));
    // The door's own abandon, with no close between.
    r.session.noteArm("t.step", 3);
    r.session.closeOperation(CloseReason.drop, CommandDoor.ui, true, esc);
    r.session.abandonDropRow();
    r.session.finishClose();
    assert(drops == 1 && tasks == 1,
           format("S6 abort: an abandoned drop still wrote its row (%s drop / %s task rows)",
                  drops, tasks));
}

// ---- wave plan 8640 S7a: the operation context and the parameter-row fold ----
//
// A topology stand-in whose policy is either the plain one or carries the two
// S7a data AS THE PEN DECLARES THEM (read from `TopologyPenTool.sessionPolicy()`,
// so a pen policy that dropped either datum turns these cells into the "off"
// arm). `v` is its haul (the operation context), `k` an ordinary attribute.

private ToolSessionPolicy foldPolicy(bool on) {
    import tools.edit.topology_pen : TopologyPenTool;
    ToolSessionPolicy p = { activationRow: true, sessionSteps: true,
        historyTopologySteps: true, opensAt: OpensAt.firstPress,
        imageAttrs: ["v", "k"], haulAttrs: ["v"] };
    if (on) {
        const pen = (new TopologyPenTool).sessionPolicy();
        p.pressOpensOperation = pen.pressOpensOperation;
        p.foldsParamRowsIntoBlock = pen.foldsParamRowsIntoBlock;
    }
    return p;
}

private final class FoldTool : Tool, TopologyStepClient {
    Mesh* m;
    CommandHistory h;
    View view;
    float v = 0.0f, k = 0.0f;
    ToolSessionPolicy pol;
    this(bool on) { pol = foldPolicy(on); }
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc { return pol; }
    override Param[] params() {
        return [Param.float_("v", "V", &v, 0.0f), Param.float_("k", "K", &k, 0.0f)];
    }
    override Mesh* topologyStepMesh() { return m; }
    override MeshSnapshot topologyStepBasis() { return MeshSnapshot.init; }
    override Command topologyStepCarrier() {
        import commands.mesh.session_edit : MeshSessionEdit;
        return new MeshSessionEdit(m, view, EditMode.Polygons, "t.fold", "Fold");
    }
    override bool recordTopologyStep(Command cmd) { h.record(cmd); return true; }
    override string topologyStepLabel() { return "Fold"; }
    override void setTopologyDormant(bool) {}
    override void rebaseTopologyStep(MeshSnapshot) {}
    override void restoreTopologyStep(in AttrImage attrs, MeshSnapshot) {
        restoreRecordedAttrs(attrs);
    }
    void press() { sessionStepBegins(); }
    void release() { sessionStepEnds(); }
}

private void foldWrite(EditSession s, FoldTool t, float value) {
    auto before = t.captureAttrImage();
    t.k = value;
    s.orchestrateParameterChange(t, "k", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.ValueWritten, before);
    s.orchestrateParameterChange(t, "", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.BatchComplete);
}

private uint flagsAt(CommandHistory h, size_t i) { return h.undoEntries()[i].flags; }

unittest { // S7a: a PodArray of uint and of Vec3 (the descriptor's kinds) round-trip raw
    uint[] verts = [5, 9, 10];
    Vec3[] orig = [Vec3(1, 2, 3), Vec3(-4, 0.5f, 6)];
    auto pv = Param.podArray_("stepVerts", "V", &verts);
    auto po = Param.podArray_("stepOrig", "O", &orig);
    const rv = pv.snapshotRaw(), ro = po.snapshotRaw();
    verts = [1];
    orig = null;
    pv.restoreRaw(rv);
    po.restoreRaw(ro);
    assert(verts == [5u, 9, 10] && orig == [Vec3(1, 2, 3), Vec3(-4, 0.5f, 6)],
           format("S7a raw round trip: verts %s orig %s", verts, orig));
    // The empty image restores empty (a press's reset descriptor).
    uint[] none;
    auto pn = Param.podArray_("stepVerts", "V", &none);
    const rn = pn.snapshotRaw();
    none = [7];
    pn.restoreRaw(rn);
    assert(none.length == 0, format("S7a raw round trip: the empty image restored %s", none));
}

unittest { // S7a u1, M-C (a) + M-H: the press resets the haul; a row's haul comes back only into its instance
    import command_history : HistoryFlags;
    import commands.mesh.session_edit : MeshSessionEdit;
    size_t cells;
    foreach (on; [false, true]) foreach (same; [true, false]) {
        Mesh m = makeCube();
        auto h = new CommandHistory();
        auto t1 = new FoldTool(on);
        t1.m = &m; t1.h = h; t1.view = new View(0, 0, 1, 1);
        t1.v = 3.0f;
        Tool active = t1;
        auto s = new EditSession(() => active, h, () { active = null; });
        s.noteArm("t.fold", 1);
        t1.press();
        assert(t1.v == (on ? 0.0f : 3.0f),
               format("S7a u1 (on %s): the press left the haul at %s (reader (a))", on, t1.v));
        t1.v = 5.0f; t1.k = 7.0f;
        m.vertices[0].y += 1.0f;
        t1.release();
        auto row = cast(const MeshSessionEdit)h.undoEntries()[$ - 1].cmd;
        assert(row !is null && row.stepInstance() == t1.preparedLifecycleOwner().value,
               "S7a u1: the row does not carry its recording instance");
        assert(s.navigate(true));
        assert(t1.v == (on ? 0.0f : 3.0f) && t1.k == 0.0f,
               format("S7a u1 (on %s): undo showed v %s k %s, not the open image", on, t1.v, t1.k));
        auto t2 = new FoldTool(on);
        t2.m = &m; t2.h = h; t2.view = t1.view;
        t2.v = 9.0f;
        if (!same) { active = t2; s.noteArm("t.fold", 1); }   // a re-armed instance, same session
        assert(s.navigate(false));
        auto cur = same ? t1 : t2;
        // Test tool FoldTool(off) is in the captured model: in a re-armed instance the
        // row is an orphan and its redo keeps the live image (law 4, model doc §R9; task
        // 9020 — was M-H's v 5 k 7). FoldTool(on) is the pen's data: M-H, unchanged.
        const orphan = !on && !same;
        const wantV = orphan || (on && !same) ? 9.0f : 5.0f;
        const wantK = orphan ? 0.0f : 7.0f;
        assert(cur.v == wantV && cur.k == wantK,
               format("S7a u1 (on %s, same instance %s): redo restored v %s k %s, expected v %s k %s",
                      on, same, cur.v, cur.k, wantV, wantK));
        ++cells;
    }
    assert(cells == 4, format("S7a u1: %s of the four images checked", cells));
}

unittest { // S7a u2, the fold: two pre-press rows fold into the activation at the press; off: none
    import command_history : HistoryFlags;
    foreach (on; [true, false]) {
        Mesh m = makeCube();
        auto h = new CommandHistory();
        auto t = new FoldTool(on);
        t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
        Tool active = t;
        auto s = new EditSession(() => active, h, () { active = null; });
        auto act = tokenRow(&m, "t.fold", "", true, false, 5);
        act.onDeactivate = () { active = null; };
        h.recordToolLifecycle(act);
        s.noteArm("t.fold", 5);
        foldWrite(s, t, 1.0f);
        foldWrite(s, t, 2.0f);
        t.press();
        m.vertices[0].y += 1.0f;
        t.release();
        assert(h.undoEntries().length == 4, format("S7a u2 rig: depth %s", h.undoEntries().length));
        size_t marked;
        foreach (i; 1 .. 3) if (flagsAt(h, i) & HistoryFlags.JoinsBelow) ++marked;
        assert(marked == (on ? 2 : 0) && !(flagsAt(h, 3) & HistoryFlags.JoinsBelow),
               format("S7a u2 (on %s): %s rows marked JoinsBelow", on, marked));
        assert(s.navigate(true) && h.undoEntries().length == 3, "S7a u2: the press did not pop alone");
        assert(s.navigate(true));
        assert(h.undoEntries().length == (on ? 0 : 2) && (active is null) == on,
               format("S7a u2 (on %s): the next undo left depth %s, tool %s", on,
                      h.undoEntries().length, active !is null));
    }
}

unittest { // S7a u3: a press whose walk meets a foreign-token row marks none
    import command_history : HistoryFlags;
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new FoldTool(true);
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    h.recordToolLifecycle(tokenRow(&m, "t.fold", "", true, false, 5));
    s.noteArm("t.fold", 5);
    foldWrite(s, t, 1.0f);
    // Another session's parameter row: every term of a fold row but the token.
    import commands.mesh.session_edit : MeshSessionEdit;
    auto foreign = new MeshSessionEdit(&m, t.view, EditMode.Polygons, "t.other", "Other");
    auto snap = MeshSnapshot.capture(m);
    foreign.setSnapshots(snap, snap);
    foreign.setTopologyStep(AttrImage.init, AttrImage.init, MeshSnapshot.init, MeshSnapshot.init,
                            false, t.preparedLifecycleOwner().value, StepOrigin.unclassified, 0);
    foreign.markSession(6);
    h.record(foreign);
    t.press();
    t.release();
    assert(h.undoEntries().length == 4 && h.undoEntries()[2].cmd is foreign,
           format("S7a u3 rig: depth %s", h.undoEntries().length));
    assert(!(flagsAt(h, 1) & HistoryFlags.JoinsBelow),
           "S7a u3: the walk crossed a foreign row and folded the parameter row");
}

// ---- Task 8920 (topology-redo wave S2a): the settle after a navigation -------

unittest { // a navigation before any arm: no tool, nothing bound — the settle asks no tool
    import edit_session : EditSession;
    import view : View;
    auto h = new CommandHistory();
    Tool none = null;
    auto s = new EditSession(() => none, h, () {});
    auto row = new Stub(new View(0, 0, 1, 1));
    assert(row.apply());
    h.record(row);
    assert(h.undoEntries().length == 1, "S2a settle: the rig recorded no row");
    // The undo moves the stack (the settle runs) with no tool and an unbound
    // session: it must step the history and touch no tool.
    assert(s.navigate(true) && h.undoEntries().length == 0 && h.redoEntries().length == 1,
           "S2a settle: an undo before any arm did not step the history");
    assert(s.navigate(false) && h.undoEntries().length == 1,
           "S2a settle: a redo before any arm did not step the history");
}

// ---- Task 8930 (topology-redo wave S2b): the operation-state invariant ------
//
// `model && operationOpen_ ⇒ postmodeArmed_`, checked after EVERY step of two
// sequences written out in the wave plan (S2b R7): PressFlagTool — script arm,
// haul, haul, attr:panel, undo, redo, undo, undo, redo, attr:script, haul,
// attr:panel (12); ArmTopologyTool — arm, attr:panel, haul, attr:script,
// attr:panel, undo, redo (7). Floor: exactly 19 checks. A haul is the
// production order: the pointer-down report, then the tool's press door.

private void s2bHaul(EditSession s, void delegate() begins, void delegate() ends, Mesh* m) {
    s.notePointerDown();
    begins();
    m.vertices[1].x += 0.25f;
    ends();
}

private void s2bAttr(EditSession s, Tool t, string name, void delegate() write,
                     ParameterChangeSource src) {
    auto before = t.captureAttrImage();
    write();
    s.orchestrateParameterChange(t, name, src, ParameterChangePhase.ValueWritten,
        src == ParameterChangeSource.InteractiveValue ? before : AttrImage.init);
    s.orchestrateParameterChange(t, "", src, ParameterChangePhase.BatchComplete);
}

private void s2bCheck(EditSession s, ref size_t checked, string at) {
    const st = s.sessionStateJson();
    assert(st.type == JSONType.object, "S2b invariant: no session report at " ~ at);
    assert(st["operationOpen"].type != JSONType.true_ || st["armed"].type == JSONType.true_,
        "S2b invariant: an open operation with the post mode not armed at " ~ at);
    ++checked;
}

unittest { // S2b invariant: an open operation is always an armed post mode
    size_t checked;
    {
        Mesh m = makeCube();
        auto h = new CommandHistory();
        auto t = new PressFlagTool;
        t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
        t.basis = MeshSnapshot.capture(m);
        Tool active = t;
        auto s = new EditSession(() => active, h, () { active = null; });
        enum ia = ParameterChangeSource.InteractiveValue, sc = ParameterChangeSource.ScriptedValue;
        s.noteArm("t.press", 1, false);                       s2bCheck(s, checked, "press: arm");
        s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);         s2bCheck(s, checked, "press: haul 1");
        s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);         s2bCheck(s, checked, "press: haul 2");
        s2bAttr(s, t, "v", () { t.v = 0.5f; }, ia);           s2bCheck(s, checked, "press: attr:panel");
        s.navigate(true);                                     s2bCheck(s, checked, "press: undo 1");
        s.navigate(false);                                    s2bCheck(s, checked, "press: redo 1");
        s.navigate(true);                                     s2bCheck(s, checked, "press: undo 2");
        s.navigate(true);                                     s2bCheck(s, checked, "press: undo 3");
        s.navigate(false);                                    s2bCheck(s, checked, "press: redo 2");
        s2bAttr(s, t, "v", () { t.v = 0.75f; }, sc);          s2bCheck(s, checked, "press: attr:script");
        s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);         s2bCheck(s, checked, "press: haul 3");
        s2bAttr(s, t, "v", () { t.v = 0.25f; }, ia);          s2bCheck(s, checked, "press: attr:panel 2");
    }
    {
        Mesh m = makeCube();
        auto h = new CommandHistory();
        auto t = new ArmTopologyTool;
        t.m = &m; t.view = new View(0, 0, 1, 1);
        Tool active = t;
        auto s = new EditSession(() => active, h, () { active = null; });
        enum ia = ParameterChangeSource.InteractiveValue, sc = ParameterChangeSource.ScriptedValue;
        s.noteArm("t.armtopo", 1);                            s2bCheck(s, checked, "arm: arm");
        s2bAttr(s, t, "on", () { t.on = false; }, ia);        s2bCheck(s, checked, "arm: attr:panel");
        s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);         s2bCheck(s, checked, "arm: haul");
        s2bAttr(s, t, "on", () { t.on = true; }, sc);         s2bCheck(s, checked, "arm: attr:script");
        s2bAttr(s, t, "on", () { t.on = false; }, ia);        s2bCheck(s, checked, "arm: attr:panel 2");
        s.navigate(true);                                     s2bCheck(s, checked, "arm: undo");
        s.navigate(false);                                    s2bCheck(s, checked, "arm: redo");
    }
    import std.stdio : writefln;
    writefln("S2b invariant: checked=%s", checked);
    assert(checked == 19, format("S2b invariant: %s steps checked, the plan's sequences hold 19",
        checked));
}

private const(imported!"commands.mesh.session_edit".MeshSessionEdit) s2bTopRow(CommandHistory h) {
    import commands.mesh.session_edit : MeshSessionEdit;
    auto row = cast(const MeshSessionEdit) h.undoEntries()[$ - 1].cmd;
    assert(row !is null && row.isTopologyStep(), "S2b: the undo top is no topology step");
    return row;
}

unittest { // S2b: the operation belongs to the token — a re-arm under Suspend starts its own
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new PressFlagTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.press", 1, false);
    s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);
    const first = s2bTopRow(h);
    assert(first.stepOrigin() == StepOrigin.opens && first.stepOperation() != 0,
        format("S2b token rig: the first haul is %s / operation %s, expected opens", first.stepOrigin(),
               first.stepOperation()));
    {   // a replay arm of the same id with a NEW token, inside a history step
        auto g = h.suspended();
        s.noteArm("t.press", 2);
    }
    s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);
    const second = s2bTopRow(h);
    assert(second.stepOperation() != first.stepOperation() && second.stepOrigin() != StepOrigin.refire,
        format("S2b: a re-arm under Suspend continued the old token's operation %s (origin %s)",
               second.stepOperation(), second.stepOrigin()));
}

unittest { // S2b M-PR: a panel write in a re-begun post mode is its own operation and leaves it closed
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new PressFlagTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.press", 1, false);
    s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);
    assert(s.navigate(true) && s.navigate(false), "S2b M-PR rig: the undo/redo did not step");
    const st = s.sessionStateJson();
    assert(st["armed"].type == JSONType.true_ && st["operationOpen"].type == JSONType.false_,
        format("S2b M-PR rig: the redo did not re-begin the post mode closed (N5): %s", st));
    s2bAttr(s, t, "v", () { t.v = 0.5f; }, ParameterChangeSource.InteractiveValue);
    const write = s2bTopRow(h);
    assert(write.stepOrigin() == StepOrigin.restart && !write.stepOpenedByPress(),
        format("S2b M-PR: the write row is %s, expected restart (its own operation)", write.stepOrigin()));
    assert(s.sessionStateJson()["operationOpen"].type == JSONType.false_,
        "S2b M-PR: the write opened the operation (the next press must restart, not refire)");
    s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);
    const haul = s2bTopRow(h);
    assert(haul.stepOrigin() == StepOrigin.restart && haul.stepOperation() != write.stepOperation(),
        format("S2b M-PR: the press after the write is %s / operation %s (write %s), expected a restart",
               haul.stepOrigin(), haul.stepOperation(), write.stepOperation()));
}

unittest { // S2b P1: a panel write inside the open operation refires it (no new operation)
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new PressFlagTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.press", 1, false);
    s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);
    const haul = s2bTopRow(h);
    s2bAttr(s, t, "v", () { t.v = 0.5f; }, ParameterChangeSource.InteractiveValue);
    const write = s2bTopRow(h);
    assert(write !is haul && write.stepOrigin() == StepOrigin.refire
           && write.stepOperation() == haul.stepOperation(),
        format("S2b P1: the panel write is %s of operation %s, expected a refire of the haul's %s",
               write.stepOrigin(), write.stepOperation(), haul.stepOperation()));
}

/// A PressFlagTool session after a script arm (post mode not armed), for the
/// S2b transition cells below.
private struct S2bRig {
    Mesh m;
    CommandHistory h;
    PressFlagTool t;
    Tool active;
    EditSession s;
}

private S2bRig* s2bRig() {
    auto r = new S2bRig;
    r.m = makeCube();
    r.h = new CommandHistory();
    r.t = new PressFlagTool;
    r.t.m = &r.m; r.t.h = r.h; r.t.view = new View(0, 0, 1, 1);
    r.t.basis = MeshSnapshot.capture(r.m);
    r.active = r.t;
    r.s = new EditSession(() => r.active, r.h, () { r.active = null; });
    r.s.noteArm("t.press", 1, false);
    return r;
}

private void s2bHaul(S2bRig* r) { s2bHaul(r.s, &r.t.pressBegins, &r.t.pressEnds, &r.m); }

unittest { // S2b E5: a press inside the open operation refires it
    auto r = s2bRig();
    s2bHaul(r);
    const g1 = s2bTopRow(r.h);
    s2bHaul(r);
    const g2 = s2bTopRow(r.h);
    assert(g1.stepOrigin() == StepOrigin.opens && g2.stepOrigin() == StepOrigin.refire
           && g2.stepOperation() == g1.stepOperation(),
        format("S2b E5: the hauls are %s / %s of operations %s / %s, expected opens then a refire",
               g1.stepOrigin(), g2.stepOrigin(), g1.stepOperation(), g2.stepOperation()));
}

/// PressFlagTool opening at the arm: its begin row records (S5b).
private final class ArmPressTool : PressFlagTool {
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.arm, imageAttrs: ["v"]
        };
        return policy;
    }
}

unittest { // S5b E2: an arm-opening tool's arm writes the begin row, which opens the operation
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new ArmPressTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    // The user arm: the activation leaves the post mode unarmed (`postmodeStartsOnPressFor`).
    s.noteArm("t.armpress", 1, false);
    assert(h.undoEntries().length == 1 && s2bTopRow(h).stepOrigin() == StepOrigin.opens
           && s2bTopRow(h).stepOperation() == s.sessionStateJson()["operation"].integer
           && s.sessionStateJson()["operationOpen"].type == JSONType.true_
           && s.sessionStateJson()["armed"].type == JSONType.true_,
        format("S5b E2: the arm wrote %s rows, state %s — expected one begin row (opens) that "
               ~ "opens the operation and arms the post mode", h.undoEntries().length,
               s.sessionStateJson()));
    s2bHaul(s, &t.pressBegins, &t.pressEnds, &m);
    assert(h.undoEntries().length == 2 && s2bTopRow(h).stepOrigin() == StepOrigin.refire,
        format("S5b E2: the first haul after the begin row is %s, expected a refire",
               s2bTopRow(h).stepOrigin()));
    // A replayed arm (Suspend) finds its begin row in the history: none is written.
    h.setState(UndoState.Suspend);
    s.noteArm("t.armpress", 2);
    h.setState(UndoState.Active);
    assert(h.undoEntries().length == 2 && s.sessionStateJson()["operationOpen"].type == JSONType.false_,
        format("S5b E2: a replayed arm wrote a begin row (rows %s) or opened an operation: %s",
               h.undoEntries().length, s.sessionStateJson()));
}

unittest { // S5b: a begin row that did not land arms nothing (the top is another session's row)
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto p = new PressFlagTool;
    p.m = &m; p.h = h; p.view = new View(0, 0, 1, 1);
    p.basis = MeshSnapshot.capture(m);
    Tool active = p;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.press", 1, false);
    s2bHaul(s, &p.pressBegins, &p.pressEnds, &m);
    assert(h.undoEntries().length == 1 && s2bTopRow(h).stepOrigin() == StepOrigin.opens,
        "S5b rig: the first session's haul did not record its opening row");
    auto t = new ArmPressTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    t.nullCarrier = true;   // the begin row cannot be recorded
    active = t;
    s.noteArm("t.armpress", 2, false);
    assert(h.undoEntries().length == 1 && s.sessionStateJson()["armed"].type == JSONType.false_,
        format("S5b: an arm whose begin row did not land armed the post mode on another "
               ~ "session's opening row (rows %s): %s", h.undoEntries().length, s.sessionStateJson()));
}

/// An arm-opening tool of the captured model whose session does not report its
/// steps (`sessionSteps` off): its begin row goes through a non-reporting `stepEnds`.
private final class ArmSilentTool : PressFlagTool {
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: false, historyTopologySteps: true,
            opensAt: OpensAt.arm, imageAttrs: ["v"]
        };
        return policy;
    }
}

unittest { // S5b: the begin flag does not outlive a begin row whose stepEnds did not report
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto q = new ArmSilentTool;
    q.m = &m; q.h = h; q.view = new View(0, 0, 1, 1);
    q.basis = MeshSnapshot.capture(m);
    Tool active = q;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.silent", 1, false);
    assert(h.undoEntries().length == 0, "S5b rig: a non-reporting arm wrote a row");
    auto t = new PressFlagTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    active = t;
    s.noteArm("t.press", 2, false);   // the post mode is not armed
    const y = m.vertices[0].y;
    auto before = t.captureAttrImage();
    t.v = 0.5f;
    s.orchestrateParameterChange(t, "v", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.ValueWritten, before);
    s.orchestrateParameterChange(t, "", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.BatchComplete);
    // An unarmed write is an attribute-only row (model doc §R6.1): it keeps the mesh
    // image; a stale begin flag makes it a mesh row that opens the operation.
    import commands.mesh.session_edit : MeshSessionEdit;
    assert(h.undoEntries().length == 1
           && cast(const MeshSessionEdit) h.undoEntries()[$ - 1].cmd is null
           && m.vertices[0].y == y,
        format("S5b: the begin flag of a non-reporting arm survived into the next session's "
               ~ "write (rows %s, top a mesh row %s, vertex moved %s)", h.undoEntries().length,
               h.undoEntries().length
                   && cast(const MeshSessionEdit) h.undoEntries()[$ - 1].cmd !is null,
               m.vertices[0].y != y));
}

unittest { // S2b E3: a dormant arm opens no operation
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new DormantRefusalTool;
    t.m = &m;
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    auto arm = tokenRow(&m, "t.dormant", "", true, false, 2);
    arm.markDormantTopology();
    h.recordToolLifecycle(arm);
    h.setState(UndoState.Suspend);
    s.noteArm("t.dormant", 2);
    h.setState(UndoState.Active);
    assert(t.dormant, "S2b E3 rig: the arm did not enter dormant topology mode");
    assert(s.sessionStateJson()["operationOpen"].type == JSONType.false_,
        format("S2b E3: a dormant arm opened an operation: %s", s.sessionStateJson()));
}

unittest { // S2b: a press is never an attribute-only row (a middle press reports no pointer-down)
    auto r = s2bRig();
    r.t.pressBegins();
    r.m.vertices[1].x += 0.25f;
    r.t.pressEnds();
    assert(r.h.undoEntries().length == 1 && s2bTopRow(r.h).stepOrigin() == StepOrigin.opens,
        format("S2b: a press with the post mode not armed wrote %s rows (an attribute-only row?)",
               r.h.undoEntries().length));
}

unittest { // S2b N1: an undo inside the same session keeps the operation open (the next press refires)
    auto r = s2bRig();
    s2bHaul(r);
    s2bHaul(r);
    const g2 = s2bTopRow(r.h);
    assert(r.s.navigate(true), "S2b N1 rig: the undo did not step");
    s2bHaul(r);
    const g3 = s2bTopRow(r.h);
    assert(g3.stepOrigin() == StepOrigin.refire && g3.stepOperation() == g2.stepOperation(),
        format("S2b N1: the press after the undo is %s of operation %s, expected a refire of %s",
               g3.stepOrigin(), g3.stepOperation(), g2.stepOperation()));
}

unittest { // S2b N4: a redo inside the same session keeps the operation open
    auto r = s2bRig();
    s2bHaul(r);
    s2bHaul(r);
    const g2 = s2bTopRow(r.h);
    assert(r.s.navigate(true) && r.s.navigate(false), "S2b N4 rig: the undo/redo did not step");
    s2bHaul(r);
    const g3 = s2bTopRow(r.h);
    assert(g3.stepOrigin() == StepOrigin.refire && g3.stepOperation() == g2.stepOperation(),
        format("S2b N4: the press after the redo is %s of operation %s, expected a refire of %s",
               g3.stepOrigin(), g3.stepOperation(), g2.stepOperation()));
}

unittest { // S2b N2: the reopened operation is the undone row's, not the session's last
    // Two restarts, so the undone row's operation (M1's) is neither the session's last (M2's)
    // nor the top row's (g1's). S7 (law 6): a restart folds the operation below it, so the
    // former rig (g1, g2, M; undo twice) took g1 and g2 as one group (probe edit, form item 10).
    auto r = s2bRig();
    s2bHaul(r);
    const g1 = s2bTopRow(r.h);
    foreach (k; 0 .. 2) {
        r.t.middleBegins();
        r.m.vertices[2].x += 0.25f;
        r.t.pressEnds();
    }
    const m2 = s2bTopRow(r.h);
    assert(r.h.undoEntries().length == 3, "S2b N2 rig: the two restarts are not rows of their own");
    const m1 = cast(const imported!"commands.mesh.session_edit".MeshSessionEdit)
        r.h.undoEntries()[1].cmd;
    assert(m1.stepOrigin() == StepOrigin.restart && m2.stepOrigin() == StepOrigin.restart
           && m1.stepOperation() != g1.stepOperation() && m2.stepOperation() != m1.stepOperation(),
        "S2b N2 rig: the middle presses did not open operations of their own");
    assert(r.s.navigate(true) && r.s.navigate(true), "S2b N2 rig: the undos did not step");
    s2bHaul(r);
    const g3 = s2bTopRow(r.h);
    assert(g3.stepOrigin() == StepOrigin.refire && g3.stepOperation() == m1.stepOperation(),
        format("S2b N2: the press after undoing both restarts refires operation %s, expected the "
               ~ "undone M1's %s (the session's last is %s, the top row's %s)", g3.stepOperation(),
               m1.stepOperation(), m2.stepOperation(), g1.stepOperation()));
}

// ---- Task 9120 (topology-redo wave S7, PF-7; plan §14): the undone restart's base -------
//
// A stand-in whose rebase body writes its basis and counts (the production shape: the
// restore body is its attributes, then its rebase body); the middle press is the tool's
// path — the press door first, then the basis taken on the live image.

private final class RebasePressTool : PressFlagTool {
    int rebases;
    override void rebaseTopologyStep(MeshSnapshot b) { basis = b; ++rebases; }
    override void restoreTopologyStep(in AttrImage attrs, MeshSnapshot b) {
        restoreRecordedAttrs(attrs);
        rebaseTopologyStep(b);
    }
    void middlePress(float dx) {
        middleBegins();
        basis = MeshSnapshot.capture(*m);
        m.vertices[2].x += dx;
        pressEnds();
    }
}

private struct Pf7Rig {
    Mesh m;
    CommandHistory h;
    RebasePressTool t;
    Tool active;
    EditSession s;
    MeshSnapshot rigBase;
}

private Pf7Rig* pf7Rig() {
    auto r = new Pf7Rig;
    r.m = makeCube();
    r.h = new CommandHistory();
    r.t = new RebasePressTool;
    r.t.m = &r.m; r.t.h = r.h; r.t.view = new View(0, 0, 1, 1);
    r.t.basis = MeshSnapshot.capture(r.m);
    r.rigBase = MeshSnapshot.capture(r.m);
    r.active = r.t;
    r.s = new EditSession(() => r.active, r.h, () { r.active = null; });
    r.s.noteArm("t.press", 1, false);
    return r;
}

private void pf7Haul(Pf7Rig* r) { s2bHaul(r.s, &r.t.pressBegins, &r.t.pressEnds, &r.m); }

private bool sameImage(in MeshSnapshot a, in MeshSnapshot b) { return a.matches(b); }

unittest { // U-PF7-refire: an undo inside one operation rebases once — the restore alone
    auto r = pf7Rig();
    pf7Haul(r);
    pf7Haul(r);
    assert(s2bTopRow(r.h).stepOrigin() == StepOrigin.refire, "PF-7 rig: g2 is no refire");
    const before = r.t.rebases;
    assert(r.s.navigate(true), "PF-7 rig: the undo did not step");
    assert(r.t.rebases - before == 1, format("PF-7: undoing a refire rebased the tool %s times, "
        ~ "expected once (the restore; the undone row's operation is the top's)",
        r.t.rebases - before));
}

unittest { // U-PF7-a: undoing a restart leaves its operation open on ITS base, not g1's
    auto r = pf7Rig();
    pf7Haul(r);
    r.t.middlePress(0.25f);
    const mid = s2bTopRow(r.h);
    assert(mid.stepOrigin() == StepOrigin.restart, "PF-7 rig: the middle press is no restart");
    assert(!sameImage(mid.stepAfterBasis(), r.rigBase),
        "PF-7 rig: the restart's base is the rig's (g1 moved nothing)");
    assert(r.s.navigate(true), "PF-7 rig: the undo did not step");
    assert(r.s.sessionStateJson()["operationOpen"].type == JSONType.true_,
        "PF-7 rig: the undo of the restart left its operation closed (N1/N2)");
    assert(sameImage(r.t.basis, mid.stepAfterBasis()) && !sameImage(r.t.basis, r.rigBase),
        "PF-7: after the restart's undo the tool's base is g1's (the operation below), not the "
        ~ "restart's own");
    pf7Haul(r);
    const g3 = s2bTopRow(r.h);
    assert(g3.stepOrigin() == StepOrigin.refire && g3.stepOperation() == mid.stepOperation()
           && sameImage(g3.stepBeforeBasis(), mid.stepAfterBasis()),
        format("PF-7: the haul after the restart's undo is %s of operation %s (restart %s), its "
               ~ "base the restart's: %s", g3.stepOrigin(), g3.stepOperation(), mid.stepOperation(),
               sameImage(g3.stepBeforeBasis(), mid.stepAfterBasis())));
}

unittest { // U-PF7-redo: a redo keeps its row's own base (the undone-restart rebase is the undo's)
    auto r = pf7Rig();
    pf7Haul(r);
    r.t.middlePress(0.25f);
    const m1 = s2bTopRow(r.h);
    r.t.middlePress(0.25f);
    const n1 = s2bTopRow(r.h);
    assert(!sameImage(m1.stepAfterBasis(), n1.stepAfterBasis()),
        "PF-7 rig: the two restarts share a base");
    assert(r.s.navigate(true) && r.s.navigate(true) && r.s.navigate(false),
        "PF-7 rig: the undo, undo, redo did not step");
    assert(sameImage(r.t.basis, m1.stepAfterBasis()),
        "PF-7: after the redo of the first restart the tool's base is not that row's own "
        ~ "(the redo head's, the second restart's?)");
}

// ---- Task 9120 (topology-redo wave S7, PF-3; plan §13, Capture-7 N6C): the undo of
// ---- another tool's UI pair hands the predecessor back its own session ----------------
//
// B — a ScrubTopologyTool (in the model, its first record carries the activation) — is
// armed through the UI door over the predecessor A, which B's arm closes (a switch), and
// hauls once; undoing B's pair re-arms A by a replay arm with a FRESH token (10).

private struct Pf3Rig {
    Mesh m;
    CommandHistory h;
    Tool active;
    EditSession s;
    ScrubTopologyTool b;
}

private Pf3Rig* pf3Rig() {
    auto r = new Pf3Rig;
    r.m = makeCube();
    r.h = new CommandHistory();
    r.s = new EditSession(() => r.active, r.h, () { r.active = null; });
    r.b = new ScrubTopologyTool;
    r.b.m = &r.m; r.b.h = r.h; r.b.view = new View(0, 0, 1, 1);
    return r;
}

/// A's session is armed and has its rows; B's UI arm closes it, B hauls once.
/// `act`: B's activation row (its revert re-arms `predId` with token 10, as a replay arm).
private void pf3ArmB(Pf3Rig* r, Tool pred, string predId, ToolActivationCommand act = null) {
    r.s.closeOperation(CloseReason.switch_);
    if (act is null) act = tokenRow(&r.m, "t.b", predId, true, true, 9, 5);
    act.onActivate = (string id) { r.active = pred; r.s.noteArm(id, 10); };
    r.h.recordToolLifecycle(act);
    r.active = r.b;
    r.s.noteArm("t.b", 9);
    r.s.finishClose();
    r.b.basis = MeshSnapshot.capture(r.m);
    r.b.haulStep(0.5f);
}

private long pf3Token(Pf3Rig* r) { return r.s.sessionStateJson()["token"].integer; }

unittest { // U1: the undo of B's UI pair returns the model predecessor A its session (N6)
    auto r = pf3Rig();
    auto a = new PressFlagTool;
    a.m = &r.m; a.h = r.h; a.view = new View(0, 0, 1, 1);
    a.basis = MeshSnapshot.capture(r.m);
    r.active = a;
    r.s.noteArm("t.a", 5, false);
    s2bHaul(r.s, &a.pressBegins, &a.pressEnds, &r.m);
    pf3ArmB(r, a, "t.a");
    assert(r.h.undoEntries().length == 3, "PF-3 U1 rig: B's activation and record are not rows");
    assert(r.s.navigate(true), "PF-3 U1 rig: the undo did not step");
    assert(r.active is a && r.h.undoEntries().length == 1,
        "PF-3 U1 rig: the undo did not take B's pair whole back to A");
    const st = r.s.sessionStateJson();
    assert(st["token"].integer == 5 && st["armed"].type == JSONType.true_
           && st["operationOpen"].type == JSONType.false_,
        format("PF-3 U1: after the undo of B's UI pair A holds token %s, armed %s, operation open "
               ~ "%s — expected its own session 5, armed, closed (N6)", st["token"], st["armed"],
               st["operationOpen"]));
    s2bHaul(r.s, &a.pressBegins, &a.pressEnds, &r.m);
    assert(s2bTopRow(r.h).stepOrigin() == StepOrigin.restart,
        format("PF-3 U1: A's haul after the pair's undo is %s, expected a restart (E7)",
               s2bTopRow(r.h).stepOrigin()));
}

unittest { // U2: A's first record still pairs with its activation (the carry is read by token)
    auto r = pf3Rig();
    auto a = new CarryTool;
    a.writeTo = r.h;
    r.active = a;
    auto actA = tokenRow(&r.m, "t.carry", "", true, true, 5);
    actA.onDeactivate = () { r.active = null; };
    r.h.recordToolLifecycle(actA);
    r.s.noteArm("t.carry", 5);
    a.arr = [Pt(1, 0, null)];
    assert(r.s.applyAndContinue(), "PF-3 U2 rig: A's in-place commit refused");
    pf3ArmB(r, a, "t.carry");
    assert(r.s.navigate(true) && r.active is a, "PF-3 U2 rig: B's pair did not undo back to A");
    assert(r.s.navigate(true), "PF-3 U2 rig: A's undo did not step");
    assert(r.h.undoEntries().length == 0 && r.active is null,
        format("PF-3 U2: A's first record popped without its activation (depth %s, A still on: "
               ~ "%s) — the restored A is not in its own session", r.h.undoEntries().length,
               r.active !is null));
}

unittest { // U3: the pen as the predecessor (§4.6) continues its session too
    auto r = pf3Rig();
    auto pen = new FoldTool(true);
    pen.m = &r.m; pen.h = r.h; pen.view = new View(0, 0, 1, 1);
    r.active = pen;
    r.s.noteArm("t.fold", 5);
    pen.press();
    r.m.vertices[3].z += 0.25f;
    pen.release();
    pf3ArmB(r, pen, "t.fold");
    assert(r.s.navigate(true) && r.active is pen,
           "PF-3 U3 rig: B's pair did not undo back to the pen");
    assert(pf3Token(r) == 5, format("PF-3 U3: the restored pen holds token %s, not its own 5",
                                    pf3Token(r)));
}

// Task 9170 (S5, law 3, model doc §2.4 row N6: «по N3, если navBefore_.armed»): the undo of
// B's UI pair re-begins A (A's own step on top, armed, ANOTHER token) and ends B's post mode,
// so B's refire leaves the redo; B's opener and its activation stay. No captured cell has a
// refire of B there (the Capture-7 cells haul B once): this pins the expression's N6 half.
unittest { // S5 N6: the undo that re-begins A cuts the post mode it ends — B's refire
    auto r = pf3Rig();
    auto a = new PressFlagTool;
    a.m = &r.m; a.h = r.h; a.view = new View(0, 0, 1, 1);
    a.basis = MeshSnapshot.capture(r.m);
    r.active = a;
    r.s.noteArm("t.a", 5, false);
    s2bHaul(r.s, &a.pressBegins, &a.pressEnds, &r.m);
    pf3ArmB(r, a, "t.a");
    r.s.notePointerDown();
    r.b.haulStep(1.0f);
    assert(r.h.undoEntries().length == 4 && s2bTopRow(r.h).stepOrigin() == StepOrigin.refire,
        "S5 N6 rig: B's second haul is not a refire row on top of A's row, B's arm and opener");
    assert(r.s.navigate(true) && r.h.redoEntries().length == 1 && r.active is r.b,
        "S5 N6 rig: the undo of B's refire left B or did not step (N1 keeps the redo)");
    assert(r.s.navigate(true) && r.active is a && pf3Token(r) == 5
           && r.s.sessionStateJson()["armed"].type == JSONType.true_,
        "S5 N6 rig: the undo of B's pair did not re-begin A in its own session");
    assert(r.h.redoEntries().length == 2,
        format("S5 N6: after the undo that ended B's post mode the redo holds %s rows, expected "
               ~ "B's activation and opener (2) — B's refire must be cut (law 3)",
               r.h.redoEntries().length));
}

unittest { // U4: an activation that refuses its undo hands no token over (the pair is split)
    static final class RefusingArm : ToolActivationCommand {
        // a predecessor of the SAME id with another token: an unguarded adopt would take it
        this(Mesh* m, View v) {
            super(m, v, EditMode.Vertices, "t.b", "t.b", true, true, true, 9, 5);
        }
        protected override void revertImpl() { failRevert("refused (test)"); }
    }
    auto r = pf3Rig();
    auto a = new PressFlagTool;
    a.m = &r.m; a.h = r.h; a.view = new View(0, 0, 1, 1);
    a.basis = MeshSnapshot.capture(r.m);
    r.active = a;
    r.s.noteArm("t.a", 5, false);
    pf3ArmB(r, a, "t.a", new RefusingArm(&r.m, new View(0, 0, 1, 1)));
    assert(r.s.navigate(true) && r.active is r.b, "PF-3 U4 rig: the split pair moved no row");
    assert(pf3Token(r) == 9, format("PF-3 U4: a refused activation undo handed over token %s",
                                    pf3Token(r)));
}


unittest { // U5 (S7 (7), plan §19.3; CAP C7-1 s05_Z): the pair's undo gives A its values back (M-H)
    auto r = pf3Rig();
    auto a = new PressFlagTool;
    a.m = &r.m; a.h = r.h; a.view = new View(0, 0, 1, 1);
    a.basis = MeshSnapshot.capture(r.m);
    r.active = a;
    r.s.noteArm("t.a", 5, false);
    a.v = 0.5f;                                  // the value A's haul wrote
    s2bHaul(r.s, &a.pressBegins, &a.pressEnds, &r.m);
    // B's UI row over a history-topology predecessor (the M-H read is keyed on it)
    auto bv = new View(0, 0, 1, 1);
    auto act = new ToolActivationCommand(&r.m, bv, EditMode.Vertices,
        "t.b", "t.a", true, true, true, 9, 5, true, true);
    pf3ArmB(r, a, "t.a", act);
    // the replay arm is a FRESH instance of A: its value is the arm's, not the haul's
    act.onActivate = (string id) { a.v = 0.0f; r.active = a; r.s.noteArm(id, 10); };
    assert(r.s.navigate(true) && r.active is a && r.h.undoEntries().length == 1,
        "PF-3 U5 rig: the undo did not take B's pair whole back to A");
    assert(pf3Token(r) == 5, format("PF-3 U5 rig: A holds token %s, not its own 5", pf3Token(r)));
    assert(a.v == 0.5f, format("PF-3 U5: after the undo of B's UI pair A holds v %s, expected "
        ~ "the 0.5 it held (M-H on the pair branch; 0 = the fresh replay arm's)", a.v));
}

// ---- Task 9120 (S7 (6), plan §19.3, model §R11 M-nav): a navigation tail re-bases a model
// ---- tool on the live mesh and writes none of its attributes (capture 8980 Z2/Z3 "kept") --

/// A scrub tool whose re-sync zeroes its attribute (a model tool's `reinitSession`) and
/// which counts its rebases.
private final class NavScrubTool : ScrubTopologyTool {
    int rebaseCalls;
    override void resyncSession() { shift = 0.0f; }
    override void rebaseTopologyStep(MeshSnapshot) { ++rebaseCalls; }
}

unittest { // U-NA1: a foreign row over the haul, undone and redone — the haul's value stays
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new NavScrubTool;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.scrub", 1);
    t.haulStep(0.5f);
    auto foreign = new Stub(new View(0, 0, 1, 1));   // a row of no session (token 0)
    assert(foreign.apply());
    h.record(foreign);
    assert(h.undoEntries().length == 2, "U-NA1 rig: the haul and the foreign row are not two rows");
    const before = t.rebaseCalls;
    assert(s.navigate(true) && h.undoEntries().length == 1, "U-NA1 rig: the undo did not step");
    const afterUndo = t.rebaseCalls - before;
    assert(t.shift == 0.5f, format("U-NA1: the undo tail wrote the model tool's attribute: shift "
        ~ "%s, expected the haul's 0.5 (N1a: the tail re-synced)", t.shift));
    assert(s.navigate(false) && h.undoEntries().length == 2, "U-NA1 rig: the redo did not step");
    assert(t.shift == 0.5f, format("U-NA1: the redo tail wrote the model tool's attribute: shift "
        ~ "%s, expected the haul's 0.5 (N1b: the tail re-synced)", t.shift));
    // FLOOR (measured): the undo tail rebases once (the operation stays open: no settle
    // rebase); the redo, its tail and the settle (the foreign row on top closes it).
    assert(afterUndo == 1 && t.rebaseCalls - before == 3,
        format("U-NA1: the tails rebased the tool %s (undo) / %s (both) times, expected 1 / 3 "
               ~ "(N2: the tail neither re-synced nor rebased)", afterUndo,
               t.rebaseCalls - before));
}

// ---- Task 9120 (S7, law 6, C3): with its tool dropped, a folded group of the model is still
// ---- one undo step and one redo step (CAP close_drop_inset_ui s05_Z: the Z after the drop
// ---- returns the image before the whole operation) --------------------------------------

unittest {
    auto r = s2bRig();
    s2bHaul(r);
    s2bHaul(r);
    assert(r.h.undoEntries().length == 2, "law 6 drop rig: the two hauls are not two rows");
    r.s.closeOperation(CloseReason.drop);
    r.active = null;
    r.s.finishClose();
    assert((r.h.undoEntries()[1].flags & HistoryFlags.JoinsBelow) != 0,
        "law 6 drop rig: the drop did not fold the operation's rows");
    assert(r.s.navigate(true) && r.h.undoEntries().length == 0 && r.h.redoEntries().length == 2,
        format("law 6: with the tool gone the undo of the folded group took %s rows of 2",
               2 - r.h.undoEntries().length));
    assert(r.s.navigate(false) && r.h.undoEntries().length == 2 && r.h.redoEntries().length == 0,
        format("law 6: with the tool gone the redo of the folded group brought %s rows of 2",
               r.h.undoEntries().length));
}

/// The pen's half of U-NA1: a tool outside the model (the pen's fold policy) is re-synced by
/// the tails, never rebased (§4.6: the pen's rebase body is not its navigation contract).
private final class NavPenTool : ScrubTopologyTool {
    int resyncs, rebaseCalls;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.firstPress, imageAttrs: ["shift"],
            pressOpensOperation: true, foldsParamRowsIntoBlock: true
        };
        return policy;
    }
    override void resyncSession() { ++resyncs; }
    override void rebaseTopologyStep(MeshSnapshot) { ++rebaseCalls; }
}

unittest { // U-NA1 pen: the same ladder re-syncs a tool outside the model, and rebases none
    import tool : capturedTopologyModel;
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new NavPenTool;
    assert(!capturedTopologyModel(t.sessionPolicy()),
           "U-NA1 pen rig: the pen policy is the model's");
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(m);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.pen", 1);
    t.haulStep(0.5f);
    auto foreign = new Stub(new View(0, 0, 1, 1));
    assert(foreign.apply());
    h.record(foreign);
    const r0 = t.resyncs;
    assert(s.navigate(true) && s.navigate(false) && h.undoEntries().length == 2,
        "U-NA1 pen rig: the undo and redo of the foreign row did not step");
    assert(t.resyncs - r0 == 2 && t.rebaseCalls == 0,
        format("U-NA1 pen: the tails re-synced the pen %s times and rebased it %s, expected 2 / 0 "
               ~ "(N3: the helper's model predicate inverted)", t.resyncs - r0, t.rebaseCalls));
}

// The fold is a property of the ROWS (`JoinsBelow`, written at the close), not of the tool
// bound when they are navigated (plan §19.2 C (1); reviewer OWN-1): under a live tool of
// another session — armed with no row of its own — the folded group is still one step.
// Model-derived like C3's redo half (gap row of C3; Capture-10 group C).
unittest {
    auto r = s2bRig();
    s2bHaul(r);
    s2bHaul(r);
    r.s.closeOperation(CloseReason.switch_);
    r.s.finishClose();
    auto other = new PressFlagTool;
    other.m = &r.m; other.h = r.h; other.view = new View(0, 0, 1, 1);
    other.basis = MeshSnapshot.capture(r.m);
    r.active = other;
    r.s.noteArm("t.other", 2, false);
    assert(r.h.undoEntries().length == 2
           && (r.h.undoEntries()[1].flags & HistoryFlags.JoinsBelow) != 0,
        "law 6 live-other rig: the switch did not fold the two hauls, or the arm wrote a row");
    assert(r.s.navigate(true) && r.h.undoEntries().length == 0 && r.h.redoEntries().length == 2,
        format("law 6: under another session's live tool the undo of the folded group took %s "
               ~ "rows of 2", 2 - r.h.undoEntries().length));
    assert(r.s.navigate(false) && r.h.undoEntries().length == 2 && r.h.redoEntries().length == 0,
        format("law 6: under another session's live tool the redo of the folded group brought "
               ~ "%s rows of 2", r.h.undoEntries().length));
}

// ---- Task 9120 (S7, law 6 with law 4's seed): the undo that drops the tool with a FOLDED
// ---- group remembers the group BASE's before-attributes, and the redo of the pair restores
// ---- them (model §R9 Л4-с: each undone row of the live instance replaces the image with its
// ---- before; CAP `*_direct_ui/s06_R`: the arm's value) ------------------------------------

/// A PressFlagTool whose UI command closes its operation (as the 12 of the model declare).
private final class UiClosePressTool : PressFlagTool {
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        import tool : CommandClose;
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.firstPress, imageAttrs: ["v"], commandClose: CommandClose.uiDoor
        };
        return policy;
    }
}

unittest {
    auto r = new S2bRig;
    r.m = makeCube();
    r.h = new CommandHistory();
    r.t = new UiClosePressTool;
    r.t.m = &r.m; r.t.h = r.h; r.t.view = new View(0, 0, 1, 1);
    r.t.basis = MeshSnapshot.capture(r.m);
    r.active = r.t;
    r.s = new EditSession(() => r.active, r.h, () { r.active = null; });
    auto act = tokenRow(&r.m, "t.press", "", true, true, 5);
    act.onDeactivate = () { r.active = null; };
    act.onActivate = (string id) { r.active = r.t; r.s.noteArm(id, 55, false); };
    r.h.recordToolLifecycle(act);
    r.s.noteArm("t.press", 5, false);
    foreach (v; [1.0f, 2.0f]) {
        r.s.notePointerDown();
        r.t.pressBegins();
        r.t.v = v;
        r.m.vertices[1].x += 0.25f;
        r.t.pressEnds();
    }
    r.s.closeOperation(CloseReason.command, CommandDoor.ui);
    r.s.finishClose();
    assert(r.h.undoEntries().length == 3
           && (r.h.undoEntries()[2].flags & HistoryFlags.JoinsBelow) != 0,
        "law 6 seed rig: the command close did not fold the two hauls over the activation");
    assert(r.s.navigate(true) && r.active is null && r.h.undoEntries().length == 0,
        format("law 6 seed rig: the undo did not drop the tool with its folded group (depth %s)",
               r.h.undoEntries().length));
    assert(r.s.navigate(false) && r.active is r.t && r.h.undoEntries().length == 3,
        "law 6 seed rig: the redo did not bring the pair and its group back whole");
    assert(r.t.v == 0.0f, format("law 4 seed after law 6: the redo of the pair restored v %s, "
        ~ "expected the group base's before (the arm's 0; the top row's before is 1)", r.t.v));
}

// ---- Task 9120 (S7, law 6 for the pen, L57): after a UI command ends the pen's session, the
// ---- next parameter row is the base of its own open step, not a row of the old block --------

unittest {
    import tool : CommandClose;
    Mesh m = makeCube();
    auto h = new CommandHistory();
    auto t = new FoldTool(true);
    t.pol.commandClose = CommandClose.uiDoor;
    t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
    Tool active = t;
    auto s = new EditSession(() => active, h, () { active = null; });
    s.noteArm("t.fold", 1);
    t.press();
    m.vertices[3].z += 0.25f;
    t.release();
    foldWrite(s, t, 0.5f);
    assert(h.undoEntries().length == 2,
           "pen L57 rig: the press and the parameter row are not two rows");
    const o = s.closeOperation(CloseReason.command, CommandDoor.ui);
    s.finishClose();
    assert(o.staysArmed && (flagsAt(h, 1) & HistoryFlags.JoinsBelow) != 0,
        "pen L57 rig: the UI command did not fold the open step and keep the pen");
    auto cmdRow = new Stub(new View(0, 0, 1, 1));
    assert(cmdRow.apply());
    h.record(cmdRow);
    foldWrite(s, t, 0.75f);
    assert(h.undoEntries().length == 4 && (flagsAt(h, 3) & HistoryFlags.PreNavOpen) == 0,
        "pen L57: the parameter row after the command joined the closed block (PreNavOpen) "
        ~ "instead of opening its own step");
}

// ---- Task 9270 (topology-redo wave S6r, model doc §R12 M-init): the instance's activation
// ---- writes the tool's `activationResetAttrs` image over the stored copy — at a live arm of
// ---- an arm-opening tool, and at a press that finds the instance inactive (CAP Capture-10
// ---- group R, findings §20.3). Order inside each cell: must-stay-green above must-redden.

/// A first-press model tool whose activation resets `v` (its data).
private class InitPressTool : PressFlagTool {
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        import tool : CommandClose;
        static immutable ToolSessionPolicy policy = {
            activationRow: true, commandClose: CommandClose.uiDoor, sessionSteps: true,
            historyTopologySteps: true, opensAt: OpensAt.firstPress, imageAttrs: ["v"],
            activationResetAttrs: ["v"]
        };
        return policy;
    }
}

/// The same tool opening its operation at the arm.
private final class InitArmTool : InitPressTool {
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        import tool : CommandClose;
        static immutable ToolSessionPolicy policy = {
            activationRow: true, commandClose: CommandClose.uiDoor, sessionSteps: true,
            historyTopologySteps: true, opensAt: OpensAt.arm, imageAttrs: ["v"],
            activationResetAttrs: ["v"]
        };
        return policy;
    }
}

/// One haul through the tool's own door; returns the attribute the step began from.
private float initHaul(EditSession s, PressFlagTool t, Mesh* m, float to) {
    s.notePointerDown();
    t.pressBegins();
    const atPress = t.v;
    t.v = to;
    m.vertices[1].x += 0.25f;
    t.pressEnds();
    return atPress;
}

/// The attribute image of `t` with `v` at `value` (the row's `before` is compared to it).
private AttrImage vImage(PressFlagTool t, float value) {
    const keep = t.v;
    t.v = value;
    auto img = t.captureAttrImage();
    t.v = keep;
    return img;
}

private struct InitRig {
    Mesh m;
    CommandHistory h;
    Tool active;
    EditSession s;
}

private InitRig* initRig(PressFlagTool t) {
    auto r = new InitRig;
    r.m = makeCube();
    r.h = new CommandHistory();
    t.m = &r.m; t.h = r.h; t.view = new View(0, 0, 1, 1);
    t.basis = MeshSnapshot.capture(r.m);
    r.active = t;
    r.s = new EditSession(() => r.active, r.h, () { r.active = null; });
    return r;
}

unittest { // U-INIT1 (CAP r1/r2): a command close deactivates the instance; the next press activates
    auto t = new InitPressTool;
    auto r = initRig(t);
    r.s.noteArm("t.init", 1, false);
    // `activations` counts activate_ runs by its datum (the one writer of true, needle (4j)),
    // not by the asserted value: inactive before the press, active after it.
    size_t activations;
    t.v = 0.4f;                                   // the stored copy the arm gave the instance
    auto pa0 = t.pa();
    const p1 = initHaul(r.s, t, &r.m, 0.5f);
    if (pa0 == PressActivation.activates && t.pa() == PressActivation.active) ++activations;
    assert(p1 == 0.0f, format("U-INIT1: the first press began from %s, expected the default 0 "
        ~ "(the press of an inactive first-press instance activates it)", p1));
    r.s.closeOperation(CloseReason.command, CommandDoor.ui);
    r.s.finishClose();
    s2bAttr(r.s, t, "v", () { t.v = 0.3f; }, ParameterChangeSource.InteractiveValue);
    assert(t.v == 0.3f, "U-INIT1 rig: the write after the close did not land");
    pa0 = t.pa();
    const p2 = initHaul(r.s, t, &r.m, 0.6f);
    if (pa0 == PressActivation.activates && t.pa() == PressActivation.active) ++activations;
    const row = s2bTopRow(r.h);
    assert(p2 == 0.0f && row !is null && row.stepBeforeAttrs().opEquals(vImage(t, 0.0f)),
        format("U-INIT1: the press after a command close began from %s, expected the default 0 "
               ~ "in the attribute and the row's before (the close must deactivate: "
               ~ "endPendingOperation_'s instanceActive_ = false)", p2));
    assert(activations == 2, format("U-INIT1: %s activations seen, measured 2", activations));
}

unittest { // U-INIT3 (CAP C9-8c): a live refire of the active instance does not activate it
    auto t = new InitPressTool;
    auto r = initRig(t);
    r.s.noteArm("t.init", 1, false);
    t.v = 0.4f;
    const p1 = initHaul(r.s, t, &r.m, 0.5f);
    assert(p1 == 0.0f, format("U-INIT3 rig: the first press began from %s, not the default", p1));
    const p2 = initHaul(r.s, t, &r.m, 0.7f);
    assert(p2 == 0.5f && s2bTopRow(r.h).stepBeforeAttrs().opEquals(vImage(t, 0.5f)),
        format("U-INIT3: the refire began from %s, expected the first haul's 0.5 (the activation "
               ~ "must raise instanceActive_, or every press resets)", p2));
}

unittest { // U-INIT2 (CAP r5 s09/s10): a dormant arm activates; its press does not — keyed on the
           // instance, not on the operation (a dormant arm opens none)
    auto a = new InitArmTool;
    auto r = initRig(a);
    auto b = new ScrubTopologyTool;
    b.m = &r.m; b.h = r.h; b.view = new View(0, 0, 1, 1);
    b.basis = MeshSnapshot.capture(r.m);
    r.s.noteArm("t.a", 5);
    initHaul(r.s, a, &r.m, 0.5f);                 // the run W closes: A's session 5 at 0.5
    // W: B's script-door activation over A (its undo re-arms A by a replay arm)
    r.s.closeOperation(CloseReason.switch_);
    auto wv = new View(0, 0, 1, 1);
    auto w = new ToolActivationCommand(&r.m, wv, EditMode.Vertices,
        "t.b", "t.a", true, false, false, 9, 5, true, true);
    w.onActivate = (string id) {
        r.active = id == "t.a" ? cast(Tool) a : cast(Tool) b;
        r.s.noteArm(id, id == "t.a" ? 5 : 9);
    };
    r.h.recordToolLifecycle(w);
    r.active = b;
    r.s.noteArm("t.b", 9);
    // A's link outlives its bind: a press of a tool that is not the reporting one is unbound.
    assert(a.pa() == PressActivation.unbound,
        format("U-INIT2: A's press after B's bind answers %s, expected unbound (pressActivation_ "
               ~ "keyed on reporting_, like the link's other answers)", a.pa()));
    r.s.finishClose();
    assert(r.s.navigate(true) && r.active is a, "U-INIT2 rig: the undo of W did not re-arm A");
    assert(r.s.navigate(false) && r.active is b, "U-INIT2 rig: the redo of W did not re-arm B");
    // A's live arm after the fully redone closed run: dormant (law 5), the closed run's copy
    r.s.closeOperation(CloseReason.switch_);
    auto av = new View(0, 0, 1, 1);
    auto arm = new ToolActivationCommand(&r.m, av, EditMode.Vertices,
        "t.a", "t.b", true, false, false, 11, 9);
    r.h.recordToolLifecycle(arm);
    r.active = a;
    r.s.noteArm("t.a", 11);
    r.s.finishClose();
    const st = r.s.sessionStateJson();
    assert(st["dormant"].type == JSONType.true_ && st["operationOpen"].type == JSONType.false_,
        format("U-INIT2 rig: A's arm is not dormant with no operation open: %s", st));
    size_t activations;                           // activate_ runs, by the datum (the bind clears it)
    if (a.pa() == PressActivation.active) ++activations;
    assert(a.v == 0.0f, format("U-INIT2: the dormant arm left v %s, expected the default 0 (a "
        ~ "live arm of an arm-opening tool activates, dormant or not)", a.v));
    s2bAttr(r.s, a, "v", () { a.v = 0.3f; }, ParameterChangeSource.InteractiveValue);
    assert(a.v == 0.3f, "U-INIT2 rig: the write after the dormant arm did not land");
    const pa0 = a.pa();
    const p = initHaul(r.s, a, &r.m, 0.6f);
    if (pa0 == PressActivation.activates && a.pa() == PressActivation.active) ++activations;
    assert(p == 0.3f, format("U-INIT2: the dormant press began from %s, expected the written 0.3 "
        ~ "(the instance is active; a press keyed on !operationOpen_ resets it)", p));
    assert(activations == 1, format("U-INIT2: %s activations seen, measured 1", activations));
}

unittest { // U-INIT4: every bind is a new instance — a pen press (outside the model: its switch
           // ends no model post mode) leaves no active datum to the next tool's first press
    auto t = new InitPressTool;
    auto r = initRig(t);
    auto pen = new FoldTool(true);
    pen.m = &r.m; pen.h = r.h; pen.view = new View(0, 0, 1, 1);
    r.active = pen;
    r.s.noteArm("t.fold", 1);
    pen.press();
    r.m.vertices[3].z += 0.25f;
    pen.release();
    assert(r.h.undoEntries().length == 1, "U-INIT4 rig: the pen press recorded no row");
    r.s.closeOperation(CloseReason.switch_);
    r.active = t;
    r.s.noteArm("t.init", 2, false);
    r.s.finishClose();
    t.v = 0.4f;                                   // the stored copy the arm gave the instance
    const p = initHaul(r.s, t, &r.m, 0.5f);
    assert(p == 0.0f, format("U-INIT4: the first press after the pen began from %s, expected the "
        ~ "default 0 (the bind must clear instanceActive_: the pen's press raised it and its "
        ~ "switch, outside the model, does not end a model post mode)", p));
}

unittest { // U-INIT5 (CAP r3/r4: no Initialize in the Z window; C9-7b s07_R): a replayed arm
           // keeps the stored copy — only a LIVE arm of an arm-opening tool activates
    auto a = new InitArmTool;
    auto r = initRig(a);
    auto b = new ScrubTopologyTool;
    b.m = &r.m; b.h = r.h; b.view = new View(0, 0, 1, 1);
    b.basis = MeshSnapshot.capture(r.m);
    a.v = 0.4f;                                   // the stored copy the live arm is given
    r.s.noteArm("t.a", 5);
    assert(a.v == 0.0f, format("U-INIT5 rig: the live arm left v %s, not the default 0", a.v));
    s2bAttr(r.s, a, "v", () { a.v = 0.3f; }, ParameterChangeSource.InteractiveValue);
    assert(a.v == 0.3f, "U-INIT5 rig: the write after the arm did not land");
    // bind B over A (its undo re-arms A by a replay arm, the instance built from the copy)
    r.s.closeOperation(CloseReason.switch_);
    auto wv = new View(0, 0, 1, 1);
    auto w = new ToolActivationCommand(&r.m, wv, EditMode.Vertices,
        "t.b", "t.a", true, false, false, 9, 5, true, true);
    UndoState atReplay;
    float atArm = -1.0f;
    w.onActivate = (string id) {
        if (id == "t.a") { a.v = 0.3f; atReplay = r.h.state(); }
        r.active = id == "t.a" ? cast(Tool) a : cast(Tool) b;
        r.s.noteArm(id, id == "t.a" ? 5 : 9);
        if (id == "t.a") atArm = a.v;             // the replay arm's own effect, before the tail
    };
    r.h.recordToolLifecycle(w);
    r.active = b;
    r.s.noteArm("t.b", 9);
    r.s.finishClose();
    assert(r.s.navigate(true) && r.active is a, "U-INIT5 rig: the undo of the bind did not re-arm A");
    assert(atReplay == UndoState.Suspend,
        format("U-INIT5 rig: A's replay arm ran under %s, not Suspend", atReplay));
    // must-stay-green first: the navigation's M-H tail writes the remembered image after the
    // arm (S7r part D removes that write), so the end state alone cannot see the arm
    assert(a.v == 0.3f, format("U-INIT5: after the undo A holds v %s, expected the stored 0.3",
        a.v));
    assert(atArm == 0.3f, format("U-INIT5: the replayed arm left v %s, expected the stored 0.3 (a "
        ~ "replay is no activation: noteArm's `state != Suspend` term)", atArm));
}

// ---- Task 9300 (S7r, plan §22, model §R13 M-ri): a redo inside the operation pins the redo
// ---- image of its later press refires, for a tool that records its image once per operation

/// A scrub tool that records its applied image once per operation (`redoPinsRefireImage`).
private final class PinningScrubTool : ScrubTopologyTool {
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyTopologySteps: true,
            opensAt: OpensAt.firstPress, imageAttrs: ["shift"], redoPinsRefireImage: true
        };
        return policy;
    }
    // A middle-button press of the same tool: a restart (a new operation).
    void middleStep(float to) {
        sessionStepBegins(PressKind.middle);
        shift = to;
        onParamChanged("shift");
        sessionStepEnds();
    }
}

private final class PinRig {
    Mesh m;
    CommandHistory h;
    Tool active;
    EditSession s;
    ScrubTopologyTool t;
    float y0;
    this(ScrubTopologyTool tool) {
        m = makeCube();
        h = new CommandHistory();
        t = tool;
        t.m = &m; t.h = h; t.view = new View(0, 0, 1, 1);
        t.basis = MeshSnapshot.capture(m);
        y0 = m.vertices[0].y;
        active = t;
        s = new EditSession(() => active, h, () { active = null; });
        s.noteArm("t.scrub", 1);
    }
    /// The live image: vertex 0's offset from the arm image.
    float y() { return m.vertices[0].y - y0; }
    bool pinned() { return s.sessionStateJson()["redoPinned"].type == JSONType.true_; }
    size_t topologyRows() {
        import commands.mesh.session_edit : MeshSessionEdit;
        size_t n;
        foreach (e; h.undoEntries())
            if (auto row = cast(const MeshSessionEdit) e.cmd) if (row.isTopologyStep()) ++n;
        return n;
    }
    void undo(string ctx) { assert(s.navigate(true), ctx ~ ": the undo did not step"); }
    void redo(string ctx) { assert(s.navigate(false), ctx ~ ": the redo did not step"); }
}

private bool near(float a, float b) { return a - b < 1e-5f && b - a < 1e-5f; }

unittest { // U-RI1 (CAP b1 s08_R, 8810 nav_redo_refire_inset s13_R): the refire after a redo
           // keeps its attributes; its redo shows the image the redo left
    auto r = new PinRig(new PinningScrubTool);
    r.t.haulStep(0.1f);
    r.t.haulStep(0.2f);
    r.undo("U-RI1 rig");
    r.redo("U-RI1 rig");
    assert(r.pinned(), "U-RI1: the redo of the operation's refire pinned nothing (redoPinned false)");
    r.t.haulStep(0.3f);
    // must-stay-green: recording a row does not apply it — the live image is the refire's own
    assert(near(r.y(), 0.3f), format("U-RI1: the refire after the redo left y %s, expected its own 0.3",
                                     r.y()));
    assert(r.topologyRows() == 3, format("U-RI1 floor: %s topology rows, measured 3",
                                         r.topologyRows()));
    r.undo("U-RI1 rig");
    assert(near(r.y(), 0.2f), format("U-RI1 rig: the undo of the refire left y %s, not 0.2", r.y()));
    r.redo("U-RI1 rig");
    assert(near(r.y(), 0.2f) && near(r.t.shift, 0.3f),
        format("U-RI1: the redo of the refire after a redo shows y %s / shift %s, expected the "
               ~ "pinned 0.2 with its own shift 0.3 (settleAfterNavigation_'s pin, stepEnds' after)",
               r.y(), r.t.shift));
}

unittest { // U-RI2 (CAP b4 s08_R = s06): without the datum nothing is pinned
    auto r = new PinRig(new ScrubTopologyTool);
    r.t.haulStep(0.1f);
    r.t.haulStep(0.2f);
    r.undo("U-RI2 rig");
    r.redo("U-RI2 rig");
    assert(!r.pinned(), "U-RI2: a tool without redoPinsRefireImage pinned its redo image");
    r.t.haulStep(0.3f);
    r.undo("U-RI2 rig");
    r.redo("U-RI2 rig");
    assert(!r.pinned() && near(r.y(), 0.3f),
        format("U-RI2: the redo of the refire shows y %s (pinned %s), expected its own 0.3",
               r.y(), r.pinned()));
}

unittest { // U-RI3 (CAP b6 s10_R = s08): an undo inside the operation ends the pin
    auto r = new PinRig(new PinningScrubTool);
    r.t.haulStep(0.1f);
    r.t.haulStep(0.2f);
    r.undo("U-RI3 rig");
    r.redo("U-RI3 rig");
    r.t.haulStep(0.3f);
    r.undo("U-RI3 rig");
    assert(!r.pinned(), "U-RI3: the undo left the redo image pinned (redoPinned true)");
    r.t.haulStep(0.4f);
    r.undo("U-RI3 rig");
    r.redo("U-RI3 rig");
    assert(near(r.y(), 0.4f), format("U-RI3: the redo of the refire after an undo shows y %s, "
        ~ "expected its own 0.4 (any undo releases the pin; an undo pins nothing)", r.y()));
}

unittest { // U-RI3b (plan §22.5 (1)): the pin is the operation's — a restart's refires keep their own
    auto r = new PinRig(new PinningScrubTool);
    auto p = cast(PinningScrubTool) r.t;
    r.t.haulStep(0.1f);
    r.t.haulStep(0.2f);
    r.undo("U-RI3b rig");
    r.redo("U-RI3b rig");
    p.middleStep(0.5f);
    r.t.haulStep(0.6f);
    r.undo("U-RI3b rig");
    r.redo("U-RI3b rig");
    assert(near(r.y(), 0.6f), format("U-RI3b: the redo of the restart's refire shows y %s, expected "
        ~ "its own 0.6 (the pin is keyed on the operation: pinnedOperation_ == operation_)", r.y()));
    r.undo("U-RI3b rig");
    r.undo("U-RI3b rig");
    r.redo("U-RI3b rig");
    assert(near(r.y(), 0.5f), format("U-RI3b: the redo of the restart row shows y %s, expected its "
        ~ "own 0.5 (stepEnds keys the pin on the row's own operation, set before setSnapshots)",
        r.y()));
}

unittest { // U-RI4 (plan §22.5 (3), uncaptured): a parameter-write refire after a redo keeps its own
    auto r = new PinRig(new PinningScrubTool);
    r.t.haulStep(0.1f);
    r.t.haulStep(0.2f);
    r.undo("U-RI4 rig");
    r.redo("U-RI4 rig");
    const depth = r.h.undoEntries().length;
    auto before = r.t.captureAttrImage();
    r.t.shift = 0.35f;
    r.s.orchestrateParameterChange(r.t, "shift", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.ValueWritten, before, false);
    r.s.orchestrateParameterChange(r.t, "", ParameterChangeSource.InteractiveValue,
        ParameterChangePhase.BatchComplete);
    assert(r.h.undoEntries().length == depth + 1 && near(r.y(), 0.35f),
        "U-RI4 rig: the parameter write recorded no row or did not apply");
    r.undo("U-RI4 rig");
    r.redo("U-RI4 rig");
    assert(near(r.y(), 0.35f), format("U-RI4: the redo of a parameter-write refire shows y %s, "
        ~ "expected its own 0.35 (the pin is a press refire's: stepEnds' topologyPendingPress_)",
        r.y()));
}

unittest { // U-RI5 (plan §22.5 (4), law 4): the redo of another instance's row pins nothing
    auto r = new PinRig(new PinningScrubTool);
    r.t.haulStep(0.1f);
    r.t.haulStep(0.2f);
    auto other = new PinningScrubTool;              // a new instance under the same token
    other.m = &r.m; other.h = r.h; other.view = new View(0, 0, 1, 1);
    other.basis = MeshSnapshot.capture(r.m);
    r.active = other;
    r.s.noteArm("t.scrub", 1);
    r.t = other;
    r.undo("U-RI5 rig");
    r.redo("U-RI5 rig");
    assert(!r.pinned(), "U-RI5: the redo of another instance's row pinned its image "
        ~ "(ownInstanceStepOnTop_'s boundToLive_)");
    r.t.haulStep(0.3f);
    r.undo("U-RI5 rig");
    r.redo("U-RI5 rig");
    assert(near(r.y(), 0.3f), format("U-RI5: the refire over a redone orphan row redoes y %s, "
        ~ "expected its own 0.3", r.y()));
}

unittest { // U-RI6 (plan §22.4 P3): the operation's end releases the pinned image
    auto r = new PinRig(new PinningScrubTool);
    r.t.haulStep(0.1f);
    r.t.haulStep(0.2f);
    r.undo("U-RI6 rig");
    r.redo("U-RI6 rig");
    assert(r.pinned(), "U-RI6 rig: the redo pinned nothing");
    r.t.discard();
    assert(!r.pinned(), "U-RI6: the operation's end kept the pinned image (endOperation_ releases it)");
}
