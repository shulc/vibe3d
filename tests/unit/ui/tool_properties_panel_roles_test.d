module tests.unit.ui.tool_properties_panel_roles_test;

import std.algorithm : canFind, count;
import std.exception : assertThrown;
import std.file : SpanMode, dirEntries, readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : fabs;
import std.meta : staticIndexOf;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;
import std.traits : Parameters, ReturnType, Unqual, fullyQualifiedName,
    isDelegate, isFunctionPointer;

import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiKey, ImVec2;
import application_command_binding : ApplicationCommandBinding;
import command : Command, g_testMode;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.tool.attr : ToolAttrCommand;
import commands.tool.host : ToolHost;
import commands.tool.pipe : ToolPipeAttrCommand;
import commands.mesh.vertex_edit : MeshVertexEdit;
import edit_session : EditSession;
import editmode : EditMode;
import forms : BindingException, Form, Row, g_forms, g_formsPanelEnabled,
    loadForms, planForm;
import forms_render : DispatchFn, FormsPanel, InteractiveDispatchFn;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import input_zones : clearZones;
import math : Vec3;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import params : Param, ParamProvider;
import property_panel : PanelIdKind, PropertyPanel, toolPropsIdsJson;
import registry : Registry;
import seltype : SelType;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import toolpipe.stage : NopStage, Stage, TaskCode;
import toolpipe.stages.falloff : FalloffStage;
import tools.transform.xfrm_transform : XfrmTransformTool;
static import ui.tool_properties_panel;
import ui.tool_properties_panel : ToolPropertiesActions,
    ToolPropertiesPanelRoles, ToolPropertiesReadRole,
    ToolPropertiesStageInfo, bindToolPropertiesPanel,
    drawToolPropertiesPanel;
import view : View;

private string memberList(T)() {
    string result = "[";
    bool first = true;
    static foreach (name; __traits(allMembers, T)) {
        if (!first) result ~= ",";
        result ~= "\"" ~ name ~ "\"";
        first = false;
    }
    return result ~ "]";
}

private enum memberPinSuffix = ". The lists are declaration-ORDER sensitive "
    ~ "and are NOT a generated ledger: a new name here is a FINDING — a "
    ~ "member was added, renamed, or reordered. Do not paste the actual list "
    ~ "over the expected one until you can say which of the three happened "
    ~ "and why the boundary still holds.";

static assert([__traits(allMembers, ToolPropertiesReadRole)] == [
        "activeTool_", "activeToolId_", "__ctor", "hasActiveTool",
        "activeToolId", "enabledStages"],
    "6504 G1 ToolPropertiesReadRole member set changed: "
        ~ memberList!ToolPropertiesReadRole ~ memberPinSuffix);
static assert([__traits(allMembers, ToolPropertiesActions)] == [
        "dispatch_", "interactive_", "forms_", "session_", "activeTool_",
        "__ctor", "drawToolForm", "drawFormedToolCustom", "drawToolParams",
        "drawToolCustom", "stageHasPanelParams", "drawStageBody"],
    "6504 G1 ToolPropertiesActions member set changed: "
        ~ memberList!ToolPropertiesActions ~ memberPinSuffix);
static assert([__traits(allMembers, ToolPropertiesPanelRoles)] == [
        "read_", "actions_", "__ctor", "read", "actions"],
    "6504 G1 ToolPropertiesPanelRoles member set changed: "
        ~ memberList!ToolPropertiesPanelRoles ~ memberPinSuffix);
static assert([__traits(allMembers, ToolPropertiesStageInfo)] == [
        "id", "displayName", "taskCode"],
    "6504 G1 ToolPropertiesStageInfo member set changed: "
        ~ memberList!ToolPropertiesStageInfo ~ memberPinSuffix);
static assert([__traits(allMembers, ui.tool_properties_panel)] == [
        "object", "ImGui", "d_imgui", "ToolPropertiesStageInfo",
        "g_enabledStageInfoScratch", "ToolPropertiesReadRole", "ToolPropertiesActions",
        "ToolPropertiesPanelRoles", "resolveStage",
        "bindToolPropertiesPanel", "kToolPropsTabMain",
        "kToolPropsTabSnapping", "g_toolPropsTab", "kSnappingHasOwnTab",
        "warnStageFormOnce", "drawToolPropertiesPanel"],
    "6504 G1 ui.tool_properties_panel member set changed: "
        ~ memberList!ui.tool_properties_panel ~ memberPinSuffix);

private enum string[] kCapabilityExempt = [
    "property_panel.PropertyPanel"
];

private bool capabilityExempt(T)() {
    foreach (name; kCapabilityExempt)
        if (name == fullyQualifiedName!T) return true;
    return false;
}

// Cycle-aware rather than depth-capped: revisiting a type ends that path, but
// an arbitrarily deep acyclic wrapper remains visible to the boundary rule.
private template CarriesCapability(X, Seen...) {
    private template Decayed(Y) {
        static if (is(Y : V[K], V, K))  alias Decayed = Unqual!V;
        else static if (is(Y : E[], E)) alias Decayed = Unqual!E;
        else static if (is(Y : E*, E))  alias Decayed = Unqual!E;
        else                            alias Decayed = Unqual!Y;
    }
    alias D = Decayed!X;
    static if (is(X == void*) || is(Unqual!X == void*))
        enum CarriesCapability = true;
    else static if (is(D : ParamProvider) || is(D == Param))
        enum CarriesCapability = true;
    else static if (capabilityExempt!D)
        enum CarriesCapability = false;
    else static if (is(D == Object))
        enum CarriesCapability = true;
    else static if (staticIndexOf!(D, Seen) >= 0)
        enum CarriesCapability = false;
    else static if (isDelegate!D || isFunctionPointer!D)
        enum CarriesCapability = CarriesCapability!(ReturnType!D, Seen, D);
    else static if (is(D == struct) || is(D == union)
                    || is(D == class) || is(D == interface)) {
        private bool anyField() {
            bool hit;
            static foreach (F; typeof(D.tupleof))
                if (CarriesCapability!(F, Seen, D)) hit = true;
            return hit;
        }
        enum CarriesCapability = anyField();
    } else
        enum CarriesCapability = false;
}

