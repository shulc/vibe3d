module tests.unit.ui.layer_list_panel_roles_test;

import std.algorithm : canFind, count;
import std.file : SpanMode, dirEntries, readText;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;

import bindbc.sdl : KMOD_NONE, KMOD_SHIFT, SDL_SetModState, loadSDL,
    sdlSupport;
import application_command_binding : ApplicationCommandBinding;
import command : Command;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.layer.commands : LayerAttr, LayerRename, LayerSelect,
    LayerSetVisible;
import document : Document, Layer;
import edit_session : EditSession;
import forms : Form, formById, g_forms, g_formsPanelEnabled, loadForms;
import forms_render : FormsPanel;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import mesh : makeCube;
import registry : Registry;
import seltype : SelType, currentSelType;
import session_owner : Session;
import tests.unit.ui.headless_panel : HeadlessPanel, KEY_LEFT_CTRL, MOD_CTRL,
    openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import tools.transform.xfrm_transform : XfrmTransformTool;
import ui.discard_guard : GuardRecord;
import ui.item_rename : ItemRenameState, bindItemRenameController;
import ui.item_rows : RowRole;
import ui.layer_list_panel : LayerListDrawSnapshot, LayerListDrawnRow,
    LayerListPanelRoles, bindLayerListPanel, drawLayerListPanel,
    layerListDrawSnapshot, resetLayerListDrawSnapshot;
import view : View;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiKey, ImVec2;

static assert(__traits(compiles, {
    LayerListPanelRoles roles = void;
    auto dispatch = roles.actions.commandDispatch();
}), "6030 action capability: external callers must be able to read dispatch");
static assert(!__traits(compiles, {
    LayerListPanelRoles roles = void;
    roles.actions.dispatch = (string id, string paramsJson) {};
}), "6030 action capability: external callers must not replace dispatch");

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..");

private Layer makeMeshLayer(string name) {
    auto layer = new Layer;
    layer.name = name;
    layer.meshRef() = makeCube();
    return layer;
}

private Document namedDocument(string[] names) {
    assert(names.length > 0);
    Document document = Document.bootstrap(makeCube());
    document.layers[0].name = names[0];
    foreach (name; names[1 .. $])
        document.layers ~= makeMeshLayer(name);
    document.setActive(0);
    return document;
}

private final class LayerPanelHarness {
    Session* owner;
    View view;
    Registry registry;
    CommandHistory history;
    CommandExecutor executor;
    EditSession editSession;
    GuardRecord[] records;
    GuardedActionController guard;
    ApplicationCommandBinding binding;
    FormsPanel forms;
    Tool activeTool;
    ItemRenameState renameState;
    LayerListPanelRoles roles;

    this() {
        owner = Session.create(namedDocument(["Alpha", "Beta", "Gamma"]));
        assert(owner.document.layers.length == 3
            && owner.document.layers[0].name == "Alpha"
            && owner.document.layers[1].name == "Beta"
            && owner.document.layers[2].name == "Gamma",
            "6030 fixture floor needs Alpha/Beta/Gamma before binding");
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
            (Command) {},
            GuardObservationPorts(
                (record) { records ~= record; },
                (answer, performed) {},
                (pending) {})));
        binding = new ApplicationCommandBinding(
            registry, executor, editSession, history, guard,
            (Command) {}, (string) {});

        registry.commandFactories["layer.select"] = () => cast(Command)
            new LayerSelect(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null);
        registry.commandFactories["layer.setVisible"] = () => cast(Command)
            new LayerSetVisible(owner.document.activeMesh(), view,
                owner.editMode, owner.documentPtr(), null);
        registry.commandFactories["layer.rename"] = () => cast(Command)
            new LayerRename(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null);
        registry.commandFactories["layer.attr"] = () => cast(Command)
            new LayerAttr(owner.document.activeMesh(), view, owner.editMode,
                          owner.documentPtr(), null);

        forms = new FormsPanel;
        // Production binds once after its document and command binding exist.
        // Keep Alpha/Beta/Gamma alive before this line so M1 reaches its named
        // stale-document witness rather than failing a fixture population floor.
        roles = bindLayerListPanel(owner, binding, forms, () => activeTool);
    }

    HeadlessPanel open() {
        resetLayerListDrawSnapshot();
        return openPanel(() {
            ImGui.SetNextWindowSize(ImVec2(520, 900));
            drawLayerListPanel(roles.read, roles.actions, renameState);
        }, "Layers host", 1280, 1000);
    }
}

