// The behavior rig constructs its own narrow roles; the final cell separately
// pins the production call so correct helper behavior cannot hide mis-wiring.
module commands.history.history_macro_registration_test;

import std.algorithm : count, endsWith;
import std.file : exists, readText, remove;
import std.json : parseJSON;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;

import command : CmdFlags, Command;
import command_history : CommandHistory, HistoryFlags;
import commands.macros.save_recorded : MacroSaveRecorded;
import edit_session : EditSession;
import tool : ToolSessionPolicy;
import editmode : EditMode;
import history_macro_registration : registerHistoryCommands;
import live_registration_roles : LiveSessionRole, LiveView, LiveViewModeRole;
import macro_recorder : MacroRecorder;
import mesh : Mesh, makeCube;
import params : injectParamsInto;
import registry : Registry;
import session_owner : Session;
import tool : Tool;
import ui.history_panel : HistoryPanelActions, HistoryPanelController,
    HistoryPanelState, bindHistoryPanelActions;
import view : View;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
    "..", "..", "..", "..");

private final class RegistrationProbeCommand : Command {
    private string id_;
    private int* value_;
    private CmdFlags flags_;

    this(Mesh* mesh, ref View view, string id, int* value,
         CmdFlags flags = CmdFlags.Model) {
        super(mesh, view, EditMode.Polygons);
        id_ = id;
        value_ = value;
        flags_ = flags;
    }

    override string name() const { return id_; }
    override string label() const { return "Registration " ~ id_; }
    override CmdFlags cmdFlags() const { return flags_; }

    protected override bool applyImpl() {
        ++*value_;
        noteUndoRecorded();
        return true;
    }

    protected override void revertImpl() { --*value_; }
}

private final class RegistrationKeepAliveTool : Tool {
    bool editOpen = true;
    size_t cancels;
    size_t resyncs;

    override bool hasUncommittedEdit() const { return editOpen; }
    override void cancelUncommittedEdit() {
        ++cancels;
        editOpen = false;
    }
    override void resyncSession() { ++resyncs; }
    // Keep-alive as policy data (slice M4; the former KeepAliveOnCancel).
    override ToolSessionPolicy sessionPolicy() const nothrow @nogc {
        static immutable ToolSessionPolicy policy = { keepAliveOnCancel: true };
        return policy;
    }
}

private final class RegistrationHarness {
    Session* session;
    View camera;
    Registry registry;
    CommandHistory history;
    HistoryPanelState panelState;
    MacroRecorder macroRecorder;
    Tool activeTool;
    EditSession editSession;
    HistoryPanelActions panelActions;
    int value;

    this() {
        session = Session.bootstrap(makeCube());
        camera = new View(0, 0, 800, 600);
        history = new CommandHistory();
        panelState = new HistoryPanelState();
        macroRecorder = new MacroRecorder();

        ref View liveView() { return camera; }
        registerHistoryCommands(registry, LiveSessionRole(session),
            LiveViewModeRole(cast(LiveView)&liveView,
                                 session.editModePtr()),
            history, panelState, macroRecorder);

        editSession = new EditSession(
            () => activeTool, history, () { activeTool = null; });
        panelActions = bindHistoryPanelActions(
            history,
            (bool isUndo) => editSession.navigate(isUndo),
            (size_t rawIndex) {},
            (string id, string paramsJson) {},
            (string id) => false,
            macroRecorder);
    }

    Command probe(string id = "probe.replayable") {
        return new RegistrationProbeCommand(
            &session.editMesh(), camera, id, &value);
    }

    void populateTwo() {
        assert(history.fire(probe("probe.first"))
            && history.fire(probe("probe.second")),
            "5810 trajectory setup could not record two replayable rows");
        assert(value == 2 && history.undoEntries().length == 2,
            "5810 trajectory population: expected value=2 and two undo rows");
    }
}