private enum bool generatedMember(string name) =
    name == "this" || name == "__ctor" || name == "__dtor"
    || name == "__xdtor" || name == "__postblit"
    || name == "__xpostblit" || name == "opAssign" || name == "Monitor"
    || name == "toString" || name == "toHash" || name == "opCmp"
    || name == "opEquals" || name == "factory";

private template CapabilityReturns(T, bool allPrivate) {
    private string[] collect() {
        string[] bad;
        static foreach (name; __traits(allMembers, T)) {{
            static if (!generatedMember!name) {
                static if (allPrivate
                        || (__traits(compiles, __traits(getVisibility,
                                __traits(getMember, T, name)))
                            && __traits(getVisibility,
                                __traits(getMember, T, name)) != "private")) {
                    static if (__traits(isTemplate,
                            __traits(getMember, T, name)))
                        bad ~= name ~ ":TEMPLATE";
                    else static if (__traits(compiles,
                            ReturnType!(__traits(getMember, T, name)))) {
                        static if (CarriesCapability!(ReturnType!(
                                __traits(getMember, T, name))))
                            bad ~= name;
                    } else static if (__traits(compiles,
                            typeof(__traits(getMember, T, name)))) {
                        static if (CarriesCapability!(typeof(
                                __traits(getMember, T, name))))
                            bad ~= name;
                    } else
                        bad ~= name ~ ":UNCLASSIFIABLE";
                }
            }
        }}
        return bad;
    }
    enum CapabilityReturns = collect();
}

private template CapabilityParams(T, bool withCtor) {
    private string[] collect() {
        string[] bad;
        static foreach (name; __traits(allMembers, T)) {{
            static if (!generatedMember!name || (withCtor && name == "__ctor")) {
                static if (__traits(compiles, __traits(getVisibility,
                            __traits(getMember, T, name)))
                        && __traits(getVisibility,
                            __traits(getMember, T, name)) != "private") {
                    static if (__traits(compiles,
                            Parameters!(__traits(getMember, T, name)))) {
                        static foreach (i, P; Parameters!(
                                __traits(getMember, T, name)))
                            static if (CarriesCapability!P)
                                bad ~= name ~ "#" ~ i.stringof;
                    }
                }
            }
        }}
        return bad;
    }
    enum CapabilityParams = collect();
}

private string capabilityList(string[] names) {
    string result = "[";
    foreach (i, name; names) {
        if (i) result ~= ",";
        result ~= "\"" ~ name ~ "\"";
    }
    return result ~ "]";
}

private enum readReturns = CapabilityReturns!(ToolPropertiesReadRole, true);
private enum readParams = CapabilityParams!(ToolPropertiesReadRole, true);
private enum actionReturns = CapabilityReturns!(ToolPropertiesActions, false);
private enum actionParams = CapabilityParams!(ToolPropertiesActions, false);
static assert(readReturns.length == 0,
    "6504 C10 R1: the read role hands back a capability: "
        ~ capabilityList(readReturns));
static assert(readParams.length == 0,
    "6504 C10 R2: the read role asks its binder for a capability: "
        ~ capabilityList(readParams));
static assert(actionReturns.length == 0,
    "6504 C10 R1: the action door hands a capability back to the body: "
        ~ capabilityList(actionReturns));
static assert(actionParams.length == 0,
    "6504 C10 R2: the action door asks the drawing body for a capability: "
        ~ capabilityList(actionParams));
static assert(!CarriesCapability!ToolPropertiesStageInfo,
    "6504 C10 descriptor: ToolPropertiesStageInfo carries a capability");
static assert(CapabilityReturns!(PropertyPanel, false).length == 0,
    "6504 exemption premise: PropertyPanel gained a public capability return");
static assert(kCapabilityExempt.length == 1,
    "6504 exemption list grew");

private class CapabilityBox { Tool tool; }
private struct CapabilityClassTrap { CapabilityBox box; }
private struct CapabilityObjectTrap { Object opaque; }
private struct CapabilityVoidPointerTrap { void* opaque; }
private struct CapabilityAaTrap { Stage[string] stages; }
private struct CapabilityTemplateTrap { T get(T = Tool)() { return null; } }
private struct CapabilityExportTrap { export Tool tool; }
private struct CapabilityLevel1 { Tool delegate() value; }
private struct CapabilityLevel2 { CapabilityLevel1 value; }
private struct CapabilityLevel3 { CapabilityLevel2 value; }
private struct CapabilityLevel4 { CapabilityLevel3 value; }
private struct CapabilityLevel5 { CapabilityLevel4 value; }
private struct CapabilityDeepTrap { CapabilityLevel5 value; }
private struct CapabilityParamPointerTrap { Param* row; }
private struct CapabilityPrivateTrap { private Tool cached_; }
private struct CapabilityProviderSliceTrap { ParamProvider[] providers; }
private struct CapabilityNamespace {
    struct PropertyPanel { Stage stage; }
}

static assert(CarriesCapability!CapabilityClassTrap
    && CarriesCapability!CapabilityObjectTrap
    && CarriesCapability!CapabilityVoidPointerTrap
    && CarriesCapability!CapabilityAaTrap
    && CapabilityReturns!(CapabilityTemplateTrap, true).length == 1
    && CarriesCapability!CapabilityExportTrap
    && CarriesCapability!CapabilityDeepTrap
    && CarriesCapability!CapabilityParamPointerTrap
    && CapabilityReturns!(CapabilityPrivateTrap, true).length == 1
    && CarriesCapability!CapabilityProviderSliceTrap,
    "6504 C10-S instrument self-test: the rule missed a capability wrapper");
static assert(CarriesCapability!(CapabilityNamespace.PropertyPanel),
    "6504 C10-S instrument self-test: the rule cleared a homonym of the exempt type");
static assert(!CarriesCapability!Form && !CarriesCapability!Row
    && !CarriesCapability!ToolPropertiesStageInfo
    && !CarriesCapability!DispatchFn && !CarriesCapability!string
    && !CarriesCapability!FormsPanel,
    "6504 C10-S instrument self-test: the rule rejected a planned value type");

