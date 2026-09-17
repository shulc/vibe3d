// The behavior rig constructs family collaborators; P6 separately pins the
// production call and its ordering so a correct helper cannot hide mis-wiring.
module tests.unit.commands.pipe_command_registration_test;

import application_command_binding : CommandInvocationContext,
    CommandInvocationOutcome, CommandInvocationResult;
import command : Command, CommandOrigin;
import command_history : CommandHistory;
import commands.tool.host : ToolHostReadView;
import commands.actr : ActrPresetCommand;
import commands.falloff : FalloffPresetCommand, FalloffAddCommand,
    FalloffRemoveCommand, FalloffClearCommand, FalloffAutoSizeCommand,
    FalloffReverseCommand;
import commands.workplane : WorkplaneResetCommand, WorkplaneEditCommand,
    WorkplaneRotateCommand, WorkplaneOffsetCommand,
    WorkplaneAlignToSelectionCommand;
import edit_session : EditSession, LiveEvalClient, ParameterChangeBatch;
import editmode : EditMode;
import math : Vec3;
import mesh : Mesh;
import pipe_command_registration : registerPipeStageCommands;
import std.algorithm : count, sort, uniq;
import std.array : array;
import std.file : exists, readText;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.regex : regex, replaceAll;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;
import toolpipe.pipeline : g_pipeCtx, ToolPipeContext;
import toolpipe.stage : TaskCode;
import toolpipe.stages.actcenter : ActionCenterStage;
import toolpipe.stages.axis : AxisStage;
import toolpipe.stages.falloff : FalloffStage;
import toolpipe.stages.workplane : WorkplaneStage;

private enum repoRoot = buildNormalizedPath(
    dirName(__FILE_FULL_PATH__), "..", "..", "..");

private final class PipeStages {
    ToolPipeContext context;
    WorkplaneStage workplane;
    ActionCenterStage acen;
    AxisStage axis;
    FalloffStage falloff;

    this(LiveRegistrationRig rig) {
        auto meshSource = () => &rig.session.editMesh();
        context = new ToolPipeContext;
        workplane = new WorkplaneStage;
        acen = new ActionCenterStage(meshSource, rig.session.editModePtr());
        axis = new AxisStage(meshSource, rig.session.editModePtr());
        falloff = new FalloffStage(meshSource, rig.session.editModePtr());
        context.pipeline.add(workplane);
        context.pipeline.add(acen);
        context.pipeline.add(axis);
        context.pipeline.add(falloff);
        g_pipeCtx = context;
    }
}

private final class LiveProbe : Tool, LiveEvalClient {
    size_t replays;

    override bool hasLiveEval() const { return true; }
    override bool hasLiveAttrEval() const { return true; }
    override void reEvaluate(ParameterChangeBatch) { ++replays; }
}

private string modeOf(T)(T stage) {
    foreach (attribute; stage.listAttrs())
        if (attribute[0] == "mode") return attribute[1];
    return "<no mode>";
}

private string typeOf(FalloffStage stage) {
    foreach (attribute; stage.listAttrs())
        if (attribute[0] == "type") return attribute[1];
    return "<no type>";
}

private void registerPipe(LiveRegistrationRig rig) {
    registerPipeStageCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(),
        ToolHostReadView(&rig.host));
}

private CommandInvocationResult invokeApplied(
        LiveRegistrationRig rig, string id, string args = "") {
    auto result = rig.binding.invokeLine(
        id, args, CommandInvocationContext(CommandOrigin.script, false));
    assert(result.outcome == CommandInvocationOutcome.applied,
        "5990 command refused through production binding: " ~ id);
    return result;
}

private void checkFactory(T)(LiveRegistrationRig rig, string id,
                             ref size_t checked) {
    auto factory = id in rig.registry.commandFactories;
    assert(factory !is null, "5990 P1 missing factory: " ~ id);
    auto command = (*factory)();
    assert(cast(T)command !is null,
        "5990 P1 factory built the wrong class for " ~ id);
    ++checked;
}

private string repoFile(string relative) {
    const path = buildPath(repoRoot, relative);
    assert(exists(path), "5990 production census cannot find " ~ relative);
    return readText(path);
}

