module tests.unit.history_http_adapter_test;

import command : CmdFlags, Command;
import command_history : CommandHistory, HistoryEntry, HistoryFlags;
import edit_session : EditSession;
import editmode : EditMode;
import http_providers : HistoryHttpAdapter;
import mesh : Mesh;
import params : Param;
import step_trace : StepTrace;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import tool : Tool;
import view : View;

private final class RowCommand : Command {
    private string wireName_;
    private string label_;
    private string value_;
    private CmdFlags flags_;
    private bool operationInverse_;

    this(string wireName, string label, string value, CmdFlags flags,
         bool operationInverse) {
        static Mesh mesh;
        static View view;
        super(&mesh, view, EditMode.Vertices);
        wireName_ = wireName;
        label_ = label;
        value_ = value;
        flags_ = flags;
        operationInverse_ = operationInverse;
    }

    override string name() const { return wireName_; }
    override string label() const { return label_; }
    override CmdFlags cmdFlags() const { return flags_; }
    override bool isOperationInverse() const { return operationInverse_; }
    override Param[] params() {
        return [Param.string_("value", "Value", &value_, "")];
    }
    protected override bool applyImpl() { return true; }
}

private void record(CommandHistory history, RowCommand command,
                    bool lifecycle = false) {
    assert(command.apply(), "history adapter setup command must apply");
    if (lifecycle) history.recordToolLifecycle(command);
    else history.record(command);
}

private void recordRefire(CommandHistory history, RowCommand command) {
    assert(command.apply(), "history adapter refire setup command must apply");
    const runId = history.nextRun();
    history.bumpTweakGeneration();
    history.replaceInSessionTail(command, runId);
    // RowCommand deliberately has no run-merge interface. Consolidation closes
    // the run while preserving the tagged row used by this serialization test.
    history.consolidate(runId);
}

private void addRows(CommandHistory history, string prefix, bool redoGroup) {
    const modelFlags = redoGroup
        ? CmdFlags.Model | CmdFlags.SideEffect
        : CmdFlags.Model | CmdFlags.Quiet;
    const uiFlags = redoGroup
        ? CmdFlags.UiState | CmdFlags.Quiet
        : CmdFlags.UiState | CmdFlags.SideEffect;
    const lifecycleFlags = redoGroup
        ? CmdFlags.ToolLifecycle | CmdFlags.UndoForce | CmdFlags.Quiet
        : CmdFlags.ToolLifecycle | CmdFlags.UndoForce;
    const refireFlags = redoGroup
        ? CmdFlags.Model | CmdFlags.SideEffect
        : CmdFlags.Model | CmdFlags.UndoBoundary;

    record(history, new RowCommand(prefix ~ ".model", prefix ~ " Model",
        prefix ~ "-model-arg", modelFlags, !redoGroup));
    record(history, new RowCommand(prefix ~ ".ui", prefix ~ " UI",
        prefix ~ "-ui-arg", uiFlags, redoGroup));
    record(history, new RowCommand(prefix ~ ".lifecycle",
        prefix ~ " Lifecycle", prefix ~ "-lifecycle-arg", lifecycleFlags,
        !redoGroup), true);
    recordRefire(history, new RowCommand(prefix ~ ".refire",
        prefix ~ " Refire", prefix ~ "-refire-arg", refireFlags,
        redoGroup));
}

private struct ExpectedRow {
    string label;
    string args;
    string command;
    long flags;
    bool ui;
    bool inSession;
    bool refire;
    long runId;
    long tweakGen;
    bool opInverse;
}

private ExpectedRow expected(ref const(HistoryEntry) entry) {
    return ExpectedRow(
        entry.label,
        entry.args,
        entry.commandName,
        cast(long)entry.flags,
        (entry.flags & HistoryFlags.UiUndo) != 0,
        (entry.flags & HistoryFlags.InSession) != 0,
        (entry.flags & HistoryFlags.Refire) != 0,
        cast(long)entry.runId,
        cast(long)entry.tweakGeneration,
        entry.cmd !is null && entry.cmd.isOperationInverse());
}

private ExpectedRow[] expectedRows(const(HistoryEntry)[] entries) {
    ExpectedRow[] result;
    foreach (ref entry; entries) result ~= expected(entry);
    return result;
}

private void assertRow(JSONValue actual, ExpectedRow wanted,
                       string side, size_t index) {
    const where = "history HTTP adapter " ~ side ~ "[" ~ index.to!string ~ "]";
    assert(actual["label"].str == wanted.label,
        where ~ ".label expected '" ~ wanted.label ~ "', got '"
        ~ actual["label"].str ~ "'");
    assert(actual["args"].str == wanted.args,
        where ~ ".args expected '" ~ wanted.args ~ "', got '"
        ~ actual["args"].str ~ "'");
    assert(actual["command"].str == wanted.command,
        where ~ ".command expected '" ~ wanted.command ~ "', got '"
        ~ actual["command"].str ~ "'");
    assert(actual["flags"].integer == wanted.flags,
        where ~ ".flags expected " ~ wanted.flags.to!string ~ ", got "
        ~ actual["flags"].integer.to!string);
    assert(actual["ui"].boolean == wanted.ui, where ~ ".ui changed");
    assert(actual["inSession"].boolean == wanted.inSession,
        where ~ ".inSession changed");
    assert(actual["refire"].boolean == wanted.refire,
        where ~ ".refire changed");
    assert(actual["runId"].integer == wanted.runId,
        where ~ ".runId expected " ~ wanted.runId.to!string ~ ", got "
        ~ actual["runId"].integer.to!string);
    assert(actual["tweakGen"].integer == wanted.tweakGen,
        where ~ ".tweakGen expected " ~ wanted.tweakGen.to!string ~ ", got "
        ~ actual["tweakGen"].integer.to!string);
    assert(actual["opInverse"].boolean == wanted.opInverse,
        where ~ ".opInverse changed");
}

