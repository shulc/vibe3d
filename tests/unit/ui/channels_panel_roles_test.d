module tests.unit.ui.channels_panel_roles_test;

import std.algorithm : count, sort;
import core.exception : AssertError;
import std.exception : assertThrown;
import std.conv : to;
import std.file : SpanMode, dirEntries, readText;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.range : walkLength;
import std.regex : matchAll, regex;
import std.string : indexOf;

import application_command_binding : ApplicationCommandBinding;
import command : Command;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.layer.commands : LayerAttr, LayerRename, LayerReorder, LayerSelect;
import document : Document, ItemKind, Layer;
import edit_session : EditSession;
import editmode : EditMode;
import forms_render : FormsPanel;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import image_data : ImagePlaneData;
import layer_params : LayerPropsProvider, itemPropsTarget;
import math : Vec3;
import mesh : MapKind, Mesh, makeCube;
import mesh_gpu : GpuMesh;
import morph_target : clearMorphTarget, setMorphTarget;
import params : Param;
import registry : Registry;
import seltype : SelType, currentSelType;
import session_owner : Session;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import tools.transform.xfrm_transform : XfrmTransformTool;
import ui.channel_rows : ChannelsKey, ChannelsModel, ChannelsProvider,
    channelsModel;
import ui.channels_panel : ChannelsActions, ChannelsDrawSnapshot,
    ChannelsPanelRoles, ChannelsPanelState, ChannelsReadRole,
    bindChannelsPanel, channelsArmTransformGuard, channelsBoundItem,
    channelsDrawSnapshot,
    channelsFormProvider, channelsInteractiveWriter,
    channelsProviderMatchesModel, channelsRefreshState,
    channelsStateWithResolver, channelsTransformGuardArmed, drawChannelsPanel,
    resetChannelsDrawSnapshot;
import ui.discard_guard : GuardRecord;
import ui.retained_item : ConstItem;
import view : View;
import d_imgui.imgui_h : ImVec2;

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

static assert(!__traits(compiles, (ChannelsPanelRoles roles) {
        Document* document = roles.read.document();
    }),
    "6503 N1 document: the Channels read role hands out a mutable Document*");
static assert(__traits(compiles, (ChannelsPanelRoles roles) {
        const(Document)* document = roles.read.document();
    }),
    "6503 N1 control: the same role expression must compile through const");
static assert(!__traits(compiles, (ChannelsPanelRoles roles) {
        auto document = roles.read.document();
        document.layers[0].name = "x";
    }),
    "6503 N1w document: the Channels read role permits a document write");

static assert(!__traits(compiles, (ChannelsKey key) {
        Layer item = key.item;
    }),
    "6503 N2 key.item: the Channels memo key hands out a mutable Layer");
static assert(__traits(compiles, (ChannelsKey key) {
        const(Layer) item = key.item;
    }),
    "6503 N2 control: the same key expression must compile through const");
static assert(__traits(compiles, (ChannelsKey key, Layer someMutableLayer) {
        key.item = someMutableLayer;
        bool isNull = key.item is null;
        bool isSame = key.item is someMutableLayer;
    }),
    "6503 N2r key.item: the key's identity slot must stay REBINDABLE — the memo assigns the whole model");
static assert(!__traits(compiles, (ChannelsModel model) {
        Layer item = model.key.item;
    }),
    "6503 N3 model.key.item: the Channels read model hands a mutable Layer out of its key");
static assert(__traits(compiles, (ChannelsModel model) {
        const(Layer) item = model.key.item;
    }),
    "6503 N3 control: the same model expression must compile through const");
static assert(!__traits(compiles, (const(Param)[] ps) {
        *(ps[0].fptr) = 1.0f;
    }),
    "6503 N7 fact: a const parameter snapshot cannot write through a float pointer");
static assert(__traits(compiles, (const(Document)* doc, const(Layer) item,
                                  const(Param)[] ps) {
        auto model = channelsModel(doc, item, ps);
    }),
    "6503 N7 control: the Channels model builder still requires a writable document, item, or parameter snapshot");

static assert(!__traits(compiles, (ChannelsProvider p) {
        auto base = p.base();
    }),
    "6503 N4 provider.base: the Channels provider hands out its writable base provider");
static assert(__traits(compiles, (ChannelsProvider p) {
        const(Layer) item = p.boundItem();
    }),
    "6503 N4 control: the replacement door must expose a read-only bound identity");
static assert(!__traits(compiles, (ChannelsProvider p) {
        Layer item = p.boundItem();
    }),
    "6503 N5 provider.boundItem: the Channels provider hands out a mutable Layer");
static assert(!__traits(compiles, (LayerPropsProvider p) {
        Layer item = p.layer();
    }),
    "6503 N6 layer provider: LayerPropsProvider.layer hands out a mutable Layer");
static assert(__traits(compiles, (LayerPropsProvider p) {
        const(Layer) item = p.layer();
    }),
    "6503 N6 control: LayerPropsProvider.layer must still expose a read-only identity");

static assert([__traits(allMembers, ChannelsProvider)] ==
        ["base_", "blocked_", "__ctor", "rebind", "boundItem",
         "setTransformGuard", "rebuildBlocked", "params", "paramEnabled",
         "onParamChanged", "toString", "toHash", "opCmp", "opEquals",
         "Monitor", "factory"],
    "6503 F7 fence (names): the Channels provider's member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!ChannelsProvider ==
        ["base_: LayerPropsProvider", "blocked_: bool[string]",
         "__ctor: ChannelsProvider(Layer l)", "rebind: void(Layer l)",
         "boundItem: const const(Layer)()",
         "setTransformGuard: void(bool toolActive, SelType current)",
         "rebuildBlocked: void()", "params: Param[]()",
         "paramEnabled: const bool(string name)",
         "onParamChanged: void(string name)", "toString: string()",
         "toHash: nothrow @trusted ulong()", "opCmp: int(Object o)",
         "opEquals: bool(Object o)", "Monitor: <no type>",
         "factory: Object(string classname)"],
    "6503 F7 fence (types): a member of ChannelsProvider changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");

static assert([__traits(allMembers, ChannelsKey)] ==
        ["item", "index", "paramCount", "opAssign"],
    "6503 F5 fence (names): the Channels key's member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!ChannelsKey ==
        ["item: Rebindable!(const(Layer))", "index: ulong",
         "paramCount: ulong",
         "opAssign: pure nothrow @nogc ref @trusted ChannelsKey(ChannelsKey p) return"],
    "6503 F5 fence (types): a member of ChannelsKey changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, ChannelsModel)] ==
        ["bound", "kindText", "index", "form", "channelCount", "key",
         "opAssign"],
    "6503 F6 fence (names): the Channels model's member set changed — the key's assignment surface may have drifted");
static assert(memberTypes!ChannelsModel ==
        ["bound: bool", "kindText: string", "index: ulong", "form: Form",
         "channelCount: ulong", "key: ChannelsKey",
         "opAssign: pure nothrow @nogc ref @trusted ChannelsModel(ChannelsModel p) return"],
    "6503 F6 fence (types): a member of ChannelsModel changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");

static assert(ChannelsKey.tupleof.length == 3,
    "6503 field roster: the Channels key must retain exactly item, index, and parameter count");
static assert(ChannelsModel.tupleof.length == 6,
    "6503 field roster: the Channels model must retain exactly its six read-model fields");
static assert(is(typeof(ChannelsDrawSnapshot.retainedItem) == ConstItem),
    "6503 snapshot slot: the retained-item slot stopped being a read-only identity");

