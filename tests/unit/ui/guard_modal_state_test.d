module tests.unit.ui.guard_modal_state_test;

import command : Command, g_testMode;
import command_history : RecordMode;
import editmode : EditMode;
import guarded_action_controller : GuardedActionController,
    GuardedActionPorts, GuardObservationPorts;
import mesh : Mesh;
import ui.discard_guard : GuardAnswer, UiRunOutcome;
import ui.guard_modal_state : GuardModalState;
import ui.panels : drawQuitGuardModal, guardModalDrawSnapshot,
    resetGuardModalDrawSnapshot;
import tests.unit.ui.headless_panel : openPanel;
import view : View;
import d_imgui.imgui_h : ImGuiKey, ImVec2;

private Mesh probeMesh;
private View probeView;

private final class GuardModalProbeCommand : Command {
    private string id_;

    this(string id) {
        super(&probeMesh, probeView, EditMode.Vertices);
        id_ = id;
    }

    override string name() const { return id_; }
    override string label() const { return "Guard modal " ~ id_; }
    override bool discardsUnsavedWork() const { return true; }
}

private final class GuardModalHarness {
    bool dirty = true;
    size_t saveCount;
    Command[] applied;
    RecordMode[] appliedModes;
    GuardAnswer[] answers;
    bool[] performed;
    GuardedActionController controller;

    this() {
        controller = new GuardedActionController(GuardedActionPorts(
            (Command command, RecordMode mode) {
                applied ~= command;
                appliedModes ~= mode;
                return true;
            },
            () => dirty,
            () {
                ++saveCount;
                dirty = false;
                return true;
            },
            (Command) {},
            GuardObservationPorts(
                (record) {},
                (answer, didPerform) {
                    answers ~= answer;
                    performed ~= didPerform;
                },
                (pending) {})));
    }

    GuardModalProbeCommand defer(string id, RecordMode mode) {
        auto command = new GuardModalProbeCommand(id);
        assert(controller.invoke(command, mode, id) == UiRunOutcome.deferred,
            "guard modal fixture did not defer " ~ id);
        return command;
    }
}

private ImVec2 center(ImVec2 lo, ImVec2 hi) {
    return ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
}

private string repositoryRoot() {
    import std.path : dirName;

    return __FILE_FULL_PATH__.dirName.dirName.dirName.dirName;
}

private size_t occurrences(const string haystack, const string needle) {
    import std.string : indexOf;

    size_t count;
    size_t at;
    while (at < haystack.length) {
        const found = haystack.indexOf(needle, at);
        if (found < 0) break;
        ++count;
        at = cast(size_t)found + needle.length;
    }
    return count;
}

unittest { // five fields belong to each state instance, never shared storage
    auto visible = new GuardModalState();
    auto other = new GuardModalState();

    visible.requestDiscardOpen(false, true);
    assert(visible.discardConfirmOpen && visible.discardConfirmPending,
        "pending guard did not request its popup handshake");
    assert(visible.consumeDiscardOpen(),
        "the first pending->open handoff did not fire");
    assert(!visible.consumeDiscardOpen(),
        "one pending guard requested OpenPopup more than once");
    visible.requestDiscardOpen(false, true);
    assert(!visible.discardConfirmPending,
        "an already-open guard re-armed its pending->open handoff");

    visible.publishNotice("visible refusal");
    assert(visible.noticeText == "visible refusal"
        && visible.noticeOpen && visible.noticePending,
        "notice publisher did not write the visible state owner");
    assert(!other.discardConfirmOpen && !other.discardConfirmPending
        && other.noticeText.length == 0 && !other.noticeOpen
        && !other.noticePending,
        "two GuardModalState instances share popup storage");
    assert(visible.consumeNoticeOpen() && !visible.consumeNoticeOpen(),
        "one notice requested OpenPopup more than once");

    other.requestDiscardOpen(true, true);
    assert(!other.discardConfirmOpen && !other.discardConfirmPending,
        "test mode opened the guard window instead of suppressing only it");
}