static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    Tool tool = role.activeTool();
}), "6504 C10: the read role must not return the active Tool");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    role.activeTool().activate();
}), "6504 C10: the read role must not activate a Tool");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    role.activeTool().deactivate();
}), "6504 C10: the read role must not deactivate a Tool");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    role.activeTool().drawProperties();
}), "6504 C10: the read role must not custom-draw a Tool");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    role.activeTool().onParamChanged("x");
}), "6504 C10: the read role must not write a Tool parameter");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    auto params = role.activeTool().params();
}), "6504 C10: the read role must not expose raw Param pointers");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    auto stages = role.pipeStages();
}), "6504 C10: the read role must not return pipeline stages");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    role.pipeStages()[0].setAttr("type", "linear");
}), "6504 C10: the read role must not mutate a pipeline stage");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    (cast(Stage) role.pipeStages()[0]).setAttr("type", "linear");
}), "6504 C10: casting must not recover a mutable pipeline stage");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    role.enabledStages()[0].setAttr("type", "linear");
}), "6504 C10: stage metadata must not be a Stage");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    role.enabledStages()[0].drawProperties();
}), "6504 C10: stage metadata must not expose custom draw");
static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    role.activeToolId() = "";
}), "6060 C10: the read role must not expose a mutable active-tool-id slot");
static assert(__traits(compiles, (ToolPropertiesReadRole role) {
    bool active = role.hasActiveTool();
    string id = role.activeToolId();
    auto stages = role.enabledStages();
}), "6504 C10-0: the read role's value-only surface must compile");
static assert(!__traits(compiles, (ToolPropertiesPanelRoles roles) {
    roles.read = roles.read;
}), "6060 C10: the aggregate role must not expose a mutable read role");
static assert(!__traits(compiles, (ToolPropertiesPanelRoles roles) {
    roles.actions = roles.actions;
}), "6060 C10: the aggregate role must not expose a mutable action role");

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..");

private final class ProbeLegacyTool : Tool {
    string id;
    float amount;
    size_t draws;
    bool dropped;
    string[] order;
    void delegate() onWrite;

    this(string id) { this.id = id; }
    override string name() const { return id; }
    override Param[] params() {
        return [Param.float_("amount", "Amount", &amount, 0.0f)];
    }
    override bool paramEnabled(string name) const {
        auto self = cast(ProbeLegacyTool) this;
        self.order ~= "row";
        return true;
    }
    override void onParamChanged(string name) {
        if (onWrite !is null) onWrite();
    }
    override void drawProperties() {
        assert(!dropped,
            "6504 C12 drop witness: custom draw ran on a tool dropped mid-frame");
        ++draws;
        order ~= "custom";
    }
}

private final class ProbeCountStage : NopStage {
    float amount;
    size_t paramsCalls;
    size_t enabledCalls;
    size_t customDraws;
    string[] order;
    void delegate() onCustomDraw;

    this(TaskCode code, string id, ubyte ordinal) {
        super(code, id, ordinal);
    }
    override Param[] params() {
        ++paramsCalls;
        return [Param.float_("amount", "Amount", &amount, 0.0f)];
    }
    override bool paramEnabled(string name) const {
        auto self = cast(ProbeCountStage) this;
        ++self.enabledCalls;
        self.order ~= "row";
        return true;
    }
    override void drawProperties() {
        ++customDraws;
        order ~= "custom";
        if (onCustomDraw !is null) onCustomDraw();
    }
}

private class ProbeXfrm : XfrmTransformTool {
    bool[] seen;
    bool throwNext;

    this(Mesh* delegate() meshSrc, GpuMesh* gpu, EditMode* editMode) {
        super(meshSrc, gpu, editMode, () => SelType.Vertex, null);
    }
    override void drawProperties() {
        seen ~= suppressTRSProperties;
        if (throwNext) {
            throwNext = false;
            throw new Exception("6060 probe");
        }
        super.drawProperties();
    }
}

private final class ToolPropsHarness {
    Mesh mesh;
    GpuMesh gpu;
    EditMode editMode = EditMode.Vertices;
    View view;
    Tool slot;
    string slotId;
    Registry registry;
    CommandHistory history;
    CommandExecutor executor;
    EditSession session;
    GuardedActionController guard;
    ApplicationCommandBinding binding;
    FormsPanel forms;
    PropertyPanel propertyPanel;
    ToolHost host;
    ToolPipeContext pipe;
    ToolPropertiesPanelRoles* roles;

    this() {
        mesh = makeCube();
        view = new View(0, 0, 800, 600);
        history = new CommandHistory;
        executor = new CommandExecutor(history,
            () => slot !is null,
            (ToolTransition) { slot = null; slotId = ""; });
        session = new EditSession(() => slot, history,
            () { slot = null; slotId = ""; });
        guard = new GuardedActionController(GuardedActionPorts(
            (Command command, RecordMode mode) =>
                executor.applyOrRefire(command, mode, null),
            () => false,
            () => true,
            (Command) {},
            GuardObservationPorts(
                (record) {},
                (answer, performed) {},
                (pending) {})));
        binding = new ApplicationCommandBinding(
            registry, executor, session, history, guard,
            (Command) {}, (string) {});

        host.getActiveTool = () => slot;
        host.getActiveToolId = () => slotId;
        host.session = () => session;
        registry.commandFactories["tool.attr"] = () => cast(Command)
            new ToolAttrCommand(&mesh, view, editMode, host);
        registry.commandFactories["tool.pipe.attr"] = () => cast(Command)
            new ToolPipeAttrCommand(&mesh, view, editMode, host);

        forms = new FormsPanel;
        forms.setTweakEndHook(() { binding.endInteractiveTweak(); });
        propertyPanel = new PropertyPanel;
        pipe = new ToolPipeContext;
        g_pipeCtx = pipe;
    }

    void bind() {
        auto bound = bindToolPropertiesPanel(binding, forms, session,
            host.getActiveTool, host.getActiveToolId);
        roles = new ToolPropertiesPanelRoles(bound.read, bound.actions);
    }

    XfrmTransformTool setMoveTool() {
        auto tool = new XfrmTransformTool(
            () => &mesh, &gpu, &editMode, () => SelType.Vertex, null);
        configureMove(tool);
        return tool;
    }

    ProbeXfrm setProbeXfrm() {
        auto tool = new ProbeXfrm(() => &mesh, &gpu, &editMode);
        configureMove(tool);
        return tool;
    }