unittest { // both non-empty stacks use the same complete row encoder
    auto history = new CommandHistory();
    addRows(history, "undo", false);
    addRows(history, "redo", true);

    foreach (_; 0 .. 4)
        assert(history.undo(), "history adapter setup undo must succeed");

    // Population floors precede every per-row comparison. Four rows on each
    // side cover Model, UI, lifecycle and refire records without an empty-loop
    // green.
    assert(history.undoEntriesVisible().length == 4,
        "history HTTP adapter source population floor: expected 4 undo rows");
    assert(history.redoEntriesVisible().length == 4,
        "history HTTP adapter source population floor: expected 4 redo rows");
    auto wantedUndo = expectedRows(history.undoEntriesVisible());
    auto wantedRedo = expectedRows(history.redoEntriesVisible());

    foreach (i; 0 .. wantedUndo.length) {
        assert(wantedUndo[i].label != wantedRedo[i].label
            && wantedUndo[i].flags != wantedRedo[i].flags,
            "history adapter stand must distinguish undo and redo row "
            ~ i.to!string);
    }
    foreach (i; [0, 1, 3]) {
        assert(wantedUndo[i].args != wantedRedo[i].args,
            "history adapter stand must distinguish undo and redo args at row "
            ~ i.to!string);
    }
    assert(wantedUndo[2].args.length == 0 && wantedRedo[2].args.length == 0,
        "history adapter lifecycle records must preserve their empty args");
    assert(wantedUndo[3].inSession && wantedUndo[3].refire
        && wantedUndo[1].ui,
        "history adapter stand must exercise true inSession/refire/ui flags");
    assert(wantedUndo[3].runId != wantedRedo[3].runId
        && wantedUndo[3].tweakGen != wantedRedo[3].tweakGen,
        "history adapter stand must distinguish undo and redo refire identity");

    Tool active;
    auto session = new EditSession(() => active, history, () {});
    auto adapter = new HistoryHttpAdapter(history, session, null);
    auto payload = parseJSON(adapter.historyJson());
    auto actualUndo = payload["undo"].array;
    auto actualRedo = payload["redo"].array;

    assert(actualUndo.length == 4,
        "history HTTP adapter JSON population floor: expected 4 undo rows, got "
        ~ actualUndo.length.to!string);
    assert(actualRedo.length == 4,
        "history HTTP adapter JSON population floor: expected 4 redo rows, got "
        ~ actualRedo.length.to!string);

    // These two explicit checks name the high-risk refactor failure before the
    // generic field walk: redo must not reuse the undo source or its flags.
    assert(actualRedo[0]["label"].str == wantedRedo[0].label,
        "history HTTP adapter redo source: expected '" ~ wantedRedo[0].label
        ~ "', got '" ~ actualRedo[0]["label"].str
        ~ "' (redo serialized undo rows)");
    assert(actualRedo[0]["flags"].integer == wantedRedo[0].flags,
        "history HTTP adapter redo flags: expected "
        ~ wantedRedo[0].flags.to!string ~ ", got "
        ~ actualRedo[0]["flags"].integer.to!string);

    foreach (i, row; actualUndo) assertRow(row, wantedUndo[i], "undo", i);
    foreach (i, row; actualRedo) assertRow(row, wantedRedo[i], "redo", i);
}

unittest { // nullable, armed and disarmed trace behavior is preserved
    auto history = new CommandHistory();
    Tool active;
    auto session = new EditSession(() => active, history, () {});

    auto absent = new HistoryHttpAdapter(history, session, null);
    assert(parseJSON(absent.traceJson()).array.length == 0,
        "history HTTP adapter null trace must serialize as []");
    absent.armTrace();
    absent.disarmTrace();

    auto trace = new StepTrace();
    auto present = new HistoryHttpAdapter(history, session, trace);
    assert(!trace.armed() && parseJSON(present.traceJson()).array.length == 0,
        "history HTTP adapter trace must start disarmed and empty");
    present.armTrace();
    assert(trace.armed(), "history HTTP adapter trace reset must arm capture");
    trace.append(`{"seq":17,"command":"test.trace"}`);
    auto captured = parseJSON(present.traceJson()).array;
    assert(captured.length == 1,
        "history HTTP adapter armed trace population floor: expected 1 row");
    assert(captured[0]["seq"].integer == 17,
        "history HTTP adapter armed trace lost its row");
    present.disarmTrace();
    assert(!trace.armed() && parseJSON(present.traceJson()).array.length == 0,
        "history HTTP adapter trace disarm must clear and disarm capture");
}
