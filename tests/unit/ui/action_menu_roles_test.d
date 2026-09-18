module tests.unit.ui.action_menu_roles_test;

import std.algorithm : count;
import std.file : readText;
import std.json : parseJSON;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;

import application_command_binding : ApplicationCommandBinding;
import bindbc.sdl : SDL_Keymod, KMOD_ALT, KMOD_CTRL, KMOD_GUI, KMOD_NONE;
import buttonset : Action, ActionKind, Button, Panel, PopupItem, PopupItemKind,
    loadButtons;
import command : CmdFlags, Command, g_testMode;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import edit_session : EditSession;
import editmode : EditMode;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import mesh : makeCube;
import params : Param;
import registry : Registry;
import session_owner : Session;
import tests.unit.ui.headless_panel : openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import toolpipe.packets : FalloffType;
import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
import toolpipe.stage : TaskCode;
import toolpipe.stages.falloff : FalloffStage;
import ui.action_menu : ActionMenuRoles, bindActionMenu, dispatchAction,
    popupWidgetId, renderButtonPopups, renderFalloffStackItems,
    renderPopupItems, selectButtonVariant;
import ui.availability : beginButtonAvailabilityFrame,
    buttonAvailabilityJson, endButtonAvailabilityFrame;
import view : View;
import ImGui = d_imgui;

private enum repoRoot = buildNormalizedPath(
    dirName(__FILE_FULL_PATH__), "..", "..", "..");

private final class MenuProbeState {
    size_t applies;
    float lastAmount;
}

private final class MenuProbeCommand : Command {
    private string id_;
    private MenuProbeState state_;
    private bool applies_;
    private bool parameterized_;
    private float amount_;

    this(Session* owner, ref View view, string id, MenuProbeState state,
         bool applies = true, bool parameterized = false) {
        super(&owner.editMesh(), view, owner.editMode);
        id_ = id;
        state_ = state;
        applies_ = applies;
        parameterized_ = parameterized;
    }

    override string name() const { return id_; }
    override string label() const { return "Action-menu " ~ id_; }
    override CmdFlags cmdFlags() const { return CmdFlags.Model; }
    override Param[] params() {
        return parameterized_
            ? [Param.float_("amount", "Amount", &amount_, 0.0f)]
            : [];
    }
    protected override bool applyImpl() {
        if (!applies_) {
            baseRefusal_ = "action-menu refusal";
            return false;
        }
        ++state_.applies;
        state_.lastAmount = amount_;
        noteUndoRecorded();
        return true;
    }
    protected override void revertImpl() {}
}

private final class ActionMenuHarness {
    Session* owner;
    View view;
    Registry registry;
    CommandHistory history;
    CommandExecutor executor;
    EditSession editSession;
    GuardedActionController guard;
    ApplicationCommandBinding binding;
    Tool activeTool;
    MenuProbeState state;
    size_t guardNoticeCount;
    string lastGuardNotice;
    size_t dispatchCount;
    size_t openArgsCount;
    size_t activationCount;

    this() {
        owner = Session.bootstrap(makeCube());
        view = new View(0, 0, 800, 600);
        history = new CommandHistory;
        executor = new CommandExecutor(history,
            () => activeTool !is null,
            (ToolTransition) { activeTool = null; });
        editSession = new EditSession(
            () => activeTool, history, () { activeTool = null; });
        guard = new GuardedActionController(GuardedActionPorts(
            (Command command, RecordMode mode) =>
                executor.applyOrRefire(command, mode, null),
            () => false,
            () => true,
            (Command command) {
                ++guardNoticeCount;
                lastGuardNotice = command.name();
            },
            GuardObservationPorts(
                (record) {}, (answer, performed) {}, (pending) {})));
        binding = new ApplicationCommandBinding(
            registry, executor, editSession, history, guard,
            (Command) {}, (string) {});
        state = new MenuProbeState;
        registry.commandFactories["probe.script"] = () => cast(Command)
            new MenuProbeCommand(owner, view, "probe.script", state, true, true);
        registry.commandFactories["probe.command"] = () => cast(Command)
            new MenuProbeCommand(owner, view, "probe.command", state);
        registry.commandFactories["probe.refuse"] = () => cast(Command)
            new MenuProbeCommand(owner, view, "probe.refuse", state, false);
        registry.commandFactories["probe.args"] = () => cast(Command)
            new MenuProbeCommand(owner, view, "probe.args", state, true, true);
    }