static assert([__traits(allMembers, ChannelsReadRole)] ==
        ["owner_", "activeTool_", "__ctor", "document", "currentSelType",
         "transformToolActive", "editMesh"],
    "6503 F1 fence (names): the Channels read role's member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!ChannelsReadRole ==
        ["owner_: Session*", "activeTool_: Tool delegate()",
         "__ctor: ref ChannelsReadRole() | ref ChannelsReadRole(Session* owner, Tool delegate() activeTool)",
         "document: const(Document)*()", "currentSelType: SelType()",
         "transformToolActive: bool()", "editMesh: const(Mesh)*()"],
    "6503 F1 fence (types): a member of ChannelsReadRole changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, ChannelsActions)] ==
        ["interactive_", "forms_", "__ctor", "drawChannelForm"],
    "6503 F2 fence (names): the Channels action role's member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!ChannelsActions ==
        ["interactive_: void delegate(string, string)",
         "forms_: FormsPanel",
         "__ctor: ref ChannelsActions() | ref ChannelsActions(void delegate(string, string) interactive, FormsPanel forms)",
         "drawChannelForm: void(ref Form form, ChannelsProvider provider)"],
    "6503 F2 fence (types): a member of ChannelsActions changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, ChannelsPanelState)] ==
        ["provider_", "model_", "resolve_", "__ctor", "retainOnly",
         "refresh", "dropMemo", "providerMatchesModel",
         "armTransformGuard", "transformGuardArmed", "toString", "toHash",
         "opCmp", "opEquals", "Monitor", "factory"],
    "6503 F3 fence (names): the Channels panel state's member set changed — a capability cannot be added here without naming it");
static assert(memberTypes!ChannelsPanelState ==
        ["provider_: ChannelsProvider", "model_: ChannelsModel",
         "resolve_: Layer delegate(const(Layer) id)",
         "__ctor: ChannelsPanelState(Layer delegate(const(Layer) id) resolve)",
         "retainOnly: void(const(Layer) item)",
         "refresh: bool(const(Document)* doc, const(Layer) item)",
         "dropMemo: bool()", "providerMatchesModel: const bool()",
         "armTransformGuard: void(bool toolActive, SelType current)",
         "transformGuardArmed: const bool()", "toString: string()",
         "toHash: nothrow @trusted ulong()", "opCmp: int(Object o)",
         "opEquals: bool(Object o)", "Monitor: <no type>",
         "factory: Object(string classname)"],
    "6503 F3 fence (types): a member of ChannelsPanelState changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, ChannelsPanelRoles)] ==
        ["read", "actions", "state"],
    "6503 F4 fence (names): the Channels roles tuple's member set changed — a capability cannot be added or removed here without naming it");
static assert(memberTypes!ChannelsPanelRoles ==
        ["read: ChannelsReadRole", "actions: ChannelsActions",
         "state: ChannelsPanelState"],
    "6503 F4 fence (types): a member of ChannelsPanelRoles changed its TYPE or SIGNATURE — regenerate with the pragma probe, read the diff, and argue the change; do not paste the actual list over the expected one");

static assert(ChannelsReadRole.tupleof.length == 2
        && is(typeof(ChannelsReadRole.tupleof[0]) == Session*),
    "6503 field roster: the Channels read role must retain exactly its session and tool getter");
static assert(ChannelsPanelState.tupleof.length == 3,
    "6503 field roster: the Channels state must retain provider, model, and resolver only");

static assert(__traits(compiles, {
    ChannelsPanelRoles roles = void;
    ChannelsPanelState s = roles.state;
}) && !__traits(compiles, new ChannelsPanelState()),
    "6358 state ownership: only bindChannelsPanel may create the panel memo");

static assert(!__traits(hasMember, ChannelsModel, "title"),
    "6358 single name store: the row model regained a cached title");

static assert(!__traits(compiles, {
    ChannelsPanelRoles roles = void;
    roles.actions.interactive_ = (string id, string paramsJson) {};
}), "6050 action capability: external callers must not replace the interactive writer");

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..");

private final class ChannelsHarness {
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
    Mesh toolMesh;
    GpuMesh toolGpu;
    EditMode toolMode = EditMode.Vertices;
    XfrmTransformTool xfrm;
    Layer alpha;
    Layer beta;
    Layer gamma;
    Layer plane;

    this() {
        owner = Session.bootstrap(makeCube());
        alpha = owner.document.layers[0];
        alpha.name = "Alpha";
        auto am = &alpha.meshRef();
        assert(am.addMeshMapOfKind(MapKind.morphRelative, "smile") !is null);
        foreach (vi; [0u, 3u, 5u])
            assert(am.setMorphValue("smile", vi, Vec3(0, 1, 0)));
        assert(am.addMeshMapOfKind(MapKind.morphAbsolute, "frown") !is null);
        foreach (vi; 0 .. am.vertices.length)
            assert(am.setMorphValue("frown", vi, am.vertices[vi]));

        beta = new Layer;
        beta.name = "Beta";
        beta.meshRef() = makeCube();
        assert(beta.meshRef().addMeshMapOfKind(
            MapKind.morphRelative, "grin") !is null);
        assert(beta.meshRef().setMorphValue("grin", 1, Vec3(0, 0.5f, 0)));
        owner.document.layers ~= beta;

        gamma = new Layer;
        gamma.name = "Gamma";
        gamma.meshRef() = makeCube();
        owner.document.layers ~= gamma;

        plane = new Layer;
        plane.name = "Plane";
        plane.kind = ItemKind.ImagePlane;
        plane.imagePlaneRef() = new ImagePlaneData;
        owner.document.layers ~= plane;

        assert(owner.document.layers.length == 4
            && owner.document.layers[0] is alpha
            && owner.document.layers[1] is beta
            && owner.document.layers[2] is gamma
            && owner.document.layers[3] is plane,
            "6050 fixture population must exist before the production bind");

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
        registry.registerCommand("layer.select", () => cast(Command)
            new LayerSelect(&owner.editMesh(), view, owner.editMode,
                            owner.documentPtr(), null));
        registry.registerCommand("layer.rename", () => cast(Command)
            new LayerRename(&owner.editMesh(), view, owner.editMode,
                            owner.documentPtr(), null));
        registry.registerCommand("layer.reorder", () => cast(Command)
            new LayerReorder(&owner.editMesh(), view, owner.editMode,
                             owner.documentPtr(), null));
        registry.registerCommand("layer.attr", () => cast(Command)
            new LayerAttr(&owner.editMesh(), view, owner.editMode,
                          owner.documentPtr(), null));

        forms = new FormsPanel;
        toolMesh = makeCube();
        xfrm = new XfrmTransformTool(
            () => &toolMesh, &toolGpu, &toolMode,
            () => SelType.Vertex, null);
    }

    ChannelsPanelRoles bind() {
        return bindChannelsPanel(owner, binding, forms, () => activeTool);
    }
}

private HeadlessPanel openChannels(ChannelsPanelRoles roles) {
    resetChannelsDrawSnapshot();
    return openPanel(
        () { drawChannelsPanel(roles.read, roles.actions, roles.state); },
        "Channels host", 1280, 1200);
}

private ChannelsDrawSnapshot fresh(ref HeadlessPanel ui) {
    resetChannelsDrawSnapshot();
    ui.frame();
    auto snapshot = channelsDrawSnapshot();
    assert(snapshot.drawn,
        "6050 draw floor: the Channels Begin body was collapsed or not submitted");
    return snapshot;
}

