module tests.unit.ui.viewport_props_roles_test;

import std.algorithm : canFind, count;
import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse,
    tempDir, write;
import std.path : buildPath, buildNormalizedPath, dirName;
import std.string : indexOf;

import command : Command;
import command_args : bindArgs;
import commands.viewport.independence : ViewportIndepAxis,
    ViewportIndependence;
import commands.viewport.master : ViewportMaster;
import display_state : DisplayStyle;
import editmode : EditMode;
import layout_reset_action : LayoutResetAction;
import mesh : makeCube;
import prefs : Prefs, seedLayoutIniIfMissing;
import tests.unit.ui.headless_panel : openPanel;
import ui.panels : drawViewportPropsPanel, resetViewportPropsDrawSnapshot,
    viewportPropsDrawSnapshot;
import ui.viewport_props_role : ViewportCommandDispatch,
    ViewportPropertiesReadRole;
import viewport : LayoutPreset, ViewportManager;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiConfigFlags, ImGuiKey, ImVec2;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..");
private enum int KEY_DOWN_ARROW = 516;

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "5850 census missing source marker " ~ marker);
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "5850 census found no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "5850 census found unterminated body after " ~ marker);
    return null;
}

private ImVec2 center(ImVec2 lo, ImVec2 hi) {
    assert(hi.x > lo.x && hi.y > lo.y,
        "viewport properties widget did not publish a clickable rectangle");
    return ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
}

private LayoutResetAction inertReset(Prefs* prefs) {
    return new LayoutResetAction(prefs, true, (string) => false, (string) {});
}

unittest { // Quad panel projects and commands the live active cell on each draw
    auto vpm = new ViewportManager(0, 0, 800, 600);
    vpm.applyLayout(LayoutPreset.Quad);
    static immutable DisplayStyle[4] styles = [
        DisplayStyle.Wireframe, DisplayStyle.Solid,
        DisplayStyle.Shaded, DisplayStyle.Weight,
    ];
    foreach (i; 0 .. 4) {
        vpm.views[i].camera.distance = 10.0f + cast(float)i;
        vpm.views[i].display.active.style = styles[i];
        vpm.views[i].masterId = i == 2 ? -1 : cast(int)i;
    }
    vpm.views[0].indCenter = true;
    assert(vpm.cellCount == 4
        && vpm.views[0].camera.distance != vpm.views[1].camera.distance
        && vpm.views[1].camera.distance != vpm.views[2].camera.distance
        && vpm.views[2].camera.distance != vpm.views[3].camera.distance,
        "5850 Quad fixture needs four live cells with different cameras");
    assert(vpm.views[0].display.active.style !=
           vpm.views[2].display.active.style,
        "5850 Quad fixture needs distinguishable active-cell styles");

    auto mesh = makeCube();
    Prefs prefs;
    auto reset = inertReset(&prefs);
    string[] ids;
    string[] payloads;
    void dispatch(string id, string payload) {
        ids ~= id;
        payloads ~= payload;
        Command command;
        if (id == "viewport.indCenter")
            command = new ViewportIndependence(&mesh,
                vpm.views[vpm.activeId].camera, EditMode.Polygons, vpm,
                ViewportIndepAxis.Center);
        else if (id == "viewport.master")
            command = new ViewportMaster(&mesh,
                vpm.views[vpm.activeId].camera, EditMode.Polygons, vpm);
        else
            assert(false, "unexpected viewport properties dispatch: " ~ id);
        bindArgs(command, payload);
        assert(command.apply(), "viewport properties command fixture refused");
    }

    auto role = ViewportPropertiesReadRole(vpm);
    auto ui = openPanel(() {
        drawViewportPropsPanel(role, cast(ViewportCommandDispatch)&dispatch,
                               reset);
    }, "Viewport properties host");
    resetViewportPropsDrawSnapshot();
    scope (exit) ui.close();
    ImGui.GetIO().ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;

    vpm.activeId = 0;
    ui.frame();
    auto snap = viewportPropsDrawSnapshot();
    assert(snap.activeId == 0
        && snap.displayStyle == cast(int)DisplayStyle.Wireframe,
        "5850 live projection setup did not read active cell 0");

    vpm.activeId = 2;
    ui.frame();
    snap = viewportPropsDrawSnapshot();
    assert(snap.activeId == 2
        && snap.displayStyle == cast(int)DisplayStyle.Shaded,
        "5850 retained-active witness: the next draw still projected cell 0");

    assert(!vpm.views[2].indCenter && vpm.views[0].indCenter,
        "5850 checkbox precondition needs opposite values in cells 0 and 2");
    ui.pressAt(center(snap.centerMin, snap.centerMax));
    ui.release();
    assert(ids.length == 1 && ids[0] == "viewport.indCenter",
        "5850 UI dispatch witness: Center bypassed command dispatch");
    assert(vpm.views[2].indCenter && vpm.views[0].indCenter,
        "5850 active-cell checkbox witness: Center used cell 0's projected value");
    assert(payloads[0].indexOf(`"yes"`) >= 0,
        "5850 Center checkbox did not dispatch its toggled value");

    snap = viewportPropsDrawSnapshot();
    ui.pressAt(center(snap.masterMin, snap.masterMax));
    ui.release();
    snap = viewportPropsDrawSnapshot();
    center(snap.masterOptionMin[2], snap.masterOptionMax[2]);
    foreach (_; 0 .. 2) {
        ui.keyDown(KEY_DOWN_ARROW);
        ui.frame();
        ui.keyUp(KEY_DOWN_ARROW);
        ui.frame();
    }
    ui.keyDown(cast(int)ImGuiKey.Enter);
    ui.frame();
    ui.keyUp(cast(int)ImGuiKey.Enter);
    ui.frame();
    assert(ids.length == 2 && ids[1] == "viewport.master",
        "5850 master UI dispatch witness: selector bypassed command dispatch");
    assert(vpm.views[2].masterId == 1 && vpm.views[0].masterId == 0,
        "5850 active-cell master witness: selector used the wrong cell's default focus");
}

