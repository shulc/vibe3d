module tests.unit.commands.view.view_settings_registration_test;

import std.algorithm : count;
import std.file : readText;
import std.format : format;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.regex : ctRegex, matchAll, replaceAll;
import std.string : indexOf;

import ai.analysis : Finding;
import ai.state : EditorAiState;
import ai_command_registration : registerAiToggleCommands;
import command : Command;
import command_args : bindArgs;
import commands.mesh.select : MeshSelect;
import copilot_command_registration : registerCopilotCommands;
import copilot_panel : CopilotPanel;
import editmode : EditMode;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import trackball : TrackballOption;
import view_settings_registration : registerViewSettingsCommands;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..", "..");

private immutable string[8] kLiveIds = [
    "snap.toggle", "constrain.toggle", "snap.toggleType", "snap.mode",
    "pref.coordRounding", "pref.trackball", "path.define",
    "symmetry.toggle",
];

private immutable string[3] kAiIds = [
    "ai.toggle", "ai.enable", "ai.disable",
];

private immutable string[4] kCopilotIds = [
    "copilot.analyze", "copilot.selectFinding", "copilot.cycleFinding",
    "ui.copilotPanel",
];

private void registerLive(LiveRegistrationRig rig) {
    registerViewSettingsCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode());
}

private void setTrackball(LiveRegistrationRig rig, int cell) {
    rig.activeCell = cell;
    auto command = rig.registry.commandFactories["pref.trackball"]();
    bindArgs(command, `{"subject":"viewport","value":"on"}`);
    assert(command.apply(),
        "6354 trackball fixture: pref.trackball viewport on refused");
}

private Command makeMeshSelect(LiveRegistrationRig rig) {
    return new MeshSelect(&rig.session.editMesh(), rig.liveView(),
                          rig.session.editMode, rig.session.editModePtr());
}

private void seedFinding(CopilotPanel panel) {
    Finding finding;
    finding.edges = [0u];
    panel.setFindings([finding]);
}

unittest { // A0: the witness drives production instead of rebuilding it
    immutable self = blankNonCode(readText(__FILE_FULL_PATH__));
    assert(self.count("registerViewSettingsCommands(") >= 1,
        "6354 self-census: the production registrar is not driven");
    assert(self.count("new SnapToggleCommand(") == 0,
        "6354 self-census: the test constructs its own snap.toggle analogue");
    assert(self.count("new TrackballPrefCommand(") == 0,
        "6354 self-census: the test constructs its own pref.trackball analogue");
    assert(self.matchAll(ctRegex!(`reg\s*\.\s*commandFactories\s*\[`)).empty,
        "6354 self-census: the test writes a stand-in production registry");
}

unittest { // A1: exact population and key-to-command identity
    auto rig = new LiveRegistrationRig;
    assert(rig.registry.commandFactories.length == 0,
        "6354 fixture: the rig must start with an empty command registry");
    registerLive(rig);
    static assert(kLiveIds.length == 8);
    assert(rig.registry.commandFactories.length == 8,
        format("6354 population: expected exactly 8 view/settings ids, got %d",
               rig.registry.commandFactories.length));
    foreach (id; kLiveIds) {
        auto factory = id in rig.registry.commandFactories;
        assert(factory !is null,
            "6354 population: " ~ id ~ " is not registered");
        auto command = (*factory)();
        assert(command.name() == id,
            "6354 population: " ~ id ~ " built the wrong command class: "
            ~ command.name());
    }
}

