module tests.unit.ui.history_panel_test;

import application_command_binding : ApplicationCommandBinding;
import command : Command;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import edit_session : EditSession, KeepAliveOnCancel;
import editmode : EditMode;
import guarded_action_controller : GuardedActionController,
    GuardedActionPorts, GuardObservationPorts;
import commands.macros.record : MacroRecord;
import macro_recorder : MacroRecorder;
import mesh : Mesh, makeCube;
import registry : Registry;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import ui.history_panel;
import ui.panels : drawCommandHistoryPanel, historyMacroStripSnapshot;
import tests.unit.ui.headless_panel : openPanel;
import view : View;

private string repositoryRoot() {
    import std.path : dirName;

    return __FILE_FULL_PATH__.dirName.dirName.dirName.dirName;
}

private final class HistoryPanelProbeCommand : Command {
    private string id_;
    private size_t* calls_;
    private bool applies_;

    this(Mesh* mesh, ref View view, string id, size_t* calls,
         bool applies = true) {
        super(mesh, view, EditMode.Polygons);
        id_ = id;
        calls_ = calls;
        applies_ = applies;
    }

    override string name() const { return id_; }
    override string label() const { return "History panel " ~ id_; }

    protected override bool applyImpl() {
        ++*calls_;
        return applies_;
    }
}

private final class HistoryPanelKeepAliveTool : Tool, KeepAliveOnCancel {
    bool editOpen = true;
    size_t cancels;
    size_t resyncs;

    override bool hasUncommittedEdit() const { return editOpen; }
    override void cancelUncommittedEdit() {
        ++cancels;
        editOpen = false;
    }
    override void resyncSession() { ++resyncs; }
    override bool survivesEditCancel() const { return true; }
}

private final class HistoryPanelActionHarness {
    Mesh mesh;
    View view;
    Registry registry;
    CommandHistory history;
    CommandExecutor executor;
    EditSession session;
    GuardedActionController guard;
    ApplicationCommandBinding binding;
    MacroRecorder macroRecorder;
    Tool activeTool;
    size_t firstCalls;
    size_t secondCalls;
    size_t refusedCalls;
    HistoryPanelActions actions;

    this() {
        mesh = makeCube();
        view = new View(0, 0, 800, 600);
        history = new CommandHistory();
        executor = new CommandExecutor(history,
            () => activeTool !is null,
            (ToolTransition) { activeTool = null; });
        session = new EditSession(
            () => activeTool, history, () { activeTool = null; });
        guard = new GuardedActionController(GuardedActionPorts(
            (Command command, RecordMode mode) =>
                executor.applyOrRefire(command, mode, null),
            () => false,
            () => true,
            (Command) {},
            GuardObservationPorts(
                (record) {}, (answer, performed) {}, (pending) {})));
        binding = new ApplicationCommandBinding(
            registry, executor, session, history, guard,
            (Command) {}, (string) {});
        macroRecorder = new MacroRecorder();

        registry.commandFactories["probe.first"] = () => cast(Command)
            new HistoryPanelProbeCommand(
                &mesh, view, "probe.first", &firstCalls);
        registry.commandFactories["probe.second"] = () => cast(Command)
            new HistoryPanelProbeCommand(
                &mesh, view, "probe.second", &secondCalls);
        registry.commandFactories["probe.refused"] = () => cast(Command)
            new HistoryPanelProbeCommand(
                &mesh, view, "probe.refused", &refusedCalls, false);
        registry.commandFactories["macro.record"] = () => cast(Command)
            new MacroRecord(&mesh, view, EditMode.Polygons, macroRecorder);

        actions = bindHistoryPanelActions(
            history,
            (bool isUndo) => session.navigate(isUndo),
            (size_t rawIndex) => binding.replayHistoryEntry(rawIndex),
            (string id, string paramsJson) => binding.dispatchUi(id, paramsJson),
            (string) => false,
            macroRecorder);
    }

    HistoryPanelController controller(HistoryPanelState state) {
        return HistoryPanelController(state, actions);
    }

