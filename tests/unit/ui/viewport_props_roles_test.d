module tests.unit.ui.viewport_props_roles_test;

import std.algorithm : canFind, count;
import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse,
    tempDir, write;
import std.path : buildPath, buildNormalizedPath, dirName;
import std.string : indexOf;
import std.array : join;
import std.format : format;

import command : Command;
import command_args : bindArgs;
import commands.viewport.independence : ViewportIndepAxis,
    ViewportIndependence;
import commands.viewport.master : ViewportMaster;
import commands.viewport.display : ViewportBackdropStyle, ViewportPointSize,
    ViewportRetopology, ViewportRetopologyPreset, ViewportShowVertices,
    ViewportCavity, ViewportCavityParams;
import display_state : BackdropStyle;
import display_state : DisplayStyle;
import display_state : CavityMode;
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
private enum int KEY_UP_ARROW = 515;
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

unittest { // 8620: the Retopology checkbox writes the mode ONLY; the preset writes all five
    auto vpm = new ViewportManager(0, 0, 800, 600);
    vpm.applyLayout(LayoutPreset.Quad);
    vpm.activeId = 2;
    auto mesh = makeCube();
    Prefs prefs;
    auto reset = inertReset(&prefs);
    string[] ids;
    string[] payloads;
    void dispatch(string id, string payload) {
        ids ~= id;
        payloads ~= payload;
        Command command;
        if (id == "viewport.retopology")
            command = new ViewportRetopology(&mesh,
                vpm.views[vpm.activeId].camera, EditMode.Polygons, vpm);
        else if (id == "viewport.retopologyPreset")
            command = new ViewportRetopologyPreset(&mesh,
                vpm.views[vpm.activeId].camera, EditMode.Polygons, vpm);
        else
            assert(false, "unexpected viewport properties dispatch: " ~ id);
        bindArgs(command, payload);
        assert(command.apply(), "viewport properties command fixture refused");
    }
    auto ui = openPanel(() {
        drawViewportPropsPanel(ViewportPropertiesReadRole(vpm),
                               cast(ViewportCommandDispatch)&dispatch, reset);
    }, "Viewport retopology host");
    resetViewportPropsDrawSnapshot();
    scope (exit) ui.close();
    ui.frame();
    auto snap = viewportPropsDrawSnapshot();
    const d0 = vpm.views[0].display;
    assert(!vpm.views[2].display.retopology,
        "8620 checkbox precondition: the mode starts off in the active cell");

    ui.pressAt(center(snap.retopologyMin, snap.retopologyMax));
    ui.release();
    assert(ids == ["viewport.retopology"],
        "8620 checkbox dispatch witness: expected exactly viewport.retopology");
    assert(payloads[0].indexOf(`"on"`) >= 0,
        "8620 checkbox did not dispatch its toggled value");
    const t = vpm.views[2].display;
    assert(t.retopology && t.backdropStyle == BackdropStyle.SameAsActive
        && !t.active.showVertices && t.active.pointSize == 0.0f,
        "8620 toggle-only: the checkbox must write the mode and nothing else");
    assert(vpm.views[0].display == d0,
        "8620 checkbox reached a cell other than the active one");

    // Mode back off by hand, so the preset's own mode write is observable.
    vpm.views[2].display.retopology = false;
    ui.frame();
    snap = viewportPropsDrawSnapshot();
    ui.pressAt(center(snap.presetMin, snap.presetMax));
    ui.release();
    assert(ids == ["viewport.retopology", "viewport.retopologyPreset"],
        "8620 preset dispatch witness: expected exactly viewport.retopologyPreset");
    const p = vpm.views[2].display;
    assert(p.retopology && p.backdropStyle == BackdropStyle.Flat
        && p.backdrop.style == DisplayStyle.Shaded
        && p.active.showVertices && p.active.pointSize == 6.0f,
        "8620 preset button: the active cell must carry the five preset atoms");

    ui.frame();
    snap = viewportPropsDrawSnapshot();
    ui.pressAt(center(snap.retopologyMin, snap.retopologyMax));
    ui.release();
    assert(ids.length == 3 && ids[2] == "viewport.retopology"
        && payloads[2].indexOf(`"off"`) >= 0 && !vpm.views[2].display.retopology,
        "8620 checkbox must read the live mode and dispatch its inverse");
}

