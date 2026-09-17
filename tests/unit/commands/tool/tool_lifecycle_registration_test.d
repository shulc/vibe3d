// The behavior rig builds its own roles; U8 separately pins every production
// input and the parent ordering so helper correctness cannot hide mis-wiring.
module tests.unit.commands.tool.tool_lifecycle_registration_test;

import application_command_binding : CommandInvocationContext,
    CommandInvocationOutcome;
import command : Command, CommandOrigin, g_editTargetResolver, g_testMode,
    kNoEditTargetReason;
import commands.tool.attr : ToolAttrCommand;
import commands.tool.begin_session : ToolBeginSessionCommand,
    ToolClearSoftPinForTestCommand;
import commands.tool.do_apply : ToolDoApplyCommand;
import commands.tool.host : ToolHost;
import commands.tool.panel_edit : ToolPanelEditCommand;
import commands.tool.pipe : ToolPipeAttrCommand;
import commands.tool.reset : ToolResetCommand;
import commands.tool.set : ToolReleaseCommand, ToolSetCommand;
import commands.ui.about : UiAboutCommand;
import commands.ui.channels : UiChannelsCommand, g_channelsShown;
import commands.ui.image_list : UiImageListCommand, g_imageListShown;
import commands.ui.layer_list : UiLayerListCommand, g_layerListShown;
import commands.ui.pie : UiPieCommand;
import commands.ui.statistics : UiStatisticsCommand, UiStatisticsExpandCommand,
    g_statisticsShown;
import commands.ui.tool_properties : UiToolPropertiesCommand,
    g_toolPropertiesShown;
import commands.ui.viewport_props : UiViewportPropsCommand,
    g_viewportPropsShown;
import edit_session : LiveEvalClient, ParameterChangeBatch;
import editmode : EditMode;
import params : Param;
import std.algorithm : count;
import std.file : exists, readText;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.regex : ctRegex, matchAll;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode, LedgerRow, reconcile,
    statementsContaining, symbolTokenHits;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import tool : Tool;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
    "..", "..", "..", "..");

private final class ProbeTool : Tool, LiveEvalClient {
    LiveRegistrationRig rig;
    float amount;
    size_t interactiveChanges;
    size_t scriptedChanges;
    size_t reEvaluates;

    this(LiveRegistrationRig rig) {
        this.rig = rig;
    }

    override Param[] params() {
        return [Param.float_("amount", "Amount", &amount, 0.0f)];
    }

    override void onParamChanged(string name) {
        if (interactiveParamEdit) ++interactiveChanges;
        else ++scriptedChanges;
    }

    override bool hasLiveEval() const { return false; }
    override bool hasLiveAttrEval() const { return false; }
    override void reEvaluate(ParameterChangeBatch batch) { ++reEvaluates; }

    override bool applyHeadless() {
        rig.session.editMesh().vertices[0].x += 1.0f;
        return true;
    }
}

private void checkFactory(T)(LiveRegistrationRig rig, string id,
                             ref size_t checked) {
    auto factory = id in rig.registry.commandFactories;
    assert(factory !is null, "5980 missing lifecycle factory: " ~ id);
    auto command = (*factory)();
    assert(command.name() == id,
        "5980 lifecycle factory key/name mismatch for " ~ id);
    assert(cast(T)command !is null,
        "5980 lifecycle factory built the wrong class for " ~ id);
    ++checked;
}

private string exceptionMessage(void delegate() action) {
    try {
        action();
    } catch (Exception error) {
        return error.msg;
    }
    assert(false, "5980 expected command dispatch to throw");
    return null;
}

private string repoFile(string relative) {
    const path = buildPath(repoRoot, relative);
    assert(exists(path), "5980 production census cannot find " ~ relative);
    return readText(path);
}