unittest { // A3: pref.trackball resolves the active camera when fired
    auto rig = new LiveRegistrationRig;
    registerLive(rig);

    rig.cells[0].trackballOption = TrackballOption.Off;
    rig.cells[1].trackballOption = TrackballOption.Off;
    assert(rig.cells[0].trackballOption == TrackballOption.Off,
        "6354 A3 control floor: cell 0 pre-state write did not land");
    assert(rig.cells[1].trackballOption == TrackballOption.Off,
        "6354 A3 control floor: cell 1 pre-state write did not land");
    setTrackball(rig, 0);
    assert(rig.cells[0].trackballOption == TrackballOption.On,
        "6354 A3 control: current cell 0 was not written");
    assert(rig.cells[1].trackballOption == TrackballOption.Off,
        "6354 A3 control: inactive cell 1 was written");

    rig.cells[0].trackballOption = TrackballOption.Off;
    rig.cells[1].trackballOption = TrackballOption.Off;
    assert(rig.cells[0].trackballOption == TrackballOption.Off,
        "6354 A3 target floor: cell 0 pre-state write did not land");
    assert(rig.cells[1].trackballOption == TrackballOption.Off,
        "6354 A3 target floor: cell 1 pre-state write did not land");
    setTrackball(rig, 1);
    assert(rig.cells[1].trackballOption == TrackballOption.On,
        "6354 A3 target: active cell 1 was not written");
    assert(rig.cells[0].trackballOption == TrackballOption.Off,
        "6354 A3 target: inactive cell 0 was written");
}

unittest { // A4: every factory resolves View at fire time
    auto rig = new LiveRegistrationRig;
    registerLive(rig);
    auto firstView = rig.liveView();
    size_t n;
    foreach (id; kLiveIds) {
        auto command = rig.registry.commandFactories[id]();
        assert(command.viewRef() is firstView,
            "6354 live View control: " ~ id ~ " did not take cell 0");
        ++n;
    }
    assert(n == 8, "6354 live View control ran over fewer than 8 ids");
    rig.activeCell = 1;
    assert(rig.liveView() !is firstView,
        "6354 live View fixture: the cell switch did not change the View");
    n = 0;
    foreach (id; kLiveIds) {
        auto command = rig.registry.commandFactories[id]();
        assert(command.viewRef() is rig.liveView(),
            "6354 live View target: " ~ id
            ~ " retained the registration-time View");
        ++n;
    }
    assert(n == 8, "6354 live View target ran over fewer than 8 ids");
}

unittest { // A5: every factory resolves Mesh at fire time
    auto rig = new LiveRegistrationRig;
    registerLive(rig);
    auto meshA = &rig.layerA.meshRef();
    size_t n;
    foreach (id; kLiveIds) {
        assert(rig.registry.commandFactories[id]().meshPtr() is meshA,
            "6354 live Mesh control: " ~ id ~ " did not take layer A");
        ++n;
    }
    assert(n == 8, "6354 live Mesh control ran over fewer than 8 ids");
    rig.session.document.setPrimary(rig.layerB);
    assert(&rig.layerB.meshRef() !is meshA,
        "6354 live Mesh fixture: primary switch did not change the mesh");
    n = 0;
    foreach (id; kLiveIds) {
        assert(rig.registry.commandFactories[id]().meshPtr()
               is &rig.layerB.meshRef(),
            "6354 live Mesh target: " ~ id
            ~ " retained the registration-time mesh");
        ++n;
    }
    assert(n == 8, "6354 live Mesh target ran over fewer than 8 ids");
}

unittest { // A6: every factory resolves EditMode at fire time
    auto rig = new LiveRegistrationRig;
    registerLive(rig);
    size_t n;
    foreach (id; kLiveIds) {
        assert(rig.registry.commandFactories[id]().editModeVal()
               == EditMode.Vertices,
            "6354 live mode control: " ~ id ~ " did not take Vertices");
        ++n;
    }
    assert(n == 8, "6354 live mode control ran over fewer than 8 ids");
    rig.session.switchGeometryType(EditMode.Polygons);
    assert(rig.session.editMode == EditMode.Polygons,
        "6354 live mode fixture: geometry type did not change");
    n = 0;
    foreach (id; kLiveIds) {
        assert(rig.registry.commandFactories[id]().editModeVal()
               == EditMode.Polygons,
            "6354 live mode target: " ~ id
            ~ " retained the registration-time mode");
        ++n;
    }
    assert(n == 8, "6354 live mode target ran over fewer than 8 ids");
}

