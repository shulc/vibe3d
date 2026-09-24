module tests.unit.commands.viewport.viewport_command_registration_test;

import core.exception : AssertError;
import std.algorithm : count, sort;
import std.array : join;
import std.exception : assertThrown;
import std.file : dirEntries, readText, SpanMode;
import std.format : format;
import std.math : fabs;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.regex : ctRegex, matchAll, replaceAll;
import std.string : indexOf;

import application_command_binding : CommandInvocationContext,
    CommandInvocationOutcome;
import command : CmdFlags, Command, CommandOrigin;
import commands.viewport.display : ViewportDisplayStyle, ViewportWireAlpha,
    ViewportWireOverlay;
import commands.viewport.fit : Fit;
import commands.viewport.fit_selected : FitSelected;
import commands.viewport.grid_steps : ViewportGridSteps;
import commands.viewport.independence : ViewportIndependence;
import commands.viewport.layout_preset : ViewportLayoutPreset;
import commands.viewport.master : ViewportMaster;
import commands.viewport.view_preset : ViewportViewPreset;
import display_state : DisplayStyle;
import editmode : EditMode;
import live_registration_roles : LiveSessionRole, LiveView, LiveViewModeRole;
import math : Vec3;
import prefs : g_prefs;
import tests.unit.census_symbols : blankNonCode, registrationFamilyBytes;
import tests.unit.live_registration_rig : LiveRegistrationRig;
import view : View;
import viewport : LayoutPreset, ViewportManager;
import viewport_command_registration : registerViewportCommands;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..", "..");

private immutable string[12] kIds = [
    "viewport.fit", "viewport.fit_selected", "viewport.view",
    "viewport.layout", "viewport.indCenter", "viewport.indScale",
    "viewport.indRotate", "viewport.displayStyle", "viewport.wireOverlay",
    "viewport.wireAlpha", "viewport.gridSteps", "viewport.master",
];

private bool isExpectedClass(string id, Command command) {
    switch (id) {
        case "viewport.fit":          return cast(Fit) command !is null;
        case "viewport.fit_selected": return cast(FitSelected) command !is null;
        case "viewport.view":         return cast(ViewportViewPreset) command !is null;
        case "viewport.layout":       return cast(ViewportLayoutPreset) command !is null;
        case "viewport.indCenter":
        case "viewport.indScale":
        case "viewport.indRotate":    return cast(ViewportIndependence) command !is null;
        case "viewport.displayStyle": return cast(ViewportDisplayStyle) command !is null;
        case "viewport.wireOverlay":  return cast(ViewportWireOverlay) command !is null;
        case "viewport.wireAlpha":    return cast(ViewportWireAlpha) command !is null;
        case "viewport.gridSteps":    return cast(ViewportGridSteps) command !is null;
        case "viewport.master":       return cast(ViewportMaster) command !is null;
        default:                       return false;
    }
}

private final class Fixture {
    LiveRegistrationRig rig;
    alias rig this;
    ViewportManager vpm;

    ref View liveView() {
        return vpm.views[vpm.activeId].camera;
    }

    this() {
        rig = new LiveRegistrationRig;
        foreach (ref vertex; layerB.meshRef().vertices)
            vertex.x += 10.0f;
        layerA.meshRef().resetSelection();
        layerB.meshRef().resetSelection();
        layerA.meshRef().selectFace(0);
        layerB.meshRef().selectFace(0);

        vpm = new ViewportManager(0, 0, 800, 600);
        vpm.applyLayout(LayoutPreset.Quad);
        // The rig's own owner topology: group master = cell 3, cell 1 fully
        // independent, cell 2 split. Pinned explicitly since the shipped Quad
        // stores its ortho group in cell 1 (gap 219, task 7139); this test is
        // about fit routing to owners, not about the layout default.
        vpm.masterId = 3;
        vpm.views[1].indCenter = true;
        vpm.views[1].indScale = true;
        vpm.views[2].indCenter = true;
        vpm.views[2].indScale = false;
    }