    ActionMenuRoles bind(bool openParameterized = false) {
        return bindActionMenu(
            (ref const Action action) => "",
            (string id, string paramsJson) {
                ++dispatchCount;
                binding.dispatchUi(id, paramsJson);
            },
            (string) { ++activationCount; },
            (string id) {
                ++openArgsCount;
                return openParameterized && id == "probe.args";
            });
    }

    void clear() {
        history.clear();
        state.applies = 0;
        state.lastAmount = 0;
        guardNoticeCount = 0;
        lastGuardNotice = "";
        dispatchCount = 0;
        openArgsCount = 0;
        activationCount = 0;
        assert(history.undoEntries().length == 0,
            "6560 history floor must begin below the capped-stack boundary");
    }
}

private Action scriptAction(string[] lines) {
    Action action;
    action.kind = ActionKind.script;
    action.scriptLines = lines;
    return action;
}

private Action commandAction(string id) {
    Action action;
    action.kind = ActionKind.command;
    action.id = id;
    return action;
}

private PopupItem[] firstRealPopup() {
    Panel[] panels = loadButtons("config/buttons.yaml");
    foreach (ref panel; panels)
        foreach (ref item; panel.items) {
            if (item.isGroup) {
                foreach (ref button; item.group.buttons)
                    if (button.action.kind == ActionKind.popup
                        && button.action.popupItems.length >= 2)
                        return button.action.popupItems;
            } else if (item.button.action.kind == ActionKind.popup
                    && item.button.action.popupItems.length >= 2) {
                return item.button.action.popupItems;
            }
        }
    return null;
}

unittest { // C1: the production binder builds both roles over non-empty floors
    auto h = new ActionMenuHarness;
    auto roles = h.bind();
    PopupItem[] popupRows = [
        PopupItem(PopupItemKind.header, "Header"),
        PopupItem(PopupItemKind.divider),
        PopupItem(PopupItemKind.action, "Action")
    ];
    assert(__traits(compiles, roles.read.refusal(commandAction("probe.command")))
        && __traits(compiles, roles.actions.activateTool("probe.tool")),
        "6560 role floor: the production binder did not construct both roles");
    assert(h.history.undoEntries().length == 0,
        "6560 binder floor: construction must not write history");
    assert(popupRows.length == 3,
        "6560 popup fixture floor: expected three distinct row kinds");
}

private Button penButton() {
    Button b;
    b.label  = "Pen";
    b.action = Action(ActionKind.tool, "pen");
    b.ctrl.present = true;
    b.ctrl.label   = "Topology Pen";
    b.ctrl.action  = Action(ActionKind.tool, "mesh.topoPen");
    return b;
}