unittest { // U1: every id builds its intended class
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    assert(rig.registry.commandFactories.length == 18,
        "5980 lifecycle registrar population: expected exactly 18 ids");

    size_t checked;
    checkFactory!ToolSetCommand(rig, "tool.set", checked);
    checkFactory!ToolReleaseCommand(rig, "tool.release", checked);
    checkFactory!ToolAttrCommand(rig, "tool.attr", checked);
    checkFactory!ToolDoApplyCommand(rig, "tool.doApply", checked);
    checkFactory!ToolResetCommand(rig, "tool.reset", checked);
    checkFactory!ToolPipeAttrCommand(rig, "tool.pipe.attr", checked);
    checkFactory!ToolBeginSessionCommand(rig, "tool.beginSession", checked);
    checkFactory!ToolClearSoftPinForTestCommand(
        rig, "tool.clearSoftPinForTest", checked);
    checkFactory!ToolPanelEditCommand(rig, "tool.panelEdit", checked);
    checkFactory!UiToolPropertiesCommand(rig, "ui.toolProperties", checked);
    checkFactory!UiLayerListCommand(rig, "ui.layerList", checked);
    checkFactory!UiImageListCommand(rig, "ui.imageList", checked);
    checkFactory!UiChannelsCommand(rig, "ui.channels", checked);
    checkFactory!UiStatisticsCommand(rig, "ui.statistics", checked);
    checkFactory!UiStatisticsExpandCommand(
        rig, "ui.statistics.expand", checked);
    checkFactory!UiViewportPropsCommand(rig, "ui.viewportProps", checked);
    checkFactory!UiAboutCommand(rig, "ui.about", checked);
    checkFactory!UiPieCommand(rig, "ui.pie", checked);
    assert(checked == 18,
        "5980 lifecycle class witness did not inspect all 18 factories");
}

unittest { // U2: set/release route through the supplied host
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    auto savedResolver = g_editTargetResolver;
    scope(exit) g_editTargetResolver = savedResolver;
    g_editTargetResolver = () => rig.session.document.hasEditTarget();

    rig.adapter.dispatchScript(
        "tool.set", `{"tool":"probe.tool"}`, false);
    assert(rig.activatePreparedIds == ["probe.tool"],
        "5980 tool.set did not reach activatePrepared with probe.tool");
    rig.adapter.dispatchScript(
        "tool.set", `{"tool":"probe.tool","off":"off"}`, false);
    assert(rig.deactivates == 1,
        "5980 tool.set off did not reach the deactivate door once");

    rig.adapter.dispatchScript("tool.release", "", false);
    assert(rig.deactivates == 1,
        "5980 tool.release with no active tool must be a no-op");
    rig.activeTool = new ProbeTool(rig);
    rig.adapter.dispatchScript("tool.release", "", false);
    assert(rig.deactivates == 2,
        "5980 tool.release with an active tool did not deactivate it");
}

