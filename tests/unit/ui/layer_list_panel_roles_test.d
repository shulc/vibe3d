module tests.unit.ui.layer_list_panel_roles_test;

import std.algorithm : canFind, count, sort;
import core.exception : AssertError;
import std.conv : to;
import std.exception : assertThrown;
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
import commands.image_plane.commands : ImagePlaneAdd;
import document : Document, ItemKind, Layer, kindInfo;
import edit_session : EditSession;
import editmode : EditMode;
import forms : Form, formById, g_forms, g_formsPanelEnabled, loadForms;
import forms_render : FormsPanel;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import layer_params : itemPropsTarget;
import mesh : makeCube;
import registry : Registry;
import seltype : SelType, currentSelType;
import session_owner : Session;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.ui.headless_panel : HeadlessPanel, KEY_LEFT_CTRL, MOD_CTRL,
    openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import tools.transform.xfrm_transform : XfrmTransformTool;
import ui.discard_guard : GuardRecord;
import ui.item_rename : ItemRenameState, bindItemRenameController;
import ui.item_rename : ItemRenameDispatch;
import ui.item_rows : ItemRow, RowRole;
static import ui.item_rows;
import ui.layer_list_panel : LayerListDrawSnapshot, LayerListDrawnRow,
    ItemFormOutcome, LayerListActions, LayerListPanelRoles,
    LayerListPanelState, LayerListReadRole, bindLayerListPanel,
    drawLayerListPanel, layerFormBoundItem, layerFormProvider,
    layerFormGangMixed, layerListDrawSnapshot, resetLayerListDrawSnapshot;
import view : View;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiKey, ImVec2;

private template memberTypes(T) {
    private string[] collect() {
        string[] result;
        foreach (name; __traits(allMembers, T)) {
            static if (__traits(compiles, __traits(getOverloads, T, name))
                       && __traits(getOverloads, T, name).length > 0) {
                string joined;
                foreach (i, overload; __traits(getOverloads, T, name)) {
                    if (i) joined ~= " | ";
                    joined ~= typeof(overload).stringof;
                }
                result ~= name ~ ": " ~ joined;
            } else static if (__traits(compiles,
                                       typeof(__traits(getMember, T, name)))) {
                result ~= name ~ ": "
                    ~ typeof(__traits(getMember, T, name)).stringof;
            } else {
                result ~= name ~ ": <no type>";
            }
        }
        return result;
    }
    enum memberTypes = collect();
}

static assert(!__traits(compiles, (LayerListPanelRoles roles) {
        Document* document = roles.read.document();
    }),
    "6502 N1 document: the Items read role hands out a mutable Document*");
static assert(__traits(compiles, (LayerListPanelRoles roles) {
        const(Document)* document = roles.read.document();
    }),
    "6502 N1 control: the same role expression must compile through const");
static assert(!__traits(compiles, (LayerListPanelRoles roles) {
        auto document = roles.read.document();
        document.layers[0].name = "x";
    }),
    "6502 N1w document: the Items read role permits a document write");
static assert(!__traits(compiles, (ItemRow row) {
        Layer layer = row.layer;
    }),
    "6502 N2 row.layer: an item row hands out a mutable Layer");
static assert(__traits(compiles, (ItemRow row) {
        const(Layer) layer = row.layer;
    }),
    "6502 N2 control: the same row expression must compile through const");
static assert(!__traits(compiles, (ItemRow row) {
        row.layer.name = "x";
    }),
    "6502 N2w row.layer: an item row permits a document-item write");
static assert(__traits(compiles, (ItemRow row, Layer someMutableLayer) {
        row.layer = someMutableLayer;
        bool isNull = row.layer is null;
        bool isSame = row.layer is someMutableLayer;
    }),
    "6502 N2r row.layer: the row's identity slot must stay REBINDABLE — the reusable row buffer is refilled in place");

