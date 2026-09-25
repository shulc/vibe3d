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
// Fast loop: tools/local/ut-standalone.sh tests/unit/tool_session_steps_test.d
module tests.unit.tool_session_steps_test;

import command_history : CommandHistory, UndoState;
import commands.tool.lifecycle : ToolActivationCommand;
import edit_session : EditSession, ParameterChangeSource, ParameterChangePhase;
import editmode : EditMode;
import mesh : Mesh, makeCube;
import math : Vec3;
import params;
import tool : AttrImage, OpensAt, PressKind, Tool, ToolSessionPolicy;
import tool_activation_ownership;
import view : View;

import std.algorithm : canFind, count;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.traits : EnumMembers;

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
        session.noteArm("t.step");
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
    return new ToolActivationCommand(m, v, EditMode.Vertices, id, "", JSONValue.init, true, joins);
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

private final class Stub : imported!"command".Command {
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
    r.session.noteArm("t.step");               // a re-arm: a fresh account
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