unittest { // U3: factories resolve live mesh/View/Mode at creation time
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    auto savedResolver = g_editTargetResolver;
    scope(exit) g_editTargetResolver = savedResolver;
    g_editTargetResolver = () => rig.session.document.hasEditTarget();

    assert(rig.registry.commandFactories.length == 18,
        "5980 live-context population: expected 18 factories");
    size_t beforeCount;
    foreach (id, factory; rig.registry.commandFactories) {
        auto command = factory();
        assert(command.meshPtr is &rig.layerA.meshRef(),
            "5980 A mesh context mismatch for " ~ id);
        assert(command.viewRef is rig.cells[0],
            "5980 A View context mismatch for " ~ id);
        assert(command.editModeVal == EditMode.Vertices,
            "5980 A mode context mismatch for " ~ id);
        ++beforeCount;
    }
    assert(beforeCount == 18,
        "5980 A context witness did not inspect all factories");

    const aBefore = rig.layerA.meshRef().vertices[0];
    rig.switchToB();
    size_t afterCount;
    foreach (id, factory; rig.registry.commandFactories) {
        auto command = factory();
        assert(command.meshPtr is &rig.layerB.meshRef(),
            "5980 live mesh resolution retained A for " ~ id);
        assert(command.viewRef is rig.cells[1],
            "5980 live View resolution retained cell 0 for " ~ id);
        assert(command.editModeVal == EditMode.Polygons,
            "5980 live mode resolution retained Vertices for " ~ id);
        ++afterCount;
    }
    assert(afterCount == 18,
        "5980 B context witness did not inspect all factories");

    auto probe = new ProbeTool(rig);
    rig.activeTool = probe;
    const bBefore = rig.layerB.meshRef().vertices[0];
    auto result = rig.binding.invokeLine(
        "tool.doApply", "",
        CommandInvocationContext(CommandOrigin.script, false));
    assert(result.outcome == CommandInvocationOutcome.applied,
        "5980 tool.doApply did not apply through the production binding");
    assert(result.command.meshPtr is &rig.layerB.meshRef(),
        "5980 tool.doApply command was not constructed against B");
    assert(rig.layerB.meshRef().vertices[0].x == bBefore.x + 1.0f,
        "5980 tool.doApply did not mutate B's first vertex");
    assert(rig.layerA.meshRef().vertices[0] == aBefore,
        "5980 tool.doApply touched inactive layer A");
    assert(rig.history.undoEntries.length == 1,
        "5980 tool.doApply did not record exactly one undo entry");
    assert(rig.history.undo(),
        "5980 tool.doApply history entry was not undoable");
    assert(rig.layerB.meshRef().vertices[0] == bBefore,
        "5980 tool.doApply undo did not restore B");
    assert(rig.layerA.meshRef().vertices[0] == aBefore,
        "5980 tool.doApply undo touched inactive layer A");
}

unittest { // U4: ToolHost is read after its late member is rebound
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    rig.bindLiveReset();
    rig.adapter.dispatchScript("tool.reset", "", false);
    assert(rig.liveResets == 1 && rig.staleResets == 0,
        "5980 late ToolHost member witness used the registration-time reset");
}

unittest { // U4b: a whole-host reassignment is read again by the same id
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    rig.bindLiveReset();
    rig.adapter.dispatchScript("tool.reset", "", false);
    assert(rig.liveResets == 1 && rig.staleResets == 0,
        "6350 U4b population: the first tool.reset did not reach the live reset");
    size_t replacementResets;
    ToolHost replacement = rig.host;
    replacement.resetActiveTool = (string id) {
        ++replacementResets;
        return true;
    };
    rig.host = replacement;
    rig.adapter.dispatchScript("tool.reset", "", false);
    assert(replacementResets == 1 && rig.liveResets == 1
            && rig.staleResets == 0,
        "6350 U4b the second tool.reset reused the first creation's ToolHost");
}

unittest { // U5: interactive attr writes use the binding's EditSession
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    auto probe = new ProbeTool(rig);
    rig.activeTool = probe;

    const historyBefore = rig.history.undoEntriesVisible.length;
    rig.adapter.dispatchScript("tool.attr",
        `{"tool":"probe.tool","attr":"amount","value":0.5}`, false);
    assert(probe.amount == 0.5f && probe.scriptedChanges == 1,
        "5980 scripted tool.attr did not write and notify the active tool");
    assert(probe.reEvaluates == 0,
        "5980 scripted tool.attr unexpectedly opened live evaluation");
    assert(rig.history.undoEntriesVisible.length == historyBefore,
        "5980 scripted tool.attr must not create history");

    string thrown;
    try {
        rig.binding.dispatchInteractiveUi("tool.attr",
            `{"tool":"probe.tool","attr":"amount","value":0.75}`);
    } catch (Exception error) {
        thrown = error.msg;
    }
    assert(thrown.length == 0,
        "5980 interactive tool.attr threw instead of using EditSession: " ~ thrown);
    assert(probe.interactiveChanges == 1,
        "5980 interactive tool.attr did not notify the active tool");
    assert(probe.reEvaluates == 1,
        "5980 interactive tool.attr did not re-evaluate through EditSession");
    assert(rig.history.undoEntriesVisible.length == historyBefore,
        "5980 interactive tool.attr must not create history in this rig");
}