unittest { // 8620: the backdrop chooser, Vertices checkbox and point size slider
    auto vpm = new ViewportManager(0, 0, 800, 600);
    vpm.applyLayout(LayoutPreset.Quad);
    vpm.activeId = 1;
    auto mesh = makeCube();
    Prefs prefs;
    auto reset = inertReset(&prefs);
    string[] ids;
    void dispatch(string id, string payload) {
        ids ~= id;
        Command command;
        auto cam = vpm.views[vpm.activeId].camera;
        if (id == "viewport.backdropStyle")
            command = new ViewportBackdropStyle(&mesh, cam, EditMode.Polygons, vpm);
        else if (id == "viewport.showVertices")
            command = new ViewportShowVertices(&mesh, cam, EditMode.Polygons, vpm);
        else if (id == "viewport.pointSize")
            command = new ViewportPointSize(&mesh, cam, EditMode.Polygons, vpm);
        else
            assert(false, "unexpected viewport properties dispatch: " ~ id);
        bindArgs(command, payload);
        assert(command.apply(), "viewport properties command fixture refused");
    }
    auto ui = openPanel(() {
        drawViewportPropsPanel(ViewportPropertiesReadRole(vpm),
                               cast(ViewportCommandDispatch)&dispatch, reset);
    }, "Viewport retopology controls host");
    resetViewportPropsDrawSnapshot();
    scope (exit) ui.close();
    ImGui.GetIO().ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;
    ui.frame();
    auto snap = viewportPropsDrawSnapshot();
    const d0 = vpm.views[0].display;

    ui.pressAt(center(snap.verticesMin, snap.verticesMax));
    ui.release();
    assert(ids == ["viewport.showVertices"] && vpm.views[1].display.active.showVertices,
        "8620 Vertices checkbox must dispatch viewport.showVertices on the active cell");

    ui.frame();
    snap = viewportPropsDrawSnapshot();
    ui.pressAt(center(snap.pointSizeMin, snap.pointSizeMax));
    ui.release();
    const ps = vpm.views[1].display.active.pointSize;
    assert(ids.length == 2 && ids[1] == "viewport.pointSize" && ps > 0.0f && ps <= 16.0f,
        "8620 point size slider must dispatch viewport.pointSize on the active cell");

    // Every chooser option, selected through the real parser. The combo
    // opens with the current option focused, so each pick is a signed step
    // from the previous one; the order visits all four with no repeat, and
    // each pick changes the value, so an id or row swap reddens a named step.
    // The steps are positional, so the panel's row order is pinned here too.
    static struct Pick { int steps; BackdropStyle want; string name; }
    static immutable Pick[4] picks = [
        Pick( 1, BackdropStyle.Wireframe,    "wireframe"),
        Pick( 2, BackdropStyle.Hidden,       "hidden"),
        Pick(-1, BackdropStyle.Flat,         "flat"),
        Pick(-2, BackdropStyle.SameAsActive, "same"),
    ];
    assert(vpm.views[1].display.backdropStyle == BackdropStyle.SameAsActive,
        "8620 chooser precondition: the active cell starts on Same as Active");
    size_t picked;
    foreach (pk; picks) {
        ui.frame();
        snap = viewportPropsDrawSnapshot();
        ui.pressAt(center(snap.backdropMin, snap.backdropMax));
        ui.release();
        const key = pk.steps > 0 ? KEY_DOWN_ARROW : KEY_UP_ARROW;
        foreach (_; 0 .. (pk.steps > 0 ? pk.steps : -pk.steps)) {
            ui.keyDown(key);
            ui.frame();
            ui.keyUp(key);
            ui.frame();
        }
        ui.keyDown(cast(int)ImGuiKey.Enter);
        ui.frame();
        ui.keyUp(cast(int)ImGuiKey.Enter);
        ui.frame();
        ++picked;
        assert(ids.length == 2 + picked && ids[$ - 1] == "viewport.backdropStyle"
            && vpm.views[1].display.backdropStyle == pk.want,
            "8620 backdrop chooser must dispatch viewport.backdropStyle " ~ pk.name);
        if (pk.want == BackdropStyle.Flat)
            assert(vpm.views[1].display.backdrop.style == DisplayStyle.Shaded,
                "8620 backdrop flat must write Shaded into the backdrop slot");
    }
    assert(picked == 4, "8620 chooser census: all four options must be picked");
    assert(vpm.views[0].display == d0,
        "8620 the retopology controls reached a cell other than the active one");
}