private void installEnvironment(ref Form[] previousForms) {
    previousForms = g_forms;
    g_forms = loadForms(repoRoot.buildPath("config", "forms",
                                           "layer_props.yaml"));
    assert(g_formsPanelEnabled && formById("layer.props") !is null,
        "6030 forms population: layer.props must be loaded and enabled");
    assert(loadSDL() == sdlSupport,
        "6030 SDL population: the dynamic SDL binding did not load");
    SDL_SetModState(KMOD_NONE);
}

private ImVec2 center(ImVec2 lo, ImVec2 hi) {
    assert(hi.x > lo.x && hi.y > lo.y,
        "6030 widget rectangle is empty");
    return ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
}

private LayerListDrawnRow rowNamed(LayerListDrawSnapshot snapshot,
                                   string name) {
    assert(snapshot.rows.length > 0,
        "6030 row population: the panel recorded no rows");
    foreach (row; snapshot.rows)
        if (row.name == name) return row;
    assert(false, "6030 row population: missing row " ~ name);
    return LayerListDrawnRow.init;
}

private void assertHistoryHeadroom(LayerPanelHarness app) {
    app.history.clear();
    app.records.length = 0;
    assert(app.history.undoEntries().length == 0 && app.records.length == 0,
        "6030 history floor must start from an empty stack and record list");
}

unittest { // M1: the once-bound role reads the document replaced in place
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    auto snapshot = layerListDrawSnapshot();
    assert(snapshot.rows.length == 4
        && snapshot.rows[1].name == "Alpha"
        && snapshot.rows[2].name == "Beta"
        && snapshot.rows[3].name == "Gamma"
        && snapshot.rows[1].role == RowRole.SelectedFirst
        && snapshot.rows[2].role == RowRole.None
        && snapshot.rows[3].role == RowRole.None,
        "6030 live-document floor needs distinct Alpha/Beta/Gamma rows");

    *app.owner.documentPtr() = namedDocument(["Delta", "Epsilon"]);
    ui.frame();
    snapshot = layerListDrawSnapshot();
    assert(snapshot.rows.length == 3
        && snapshot.rows[1].name == "Delta"
        && snapshot.rows[2].name == "Epsilon",
        "6030 live-document witness: rows still show the document captured at bind");
}