unittest { // real ImGui handshake keeps every answer deferred until settle
    const oldTestMode = g_testMode;
    g_testMode = false;
    scope (exit) g_testMode = oldTestMode;

    auto state = new GuardModalState();
    auto harness = new GuardModalHarness();
    resetGuardModalDrawSnapshot();
    auto ui = openPanel(() {
        drawQuitGuardModal(state, false, harness.controller);
    }, "Guard modal host");
    scope (exit) ui.close();

    auto saveCommand = harness.defer("save", RecordMode.Coalescing);
    ui.frame();
    ui.frame();
    auto snap = guardModalDrawSnapshot();
    assert(snap.discardOpenCalls == 1 && state.discardConfirmOpen
        && !state.discardConfirmPending,
        "one deferred command must perform pending->OpenPopup exactly once");
    assert(snap.saveMax.x > snap.saveMin.x && snap.saveMax.y > snap.saveMin.y,
        "guard modal did not publish a clickable Save button");
    ui.hoverAt(center(snap.saveMin, snap.saveMax));
    snap = guardModalDrawSnapshot();
    ui.pressAt(center(snap.saveMin, snap.saveMax));
    ui.release();
    assert(harness.saveCount == 1,
        "Save answer did not run the ordinary Save separately");
    assert(harness.applied.length == 0,
        "guarded action applied at the Save answer before settle");
    assert(harness.controller.pending && !harness.controller.awaitingAnswer,
        "Save answer dropped the deferred command before settle");
    assert(harness.controller.settle()
        && harness.applied.length == 1
        && harness.applied[0] is saveCommand,
        "post-flush settle did not apply the Save-held command");

    harness.dirty = true;
    auto discardCommand = harness.defer("discard", RecordMode.Record);
    ui.frame();
    ui.frame();
    snap = guardModalDrawSnapshot();
    assert(snap.discardOpenCalls == 2,
        "the second guarded command did not get exactly one fresh open request");
    assert(snap.discardMax.x > snap.discardMin.x
        && snap.discardMax.y > snap.discardMin.y,
        "guard modal did not publish a clickable Discard button");
    ui.hoverAt(center(snap.discardMin, snap.discardMax));
    snap = guardModalDrawSnapshot();
    ui.pressAt(center(snap.discardMin, snap.discardMax));
    ui.release();
    assert(harness.applied.length == 1,
        "guarded action applied at the Discard answer before settle");
    assert(harness.controller.pending && !harness.controller.awaitingAnswer,
        "Discard answer dropped the deferred command before settle");
    assert(harness.controller.settle()
        && harness.applied.length == 2
        && harness.applied[1] is discardCommand,
        "post-flush settle did not apply the Discard-held command");
    assert(!harness.controller.settle() && harness.applied.length == 2,
        "guarded settle was not one-shot");
    assert(harness.saveCount == 1
        && harness.appliedModes == [RecordMode.Coalescing, RecordMode.Record],
        "ordinary Save and guarded applies were not counted independently");

    harness.dirty = true;
    harness.defer("cancel-between-frames", RecordMode.Record);
    ui.frame();
    assert(state.discardConfirmOpen,
        "between-frame cancellation setup did not open the popup");
    harness.controller.answerCancel();
    const answersBeforeCloseFrame = harness.answers.length;
    ui.frame();
    assert(!state.discardConfirmOpen && !state.discardConfirmPending,
        "a controller cancelled between frames left the popup open");
    assert(harness.answers.length == answersBeforeCloseFrame,
        "closing a popup for an already-cancelled controller answered twice");

    harness.dirty = true;
    harness.defer("escape", RecordMode.Record);
    ui.frame();
    ui.keyDown(cast(int)ImGuiKey.Escape);
    ui.frame();
    ui.keyUp(cast(int)ImGuiKey.Escape);
    ui.frame();
    assert(!harness.controller.pending && !state.discardConfirmOpen,
        "ESC did not route through the guard's Cancel answer");
    ui.close();

    harness.dirty = true;
    harness.defer("test-mode", RecordMode.Record);
    auto suppressedState = new GuardModalState();
    auto suppressedUi = openPanel(() {
        drawQuitGuardModal(suppressedState, true, harness.controller);
    }, "Suppressed guard modal host");
    scope (exit) suppressedUi.close();
    suppressedUi.frame();
    assert(harness.controller.awaitingAnswer
        && !suppressedState.discardConfirmOpen
        && harness.applied.length == 2,
        "test mode suppressed the deferral instead of only the guard window");
    harness.controller.answerCancel();
}