private ChannelsDrawSnapshot settle(ref HeadlessPanel ui) {
    fresh(ui);
    return fresh(ui);
}

unittest { // the all-valid role roster binds and every missing member fails
    auto h = new ChannelsHarness;
    auto ok = bindChannelsPanel(h.owner, h.binding, h.forms,
                                () => h.activeTool);
    assert(ok.state !is null && ok.read.document() !is null
        && channelsFormProvider(ok.state) is null,
        "6503 floor: the all-valid Channels roster must bind, with an empty memo");
    assert(channelsInteractiveWriter(ok.actions)
            is &h.binding.dispatchInteractiveUi,
        "6503 interactive writer: the Channels binding stored the ordinary UI dispatch instead of the interactive one");

    void delegate(string, string) interactive =
        &h.binding.dispatchInteractiveUi;
    assertThrown!AssertError(channelsStateWithResolver(null),
        "6503 state roster: a null item resolver must be rejected");
    assertThrown!AssertError(ChannelsActions(null, h.forms),
        "6503 action roster: a null interactive writer must be rejected");
    assertThrown!AssertError(ChannelsActions(interactive, null),
        "6503 action roster: a null forms panel must be rejected");
    assertThrown!AssertError(ChannelsReadRole(null, () => h.activeTool),
        "6503 read roster: a null session owner must be rejected");
    assertThrown!AssertError(ChannelsReadRole(h.owner, null),
        "6503 read roster: a null active-tool getter must be rejected");
}

private ImVec2 center(ImVec2 lo, ImVec2 hi) {
    assert(hi.x > lo.x && hi.y > lo.y,
        "6050 widget rectangle is empty");
    return ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
}

private bool sameRect(ImVec2 alo, ImVec2 ahi, ImVec2 blo, ImVec2 bhi) {
    return alo.x == blo.x && alo.y == blo.y
        && ahi.x == bhi.x && ahi.y == bhi.y;
}

private void clearHistory(ChannelsHarness h) {
    h.history.clear();
    h.records.length = 0;
    assert(h.history.undoEntries().length == 0 && h.records.length == 0,
        "6050 history floor must start below the capped-stack boundary");
}

unittest { // M1/M5: live focus and one real interactive write
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto h = new ChannelsHarness;
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();

    auto snapshot = settle(ui);
    assert(snapshot.bound && snapshot.title == "Alpha"
        && snapshot.kindText == "Mesh" && snapshot.formDrawn
        && snapshot.lastRowMax.x > snapshot.lastRowMin.x
        && snapshot.lastRowMax.y > snapshot.lastRowMin.y,
        "6050 live-focus floor needs Alpha's non-empty mesh form");

    h.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    assert(h.owner.documentPtr().primary is h.beta
        && itemPropsTarget(h.owner.documentPtr()) is h.beta,
        "6050 live-focus precondition: the owner did not select Beta");
    snapshot = settle(ui);
    assert(snapshot.title == "Beta",
        "6050 live focus: Channels still shows the item captured at bind");

    clearHistory(h);
    const depth = h.history.undoEntries().length;
    const records = h.records.length;
    assert(ui.editAt(center(snapshot.lastRowMin, snapshot.lastRowMax), "2.5"),
        "6050 channel write floor: Beta's last row did not take ActiveId");
    assert(h.beta.xform.pivot.z == 2.5f && h.alpha.xform.pivot.z == 0.0f,
        "6050 live focus: the channel write did not change Beta alone");
    auto entries = h.history.undoEntries();
    assert(entries.length == depth + 1
        && entries[$ - 1].commandName == "layer.attr"
        && entries[$ - 1].args
            == `index:"1" attr:pivot.z value:"2.5"`,
        "6050 channel write lost its layer.attr history identity");
    assert(h.records.length == records + 1
        && h.records[$ - 1].id == "layer.attr",
        "6050 interactive route: the channel write bypassed the UI policy");
    assert(h.history.undo()
        && h.beta.xform.pivot.z == 0.0f
        && h.history.undoEntries().length == depth,
        "6050 channel write did not undo to Beta's baseline");
}

unittest { // M1b/M9: maps read the live edit mesh and target name
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto h = new ChannelsHarness;
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();

    auto snapshot = settle(ui);
    assert(snapshot.mapsHeaderDrawn && !snapshot.mapsOpen
        && snapshot.mapLines.length == 0,
        "6050 maps floor needs Alpha's closed, populated maps section");
    ui.pressAt(center(snapshot.mapsHeaderMin, snapshot.mapsHeaderMax));
    ui.release();
    snapshot = fresh(ui);
    assert(snapshot.mapsOpen && snapshot.mapLines == [
            "  smile  [relative]  3/8",
            "  frown  [absolute]  8/8",
            "no target bound - edits go to the base"],
        "6050 maps rows lost relative/absolute presence or unbound text");

    setMorphTarget("smile", MapKind.morphRelative);
    snapshot = fresh(ui);
    assert(snapshot.mapLines == [
            "> smile  [relative]  3/8",
            "  frown  [absolute]  8/8"],
        "6050 direct morphTargetName read lost the bound marker");

    clearMorphTarget();
    h.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    assert(h.owner.documentPtr().primary is h.beta,
        "6050 live-edit-mesh precondition: the owner did not select Beta");
    snapshot = settle(ui);
    assert(snapshot.mapLines == [
            "  grin  [relative]  1/8",
            "no target bound - edits go to the base"],
        "6050 live edit mesh: Vertex Maps still list the primary captured at bind");

    h.binding.dispatchUi("layer.select", `{"index":2,"mode":"set"}`);
    assert(h.owner.documentPtr().primary is h.gamma,
        "6050 empty-maps precondition: the owner did not select Gamma");
    snapshot = settle(ui);
    assert(snapshot.bound && snapshot.title == "Gamma"
        && !snapshot.mapsHeaderDrawn && snapshot.mapLines.length == 0,
        "6050 empty maps: a mesh without morph maps drew a maps section");
}

unittest { // M10: focus and edit mesh remain deliberately distinct
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto h = new ChannelsHarness;
    h.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    h.binding.dispatchUi("layer.select", `{"index":3,"mode":"set"}`);
    assert(itemPropsTarget(h.owner.documentPtr()) is h.plane
        && h.owner.documentPtr().primary is h.beta,
        "6050 focus/edit-mesh precondition needs Plane focus and Beta primary");

    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();
    auto snapshot = settle(ui);
    assert(snapshot.title == "Plane" && snapshot.kindText == "Image Plane"
        && snapshot.providerMatchesModel,
        "6050 focus preservation: Channels did not bind one coherent image-plane focus");
    assert(snapshot.mapsHeaderDrawn,
        "6050 edit-mesh preservation (П4.1), not a law: Beta's maps header is absent");
    ui.pressAt(center(snapshot.mapsHeaderMin, snapshot.mapsHeaderMax));
    ui.release();
    snapshot = fresh(ui);
    assert(snapshot.mapLines == [
            "  grin  [relative]  1/8",
            "no target bound - edits go to the base"],
        "6050 edit-mesh preservation (П4.1), not a law: Plane focus hid Beta's maps");
}

