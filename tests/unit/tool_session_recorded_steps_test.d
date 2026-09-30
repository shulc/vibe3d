module tests.unit.tool_session_recorded_steps_test;

import command : Command, CmdFlags;
import command_history : CommandHistory;
import command_history : RecordMode;
import command_history : HistoryFlags;
import command_history : RunCloseMode;
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
    int value, resyncs, refireTarget;
    bool pending, ladder, firstUndoEnds;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyRecordedSteps: true };
        static immutable ToolSessionPolicy ladderPolicy = {
            activationRow: true, sessionSteps: true, historyRecordedSteps: true,
            previewHistoryLadder: true, keepAliveOnCancel: true };
        ToolSessionPolicy selected = ladder ? ladderPolicy : policy;
        selected.recordedFirstUndoEndsTool = firstUndoEnds;
        if (firstUndoEnds) selected.activationRow = false;
        return selected;
    }
    void gesture(CommandHistory history, int after) {
        auto cmd = new ValueEdit(&value, value, after);
        assert(cmd.apply());
        history.record(cmd);
        sessionRecordCompleted(cmd);
    }
    void liveGesture(CommandHistory history, ulong runId, int after) {
        auto cmd = new ValueEdit(&value, value, after);
        assert(cmd.apply());
        history.recordInSession(cmd, runId);
        sessionRecordCompleted(cmd);
    }
    override void resyncSession() { ++resyncs; }
    override bool hasUncommittedEdit() const { return pending; }
    override void cancelUncommittedEdit() { pending = false; }
    override bool wantsRefire() const { return true; }
    override Command buildRefireCommand() {
        return new ValueEdit(&value, value, refireTarget);
    }
    override void setRefireDriving(bool on) {}
    override void onRefireCommitted() {}
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
    assert(executor.applyOrRefire(new ValueEdit(&tool.value, 0, 9, "tool.doApply"),
                                  RecordMode.Record, null));
    assert(executor.applyOrRefire(new ValueEdit(&tool.value, 9, 17, "tool.doApply"),
                                  RecordMode.Record, null));
    history.blockEnd();
    assert(session.sessionStateJson()["steps"].integer == 1,
           "the named block lost its common Transform ToolSession owner");
    assert(session.navigate(true) && tool.value == 0);
    assert(session.navigate(false) && tool.value == 17);
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
    assert(session.navigate(true) && tool.value == 7,
           "internal Undo must peel one gesture");
    assert(session.navigate(false) && tool.value == 13,
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
    assert(session.navigate(true) && tool.value == 0 && active is tool,
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
    assert(tool.value == 7 && !session.navigate(false) &&
           !session.terminalRedoRequested(),
           "a fresh C-branch gesture must replace the terminal branch");
    assert(history.closeRunVisible(branchRun, "TransformMove") == 1);
    active = null;
    assert(session.navigate(true) && tool.value == 0 && active is tool,
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
    assert(session.navigate(true) && tool.value == 1 && active is tool,
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
    assert(session.navigate(true) && tool.value == 7 && active is tool,
           "closed step Undo must restore the last gesture and its owner");
    assert(history.undoEntries().length == 1 &&
           history.redoEntries().length == 1 &&
           session.sessionStateJson()["token"].integer == 8490,
           "closed step Undo must retain redo and the original session token");
    assert(session.navigate(false) && tool.value == 13 && active is tool,
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
    assert(session.navigate(true) && tool.value == 7 && active is tool,
        "8492 Undo latest gesture must keep the owner");
    assert(session.navigate(true) && tool.value == 0 && active is null &&
           (history.redoEntries()[0].flags & HistoryFlags.ClosedStep),
        "8492 Undo first recorded gesture must end the silent arm");
    assert(session.navigate(false) && tool.value == 7 && active is tool &&
           session.sessionStateJson()["token"].integer == 8492,
        "8492 Redo first gesture must re-arm the original session");
    assert(session.navigate(false) && tool.value == 10,
        "8492 Redo second gesture must restore the second geometry step");
    assert(history.closeRunVisible(history.currentRunId, "rotate",
                                  RunCloseMode.stepUndo) == 2,
        "8492 close must tag both runs of one recorded session");
    active = null;
    assert(session.navigate(true) && tool.value == 7 && active is tool,
        "8492 outside Undo must restore one step and its owner");
}

unittest { // A preset based on rotate must not inherit the bare door's law.
    size_t grouped, restored, defaulted;
    foreach (p; loadToolPresets("config/tool_presets.yaml")) {
        if (p.id == "TransformMove") {
            assert(p.runCloseMode == RunCloseMode.groupUndo);
            ++grouped;
        } else if (p.id == "TransformRotate") {
            assert(p.runCloseMode == RunCloseMode.groupRedo);
            ++restored;
        } else {
            assert(p.runCloseMode == RunCloseMode.consolidate,
                   "an unmeasured preset inherited the bare rotate close law");
            ++defaulted;
        }
    }
    assert(grouped == 1 && restored == 1 && defaulted > 0);
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
    assert(executor.applyOrRefire(new ValueEdit(&tool.value, 0, 9, "tool.doApply"),
                                  RecordMode.Record, null));
    assert(session.sessionStateJson()["steps"].integer == 1);
    assert(session.navigate(true) && tool.value == 0);
    assert(session.navigate(false) && tool.value == 9);
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
    assert(session.navigate(true) && tool.value == 0);
    assert(session.navigate(false) && tool.value == 11);
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
    assert(session.navigate(true) && tool.value == 11);
    assert(session.navigate(true) && tool.value == 0);
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
    assert(undone && tool.value == 7 && tool.resyncs == 1,
           format("first Undo: moved=%s value=%s resyncs=%s", undone, tool.value, tool.resyncs));
    state = session.sessionStateJson();
    assert(state["steps"].integer == 1 && state["redo"].integer == 1,
           "Undo left a duplicate completed state in ToolSession");
    assert(session.navigate(false) && tool.value == 13 && tool.resyncs == 2,
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
    assert(session.navigate(true) && !tool.pending && tool.value == 7,
           "Undo stepped a completed row underneath the pending preview");
    assert(session.navigate(true) && tool.value == 0,
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
    assert(session.navigate(true) && tool.pending && tool.value == 7,
           "first Undo skipped the live recorded row or cancelled the preview");
    assert(session.navigate(true) && tool.pending && tool.value == 0,
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
            auto edit = new ValueEdit(&tool.value, before, after);
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
        assert(session.navigate(true) && tool.value == 7 && active is tool,
            format("8530 closed group crossed ownership boundary %s", boundary));
        assert(history.undoEntries().length == 1 && history.redoEntries().length == 2);
        assert(session.navigate(false) && tool.value == 19 && active is tool,
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
            auto edit = new ValueEdit(&tool.value, before, after);
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
        assert(tool.value == 0 && history.redoEntries().length == 3);
        active = null;
        assert(session.navigate(false) && tool.value == 13 && active is tool,
            format("8530 Redo crossed ownership boundary %s", boundary));
        assert(history.undoEntries().length == 2 && history.redoEntries().length == 1,
            "8530 Redo must leave the foreign tail untouched");
        assert(session.sessionStateJson()["token"].integer == 8530);
    }
}