unittest { // real owners, clear/lockout, and macro record/save factories
    auto h = new RegistrationHarness();
    assert(h.registry.commandIds().length == 11,
        "5810 registrar population: expected exactly 11 history/macro ids");

    assert(!h.panelState.visible,
        "5810 panel owner setup must start hidden");
    assert(h.registry.makeCommand("history.show").apply()
        && h.panelState.visible,
        "5810 history.show did not mutate the real panel owner");
    assert(h.registry.makeCommand("history.show").apply()
        && !h.panelState.visible,
        "5810 history.show toggled a copied panel owner");

    assert(h.history.fire(h.probe()) && h.history.undoEntries().length == 1,
        "5810 clear setup did not populate history");
    assert(h.registry.makeCommand("history.clear").apply()
        && h.history.undoEntries().length == 0
        && h.history.redoEntries().length == 0,
        "5810 history.clear did not clear both stacks");

    assert(h.registry.makeCommand("undo.lockout.on").apply(),
        "5810 lockout-on factory refused");
    const blockedValue = h.value;
    assert(!h.history.fire(h.probe("probe.blocked"))
        && h.value == blockedValue
        && h.history.undoEntries().length == 0,
        "5810 lockout allowed apply or history recording");
    assert(h.registry.makeCommand("undo.lockout.off").apply()
        && h.history.fire(h.probe()),
        "5810 lockout-off did not restore history service");

    h.history.clear();
    h.history.onRecord = (line, flags) =>
        h.macroRecorder.onCommandRecorded(line, flags);
    assert(h.registry.makeCommand("macro.record").apply()
        && h.macroRecorder.active && h.macroRecorder.length == 0,
        "5810 macro.record did not start a fresh recorder");
    assert(h.history.fire(h.probe()) && h.macroRecorder.length == 1,
        "5810 macro recorder did not observe the replayable command");

    auto stop = h.registry.makeCommand("macro.record");
    auto stopArgs = parseJSON(`{"state":0}`);
    injectParamsInto(stop.params(), stopArgs);
    assert(stop.apply() && !h.macroRecorder.active
        && h.macroRecorder.length == 1,
        "5810 macro.record state:0 did not stop without clearing");
    assert(h.history.fire(h.probe("probe.afterStop"))
        && h.macroRecorder.length == 1,
        "5810 stopped macro recorder still captured commands");

    const path = buildPath("/var/tmp", "vibe3d-5810-macro.lxm");
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    auto save = cast(MacroSaveRecorded)
        h.registry.makeCommand("macro.saveRecorded");
    assert(save !is null, "5810 macro.saveRecorded factory returned wrong type");
    auto saveArgs = parseJSON(`{"path":"/var/tmp/vibe3d-5810-macro.lxm"}`);
    injectParamsInto(save.params(), saveArgs);
    assert(save.apply() && exists(path),
        "5810 macro.saveRecorded did not write the captured macro");
    const macroText = readText(path);
    assert(macroText.count('\n') == 2
        && macroText.endsWith("probe.replayable\n"),
        "5810 saved macro did not contain exactly the pre-stop command");
}

unittest { // script export sees one lifecycle and one replayable row
    auto h = new RegistrationHarness();
    assert(h.history.fire(h.probe()),
        "5810 export fixture could not record replayable row");
    auto lifecycle = new RegistrationProbeCommand(
        &h.session.editMesh(), h.camera, "probe.lifecycle", &h.value,
        CmdFlags.ToolLifecycle);
    h.history.recordToolLifecycle(lifecycle);

    auto rows = h.history.undoEntriesVisible();
    assert(rows.length == 2,
        "5810 export fixture population: expected lifecycle + replayable rows");
    assert(rows[0].commandName == "probe.replayable"
        && (rows[0].flags & HistoryFlags.ToolLifecycle) == 0
        && rows[1].commandName == "probe.lifecycle"
        && (rows[1].flags & HistoryFlags.ToolLifecycle) != 0,
        "5810 export fixture did not contain both required row classes");

    const path = buildPath("/var/tmp", "vibe3d-5810-history.lxm");
    if (exists(path)) remove(path);
    scope(exit) if (exists(path)) remove(path);
    auto save = h.registry.makeCommand("history.saveAsScript");
    auto args = parseJSON(`{"path":"/var/tmp/vibe3d-5810-history.lxm"}`);
    injectParamsInto(save.params(), args);
    assert(save.apply() && exists(path),
        "5810 history.saveAsScript did not write its fixture");
    const scriptText = readText(path);
    assert(scriptText.count('\n') == 2
        && scriptText.endsWith("probe.replayable\n"),
        "5810 lifecycle export filter: lifecycle row leaked into script");
}

