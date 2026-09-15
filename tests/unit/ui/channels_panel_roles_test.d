module tests.unit.ui.channels_panel_roles_test;

import std.algorithm : count;
import std.file : SpanMode, dirEntries, readText;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.range : walkLength;
import std.regex : matchAll, regex;
import std.string : indexOf;

import application_command_binding : ApplicationCommandBinding;
import command : Command;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.layer.commands : LayerAttr, LayerSelect;
import document : Document, ItemKind, Layer;
import edit_session : EditSession;
import editmode : EditMode;
import forms_render : FormsPanel;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import image_data : ImagePlaneData;
import layer_params : itemPropsTarget;
import math : Vec3;
import mesh : MapKind, Mesh, makeCube;
import mesh_gpu : GpuMesh;
import morph_target : clearMorphTarget, setMorphTarget;
import registry : Registry;
import seltype : SelType, currentSelType;
import session_owner : Session;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import tools.transform.xfrm_transform : XfrmTransformTool;
import ui.channels_panel : ChannelsDrawSnapshot, ChannelsPanelRoles,
    bindChannelsPanel, channelsDrawSnapshot, drawChannelsPanel,
    resetChannelsDrawSnapshot;
import ui.discard_guard : GuardRecord;
import view : View;
import d_imgui.imgui_h : ImVec2;

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
        registry.commandFactories["layer.select"] = () => cast(Command)
            new LayerSelect(&owner.editMesh(), view, owner.editMode,
                            owner.documentPtr(), null);
        registry.commandFactories["layer.attr"] = () => cast(Command)
            new LayerAttr(&owner.editMesh(), view, owner.editMode,
                          owner.documentPtr(), null);

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
        () { drawChannelsPanel(roles.read, roles.actions); },
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

unittest { // M6a-d and the retired EditorApp path: production source census
    import tests.unit.census_symbols : blankNonCode;

    const rawApp = readText(repoRoot.buildPath("source", "app.d"));
    const rawChannels = readText(repoRoot.buildPath(
        "source", "ui", "channels_panel.d"));
    const app = blankNonCode(rawApp);
    const channels = blankNonCode(rawChannels);
    const panels = blankNonCode(readText(repoRoot.buildPath(
        "source", "ui", "panels.d")));
    assert(rawChannels.length > 5_000,
        "6050 source population: channels panel source is unexpectedly small");
    foreach (forbidden; ["EditorApp", "editor_app", "ui.panels",
                         "ui.layer_list_panel", "with (", "activeMesh"])
        assert(channels.count(forbidden) == 0,
            "6050 role boundary: channels panel regained " ~ forbidden);
    assert(channels.count(
            "void drawChannelsPanel(ChannelsReadRole read, ChannelsActions actions)") == 1
        && channels.count(
            "private void drawVertexMapsSection(const(Mesh)* m)") == 1,
        "6050 panel signatures: the two narrow draw entries are not unique");

    const binder = bodyAt(channels,
        "ChannelsPanelRoles bindChannelsPanel(Session* owner,");
    assert(binder.count("binding.") == 1
        && binder.count("&binding.dispatchUi") == 0
        && binder.count("&binding.dispatchInteractiveUi") == 1,
        "6050 binder census: Channels must bind only the interactive UI method");
    const readRole = bodyAt(channels, "struct ChannelsReadRole");
    assert(readRole.count("owner_.documentPtr()") == 1
        && readRole.count("owner_.editMesh()") == 1
        && readRole.count("owner_.selTypeOrder") == 1
        && readRole.count("cast(TransformTool) activeTool_()") == 1,
        "6050 read-role census: a live owner/tool read was duplicated or replaced");
    const actions = bodyAt(channels, "struct ChannelsActions");
    assert(actions.count("forms_.draw(form, provider, null, interactive_,") == 1
        && actions.count("void delegate(string, string) interactive_;") == 1,
        "6050 action census: the private interactive-only writer shape changed");
    assert(channels.count("itemPropsTarget(read.document())") == 1
        && channels.count("actions.drawChannelForm(model.form, prov);") == 1
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
        "drawChannelsPanel(channelsPanelRoles.read, channelsPanelRoles.actions);";
    assert(identifierCount(app, "bindChannelsPanel") == 2
        && identifierCount(app, "drawChannelsPanel") == 2
        && identifierCount(app, "channelsPanelRoles") == 3
        && flatApp.count(bindCall) == 1
        && flatApp.count(drawCall) == 1
        && flatApp.count("import ui.channels_panel : bindChannelsPanel;") == 1
        && flatApp.count("import ui.channels_panel : drawChannelsPanel;") == 1,
        "6050 production calls: the complete bind/draw texts or identifiers changed");
    const commandBindingAt = flatApp.indexOf(
        "commandBinding = new ApplicationCommandBinding(");
    const bindAt = flatApp.indexOf(bindCall);
    const loopAt = flatApp.indexOf("while (running) {");
    const guardAt = flatApp.indexOf(
        "if (!command.g_testMode || g_channelsShown) {");
    const drawAt = flatApp.indexOf(drawCall);
    assert(commandBindingAt >= 0 && bindAt >= 0 && loopAt >= 0
        && guardAt >= 0 && drawAt >= 0
        && commandBindingAt < bindAt && bindAt < loopAt
        && loopAt < guardAt && guardAt < drawAt,
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