    void dispatch(string id) {
        binding.dispatchUi(id, "{}");
    }
}

unittest { // each state owns its buffers for its whole panel lifetime
    auto a = new HistoryPanelState();
    auto b = new HistoryPanelState();
    assert(!a.visible && a.showArgs && !a.showRowNumbers
        && !a.showTimestamps && !a.showCommandIds && !a.replLastWasError,
        "History panel state lost its initial visibility/display field vector");
    assert(a.filterBuffer.ptr !is b.filterBuffer.ptr,
        "history states A and B share the filter backing buffer");
    assert(a.replBuffer.ptr !is b.replBuffer.ptr,
        "history states A and B share the REPL backing buffer");
    assert(a.filterBuffer.length == HistoryFilterCapacity
        && a.replBuffer.length == HistoryReplCapacity,
        "history state buffers lost their fixed widget capacities");

    char[] producer = "first-only".dup;
    a.setFilterText(cast(string)producer);
    producer[] = 'x';
    assert(a.filterText == "first-only",
        "history filter borrowed producer storage instead of owning its bytes");
    assert(b.filterText.length == 0,
        "editing state A's filter changed independent state B");

    char[] replProducer = "probe.first".dup;
    a.setReplText(cast(string)replProducer);
    replProducer[] = 'y';
    assert(a.replText == "probe.first",
        "history REPL borrowed producer storage instead of owning its bytes");
    assert(b.replText.length == 0,
        "editing state A's REPL changed independent state B");
}

unittest { // REPL parsing and state reaction through real application dispatch
    auto harness = new HistoryPanelActionHarness();
    auto state = new HistoryPanelState();
    auto controller = harness.controller(state);

    state.setReplText("probe.first key:");
    assert(controller.submitRepl() == HistoryReplOutcome.failed,
        "malformed History REPL input was not reported as a parse failure");
    assert(state.replLastWasError
        && state.replText == "probe.first key:"
        && harness.firstCalls == 0
        && harness.history.undoEntries().length == 0,
        "parse failure must retain input, mark error, and dispatch nothing");

    state.setReplText("probe.refused");
    assert(controller.submitRepl() == HistoryReplOutcome.dispatched,
        "a non-throwing refused History REPL dispatch was treated as failure");
    assert(!state.replLastWasError && state.replText.length == 0
        && harness.refusedCalls == 1
        && harness.history.undoEntries().length == 0,
        "a non-throwing refused History REPL dispatch must still clear input");

    state.setReplText("probe.first");
    assert(controller.submitRepl() == HistoryReplOutcome.dispatched,
        "valid History REPL input did not dispatch");
    assert(!state.replLastWasError && state.replText.length == 0,
        "a non-throwing History REPL dispatch must clear input and error");
    assert(harness.firstCalls == 1
        && harness.history.undoEntries().length == 1
        && harness.history.undoEntries()[0].commandName == "probe.first",
        "History REPL success did not call the real application binding/history action");
}

unittest { // macro strip reads the recorder again after its button dispatch
    auto harness = new HistoryPanelActionHarness();
    harness.macroRecorder.start();
    harness.macroRecorder.onCommandRecorded("probe.first", 0);
    harness.macroRecorder.stop();
    assert(!harness.macroRecorder.active && harness.macroRecorder.length == 1,
        "macro strip setup needs an inactive non-empty recorder");

    auto state = new HistoryPanelState();
    state.visible = true;
    auto read = bindHistoryPanelRead(harness.history);
    auto ui = openPanel(() {
        drawCommandHistoryPanel(state, read, harness.actions, 0.0f);
    }, "History panel host");
    scope (exit) ui.close();

    ui.frame();
    auto before = historyMacroStripSnapshot();
    assert(before.status.length == 1 && before.saveEnabled,
        "macro strip setup did not draw its populated-buffer state");
    assert(before.recMax.x > before.recMin.x
        && before.recMax.y > before.recMin.y,
        "macro strip did not publish a clickable Rec rectangle");
    auto recPoint = before.recMin;
    recPoint.x = (before.recMin.x + before.recMax.x) * 0.5f;
    recPoint.y = (before.recMin.y + before.recMax.y) * 0.5f;

    ui.pressAt(recPoint);
    ui.release();
    auto after = historyMacroStripSnapshot();
    assert(harness.macroRecorder.active && harness.macroRecorder.length == 0,
        "the real macro.record action did not start and clear the recorder");
    assert(after.status.length == 0 && !after.saveEnabled,
        "macro strip used the pre-dispatch recorder length for Save/REC");
}