    private void configureMove(XfrmTransformTool tool) {
        tool.flagT = true;
        tool.flagR = false;
        tool.flagS = false;
        tool.handleFamily = 0;
        tool.setUndoBindings(history,
            () => new MeshVertexEdit(&mesh, view, editMode));
        tool.activate();
        slot = tool;
        slotId = "move";
    }

    FalloffStage addFalloff(string id = "falloff", Vec3 start = Vec3(0, 0, 0)) {
        auto stage = new FalloffStage(() => &mesh, &editMode, id);
        if (id == "falloff")
            pipe.pipeline.add(stage);
        else
            pipe.pipeline.addStacked(stage);
        const ok = stage.setAttr("type", "linear");
        assert(ok,
            "6060 falloff fixture could not select linear");
        stage.start = start;
        return stage;
    }

    FalloffStage addInactiveFalloff() {
        auto stage = new FalloffStage(() => &mesh, &editMode, "falloff");
        pipe.pipeline.add(stage);
        return stage;
    }

    HeadlessPanel open(string hostName = "Tool properties host") {
        return openPanel(() {
            drawToolPropertiesPanel(roles.read, roles.actions,
                                    propertyPanel, 370.0f);
        }, hostName);
    }
}

private void loadFormFile(string name) {
    g_forms = loadForms(repoRoot.buildPath("config", "forms", name));
    assert(g_forms.length > 0,
        "6060 form population: " ~ name ~ " loaded no forms");
}

private void loadInstanceWriteForm() {
    Form form;
    form.id = "6060-instance-write";
    form.whenStage = "falloff";
    form.showLabel = false;
    form.rows = [
        Row.makeControl("tool.pipe.attr falloff start ?", "Start A", "start-a"),
        Row.makeControl("tool.pipe.attr falloff end ?", "End", "end"),
        Row.makeControl("tool.pipe.attr falloff start ?", "Start B", "start-b")
    ];
    g_forms = [form];
}

private void tabInto(ref HeadlessPanel ui, size_t count) {
    assert(count > 0, "6060 Tab population must be non-zero");
    foreach (_; 0 .. count) {
        ui.keyDown(cast(int) ImGuiKey.Tab);
        ui.frame();
        ui.keyUp(cast(int) ImGuiKey.Tab);
        ui.frame();
        assert(ImGui.IsAnyItemActive(),
            "6060 Tab walk lost the active input item");
    }
}

private void typeAndCommit(ref HeadlessPanel ui, string value) {
    ui.typeText(value);
    ui.keyDown(cast(int) ImGuiKey.Enter);
    ui.frame();
    ui.keyUp(cast(int) ImGuiKey.Enter);
    ui.frame();
    ui.frame();
}

private JSONValue[] idItems() {
    return parseJSON(toolPropsIdsJson())["items"].array;
}

private size_t idCount(string kind, string section = "", string key = "") {
    size_t n;
    foreach (item; idItems()) {
        if (item["kind"].str != kind) continue;
        if (section.length && item["section"].str != section) continue;
        if (key.length && item["key"].str != key) continue;
        ++n;
    }
    return n;
}

private string[] sectionKeys() {
    string[] result;
    foreach (item; idItems())
        if (item["kind"].str == cast(string) PanelIdKind.Section)
            result ~= item["key"].str;
    return result;
}

private size_t visibleParamCount(FalloffStage stage) {
    size_t n;
    foreach (ref param; stage.params())
        if (!param.hidden_) ++n;
    return n;
}