unittest { // A7: mesh.select lookup stays lazy through registration
    auto rig = new LiveRegistrationRig;
    auto ai = new EditorAiState;
    ai.setEnabled(true);
    auto panel = new CopilotPanel;
    seedFinding(panel);
    size_t sentinelCalls;
    rig.registry.commandFactories["mesh.select"] = () => makeMeshSelect(rig);
    registerCopilotCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), ai, panel,
        () => rig.registry.commandFactories["mesh.select"]());
    assert("copilot.selectFinding" in rig.registry.commandFactories,
        "6354 A7 population: the copilot family did not register");
    size_t registered;
    foreach (id; kCopilotIds) {
        auto registeredCommand = rig.registry.commandFactories[id]();
        assert(registeredCommand.name() == id,
            "6354 copilot population: " ~ id
            ~ " built a command whose name is " ~ registeredCommand.name());
        ++registered;
    }
    assert(registered == 4,
        "6354 copilot population ran over fewer than four ids");
    rig.registry.commandFactories["mesh.select"] = () {
        ++sentinelCalls;
        return makeMeshSelect(rig);
    };
    auto command = rig.registry.commandFactories["copilot.selectFinding"]();
    bindArgs(command, `{"index":0}`);
    assert(command.apply(),
        "6354 A7 fixture: selectFinding refused before the mesh.select lookup");
    assert(sentinelCalls == 1,
        "6354 lazy lookup: copilot retained the registration-time factory");
}

unittest { // A8a: AI action and EditorAiState collaborators are distinct
    auto rig = new LiveRegistrationRig;
    auto aiX = new EditorAiState;
    auto aiY = new EditorAiState;
    registerAiToggleCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), aiX);
    foreach (id; kAiIds) {
        auto command = rig.registry.commandFactories[id]();
        assert(command.name() == id,
            "6354 ai action witness: " ~ id
            ~ " built a command whose name is " ~ command.name());
    }
    assert(rig.registry.commandFactories["ai.enable"]().apply(),
        "6354 ai state witness: ai.enable for X refused");
    assert(aiX.enabled && !aiY.enabled,
        "6354 ai state witness: the first registration did not target X only");
    assert(rig.registry.commandFactories["ai.enable"]().apply() && aiX.enabled,
        "6354 ai action witness: ai.enable is not idempotent");
    aiX.setEnabled(false);
    assert(rig.registry.commandFactories["ai.toggle"]().apply() && aiX.enabled,
        "6354 ai action witness: ai.toggle did not turn X on");
    assert(rig.registry.commandFactories["ai.toggle"]().apply() && !aiX.enabled,
        "6354 ai action witness: ai.toggle does not alternate");

    registerAiToggleCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), aiY);
    assert(rig.registry.commandFactories["ai.enable"]().apply(),
        "6354 ai state witness: ai.enable for Y refused");
    assert(aiY.enabled && !aiX.enabled,
        "6354 ai state witness: re-registration did not retarget Y");
}

unittest { // A8b: CopilotPanel collaborator follows re-registration
    auto rig = new LiveRegistrationRig;
    auto ai = new EditorAiState;
    ai.setEnabled(true);
    auto panelX = new CopilotPanel;
    auto panelY = new CopilotPanel;
    seedFinding(panelX);
    seedFinding(panelY);
    rig.registry.commandFactories["mesh.select"] = () => makeMeshSelect(rig);
    registerCopilotCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), ai, panelX,
        () => rig.registry.commandFactories["mesh.select"]());
    auto command = rig.registry.commandFactories["copilot.selectFinding"]();
    bindArgs(command, `{"index":0}`);
    assert(command.apply(),
        "6354 panel witness: selectFinding for X refused");
    assert(panelX.active() == 0 && panelY.active() == -1,
        "6354 panel witness: the first registration did not target X only");

    registerCopilotCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), ai, panelY,
        () => rig.registry.commandFactories["mesh.select"]());
    command = rig.registry.commandFactories["copilot.selectFinding"]();
    bindArgs(command, `{"index":0}`);
    assert(command.apply(),
        "6354 panel witness: selectFinding for Y refused");
    assert(panelY.active() == 0,
        "6354 panel witness: re-registration did not retarget Y");
}