unittest { // P1: every one of the 27 ids builds its intended class
    auto savedPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedPipe;
    auto rig = new LiveRegistrationRig;
    auto stages = new PipeStages(rig);
    registerPipe(rig);
    assert(rig.registry.commandFactories.length == 27,
        format("5990 P1 population: found %s pipe ids",
               rig.registry.commandFactories.length));

    size_t checked;
    checkFactory!WorkplaneResetCommand(rig, "workplane.reset", checked);
    checkFactory!WorkplaneEditCommand(rig, "workplane.edit", checked);
    checkFactory!WorkplaneRotateCommand(rig, "workplane.rotate", checked);
    checkFactory!WorkplaneOffsetCommand(rig, "workplane.offset", checked);
    checkFactory!WorkplaneAlignToSelectionCommand(
        rig, "workplane.alignToSelection", checked);
    foreach (mode; ["auto", "select", "selectauto", "element", "local",
                    "origin", "screen", "border", "none", "pivot", "parent"])
        checkFactory!ActrPresetCommand(rig, "actr." ~ mode, checked);
    foreach (type; ["linear", "radial", "cylinder", "screen", "lasso",
                    "vertexMap"])
        checkFactory!FalloffPresetCommand(rig, "falloff." ~ type, checked);
    checkFactory!FalloffAddCommand(rig, "falloff.add", checked);
    checkFactory!FalloffRemoveCommand(rig, "falloff.remove", checked);
    checkFactory!FalloffClearCommand(rig, "falloff.clear", checked);
    checkFactory!FalloffAutoSizeCommand(rig, "falloff.autosize", checked);
    checkFactory!FalloffReverseCommand(rig, "falloff.reverse", checked);
    assert(checked == 27,
        "5990 P1 class witness did not inspect all 27 factories");
}

unittest { // P2: dynamic rows retain their values and reach the claim path
    auto savedPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedPipe;
    auto rig = new LiveRegistrationRig;
    auto stages = new PipeStages(rig);
    registerPipe(rig);

    static struct Row { string id; string acen; string axis; }
    immutable Row[] rows = [
        Row("auto", "auto", "auto"),
        Row("select", "select", "select"),
        Row("selectauto", "selectauto", "selectauto"),
        Row("element", "element", "element"),
        Row("local", "local", "local"),
        Row("origin", "origin", "world"),
        Row("screen", "screen", "screen"),
        Row("border", "border", "select"),
        Row("none", "none", "none"),
        Row("pivot", "pivot", "pivot"),
        Row("parent", "parent", "parent"),
    ];
    string[] seenAcen;
    size_t actrRows;
    foreach (row; rows) {
        stages.acen.userLocked = false;
        stages.axis.userLocked = false;
        stages.falloff.userLocked = false;
        stages.acen.claimForPreset();
        stages.falloff.claimForPreset();
        assert(stages.acen.presetClaimed()
            && stages.falloff.presetClaimed()
            && !stages.acen.userLocked && !stages.falloff.userLocked,
            "5990 P2 actr claim premise was not armed");

        auto result = invokeApplied(rig, "actr." ~ row.id);
        assert(stages.acen.userLocked && stages.axis.userLocked
            && !stages.acen.presetClaimed()
            && stages.falloff.userLocked && !stages.falloff.presetClaimed(),
            "5990 P2 actr claim path failed for actr." ~ row.id);
        assert(result.command.name() == "actr." ~ row.id,
            format("5990 P2 row name: actr.%s built %s",
                   row.id, result.command.name()));
        assert(modeOf(stages.acen) == row.acen
            && modeOf(stages.axis) == row.axis,
            format("5990 P2 row values: actr.%s gave acen %s axis %s",
                   row.id, modeOf(stages.acen), modeOf(stages.axis)));
        seenAcen ~= modeOf(stages.acen);
        ++actrRows;
    }
    assert(actrRows == 11 && seenAcen.dup.sort.uniq.array.length == 11,
        format("5990 P2 actr population/distinctness changed: %s", seenAcen));

    string[] seenTypes;
    size_t falloffRows;
    foreach (type; ["linear", "radial", "cylinder", "screen", "lasso",
                    "vertexMap"]) {
        stages.acen.userLocked = false;
        stages.falloff.userLocked = false;
        stages.acen.claimForPreset();
        stages.falloff.claimForPreset();
        assert(stages.acen.presetClaimed()
            && stages.falloff.presetClaimed(),
            "5990 P2 falloff claim premise was not armed");

        auto result = invokeApplied(rig, "falloff." ~ type);
        assert(stages.falloff.userLocked && !stages.falloff.presetClaimed()
            && stages.acen.userLocked && !stages.acen.presetClaimed()
            && cast(FalloffStage)
                g_pipeCtx.pipeline.findByTask(TaskCode.Wght) is stages.falloff,
            "5990 P2 falloff claim/identity path failed for falloff." ~ type);
        assert(result.command.name() == "falloff." ~ type
            && typeOf(stages.falloff) == type,
            format("5990 P2 row values: falloff.%s built %s type %s", type,
                   result.command.name(), typeOf(stages.falloff)));
        seenTypes ~= typeOf(stages.falloff);
        ++falloffRows;
    }
    assert(falloffRows == 6 && seenTypes.dup.sort.uniq.array.length == 6,
        format("5990 P2 falloff population/distinctness changed: %s",
               seenTypes));
    assert(actrRows + falloffRows == 17,
        "5990 P2 claim-path population must remain 17 rows");
}

