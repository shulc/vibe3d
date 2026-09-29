module tests.unit.tool_session_recorded_steps_test;

import command : Command, CmdFlags;
import command_history : CommandHistory;
import command_history : RecordMode;
import command_executor : CommandExecutor;
import edit_session : EditSession, RefireClient;
import editmode : EditMode;
import tool : Tool, ToolSessionPolicy;
import tool_activation_ownership : ToolTransition;
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
    bool pending, ladder;
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = {
            activationRow: true, sessionSteps: true, historyRecordedSteps: true };
        static immutable ToolSessionPolicy ladderPolicy = {
            activationRow: true, sessionSteps: true, historyRecordedSteps: true,
            previewHistoryLadder: true, keepAliveOnCancel: true };
        return ladder ? ladderPolicy : policy;
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
}