unittest { // raw command undo and panel cursor deliberately diverge live
    auto raw = new RegistrationHarness();
    raw.populateTwo();
    auto rawTool = new RegistrationKeepAliveTool();
    raw.activeTool = rawTool;
    assert(raw.registry.makeCommand("history.undo").apply(),
        "5810 raw trajectory: history.undo factory refused");
    assert(raw.value == 1
        && raw.history.undoEntries().length == 1
        && raw.history.redoEntries().length == 1
        && rawTool.editOpen && rawTool.cancels == 0,
        "5810 raw trajectory must step history without cancelling the live edit");

    auto panel = new RegistrationHarness();
    panel.populateTwo();
    auto panelTool = new RegistrationKeepAliveTool();
    panel.activeTool = panelTool;
    auto controller = HistoryPanelController(panel.panelState,
                                              panel.panelActions);
    assert(controller.navigate(true),
        "5810 panel trajectory: cursor undo refused");
    assert(panel.value == 2
        && panel.history.undoEntries().length == 2
        && panel.history.redoEntries().length == 0
        && !panelTool.editOpen && panelTool.cancels == 1
        && panel.activeTool is panelTool,
        "5810 panel trajectory must cancel the live edit before stepping history");
}

unittest { // production wiring, scope fences, and the single panel owner
    const registration = readText(buildPath(repoRoot, "source", "registration.d"));
    const registrar = readText(buildPath(repoRoot, "source",
        "history_macro_registration.d"));
    const lifecycle = readText(buildPath(repoRoot, "source",
        "scene_file_lifecycle_registration.d"));
    const app = readText(buildPath(repoRoot, "source", "app.d"));

    assert(registrar.length > 3_500,
        "5810 production census population: registrar source is too small");
    assert(registrar.count("EditorApp") == 0
        && registrar.count("editor_app") == 0,
        "5810 narrow-role witness: registrar imports or names EditorApp");
    assert(registrar.count(
            "new HistoryUndo(&session.activeMesh(), live.view(), live.mode, history)") == 1
        && registrar.count(
            "new HistoryRedo(&session.activeMesh(), live.view(), live.mode, history)") == 1
        && registrar.count("EditSession") == 0
        && registrar.count(".navigate(") == 0,
        "5810 raw-door fence: history.undo/redo stopped stepping CommandHistory directly");
    assert(registrar.count("reg.registerCommand(") == 11,
        "5810 registrar id population changed from 11");
    assert(registrar.count("scene.reset") == 0
        && registrar.count("scene.loadMesh") == 0
        && lifecycle.count("registerCommand(\"scene.reset\"") == 1
        && lifecycle.count("registerCommand(\"scene.loadMesh\"") == 1
        && registration.count("registerCommand(\"scene.reset\"") == 0
        && registration.count("registerCommand(\"scene.loadMesh\"") == 0,
        "5810 lifecycle scope fence: scene reset/load left the old registrar");

    enum productionCall =
        "registerHistoryCommands(app.reg(), LiveSessionRole(app.sessionOwner),";
    assert(registration.count(productionCall) == 1
        && registration.count(
            "app.history, app.historyPanelState, app.macroRecorder);") == 1,
        "5810 production wiring witness: registerCommands no longer calls the "
        ~ "narrow registrar with the real owners");
    assert(registration.count("bindSelTypeAuthority(") == 1,
        "5810 registry construction authority bind changed");
    assert(app.count("new HistoryPanelState()") == 1
        && registration.count("new HistoryPanelState()") == 0
        && registrar.count("new HistoryPanelState()") == 0,
        "5810 panel ownership witness: production gained a duplicate panel state");
}
