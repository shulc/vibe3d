module tests.unit.ui.history_panel_test;

import application_command_binding : ApplicationCommandBinding;
import command : Command;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import edit_session : EditSession, KeepAliveOnCancel;
import editmode : EditMode;
import guarded_action_controller : GuardedActionController,
    GuardedActionPorts, GuardObservationPorts;
import macro_recorder : MacroRecorder;
import mesh : Mesh, makeCube;
import registry : Registry;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import ui.history_panel;
import view : View;

private string repositoryRoot() {
    import std.path : dirName;

    return __FILE_FULL_PATH__.dirName.dirName.dirName.dirName;
}

private final class HistoryPanelProbeCommand : Command {
    private string id_;
    private size_t* calls_;

    this(Mesh* mesh, ref View view, string id, size_t* calls) {
        super(mesh, view, EditMode.Polygons);
        id_ = id;
        calls_ = calls;
    }

    override string name() const { return id_; }
    override string label() const { return "History panel " ~ id_; }

    protected override bool applyImpl() {
        ++*calls_;
        return true;
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
    const appSource = readText(root.buildPath("source", "editor_app.d"));

    assert(!stateSource.canFind("EditorApp")
        && !stateSource.canFind("editor_app"),
        "HistoryPanelState/controller regained an EditorApp dependency");
    assert(panelSource.canFind(
            "void drawCommandHistoryPanel(HistoryPanelState state,")
        && !panelSource.canFind("drawCommandHistoryPanel(EditorApp"),
        "History panel drawing regained the whole EditorApp seam");
    foreach (retired; ["historyFilterPtr", "historyShowArgsPtr",
             "historyShowRowNumbersPtr", "historyShowTimestampsPtr",
             "historyShowCommandIdsPtr", "historyReplLastWasErrorPtr",
             "historyReplInputPtr"])
        assert(!appSource.canFind(retired),
            "EditorApp regained retired History form pointer: " ~ retired);
}