unittest { // selection modifiers, short circuit and visibility keep UI dispatch
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    assertHistoryHeadroom(app);
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();

    auto beta = rowNamed(layerListDrawSnapshot(), "Beta");
    ui.pressAt(center(beta.nameMin, beta.nameMax));
    ui.release();
    ui.frame(); // release-frame rows precede the dispatch; observe the next draw
    auto snapshot = layerListDrawSnapshot();
    assert(app.owner.document.layers[1].selected
        && !app.owner.document.layers[0].selected
        && rowNamed(snapshot, "Beta").role == RowRole.SelectedFirst,
        "6030 plain selection did not make Beta the sole first row");
    assert(app.history.undoEntries().length == 1
        && app.history.undoEntries()[$ - 1].commandName == "layer.select"
        && app.history.undoEntries()[$ - 1].args == "index:1"
        && app.records.length == 1
        && app.records[$ - 1].id == "layer.select"
        && app.records[$ - 1].outcome == "applied",
        "6030 plain selection lost its command/history/guard identity: args="
        ~ (app.history.undoEntries().length
            ? app.history.undoEntries()[$ - 1].args : "<none>"));

    auto alpha = rowNamed(snapshot, "Alpha");
    ui.keyDown(KEY_LEFT_CTRL);
    ui.keyDown(MOD_CTRL);
    ui.frame();
    alpha = rowNamed(layerListDrawSnapshot(), "Alpha");
    ui.pressAt(center(alpha.roleMin, alpha.roleMax));
    ui.release();
    ui.keyUp(KEY_LEFT_CTRL);
    ui.keyUp(MOD_CTRL);
    ui.frame();
    snapshot = layerListDrawSnapshot();
    assert(app.owner.document.layers[0].selected
        && app.owner.document.layers[1].selected
        && rowNamed(snapshot, "Beta").role == RowRole.SelectedFirst
        && rowNamed(snapshot, "Alpha").role == RowRole.Selected,
        "6030 Ctrl role-cell selection did not toggle Alpha beside Beta");
    assert(app.history.undoEntries().length == 2
        && app.history.undoEntries()[$ - 1].args == "mode:toggle",
        "6030 Ctrl role-cell did not retain mode:toggle command args");

    SDL_SetModState(KMOD_SHIFT);
    auto gamma = rowNamed(snapshot, "Gamma");
    ui.pressAt(center(gamma.nameMin, gamma.nameMax));
    ui.release();
    SDL_SetModState(KMOD_NONE);
    ui.frame();
    snapshot = layerListDrawSnapshot();
    assert(!app.owner.document.layers[0].selected
        && app.owner.document.layers[1].selected
        && app.owner.document.layers[2].selected
        && rowNamed(snapshot, "Beta").role == RowRole.SelectedFirst
        && rowNamed(snapshot, "Gamma").role == RowRole.Selected,
        "6030 Shift range must replace with the contiguous Beta/Gamma span");
    assert(app.history.undoEntries().length == 3
        && app.history.undoEntries()[$ - 1].args == "index:2 mode:range",
        "6030 Shift name-cell did not retain mode:range command args");

    app.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    ui.frame();
    const historyBeforeNoop = app.history.undoEntries().length;
    const recordsBeforeNoop = app.records.length;
    beta = rowNamed(layerListDrawSnapshot(), "Beta");
    ui.pressAt(center(beta.roleMin, beta.roleMax));
    ui.release();
    assert(app.history.undoEntries().length == historyBeforeNoop
        && app.records.length == recordsBeforeNoop,
        "6030 sole-row click must short-circuit before UI dispatch");

    ui.frame();
    beta = rowNamed(layerListDrawSnapshot(), "Beta");
    ui.pressAt(center(beta.eyeMin, beta.eyeMax));
    ui.release();
    assert(!app.owner.document.layers[1].visible
        && app.history.undoEntries().length == historyBeforeNoop + 1
        && app.history.undoEntries()[$ - 1].commandName == "layer.setVisible"
        && app.records.length == recordsBeforeNoop + 1,
        "6030 eye cell lost layer.setVisible UI dispatch");
}

unittest { // rename edits exactly the selected item through the bound action
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    assertHistoryHeadroom(app);
    app.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    app.history.clear();
    app.records.length = 0;
    auto rename = bindItemRenameController(app.renameState,
        app.roles.actions.commandDispatch());
    rename.begin(1, "Beta");
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    ui.frame();
    ui.typeText("Z");
    ui.keyDown(cast(int) ImGuiKey.Enter);
    ui.frame();
    ui.keyUp(cast(int) ImGuiKey.Enter);
    ui.frame();
    ui.frame();
    ui.frame();
    assert(app.owner.document.layers[1].name == "Z"
        && app.owner.document.layers[0].name == "Alpha"
        && app.owner.document.layers[2].name == "Gamma",
        "6030 rename must edit Beta and no other item: got `"
        ~ app.owner.document.layers[1].name ~ "`, buffer `"
        ~ app.renameState.text ~ "`");
    assert(app.history.undoEntries().length == 1
        && app.history.undoEntries()[0].commandName == "layer.rename"
        && app.records.length == 1
        && app.records[0].id == "layer.rename"
        && app.records[0].outcome == "applied"
        && app.renameState.index == -1,
        "6030 rename lost its one UI history/guard record or stayed active");
}