unittest { // U6: script refusals are exact and never create history
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    auto savedResolver = g_editTargetResolver;
    scope(exit) g_editTargetResolver = savedResolver;
    g_editTargetResolver = () => rig.session.document.hasEditTarget();

    rig.activeTool = new ProbeTool(rig);
    rig.adapter.dispatchScript("tool.doApply", "", false);
    assert(rig.history.undoEntriesVisible.length == 1,
        "5980 refusal history population: expected one real setup entry");
    const historyBefore = rig.history.undoEntriesVisible.length;

    rig.activatePreparedIds.length = 0;
    g_editTargetResolver = () => false;
    const noTarget = exceptionMessage(() {
        rig.adapter.dispatchScript(
            "tool.set", `{"tool":"probe.tool"}`, false);
    });
    assert(noTarget == "command 'tool.set' did not apply: " ~ kNoEditTargetReason,
        "5980 no-target refusal changed: " ~ noTarget);
    assert(rig.activatePreparedIds.length == 0,
        "5980 refused tool.set still reached activatePrepared");
    assert(rig.history.undoEntriesVisible.length == historyBefore,
        "5980 refused tool.set changed non-empty history");

    g_editTargetResolver = () => rig.session.document.hasEditTarget();
    rig.activeTool = null;
    const noTool = exceptionMessage(() {
        rig.adapter.dispatchScript("tool.doApply", "", false);
    });
    assert(noTool == "command 'tool.doApply' did not apply",
        "5980 no-tool refusal changed: " ~ noTool);
    assert(rig.history.undoEntriesVisible.length == historyBefore,
        "5980 refused tool.doApply changed non-empty history");
}

unittest { // U7: all test-only doors refuse outside test mode
    auto rig = new LiveRegistrationRig;
    rig.registerLifecycle();
    rig.activeTool = new ProbeTool(rig);

    const savedTestMode = g_testMode;
    const savedToolProperties = g_toolPropertiesShown;
    const savedLayerList = g_layerListShown;
    const savedImageList = g_imageListShown;
    const savedChannels = g_channelsShown;
    const savedStatistics = g_statisticsShown;
    const savedViewportProps = g_viewportPropsShown;
    scope(exit) {
        g_testMode = savedTestMode;
        g_toolPropertiesShown = savedToolProperties;
        g_layerListShown = savedLayerList;
        g_imageListShown = savedImageList;
        g_channelsShown = savedChannels;
        g_statisticsShown = savedStatistics;
        g_viewportPropsShown = savedViewportProps;
    }
    g_testMode = false;
    g_toolPropertiesShown = false;
    g_layerListShown = false;
    g_imageListShown = false;
    g_channelsShown = false;
    g_statisticsShown = false;
    g_viewportPropsShown = false;

    immutable ids = [
        "tool.beginSession", "tool.clearSoftPinForTest", "tool.panelEdit",
        "ui.toolProperties", "ui.layerList", "ui.imageList", "ui.channels",
        "ui.statistics", "ui.statistics.expand", "ui.viewportProps",
    ];
    immutable args = [
        "", "", `{"dx":0,"dy":0,"dz":0}`,
        `{"visible":"show"}`, `{"visible":"show"}`,
        `{"visible":"show"}`, `{"visible":"show"}`,
        `{"visible":"show"}`, `{"target":"Vertices","state":"open"}`,
        `{"visible":"show"}`,
    ];
    assert(ids.length == 10 && args.length == 10,
        "5980 U7 refusal population must contain exactly ten doors");
    const historyBefore = rig.history.undoEntriesVisible.length;
    size_t refused;
    foreach (i, id; ids) {
        const message = exceptionMessage(() {
            rig.adapter.dispatchScript(id, args[i], false);
        });
        assert(message.indexOf("only available in --test mode") >= 0,
            "5980 U7 wrong refusal for " ~ id ~ ": " ~ message);
        ++refused;
    }
    assert(refused == 10,
        "5980 U7 did not exercise all ten test-only doors");
    assert(rig.history.undoEntriesVisible.length == historyBefore,
        "5980 U7 test-only refusals changed history");
    assert(!g_toolPropertiesShown && !g_layerListShown && !g_imageListShown
        && !g_channelsShown && !g_statisticsShown && !g_viewportPropsShown,
        "5980 U7 refused show command changed a visibility flag");

    g_testMode = true;
    immutable visibilityIds = [
        "ui.toolProperties", "ui.layerList", "ui.imageList", "ui.channels",
        "ui.statistics", "ui.viewportProps",
    ];
    size_t shown;
    foreach (id; visibilityIds) {
        rig.adapter.dispatchScript(id, `{"visible":"show"}`, false);
        ++shown;
    }
    assert(shown == 6,
        "5980 U7 positive control did not exercise all six visibility doors");
    assert(g_toolPropertiesShown,
        "5980 U7 positive control did not show Tool Properties in test mode");
    assert(g_layerListShown,
        "5980 U7 positive control did not show Layer List in test mode");
    assert(g_imageListShown,
        "5980 U7 positive control did not show Image List in test mode");
    assert(g_channelsShown,
        "5980 U7 positive control did not show Channels in test mode");
    assert(g_statisticsShown,
        "5980 U7 positive control did not show Statistics in test mode");
    assert(g_viewportPropsShown,
        "5980 U7 positive control did not show Viewport Properties in test mode");
    const otherReason = exceptionMessage(() {
        rig.adapter.dispatchScript("tool.beginSession", "", false);
    });
    assert(otherReason ==
            "tool.beginSession: active tool is not a transform tool",
        "5980 U7 positive control did not reach the non-transform refusal: "
        ~ otherReason);
}