static assert(!__traits(compiles, (const(Document)* doc) {
        Layer target = itemPropsTarget(doc);
    }),
    "6502 N3 propsTarget: the focus query hands a mutable Layer out of a read-only document");
static assert(__traits(compiles, (const(Document)* doc) {
        const(Layer) target = itemPropsTarget(doc);
    }),
    "6502 N3 control: the focus query must answer a read-only document with a read-only identity");
static assert(__traits(compiles, (Document* doc) {
        Layer target = itemPropsTarget(doc);
    }),
    "6502 N3m control: a mutable caller must still receive a mutable Layer — this query is ONE definition, not a narrowing");

static assert(typeof(__traits(getMember, ui.item_rows, "rowParentOf")).stringof
        == "const(Layer)(const(Document)* doc, const(Layer) l)",
    "6502 N4 rowParentOf: the row-parent walk must take a read-only document and answer a read-only identity; if only a parameter name changed, update the expected string and report it");
static assert(typeof(__traits(getMember, ui.item_rows, "roleOf")).stringof
        == "RowRole(const(Document)* doc, const(Layer) l)",
    "6502 N5 roleOf: the row-role query must take a read-only document and identity; if only a parameter name changed, update the expected string and report it");

static assert([__traits(allMembers, LayerListReadRole)] ==
        ["owner_", "activeTool_", "__ctor", "document", "currentSelType",
         "transformToolActive"],
    "6502 F1 fence (names): the Items read role's member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!LayerListReadRole ==
        ["owner_: Session*", "activeTool_: Tool delegate()",
         "__ctor: ref LayerListReadRole() | ref LayerListReadRole(Session* owner, Tool delegate() activeTool)",
         "document: const(Document)*()", "currentSelType: SelType()",
         "transformToolActive: bool()"],
    "6502 F1 fence (types): a member of LayerListReadRole changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, LayerListActions)] ==
        ["owner_", "dispatch", "interactive_", "forms_", "state_",
         "resolveLive", "__ctor", "commandDispatch", "drawItemForm"],
    "6502 F2 fence (names): the Items action role's member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!LayerListActions ==
        ["owner_: Session*", "dispatch: void delegate(string id, string paramsJson)",
         "interactive_: void delegate(string id, string paramsJson)",
         "forms_: FormsPanel", "state_: LayerListPanelState",
         "resolveLive: Layer(Document* doc, const(Layer) id, out ulong index)",
         "__ctor: ref LayerListActions() | ref LayerListActions(Session* owner, void delegate(string id, string paramsJson) dispatch, void delegate(string id, string paramsJson) interactive, FormsPanel forms, LayerListPanelState state)",
         "commandDispatch: void delegate(string id, string paramsJson)()",
         "drawItemForm: ItemFormOutcome(ref Form form, const(Layer) target, const(Layer)[] gang, bool toolActive, SelType current)"],
    "6502 F2 fence (types): a member of LayerListActions changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, LayerListPanelRoles)] ==
        ["read", "actions", "state"],
    "6502 F3 fence (names): the Items role roster changed — a capability cannot be added or removed here without naming it");
static assert(memberTypes!LayerListPanelRoles ==
        ["read: LayerListReadRole", "actions: LayerListActions",
         "state: LayerListPanelState"],
    "6502 F3 fence (types): a member of LayerListPanelRoles changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, ItemRow)] ==
        ["index", "layer", "name", "renameSeed", "glyph", "depth",
         "role", "look", "isRoot", "visible", "canToggleVisible",
         "canRename", "dimmed", "isSoleSelection", "opAssign"],
    "6502 F4 fence (names): ItemRow's member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!ItemRow ==
        ["index: ulong", "layer: Rebindable!(const(Layer))", "name: string",
         "renameSeed: string", "glyph: ItemGlyph", "depth: int",
         "role: RowRole", "look: RowLook", "isRoot: bool", "visible: bool",
         "canToggleVisible: bool", "canRename: bool", "dimmed: bool",
         "isSoleSelection: bool",
         "opAssign: pure nothrow @nogc ref @trusted ItemRow(ItemRow p) return"],
    "6502 F4 fence (types): a member of ItemRow changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");