unittest { // M3/M4: guard blocks geometry mode and permits item mode
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto h = new ChannelsHarness;
    h.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    assert(h.owner.documentPtr().primary is h.beta,
        "6050 guard precondition: the owner did not select Beta");
    clearHistory(h);
    h.activeTool = null;
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();

    auto snapshot = settle(ui);
    const floorMin = snapshot.lastRowMin;
    const floorMax = snapshot.lastRowMax;
    assert(!snapshot.transformGuardArmed
        && ui.editAt(center(floorMin, floorMax), "1.5")
        && h.beta.xform.pivot.z == 1.5f,
        "6050 guard floor: the unarmed row did not accept a write");
    assert(h.history.undo() && h.beta.xform.pivot.z == 0.0f,
        "6050 guard floor: the baseline write did not undo");

    h.activeTool = h.xfrm;
    h.owner.switchGeometryType(EditMode.Vertices);
    assert(currentSelType(h.owner.selTypeOrder) == SelType.Vertex,
        "6050 geometry guard precondition: the owner is not in vertex mode");
    snapshot = settle(ui);
    assert(snapshot.transformGuardArmed,
        "6050 guard: a transform tool over a geometry selection did not arm");
    assert(sameRect(snapshot.lastRowMin, snapshot.lastRowMax,
                    floorMin, floorMax),
        "6050 guard control: the armed probe no longer targets the floor row");
    const blockedDepth = h.history.undoEntries().length;
    assert(!ui.editAt(center(snapshot.lastRowMin, snapshot.lastRowMax), "7.5"),
        "6050 guard: the disabled row still took ActiveId");
    assert(h.history.undoEntries().length == blockedDepth
        && h.beta.xform.pivot.z == 0.0f,
        "6050 guard: the disabled row wrote history or pivot state");

    h.owner.selTypeOrder.touch(SelType.Item);
    assert(currentSelType(h.owner.selTypeOrder) == SelType.Item,
        "6050 item guard precondition: the owner is not in item mode");
    snapshot = settle(ui);
    assert(!snapshot.transformGuardArmed,
        "6050 item guard: a transform tool kept the item row disabled");
    const itemDepth = h.history.undoEntries().length;
    assert(ui.editAt(center(snapshot.lastRowMin, snapshot.lastRowMax), "4.5"),
        "6050 item guard: the enabled row did not take ActiveId");
    assert(h.history.undoEntries().length == itemDepth + 1
        && h.history.undoEntries()[$ - 1].commandName == "layer.attr"
        && h.beta.xform.pivot.z == 4.5f,
        "6050 item guard: the permitted row did not write one layer.attr");
}

unittest { // I1: two bindings over two sessions own their memo: draw A, B, A
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto a = new ChannelsHarness;
    auto b = new ChannelsHarness;
    b.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    assert(a.owner !is b.owner
        && itemPropsTarget(a.owner.documentPtr()) is a.alpha
        && itemPropsTarget(b.owner.documentPtr()) is b.beta,
        "6358 A/B/A precondition: two sessions focusing different items");
    auto rolesA = a.bind();
    auto rolesB = b.bind();
    ChannelsPanelRoles* current = &rolesA;
    resetChannelsDrawSnapshot();
    auto ui = openPanel(
        () { drawChannelsPanel(current.read, current.actions, current.state); },
        "Channels host", 1280, 1200);
    scope (exit) ui.close();

    const a1 = fresh(ui);
    assert(a1.bound && a1.title == "Alpha" && a1.memoReported
        && a1.modelRebuilt && a1.provider !is null,
        "6358 A/B/A floor: A's first draw must build its own rows");
    const a2 = fresh(ui);
    assert(a2.title == "Alpha" && a2.memoReported && !a2.modelRebuilt
        && a2.provider is a1.provider,
        "6358 memo hit floor: an unchanged item rebuilt its rows");
    current = &rolesB;
    const b1 = fresh(ui);
    assert(b1.bound && b1.title == "Beta" && b1.modelRebuilt
        && b1.provider !is a1.provider,
        "6358 A/B/A floor: B's first draw must build B's rows");
    current = &rolesA;
    const a3 = fresh(ui);
    assert(a3.bound && a3.title == "Alpha" && a3.formDrawn,
        "6358 A/B/A control: A's header after B");
    assert(a3.memoReported && !a3.modelRebuilt && a3.provider is a1.provider,
        "6358 per-binding memo: drawing B evicted A's rows and provider");
}

unittest { // I2: live header on rename, no row rebuild; focus != primary control
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto h = new ChannelsHarness;
    h.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    h.binding.dispatchUi("layer.select", `{"index":3,"mode":"set"}`);
    auto doc = h.owner.documentPtr();
    assert(itemPropsTarget(doc) is h.plane && doc.primary is h.beta,
        "6358 rename precondition needs Plane focus and Beta primary");
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();

    const first = fresh(ui);
    assert(first.bound && first.title == "Plane"
        && first.kindText == "Image Plane" && first.modelRebuilt
        && first.provider !is null,
        "6358 rename floor: Plane's rows were not built on the first draw");
    const base = fresh(ui);
    assert(!base.modelRebuilt && base.provider is first.provider
        && base.formDrawn,
        "6358 rename hit floor: an unchanged Plane rebuilt its rows");

    h.binding.dispatchUi("layer.rename", `{"index":1,"name":"BetaRenamed"}`);
    assert(h.beta.name == "BetaRenamed" && doc.primary is h.beta
        && itemPropsTarget(doc) is h.plane,
        "6358 control precondition: the primary rename did not land");
    auto snap = fresh(ui);
    assert(snap.title == "Plane" && !snap.modelRebuilt
        && snap.provider is first.provider,
        "6358 focus control: renaming the primary moved the Channels header");

    h.binding.dispatchUi("layer.rename", `{"index":3,"name":"PlaneRenamed"}`);
    assert(h.plane.name == "PlaneRenamed" && itemPropsTarget(doc) is h.plane,
        "6358 rename precondition: the focused rename did not land");
    snap = fresh(ui);
    assert(snap.bound && snap.formDrawn && snap.kindText == "Image Plane",
        "6358 rename floor: the renamed Plane's form was not drawn");
    assert(snap.title == "PlaneRenamed",
        "6358 live header: renaming the focused item left a cached title");
    assert(!snap.modelRebuilt && snap.provider is first.provider,
        "6358 rename is not a row change: the header update rebuilt the rows");
}

unittest { // I3: reorder rebuilds rows so the write follows the item
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto h = new ChannelsHarness;
    h.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    h.binding.dispatchUi("layer.select", `{"index":2,"mode":"add"}`);
    auto doc = h.owner.documentPtr();
    assert(itemPropsTarget(doc) is h.gamma && doc.primary is h.beta,
        "6358 reorder precondition needs Gamma focus and Beta primary");
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();
    const first = fresh(ui);
    assert(first.bound && first.title == "Gamma" && first.modelRebuilt,
        "6358 reorder floor: Gamma's rows were not built");
    const base = fresh(ui);
    assert(!base.modelRebuilt, "6358 reorder hit floor: unchanged Gamma rebuilt");

    h.binding.dispatchUi("layer.reorder", `{"from":0,"to":2}`);
    assert(doc.layers.length == 4 && doc.layers[0] is h.beta
        && doc.layers[1] is h.gamma && doc.layers[2] is h.alpha
        && doc.layers[3] is h.plane
        && itemPropsTarget(doc) is h.gamma && doc.primary is h.beta,
        "6358 reorder precondition: Gamma at 1, Alpha at Gamma's old 2, Beta at 0");
    const moved = fresh(ui);
    const settled = fresh(ui);
    assert(moved.title == "Gamma" && settled.formDrawn,
        "6358 reorder floor: Gamma's form was not drawn after the move");
    clearHistory(h);
    assert(ui.editAt(center(settled.lastRowMin, settled.lastRowMax), "2.5"),
        "6358 reorder write floor: Gamma's last row did not take ActiveId");
    assert(h.gamma.xform.pivot.z == 2.5f && h.alpha.xform.pivot.z == 0.0f
        && h.beta.xform.pivot.z == 0.0f,
        "6358 reorder target: the channel write missed the moved item");
    auto entries = h.history.undoEntries();
    assert(entries.length == 1
        && entries[$ - 1].args == `index:"1" attr:pivot.z value:"2.5"`,
        "6358 reorder target: layer.attr did not address Gamma's new index");
    assert(moved.memoReported && moved.modelRebuilt,
        "6358 reorder memo: an index change was served from the old rows");
}