unittest { // U8: production owns the same live inputs and wrapper order
    const registrarRaw = repoFile("source/tool_lifecycle_registration.d");
    const registrationRaw = repoFile("source/registration.d");
    const appRaw = repoFile("source/app.d");
    const registrar = blankNonCode(registrarRaw);
    const registration = blankNonCode(registrationRaw);
    const app = blankNonCode(appRaw);

    assert(registrarRaw.length > 4_000
        && registrationRaw.length > 50_000
        && appRaw.length > 100_000,
        "5980 U8 source population floor: a production file is implausibly small");
    foreach (forbidden; ["EditorApp", "editor_app", "Ai3dModalRefs",
                         "RemeshModalRefs", "with (", "*host", "ToolHost*",
                         "ToolHost *", "tupleof", "getMember"])
        assert(registrar.count(forbidden) == 0,
            "5980 narrow registrar regained forbidden code: " ~ forbidden);
    assert(registrar.count("reg.commandFactories[") == 18,
        "5980 U8 registrar no longer contains exactly 18 factory rows");

    const readHits = symbolTokenHits(registrar,
        "source/tool_lifecycle_registration.d", "host.read()");
    assert(readHits.length > 0,
        "6350 U8 factory-read population is empty");
    const drift = reconcile([
        LedgerRow("registerToolLifecycleCommands", 9,
                  "one ToolHostReadView read per ToolHost-consuming factory"),
    ], readHits);
    assert(drift.length == 0,
        "6350 U8 host.read() site census changed:" ~ drift);

    const statements = statementsContaining(registrar, "host.read()");
    assert(statements.length == 9, format(
        "6350 U8 factory-read statement population: expected 9, got %s",
        statements.length));
    string early;
    foreach (statement; statements) {
        const lambdaAt = statement.indexOf("() =>");
        const readAt = statement.indexOf("host.read()");
        const startsFactory = statement.indexOf("reg.commandFactories[") == 0;
        if (statement.count("host.read()") != 1 || !startsFactory
                || lambdaAt < 0 || lambdaAt > readAt)
            early ~= "\n    " ~ statement;
    }
    assert(early.length == 0,
        "6350 U8 host.read() outside a factory lambda (a registration-time copy):"
        ~ early);

    immutable classNames = [
        "ToolSetCommand", "ToolReleaseCommand", "ToolAttrCommand",
        "ToolDoApplyCommand", "ToolResetCommand", "ToolPipeAttrCommand",
        "ToolBeginSessionCommand", "ToolClearSoftPinForTestCommand",
        "ToolPanelEditCommand", "UiToolPropertiesCommand",
        "UiLayerListCommand", "UiImageListCommand", "UiChannelsCommand",
        "UiStatisticsCommand", "UiStatisticsExpandCommand",
        "UiViewportPropsCommand", "UiAboutCommand", "UiPieCommand",
    ];
    assert(classNames.length == 18,
        "5980 U8 retired-class census must name exactly 18 classes");
    foreach (name; classNames)
        assert(registration.count(name) == 0,
            "5980 U8 registration.d retained lifecycle class " ~ name);
    assert(registration.count("void registerToolLifecycleCommands(") == 0,
        "5980 U8 registration.d retained the old family body");
    assert(registration.count("auto liveSession") == 0
        && registration.count("auto liveViewMode") == 0,
        "5980 U8 live roles must remain inline at each registrar call");

    enum productionCall =
        "registerToolLifecycleCommands(app.reg(), LiveSessionRole(app.sessionOwner),\n"
      ~ "        LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()),\n"
      ~ "        app.toolHostView);";
    assert(registration.count(productionCall) == 1,
        "5980 U8 production call no longer passes the real Session, live "
      ~ "View/Mode source, and ToolHost read view inline");
    const callAt = registration.indexOf(productionCall);
    assert(callAt >= 0,
        "5980 U8 lifecycle production-call population floor is empty");
    immutable productionFields = [
        "sessionOwner", "cameraViewDg", "toolHostView",
    ];
    assert(productionFields.length == 3,
        "5980 U8 lifecycle input-field census must name exactly three fields");
    foreach (field; productionFields)
        assert(registration.count("app." ~ field) >= 1,
            "5980 U8 lifecycle input field is absent from registration.d: " ~ field);
    enum lifecycleInputRebinding = ctRegex!(
        `app\.(sessionOwner|cameraViewDg|toolHostView)[ \t\r\n]*=[^=]`);
    size_t reboundInputs;
    foreach (_; matchAll(registration, lifecycleInputRebinding))
        ++reboundInputs;
    assert(reboundInputs == 0,
        "5980 U8 production lifecycle input was rebound in registration.d");
    const wrapperAt = registration.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(callAt >= 0 && wrapperAt > callAt,
        "5980 U8 lifecycle registration moved after currentType wrapping");
    assert(registration.count(
            "reg.commandFactories[id] = withSelType(reg.commandFactories[id],") == 1,
        "5980 U8 currentType factory capture changed; none of this family's "
      ~ "18 commands reads it, so source order is the only witness");

    const sessionAt = app.indexOf("toolHost.session = () => session;");
    const hostAt = app.indexOf(
        "app.toolHostView = ToolHostReadView(&toolHost);");
    const registerAt = app.indexOf("registerCommands(app);");
    assert(sessionAt >= 0 && app.count("toolHost.session = () => session;") == 1,
        "5980 U8 production ToolHost lost its EditSession binding");
    assert(hostAt > sessionAt
            && app.count("app.toolHostView = ToolHostReadView(&toolHost);") == 1,
        "5980 U8 production ToolHost read view must be bound after session binding");
    assert(app.count("registerCommands(app);") == 1 && registerAt > hostAt,
        "6350 U8 production view must be bound before registerCommands copies EditorApp");
    assert(app.count("toolHost.resetActiveTool = (string optId) {") == 1,
        "6350 U8 the late reset write must target the ToolHost the view binds");
    assert(app.count("reg, executor, session, history,") == 1,
        "5980 U8 ApplicationCommandBinding no longer receives the same EditSession");
}