    LiveViewModeRole viewportLive() {
        return LiveViewModeRole(cast(LiveView)&liveView,
                                session.editModePtr());
    }

    void registerViewport() {
        registerViewportCommands(registry, LiveSessionRole(session),
                                 viewportLive(), vpm);
    }

    void sentinels() {
        foreach (k; 0 .. 4) {
            vpm.views[k].camera.focus = Vec3(100.0f + k, 0, 0);
            vpm.views[k].camera.distance = 50.0f + k;
        }
    }

    CommandInvocationOutcome script(string id, string params = "") {
        return binding.invokeLine(
            id, params,
            CommandInvocationContext(CommandOrigin.script, false)).outcome;
    }
}

private bool near(Vec3 a, Vec3 b) {
    return fabs(a.x - b.x) < 1e-4f && fabs(a.y - b.y) < 1e-4f
        && fabs(a.z - b.z) < 1e-4f;
}

unittest { // U1: every id builds its intended command class
    auto fixture = new Fixture;
    assertThrown!AssertError(
        registerViewportCommands(fixture.registry,
            LiveSessionRole(fixture.session), fixture.viewportLive(), null),
        "6010 null-manager contract must reject registration");
    assert(fixture.registry.commandIds().length == 0,
        "6010 null-manager rejection registered a partial family");

    fixture.registerViewport();
    assert(fixture.registry.commandIds().length == 12,
        format("6010 id population: expected 12 viewport ids, got %d",
               fixture.registry.commandIds().length));
    size_t checked;
    foreach (id; kIds) {
        auto command = fixture.registry.makeCommand(id);
        assert(command !is null, "6010 id witness: missing " ~ id);
        assert(command.name() == id,
            "6010 id witness: " ~ id ~ " builds a command named "
            ~ command.name());
        assert(isExpectedClass(id, command),
            "6010 class witness: " ~ id ~ " builds the wrong class");
        assert(command.cmdFlags() == CmdFlags.UI,
            "6010 camera-only witness: " ~ id ~ " is not a UI command");
        ++checked;
    }
    assert(checked == 12,
        "6010 id witness ran over fewer than 12 ids");
}