static assert([__traits(allMembers, LayerListPanelState)] ==
        ["props_", "gangBuf_", "__ctor", "toString", "toHash", "opCmp",
         "opEquals", "Monitor", "factory"],
    "6502 F5 fence (names): the Items binding state member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!LayerListPanelState ==
        ["props_: LayerPropsProvider", "gangBuf_: Layer[]",
         "__ctor: LayerListPanelState()", "toString: string()",
         "toHash: nothrow @trusted ulong()", "opCmp: int(Object o)",
         "opEquals: bool(Object o)", "Monitor: <no type>",
         "factory: Object(string classname)"],
    "6502 F5 fence (types): a member of LayerListPanelState changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");

static assert(LayerListReadRole.tupleof.length == 2
        && is(typeof(LayerListReadRole.tupleof[0]) == Session*),
    "6502 field roster: the Items read role must retain exactly its session and tool getter");
static assert(LayerListActions.tupleof.length == 5,
    "6502 field roster: the Items action role must retain exactly five capabilities");
static assert(LayerListPanelState.tupleof.length == 2,
    "6502 field roster: the Items binding state must retain exactly provider and gang buffer");

static assert(__traits(compiles, {
    LayerListPanelRoles roles = void;
    auto dispatch = roles.actions.commandDispatch();
}), "6030 action capability: external callers must be able to read dispatch");
static assert(!__traits(compiles, {
    LayerListPanelRoles roles = void;
    roles.actions.dispatch = (string id, string paramsJson) {};
}), "6030 action capability: external callers must not replace dispatch");

