module tests.unit.tool_session_recorded_steps_test;

import command : Command, CmdFlags;
import command_history : CommandHistory;
import command_history : RecordMode;
import command_history : HistoryFlags;
import command_history : RunCloseMode, RecordedRunBoundaryMode, RunCloseScope, HistoryEntry;
import commands.tool.lifecycle : ToolActivationCommand;
import command_executor : CommandExecutor;
import edit_session : EditSession, RefireClient;
import editmode : EditMode;
import tool : Tool, ToolSessionPolicy;
import tool_presets : loadToolPresets;
import tool_activation_ownership : ToolTransition;
import tool_activation_ownership : postmodeArmedOnArm;
import view : View;
import std.file : readText;
import std.format : format;
import std.string : indexOf;

private final class ValueEdit : Command {
    View view_;
    int* value;
    int before, after;
    string commandName;
    this(int* value, int before, int after,
         string commandName = "Recorded transform step") {
        view_ = new View(0, 0, 1, 1);
        super(null, view_, EditMode.Vertices);
        this.value = value;
        this.before = before;
        this.after = after;
        this.commandName = commandName;
    }
    override string name() const { return commandName; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    protected override bool applyImpl() {
        *value = after;
        noteUndoRecorded();
        return true;
    }
    protected override void revertImpl() { *value = before; }
}

private final class RecordedTool : Tool, RefireClient {
    int amount, resyncs, refireTarget;
    ulong ownedRecordToken() { return sessionRecordToken(); }
    bool pending, ladder, firstUndoEnds, emptiesRedo;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyRecordedSteps: true };
        static immutable ToolSessionPolicy ladderPolicy = {
            activationRow: true, sessionSteps: true, historyRecordedSteps: true,
            previewHistoryLadder: true, keepAliveOnCancel: true };
        ToolSessionPolicy selected = ladder ? ladderPolicy : policy;
        selected.recordedFirstUndoEndsTool = firstUndoEnds;
        if (firstUndoEnds) selected.activationRow = false;
        selected.undoEmptiesRedo = emptiesRedo;
        return selected;
    }
    void gesture(CommandHistory history, int after) {
        auto cmd = new ValueEdit(&amount, amount, after);
        assert(cmd.apply());
        history.record(cmd);
        sessionRecordCompleted(cmd);
    }
    void liveGesture(CommandHistory history, ulong runId, int after) {
        auto cmd = new ValueEdit(&amount, amount, after);
        assert(cmd.apply());
        history.recordInSession(cmd, runId);
        sessionRecordCompleted(cmd);
    }
    override void resyncSession() { ++resyncs; }
    override bool hasUncommittedEdit() const { return pending; }
    override void cancelUncommittedEdit() { pending = false; }
    override bool wantsRefire() const { return true; }
    override Command buildRefireCommand() {
        return new ValueEdit(&amount, amount, refireTarget);
    }
    override void setRefireDriving(bool on) {}
    override void onRefireCommitted() {}
}