unittest { // C2a: the six relocated variant cells
    string label;
    Action action;
    string variant;
    auto btn = penButton();

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
    assert(action.id == "mesh.topoPen" && label == "Topology Pen" && variant == "_ctrl");

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    selectButtonVariant(btn, KMOD_NONE, "mesh.topoPen", label, action, variant);
    assert(action.id == "mesh.topoPen", "released modifier must not drop an active variant tool");
    assert(label == "Topology Pen", "an active variant must keep its own label");

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    selectButtonVariant(btn, KMOD_NONE, "pen", label, action, variant);
    assert(action.id == "pen" && label == "Pen" && variant == "");

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    selectButtonVariant(btn, KMOD_NONE, "", label, action, variant);
    assert(action.id == "pen" && variant == "");

    assert(btn.ctrl.present, "6560 variant floor: the ctrl fixture is absent");
    version (OSX) {
        selectButtonVariant(btn, KMOD_GUI, "", label, action, variant);
        assert(action.id == "mesh.topoPen", "macOS: Cmd must reach a ctrl: variant");
        selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
        assert(action.id == "pen" && label == "Pen", "macOS: Control must not preview a variant it cannot click");
    } else {
        selectButtonVariant(btn, KMOD_GUI, "", label, action, variant);
        assert(action.id == "pen", "non-macOS: Super/Cmd must NOT alias Ctrl");
        selectButtonVariant(btn, KMOD_CTRL, "", label, action, variant);
        assert(action.id == "mesh.topoPen", "non-macOS: Control selects the ctrl: variant");
    }

    Button cmdBtn;
    cmdBtn.label  = "Arc";
    cmdBtn.action = Action(ActionKind.tool, "prim.arc");
    cmdBtn.ctrl.present = true;
    cmdBtn.ctrl.label   = "Unit Arc";
    cmdBtn.ctrl.action  = Action(ActionKind.command, "prim.arc.unit");
    assert(cmdBtn.ctrl.present, "6560 variant floor: the command ctrl fixture is absent");
    selectButtonVariant(cmdBtn, KMOD_NONE, "prim.arc", label, action, variant);
    assert(action.id == "prim.arc" && variant == "", "a command variant must not claim the button");
}

unittest { // C2b: simultaneous held modifiers keep Ctrl above Alt
    string label;
    Action action;
    string variant;
    auto btn = penButton();
    btn.alt.present = true;
    btn.alt.label = "Alt Pen";
    btn.alt.action = Action(ActionKind.tool, "mesh.altPen");
    assert(btn.ctrl.present && btn.alt.present,
        "6560 modifier-priority floor: both variants must exist");
    version (OSX) enum testCtrl = KMOD_GUI;
    else          enum testCtrl = KMOD_CTRL;
    selectButtonVariant(btn, cast(SDL_Keymod)(testCtrl | KMOD_ALT), "",
                        label, action, variant);
    assert(variant == "_ctrl",
        "6560 modifier priority: ctrl must win over a simultaneously held alt");
}

unittest { // C2c: active variant claims retain Ctrl-before-Alt ordering
    string label;
    Action action;
    string variant;
    auto btn = penButton();
    btn.ctrl.action = Action(ActionKind.tool, "mesh.sharedPen");
    btn.alt.present = true;
    btn.alt.label = "Alt Shared Pen";
    btn.alt.action = Action(ActionKind.tool, "mesh.sharedPen");
    immutable activeToolId = "mesh.sharedPen";
    assert(btn.ctrl.present && btn.alt.present && activeToolId.length > 0,
        "6560 active-variant floor: both variants and an active id must exist");
    selectButtonVariant(btn, KMOD_NONE, activeToolId, label, action, variant);
    assert(label == btn.ctrl.label,
        "6560 active variant priority: ctrl must claim before alt when both name the active tool");
}

unittest { // C3: a modifier popup id remains addressable after modifier release
    const savedTestMode = g_testMode;
    g_testMode = true;
    scope (exit) g_testMode = savedTestMode;
    auto h = new ActionMenuHarness;
    auto roles = h.bind();
    Button btn;
    btn.label = "Variant host";
    btn.action = commandAction("probe.command");
    btn.alt.present = true;
    btn.alt.label = "Variant popup";
    btn.alt.action.kind = ActionKind.popup;
    foreach (i; 0 .. 2) {
        PopupItem row;
        row.kind = PopupItemKind.action;
        row.label = "Popup row" ~ cast(char)('A' + i);
        row.action = commandAction("probe.command");
        btn.alt.action.popupItems ~= row;
    }
    assert(btn.alt.action.popupItems.length >= 2,
        "6560 popup-id floor: the alternate popup needs two submitted rows");
    assert(popupWidgetId(btn.label, "") != popupWidgetId(btn.label, "_alt"),
        "6560 popup ids: primary and alternate popup ids must stay distinct");
    bool opened;
    auto ui = openPanel(() {
        beginButtonAvailabilityFrame(true, "", 0);
        scope (exit) endButtonAvailabilityFrame();
        if (!opened) {
            ImGui.OpenPopup(popupWidgetId(btn.label, "_alt"));
            opened = true;
        }
        renderButtonPopups(btn, roles.read, roles.actions);
    }, "action menu modifier host");
    scope (exit) ui.close();
    ui.frame();
    auto rows = parseJSON(buttonAvailabilityJson())["items"].array;
    assert(rows.length > 0,
        "6560 instrument floor: the drawn-button record is empty — g_testMode or the availability bracket was not raised");
    size_t publishedPopupRows;
    foreach (row; rows)
        if (row["source"].str == "popup") ++publishedPopupRows;
    assert(publishedPopupRows >= 2,
        "6560 popup id: releasing Alt must not orphan the alternate popup rows");
}