unittest { // S3a: the Cavity combo and Ridge/Valley sliders; greyed off Shaded / under retopology
    auto vpm = new ViewportManager(0, 0, 800, 600);
    vpm.applyLayout(LayoutPreset.Quad);
    vpm.activeId = 1;
    auto mesh = makeCube();
    Prefs prefs;
    auto reset = inertReset(&prefs);
    string[] ids;
    string[] payloads;
    void dispatch(string id, string payload) {
        ids ~= id;
        payloads ~= payload;
        Command command;
        auto cam = vpm.views[vpm.activeId].camera;
        if (id == "viewport.cavity")
            command = new ViewportCavity(&mesh, cam, EditMode.Polygons, vpm);
        else if (id == "viewport.cavityParams")
            command = new ViewportCavityParams(&mesh, cam, EditMode.Polygons, vpm);
        else
            assert(false, "unexpected viewport properties dispatch: " ~ id);
        bindArgs(command, payload);
        assert(command.apply(), "viewport properties command fixture refused: " ~ id ~ " " ~ payload);
    }
    auto ui = openPanel(() {
        drawViewportPropsPanel(ViewportPropertiesReadRole(vpm),
                               cast(ViewportCommandDispatch)&dispatch, reset);
    }, "Viewport cavity controls host");
    resetViewportPropsDrawSnapshot();
    scope (exit) ui.close();
    ImGui.GetIO().ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;
    vpm.views[1].display.active.style = DisplayStyle.Shaded;
    assert(vpm.views[1].display.active.style == DisplayStyle.Shaded
        && !vpm.views[1].display.retopology
        && vpm.views[1].display.cavity.mode == CavityMode.Off,
        "S3a precondition: the active cell starts Shaded, retopology off, cavity Off");
    const d0 = vpm.views[0].display;

    // Every combo option through the real parser (signed steps from the
    // previous pick, as the backdrop chooser above).
    static struct Pick { int steps; CavityMode want; string name; }
    static immutable Pick[4] picks = [
        Pick( 1, CavityMode.Screen, "screen"),
        Pick( 2, CavityMode.Both,   "both"),
        Pick(-1, CavityMode.World,  "world"),
        Pick(-2, CavityMode.Off,    "off"),
    ];
    size_t picked;
    foreach (pk; picks) {
        ui.frame();
        auto snap = viewportPropsDrawSnapshot();
        ui.pressAt(center(snap.cavityMin, snap.cavityMax));
        ui.release();
        const key = pk.steps > 0 ? KEY_DOWN_ARROW : KEY_UP_ARROW;
        foreach (_; 0 .. (pk.steps > 0 ? pk.steps : -pk.steps)) {
            ui.keyDown(key);
            ui.frame();
            ui.keyUp(key);
            ui.frame();
        }
        ui.keyDown(cast(int)ImGuiKey.Enter);
        ui.frame();
        ui.keyUp(cast(int)ImGuiKey.Enter);
        ui.frame();
        ++picked;
        assert(ids.length == picked && ids[$ - 1] == "viewport.cavity"
            && vpm.views[1].display.cavity.mode == pk.want,
            "S3a cavity combo must dispatch viewport.cavity " ~ pk.name);
    }
    assert(picked == 4, "S3a combo census: all four options must be picked");

    // The sliders: start both off the centre value so a press at the centre
    // (about 1.0 on 0..2) is a change.
    vpm.views[1].display.cavity.screenRidge = 0.25f;
    vpm.views[1].display.cavity.screenValley = 0.25f;
    ui.frame();
    auto snap = viewportPropsDrawSnapshot();
    ui.pressAt(center(snap.cavityRidgeMin, snap.cavityRidgeMax));
    ui.release();
    const r = vpm.views[1].display.cavity.screenRidge;
    assert(ids.length == 5 && ids[4] == "viewport.cavityParams" && payloads[4].indexOf("screenRidge") >= 0
        && r > 0.5f && r < 1.5f && vpm.views[1].display.cavity.screenValley == 0.25f,
        "S3a ridge slider must dispatch viewport.cavityParams screenRidge only");
    ui.frame();
    snap = viewportPropsDrawSnapshot();
    ui.pressAt(center(snap.cavityValleyMin, snap.cavityValleyMax));
    ui.release();
    const v = vpm.views[1].display.cavity.screenValley;
    assert(ids.length == 6 && ids[5] == "viewport.cavityParams" && payloads[5].indexOf("screenValley") >= 0
        && v > 0.5f && v < 1.5f && vpm.views[1].display.cavity.screenRidge == r,
        "S3a valley slider must dispatch viewport.cavityParams screenValley only");
    assert(vpm.views[0].display == d0, "S3a the cavity controls reached a cell other than the active one");

    // Greyed: the same presses dispatch nothing off Shaded and under
    // retopology (the presses above are the positive control).
    // Each press must take NO ActiveId (a disabled widget) and dispatch
    // nothing; the presses above are the positive control.
    size_t pressedDisabled;
    void pressAll(string why) {
        ui.frame();
        auto sn = viewportPropsDrawSnapshot();
        foreach (k, rc; [[sn.cavityMin, sn.cavityMax], [sn.cavityRidgeMin, sn.cavityRidgeMax],
                         [sn.cavityValleyMin, sn.cavityValleyMax]]) {
            assert(!ui.tryPressAt(center(rc[0], rc[1])),
                format("S3a %s: cavity control %d took the press (it must be disabled)", why, k));
            ui.release();
            ++pressedDisabled;
        }
    }
    vpm.views[1].display.active.style = DisplayStyle.Solid;
    pressAll("under Solid");
    assert(ids.length == 6, "S3a under Solid the cavity controls must be disabled (dispatched " ~ ids[6 .. $].join(",") ~ ")");
    vpm.views[1].display.active.style = DisplayStyle.Shaded;
    vpm.views[1].display.retopology = true;
    pressAll("under retopology");
    assert(ids.length == 6, "S3a under retopology the cavity controls must be disabled (dispatched "
        ~ ids[6 .. $].join(",") ~ ")");
    assert(pressedDisabled == 6, format("S3a population: 6 disabled presses, made %d", pressedDisabled));
}