unittest { // U2: primary, mode, and active cell resolve after registration
    const prefsBefore = g_prefs.viewportDisplay;
    scope(exit) g_prefs.viewportDisplay = prefsBefore;

    auto fixture = new Fixture;
    fixture.vpm.activeId = 1;
    assert(fixture.session.document.primary is fixture.layerA
        && fixture.session.editMode == EditMode.Vertices,
        "6010 setup: registration must happen while A/Vertices are current");
    fixture.registerViewport();

    fixture.session.document.setPrimary(fixture.layerB);
    fixture.session.switchGeometryType(EditMode.Polygons);
    fixture.vpm.activeId = 0;

    assert(&fixture.session.editMesh() is &fixture.layerB.meshRef()
        && &fixture.layerA.meshRef() !is &fixture.layerB.meshRef()
        && fixture.layerA.meshRef().vertices.length == 8
        && fixture.layerB.meshRef().vertices.length == 6,
        "6010 floor: A and B are not two distinct live layers");
    assert(fixture.vpm.focusOwner(0) == 3
        && fixture.vpm.scaleOwner(0) == 3
        && fixture.vpm.focusOwner(1) == 1
        && fixture.vpm.scaleOwner(1) == 1
        && fixture.vpm.focusOwner(2) == 2
        && fixture.vpm.scaleOwner(2) == 3,
        "6010 floor: Quad owners are not follower/independent/split");

    Vec3[] allVertices;
    foreach (layer; [fixture.layerA, fixture.layerB])
        foreach (vertex; layer.meshRef().vertices)
            allVertices ~= vertex;
    Vec3 allCentre;
    float allDist3;
    float allDist1;
    fixture.vpm.views[3].camera.computeFrame(
        allVertices, allCentre, allDist3);
    fixture.vpm.views[1].camera.computeFrame(
        allVertices, allCentre, allDist1);
    fixture.sentinels();
    assert(!near(allCentre, fixture.vpm.views[3].camera.focus)
        && fabs(allDist3 - fixture.vpm.views[3].camera.distance) > 1e-3f,
        "6010 floor: the expected frame equals the sentinel");

    // C1: follower 0 writes only the focus/scale owner camera 3.
    assert(fixture.script("viewport.fit") == CommandInvocationOutcome.applied,
        "6010 route: viewport.fit did not apply through the binding");
    assert(fixture.vpm.views[1].camera.focus == Vec3(101, 0, 0)
        && fixture.vpm.views[1].camera.distance == 51.0f,
        "6010 registration-time active witness: fit framed cell 1, the cell "
        ~ "that was active when the factory was registered");
    assert(fixture.vpm.views[0].camera.focus == Vec3(100, 0, 0)
        && fixture.vpm.views[0].camera.distance == 50.0f,
        "6010 owner-camera witness: fit wrote the follower's own camera "
        ~ "instead of its focus/scale owners");
    assert(near(fixture.vpm.views[3].camera.focus, allCentre)
        && fabs(fixture.vpm.views[3].camera.distance - allDist3) < 1e-3f,
        "6010 linked-camera witness: the follower's master was not framed");
    assert(fixture.vpm.views[2].camera.focus == Vec3(102, 0, 0),
        "6010 linked-camera witness: an unrelated cell was framed");

    // C2: independent cell 1 fits itself, not the group master.
    fixture.sentinels();
    fixture.vpm.activeId = 1;
    assert(fixture.script("viewport.fit") == CommandInvocationOutcome.applied,
        "6010 route: independent viewport.fit did not apply");
    assert(near(fixture.vpm.views[1].camera.focus, allCentre)
        && fabs(fixture.vpm.views[1].camera.distance - allDist1) < 1e-3f
        && fixture.vpm.views[3].camera.focus == Vec3(103, 0, 0)
        && fixture.vpm.views[3].camera.distance == 53.0f,
        "6010 independent-cell witness: cell 1 did not fit only itself");

    // C3: focus belongs to cell 2 while scale belongs to cell 3.
    fixture.sentinels();
    fixture.vpm.activeId = 2;
    assert(fixture.script("viewport.fit") == CommandInvocationOutcome.applied,
        "6010 route: split viewport.fit did not apply");
    assert(near(fixture.vpm.views[2].camera.focus, allCentre)
        && fixture.vpm.views[2].camera.distance == 52.0f
        && fixture.vpm.views[3].camera.focus == Vec3(103, 0, 0)
        && fabs(fixture.vpm.views[3].camera.distance - allDist3) < 1e-3f,
        "6010 split-owner witness: focus and scale owners were swapped");

    // C5: selected geometry comes from B and lands on the follower owner.
    fixture.sentinels();
    fixture.vpm.activeId = 0;
    auto bVertices = fixture.layerB.meshRef().vertices;
    Vec3 faceCentre;
    float faceDistance;
    fixture.vpm.views[3].camera.computeFrame(
        [bVertices[4], bVertices[0], bVertices[2]],
        faceCentre, faceDistance);
    assert(fixture.script("viewport.fit_selected")
           == CommandInvocationOutcome.applied,
        "6010 route: viewport.fit_selected did not apply");
    assert(fixture.vpm.views[1].camera.focus == Vec3(101, 0, 0)
        && fixture.vpm.views[0].camera.focus == Vec3(100, 0, 0),
        "6010 fit_selected owner witness: framed the registration-time or "
        ~ "the follower's own camera instead of the owner");
    assert(near(fixture.vpm.views[3].camera.focus, faceCentre),
        format("6010 selection witness: fit_selected framed %s, expected B's "
             ~ "selected polygon at %s",
             fixture.vpm.views[3].camera.focus, faceCentre));

    // C5b: fit_selected also honours distinct focus and scale owners.
    fixture.sentinels();
    fixture.vpm.activeId = 2;
    assert(fixture.layerB.meshRef().hasAnySelectedFaces()
        && fixture.vpm.focusOwner(2) == 2
        && fixture.vpm.scaleOwner(2) == 3
        && fixture.vpm.focusOwner(2) != fixture.vpm.scaleOwner(2),
        "6010 C5b floor: selected-face population or split owners collapsed");
    assert(fixture.script("viewport.fit_selected")
           == CommandInvocationOutcome.applied,
        "6010 route: split viewport.fit_selected did not apply");
    assert(near(fixture.vpm.views[2].camera.focus, faceCentre)
        && fixture.vpm.views[2].camera.distance == 52.0f,
        "6010 C5b split-owner witness: fit_selected did not write only focus "
        ~ "to cell 2");
    assert(fixture.vpm.views[3].camera.focus == Vec3(103, 0, 0)
        && fabs(fixture.vpm.views[3].camera.distance - faceDistance) < 1e-3f,
        "6010 C5b split-owner witness: fit_selected did not write only scale "
        ~ "to cell 3");

    // C6: display and independence writes target only the dispatch-time cell.
    fixture.vpm.views[0].display.active.style = DisplayStyle.Wireframe;
    fixture.vpm.views[2].display.active.style = DisplayStyle.Solid;
    fixture.vpm.views[0].indRotate = true;
    fixture.vpm.views[2].indRotate = true;
    fixture.vpm.activeId = 2;
    assert(fixture.script("viewport.displayStyle", `{"value":"shaded"}`)
           == CommandInvocationOutcome.applied,
        "6010 route: viewport.displayStyle did not apply");
    assert(fixture.vpm.views[0].display.active.style == DisplayStyle.Wireframe,
        "6010 display target witness: cell 0 changed although cell 2 is active");
    assert(fixture.vpm.views[2].display.active.style == DisplayStyle.Shaded,
        "6010 display target witness: active cell 2 was not restyled");
    assert(fixture.script("viewport.indRotate", `{"value":false}`)
           == CommandInvocationOutcome.applied,
        "6010 route: viewport.indRotate did not apply");
    assert(fixture.vpm.views[0].indRotate
        && !fixture.vpm.views[2].indRotate,
        "6010 checkbox target witness: indRotate did not land on active cell 2 only");

    // C4: every factory exposes the late-bound mesh, mode, then view.
    fixture.vpm.activeId = 0;
    size_t meshes;
    size_t modes;
    size_t views;
    foreach (id; kIds) {
        auto command = fixture.registry.makeCommand(id);
        assert(command.meshPtr is &fixture.layerB.meshRef(),
            "6010 live primary witness: " ~ id
            ~ " captured the registration-time mesh");
        ++meshes;
    }
    foreach (id; kIds) {
        auto command = fixture.registry.makeCommand(id);
        assert(command.editModeVal == EditMode.Polygons,
            "6010 live mode witness: " ~ id
            ~ " captured the registration-time mode");
        ++modes;
    }
    foreach (id; kIds) {
        auto command = fixture.registry.makeCommand(id);
        immutable isFit = id == "viewport.fit"
            || id == "viewport.fit_selected";
        immutable want = isFit ? 3 : 0;
        int got = -1;
        foreach (k; 0 .. 4)
            if (command.viewRef is fixture.vpm.views[k].camera)
                got = k;
        assert(got == want,
            format("6010 live view witness: %s bound cell %d's camera, expected %d",
                   id, got, want));
        ++views;
    }
    assert(meshes == 12 && modes == 12 && views == 12,
        "6010 live binding witness ran over fewer than 12 factories");
}