unittest { // C4: real YAML popup rows publish enabled and refused availability
    const savedTestMode = g_testMode;
    g_testMode = true;
    scope (exit) g_testMode = savedTestMode;
    auto h = new ActionMenuHarness;
    PopupItem[] rows = firstRealPopup();
    assert(rows.length >= 2,
        "6560 real-popup floor: config/buttons.yaml yielded fewer than two rows");
    string refusedId;
    foreach (ref row; rows)
        if (row.kind == PopupItemKind.action
            && row.action.kind == ActionKind.command) {
            refusedId = row.action.id;
            break;
        }
    assert(refusedId.length > 0,
        "6560 real-popup floor: no command row can carry a refusal");
    immutable refusalSentence = "blocked by the action-menu registry probe";
    auto roles = bindActionMenu(
        (ref const Action action) => action.id == refusedId
            ? refusalSentence : "",
        (string id, string paramsJson) {}, (string id) {},
        (string id) => false);
    auto ui = openPanel(() {
        beginButtonAvailabilityFrame(true, "", 0);
        scope (exit) endButtonAvailabilityFrame();
        renderPopupItems(roles.read, roles.actions, rows);
    }, "action menu availability host");
    scope (exit) ui.close();
    ui.frame();
    auto recorded = parseJSON(buttonAvailabilityJson())["items"].array;
    assert(recorded.length > 0,
        "6560 instrument floor: the drawn-button record is empty — g_testMode or the availability bracket was not raised");
    size_t disabled, enabled;
    bool reasonSeen;
    foreach (row; recorded) {
        if (row["source"].str != "popup") continue;
        if (row["disabled"].boolean) {
            ++disabled;
            if (row["reason"].str == refusalSentence) reasonSeen = true;
        } else {
            ++enabled;
        }
    }
    assert(disabled >= 1 && enabled >= 1,
        "6560 popup availability: the real table must publish both disabled and enabled rows");
    assert(reasonSeen,
        "6560 popup availability: the refused row lost the registry sentence");
}

unittest { // C5: script arguments travel through the UI binding into history
    auto h = new ActionMenuHarness;
    auto roles = h.bind();
    h.clear();
    auto action = scriptAction(["probe.script amount:2.5"]);
    assert(h.history.undoEntries().length == 0,
        "6560 script dispatch floor: history was not empty before dispatch");
    dispatchAction(roles.actions, action);
    assert(h.state.applies == 1 && h.state.lastAmount == 2.5f,
        "6560 script dispatch: parsed arguments did not reach the registered command");
    assert(h.history.undoEntries().length == 1,
        "6560 script dispatch: a script line with arguments must run through the UI command binding and record one history entry");
}

unittest { // C5b: the command branch also enters through the UI binding
    auto h = new ActionMenuHarness;
    auto roles = h.bind();
    h.clear();
    auto action = commandAction("probe.command");
    assert(h.history.undoEntries().length == 0,
        "6560 command-row floor: history was not empty before dispatch");
    dispatchAction(roles.actions, action);
    assert(h.openArgsCount == 1,
        "6560 command row: the args-dialog policy must be asked exactly once");
    assert(h.history.undoEntries().length == 1,
        "6560 command row: a registered non-refusing command must record exactly one history entry through the UI door");
}