unittest { // I4: an empty document releases the provider and rows
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    import mesh : makeCube;
    auto h = new ChannelsHarness;
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();
    const first = fresh(ui);
    assert(first.bound && first.title == "Alpha" && first.retainedReported
        && first.retainsProvider && first.retainedItem is h.alpha,
        "6358 release floor: the bound draw did not retain its memo");

    *h.owner.documentPtr() = Document.init;
    assert(h.owner.documentPtr().layers.length == 0
        && itemPropsTarget(h.owner.documentPtr()) is null,
        "6358 release precondition: the replaced document still has a focus");
    const empty = fresh(ui);
    assert(!empty.bound && !empty.formDrawn && empty.retainedReported,
        "6358 release floor: the no-item branch did not run");
    assert(!empty.retainsProvider && empty.retainedItem is null,
        "6358 no-item release: the panel state still holds the closed document");

    *h.owner.documentPtr() = Document.bootstrap(makeCube());
    h.owner.documentPtr().layers[0].name = "Fresh";
    const again = fresh(ui);
    assert(again.bound && again.title == "Fresh" && again.modelRebuilt
        && again.provider !is first.provider,
        "6358 release recovery: the next document did not rebuild the memo");
}

unittest { // I5: a payload appearing under the same item and index is a memo miss
    import image_data : ImageData;
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto h = new ChannelsHarness;
    auto logo = new Layer;
    logo.name = "Logo";
    logo.kind = ItemKind.Image;
    h.owner.document.layers ~= logo;
    h.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    h.binding.dispatchUi("layer.select", `{"index":4,"mode":"set"}`);
    auto doc = h.owner.documentPtr();
    assert(itemPropsTarget(doc) is logo && doc.primary is h.beta
        && logo.imageOrNull() is null,
        "6358 payload precondition needs a payload-less Image focus");
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();
    const first = fresh(ui);
    const base = fresh(ui);
    assert(first.modelRebuilt && !base.modelRebuilt
        && base.channelCount == 2 && base.disabledChannels == 1,
        "6358 payload floor: the payload-less Image did not memoise its base rows");
    const providerBeforeMiss = channelsFormProvider(roles.state);
    assert(providerBeforeMiss !is null && !channelsDrawSnapshot().modelRebuilt,
        "6503 provider timing: captured before the miss");
    logo.imageRef() = new ImageData();
    const grown = fresh(ui);
    assert(grown.bound && grown.title == "Logo" && grown.provider !is null,
        "6358 payload control: the Image binding was not rebuilt");
    assert(channelsFormProvider(roles.state) is providerBeforeMiss,
        "6503 provider reuse: a parameter-count miss replaced the binding's provider instead of rebinding it");
    assert(grown.modelRebuilt && grown.channelCount == 5,
        "6358 payload miss: new channels were served from the old rows");
    assert(grown.disabledChannels == 2,
        "6358 payload rebind: the readonly filename row was not re-blocked");
}


private extern (C) void igSetNextWindowCollapsed(bool collapsed, int cond);

unittest { // I6: a collapsed (hidden-tab) panel keeps only the current focus
    import mesh : makeCube;
    clearMorphTarget();
    scope (exit) clearMorphTarget();
    auto h = new ChannelsHarness;
    auto roles = h.bind();
    bool collapse = false;
    resetChannelsDrawSnapshot();
    auto ui = openPanel(() {
        igSetNextWindowCollapsed(collapse, 1);
        drawChannelsPanel(roles.read, roles.actions, roles.state);
    }, "Channels host", 1280, 1200);
    scope (exit) ui.close();
    const first = fresh(ui);
    assert(first.bound && first.retainedReported
        && first.retainedItem is h.alpha && first.retainsProvider,
        "6358 hidden floor: the expanded draw did not retain Alpha's memo");

    collapse = true;
    resetChannelsDrawSnapshot();
    ui.frame();
    auto hidden = channelsDrawSnapshot();
    assert(!hidden.drawn && hidden.retainedReported,
        "6358 hidden floor: the collapsed frame submitted its body or did not report");
    assert(hidden.retainedItem is h.alpha && hidden.retainsProvider,
        "6358 hidden control: a collapsed frame with an unchanged focus dropped its memo");

    auto next = Document.bootstrap(makeCube());
    next.layers[0].name = "Next";
    *h.owner.documentPtr() = next;
    assert(itemPropsTarget(h.owner.documentPtr()) !is null
        && itemPropsTarget(h.owner.documentPtr()) !is h.alpha,
        "6358 hidden precondition: the replacement document has its own focus");
    resetChannelsDrawSnapshot();
    ui.frame();
    hidden = channelsDrawSnapshot();
    assert(!hidden.drawn && hidden.retainedReported,
        "6358 hidden floor: the collapsed replacement frame did not report");
    assert(hidden.retainedItem is null && !hidden.retainsProvider,
        "6358 hidden release: a collapsed panel kept the replaced document's item");

    *h.owner.documentPtr() = Document.init;
    resetChannelsDrawSnapshot();
    ui.frame();
    hidden = channelsDrawSnapshot();
    assert(!hidden.drawn && hidden.retainedReported
        && hidden.retainedItem is null && !hidden.retainsProvider,
        "6358 hidden release: a collapsed no-item frame holds a memo");

    collapse = false;
    *h.owner.documentPtr() = next;
    fresh(ui);
    const shown = fresh(ui);
    assert(shown.bound && shown.title == "Next" && shown.retainsProvider,
        "6358 hidden recovery: expanding again did not rebuild the memo");
}

unittest { // provider/model negative: a valid resolver may still return the wrong member
    auto h = new ChannelsHarness;
    size_t resolves;
    auto state = channelsStateWithResolver((const(Layer) id) {
        ++resolves;
        return h.beta;
    });
    auto doc = h.owner.documentPtr();
    assert(doc.indexOf(h.alpha) < doc.layers.length
        && doc.indexOf(h.beta) < doc.layers.length
        && h.alpha !is h.beta,
        "6503 provider/model negative floor: the document needs two distinct valid members");
    assert(channelsRefreshState(state, doc, h.alpha) && resolves == 1
        && channelsFormProvider(state) !is null
        && channelsBoundItem(state) is h.beta,
        "6503 provider/model negative floor: the valid resolver result was not accepted and stored");
    // The floor above reports "accepted a valid set"; this adjacent needle
    // reports the other half, "stored an item different from the model".
    assert(!channelsProviderMatchesModel(state),
        "6503 provider/model identity: the state accepted a valid identity set but stored a different member");
}