unittest { // successful restore stays deferred until the pre-frame boundary
    const root = buildPath(tempDir(), "vibe3d-5850-layout-success");
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    const shipped = buildPath(root, "shipped.ini");
    const userIni = buildPath(root, "user.ini");
    const shippedBytes = "[Window][ViewportHost]\nPos=17,23\n";
    write(shipped, shippedBytes);
    write(userIni, "old-user-layout\n");
    assert(readText(shipped).length > 20 && readText(userIni).length > 5
        && readText(shipped) != readText(userIni),
        "5850 success floor needs a non-empty changed ini");

    Prefs prefs;
    prefs.viewportLayout = LayoutPreset.Quad;
    size_t loadCalls;
    string loadedBytes;
    string[] order;
    auto action = new LayoutResetAction(&prefs, false,
        (string path) {
            order ~= "restore";
            return seedLayoutIniIfMissing(shipped, path);
        },
        (string path) {
            order ~= "load";
            ++loadCalls;
            loadedBytes = readText(path);
        });
    action.bindLayoutIniPath(userIni);

    auto vpm = new ViewportManager(0, 0, 800, 600);
    auto ui = openPanel(() {
        drawViewportPropsPanel(ViewportPropertiesReadRole(vpm),
            cast(ViewportCommandDispatch)((string id, string payload) {}), action);
    }, "Viewport reset success host");
    resetViewportPropsDrawSnapshot();
    scope (exit) ui.close();
    ui.frame();
    auto snap = viewportPropsDrawSnapshot();
    ui.pressAt(center(snap.resetMin, snap.resetMax));
    ui.release();

    assert(prefs.viewportLayout == LayoutPreset.Single
        && readText(userIni) == shippedBytes,
        "5850 successful reset did not persist Single and restore shipped ini");
    assert(loadCalls == 0 && order == ["restore"] && action.pendingReload(),
        "5850 authoring-order witness: ini reloaded inside the button frame");
    assert(!action.fallbackReseed(),
        "5850 successful restore incorrectly armed fallback reseed");

    action.reloadBeforeFrame();
    assert(loadCalls == 1 && loadedBytes == shippedBytes
        && order == ["restore", "load"] && !action.pendingReload(),
        "5850 pre-NewFrame reload did not consume the restored non-empty ini");
    ui.frame();
    action.reloadBeforeFrame();
    assert(loadCalls == 1,
        "5850 restored ini reload was not one-shot");
}

unittest { // missing shipped ini takes the separate fallback cell
    const root = buildPath(tempDir(), "vibe3d-5850-layout-fallback");
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    const userIni = buildPath(root, "user.ini");
    write(userIni, "genuinely non-empty prior layout\n");
    assert(readText(userIni).length > 10,
        "5850 fallback floor needs a genuinely non-empty ini");

    Prefs prefs;
    prefs.viewportLayout = LayoutPreset.Quad;
    size_t restoreCalls;
    size_t loadCalls;
    auto action = new LayoutResetAction(&prefs, false,
        (string) { ++restoreCalls; return false; },
        (string) { ++loadCalls; });
    action.bindLayoutIniPath(userIni);

    auto vpm = new ViewportManager(0, 0, 800, 600);
    auto ui = openPanel(() {
        drawViewportPropsPanel(ViewportPropertiesReadRole(vpm),
            cast(ViewportCommandDispatch)((string id, string payload) {}), action);
    }, "Viewport reset fallback host");
    resetViewportPropsDrawSnapshot();
    scope (exit) ui.close();
    ui.frame();
    auto snap = viewportPropsDrawSnapshot();
    ui.pressAt(center(snap.resetMin, snap.resetMax));
    ui.release();

    assert(restoreCalls == 1 && loadCalls == 0 && !exists(userIni),
        "5850 fallback cell did not attempt one restore after removing old ini");
    assert(prefs.viewportLayout == LayoutPreset.Single,
        "5850 fallback floor: a genuinely Quad setting did not change to Single");
    assert(!action.pendingReload() && action.fallbackReseed(),
        "5850 fallback cell did not arm only the programmatic reseed");
    assert(action.consumeFallbackReseed() && !action.consumeFallbackReseed(),
        "5850 fallback reseed request was not one-shot");
}