unittest { // M2: interactive form writes through guarded UI binding
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    app.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    assertHistoryHeadroom(app);
    app.activeTool = null;
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    auto snapshot = layerListDrawSnapshot();
    assert(snapshot.formDrawn && snapshot.formTarget == 1
        && snapshot.formWidth > 20 && snapshot.formRowH > 0,
        "6030 form population: Beta's first form row was not recorded");
    const alpha = app.owner.document.layers[0].name;
    const beta = app.owner.document.layers[1].name;
    const gamma = app.owner.document.layers[2].name;
    ui.pressAt(ImVec2(snapshot.formOrigin.x + 0.75f * snapshot.formWidth,
                      snapshot.formOrigin.y + 0.5f * snapshot.formRowH));
    ui.release();
    ui.typeText("Q");
    assert(app.owner.document.layers[1].name != beta
        && app.owner.document.layers[0].name == alpha
        && app.owner.document.layers[2].name == gamma,
        "6030 interactive form write did not change Beta alone");
    assert(app.history.undoEntries().length == 1
        && app.history.undoEntries()[0].commandName == "layer.attr",
        "6030 interactive form write did not create one layer.attr history entry");
    assert(app.records.length == 1
        && app.records[0].id == "layer.attr"
        && app.records[0].outcome == "applied",
        "6030 interactive form write bypassed the guarded UI binding");
}

unittest { // M3: transform guard reads both live tool and live selection type
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    app.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    auto xfrm = new XfrmTransformTool(
        () => app.owner.document.activeMesh(), null, app.owner.editModePtr(),
        () => currentSelType(app.owner.selTypeOrder), null);
    app.activeTool = xfrm;
    assert(app.roles.read.currentSelType() != SelType.Item,
        "6030 transform-guard floor needs a geometry selection type");
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    auto snapshot = layerListDrawSnapshot();
    assert(snapshot.formDrawn && snapshot.transformGuardArmed,
        "6030 transform guard did not arm for a live transform tool in geometry mode");

    app.owner.selTypeOrder.touch(SelType.Item);
    ui.frame();
    snapshot = layerListDrawSnapshot();
    assert(snapshot.formDrawn && !snapshot.transformGuardArmed,
        "6030 transform guard stayed armed in item mode");

    app.owner.selTypeOrder.touch(SelType.Vertex);
    app.activeTool = null;
    ui.frame();
    snapshot = layerListDrawSnapshot();
    assert(snapshot.formDrawn && !snapshot.transformGuardArmed,
        "6030 transform guard armed without a transform tool");
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6030 census missing source marker " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6030 census found no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "6030 census found unterminated body after " ~ marker);
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
        const pos = cast(size_t) hit;
        const left = pos == 0 || !identifierChar(code[pos - 1]);
        const end = pos + identifier.length;
        const right = end == code.length || !identifierChar(code[end]);
        if (left && right) ++total;
        from = end;
    }
    return total;
}

private string collapseWhitespace(string text) {
    string result;
    bool spacing;
    foreach (ch; text) {
        const ws = ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t';
        if (ws) { spacing = result.length > 0; continue; }
        if (spacing) result ~= ' ';
        result ~= ch;
        spacing = false;
    }
    return result;
}