unittest { // C6: blank and comment script lines do not manufacture commands
    auto h = new ActionMenuHarness;
    auto roles = h.bind();
    h.clear();
    auto action = scriptAction(["probe.script amount:3.5", "", "# skipped"]);
    assert(action.scriptLines.length == 3,
        "6560 empty-line floor: the fixture must contain command, blank, and comment lines");
    dispatchAction(roles.actions, action);
    assert(h.state.applies == 1 && h.state.lastAmount == 3.5f,
        "6560 script empty lines: only the non-empty command may apply");
    assert(h.history.undoEntries().length == 1,
        "6560 script empty lines: blank and comment lines must not create history entries");
}

unittest { // C7: ordinary UI refusal reports through the guard notice port
    auto h = new ActionMenuHarness;
    auto roles = h.bind();
    h.clear();
    auto action = commandAction("probe.refuse");
    assert(h.guardNoticeCount == 0,
        "6560 UI-refusal floor: the guard notice port was already dirty");
    bool threw;
    try {
        dispatchAction(roles.actions, action);
    } catch (Exception) {
        threw = true;
    }
    assert(!threw,
        "6560 UI refusal: an ordinary command refusal must notify, not throw");
    assert(h.guardNoticeCount == 1 && h.lastGuardNotice == "probe.refuse",
        "6560 UI refusal: the guarded-action notice port must record the refused command exactly once");
    assert(h.history.undoEntries().length == 0,
        "6560 UI refusal: a refused command must not change history");
    // Script-origin HTTP refusal is intentionally a different contract: its
    // CommandHttpAdapter door throws, while this UI door records a notice.
}

unittest { // C8: parameterized command rows stop at the args dialog
    auto h = new ActionMenuHarness;
    auto roles = h.bind(true);
    h.clear();
    auto action = commandAction("probe.args");
    immutable before = h.dispatchCount;
    assert(h.dispatchCount == before,
        "6560 args-dialog floor: dispatch count changed before the row ran");
    dispatchAction(roles.actions, action);
    assert(h.openArgsCount == 1 && h.dispatchCount == before,
        "6560 args dialog: a command row with parameters must open the dialog instead of dispatching with empty arguments");
    assert(h.history.undoEntries().length == 0,
        "6560 args dialog: opening the dialog must not write history");
}

unittest { // C9/C10: the real stack renders three rows and removes one extra
    const savedTestMode = g_testMode;
    g_testMode = true;
    scope (exit) g_testMode = savedTestMode;
    auto savedPipe = g_pipeCtx;
    scope (exit) g_pipeCtx = savedPipe;
    auto context = new ToolPipeContext;
    auto primary = new FalloffStage(null, null, "falloff");
    primary.type = FalloffType.Linear;
    auto extra1 = new FalloffStage(null, null, "falloff#1");
    extra1.type = FalloffType.Radial;
    auto extra2 = new FalloffStage(null, null, "falloff#2");
    extra2.type = FalloffType.None;
    context.pipeline.add(primary);
    context.pipeline.addStacked(extra1);
    context.pipeline.addStacked(extra2);
    g_pipeCtx = context;
    assert(context.pipeline.findAllByTask(TaskCode.Wght).length == 3,
        "6560 falloff popup floor: the real pipeline must contain primary plus two extras");
    auto roles = bindActionMenu(
        (ref const Action) => "",
        (string id, string paramsJson) {
            if (id != "falloff.remove") return;
            import std.json : parseJSON;
            const target = parseJSON(paramsJson)["id"].str;
            auto stage = context.pipeline.findById(target);
            if (stage !is null) context.pipeline.removeStage(stage);
        },
        (string) {}, (string) => false);
    auto ui = openPanel(
        () { renderFalloffStackItems(roles.actions); },
        "action menu falloff host");
    scope (exit) ui.close();
    ui.frame();
    assert(ui.anyItemHoveredAt(ui.rowPoint(0)),
        "6560 falloff instrument: row 0 was not hover-addressable");
    assert(ui.anyItemHoveredAt(ui.rowPoint(1)),
        "6560 falloff instrument: row 1 was not hover-addressable");
    assert(ui.anyItemHoveredAt(ui.rowPoint(2)),
        "6560 falloff instrument: row 2 was not hover-addressable");
    assert(!ui.anyItemHoveredAt(ui.rowPoint(3)),
        "6560 falloff instrument: a nonexistent fourth row was hover-addressable");
    immutable before = context.pipeline.findAllByTask(TaskCode.Wght).length;
    assert(before == 3,
        "6560 falloff click floor: the stack changed before the gesture");
    ui.pressRow(1);
    ui.release();
    ui.frame();
    assert(context.pipeline.findById("falloff#1") is null,
        "6560 falloff click: the second popup row must remove falloff#1");
    assert(context.pipeline.findById("falloff") is primary,
        "6560 falloff click: removing a stacked extra must retain primary falloff");
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6560 census missing source marker " ~ marker);
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6560 census found no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "6560 census found unterminated body after " ~ marker);
    return null;
}