unittest { // defensive miss: a failed resolver leaves no half-bound memo
    auto h = new ChannelsHarness;
    bool resolveLive = true;
    size_t resolves;
    auto state = channelsStateWithResolver((const(Layer) id) {
        ++resolves;
        return resolveLive ? h.alpha : null;
    });
    auto doc = h.owner.documentPtr();
    assert(channelsRefreshState(state, doc, h.alpha)
        && channelsBoundItem(state) is h.alpha && resolves == 1,
        "6503 defensive miss floor: the memo was not populated before resolver failure");

    auto first = doc.layers[0];
    doc.layers[0] = doc.layers[1];
    doc.layers[1] = first;
    resolveLive = false;
    channelsRefreshState(state, doc, h.alpha);
    assert(resolves == 2,
        "6503 defensive miss floor: the index miss did not reach the null resolver result");
    // The floor above proves the defensive arm ran; this adjacent needle proves
    // its promised post-state, rather than merely counting its provider read.
    assert(channelsFormProvider(state) is null,
        "6503 defensive miss: resolver failure left a half-bound provider in the memo");
}

unittest { // B1: the provider belongs to this binding (control for B2)
    auto h = new ChannelsHarness;
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();
    const snapshot = settle(ui);
    assert(snapshot.drawn && snapshot.bound && snapshot.formDrawn
        && snapshot.providerMatchesModel && snapshot.channelCount == 14,
        "6503 B1 floor: the binding did not draw one coherent mesh form");
    assert(channelsFormProvider(roles.state) !is null
        && channelsBoundItem(roles.state)
            is itemPropsTarget(h.owner.documentPtr()),
        "6503 B1 binding provider: state does not own the provider bound to its focus");
}

unittest { // B2: two bindings own distinct providers bound to their sessions
    auto a = new ChannelsHarness;
    auto b = new ChannelsHarness;
    b.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    const focusA = itemPropsTarget(a.owner.documentPtr());
    const focusB = itemPropsTarget(b.owner.documentPtr());
    assert(focusA !is null && focusB !is null && focusA !is focusB,
        "6503 B2 floor: the two sessions need distinct focused identities");
    auto rolesA = a.bind();
    auto rolesB = b.bind();
    ChannelsPanelRoles* current = &rolesA;
    auto ui = openPanel(
        () { drawChannelsPanel(current.read, current.actions, current.state); },
        "Channels host", 1280, 1200);
    scope (exit) ui.close();
    const snapA = settle(ui);
    current = &rolesB;
    const snapB = settle(ui);
    assert(snapA.drawn && snapA.bound && snapA.formDrawn
        && snapB.drawn && snapB.bound && snapB.formDrawn,
        "6503 B2 floor: both bindings must draw their populated forms");
    assert(channelsFormProvider(rolesA.state) !is null
        && channelsFormProvider(rolesB.state) !is null
        && channelsBoundItem(rolesA.state) is focusA
        && channelsBoundItem(rolesB.state) is focusB,
        "6503 B2 floor: each binding must remain bound to its own focus");
    assert(channelsFormProvider(rolesA.state)
            !is channelsFormProvider(rolesB.state),
        "6503 per-binding provider: two Channels bindings share one provider");
}

unittest { // B3: equal-looking items remain distinct memo identities
    import mesh : makeCube;
    auto h = new ChannelsHarness;
    h.alpha.name = "Same";
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();
    const before = settle(ui);
    const oldFocus = channelsBoundItem(roles.state);
    assert(before.bound && before.formDrawn && before.channelCount == 14
        && oldFocus is h.alpha,
        "6503 B3 floor: the old equal-looking mesh was not bound");

    auto next = Document.bootstrap(makeCube());
    next.layers[0].name = "Same";
    const newFocus = next.layers[0];
    *h.owner.documentPtr() = next;
    const after = fresh(ui);
    assert(after.bound && after.formDrawn && after.modelRebuilt
        && after.channelCount == before.channelCount,
        "6503 B3 floor: equal row counts must survive document replacement");
    assert(channelsBoundItem(roles.state) is newFocus
        && channelsBoundItem(roles.state) !is oldFocus,
        "6503 memo identity: equal item contents hid a changed identity");
}