unittest { // P3b: a post-switch factory executes on B in B's mode
    auto savedPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedPipe;
    auto rig = new LiveRegistrationRig;
    auto stages = new PipeStages(rig);
    registerPipe(rig);

    rig.layerA.meshRef().resetSelection();
    rig.layerB.meshRef().resetSelection();
    rig.layerA.meshRef().selectFace(0);
    rig.layerB.meshRef().selectFace(0);
    Vec3 centroid(ref Mesh mesh) {
        Vec3 result = Vec3(0, 0, 0);
        foreach (vertex; mesh.faces[0])
            result = result + mesh.vertices[vertex];
        return result * (1.0f / cast(float)mesh.faces[0].length);
    }
    const centroidA = centroid(rig.layerA.meshRef());
    const centroidB = centroid(rig.layerB.meshRef());
    const delta = centroidB - centroidA;
    assert(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z > 0.01f,
        "5990 P3b floor: A and B face centroids coincide");

    rig.switchToB();
    auto result = rig.binding.invokeLine(
        "workplane.alignToSelection", "",
        CommandInvocationContext(CommandOrigin.script, false));
    assert(result.outcome == CommandInvocationOutcome.applied,
        "5990 P3b applied: alignToSelection refused");
    const error = stages.workplane.center - centroidB;
    assert(error.x * error.x + error.y * error.y + error.z * error.z < 1e-8f,
        format("5990 P3b centre %s want B %s (A would be %s)",
               stages.workplane.center, centroidB, centroidA));
}

unittest { // P3: all 27 factories resolve mesh/View/Mode at creation
    auto savedPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedPipe;
    auto rig = new LiveRegistrationRig;
    auto stages = new PipeStages(rig);
    registerPipe(rig);

    auto ids = rig.registry.commandFactories.keys.array;
    ids.sort;
    assert(ids.length == 27,
        "5990 P3 live-context population must contain 27 factories");
    size_t beforeCount;
    foreach (id; ids) {
        auto command = rig.registry.commandFactories[id]();
        assert(command.meshPtr is &rig.layerA.meshRef(),
            "5990 P3 A mesh context mismatch for " ~ id);
        assert(command.viewRef is rig.cells[0],
            "5990 P3 A View context mismatch for " ~ id);
        assert(command.editModeVal == EditMode.Vertices,
            "5990 P3 A mode context mismatch for " ~ id);
        ++beforeCount;
    }
    assert(beforeCount == 27,
        "5990 P3 A context witness did not inspect all factories");

    rig.switchToB();
    size_t meshCount;
    foreach (id; ids) {
        assert(rig.registry.commandFactories[id]().meshPtr
                is &rig.layerB.meshRef(),
            "5990 P3 late mesh: " ~ id);
        ++meshCount;
    }
    assert(meshCount == 27,
        "5990 P3 late-mesh witness did not inspect all factories");
    size_t viewCount;
    foreach (id; ids) {
        assert(rig.registry.commandFactories[id]().viewRef is rig.cells[1],
            "5990 P3 late view: " ~ id);
        ++viewCount;
    }
    assert(viewCount == 27,
        "5990 P3 late-View witness did not inspect all factories");
    size_t modeCount;
    foreach (id; ids) {
        assert(rig.registry.commandFactories[id]().editModeVal
                == EditMode.Polygons,
            "5990 P3 late mode: " ~ id);
        ++modeCount;
    }
    assert(modeCount == 27,
        "5990 P3 late-mode witness did not inspect all factories");
}