private bool identifierChar(char ch) {
    return ch == '_' || (ch >= '0' && ch <= '9')
        || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
}

private size_t identifierCount(string code, string identifier) {
    size_t total;
    size_t from;
    while (from < code.length) {
        const hit = code.indexOf(identifier, from);
        if (hit < 0) break;
        const pos = cast(size_t)hit;
        const left = pos == 0 || !identifierChar(code[pos - 1]);
        const end = pos + identifier.length;
        const right = end == code.length || !identifierChar(code[end]);
        if (left && right) ++total;
        from = end;
    }
    return total;
}

private string collapseWhitespace(string source) {
    string result;
    bool spacing;
    foreach (ch; source) {
        const whitespace = ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
        if (whitespace) {
            spacing = result.length > 0;
            continue;
        }
        if (spacing) result ~= ' ';
        result ~= ch;
        spacing = false;
    }
    return result;
}

unittest { // C11: status bar owns one role dispatch and one tool drop
    import tests.unit.census_symbols : blankNonCode;

    const panels = blankNonCode(readText(
        repoRoot.buildPath("source", "ui", "panels.d")));
    const body = bodyAt(panels,
        "void drawStatusBar(EditorApp app, ActionMenuRoles menu)");
    assert(body.length > 4_000,
        "6560 status census floor: drawStatusBar body is unexpectedly small");
    assert(body.count("dispatchAction(menu.actions, action)") == 1,
        "6560 status dispatch: drawStatusBar must use the shared action door exactly once");
    assert(body.count("dropActiveTool(ToolTransition.panelDrop)") == 1,
        "6560 status drop: edit-mode actions must retain one post-dispatch tool drop");
    assert(body.count("tryOpenArgsDialog") == 0
        && body.count("uiCommandDelegate") == 0
        && body.count("activateToolById") == 0,
        "6560 status boundary: drawStatusBar regained an application action door");
}

unittest { // C12: side panel consumes the shared dispatch and popup renderer
    import tests.unit.census_symbols : blankNonCode;

    const panels = blankNonCode(readText(
        repoRoot.buildPath("source", "ui", "panels.d")));
    const body = bodyAt(panels,
        "void drawSidePanel(EditorApp app, ActionMenuRoles menu)");
    assert(body.length > 3_000,
        "6560 side census floor: drawSidePanel body is unexpectedly small");
    assert(body.count("dispatchAction(menu.actions, action)") == 1,
        "6560 side dispatch: drawSidePanel must use the shared action door exactly once");
    assert(body.count(
            "renderButtonPopups(btn, menu.read, menu.actions)") == 1,
        "6560 side popup: drawSidePanel must submit the shared popup renderer exactly once");
    assert(body.count("renderVariantPopup") == 0,
        "6560 side boundary: the old nested popup renderer returned");
}