unittest { // S3b: the world-cavity Distance / Attenuation / Samples sliders, World and Both only
    auto vpm = new ViewportManager(0, 0, 800, 600);
    vpm.applyLayout(LayoutPreset.Quad);
    vpm.activeId = 1;
    auto mesh = makeCube();
    Prefs prefs;
    auto reset = inertReset(&prefs);
    string[] ids;
    string[] payloads;
    void dispatch(string id, string payload) {
        ids ~= id;
        payloads ~= payload;
        assert(id == "viewport.cavityParams", "unexpected viewport properties dispatch: " ~ id);
        Command command = new ViewportCavityParams(&mesh, vpm.views[vpm.activeId].camera,
                                                   EditMode.Polygons, vpm);
        bindArgs(command, payload);
        assert(command.apply(), "viewport properties command fixture refused: " ~ id ~ " " ~ payload);
    }
    auto ui = openPanel(() {
        drawViewportPropsPanel(ViewportPropertiesReadRole(vpm),
                               cast(ViewportCommandDispatch)&dispatch, reset);
    }, "Viewport world cavity controls host");
    resetViewportPropsDrawSnapshot();
    scope (exit) ui.close();
    vpm.views[1].display.active.style = DisplayStyle.Shaded;
    const d0 = vpm.views[0].display;

    // Hidden for Off and Screen; three sliders for World and Both.
    size_t modes;
    foreach (m; [CavityMode.Off, CavityMode.Screen, CavityMode.World, CavityMode.Both]) {
        vpm.views[1].display.cavity.mode = m;
        ui.frame();
        immutable int want = (m == CavityMode.World || m == CavityMode.Both) ? 3 : 0;
        assert(viewportPropsDrawSnapshot().cavityWorldDrawn == want,
            format("S3b %s: %d world sliders drawn, expected %d", m,
                   viewportPropsDrawSnapshot().cavityWorldDrawn, want));
        ++modes;
    }
    assert(modes == 4 && ids.length == 0, "S3b population: 4 modes drawn, nothing dispatched");

    // A press at each slider's centre writes only its own value (start values
    // far from the centre, so the press is a change).
    vpm.views[1].display.cavity.mode = CavityMode.World;
    vpm.views[1].display.cavity.distance = 0.02f;
    vpm.views[1].display.cavity.attenuation = 0.1f;
    vpm.views[1].display.cavity.samples = 2;
    static immutable string[3] keys = ["distance", "attenuation", "samples"];
    foreach (k; 0 .. 3) {
        ui.frame();
        auto snap = viewportPropsDrawSnapshot();
        ui.pressAt(center(snap.cavityWorldMin[k], snap.cavityWorldMax[k]));
        ui.release();
        assert(ids.length == k + 1 && payloads[k].indexOf(keys[k]) >= 0
            && payloads[k].indexOf(",") < 0,
            format("S3b slider %d must dispatch viewport.cavityParams %s alone, got %s", k, keys[k], payloads));
    }
    const c = vpm.views[1].display.cavity;
    assert(c.distance > 0.4f && c.distance < 0.6f, format("S3b distance after a centre press: %s", c.distance));
    assert(c.attenuation > 4.0f && c.attenuation < 6.0f, format("S3b attenuation after a centre press: %s", c.attenuation));
    assert(c.samples >= 28 && c.samples <= 37, format("S3b samples after a centre press: %s", c.samples));
    assert(vpm.views[0].display == d0, "S3b the world cavity sliders reached a cell other than the active one");

    // Greyed under Solid (drawn, disabled): presses take nothing.
    vpm.views[1].display.active.style = DisplayStyle.Solid;
    ui.frame();
    auto sn = viewportPropsDrawSnapshot();
    assert(sn.cavityWorldDrawn == 3, "S3b under Solid the world sliders stay drawn (greyed)");
    foreach (k; 0 .. 3) {
        assert(!ui.tryPressAt(center(sn.cavityWorldMin[k], sn.cavityWorldMax[k])),
            format("S3b under Solid world slider %d took the press", k));
        ui.release();
    }
    assert(ids.length == 3, "S3b under Solid the world sliders must dispatch nothing");
}