unittest { // B4: the transform guard crosses only the narrow state door
    auto h = new ChannelsHarness;
    auto roles = h.bind();
    auto ui = openChannels(roles);
    scope (exit) ui.close();
    const snapshot = settle(ui);
    assert(snapshot.bound && snapshot.formDrawn && snapshot.channelCount == 14
        && channelsFormProvider(roles.state) !is null,
        "6503 B4 floor: the state needs a populated provider");
    channelsArmTransformGuard(roles.state, false, SelType.Vertex);
    assert(!channelsTransformGuardArmed(roles.state),
        "6503 B4 floor: no transform tool must leave rows enabled");
    channelsArmTransformGuard(roles.state, true, SelType.Vertex);
    assert(channelsTransformGuardArmed(roles.state),
        "6503 transform interlock: the item transform rows did not grey while a transform tool is up over a geometry selection");
    channelsArmTransformGuard(roles.state, true, SelType.Item);
    assert(!channelsTransformGuardArmed(roles.state),
        "6503 transform interlock: item selection kept its own transform rows grey");
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6050 census missing source marker " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6050 census found no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "6050 census found unterminated body after " ~ marker);
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

private struct ChannelsStripSignalRow {
    string path;
    size_t casts, traits, tupleofs, mixins, unions, memcpys, memmoves;
}

private enum ChannelsStripSignalRow[] kChannelsStripSignalLedger = [
    ChannelsStripSignalRow("source/ui/channels_panel.d", 1, 0, 0, 0, 0, 0, 0),
    ChannelsStripSignalRow("source/ui/channel_rows.d", 0, 0, 0, 0, 0, 0, 0),
];

private enum kChannelsStripSignalTokens =
    ["cast", "__traits", "tupleof", "mixin", "union", "memcpy", "memmove"];
static assert(kChannelsStripSignalTokens ==
        ["cast", "__traits", "tupleof", "mixin", "union", "memcpy", "memmove"],
    "6503 strip signal token roster changed — every measured column must remain in the exact scan below");

unittest { // M6a-d and the retired EditorApp path: production source census
    import tests.unit.census_symbols : blankNonCode;

    const rawApp = readText(repoRoot.buildPath("source", "app.d"));
    const rawChannels = readText(repoRoot.buildPath(
        "source", "ui", "channels_panel.d"));
    const rawRows = readText(repoRoot.buildPath(
        "source", "ui", "channel_rows.d"));
    const app = blankNonCode(rawApp);
    const channels = blankNonCode(rawChannels);
    const panels = blankNonCode(readText(repoRoot.buildPath(
        "source", "ui", "panels.d")));
    assert(rawChannels.length > 5_000,
        "6050 source population: channels panel source is unexpectedly small");

    string[] actualStripPaths;
    string[] rawStripSources;
    size_t stripSourceBytes;
    foreach (row; kChannelsStripSignalLedger) {
        actualStripPaths ~= row.path;
        auto raw = readText(repoRoot.buildPath(row.path));
        rawStripSources ~= raw;
        stripSourceBytes += raw.length;
    }
    assert(kChannelsStripSignalLedger.length == 2
        && rawStripSources.length == 2 && rawChannels.length + rawRows.length > 30_000
        && stripSourceBytes > 30_000,
        "6503 strip signal population: expected two populated production files over 30000 bytes");

    // Needle: name the exact file and spelling before any structural or total
    // pin can intercept it. New bypass spellings belong in this loop first.
    foreach (i, row; kChannelsStripSignalLedger) {
        const code = blankNonCode(rawStripSources[i]);
        immutable recorded = [row.casts, row.traits, row.tupleofs, row.mixins,
                              row.unions, row.memcpys, row.memmoves];
        foreach (column, token; kChannelsStripSignalTokens) {
            const actual = identifierCount(code, token);
            assert(actual == recorded[column],
                "6503 strip signal: " ~ row.path ~ " " ~ token ~ " = "
                ~ actual.to!string ~ ", recorded "
                ~ recorded[column].to!string
                ~ " — a row may only FALL; if the spelling left, lower it "
                ~ "in this commit; if it appeared, treat that as a finding");
        }
    }

    // Structural checks follow the needle: they prove the exact scan still
    // covers the intended two files and all seven recorded columns.
    auto sortedStripPaths = actualStripPaths.dup;
    sortedStripPaths.sort;
    auto expectedStripPaths = ["source/ui/channel_rows.d",
                               "source/ui/channels_panel.d"];
    expectedStripPaths.sort;
    assert(sortedStripPaths == expectedStripPaths,
        "6503 strip signal shape: the ledger does not name exactly the two owned files");
    foreach (path; expectedStripPaths) {
        size_t appearances;
        foreach (row; kChannelsStripSignalLedger)
            if (row.path == path) ++appearances;
        assert(appearances == 1,
            "6503 strip signal shape: " ~ path ~ " appears "
            ~ appearances.to!string ~ " times instead of once");
    }
    foreach (row; kChannelsStripSignalLedger) {
        immutable recorded = [row.casts, row.traits, row.tupleofs, row.mixins,
                              row.unions, row.memcpys, row.memmoves];
        assert(recorded.length == kChannelsStripSignalTokens.length,
            "6503 strip signal token roster and recorded columns diverged");
    }

    // Pin: aggregate totals come last, after the exact file/token diagnosis.
    size_t stripCasts, stripTraits, stripTupleofs, stripMixins, stripUnions,
           stripMemcpys, stripMemmoves;
    foreach (row; kChannelsStripSignalLedger) {
        stripCasts += row.casts;
        stripTraits += row.traits;
        stripTupleofs += row.tupleofs;
        stripMixins += row.mixins;
        stripUnions += row.unions;
        stripMemcpys += row.memcpys;
        stripMemmoves += row.memmoves;
    }
    assert(stripCasts == 1 && stripTraits == 0 && stripTupleofs == 0
        && stripMixins == 0 && stripUnions == 0 && stripMemcpys == 0
        && stripMemmoves == 0,
        "6503 strip signal totals changed: cast=" ~ stripCasts.to!string
        ~ " __traits=" ~ stripTraits.to!string ~ " tupleof="
        ~ stripTupleofs.to!string ~ " mixin=" ~ stripMixins.to!string
        ~ " union=" ~ stripUnions.to!string
        ~ " memcpy=" ~ stripMemcpys.to!string
        ~ " memmove=" ~ stripMemmoves.to!string);
    foreach (forbidden; ["EditorApp", "editor_app", "ui.panels",
                         "ui.layer_list_panel", "with (", "activeMesh"])
        assert(channels.count(forbidden) == 0,
            "6050 role boundary: channels panel regained " ~ forbidden);
    assert(collapseWhitespace(channels).count(
            "void drawChannelsPanel(ChannelsReadRole read, ChannelsActions actions, ChannelsPanelState state)") == 1
        && channels.count(
            "private void drawVertexMapsSection(const(Mesh)* m)") == 1,
        "6050 panel signatures: the two narrow draw entries are not unique");

    const binder = bodyAt(channels,
        "ChannelsPanelRoles bindChannelsPanel(Session* owner,");
    const drawBody = bodyAt(channels, "void drawChannelsPanel(");
    const readRole = bodyAt(channels, "struct ChannelsReadRole");
    const actions = bodyAt(channels, "struct ChannelsActions");
    const stateBody = bodyAt(channels, "final class ChannelsPanelState");
    assert(drawBody.count("recordChannelsBegin") > 0
        && drawBody.count("recordChannelsRetained") > 0
        && drawBody.count("drawVertexMapsSection") > 0,
        "6503 draw region: the Channels draw body no longer spans its form and maps sections");
    assert(drawBody.count("struct ChannelsActions") == 0
        && drawBody.count("final class ChannelsPanelState") == 0
        && drawBody.count("bindChannelsPanel") == 0,
        "6503 draw region: the Channels draw body swallowed a role, state, or binder");
    assert(actions.count("drawChannelForm") > 0
        && actions.count("forms_.draw") > 0,
        "6503 action region: the action role no longer spans its form write");
    assert(actions.count("drawChannelsPanel") == 0
        && actions.count("bindChannelsPanel") == 0,
        "6503 action region: the action-role region swallowed the draw body");
    assert(readRole.count("documentPtr") > 0
        && readRole.count("editMesh") > 0
        && readRole.count("activeTool_") > 0,
        "6503 read region: the read role no longer spans its live readers");
    assert(readRole.count("interactive_") == 0
        && readRole.count("provider_") == 0,
        "6503 read region: the read role swallowed a write capability");
    assert(stateBody.count("providerMatchesModel") > 0
        && stateBody.count("armTransformGuard") > 0
        && stateBody.count("dropMemo") > 0,
        "6503 state region: the memo state no longer spans its narrow doors");
    assert(stateBody.count("drawChannelsPanel") == 0
        && stateBody.count("bindChannelsPanel") == 0,
        "6503 state region: the memo state swallowed draw or binder code");
    assert(binder.count("ChannelsPanelRoles") > 0
        && binder.count("liveItem") > 0,
        "6503 binder region: the live resolver is no longer composed by the binder");
    assert(binder.count("drawChannelsPanel") == 0
        && binder.count("final class ChannelsPanelState") == 0,
        "6503 binder region: the binder swallowed state or draw code");
    const liveResolver = bodyAt(channels,
        "private Layer liveItem(Session* owner, const(Layer) id)");
    assert(liveResolver.count("indexOf") == 1,
        "6503 live resolver: identity must be resolved by document membership, not byte laundering");
    assert(binder.count("binding.") == 1
        && binder.count("&binding.dispatchUi") == 0
        && binder.count("&binding.dispatchInteractiveUi") == 1,
        "6050 binder census: Channels must bind only the interactive UI method");
    assert(binder.count("new ChannelsPanelState") == 1
        && channels.count("new ChannelsPanelState") == 1
        && identifierCount(channels, "static") == 0,
        "6358 state census: bind owns the only construction and draw has no static; A/B/A covers a module singleton");
    assert(identifierCount(drawBody, "owner_") == 0,
        "6503 read fence: the Channels draw body names the read role's private session");
    assert(identifierCount(drawBody, "documentPtr") == 0,
        "6503 read fence: the Channels draw body reads the live document directly");
    assert(identifierCount(drawBody, "resolve_") == 0,
        "6503 write fence: the Channels draw body reached the memo's item resolver");
    assert(identifierCount(drawBody, "params") == 0
        && identifierCount(drawBody, "setLayer") == 0,
        "6503 write fence: the Channels draw body reached writable parameter pointers");
    assert(identifierCount(drawBody, "base") == 0,
        "6503 provider fence: the Channels draw body regained the broad base-provider door");
    assert(identifierCount(drawBody, "provider_") == 1,
        "6503 provider handle fence: the Channels draw body must name the provider exactly once, only to hand it to the action side");
    assert(identifierCount(drawBody, "static") == 0
        && identifierCount(drawBody, "cast") == 0,
        "6503 draw fence: the Channels draw body gained static state or a qualifier-removing cast");
    assert(identifierCount(channels, "documentPtr") == 2,
        "6503 file census: a new reader of the live document appeared");
    assert(identifierCount(channels, "base") == 0,
        "6503 file census: the broad base-provider door returned");
    assert(identifierCount(channels, "resolve_") == 3,
        "6503 file census: a new reader of the binding's private resolver appeared");
    assert(identifierCount(channels, "provider_") == 23,
        "6503 file census: a new reader of the binding's private provider appeared");
    assert(drawBody.count(
            "recordChannelsProvider(state.providerMatchesModel());") == 1
        && drawBody.count(
            "state.armTransformGuard(read.transformToolActive(),") == 1,
        "6503 narrow-door census: provider coherence or the transform guard bypassed state");
    const retainAt = drawBody.indexOf("state.retainOnly(item);");
    const drawBeginAt = drawBody.indexOf("ImGui.Begin(");
    assert(drawBody.count("const title = channelsHeaderName(item);") == 1
        && drawBody.count("ImGui.TextUnformatted(title);") == 1
        && drawBody.count("recordChannelsHeader(title, state.model_.kindText);") == 1
        && drawBody.count("state.retainOnly(item);") == 1
        && retainAt >= 0 && drawBeginAt > retainAt
        && drawBody.count(".title") == 0,
        "6358 draw census: computed, drawn, or recorded live header, or pre-Begin retention changed");
    assert(readRole.count("owner_.documentPtr()") == 1
        && readRole.count("owner_.editMesh()") == 1
        && readRole.count("owner_.selTypeOrder") == 1
        && readRole.count("cast(TransformTool) activeTool_()") == 1,
        "6050 read-role census: a live owner/tool read was duplicated or replaced");
    assert(actions.count("forms_.draw(form, provider, null, interactive_,") == 1
        && actions.count("void delegate(string, string) interactive_;") == 1,
        "6050 action census: the private interactive-only writer shape changed");
    assert(channels.count("itemPropsTarget(read.document())") == 1
        && channels.count("actions.drawChannelForm(state.model_.form, state.provider_);") == 1
        && channels.count("drawVertexMapsSection(read.editMesh());") == 1,
        "6050 draw census: a role consumer bypassed its narrow capability");
    assert(panels.count("drawChannelsPanel") == 0
        && panels.count("drawVertexMapsSection") == 0,
        "6050 retired panel path: ui.panels still owns a Channels function");

    size_t sourceFiles;
    size_t oldSignatures;
    size_t toolGetterAssignments;
    foreach (entry; dirEntries(repoRoot.buildPath("source"), "*.d",
                               SpanMode.depth)) {
        ++sourceFiles;
        const code = blankNonCode(readText(entry.name));
        oldSignatures += code.count("drawChannelsPanel(EditorApp");
        toolGetterAssignments += code.matchAll(
            regex(`getActiveTool\s*=[^=>]`)).walkLength;
    }
    assert(sourceFiles > 500 && oldSignatures == 0,
        "6050 source census: the EditorApp Channels overload survived");
    assert(toolGetterAssignments == 1,
        "6050 live getter census: getActiveTool has more than one writer");

    const flatApp = collapseWhitespace(app);
    enum bindCall =
        "auto channelsPanelRoles = bindChannelsPanel(sessionOwner, commandBinding, formsPanel, toolHost.getActiveTool);";
    enum drawCall =
        "drawChannelsPanel(channelsPanelRoles.read, channelsPanelRoles.actions, channelsPanelRoles.state);";
    assert(identifierCount(app, "bindChannelsPanel") == 2
        && identifierCount(app, "drawChannelsPanel") == 2
        && identifierCount(app, "channelsPanelRoles") == 4
        && identifierCount(app, "ChannelsPanelState") == 0
        && flatApp.count(bindCall) == 1
        && flatApp.count(drawCall) == 1
        && flatApp.count("import ui.channels_panel : bindChannelsPanel;") == 1
        && flatApp.count("import ui.channels_panel : drawChannelsPanel;") == 1,
        "6050 production calls: the complete bind/draw texts or identifiers changed");
    const commandBindingAt = flatApp.indexOf(
        "commandBinding = new ApplicationCommandBinding(");
    const bindAt = flatApp.indexOf(bindCall);
    enum frameMarker = "void frame() {";
    assert(flatApp.count(frameMarker) == 1,
        "6050 production frame anchor must occur exactly once");
    const frameAt = flatApp.indexOf(frameMarker);
    const frameBody = bodyAt(flatApp, frameMarker);
    const guardAt = frameBody.indexOf(
        "if (!command.g_testMode || g_channelsShown) {");
    const drawAt = frameBody.indexOf(drawCall);
    assert(commandBindingAt >= 0 && bindAt >= 0 && frameAt >= 0
        && guardAt >= 0 && drawAt >= 0
        && commandBindingAt < bindAt && bindAt < frameAt
        && guardAt < drawAt,
        "6050 production placement: bind/draw no longer bracket the frame loop guard");

    enum uiClosure =
        "uiCommandDelegate = (string id, string paramsJson) { commandBinding.dispatchUi(id, paramsJson); };";
    enum interactiveClosure =
        "formsInteractiveDispatch = (string id, string paramsJson) { commandBinding.dispatchInteractiveUi(id, paramsJson); };";
    assert(flatApp.count(uiClosure) == 1,
        "6050 equivalence: the application UI closure changed unexpectedly");
    assert(flatApp.count(interactiveClosure) == 1,
        "6050 equivalence: bindChannelsPanel's &binding.dispatchInteractiveUi stands for EditorApp.formsInteractiveDispatch only while app.d's closure is exactly this");
    assert(app.matchAll(regex(`\bcommandBinding\s*=\s*[^=]`)).walkLength == 1
        && app.matchAll(regex(`\bformsPanel\s*=\s*[^=]`)).walkLength == 2
        && flatApp.count("auto formsPanel = new forms_render.FormsPanel();") == 1
        && flatApp.count(
            "formsPanel.setTweakEndHook(() { commandBinding.endInteractiveTweak(); });") == 1
        && flatApp.count("toolHost.getActiveTool = () => activeTool;") == 1,
        "6050 binder equivalence: a once-bound production source gained another writer");

    const chromePush = rawChannels.indexOf("pushPanelChromeStyle();");
    const chromePop = rawChannels.indexOf("scope(exit) popPanelChromeStyle();");
    const endAt = rawChannels.indexOf("scope(exit) ImGui.End();");
    const beginAt = rawChannels.indexOf("if (ImGui.Begin(\"Channels\")) {");
    assert(chromePush >= 0 && chromePush < chromePop && chromePop < endAt
        && endAt < beginAt
        && rawChannels.count("pushPanelChromeStyle();") == 1
        && rawChannels.count("scope(exit) popPanelChromeStyle();") == 1
        && rawChannels.count("scope(exit) ImGui.End();") == 1
        && rawChannels.count("if (ImGui.Begin(\"Channels\")) {") == 1,
        "6050 panel chrome: extraction changed Begin/End/style ordering");
    assert(rawChannels.count("ImGui.CollapsingHeader(\"Vertex Maps\")") == 1
        && rawChannels.count("no target bound - edits go to the base") == 1,
        "6050 panel labels: Vertex Maps header or unbound text changed");
}