unittest { // production publisher, panel and diagnostic share one owner
    import std.algorithm.searching : canFind;
    import std.file : readText;
    import std.path : buildPath;
    import std.string : indexOf;

    const root = repositoryRoot();
    const app = readText(root.buildPath("source", "app.d"));
    const editor = readText(root.buildPath("source", "editor_app.d"));
    const panel = readText(root.buildPath("source", "ui", "panels.d"));
    const provider = readText(root.buildPath("source", "http_providers.d"));

    assert(occurrences(app, "auto guardModalState = new GuardModalState();") == 1,
        "application must construct exactly one GuardModalState owner");
    assert(occurrences(app,
            "app.guardModalState               = guardModalState;") == 1
        && occurrences(app,
            "guardModalState.publishNotice(text);") == 1
        && occurrences(app,
            "drawQuitGuardModal(guardModalState, testMode, guardController);") == 1,
        "notice publisher, visible diagnostic and modal no longer share one GuardModalState");
    assert(provider.indexOf("guardModalState.discardConfirmOpen") >= 0
        && provider.indexOf("guardModalState.noticeOpen") >= 0,
        "HTTP visible-state diagnostic no longer reads GuardModalState");

    immutable string[] retiredSlots = [
        "discardConfirmOpenPtr", "discardConfirmPendingPtr",
        "noticeTextPtr", "noticeOpenPtr", "noticePendingPtr",
    ];
    foreach (slot; retiredSlots)
        assert(!app.canFind(slot) && !editor.canFind(slot),
            "retired modal pointer slot/storage remains: " ~ slot);
    immutable string[] retiredLocals = [
        "bool   discardConfirmOpen;", "bool   discardConfirmPending;",
        "string noticeText;", "bool   noticeOpen;", "bool   noticePending;",
    ];
    foreach (local; retiredLocals)
        assert(!app.canFind(local),
            "old app.main modal storage remains beside GuardModalState: " ~ local);

    assert(panel.indexOf(
            "void drawQuitGuardModal(GuardModalState state, bool testMode,") >= 0
        && panel.indexOf("void drawQuitGuardModal(EditorApp") < 0,
        "quit modal regained the whole EditorApp instead of its three roles");
    assert(occurrences(panel,
            "cancelGuardPopup(state, guardController);") == 4,
        "Cancel button and ESC/X no longer share one answerCancel path");

    assert(panel.canFind("Until task 1521 this")
        && panel.canFind("guard a SECOND point")
        && panel.canFind("File → New and File → Open but NOT quit")
        && panel.canFind("one GuardedActionController"),
        "the measured task-1521 single-decision-point contract was lost");

    const raiseBegin = app.indexOf("    void raiseNotice(string text)");
    const raiseEnd = app.indexOf("    void raiseCommandNotice(Command cmd)");
    assert(raiseBegin >= 0 && raiseEnd > raiseBegin,
        "could not locate the production notice publisher");
    const raiseBody = app[cast(size_t)raiseBegin .. cast(size_t)raiseEnd];
    const emptyGate = raiseBody.indexOf("if (text.length == 0) return;");
    const testGate = raiseBody.indexOf("if (command.g_testMode) return;");
    const publish = raiseBody.indexOf("guardModalState.publishNotice(text);");
    assert(emptyGate >= 0 && testGate > emptyGate && publish > testGate,
        "notice reason/test-mode gating moved after visible publication");
}