unittest { // A8c: all seven gated factories keep live base inputs
    auto rig = new LiveRegistrationRig;
    auto ai = new EditorAiState;
    auto panel = new CopilotPanel;
    registerAiToggleCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), ai);
    registerCopilotCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), ai, panel,
        () => makeMeshSelect(rig));
    immutable ids = kAiIds[] ~ kCopilotIds[];
    assert(ids.length == 7,
        "6354 gated context fixture: expected seven ids");

    auto viewA = rig.liveView();
    rig.activeCell = 1;
    assert(rig.liveView() !is viewA,
        "6354 gated context fixture: View did not change");
    size_t n;
    foreach (id; ids) {
        assert(rig.registry.commandFactories[id]().viewRef() is rig.liveView(),
            "6354 gated View witness: " ~ id ~ " retained cell 0");
        ++n;
    }
    assert(n == 7, "6354 gated View witness ran over fewer than seven ids");

    auto meshA = &rig.layerA.meshRef();
    rig.session.document.setPrimary(rig.layerB);
    assert(&rig.layerB.meshRef() !is meshA,
        "6354 gated context fixture: Mesh did not change");
    n = 0;
    foreach (id; ids) {
        assert(rig.registry.commandFactories[id]().meshPtr()
               is &rig.layerB.meshRef(),
            "6354 gated Mesh witness: " ~ id ~ " retained layer A");
        ++n;
    }
    assert(n == 7, "6354 gated Mesh witness ran over fewer than seven ids");

    rig.session.switchGeometryType(EditMode.Polygons);
    assert(rig.session.editMode == EditMode.Polygons,
        "6354 gated context fixture: EditMode did not change");
    n = 0;
    foreach (id; ids) {
        assert(rig.registry.commandFactories[id]().editModeVal()
               == EditMode.Polygons,
            "6354 gated mode witness: " ~ id ~ " retained Vertices");
        ++n;
    }
    assert(n == 7, "6354 gated mode witness ran over fewer than seven ids");
}