unittest { // production binder, call sites and the retired EditorApp path
    import tests.unit.census_symbols : blankNonCode;

    const rawApp = readText(repoRoot.buildPath("source", "app.d"));
    const rawLayer = readText(repoRoot.buildPath(
        "source", "ui", "layer_list_panel.d"));
    const app = blankNonCode(rawApp);
    const layer = blankNonCode(rawLayer);
    const panels = blankNonCode(readText(repoRoot.buildPath(
        "source", "ui", "panels.d")));
    assert(rawLayer.length > 5_000,
        "6030 source population: layer-list panel source is unexpectedly small");
    assert(layer.count("EditorApp") == 0 && layer.count("editor_app") == 0
        && layer.count("ui.panels") == 0 && layer.count("with (") == 0,
        "6030 role boundary: layer-list panel regained EditorApp/panels coupling");
    assert(layer.count(
        "void drawLayerListPanel(LayerListReadRole read, LayerListActions actions,") == 1,
        "6030 panel signature: the role-based draw entry is not unique");

    const binder = bodyAt(layer,
        "LayerListPanelRoles bindLayerListPanel(Session* owner,");
    assert(identifierCount(binder, "binding") == 3
        && binder.count("&binding.dispatchUi") == 1
        && binder.count("&binding.dispatchInteractiveUi") == 1,
        "6030 binder census: Layers must bind exactly the UI and interactive UI methods directly");
    const actions = bodyAt(layer, "struct LayerListActions");
    assert(actions.count("ItemRenameDispatch dispatch;") == 1
        && actions.count("ItemRenameDispatch commandDispatch()") == 1
        && actions.count("return dispatch;") == 1,
        "6030 action census: dispatch storage/accessor shape changed");
    assert(panels.count("void drawLayerListPanel(") == 0,
        "6030 retired panel path: ui.panels still defines drawLayerListPanel");

    size_t sourceFiles;
    size_t oldSignatures;
    foreach (entry; dirEntries(repoRoot.buildPath("source"), "*.d",
                               SpanMode.depth)) {
        ++sourceFiles;
        oldSignatures += blankNonCode(readText(entry.name))
            .count("drawLayerListPanel(EditorApp");
    }
    assert(sourceFiles > 500 && oldSignatures == 0,
        "6030 source census: the EditorApp layer-list overload survived");

    const flatApp = collapseWhitespace(app);
    enum bindCall = "bindLayerListPanel(sessionOwner, commandBinding, formsPanel, toolHost.getActiveTool)";
    assert(app.count("bindLayerListPanel(") == 1
        && app.count("auto layerListRoles =") == 1
        && flatApp.count(bindCall) == 1,
        "6030 production binder: Layers must bind commandBinding and the live production tool getter exactly once");
    const commandBindingAt = flatApp.indexOf(
        "commandBinding = new ApplicationCommandBinding(");
    const bindAt = flatApp.indexOf(bindCall);
    const loopAt = flatApp.indexOf("while (running) {");
    enum drawCall =
        "drawLayerListPanel(layerListRoles.read, layerListRoles.actions, itemRenameState);";
    const drawAt = flatApp.indexOf(drawCall);
    assert(commandBindingAt >= 0 && bindAt >= 0 && loopAt >= 0 && drawAt >= 0
        && commandBindingAt < bindAt && bindAt < loopAt && loopAt < drawAt
        && flatApp.count(drawCall) == 1,
        "6030 production placement: binder/draw no longer bracket the frame loop");
    assert(app.count("toolHost.getActiveTool   = () => activeTool;") == 1,
        "6030 production tool getter lost its live activeTool closure");

    enum uiClosure =
        "uiCommandDelegate = (string id, string paramsJson) {\n"
        ~ "        commandBinding.dispatchUi(id, paramsJson);\n    };";
    enum interactiveClosure =
        "formsInteractiveDispatch = (string id, string paramsJson) {\n"
        ~ "        commandBinding.dispatchInteractiveUi(id, paramsJson);\n    };";
    assert(rawApp.count(uiClosure) == 1,
        "6030 early-binding equivalence: Layers binds commandBinding directly, so wrapping uiCommandDelegate would skip Layers");
    assert(rawApp.count(interactiveClosure) == 1,
        "6030 early-binding equivalence: Layers binds commandBinding directly, so wrapping formsInteractiveDispatch would skip Layers");

    const chromePush = rawLayer.indexOf("pushPanelChromeStyle();");
    const chromePop = rawLayer.indexOf("scope(exit) popPanelChromeStyle();");
    const endAt = rawLayer.indexOf("scope(exit) ImGui.End();");
    const beginAt = rawLayer.indexOf("if (ImGui.Begin(\"Items###Layers\")) {");
    assert(chromePush >= 0 && chromePush < chromePop && chromePop < endAt
        && endAt < beginAt
        && rawLayer.count("pushPanelChromeStyle();") == 1
        && rawLayer.count("scope(exit) popPanelChromeStyle();") == 1
        && rawLayer.count("scope(exit) ImGui.End();") == 1
        && rawLayer.count("if (ImGui.Begin(\"Items###Layers\")) {") == 1,
        "6030 panel chrome: extraction changed Begin/End/style ordering");
    foreach (needle; ["\"##vis\"", "\"##role\"", "\"##additem_open\"",
                      "\"VIBE3D_LAYER_ROW\""])
        assert(rawLayer.count(needle) >= 1,
            "6030 panel IDs: extraction lost " ~ needle);
    assert(rawLayer.count("publishPanelZone(\"layerList\")") == 1
        && rawApp.count("DockBuilderDockWindow(\"Layers\"") == 3,
        "6030 dock/input contract: Layers zone or dock IDs changed");
}