static assert(__traits(compiles, (ItemRow row) {
        auto escaped = __traits(getMember, row.layer, "stripped");
    }),
    "6502 N-remnant: private-field reflection compiles in D by construction and has no mutation witness. If this fails, first check whether the stored identity became mutable again (the real N1–N5 failures above); only if those hold did the language close the hole.");

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
    LayerListPanelRoles roles = void;
    Layer empty;
    Layer plane;

    this() {
        owner = Session.create(namedDocument(["Alpha", "Beta", "Gamma"]));
        assert(owner.document.layers.length == 3
            && owner.document.layers[0].name == "Alpha"
            && owner.document.layers[1].name == "Beta"
            && owner.document.layers[2].name == "Gamma",
            "6030 fixture floor needs Alpha/Beta/Gamma before binding");
        wire();
    }

    this(bool withNonMeshItems) {
        assert(withNonMeshItems);
        Document document = namedDocument(["Alpha", "Beta", "Gamma"]);
        empty = new Layer;
        empty.kind = ItemKind.Empty;
        empty.name = "Empty";
        document.layers ~= empty;
        View commandView = new View(0, 0, 800, 600);
        auto add = new ImagePlaneAdd(document.activeMesh(), commandView,
            EditMode.Vertices, &document, null);
        assert(add.apply(), "6502 fixture: production imagePlane.add failed");
        plane = add.created();
        owner = Session.create(document);
        assert(owner.document.layers.length == 5
            && owner.document.layers[0].name == "Alpha"
            && owner.document.layers[1].name == "Beta"
            && owner.document.layers[2].name == "Gamma"
            && owner.document.layers[3] is empty
            && owner.document.layers[4] is plane
            && kindInfo(empty.kind).canBePrimary == false,
            "6502 fixture floor needs three meshes, Empty and a production image plane");
        wire();
    }

    private void wire() {
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

unittest { // the all-valid action roster binds and every missing member fails
    auto app = new LayerPanelHarness;
    auto ok = bindLayerListPanel(app.owner, app.binding, app.forms,
                                 () => app.activeTool);
    assert(ok.state !is null && ok.actions.tupleof[4] is ok.state
        && ok.actions.commandDispatch() !is null
        && ok.read.document() !is null,
        "6502 floor: the all-valid Items roster must bind");

    ItemRenameDispatch dispatch = &app.binding.dispatchUi;
    ItemRenameDispatch interactive = &app.binding.dispatchInteractiveUi;
    assertThrown!AssertError(LayerListActions(
        null, dispatch, interactive, app.forms, ok.state),
        "6502 action roster: a null session owner must be rejected");
    assertThrown!AssertError(LayerListActions(
        app.owner, null, interactive, app.forms, ok.state),
        "6502 action roster: a null UI dispatch must be rejected");
    assertThrown!AssertError(LayerListActions(
        app.owner, dispatch, null, app.forms, ok.state),
        "6502 action roster: a null interactive dispatch must be rejected");
    assertThrown!AssertError(LayerListActions(
        app.owner, dispatch, interactive, null, ok.state),
        "6502 action roster: a null forms panel must be rejected");
    assertThrown!AssertError(LayerListActions(
        app.owner, dispatch, interactive, app.forms, null),
        "6502 action roster: a null binding state must be rejected");
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
        app.owner.documentPtr(), app.roles.actions.commandDispatch());
    rename.begin(app.owner.document.layers[1], "Beta");
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
        && !app.renameState.open,
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
    assert(snapshot.formBlockEntered && snapshot.formTarget == 1
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
    assert(snapshot.formBlockEntered && snapshot.transformGuardArmed,
        "6030 transform guard did not arm for a live transform tool in geometry mode");

    app.owner.selTypeOrder.touch(SelType.Item);
    ui.frame();
    snapshot = layerListDrawSnapshot();
    assert(snapshot.formBlockEntered && !snapshot.transformGuardArmed,
        "6030 transform guard stayed armed in item mode");

    app.owner.selTypeOrder.touch(SelType.Vertex);
    app.activeTool = null;
    ui.frame();
    snapshot = layerListDrawSnapshot();
    assert(snapshot.formBlockEntered && !snapshot.transformGuardArmed,
        "6030 transform guard armed without a transform tool");
}

unittest { // B-OWN: the provider belongs to this binding and its live focus
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    const snapshot = layerListDrawSnapshot();
    assert(snapshot.formBlockEntered && snapshot.formBound
        && snapshot.formTarget == 0 && snapshot.formWidth > 20
        && snapshot.formRowH > 0,
        "6502 B-OWN floor: Alpha's form was not drawn and bound");
    assert(layerFormProvider(app.roles.state) !is null
        && layerFormBoundItem(app.roles.state)
            is app.owner.document.layers[0],
        "6502 B-OWN: the binding state does not own the provider bound to its focus");
}

unittest { // B-NONE: an unresolved form target stays distinct from layer zero
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    auto only = new Layer;
    only.kind = ItemKind.Empty;
    only.name = "Only";
    app.owner.document.layers = [only];
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    const snapshot = layerListDrawSnapshot();
    assert(snapshot.formBlockEntered && !snapshot.formBound
        && snapshot.formTarget == size_t.max,
        "6502 B-NONE: an unresolved form target became layer zero");
}

unittest { // B-TWO: alternating bindings retain distinct provider identities
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto first = new LayerPanelHarness;
    auto second = new LayerPanelHarness;
    int which;
    auto ui = openPanel(() {
        ImGui.SetNextWindowSize(ImVec2(520, 900));
        if (which == 0)
            drawLayerListPanel(first.roles.read, first.roles.actions,
                               first.renameState);
        else
            drawLayerListPanel(second.roles.read, second.roles.actions,
                               second.renameState);
    }, "Items alt host", 1280, 1000);
    scope (exit) ui.close();

    ui.frame();
    auto firstProvider = layerFormProvider(first.roles.state);
    assert(layerListDrawSnapshot().formBound && firstProvider !is null,
        "6502 B-TWO floor: the first binding did not create its provider");
    which = 1;
    ui.frame();
    auto secondProvider = layerFormProvider(second.roles.state);
    assert(layerListDrawSnapshot().formBound && secondProvider !is null,
        "6502 B-TWO floor: the second binding did not create its provider");
    assert(firstProvider !is secondProvider,
        "6502 B-TWO: two live bindings share one form provider");
    which = 0;
    ui.frame();
    assert(layerFormProvider(first.roles.state) is firstProvider
        && layerFormBoundItem(first.roles.state)
            is first.owner.document.layers[0],
        "6502 B-TWO: returning to the first binding lost its provider or document identity");
}

unittest { // B-FOCUS: one binding reuses its provider for the current item
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    app.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    auto provider = layerFormProvider(app.roles.state);
    assert(layerListDrawSnapshot().formBound && provider !is null
        && layerFormBoundItem(app.roles.state)
            is app.owner.document.layers[1],
        "6502 B-FOCUS floor: Beta did not bind the form provider");
    app.binding.dispatchUi("layer.select", `{"index":2,"mode":"set"}`);
    ui.frame();
    assert(layerListDrawSnapshot().formBound
        && layerListDrawSnapshot().formTarget == 2
        && layerFormProvider(app.roles.state) is provider
        && layerFormBoundItem(app.roles.state)
            is app.owner.document.layers[2],
        "6502 B-FOCUS: the provider did not follow the live focus by identity");
}

private extern (C) void igSetNextWindowCollapsed(bool collapsed, int cond);

unittest { // B-REPLACE: a collapsed replacement cannot preserve stale identity
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness;
    app.binding.dispatchUi("layer.select", `{"index":2,"mode":"set"}`);
    auto oldFocus = app.owner.document.layers[2];
    bool collapsed;
    bool replace;
    Document next = namedDocument(["Delta", "Epsilon"]);
    auto ui = openPanel(() {
        ImGui.SetNextWindowSize(ImVec2(520, 900));
        igSetNextWindowCollapsed(collapsed, 1);
        if (replace) {
            *app.owner.documentPtr() = next;
            replace = false;
        }
        drawLayerListPanel(app.roles.read, app.roles.actions, app.renameState);
    }, "Items replacement host", 1280, 1000);
    scope (exit) ui.close();

    ui.frame();
    const before = layerListDrawSnapshot();
    const focusIndexBefore = app.owner.document.indexOf(
        app.owner.document.focusedItem);
    auto provider = layerFormProvider(app.roles.state);
    assert(before.formBound && before.formTarget == 2
        && layerFormBoundItem(app.roles.state) is oldFocus,
        "6502 B-REPLACE floor: the old document was not bound at nonzero focus");
    collapsed = true;
    replace = true;
    ui.frame();
    assert(layerListDrawSnapshot().formTarget == before.formTarget
        && layerFormBoundItem(app.roles.state) is oldFocus,
        "6502 B-REPLACE hidden floor: the collapsed frame unexpectedly rewrote its snapshot or provider");
    collapsed = false;
    ui.frame();
    const after = layerListDrawSnapshot();
    const focusIndexAfter = app.owner.document.indexOf(
        app.owner.document.focusedItem);
    assert(focusIndexBefore != focusIndexAfter,
        "6502 B-REPLACE floor: focus indices before and after replacement must differ");
    assert(after.formBound && after.formTarget == 0
        && after.rows.length == 3 && after.rows[1].name == "Delta"
        && layerFormProvider(app.roles.state) is provider
        && layerFormBoundItem(app.roles.state)
            is app.owner.document.layers[0]
        && layerFormBoundItem(app.roles.state) !is oldFocus,
        "6502 B-REPLACE: the expanded draw retained the replaced document's item identity");
}

unittest { // B-PRIMARY: a non-primary focus still owns the form
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness(true);
    app.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    app.binding.dispatchUi("layer.select", `{"index":3,"mode":"toggle"}`);
    assert(app.owner.document.focusedItem is app.empty
        && app.owner.document.primary is app.owner.document.layers[1]
        && app.owner.document.focusedItem !is app.owner.document.primary,
        "6502 B-PRIMARY floor: Empty focus did not diverge from Beta primary");
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    assert(layerListDrawSnapshot().formBound
        && layerListDrawSnapshot().formTarget == 3
        && layerFormBoundItem(app.roles.state) is app.empty,
        "6502 B-PRIMARY: the form followed primary instead of the non-primary focus");
}

unittest { // B-PLANE: a production-created plane reaches the binding
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness(true);
    assert(app.plane !is null && app.plane.imagePlaneOrNull() !is null,
        "6502 B-PLANE floor: imagePlane.add did not create the plane payload");
    app.binding.dispatchUi("layer.select", `{"index":4,"mode":"set"}`);
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    assert(layerListDrawSnapshot().formBound
        && layerListDrawSnapshot().formTarget == 4
        && layerFormBoundItem(app.roles.state) is app.plane,
        "6502 B-PLANE reachability: the production plane did not reach the owned form provider");
}

unittest { // B-GANG: the production binding passes its resolved gang to its provider
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness(true);
    auto other = new Layer;
    other.kind = ItemKind.Empty;
    other.name = "Other Empty";
    app.owner.document.layers ~= other;
    app.binding.dispatchUi("layer.select", `{"index":3,"mode":"set"}`);
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    assert(layerListDrawSnapshot().formBound
        && !layerFormGangMixed(app.roles.state),
        "6502 B-GANG floor: a single selected Empty reported a mixed name");

    app.binding.dispatchUi("layer.select", `{"index":5,"mode":"toggle"}`);
    ui.frame();
    assert(layerListDrawSnapshot().formBound
        && layerFormGangMixed(app.roles.state),
        "6502 B-GANG: the resolved gang never reached the owned provider");
}

unittest { // B-FORM: focus leads the gang dispatch and receives the edit
    Form[] priorForms;
    installEnvironment(priorForms);
    scope (exit) { g_forms = priorForms; SDL_SetModState(KMOD_NONE); }

    auto app = new LayerPanelHarness(true);
    auto gang = new Layer;
    gang.kind = ItemKind.Empty;
    gang.name = "Empty";
    app.owner.document.layers ~= gang;
    app.binding.dispatchUi("layer.select", `{"index":5,"mode":"set"}`);
    app.binding.dispatchUi("layer.select", `{"index":3,"mode":"toggle"}`);
    assertHistoryHeadroom(app);
    const alpha = app.owner.document.layers[0].name;
    const beta = app.owner.document.layers[1].name;
    const gamma = app.owner.document.layers[2].name;
    const emptyName = app.empty.name;
    auto ui = app.open();
    scope (exit) ui.close();
    ui.frame();
    const snapshot = layerListDrawSnapshot();
    assert(snapshot.formBlockEntered && snapshot.formBound
        && snapshot.formTarget == 3 && snapshot.formWidth > 20
        && snapshot.formRowH > 0,
        "6502 B-FORM floor: Empty's first form row was not recorded");
    ui.pressAt(ImVec2(snapshot.formOrigin.x + 0.75f * snapshot.formWidth,
                      snapshot.formOrigin.y + 0.5f * snapshot.formRowH));
    ui.release();
    ui.typeText("Q");
    assert(app.empty.name != emptyName
        && app.owner.document.layers[0].name == alpha
        && app.owner.document.layers[1].name == beta
        && app.owner.document.layers[2].name == gamma,
        "6502 B-FORM: the form did not edit Empty while preserving all mesh names");
    assert(app.history.undoEntries().length == 1
        && app.history.undoEntries()[0].commandName == "layer.attr"
        && app.records.length == 1 && app.records[0].id == "layer.attr"
        && app.records[0].outcome == "applied",
        "6502 B-FORM: the edit lost its one guarded layer.attr command");
    assert(app.history.undoEntries()[0].args.canFind(`index:"3,5"`),
        "6502 gang order: the dispatched layer.attr addressed the gang before the focus; args="
        ~ app.history.undoEntries()[0].args);
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

private struct ItemStripSignalRow {
    string path;
    size_t casts, traits, tupleofs, mixins, unions;
}

private enum ItemStripSignalRow[] kItemStripSignalLedger = [
    ItemStripSignalRow("source/ui/layer_list_panel.d", 7, 0, 0, 0, 0),
    ItemStripSignalRow("source/ui/item_rows.d", 0, 0, 0, 0, 0),
    ItemStripSignalRow("source/layer_params.d", 0, 0, 0, 0, 0),
];

private enum kItemStripSignalTokens =
    ["cast", "__traits", "tupleof", "mixin", "union"];
static assert(kItemStripSignalTokens ==
        ["cast", "__traits", "tupleof", "mixin", "union"],
    "6502 strip signal token roster changed — every measured column must remain in the exact scan below");

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

unittest { // 6502 census: ownership regions, file totals and strip signal
    const rawLayer = readText(repoRoot.buildPath(
        "source", "ui", "layer_list_panel.d"));
    const rawRows = readText(repoRoot.buildPath("source", "ui", "item_rows.d"));
    const rawParams = readText(repoRoot.buildPath("source", "layer_params.d"));
    const layer = blankNonCode(rawLayer);

    string[] actualPaths;
    string[] rawSources;
    size_t sourceBytes;
    foreach (row; kItemStripSignalLedger) {
        actualPaths ~= row.path;
        auto raw = readText(repoRoot.buildPath(row.path));
        rawSources ~= raw;
        sourceBytes += raw.length;
    }
    assert(kItemStripSignalLedger.length == 3 && rawSources.length == 3
        && rawLayer.length + rawRows.length + rawParams.length > 100_000
        && sourceBytes > 100_000,
        "6502 strip signal population: expected three populated production files over 100000 bytes");

    auto sortedActual = actualPaths.dup;
    sortedActual.sort;
    auto expectedPaths = ["source/layer_params.d", "source/ui/item_rows.d",
                          "source/ui/layer_list_panel.d"];
    expectedPaths.sort;
    assert(sortedActual == expectedPaths,
        "6502 strip signal shape: the ledger does not name exactly the three owned files");
    foreach (path; expectedPaths) {
        size_t appearances;
        foreach (row; kItemStripSignalLedger)
            if (row.path == path) ++appearances;
        assert(appearances == 1,
            "6502 strip signal shape: " ~ path ~ " appears "
            ~ appearances.to!string ~ " times instead of once");
    }

    size_t casts, traits, tupleofs, mixins, unions;
    foreach (row; kItemStripSignalLedger) {
        casts += row.casts;
        traits += row.traits;
        tupleofs += row.tupleofs;
        mixins += row.mixins;
        unions += row.unions;
    }
    assert(casts == 7 && traits == 0 && tupleofs == 0
        && mixins == 0 && unions == 0,
        "6502 strip signal totals changed: cast=" ~ casts.to!string
        ~ " __traits=" ~ traits.to!string ~ " tupleof="
        ~ tupleofs.to!string ~ " mixin=" ~ mixins.to!string
        ~ " union=" ~ unions.to!string);
    foreach (i, row; kItemStripSignalLedger) {
        const code = blankNonCode(rawSources[i]);
        immutable recorded =
            [row.casts, row.traits, row.tupleofs, row.mixins, row.unions];
        assert(recorded.length == kItemStripSignalTokens.length,
            "6502 strip signal token roster and recorded columns diverged");
        foreach (column, token; kItemStripSignalTokens) {
            const actual = identifierCount(code, token);
            assert(actual == recorded[column],
                "6502 strip signal: " ~ row.path ~ " " ~ token ~ " = "
                ~ actual.to!string ~ ", recorded "
                ~ recorded[column].to!string
                ~ " — a row may only FALL; if the spelling left, lower it "
                ~ "in this commit; if it appeared, treat that as a finding");
        }
    }

    const drawBody = bodyAt(layer,
        "void drawLayerListPanel(LayerListReadRole read, LayerListActions actions,");
    assert(drawBody.count("itemRowsInto") > 0
        && drawBody.count("recordLayerRow") > 0
        && drawBody.count("layerDeleteButtonState") > 0
        && drawBody.count("EndDragDropTarget") > 0,
        "6502 draw region: the Items draw body no longer spans the row loop and the form block — the nulls below would be measuring the wrong region");
    assert(drawBody.count("struct LayerListActions") == 0
        && drawBody.count("bindLayerListPanel") == 0
        && drawBody.count("final class LayerListPanelState") == 0,
        "6502 draw region: the Items draw body swallowed the action role or the binder");

    const actionsBody = bodyAt(layer, "struct LayerListActions");
    assert(actionsBody.count("drawItemForm") > 0
        && actionsBody.count("resolveLive") > 0
        && actionsBody.count("commandDispatch") > 0,
        "6502 action region: the action-role region did not span drawItemForm/resolveLive");
    assert(actionsBody.count("drawLayerListPanel") == 0
        && actionsBody.count("beginLayerListDraw") == 0,
        "6502 action region: the action-role region swallowed the draw body");

    const readRoleBody = bodyAt(layer, "struct LayerListReadRole");
    assert(readRoleBody.count("documentPtr") > 0
        && readRoleBody.count("selTypeOrder") > 0
        && readRoleBody.count("transformToolActive") > 0,
        "6502 read region: the read-role region did not span its three accessors");
    assert(readRoleBody.count("dispatch") == 0
        && readRoleBody.count("forms_") == 0,
        "6502 read region: the read-role region swallowed the action role");

    assert(identifierCount(drawBody, "owner_") == 0,
        "6502 read fence: the Items draw body names the read role's private member");
    assert(identifierCount(drawBody, "state_") == 0,
        "6502 write fence: the Items draw body names the binding's private form state");
    assert(identifierCount(drawBody, "props_") == 0
        && identifierCount(drawBody, "LayerPropsProvider") == 0
        && identifierCount(drawBody, "layerProv") == 0
        && layer.count("static LayerPropsProvider layerProv;") == 0,
        "6502 provider fence: the Items draw body regained provider storage or access");
    assert(identifierCount(drawBody, "static") == 3,
        "6502 draw census: static locals changed; the removed frame-global provider may have returned");

    assert(identifierCount(layer, "owner_") == 7,
        "6502 read fence: owner_ is named "
        ~ identifierCount(layer, "owner_").to!string ~ " times (recorded 7)");
    assert(identifierCount(layer, "state_") == 15,
        "6502 write fence: state_ is named "
        ~ identifierCount(layer, "state_").to!string ~ " times (recorded 15)");
    assert(identifierCount(layer, "props_") == 13,
        "6502 write fence: props_ is named "
        ~ identifierCount(layer, "props_").to!string ~ " times (recorded 13)");
    assert(identifierCount(layer, "gangBuf_") == 7,
        "6502 write fence: gangBuf_ is named "
        ~ identifierCount(layer, "gangBuf_").to!string ~ " times (recorded 7)");
    assert(identifierCount(layer, "LayerPropsProvider") == 3,
        "6502 provider fence: LayerPropsProvider is named "
        ~ identifierCount(layer, "LayerPropsProvider").to!string
        ~ " times (recorded 3)");
    assert(identifierCount(readRoleBody, "owner_") == 4,
        "6502 read-role census: owner_ is no longer confined to its four recorded uses");
    assert(identifierCount(actionsBody, "owner_") == 3
        && identifierCount(actionsBody, "state_") == 15,
        "6502 action-role census: owner_/state_ uses changed from 3/15");
}
