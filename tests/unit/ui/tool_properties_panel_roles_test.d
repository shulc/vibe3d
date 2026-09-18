module tests.unit.ui.tool_properties_panel_roles_test;

import std.algorithm : canFind, count;
import std.exception : assertThrown;
import std.file : SpanMode, dirEntries, readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.math : fabs;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;

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
import forms_render : FormsPanel;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import input_zones : clearZones;
import math : Vec3;
import mesh : Mesh, makeCube;
import mesh_gpu : GpuMesh;
import params : Param;
import property_panel : PanelIdKind, PropertyPanel, toolPropsIdsJson;
import registry : Registry;
import seltype : SelType;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import toolpipe.pipeline : ToolPipeContext, g_pipeCtx;
import toolpipe.stages.falloff : FalloffStage;
import tools.transform.xfrm_transform : XfrmTransformTool;
import ui.tool_properties_panel : ToolPropertiesPanelRoles,
    ToolPropertiesReadRole, bindToolPropertiesPanel, drawToolPropertiesPanel;
import view : View;

static assert(!__traits(compiles, (ToolPropertiesReadRole role) {
    Tool tool = role.activeTool();
}), "6504 C10: the read role must not return the active Tool");
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
    void delegate() onWrite;

    this(string id) { this.id = id; }
    override string name() const { return id; }
    override Param[] params() {
        return [Param.float_("amount", "Amount", &amount, 0.0f)];
    }
    override void onParamChanged(string name) {
        if (onWrite !is null) onWrite();
    }
    override void drawProperties() { ++draws; }
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
            && panel.count("with (") == 0,
            "6060 C11 role boundary: panel regained EditorApp/ui.panels coupling");

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
        enum toolFormDraw =
            "forms_.draw(form, tool, dispatch_, interactive_, activeToolId, );";
        enum stageFormDraw =
            "forms_.draw(*stageForm, stage, dispatch_, interactive_, , stage.id());";
        assert(flatActions.count(toolFormDraw) == 1
            && flatActions.count(stageFormDraw) == 1
            && flatActions.count("panel.draw(activeTool_(), session_);") == 1
            && flatActions.count("panel.drawProvider(stage, session_);") == 2,
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
        foreach (entry; dirEntries(repoRoot.buildPath("source"), "*.d",
                                   SpanMode.depth)) {
            ++sourceFiles;
            oldSignatures += blankNonCode(readText(entry.name))
                .count("drawToolPropertiesPanel(EditorApp");
        }
        assert(sourceFiles > 500 && oldSignatures == 0,
            "6060 C11 source census: the EditorApp panel overload survived");

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