unittest { // P4: ToolHost is read at command creation
    auto savedPipe = g_pipeCtx;
    scope(exit) g_pipeCtx = savedPipe;
    auto rig = new LiveRegistrationRig;
    auto stages = new PipeStages(rig);
    auto decoyProbe = new LiveProbe;
    auto decoySession = new EditSession(
        () => cast(Tool)decoyProbe, new CommandHistory, () {});
    rig.host.session = () => decoySession;
    registerPipe(rig);

    auto liveProbe = new LiveProbe;
    rig.activeTool = liveProbe;
    rig.host.session = () => rig.editSession;
    size_t applied;
    void fire(string id, string args = "") {
        invokeApplied(rig, id, args);
        ++applied;
    }
    fire("falloff.radial");
    fire("falloff.add", `{"type":"linear"}`);
    fire("falloff.remove", `{"id":"falloff#1"}`);
    fire("falloff.clear");
    fire("falloff.autosize");
    fire("falloff.reverse");
    assert(applied == 6,
        "5990 P4 did not execute all six ToolHost-consuming commands");
    assert(decoyProbe.replays == 0,
        format("5990 P4 stale session replayed %s time(s)",
               decoyProbe.replays));
    assert(liveProbe.replays == 6,
        format("5990 P4 live session replayed %s of 6", liveProbe.replays));
}

unittest { // P6: production owns the narrow registrar call and ordering
    const moduleRaw = repoFile("source/pipe_command_registration.d");
    const registrationRaw = repoFile("source/registration.d");
    const editorAppRaw = repoFile("source/editor_app.d");
    const moduleCode = blankNonCode(moduleRaw);
    const registration = blankNonCode(registrationRaw);
    const editorApp = blankNonCode(editorAppRaw);
    assert(moduleRaw.length > 3_000
        && registrationRaw.length > 80_000
        && editorAppRaw.length > 40_000,
        "5990 P6 source population: a production file is implausibly small");

    foreach (forbidden; ["EditorApp", "editor_app", "Ai3dModalRefs",
                         "RemeshModalRefs", "with (", "app."])
        assert(moduleCode.count(forbidden) == 0,
            "5990 P6 narrow registrar regained forbidden code: " ~ forbidden);
    assert(moduleCode.count("reg.commandFactories[") == 12,
        format("5990 P6 factory-row population changed to %s",
               moduleCode.count("reg.commandFactories[")));
    assert(moduleCode.count("host.read()") == 6
            && moduleCode.count("*host") == 0,
        format("5990 P6 ToolHost factory-read population changed to %s",
               moduleCode.count("host.read()")));

    immutable classNames = [
        "WorkplaneResetCommand", "WorkplaneEditCommand",
        "WorkplaneRotateCommand", "WorkplaneOffsetCommand",
        "WorkplaneAlignToSelectionCommand", "ActrPresetCommand",
        "FalloffPresetCommand", "FalloffAddCommand",
        "FalloffRemoveCommand", "FalloffClearCommand",
        "FalloffAutoSizeCommand", "FalloffReverseCommand",
    ];
    assert(classNames.length == 12,
        "5990 P6 retired-class census must name exactly 12 classes");
    foreach (name; classNames) {
        assert(registration.count(name) == 0,
            "5990 P6 registration.d retained pipe class " ~ name);
        assert(moduleCode.count("new " ~ name ~ "(") >= 1,
            "5990 P6 narrow registrar does not instantiate " ~ name);
    }
    assert(registration.count("void registerPipeStageCommands(") == 0,
        "5990 P6 registration.d retained the old family body");

    const flat = replaceAll(registration, regex(`\s+`), " ");
    enum productionCall =
        "registerPipeStageCommands(app.reg(), LiveSessionRole(app.sessionOwner), "
      ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
      ~ "app.toolHostView);";
    assert(flat.count(productionCall) == 1,
        "5990 P6 production call no longer passes the real Session, live "
      ~ "View/Mode source, and ToolHost read view inline");
    const callAt = flat.indexOf(productionCall);
    const wrapperAt = flat.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(callAt >= 0 && wrapperAt > callAt,
        "5990 P6 pipe registration moved after currentType wrapping");
    assert(editorApp.count("toolHost()") == 0,
        "5990 P6 EditorApp retained the ToolHost forwarder");
    assert(editorApp.count("ToolHostReadView toolHostView;") == 1
            && editorApp.count("toolHostPtr") == 0,
        "5990 P6 EditorApp lost the narrow ToolHost read view or retained the retired channel");
}