unittest { // test mode never deletes a real-user ini path
    const root = buildPath(tempDir(), "vibe3d-5850-layout-test-mode");
    if (exists(root)) rmdirRecurse(root);
    mkdirRecurse(root);
    scope (exit) if (exists(root)) rmdirRecurse(root);
    const userIni = buildPath(root, "user.ini");
    const original = "real-user-layout-must-survive\n";
    write(userIni, original);

    Prefs prefs;
    prefs.viewportLayout = LayoutPreset.Quad;
    size_t restoreCalls;
    auto action = new LayoutResetAction(&prefs, true,
        (string) { ++restoreCalls; return true; }, (string) {});
    action.bindLayoutIniPath(userIni);
    action.authorReset();
    assert(exists(userIni) && readText(userIni) == original
        && restoreCalls == 0,
        "5850 test-mode safety witness: reset deleted a real user ini");
    assert(prefs.viewportLayout == LayoutPreset.Single
        && action.fallbackReseed() && !action.pendingReload(),
        "test-mode reset did not preserve the existing in-memory fallback path");
}

unittest { // production wiring for the collaborators built above
    const app = readText(buildPath(repoRoot, "source", "app.d"));
    const panel = readText(buildPath(repoRoot, "source", "ui", "panels.d"));
    const role = readText(buildPath(repoRoot, "source", "ui",
                                    "viewport_props_role.d"));
    const action = readText(buildPath(repoRoot, "source",
                                      "layout_reset_action.d"));
    const editor = readText(buildPath(repoRoot, "source", "editor_app.d"));

    assert(role.length > 1_000 && action.length > 2_500,
        "5850 production census population: role/action sources are too small");
    assert(role.count("EditorApp") == 0 && role.count("editor_app") == 0
        && action.count("EditorApp") == 0 && action.count("editor_app") == 0,
        "5850 no-EditorApp witness: a narrow role/action reaches EditorApp");
    assert(panel.indexOf(
        "void drawViewportPropsPanel(ViewportPropertiesReadRole viewportRead,") >= 0
        && panel.indexOf("void drawViewportPropsPanel(EditorApp") < 0,
        "5850 panel signature witness: Viewport Properties regained EditorApp");

    enum productionPanelCall =
        "drawViewportPropsPanel(ViewportPropertiesReadRole(vpm),\n"
        ~ "                                   uiCommandDelegate, layoutResetAction);";
    assert(app.count(productionPanelCall) == 1,
        "5850 production panel wiring witness: the real call lost its three roles");
    assert(app.count("uiCommandDelegate = (string id, string paramsJson) {\n"
        ~ "        commandBinding.dispatchUi(id, paramsJson);\n    };") == 1,
        "5850 production dispatch witness: panel dispatch no longer reaches the application command binding");

    enum frameMarker = "void frame() {";
    assert(app.count(frameMarker) == 1,
        "5850 production frame anchor must occur exactly once");
    const frameBody = bodyAt(app, frameMarker);
    const reloadAt = frameBody.indexOf("layoutResetAction.reloadBeforeFrame();");
    const newFrameAt = frameBody.indexOf("ImGui.NewFrame();", reloadAt);
    assert(reloadAt >= 0 && reloadAt < newFrameAt
        && app.count("layoutResetAction.reloadBeforeFrame();") == 1,
        "5850 production reload witness: reset ini is not consumed once inside the frame loop before NewFrame");
    assert(app.count(
        "const forceLayoutReseed = layoutResetAction.consumeFallbackReseed();") == 1,
        "5850 production fallback witness: dock seeding lost the reset action");
    assert(app.count("layoutResetAction.bindLayoutIniPath(userIniPath);") == 1
        && app.count("io.IniFilename = layoutResetAction.iniFilename();") == 1,
        "5850 production ini-owner witness: ImGui does not use the reset owner's stable path");

    immutable string[] retired = [
        "g_layoutIniPathZ", "g_forceLayoutReseed",
        "g_pendingLayoutReloadPathZ",
    ];
    foreach (name; retired)
        assert(!app.canFind(name) && !panel.canFind(name)
            && !editor.canFind(name),
            "5850 retired layout-reset storage remains beside the owner: " ~ name);
}