unittest { // U3: production uses the narrow registrar before LAST wrapping
    string squash(string source) {
        return replaceAll(source, ctRegex!(`\s+`), " ");
    }

    const registrationRaw = readText(
        buildPath(repoRoot, "source", "registration.d"));
    const registrarRaw = readText(
        buildPath(repoRoot, "source", "viewport_command_registration.d"));
    const appRaw = readText(buildPath(repoRoot, "source", "app.d"));
    size_t registrarFiles;
    const familyBytes = registrationFamilyBytes(repoRoot, registrarFiles);
    assert(registrarFiles >= 15 && familyBytes > 110_000
        && registrarRaw.length > 2_000
        && appRaw.length > 100_000,
        "6509 census population: the registration family shrank unexpectedly — "
      ~ "the viewport registration witness is reading truncated source");

    const registrar = blankNonCode(registrarRaw);
    foreach (banned; ["EditorApp", "editor_app", "Ai3dModalRefs",
                      "RemeshModalRefs", "with (", "with("])
        assert(registrar.count(banned) == 0,
            "6010 no-EditorApp witness: viewport registrar names " ~ banned);
    assert(registrarRaw.count(`reg.registerCommand("viewport.`) == 12,
        "6010 registrar population: expected 12 viewport factory rows");

    const registration = squash(blankNonCode(registrationRaw));
    enum productionCall = "registerViewportCommands(app.reg(), "
        ~ "LiveSessionRole(app.sessionOwner), "
        ~ "LiveViewModeRole(app.cameraViewDg, app.sessionOwner.editModePtr()), "
        ~ "app.vpm);";
    assert(registration.count(productionCall) == 1,
        "6010 production wiring witness: registerCommands does not call the "
        ~ "viewport registrar with inline live roles and the real manager");
    const callAt = registration.indexOf(productionCall);
    const viewFamilyAt = registration.indexOf(
        "registerViewSettingsCommands(app.reg(), ");
    assert(callAt >= 0 && viewFamilyAt > callAt,
        "6010 registration ordering witness: viewport registration must stay "
        ~ "before view/settings registration");
    assert(registrationRaw.count(`registerCommand("viewport.`) == 0
        && registration.count("focusOwnerCamera") == 0
        && registration.count("scaleOwnerCamera") == 0,
        "6010 old-path witness: registration.d still builds a viewport factory");
    foreach (className; ["Fit", "FitSelected", "ViewportViewPreset",
                         "ViewportLayoutPreset", "ViewportIndependence",
                         "ViewportDisplayStyle", "ViewportWireOverlay",
                         "ViewportWireAlpha", "ViewportGridSteps",
                         "ViewportMaster"])
        assert(registration.count("new " ~ className ~ "(") == 0,
            "6010 old-path witness: registration.d still constructs "
            ~ className);

    const app = squash(blankNonCode(appRaw));
    assert(app.count("ref View cameraView() { return vpm.views[vpm.activeId].camera; }") == 1
        && app.count("app.cameraViewDg = cast(ViewDg)&cameraView;") == 1,
        "6010 live view source witness: cameraViewDg no longer reads the active cell");

    string[] vpmWriteSites;
    size_t sourceFiles;
    foreach (entry; dirEntries(buildPath(repoRoot, "source"), "*.d",
                               SpanMode.depth)) {
        ++sourceFiles;
        const code = blankNonCode(readText(entry.name));
        foreach (_; matchAll(code, ctRegex!(`\bvpm\s*=[^=>]`)))
            vpmWriteSites ~= entry.name[repoRoot.length + 1 .. $];
    }
    vpmWriteSites.sort;
    assert(sourceFiles > 500,
        format("6010 vpm census scanned only %d source files", sourceFiles));
    assert(vpmWriteSites == ["source/app.d", "source/app.d",
                             "source/commands/viewport/command_base.d"],
        "6010 single-manager witness: unexpected vpm writers: "
        ~ vpmWriteSites.join(", "));
    assert(app.count("auto vpm = new ViewportManager(") == 1
        && app.count("app.vpm = vpm;") == 1,
        "6010 single-manager witness: app no longer constructs and publishes "
        ~ "exactly one manager");
    const assignAt = app.indexOf("app.vpm = vpm;");
    const registerAt = app.indexOf("registerCommands(app);");
    assert(assignAt >= 0 && registerAt > assignAt,
        "6010 manager wiring order witness: app.vpm is assigned after registration");
}
