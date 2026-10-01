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

import command_history : CommandHistory, UndoState;
import commands.tool.lifecycle : ToolActivationCommand;
import edit_session : EditSession, ParameterChangeSource, ParameterChangePhase;
import editmode : EditMode;
import mesh : Mesh, makeCube;
import math : Vec3;
import params;
import tool : AttrImage, OpensAt, PressKind, Tool, ToolSessionPolicy, TopologyStepClient;
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
            historyTopologySteps: true, dormantAfterClosedRedo: true,
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

unittest { // The session half selects the predecessor run, not its newer sibling.
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
    assert(restored.shift == 17,
        format("topology attr ownership ignored predecessor session: restored %s, expected 17",
               restored.shift));
}

// ---- 8290: a held widget is ONE topology step --------------------------------

private final class ScrubTopologyTool : Tool, TopologyStepClient {
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

private final class PressFlagTool : Tool, TopologyStepClient {
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
    void pressEnds() { sessionStepEnds(); }
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
    t.seen = JSONValue.init;
    t.act = true;
    s.orchestrateParameterChange(t, "act", ParameterChangeSource.ScriptedValue,
        ParameterChangePhase.ValueWritten);
    s.orchestrateParameterChange(t, "", ParameterChangeSource.ScriptedValue,
        ParameterChangePhase.BatchComplete);
    assert(t.seen.type == JSONType.false_ && h.undoEntries().length == 3
           && !lastRowByPress(h),
        format("8646 press flag: an Action step reported pendingPress %s (rows %s)",
               t.seen, h.undoEntries().length));
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