unittest { // A9: production wiring and source ownership census
    string squash(string source) {
        return replaceAll(source, ctRegex!(`\s+`), " ");
    }

    const registrationRaw = readText(
        buildPath(repoRoot, "source", "registration.d"));
    const settingsRaw = readText(
        buildPath(repoRoot, "source", "view_settings_registration.d"));
    const aiRaw = readText(
        buildPath(repoRoot, "source", "ai_command_registration.d"));
    const copilotRaw = readText(
        buildPath(repoRoot, "source", "copilot_command_registration.d"));
    assert(registrationRaw.length > 50_000,
        "6354 A9 population: registration.d is missing or truncated");
    assert(settingsRaw.length > 1_500,
        "6354 A9 population: settings registrar is missing or truncated");
    assert(aiRaw.length > 500,
        "6354 A9 population: AI registrar is missing or truncated");
    assert(copilotRaw.length > 500,
        "6354 A9 population: copilot registrar is missing or truncated");

    foreach (raw; [settingsRaw, aiRaw, copilotRaw]) {
        const code = blankNonCode(raw);
        foreach (banned; ["EditorApp", "editor_app", "Ai3dModalRefs",
                          "RemeshModalRefs", "with (", "with("])
            assert(code.count(banned) == 0,
                "6354 no-broad-context witness: registrar names " ~ banned);
    }

    static immutable expectedCounts = [8, 3, 4];
    size_t fileIndex;
    foreach (raw; [settingsRaw, aiRaw, copilotRaw]) {
        size_t assignments;
        bool[string] distinct;
        foreach (m; raw.matchAll(ctRegex!(
                `reg\.commandFactories\["([^"]+)"\]\s*=`))) {
            ++assignments;
            distinct[m.captures[1]] = true;
        }
        assert(assignments == expectedCounts[fileIndex],
            format("6354 A9 assignments: file %d has %d, expected %d",
                   fileIndex, assignments, expectedCounts[fileIndex]));
        assert(distinct.length == expectedCounts[fileIndex],
            format("6354 A9 distinct keys: file %d has %d, expected %d",
                   fileIndex, distinct.length, expectedCounts[fileIndex]));
        ++fileIndex;
    }
    assert(fileIndex == 3,
        "6354 A9 population: fewer than three registrar files were counted");

    const registration = squash(blankNonCode(registrationRaw));
    enum callSettings = "registerViewSettingsCommands(app.reg(), "
        ~ "LiveSessionRole(app.sessionOwner), "
        ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()));";
    enum callAi = "static if (kCopilotEnabled) "
        ~ "registerAiToggleCommands(app.reg(), "
        ~ "LiveSessionRole(app.sessionOwner), "
        ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
        ~ "app.aiState);";
    enum callCopilot = "version (WithAI) static if (kCopilotEnabled) "
        ~ "registerCopilotCommands(app.reg(), "
        ~ "LiveSessionRole(app.sessionOwner), "
        ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
        ~ "app.aiState, app.copilotPanel, "
        ~ "() => app.reg().commandFactories[ ]());";
    assert(registration.count(callSettings) == 1,
        "6354 production wiring: settings call text or multiplicity changed");
    assert(registration.count(callAi) == 1,
        "6354 production wiring: AI call text, arguments, or gate changed");
    assert(registration.count(callCopilot) == 1,
        "6354 production wiring: copilot call text, arguments, or gates changed");
    assert(squash(registrationRaw).count(
        `() => app.reg().commandFactories["mesh.select"]())`) == 1,
        "6354 lazy lookup witness: production no longer passes a fire-time lookup");

    assert(registration.count("registerViewCommands") == 0,
        "6354 old-path witness: registerViewCommands still exists");
    foreach (prefix; [`commandFactories["snap.`, `commandFactories["ai.`,
                      `commandFactories["copilot.`, `commandFactories["path.`,
                      `commandFactories["symmetry.`, `commandFactories["pref.`,
                      `commandFactories["ui.copilotPanel`])
        assert(registrationRaw.count(prefix) == 0,
            "6354 old-path witness: registration.d still owns " ~ prefix);
    foreach (className; ["SnapToggleCommand", "ConstrainToggleCommand",
                         "SnapToggleTypeCommand", "SnapModeCommand",
                         "CoordRoundingCommand", "TrackballPrefCommand",
                         "PathDefineCommand", "SymmetryToggleCommand"])
        assert(registration.count("new " ~ className ~ "(") == 0,
            "6354 old-path witness: registration.d still constructs "
            ~ className);

    const viewportAt = registration.indexOf("registerViewportCommands(");
    const settingsAt = registration.indexOf("registerViewSettingsCommands(");
    const aiAt = registration.indexOf("registerAiToggleCommands(");
    const copilotAt = registration.indexOf("registerCopilotCommands(");
    const wrapperAt = registration.indexOf(
        "auto selTypeSrc = () => currentSelType(selTypeOrder);");
    assert(viewportAt >= 0,
        "6354 ordering floor: viewport registrar call is missing");
    assert(settingsAt > viewportAt,
        "6354 ordering: settings registrar moved before viewport");
    assert(aiAt > settingsAt,
        "6354 ordering: AI registrar moved before settings");
    assert(copilotAt > aiAt,
        "6354 ordering: copilot registrar moved before AI toggles");
    assert(wrapperAt > copilotAt,
        "6354 ordering: selection-type wrapper no longer follows the family");
}