private float halfWidthX(ref const Mesh mesh) {
    float result = 0.0f;
    foreach (ref vertex; mesh.vertices)
        if (fabs(vertex.x) > result) result = fabs(vertex.x);
    return result;
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6060 census missing source marker " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6060 census found no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "6060 census found unterminated body after " ~ marker);
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

unittest {
    auto priorForms = g_forms;
    const priorEnabled = g_formsPanelEnabled;
    auto priorPipe = g_pipeCtx;
    const priorTestMode = g_testMode;
    scope(exit) {
        g_forms = priorForms;
        g_formsPanelEnabled = priorEnabled;
        g_pipeCtx = priorPipe;
        g_testMode = priorTestMode;
        clearZones();
    }
    g_formsPanelEnabled = true;
    g_testMode = true;
    clearZones();

    { // C1: formed transform writes through the interactive production action.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto tool = app.setMoveTool();
        app.bind();
        const initialState = tool.toolStateJson();
        const initialHalfWidth = halfWidthX(app.mesh);
        const initialHistory = app.history.undoEntries().length;
        assert(initialState["valueReplay"]["source"].str == "none"
            && initialHistory == 0
            && fabs(initialHalfWidth - 0.5f) < 1e-5f,
            format("6060 C1 population: fresh move tool must have no replay/history "
                ~ "(source=%s history=%s halfWidth=%s)",
                initialState["valueReplay"]["source"].str,
                initialHistory, initialHalfWidth));

        auto ui = app.open();
        scope(exit) ui.close();
        ui.frame();
        tabInto(ui, 1);
        ui.typeText("2");
        auto state = tool.toolStateJson();
        assert(state["valueReplay"]["source"].str == "interactive",
            "6060 C1 production binder witness: formed value bypassed interactive dispatch");
        assert(state["valueReplay"]["channels"].array.length == 1
            && state["valueReplay"]["channels"].array[0].str == "TX"
            && state["valueReplay"]["folds"].integer == 1,
            "6060 C1 preview witness: TX did not open exactly one live replay: "
                ~ state.toString());
        ui.keyDown(cast(int) ImGuiKey.Enter);
        ui.frame();
        ui.keyUp(cast(int) ImGuiKey.Enter);
        ui.frame();
        ui.frame();
        state = tool.toolStateJson();
        assert(app.history.undoEntries().length == 0
            && halfWidthX(app.mesh) > 2.0f
            && state["editOpen"].type == JSONType.true_,
            format("6060 C1 history/mesh witness: interactive TX did not reach "
                ~ "the open preview session (history=%s halfWidth=%s editOpen=%s)",
                app.history.undoEntries().length, halfWidthX(app.mesh),
                state["editOpen"].toString()));
    }

    { // C2: the transform-row suppression latch restores on the normal path.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto tool = app.setProbeXfrm();
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();
        ui.frame();
        assert(tool.seen == [true] && !tool.suppressTRSProperties,
            "6060 C2 latch witness: normal draw did not bracket suppressTRSProperties");
    }

    { // C3: both latch and panel prologue restore after a thrown custom draw.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto tool = app.setProbeXfrm();
        app.bind();
        size_t caught;
        float hostWidth;
        auto ui = openPanel(() {
            hostWidth = ImGui.GetContentRegionAvail().x;
            try {
                drawToolPropertiesPanel(app.roles.read, app.roles.actions,
                                        app.propertyPanel, 370.0f);
            } catch (Exception error) {
                ++caught;
                assert(ImGui.GetContentRegionAvail().x == hostWidth,
                    "6060 C3 panel prologue witness: exception left the inner window current");
            }
        }, "Tool properties host");
        scope(exit) ui.close();

        ui.frame();
        const before = tool.seen.length;
        tool.throwNext = true;
        ui.frame();
        assert(caught == 1 && tool.seen.length == before + 1
            && tool.seen[$ - 1] && !tool.suppressTRSProperties,
            "6060 C3 latch witness: exceptional draw left suppression armed");
        ui.frame();
        assert(tool.seen.length == before + 2
            && !tool.suppressTRSProperties,
            "6060 C3 recovery witness: the next balanced frame did not draw");
    }

    { // C4: a tool without a form keeps the legacy PropertyPanel path.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto legacy = new ProbeLegacyTool("probe.legacyA");
        app.slot = legacy;
        app.slotId = legacy.id;
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();
        ui.frame();
        assert(idCount(cast(string) PanelIdKind.Row,
                       "probe.legacyA", "amount") == 1
            && legacy.draws == 1,
            "6060 C4 legacy witness: schema row or custom draw was lost");
        assert(legacy.order == ["row", "custom"],
            "6504 C4 tool order witness: custom draw did not run after the schema rows");
    }

    { // C5: Tool and pipeline reads stay live after the once-only bind.
        loadFormFile("falloff.yaml");
        auto app = new ToolPropsHarness;
        auto legacyA = new ProbeLegacyTool("probe.legacyA");
        auto legacyB = new ProbeLegacyTool("probe.legacyB");
        auto primary = app.addFalloff();
        app.slot = legacyA;
        app.slotId = legacyA.id;
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        assert(idCount(cast(string) PanelIdKind.Row,
                       "probe.legacyA", "amount") == 1
            && legacyA.draws == 1,
            "6060 C5 population: legacy A row did not draw before the swap");
        app.slot = legacyB;
        app.slotId = legacyB.id;
        ui.frame();
        assert(idCount(cast(string) PanelIdKind.Row,
                       "probe.legacyA", "amount") == 0
            && idCount(cast(string) PanelIdKind.Row,
                       "probe.legacyB", "amount") == 1
            && legacyA.draws == 1 && legacyB.draws == 1,
            "6060 C5 live-tool witness: role retained the tool captured at bind");

        app.slot = null;
        app.slotId = "";
        ui.frame();
        auto sections = sectionKeys();
        assert(idCount(cast(string) PanelIdKind.Row,
                       "probe.legacyB", "amount") == 0
            && sections.canFind("falloff") && primary.isActive(),
            "6060 C5 no-tool witness: user stage disappeared with the tool");

        auto stacked = app.addFalloff("falloff#1", Vec3(5, 5, 5));
        ui.frame();
        sections = sectionKeys();
        assert(sections.canFind("falloff") && sections.canFind("falloff#1")
            && stacked.isActive(),
            "6504 C5 live-pipeline witness: stage sections are not the live, uniquely-identified pipeline slice");
    }

    { // C6: the active tool is re-read after an in-frame parameter callback.
        loadFormFile("falloff.yaml");
        auto app = new ToolPropsHarness;
        auto legacyA = new ProbeLegacyTool("probe.legacyA");
        auto legacyB = new ProbeLegacyTool("probe.legacyB");
        legacyA.onWrite = () {
            app.slot = legacyB;
            app.slotId = legacyB.id;
        };
        app.slot = legacyA;
        app.slotId = legacyA.id;
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        tabInto(ui, 1);
        const aBefore = legacyA.draws;
        const bBefore = legacyB.draws;
        typeAndCommit(ui, "2");
        assert(legacyA.draws == aBefore && legacyB.draws > bBefore,
            "6060 C6 same-frame witness: custom draw used a cached pre-write tool");
    }

    { // C7: valid stage forms draw; malformed forms fall back to legacy rows.
        loadFormFile("falloff.yaml");
        auto app = new ToolPropsHarness;
        auto stage = app.addFalloff();
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        assert(sectionKeys().canFind("falloff")
            && idCount(cast(string) PanelIdKind.Row, "falloff") == 0,
            "6060 C7 formed-stage witness: falloff form did not own the section");

        Form bad;
        bad.id = "bad-falloff";
        bad.whenStage = "falloff";
        bad.rows = [Row.makeControl(
            "tool.pipe.attr falloff start", "Start", "start")];
        assertThrown!BindingException(planForm(bad, stage.params()));
        g_forms = [bad];
        ui.frame();
        const visible = visibleParamCount(stage);
        assert(visible > 0
            && idCount(cast(string) PanelIdKind.Row, "falloff") == visible,
            "6060 C7 malformed-form witness: legacy fallback did not draw every visible row");
        ui.frame();
    }

    { // C8: a stacked stage form writes its unique instance id.
        loadInstanceWriteForm();
        auto app = new ToolPropsHarness;
        auto primary = app.addFalloff();
        auto stacked = app.addFalloff("falloff#1", Vec3(5, 5, 5));
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        auto sections = sectionKeys();
        assert(sections.canFind("falloff") && sections.canFind("falloff#1")
            && primary.start == Vec3(0, 0, 0)
            && stacked.start == Vec3(5, 5, 5),
            "6060 C8 population: two distinct falloff sections/starts required");
        tabInto(ui, 10);
        typeAndCommit(ui, "2");
        assert(stacked.start.x == 2.0f
            && primary.start == Vec3(0, 0, 0),
            format("6060 C8 instance-id witness: stacked write targeted the "
                ~ "family id (primary=%s stacked=%s)",
                primary.start, stacked.start));
    }

    { // C9: tool.pipe.attr remains writable with no active tool.
        import toolpipe.pipeline : noteUserStageChoice;

        loadInstanceWriteForm();
        auto app = new ToolPropsHarness;
        auto stage = app.addFalloff();
        stage.claimForPreset();
        noteUserStageChoice(app.pipe.pipeline, stage, true);
        assert(stage.isActive() && !stage.presetClaimed() && app.slot is null,
            "6060 C9 population: preset break must leave an active user stage and no tool");
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        tabInto(ui, 1);
        typeAndCommit(ui, "2");
        assert(stage.start.x == 2.0f && app.slot is null,
            "6060 C9 no-tool write witness: tool.pipe.attr did not use the stage path");
    }

    { // C12: a tool dropped by its value write is not custom-drawn afterwards.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto legacy = new ProbeLegacyTool("probe.legacyA");
        legacy.onWrite = () {
            legacy.dropped = true;
            app.slot = null;
            app.slotId = "";
        };
        app.slot = legacy;
        app.slotId = legacy.id;
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        assert(legacy.draws >= 1
            && idCount(cast(string) PanelIdKind.Row,
                       "probe.legacyA", "amount") == 1,
            "6504 C12 population: the legacy row never drew, so nothing was dropped");
        tabInto(ui, 1);
        const drawsBefore = legacy.draws;
        typeAndCommit(ui, "2");
        assert(app.slot is null,
            "6504 C12 population: the param write did not drop the tool");
        assert(legacy.draws == drawsBefore,
            "6504 C12 drop witness: the action door drew a tool that had been dropped mid-frame");
    }

    { // RV1: Snap metadata keeps a schema-bearing stage off the Main page.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto snap = new ProbeCountStage(
            TaskCode.Snap, "probe.snap", 0x90);
        app.pipe.pipeline.add(snap);
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        assert(snap.pipeEnabled && snap.params().length == 1
            && app.pipe.pipeline.findById("probe.snap") is snap,
            "6504 RV1 population: the schema-bearing Snap stage did not reach the Main-page filter");
        ui.frame();
        assert(!sectionKeys().canFind("probe.snap")
            && idCount(cast(string) PanelIdKind.Row, "probe.snap") == 0,
            "6504 RV1 task-code witness: a Snap stage drew a section on the Main page");
    }

    { // RV2: section metadata carries the human stage label, not its id.
        loadFormFile("falloff.yaml");
        auto app = new ToolPropsHarness;
        auto stage = app.addFalloff();
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        string[] labels;
        foreach (item; idItems())
            if (item["kind"].str == cast(string) PanelIdKind.Section
                && item["key"].str == stage.id())
                labels ~= item["label"].str;
        assert(labels.length == 1 && stage.displayName() != stage.id(),
            "6504 RV2 population: the falloff section or its distinct human label is missing");
        assert(labels[0] == stage.displayName(),
            "6504 RV2 display-name witness: the section label fell back to the stage id");
    }

    { // RV3: a pipe-disabled stage is absent even when it has a schema.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto disabled = new ProbeCountStage(
            TaskCode.Path, "probe.disabled", 0x90);
        disabled.pipeEnabled = false;
        app.pipe.pipeline.add(disabled);
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        assert(!disabled.pipeEnabled
            && app.pipe.pipeline.findById("probe.disabled") is disabled,
            "6504 RV3 population: the pipe-disabled schema stage was not registered");
        assert(disabled.paramsCalls == 0
            && !sectionKeys().canFind("probe.disabled")
            && idCount(cast(string) PanelIdKind.Row, "probe.disabled") == 0,
            "6504 RV3 pipe-enabled witness: a disabled stage reached the Main-page section path");
    }

    { // C15: an enabled but schema-less stage has no section on the Main page.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto stage = app.addInactiveFalloff();
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        assert(stage.pipeEnabled && !stage.isActive()
            && stage.params().length == 0
            && app.pipe.pipeline.findById("falloff") !is null,
            "6504 C15 population: the probe falloff must be registered, enabled and schema-less");
        assert(!sectionKeys().canFind("falloff")
            && idCount(cast(string) PanelIdKind.Row, "falloff") == 0,
            "6504 C15 schema-less-stage witness: a registered stage with no panel schema drew a section anyway");
    }

    { // C13: stage schema reads and custom UI retain their per-frame order.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto probe = new ProbeCountStage(
            TaskCode.Path, "probe.stage", 0x80);
        app.pipe.pipeline.add(probe);
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        const visible = idCount(
            cast(string) PanelIdKind.Row, "probe.stage");
        assert(visible == 1 && sectionKeys().canFind("probe.stage"),
            "6504 C13 population: the probe stage never got a section");
        assert(probe.paramsCalls == 2,
            "6504 C13 params-call witness: the stage projection changed how often params() is read");
        assert(probe.customDraws == 1,
            "6504 C13 stage custom-draw witness: stage.drawProperties() did not run once per frame");
        assert(probe.order.length > 0 && probe.order[$ - 1] == "custom"
            && probe.order.count("row") == visible,
            "6504 C13 order witness: stage custom draw did not run after the schema rows");
    }

    { // C14: removal during an earlier section makes the later section vanish.
        loadFormFile("transform.yaml");
        auto app = new ToolPropsHarness;
        auto a = new ProbeCountStage(TaskCode.Cons, "probe.a", 0xE0);
        auto b = new ProbeCountStage(TaskCode.Path, "probe.b", 0xF0);
        app.pipe.pipeline.add(a);
        app.pipe.pipeline.add(b);
        assert(app.pipe.pipeline.all().length == 2
            && app.pipe.pipeline.findById("probe.a") is a
            && app.pipe.pipeline.findById("probe.b") is b,
            "6504 C14 population: the rig must register exactly the A and B stages");
        bool armed;
        a.onCustomDraw = () {
            if (armed) app.pipe.pipeline.removeStage(b);
        };
        app.bind();
        auto ui = app.open();
        scope(exit) ui.close();

        ui.frame();
        auto sections = sectionKeys();
        assert(sections.canFind("probe.a") && sections.canFind("probe.b")
            && idCount(cast(string) PanelIdKind.Row, "probe.a") == 1
            && idCount(cast(string) PanelIdKind.Row, "probe.b") == 1
            && a.customDraws == 1 && b.customDraws == 1,
            "6504 C14 population: both probe stages must draw a section and a row before the removal is armed");

        armed = true;
        ui.frame();
        sections = sectionKeys();
        assert(app.pipe.pipeline.findById("probe.b") is null,
            "6504 C14 population: the armed custom draw did not de-register the second stage");
        assert(sections.canFind("probe.a")
            && idCount(cast(string) PanelIdKind.Row, "probe.a") == 1,
            "6504 C14 population: the first stage vanished with the second");
        assert(!sections.canFind("probe.b")
            && idCount(cast(string) PanelIdKind.Row, "probe.b") == 0
            && b.customDraws == 1,
            "6504 C14 de-registered-stage witness: a stage removed during an earlier section still reached the panel");
    }

    { // C11: source census pins the production binder and guarded draw site.
        import tests.unit.census_symbols : blankNonCode;

        const rawApp = readText(repoRoot.buildPath("source", "app.d"));
        const rawPanel = readText(repoRoot.buildPath(
            "source", "ui", "tool_properties_panel.d"));
        const app = blankNonCode(rawApp);
        const panel = blankNonCode(rawPanel);
        const panels = blankNonCode(readText(repoRoot.buildPath(
            "source", "ui", "panels.d")));
        const editor = blankNonCode(readText(repoRoot.buildPath(
            "source", "editor_app.d")));
        assert(rawPanel.length > 5_000,
            "6060 C11 source population: tool-properties module is unexpectedly small");
        assert(identifierCount(panel, "EditorApp") == 0
            && identifierCount(panel, "editor_app") == 0
            && identifierCount(panel, "panels") == 0
            && panel.count("with (") == 0
            && panel.count("with(") == 0,
            "6060 C11 role boundary: panel regained EditorApp/ui.panels coupling");

        const drawBody = bodyAt(panel, "void drawToolPropertiesPanel(");
        assert(rawPanel.count("tupleof") == 0
            && rawPanel.count("getMember") == 0
            && rawPanel.count("mixin") == 0,
            "6504 G3 reflection census: tupleof/getMember/a string mixin reach "
                ~ "past private (measured: even across modules), and "
                ~ "blankNonCode cannot see a mixin — if this module legitimately "
                ~ "needs one, the boundary needs a new argument, not a bigger ban list");
        const snappingBody = bodyAt(panel, "if (!inMain)");
        const enabledStagesBody = bodyAt(panel,
            "ToolPropertiesStageInfo[] enabledStages()");
        assert(identifierCount(snappingBody, "params") == 0
            && identifierCount(snappingBody, "stageHasPanelParams") == 0
            && identifierCount(snappingBody, "actions") == 1
            && identifierCount(snappingBody, "drawStageBody") == 1
            && identifierCount(snappingBody, "taskCode") == 1
            && identifierCount(enabledStagesBody, "params") == 0,
            "6504 C11-g snap-page witness: the Snapping page gained a params() "
                ~ "read, lost its task-code filter, or re-synced a stage mirror "
                ~ "on the one page that must not touch it");
        foreach (name; ["Stage", "Tool", "ParamProvider",
                        "XfrmTransformTool", "drawProperties", "params",
                        "allMut", "findById", "suppressTRSProperties",
                        "resolveStage"])
            assert(identifierCount(drawBody, name) == 0,
                "6504 C11-a capability boundary: the drawing body names " ~ name);
        foreach (name; ["activeTool_", "hasActiveTool_", "activeToolId_",
                        "dispatch_", "interactive_", "forms_", "session_",
                        "read_", "actions_", "activate", "deactivate",
                        "onParamChanged", "setAttr", "interactiveParamEdit",
                        "g_pipeCtx", "pipeline"])
            assert(identifierCount(drawBody, name) == 0,
                "6504 C11-a reach-around: the drawing body names a role's "
                    ~ "private member or mutator (" ~ name ~ ")");
        assert(drawBody.count("cast(") == 2
            && drawBody.count("cast(Stage") == 0,
            "6504 C11-a cast census: the drawing body recovered a mutable stage/tool");
        assert(identifierCount(drawBody, "inMain") == 3,
            "6504 C11-a page gate: the Main-page wrapper around the tool block "
                ~ "and the section loop is gone or duplicated, and the "
                ~ "Snapping page is not reachable from a headless cell");
        assert(identifierCount(drawBody, "actions") == 7
            && identifierCount(drawBody, "drawToolForm") == 1
            && identifierCount(drawBody, "drawFormedToolCustom") == 1
            && identifierCount(drawBody, "drawToolParams") == 1
            && identifierCount(drawBody, "drawToolCustom") == 1
            && identifierCount(drawBody, "stageHasPanelParams") == 1
            && identifierCount(drawBody, "drawStageBody") == 2,
            "6504 C11-a action census: the drawing body bypassed or duplicated "
                ~ "the six action doors");
        assert(identifierCount(panel, "ParamProvider") == 0
            && identifierCount(panel, "allMut") == 0
            && panel.count("cast(Stage") == 0
            && panel.count("pipeline.findById(stageId)") == 1
            && panel.count("pipeline.all()") == 1
            && panel.count(".params()") == 1,
            "6504 C11-b module census: the panel regained a provider/stage escape");

        const readRole = bodyAt(panel, "struct ToolPropertiesReadRole");
        assert(identifierCount(readRole, "enabledStages") == 1
            && identifierCount(readRole, "Stage") == 0
            && identifierCount(readRole, "Tool") == 0
            && identifierCount(readRole, "params") == 0
            && readRole.count("cast(") == 0,
            "6504 C11-c read-role slice: enabledStages vanished, or display metadata regained mutation capability");

        const binder = bodyAt(panel,
            "ToolPropertiesPanelRoles bindToolPropertiesPanel(");
        const flatBinder = collapseWhitespace(binder);
        enum boundActions =
            "ToolPropertiesActions(&binding.dispatchUi, &binding.dispatchInteractiveUi, forms, session, activeTool)";
        enum boundRead =
            "ToolPropertiesReadRole(() => activeTool() !is null, activeToolId)";
        assert(identifierCount(binder, "binding") == 3
            && binder.count("&binding.dispatchUi") == 1
            && binder.count("&binding.dispatchInteractiveUi") == 1
            && flatBinder.count(boundActions) == 1
            && flatBinder.count(boundRead) == 1,
            "6060 C11 binder census: production UI/interactive actions changed");
        const actions = bodyAt(panel, "struct ToolPropertiesActions");
        const flatActions = collapseWhitespace(actions);
        assert(identifierCount(actions, "Tool") == 2
            && actions.count("Tool delegate()") == 2
            && identifierCount(actions, "Stage") == 0
            && identifierCount(actions, "ParamProvider") == 0
            && identifierCount(actions, "params") == 1,
            "6504 C11-d action-door storage: Tool must appear exactly twice in "
                ~ "this struct — the private Tool delegate() activeTool_ field "
                ~ "and the constructor's fifth parameter. A third occurrence "
                ~ "is a cached tool between frames (or a Tool local that must "
                ~ "be auto); two occurrences of something other than Tool "
                ~ "delegate() is a stored handle.");
        enum toolFormDraw =
            "forms_.draw(form, tool, dispatch_, interactive_, activeToolId, );";
        enum stageFormDraw =
            "forms_.draw(*stageForm, stage, dispatch_, interactive_, , stage.id());";
        assert(flatActions.count(toolFormDraw) == 1
            && flatActions.count(stageFormDraw) == 1
            && flatActions.count("panel.draw(activeTool_(), session_);") == 1
            && flatActions.count("panel.drawProvider(stage, session_);") == 2
            && flatActions.count(
                "scope(exit) xf.suppressTRSProperties = false;") == 1
            && flatActions.count("stage.drawProperties();") == 1
            && flatActions.count("tool.drawProperties();") == 1
            && flatActions.count("xf.drawProperties();") == 1
            && flatActions.count("formByStage(stage.formFamilyId())") == 1,
            "6060 C11 action census: generic/interactive or legacy dispatch changed");
        const flatPanel = collapseWhitespace(rawPanel);
        enum toolFormLiteral =
            q{forms_.draw(form, tool, dispatch_, interactive_, activeToolId, "");};
        enum stageFormLiteral =
            q{forms_.draw(*stageForm, stage, dispatch_, interactive_, "", stage.id());};
        assert(flatPanel.count(toolFormLiteral) == 1
            && flatPanel.count(stageFormLiteral) == 1,
            "6060 C11 form calls must carry the live tool and unique stage id");

        assert(rawPanel.count("ImGui.Begin(\"Tool Properties\")") == 1
            && rawPanel.count("publishPanelZone(\"toolProps\")") == 1,
            "6060 C11 panel ids: window or input-zone identity changed");
        const chromePush = rawPanel.indexOf("pushPanelChromeStyle();");
        const chromePop = rawPanel.indexOf(
            "scope(exit) popPanelChromeStyle();");
        const endAt = rawPanel.indexOf("scope(exit) ImGui.End();");
        const beginAt = rawPanel.indexOf(
            "if (ImGui.Begin(\"Tool Properties\")) {");
        assert(chromePush >= 0 && chromePush < chromePop
            && chromePop < endAt && endAt < beginAt
            && rawPanel.count("scope(exit) propertyPanel.popScope();") == 1
            && rawPanel.count("scope(exit) endToolPropsIdColumn();") == 1
            && rawPanel.count(
                "scope(exit) xf.suppressTRSProperties = false;") == 1,
            "6060 C11 unwind order: panel prologue or nested scopes changed");

        assert(identifierCount(panels, "drawToolPropertiesPanel") == 0
            && identifierCount(panels, "drawStageBody") == 0
            && identifierCount(panels, "g_toolPropsTab") == 0
            && identifierCount(editor, "propertyPanel") == 0,
            "6060 C11 retired path: old panel body or EditorApp storage survived");

        size_t sourceFiles;
        size_t oldSignatures;
        size_t stackedCallers;
        foreach (entry; dirEntries(repoRoot.buildPath("source"), "*.d",
                                   SpanMode.depth)) {
            ++sourceFiles;
            const source = blankNonCode(readText(entry.name));
            oldSignatures += source.count("drawToolPropertiesPanel(EditorApp");
            if (entry.name != repoRoot.buildPath(
                    "source", "toolpipe", "pipeline.d"))
                stackedCallers += source.count("addStacked(");
        }
        assert(sourceFiles > 500 && oldSignatures == 0,
            "6060 C11 source census: the EditorApp panel overload survived");
        assert(stackedCallers == 1,
            "6504 C11-h stacking census: a second addStacked caller can mint "
                ~ "a duplicate stage id, and resolution by id then picks the "
                ~ "wrong instance");

        const flatApp = collapseWhitespace(app);
        enum bindCall =
            "bindToolPropertiesPanel(commandBinding, formsPanel, session, toolHost.getActiveTool, toolHost.getActiveToolId)";
        enum drawCall =
            "drawToolPropertiesPanel(toolPropertiesRoles.read, toolPropertiesRoles.actions, propertyPanel, layout.sideW + 10);";
        assert(identifierCount(app, "bindToolPropertiesPanel") == 2
            && identifierCount(app, "toolPropertiesRoles") == 3
            && flatApp.count(bindCall) == 1
            && flatApp.count(drawCall) == 1,
            "6060 C11 production calls: binder/draw text changed");
        const commandBindingAt = flatApp.indexOf(
            "commandBinding = new ApplicationCommandBinding(");
        const bindAt = flatApp.indexOf(bindCall);
        const loopAt = flatApp.indexOf("while (running) {");
        const drawAt = flatApp.indexOf(drawCall);
        assert(commandBindingAt >= 0 && bindAt >= 0 && loopAt >= 0
            && drawAt >= 0 && commandBindingAt < bindAt
            && bindAt < loopAt && loopAt < drawAt,
            "6060 C11 placement: binder/draw no longer bracket the frame loop");

        enum guardedDraw =
            "if ((activeTool !is null || anyFalloffActive()) && (!command.g_testMode || g_toolPropertiesShown)) { import ui.tool_properties_panel : drawToolPropertiesPanel; "
            ~ drawCall ~ " }";
        assert(flatApp.count(guardedDraw) == 1,
            "6060 C11 adjacency: production draw moved outside its exact visibility guard");
        assert(app.count(
            "toolHost.getActiveTool   = () => activeTool;") == 1
            && app.count(
            "toolHost.getActiveToolId = () => activeToolId;") == 1
            && app.count("app.propertyPanel") == 0
            && rawApp.count("DockBuilderDockWindow(\"Tool Properties\"") >= 1,
            "6060 C11 live getters/storage/dock contract changed");
    }
}