/// A plain row whose undo binds another tool (an activation row's revert, reduced).
private final class SwapEdit : Command {
    View view_;
    Tool* active;
    Tool to;
    this(Tool* active, Tool to) {
        view_ = new View(0, 0, 1, 1);
        super(null, view_, EditMode.Vertices);
        this.active = active;
        this.to = to;
    }
    override string name() const { return "swap"; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    protected override bool applyImpl() { noteUndoRecorded(); return true; }
    protected override void revertImpl() { *active = to; }
}

unittest { // 9500: an undo that leaves a flagged tool armed empties the redo; a
            // refused undo changes nothing.
    foreach (flag; [true, false]) {
        auto tool = new RecordedTool;
        tool.emptiesRedo = flag;
        Tool active = tool;
        auto history = new CommandHistory;
        auto session = new EditSession(() => active, history, () { active = null; });
        session.noteArm("xfrm.redo-empties-test", 1);
        tool.gesture(history, 7);
        tool.gesture(history, 13);
        assert(session.navigate(true) && tool.amount == 7 && active is tool);
        assert(history.redoEntries().length == (flag ? 0 : 1),
               format("9500 surviving undo (flag %s): redo %s", flag, history.redoEntries().length));
    }
    // A refused undo (nothing below the redo) leaves the redo alone.
    {
        auto tool = new RecordedTool;
        tool.emptiesRedo = true;
        Tool active = tool;
        auto history = new CommandHistory;
        auto session = new EditSession(() => active, history, () { active = null; });
        session.noteArm("xfrm.redo-empties-test", 1);
        tool.gesture(history, 7);
        assert(history.undo() && history.undoEntries().length == 0
               && history.redoEntries().length == 1, "9500 refused rig: raw undo");
        assert(!session.navigate(true) && history.redoEntries().length == 1,
               format("9500: a refused undo emptied the redo (%s left)", history.redoEntries().length));
    }
    // The row popped binds another tool (a layer click under 9457): the
    // armed flagged tool still empties the redo.
    {
        auto a = new RecordedTool, b = new RecordedTool;
        a.emptiesRedo = b.emptiesRedo = true;
        Tool active = a;
        auto history = new CommandHistory;
        auto session = new EditSession(() => active, history, () { active = null; });
        session.noteArm("xfrm.redo-empties-test", 1);
        auto swap = new SwapEdit(&active, b);
        assert(swap.apply());
        history.record(swap);
        a.gesture(history, 7);
        assert(history.undo() && history.redoEntries().length == 1, "9500 swap rig: raw undo");
        assert(session.navigate(true) && active is b,
               "9500 swap rig: the undo did not bind the other tool");
        assert(history.redoEntries().length == 0,
               format("9500 swap: redo %s, expected empty", history.redoEntries().length));
    }
    // An undone activation row whose carry rule keeps its redo (a session-steps
    // arm over an unclassified predecessor) keeps it under the restored tool.
    {
        auto a = new RecordedTool, b = new RecordedTool;
        a.emptiesRedo = b.emptiesRedo = true;
        Tool active = a;
        auto history = new CommandHistory;
        auto session = new EditSession(() => active, history, () { active = null; });
        session.noteArm("xfrm.redo-empties-test", 1);
        auto view = new View(0, 0, 1, 1);
        auto act = new ToolActivationCommand(null, view, EditMode.Vertices, "a", "b", true);
        act.onActivate = (string id) { active = b; };
        assert(act.carriesRedoAfterUndo(), "9500 activation rig: the row carries no redo");
        history.recordToolLifecycle(act);
        a.gesture(history, 7);
        assert(history.undo() && history.redoEntries().length == 1, "9500 activation rig: raw undo");
        assert(session.navigate(true) && active is b,
               "9500 activation rig: the undo did not restore the predecessor");
        assert(history.redoEntries().length == 2,
               format("9500: the undone activation row lost its redo (%s left)",
                      history.redoEntries().length));
    }
}

unittest { // 8493: selected stage and running postmode are distinct states.
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto session = new EditSession(() => active, history, () { active = null; });
    assert(!postmodeArmedOnArm(ToolTransition.commandArm, true));
    assert(!postmodeArmedOnArm(ToolTransition.interactiveArm, true));
    assert(postmodeArmedOnArm(ToolTransition.replayArm, true));
    assert(postmodeArmedOnArm(ToolTransition.commandArm, false));
    session.noteArm("policy-selected", 8493, false);
    assert(!session.sessionStateJson()["armed"].boolean &&
           session.sessionStateJson()["postmodeOwner"].str == "none",
           "8493 user arm must select the stage without starting postmode");
    session.notePointerDown();
    assert(session.sessionStateJson()["armed"].boolean &&
           session.sessionStateJson()["postmodeOwner"].str == "human",
           "8493 first press must start postmode without another arm");
    session.noteArm("policy-selected", 8494, true);
    assert(session.sessionStateJson()["armed"].boolean,
           "8493 history replay must restore a running postmode");
    session.noteArm("policy-selected", 8495, false);
    assert(!session.sessionStateJson()["armed"].boolean,
           "8493 repeated UI arm after replay must wait for the next press");
}

unittest {
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto session = new EditSession(() => active, history, () { active = null; });
    session.noteArm("xfrm.block-test", 6);
    auto executor = new CommandExecutor(history, () => active !is null,
        (ToolTransition why) { active = null; }, null, null,
        (Command cmd) { session.recordAppliedToolCommand(cmd); });
    history.blockBegin("Two transform applies");
    assert(executor.applyOrRefire(new ValueEdit(&tool.amount, 0, 9, "tool.doApply"),
                                  RecordMode.Record, null));
    assert(executor.applyOrRefire(new ValueEdit(&tool.amount, 9, 17, "tool.doApply"),
                                  RecordMode.Record, null));
    history.blockEnd();
    assert(session.sessionStateJson()["steps"].integer == 1,
           "the named block lost its common Transform ToolSession owner");
    assert(session.navigate(true) && tool.amount == 0);
    assert(session.navigate(false) && tool.amount == 17);
}

unittest { // 8261: open gestures, closed rows, one outside step, restored owner.
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto view = new View(0, 0, 1, 1);
    auto arm = new ToolActivationCommand(null, view, EditMode.Vertices,
        "TransformMove", "", true, false, false, 8261);
    history.recordToolLifecycle(arm);
    EditSession session;
    session = new EditSession(() => active, history,
        () { active = null; }, (string id) {
            assert(id == "TransformMove", "closed run restored wrong tool owner");
            active = tool;
            session.noteArm(id, 8262);
        });
    session.noteArm("TransformMove", 8261);
    const run = history.nextRun();
    tool.liveGesture(history, run, 7);
    tool.liveGesture(history, run, 13);
    assert(session.navigate(true) && tool.amount == 7,
           "internal Undo must peel one gesture");
    assert(session.navigate(false) && tool.amount == 13,
           "internal Redo must restore the second gesture");
    assert(history.closeRunVisible(run, "TransformMove") == 2,
           "closed run lost a visible adjustment group");
    active = null;
    session.noteArm("foreign owner", 9999); // stale session cache, history is authority
    auto rows = history.undoEntriesVisible();
    assert(rows.length == 3 &&
           (rows[1].flags & HistoryFlags.ClosedRun) &&
           (rows[2].flags & HistoryFlags.ClosedRun) &&
           !(rows[1].flags & HistoryFlags.InSession) &&
           !(rows[2].flags & HistoryFlags.InSession),
           "close must retain two completed History rows");
    assert(session.navigate(true) && tool.amount == 0 && active is tool,
           "one outside Undo must restore S0 and tool ownership");
    assert(session.sessionStateJson()["token"].integer == 8261,
           "restored owner must retain the activation row's session token");
    assert(history.undoEntries().length == 1 &&
           history.redoEntries().length == 0,
           "closed-run Undo must consume both rows and its redo branch");
    assert(!session.navigate(false) && session.terminalRedoRequested(),
           "outside Redo must request the terminal modal");
    const branchRun = history.nextRun();
    tool.liveGesture(history, branchRun, 7);
    assert(tool.amount == 7 && !session.navigate(false) &&
           !session.terminalRedoRequested(),
           "a fresh C-branch gesture must replace the terminal branch");
    assert(history.closeRunVisible(branchRun, "TransformMove") == 1);
    active = null;
    assert(session.navigate(true) && tool.amount == 0 && active is tool,
           "a re-armed C branch must itself close and outside-Undo to S0");
}

unittest { // 8261: cap eviction keeps the oldest retained prestate recoverable.
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto view = new View(0, 0, 1, 1);
    auto arm = new ToolActivationCommand(null, view, EditMode.Vertices,
        "TransformMove", "", true, false, false, 8263);
    history.recordToolLifecycle(arm);
    EditSession session;
    session = new EditSession(() => active, history,
        () { active = null; }, (string id) {
            assert(id == "TransformMove");
            active = tool;
            session.noteArm(id, 8264);
        });
    session.noteArm("TransformMove", 8263);
    const run = history.nextRun();
    foreach (i; 1 .. 52) tool.liveGesture(history, run, i);
    assert(history.undoEntries().length == 50 &&
           cast(const ToolActivationCommand)history.undoEntries()[0].cmd is null,
           "setup must evict the activation row at History capacity");
    assert(history.closeRunVisible(run, "TransformMove") == 50);
    active = null;
    assert(session.navigate(true) && tool.amount == 1 && active is tool,
           "capped closed run must undo to oldest retained prestate and restore owner");
    assert(history.undoEntries().length == 0 && history.redoEntries().length == 0 &&
           session.sessionStateJson()["token"].integer == 8263,
           "cap recovery must preserve bounded History and session ownership");
    assert(!session.navigate(false) && session.terminalRedoRequested(),
           "capped closed run must still reach terminal Redo");
}

unittest { // 8490: a closed run may retain independent gesture steps.
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    EditSession session;
    session = new EditSession(() => active, history,
        () { active = null; }, (string id) {
            assert(id == "rotate");
            active = tool;
            session.noteArm(id, 999);
        });
    session.noteArm("rotate", 8490);
    const run = history.nextRun();
    tool.liveGesture(history, run, 7);
    tool.liveGesture(history, run, 13);
    assert(history.closeRunVisible(run, "rotate", RunCloseMode.stepUndo) == 2);
    const closed = history.undoEntriesVisible();
    assert(closed.length == 2 &&
           (closed[0].flags & HistoryFlags.ClosedStep) &&
           (closed[1].flags & HistoryFlags.ClosedStep),
           "stepwise close must preserve two visible completed gestures");
    active = null;
    assert(session.navigate(true) && tool.amount == 7 && active is tool,
           "closed step Undo must restore the last gesture and its owner");
    assert(history.undoEntries().length == 1 &&
           history.redoEntries().length == 1 &&
           session.sessionStateJson()["token"].integer == 8490,
           "closed step Undo must retain redo and the original session token");
    assert(session.navigate(false) && tool.amount == 13 && active is tool,
           "closed step Redo must restore the last gesture");
    assert(!session.terminalRedoRequested(),
           "stepwise closed runs do not request a terminal Redo modal");
}

unittest { // 8492: a silent arm is carried by its first recorded step.
    auto tool = new RecordedTool;
    tool.firstUndoEnds = true;
    Tool active = tool;
    auto history = new CommandHistory;
    EditSession session;
    session = new EditSession(() => active, history,
        () { active = null; }, (string id) {
            assert(id == "rotate", "8492 recorded step re-armed the wrong owner");
            active = tool;
            session.noteArm(id, 999);
        });
    session.noteArm("rotate", 8492);
    const firstRun = history.nextRun();
    tool.liveGesture(history, firstRun, 7);
    history.consolidate(firstRun); // off-gizmo relocation crosses a run boundary
    const secondRun = history.nextRun();
    tool.liveGesture(history, secondRun, 10);
    assert(session.navigate(true) && tool.amount == 7 && active is tool,
        "8492 Undo latest gesture must keep the owner");
    assert(session.navigate(true) && tool.amount == 0 && active is null &&
           (history.redoEntries()[0].flags & HistoryFlags.ClosedStep),
        "8492 Undo first recorded gesture must end the silent arm");
    assert(session.navigate(false) && tool.amount == 7 && active is tool &&
           session.sessionStateJson()["token"].integer == 8492,
        "8492 Redo first gesture must re-arm the original session");
    assert(session.navigate(false) && tool.amount == 10,
        "8492 Redo second gesture must restore the second geometry step");
    assert(history.closeRunVisible(history.currentRunId, "rotate",
                                  RunCloseMode.stepUndo) == 2,
        "8492 close must tag both runs of one recorded session");
    active = null;
    assert(session.navigate(true) && tool.amount == 7 && active is tool,
        "8492 outside Undo must restore one step and its owner");
}

unittest { // A preset based on rotate must not inherit the bare door's law.
    size_t grouped, restored, defaulted;
    foreach (p; loadToolPresets("config/tool_presets.yaml")) {
        if (p.id == "TransformMove") {
            assert(p.runCloseMode == RunCloseMode.groupUndo);
            ++grouped;
        } else if (p.id == "TransformRotate" || p.id == "TransformScale" || p.id == "Transform" || p.id == "xfrm.scaleUniform") {
            assert(p.runCloseMode == RunCloseMode.groupRedo, "preset closed navigation policy: " ~ p.id);
            ++restored;
        } else {
            assert(p.runCloseMode == RunCloseMode.consolidate,
                   "an unmeasured preset inherited the bare rotate close law");
            ++defaulted;
        }
    }
    foreach (p; loadToolPresets("config/tool_presets.yaml")) {
        assert(p.runBoundaryMode == (p.id == "Transform" ?
            RecordedRunBoundaryMode.retainSteps : RecordedRunBoundaryMode.consolidate));
        assert(p.runCloseScope == (p.id == "Transform" ? RunCloseScope.session : RunCloseScope.run));
    }
    assert(grouped == 1 && restored == 4 && defaulted > 0);
}

unittest {
    // Headless Transform producers enter through tool.doApply's executor
    // record instead of a drag writer, but own the same History row.
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto session = new EditSession(() => active, history, () { active = null; });
    session.noteArm("xfrm.headless-test", 2);
    auto executor = new CommandExecutor(history, () => active !is null,
        (ToolTransition why) { active = null; }, null, null,
        (Command cmd) { session.recordAppliedToolCommand(cmd); });
    assert(executor.applyOrRefire(new ValueEdit(&tool.amount, 0, 9, "tool.doApply"),
                                  RecordMode.Record, null));
    assert(session.sessionStateJson()["steps"].integer == 1);
    assert(session.navigate(true) && tool.amount == 0);
    assert(session.navigate(false) && tool.amount == 9);
}

unittest {
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto session = new EditSession(() => active, history, () { active = null; });
    session.noteArm("xfrm.refire-test", 4);
    session.refireBegin();
    assert(session.tryRefireDispatch(
        new ValueEdit(&tool.refireTarget, 0, 11, "tool.attr"), "tool.attr"));
    session.refireEnded();
    assert(session.sessionStateJson()["steps"].integer == 1,
           "refireEnd did not give its History row to ToolSession");
    assert(session.navigate(true) && tool.amount == 0);
    assert(session.navigate(false) && tool.amount == 11);
}

unittest {
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto session = new EditSession(() => active, history, () { active = null; });
    session.noteArm("xfrm.dangling-refire-test", 5);
    session.refireBegin();
    assert(session.tryRefireDispatch(
        new ValueEdit(&tool.refireTarget, 0, 11, "tool.attr"), "tool.attr"));
    session.refireBegin(); // commits the dangling current-tool refire
    assert(session.sessionStateJson()["steps"].integer == 1);
    assert(session.tryRefireDispatch(
        new ValueEdit(&tool.refireTarget, 11, 17, "tool.attr"), "tool.attr"));
    session.refireEnded();
    assert(session.sessionStateJson()["steps"].integer == 2);
    assert(session.navigate(true) && tool.amount == 11);
    assert(session.navigate(true) && tool.amount == 0);
}

unittest {
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto session = new EditSession(() => active, history, () { active = null; });
    session.noteArm("xfrm.recorded-test", 1);
    tool.gesture(history, 7);
    tool.gesture(history, 13);
    auto state = session.sessionStateJson();
    assert(state["steps"].integer == 2 && state["redo"].integer == 0,
           "recorded steps were not tagged by the production ToolSession link");
    assert(history.undoEntries()[$ - 1].cmd.sessionToken() == state["token"].integer,
           "completed command lost its ToolSession owner token");
    const undone = session.navigate(true);
    assert(undone && tool.amount == 7 && tool.resyncs == 1,
           format("first Undo: moved=%s value=%s resyncs=%s", undone, tool.amount, tool.resyncs));
    state = session.sessionStateJson();
    assert(state["steps"].integer == 1 && state["redo"].integer == 1,
           "Undo left a duplicate completed state in ToolSession");
    assert(session.navigate(false) && tool.amount == 13 && tool.resyncs == 2,
           "Redo did not restore the history-owned gesture");
    state = session.sessionStateJson();
    assert(state["steps"].integer == 2 && state["redo"].integer == 0);
}

unittest {
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    auto session = new EditSession(() => active, history, () { active = null; });
    session.noteArm("xfrm.pending-test", 3);
    tool.gesture(history, 7);
    tool.pending = true;
    assert(session.navigate(true) && !tool.pending && tool.amount == 7,
           "Undo stepped a completed row underneath the pending preview");
    assert(session.navigate(true) && tool.amount == 0,
           "second Undo did not reach the completed History row");
    assert(!session.navigate(true),
           "history-owned producer exposed a phantom attribute-image step");
}

unittest {
    auto tool = new RecordedTool;
    tool.ladder = true;
    Tool active = tool;
    auto history = new CommandHistory;
    auto session = new EditSession(() => active, history, () { active = null; });
    session.noteArm("prim.preview-ladder-test", 7);
    const runId = history.nextRun();
    tool.pending = true;
    tool.liveGesture(history, runId, 7);
    tool.liveGesture(history, runId, 13);
    assert(session.navigate(true) && tool.pending && tool.amount == 7,
           "first Undo skipped the live recorded row or cancelled the preview");
    assert(session.navigate(true) && tool.pending && tool.amount == 0,
           "second Undo skipped the earlier live recorded row");
    assert(session.navigate(true) && !tool.pending && active is tool,
           "the preview was not cancelled after its recorded ladder emptied");
    assert(!session.navigate(true), "empty live ladder exposed a phantom step");
}

unittest {
    // The focused stand-in exercises the protocol; these pins ensure its
    // production call sites are wired to the same completed-row callback.
    assert(readText("source/tools/transform/transform.d")
            .indexOf("sessionRecordCompleted(cmd);") >= 0,
           "TransformTool recordCommit no longer publishes its completed row");
    assert(readText("source/tools/transform/xfrm_transform.d")
            .indexOf("sessionRecordCompleted(cmd);") >= 0,
           "XfrmTransformTool recordTransformCommand no longer publishes its completed row");
    assert(readText("source/tool.d").indexOf("sessionRecordCompleted(cmd);") >= 0,
           "Tool.recordGestureEdit no longer publishes wrapper/Magnet rows");
    assert(readText("config/tool_presets.yaml").indexOf(
            "historyClose: groupUndo") >= 0 &&
           readText("source/tool_presets.d").indexOf(
            "t.runCloseMode = presetCopy.runCloseMode;") >= 0,
           "production TransformMove preset lost its declared closed-run policy");
    assert(readText("source/tools/transform/xfrm_transform.d").indexOf(
            "history.closeRunVisible(history.currentRunId,") >= 0,
           "Xfrm drop stopped preserving the visible TransformMove groups");
    assert(readText("source/app.d").indexOf(
            "guardModalState.publishHistoryTerminal(\"Out of redos.\");") >= 0,
           "interactive terminal Redo lost the captured modal text");
    assert(readText("source/ui/panels.d").indexOf(
            "ImGui.BeginPopupModal(\"Redo\"") >= 0,
           "terminal Redo request no longer has a visible modal renderer");
    assert(readText("source/http_providers.d").indexOf(
            "modal(\"history.redo.terminal\", guardModalState.historyTerminalOpen);") >= 0,
           "terminal Redo modal lost its independent input-state witness");
}



unittest { // 8530: group navigation and each independent ownership boundary.
    foreach (boundary; 0 .. 4) {
        auto tool = new RecordedTool;
        Tool active = tool;
        auto history = new CommandHistory;
        EditSession session;
        session = new EditSession(() => active, history, () { active = null; },
            (string id) { active = tool; session.noteArm(id, 999); });
        session.noteArm("policy-selected", 8530);
        void record(ulong run, ulong token, int before, int after) {
            auto edit = new ValueEdit(&tool.amount, before, after);
            edit.markSession(token);
            assert(edit.apply()); history.recordInSession(edit, run);
        }
        record(1, boundary == 1 ? 8531 : 8530, 0, 7);
        assert(history.closeRunVisible(1, boundary == 2 ? "other-owner" : "policy-selected",
            boundary == 3 ? RunCloseMode.groupUndo : RunCloseMode.groupRedo) == 1);
        ulong secondRun = boundary == 0 ? 2 : 1;
        record(secondRun, 8530, 7, 13); record(secondRun, 8530, 13, 19);
        assert(history.closeRunVisible(secondRun, "policy-selected", RunCloseMode.groupRedo) == 2);
        assert(history.undoEntries().length == 3);
        active = null;
        assert(session.navigate(true) && tool.amount == 7 && active is tool,
            format("8530 closed group crossed ownership boundary %s", boundary));
        assert(history.undoEntries().length == 1 && history.redoEntries().length == 2);
        assert(session.navigate(false) && tool.amount == 19 && active is tool,
            "8530 one Redo must replay both retained rows");
        assert(history.undoEntries().length == 3 && history.redoEntries().length == 0);
        assert(session.sessionStateJson()["token"].integer == 8530);
        assert(!session.terminalRedoRequested(), "8530 retained group must not request discard modal");
    }
}

unittest { // 8530: Redo leaves a foreign tail beyond the retained group.
    foreach (boundary; 0 .. 4) {
        auto tool = new RecordedTool;
        Tool active = tool;
        auto history = new CommandHistory;
        EditSession session;
        session = new EditSession(() => active, history, () { active = null; },
            (string id) { active = tool; session.noteArm(id, 999); });
        session.noteArm("policy-selected", 8530);
        void record(ulong run, ulong token, int before, int after) {
            auto edit = new ValueEdit(&tool.amount, before, after);
            edit.markSession(token);
            assert(edit.apply()); history.recordInSession(edit, run);
        }
        record(1, 8530, 0, 7); record(1, 8530, 7, 13);
        assert(history.closeRunVisible(1, "policy-selected", RunCloseMode.groupRedo) == 2);
        ulong foreignRun = boundary == 0 ? 2 : 1;
        record(foreignRun, boundary == 1 ? 8531 : 8530, 13, 19);
        assert(history.closeRunVisible(foreignRun,
            boundary == 2 ? "other-owner" : "policy-selected",
            boundary == 3 ? RunCloseMode.groupUndo : RunCloseMode.groupRedo) == 1);
        foreach (_; 0 .. 3) assert(history.undo());
        assert(tool.amount == 0 && history.redoEntries().length == 3);
        active = null;
        assert(session.navigate(false) && tool.amount == 13 && active is tool,
            format("8530 Redo crossed ownership boundary %s", boundary));
        assert(history.undoEntries().length == 2 && history.redoEntries().length == 1,
            "8530 Redo must leave the foreign tail untouched");
        assert(session.sessionStateJson()["token"].integer == 8530);
    }
}

unittest { // 8560: retire geometry-bank rows, keep every live step, close one session.
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    EditSession session;
    session = new EditSession(() => active, history, () { active = null; },
        (string id) { active = tool; session.noteArm(id, 999); });
    assert(tool.ownedRecordToken() == 0);
    session.noteArm("policy-selected", 8560);
    assert(tool.ownedRecordToken() == 8560, "8560 token forwarding lost session owner");
    tool.liveGesture(history, 1, 7); tool.liveGesture(history, 1, 13);
    (cast(HistoryEntry[])history.undoEntries())[0].flags |= HistoryFlags.Refire;
    assert(history.retireRunSteps(1, tool.ownedRecordToken()) == 2);
    assert(history.undoEntries().length == 2 && !history.runOpen());
    foreach (entry; history.undoEntries()) {
        assert(entry.runId == 1 && entry.cmd.sessionToken() == 8560);
        assert(!(entry.flags & (HistoryFlags.InSession | HistoryFlags.Refire)));
    }
    tool.liveGesture(history, 2, 19);
    assert(session.navigate(true) && tool.amount == 13);
    assert(session.navigate(true) && tool.amount == 7,
        "8560 bank retirement lost the earlier same-bank gesture");
    assert(session.navigate(false) && tool.amount == 13);
    assert(session.navigate(false) && tool.amount == 19);
    assert(history.retireRunSteps(2, 8560) == 1);
    tool.liveGesture(history, 3, 23); tool.liveGesture(history, 3, 29);
    foreach (expected; [23, 19, 13, 7, 0])
        assert(session.navigate(true) && tool.amount == expected, "8560 five-step live Undo image lost");
    foreach (expected; [7, 13, 19, 23, 29])
        assert(session.navigate(false) && tool.amount == expected, "8560 five-step live Redo image lost");
    assert(history.closeRunVisible(3, "policy-selected", RunCloseMode.groupRedo,
        RunCloseScope.session, 8560) == 5, "8560 session close omitted previous banks");
    const rows = history.undoEntries();
    assert(rows.length == 5 && rows[0].closedNavigationGroupId != 0);
    foreach (entry; rows) assert(entry.sameClosedNavigation(rows[0]));
    active = null;
    assert(session.navigate(true) && tool.amount == 0 && active is tool,
        "8560 grouped outside Undo did not restore the whole session");
    assert(history.undoEntries().length == 0 && history.redoEntries().length == 5);
    assert(session.navigate(false) && tool.amount == 29,
        "8560 grouped Redo did not restore every retained bank");
    assert(history.undoEntries().length == 5 && history.redoEntries().length == 0);
    const group = history.undoEntries()[0].closedNavigationGroupId;
    active = null;
    assert(session.navigate(true) && tool.amount == 0);
    tool.liveGesture(history, 4, 35);
    assert(history.redoEntries().length == 0, "8560 branch kept obsolete redo rows");
    assert(history.closeRunVisible(4, "policy-selected", RunCloseMode.groupRedo,
        RunCloseScope.session, 8560) == 1);
    assert(history.undoEntries()[0].closedNavigationGroupId > group,
        "8560 branch reused the prior closed group");
    history.clear();
    tool.liveGesture(history, 4, 31);
    assert(history.closeRunVisible(4, "policy-selected", RunCloseMode.groupRedo,
        RunCloseScope.session, 8560) == 1);
    assert(history.undoEntries()[0].closedNavigationGroupId > group,
        "8560 history clear reused a closed navigation identity");
    active = null;
    assert(tool.ownedRecordToken() == 0, "8560 dropped owner still exposes its token");
    auto other = new RecordedTool;
    active = other; session.noteArm("other", 8561);
    assert(tool.ownedRecordToken() == 0 && other.ownedRecordToken() == 8561,
        "8560 stale bound tool borrowed the new owner's token");
}

unittest { // Every explicit-group discriminator varies with equal group IDs.
    foreach (boundary; 0 .. 10) {
        int amount;
        auto first = new ValueEdit(&amount, 0, 1); first.markSession(boundary == 3 ? 0 : 8560);
        auto second = new ValueEdit(&amount, 1, 2);
        second.markSession(boundary == 2 ? 8561 : boundary == 3 ? 0 : 8560);
        HistoryEntry a = {cmd:first, flags:HistoryFlags.ClosedRun | HistoryFlags.ClosedGroupRedo,
            runId:1, closedOwnerId:"policy", closedNavigationGroupId:1,
            closedScope:RunCloseScope.session};
        auto b = a; b.cmd = second; b.runId = 2;
        if (boundary == 1) b.closedNavigationGroupId = 2;
        if (boundary == 4) b.closedOwnerId = "other";
        if (boundary == 5) { a.closedOwnerId = ""; b.closedOwnerId = ""; }
        if (boundary == 6) b.flags &= ~cast(uint)HistoryFlags.ClosedGroupRedo;
        if (boundary == 7) { a.closedScope = b.closedScope = RunCloseScope.run; }
        if (boundary == 8) { a.flags = b.flags = 0; }
        if (boundary == 9) b.closedScope = RunCloseScope.run;
        assert(a.sameClosedNavigation(b) == (boundary == 0),
            format("8560 explicit group crossed boundary %s", boundary));
    }
}

unittest { // Close/retire stop at each independently varied suffix boundary.
    foreach (boundary; 0 .. 7) {
        int amount;
        auto history = new CommandHistory;
        void record(ulong token) {
            auto cmd = new ValueEdit(&amount, amount, amount + 1);
            cmd.markSession(token); assert(cmd.apply()); history.recordInSession(cmd, 1);
        }
        record(boundary == 1 ? 8561 : boundary == 2 ? 0 : 8560);
        auto rows = cast(HistoryEntry[])history.undoEntries();
        if (boundary == 3) rows[0].flags |= HistoryFlags.ToolLifecycle;
        if (boundary == 4) rows[0].flags |= HistoryFlags.ClosedRun;
        if (boundary == 5) rows[0].closedNavigationGroupId = 7;
        if (boundary == 6) rows[0].closedOwnerId = "foreign";
        record(8560);
        assert(history.closeRunVisible(1, "policy", RunCloseMode.groupRedo,
            RunCloseScope.session, 8560) == (boundary == 0 ? 2 : 1),
            format("8560 session suffix crossed boundary %s", boundary));
    }
    foreach (boundary; 0 .. 8) {
        int amount;
        auto history = new CommandHistory;
        auto cmd = new ValueEdit(&amount, 0, 1);
        cmd.markSession(boundary == 1 ? 0 : boundary == 7 ? 8561 : 8560);
        assert(cmd.apply()); history.recordInSession(cmd, 1);
        auto rows = cast(HistoryEntry[])history.undoEntries();
        if (boundary == 2) rows[0].flags |= HistoryFlags.ToolLifecycle;
        if (boundary == 3) rows[0].flags |= HistoryFlags.ClosedRun;
        if (boundary == 4) rows[0].closedNavigationGroupId = 7;
        if (boundary == 5) rows[0].flags &= ~cast(uint)HistoryFlags.InSession;
        if (boundary == 6) rows[0].runId = 2;
        assert(history.retireRunSteps(1, boundary == 1 ? 0 : 8560) == (boundary == 0 ? 1 : 0),
            format("8560 run retirement crossed boundary %s", boundary));
    }
    int zeroAmount;
    auto zeroHistory = new CommandHistory;
    auto zeroCommand = new ValueEdit(&zeroAmount, 0, 1);
    assert(zeroCommand.apply()); zeroHistory.recordInSession(zeroCommand, 1);
    assert(zeroHistory.closeRunVisible(1, "policy", RunCloseMode.groupRedo,
        RunCloseScope.session, 0) == 0, "8560 zero owned token closed a zero-token row");
    auto empty = new CommandHistory;
    assert(empty.retireRunSteps(1, 8560) == 0);
    assert(empty.closeRunVisible(1, "policy", RunCloseMode.groupRedo,
        RunCloseScope.session, 8560) == 0);
    int amount;
    auto cmd = new ValueEdit(&amount, 0, 1); cmd.markSession(8560);
    assert(cmd.apply()); empty.recordInSession(cmd, 1);
    assert(empty.closeRunVisible(1, "policy", RunCloseMode.groupRedo,
        RunCloseScope.session, 8560) == 1);
    assert(empty.undoEntries()[0].closedNavigationGroupId == 1,
        "8560 empty close allocated a navigation group");
}

unittest { // A depth-limited surviving suffix remains a complete navigation group.
    auto tool = new RecordedTool;
    Tool active = tool;
    auto history = new CommandHistory;
    EditSession session;
    session = new EditSession(() => active, history, () { active = null; },
        (string id) { active = tool; session.noteArm(id, 999); });
    session.noteArm("policy", 8560);
    foreach (i; 1 .. 56) tool.liveGesture(history, i, i);
    assert(history.undoEntries().length == 50);
    assert(history.closeRunVisible(55, "policy", RunCloseMode.groupRedo,
        RunCloseScope.session, 8560) == 50);
    active = null;
    assert(session.navigate(true) && tool.amount == 5);
    assert(history.redoEntries().length == 50 && session.navigate(false) && tool.amount == 55);
}

unittest { // Generic alias declarations carry both navigation policy fields.
    import std.file : write, remove;
    import core.sys.posix.unistd : getpid;
    auto path = format("/var/tmp/preset-policy-%s.yaml", getpid());
    scope(exit) remove(path);
    write(path, "presets:\n  - id: canonical\n    base: xfrm.transform\n    historyClose: groupRedo\n    runBoundary: retainSteps\n    closeScope: session\n  - id: alias\n    alias: canonical\n");
    auto presets = loadToolPresets(path);
    assert(presets.length == 2);
    foreach (p; presets) {
        assert(p.runBoundaryMode == RecordedRunBoundaryMode.retainSteps);
        assert(p.runCloseScope == RunCloseScope.session);
    }
    foreach (field; ["runBoundary", "closeScope"]) {
        write(path, format("presets:\n  - id: invalid\n    base: xfrm.transform\n    %s: invalid\n", field));
        bool refused;
        try { loadToolPresets(path); } catch (Exception) { refused = true; }
        assert(refused, "8560 invalid policy declaration accepted: " ~ field);
    }
}