unittest { // cursor undo cancels the live edit, then moves raw history
    auto harness = new HistoryPanelActionHarness();
    harness.dispatch("probe.first");
    harness.dispatch("probe.second");
    assert(harness.history.undoEntries().length == 2,
        "live-navigation setup did not populate two history rows");

    auto held = new HistoryPanelKeepAliveTool();
    harness.activeTool = held;
    auto controller = harness.controller(new HistoryPanelState());

    assert(controller.navigate(true),
        "cursor undo did not consume the live edit");
    assert(harness.activeTool is held && held.cancels == 1 && !held.editOpen,
        "cursor undo must cancel the live edit while keeping its tool armed");
    assert(harness.history.undoEntries().length == 2,
        "cursor undo stepped history before cancelling the live edit");

    assert(controller.navigate(true),
        "the next cursor undo did not move history");
    assert(harness.activeTool is held && held.resyncs == 1
        && harness.history.undoEntries().length == 1
        && harness.history.redoEntries().length == 1,
        "after live cancel, the next navigation must step history and keep the tool armed");
}

unittest { // replay preserves the clicked entry's original raw index
    auto harness = new HistoryPanelActionHarness();
    harness.dispatch("probe.first");
    harness.dispatch("probe.second");
    auto read = bindHistoryPanelRead(harness.history);
    auto before = read.undoEntries();
    assert(before.length == 2
        && before[0].commandName == "probe.first"
        && before[1].commandName == "probe.second",
        "replay setup must hold two populated, different command rows");

    auto controller = harness.controller(new HistoryPanelState());
    controller.replay(0);
    assert(harness.firstCalls == 2 && harness.secondCalls == 1,
        "History replay did not use the original raw index 0");
    assert(harness.history.undoEntries().length == 3
        && harness.history.undoEntries()[$ - 1].commandName == "probe.first",
        "History replay did not append the command selected by raw index 0");
}

unittest { // the History panel seam cannot silently grow EditorApp back
    import std.algorithm.searching : canFind;
    import std.file : readText;
    import std.path : buildPath;

    const root = repositoryRoot();
    const stateSource = readText(root.buildPath("source", "ui", "history_panel.d"));
    const panelSource = readText(root.buildPath("source", "ui", "panels.d"));
    const editorAppSource = readText(root.buildPath("source", "editor_app.d"));
    const appSource = readText(root.buildPath("source", "app.d"));

    assert(!stateSource.canFind("EditorApp")
        && !stateSource.canFind("editor_app"),
        "HistoryPanelState/controller regained an EditorApp dependency");
    assert(panelSource.canFind(
            "void drawCommandHistoryPanel(HistoryPanelState state,")
        && !panelSource.canFind("drawCommandHistoryPanel(EditorApp"),
        "History panel drawing regained the whole EditorApp seam");
    assert(appSource.canFind(
            "bindHistoryPanelActions(\n        history, &navHistory,"),
        "app.d no longer binds History panel navigation through navHistory");
    foreach (retired; ["historyFilterPtr", "historyShowArgsPtr",
             "historyShowRowNumbersPtr", "historyShowTimestampsPtr",
             "historyShowCommandIdsPtr", "historyReplLastWasErrorPtr",
             "historyReplInputPtr"])
        assert(!editorAppSource.canFind(retired),
            "EditorApp regained retired History form pointer: " ~ retired);
}
