module tests.unit.ui.image_list_panel_roles_test;

import std.algorithm : canFind, count;
import std.file : SpanMode, dirEntries, readText;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;
import tests.unit.census_symbols : blankNonCode;

import bindbc.sdl : KMOD_NONE, SDL_SetModState, loadSDL, sdlSupport;
import application_command_binding : ApplicationCommandBinding;
import command : Command, g_testMode;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.image.commands : ImageLoad, ImageRemove;
import commands.layer.commands : LayerDelete, LayerRename, LayerSelect;
import document : Document, ImageData, ItemKind, Layer;
import edit_session : EditSession;
import forms_render : FormsPanel;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import mesh : makeCube;
import registry : Registry;
import session_owner : Session;
import tests.unit.ui.headless_panel : HeadlessPanel, KEY_LEFT_CTRL, MOD_CTRL,
    openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import ui.discard_guard : GuardRecord;
import ui.image_list_panel : ImageListDrawSnapshot, ImageListDrawnRow,
    ImageListPanelRoles, bindImageListPanel, drawImageListPanel,
    imageListDrawSnapshot, resetImageListDrawSnapshot;
import ui.item_rename : ItemRenameState;
import ui.layer_list_panel : LayerListDrawnRow, LayerListPanelRoles,
    bindLayerListPanel, drawLayerListPanel, layerListDrawSnapshot,
    resetLayerListDrawSnapshot;
import view : View;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiKey, ImVec2;

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..");

private Layer meshLayer(string name) {
    auto l = new Layer; l.name = name; l.meshRef() = makeCube(); return l;
}
private Layer imageLayer(string name) {
    auto l = new Layer; l.kind = ItemKind.Image; l.name = name;
    l.imageRef() = new ImageData; return l;
}
// [0] Alpha mesh  [1] Beta mesh  [2] ImgOne  [3] ImgTwo  [4] Consumer -> ImgOne
private Document imageDocument() {
    Document d = Document.bootstrap(makeCube());
    d.layers[0].name = "Alpha";
    d.layers ~= meshLayer("Beta");
    auto one = imageLayer("ImgOne");
    d.layers ~= one;
    d.layers ~= imageLayer("ImgTwo");
    auto consumer = new Layer;
    consumer.kind = ItemKind.Empty;
    consumer.name = "Consumer";
    d.layers ~= consumer;
    consumer.setLink("backdropImage", one);
    d.setActive(0);
    return d;
}

private final class ImagePanelHarness {
    Session* owner;
    View view;
    Registry registry;
    CommandHistory history;
    CommandExecutor executor;
    EditSession editSession;
    GuardRecord[] records;
    size_t notices;
    GuardedActionController guard;
    ApplicationCommandBinding binding;
    Tool activeTool;
    ItemRenameState renameState;
    ImageListPanelRoles imageRoles;
    FormsPanel forms;
    LayerListPanelRoles layerRoles;

    this() {
        owner = Session.create(imageDocument());
        assert(owner.document.layers.length == 5
            && owner.document.layers[2].hasImage
            && owner.document.layers[3].hasImage,
            "6040 fixture floor: two image items at 2/3 before binding");
        view = new View(0, 0, 800, 600);
        history = new CommandHistory;
        executor = new CommandExecutor(history, () => activeTool !is null,
            (ToolTransition) { activeTool = null; });
        editSession = new EditSession(() => activeTool, history,
            () { activeTool = null; });
        guard = new GuardedActionController(GuardedActionPorts(
            (Command c, RecordMode m) => executor.applyOrRefire(c, m, null),
            () => false, () => true, (Command) { ++notices; },
            GuardObservationPorts((r) { records ~= r; }, (a, p) {}, (p) {})));
        binding = new ApplicationCommandBinding(registry, executor,
            editSession, history, guard, (Command) {}, (string) {});
        registry.commandFactories["layer.select"] = () => cast(Command)
            new LayerSelect(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null);
        registry.commandFactories["layer.rename"] = () => cast(Command)
            new LayerRename(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null);
        registry.commandFactories["layer.delete"] = () => cast(Command)
            new LayerDelete(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null);
        registry.commandFactories["image.load"] = () => cast(Command)
            new ImageLoad(owner.document.activeMesh(), view, owner.editMode,
                          owner.documentPtr(), null);
        registry.commandFactories["image.remove"] = () => cast(Command)
            new ImageRemove(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null);
        imageRoles = bindImageListPanel(owner, binding);
        forms = new FormsPanel;
        layerRoles = bindLayerListPanel(owner, binding, forms, () => activeTool);
    }

    void clearRecords() {
        history.clear();
        records.length = 0;
        notices = 0;
        assert(history.undoEntries().length == 0 && records.length == 0,
            "6040 history floor must start empty");
    }

    HeadlessPanel openImages() {
        resetImageListDrawSnapshot();
        return openPanel(() {
            ImGui.SetNextWindowPos(ImVec2(380, 0));
            ImGui.SetNextWindowSize(ImVec2(420, 480));
            drawImageListPanel(imageRoles.read, imageRoles.actions, renameState);
        }, "Images host");
    }

    HeadlessPanel openBoth() {
        resetImageListDrawSnapshot();
        resetLayerListDrawSnapshot();
        return openPanel(() {
            ImGui.SetNextWindowPos(ImVec2(380, 0));
            ImGui.SetNextWindowSize(ImVec2(380, 480));
            drawLayerListPanel(layerRoles.read, layerRoles.actions, renameState);
            ImGui.SetNextWindowPos(ImVec2(780, 0));
            ImGui.SetNextWindowSize(ImVec2(420, 480));
            drawImageListPanel(imageRoles.read, imageRoles.actions, renameState);
        }, "Items+Images host");
    }
}

private ImVec2 center(ImVec2 lo, ImVec2 hi) {
    assert(hi.x > lo.x && hi.y > lo.y, "6040 widget rectangle is empty");
    return ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
}

private ImageListDrawnRow imageRow(ImageListDrawSnapshot s, string name) {
    assert(s.rows.length > 0, "6040 row population: Images recorded no rows");
    foreach (r; s.rows) if (r.name == name) return r;
    assert(false, "6040 row population: missing image row " ~ name);
}

private size_t renamingRows(ImageListDrawSnapshot s) {
    size_t n;
    foreach (r; s.rows) if (r.renaming) ++n;
    return n;
}

private string lastArgs(ImagePanelHarness app) {
    return app.history.undoEntries().length
        ? app.history.undoEntries()[$ - 1].commandName ~ " "
          ~ app.history.undoEntries()[$ - 1].args
        : "<none>";
}

private void doubleClick(ref HeadlessPanel ui, ImVec2 p) {
    ui.pressAt(p); ui.release();
    ui.pressAt(p); ui.release();
}

unittest { // B1: the once-bound read role follows a document replaced in place
    auto prior = g_testMode; g_testMode = true;
    scope (exit) g_testMode = prior;
    auto app = new ImagePanelHarness;
    auto ui = app.openImages();
    scope (exit) ui.close();
    ui.frame();
    auto s = imageListDrawSnapshot();
    assert(s.drawn && s.rows.length == 2
        && s.rows[0].index == 2 && s.rows[0].name == "ImgOne"
        && s.rows[1].index == 3 && s.rows[1].name == "ImgTwo"
        && !s.removeEnabled && s.loadMax.x > s.loadMin.x,
        "6040 live-document floor: two distinct image rows at 2/3, Remove off");

    Document next = Document.bootstrap(makeCube());
    next.layers[0].name = "Delta";
    next.layers ~= imageLayer("ImgThree");
    *app.owner.documentPtr() = next;
    ui.frame();
    s = imageListDrawSnapshot();
    assert(s.rows.length == 1 && s.rows[0].index == 1
        && s.rows[0].name == "ImgThree",
        "6040 live-document witness: rows still show the document captured at bind");
}

unittest { // B2: selection clicks dispatch the DOCUMENT index through the UI route
    auto prior = g_testMode; g_testMode = true;
    scope (exit) g_testMode = prior;
    auto app = new ImagePanelHarness;
    app.clearRecords();
    auto ui = app.openImages();
    scope (exit) ui.close();
    ui.frame();
    auto s = imageListDrawSnapshot();
    assert(!imageRow(s, "ImgOne").focused && !imageRow(s, "ImgTwo").focused
        && !app.owner.document.layers[2].selected
        && !app.owner.document.layers[3].selected,
        "6040 selection floor: no image row selected or focused");

    auto two = imageRow(s, "ImgTwo");
    ui.pressAt(center(two.markerMin, two.markerMax));
    ui.release();
    ui.frame();
    s = imageListDrawSnapshot();
    assert(app.owner.document.focusedItem is app.owner.document.layers[3]
        && imageRow(s, "ImgTwo").focused && !imageRow(s, "ImgOne").focused,
        "6040 marker click did not focus ImgTwo (document index 3)");
    assert(app.history.undoEntries().length == 1
        && app.history.undoEntries()[0].commandName == "layer.select",
        "6040 marker click lost its layer.select history: " ~ lastArgs(app));
    assert(app.records.length == 1 && app.records[0].id == "layer.select"
        && app.records[0].outcome == "applied",
        "6040 marker click bypassed the guarded UI binding");

    keyCtrl(ui, true);
    auto one = imageRow(imageListDrawSnapshot(), "ImgOne");
    ui.pressAt(center(one.nameMin, one.nameMax));
    ui.release();
    keyCtrl(ui, false);
    ui.frame();
    assert(app.owner.document.layers[2].selected
        && app.owner.document.layers[3].selected
        && app.history.undoEntries().length == 2,
        "6040 Ctrl name click did not toggle ImgOne beside ImgTwo: " ~ lastArgs(app));
}

private void keyCtrl(ref HeadlessPanel ui, bool down) {
    if (down) { ui.keyDown(KEY_LEFT_CTRL); ui.keyDown(MOD_CTRL); ui.frame(); }
    else { ui.keyUp(KEY_LEFT_CTRL); ui.keyUp(MOD_CTRL); }
}

unittest { // B3: a deletion between frames moves the Remove target to the live index
    auto prior = g_testMode; g_testMode = true;
    scope (exit) g_testMode = prior;
    auto app = new ImagePanelHarness;
    auto imgOne = app.owner.document.layers[2];
    auto imgTwo = app.owner.document.layers[3];
    app.binding.dispatchUi("layer.select", `{"index":3,"mode":"set"}`);
    app.clearRecords();
    auto ui = app.openImages();
    scope (exit) ui.close();
    ui.frame();
    auto s = imageListDrawSnapshot();
    assert(s.removeEnabled && s.removeIndex == 3,
        "6040 remove floor: Remove must target ImgTwo at index 3");

    app.binding.dispatchUi("layer.delete", `{"index":1}`);
    assert(app.owner.document.layers.length == 4
        && app.owner.document.focusedItem is imgTwo,
        "6040 deletion floor: Beta deleted, ImgTwo still focused");
    ui.frame();
    s = imageListDrawSnapshot();
    assert(s.removeIndex == 2 && s.rows.length == 2
        && s.rows[0].index == 1 && s.rows[1].index == 2,
        "6040 stale remove target: Remove still addresses the index from before the deletion");

    const historyBefore = app.history.undoEntries().length;
    ui.pressAt(center(s.removeMin, s.removeMax));
    ui.release();
    ui.frame();
    assert(!app.owner.document.isMember(imgTwo)
        && app.owner.document.isMember(imgOne)
        && !imageListDrawSnapshot().confirmDrawn,
        "6040 direct remove: Remove did not delete exactly ImgTwo without a confirm");
    assert(app.history.undoEntries().length == historyBefore + 1
        && app.history.undoEntries()[$ - 1].commandName == "image.remove"
        && app.records[$ - 1].id == "image.remove"
        && app.records[$ - 1].outcome == "applied",
        "6040 direct remove lost its UI history/guard identity: " ~ lastArgs(app));

    app.binding.dispatchUi("layer.select", `{"index":0,"mode":"set"}`);
    ui.frame();
    const finalSnapshot = imageListDrawSnapshot();
    assert(finalSnapshot.drawn && !finalSnapshot.removeEnabled,
        "6040 focus change: Remove stayed enabled after the focus moved to a mesh");
}

unittest { // B4: the confirm removes the item it named, not the current focus
    auto prior = g_testMode; g_testMode = true;
    scope (exit) g_testMode = prior;
    auto app = new ImagePanelHarness;
    auto imgOne = app.owner.document.layers[2];
    auto imgTwo = app.owner.document.layers[3];
    app.binding.dispatchUi("layer.select", `{"index":2,"mode":"set"}`);
    app.clearRecords();
    auto ui = app.openImages();
    scope (exit) ui.close();
    ui.frame();
    auto s = imageListDrawSnapshot();
    assert(s.removeEnabled && s.removeIndex == 2,
        "6040 confirm floor: Remove must target ImgOne at index 2");
    ui.pressAt(center(s.removeMin, s.removeMax));
    ui.release();
    ui.frame();
    s = imageListDrawSnapshot();
    assert(s.confirmDrawn && s.confirmIndex == 2
        && s.confirmText == "\"ImgOne\" is still used by 1 item(s): Consumer"
        && app.history.undoEntries().length == 0,
        "6040 confirm population: an in-use image must open the confirm without dispatching");

    app.binding.dispatchUi("layer.select", `{"index":3,"mode":"set"}`);
    ui.frame();
    s = imageListDrawSnapshot();
    assert(s.confirmDrawn && s.removeIndex == 3 && s.confirmIndex == 2,
        "6040 confirm discriminator: focus and confirmed item must now differ");
    ui.pressAt(center(s.confirmMin, s.confirmMax));
    ui.release();
    ui.frame();
    assert(!app.owner.document.isMember(imgOne)
        && app.owner.document.isMember(imgTwo),
        "6040 confirm target: Remove Image? removed the current focus instead of the confirmed item");
    assert(app.history.undoEntries()[$ - 1].commandName == "image.remove"
        && !imageListDrawSnapshot().confirmDrawn,
        "6040 confirm close: the confirm did not dispatch once and close");
}

unittest { // B5: Load dispatches the argument-less load through the UI route
    auto prior = g_testMode; g_testMode = true;
    scope (exit) g_testMode = prior;
    auto app = new ImagePanelHarness;
    app.clearRecords();
    auto ui = app.openImages();
    scope (exit) ui.close();
    ui.frame();
    auto s = imageListDrawSnapshot();
    ui.pressAt(center(s.loadMin, s.loadMax));
    ui.release();
    ui.frame();
    assert(app.owner.document.layers.length == 5
        && app.history.undoEntries().length == 0,
        "6040 load refusal changed the document or history");
    assert(app.records.length == 1 && app.records[0].id == "image.load"
        && app.records[0].outcome == "refused" && app.notices == 1,
        "6040 Load did not reach image.load through the guarded UI route");
}

unittest { // B6: Items and Images share main's ItemRenameState by document index
    auto prior = g_testMode; g_testMode = true;
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    assert(loadSDL() == sdlSupport, "6040 SDL population: binding did not load");
    SDL_SetModState(KMOD_NONE);
    auto app = new ImagePanelHarness;
    app.binding.dispatchUi("layer.select", `{"index":1,"mode":"set"}`);
    app.clearRecords();
    auto ui = app.openBoth();
    scope (exit) ui.close();
    ui.frame();
    auto items = layerListDrawSnapshot();
    auto images = imageListDrawSnapshot();
    LayerListDrawnRow beta;
    bool sawBeta, sawConsumer, sawImage;
    foreach (r; items.rows) {
        if (r.name == "Beta") { beta = r; sawBeta = true; }
        if (r.name == "Consumer") sawConsumer = true;
        if (r.name == "ImgOne" || r.name == "ImgTwo") sawImage = true;
    }
    assert(sawBeta && sawConsumer && !sawImage,
        "6040 cross-panel floor: Items must contain Beta/Consumer and no images");
    assert(images.rows.length == 2 && renamingRows(images) == 0
        && app.renameState.index == -1,
        "6040 cross-panel floor: two Images rows and no editor");

    doubleClick(ui, center(beta.nameMin, beta.nameMax));
    ui.frame(); ui.frame();
    assert(app.renameState.index == 1,
        "6040 cross-panel floor: the Items double-click did not start renaming Beta");
    assert(renamingRows(imageListDrawSnapshot()) == 0,
        "6040 cross-panel index: an Items rename opened an editor on an Images row");

    auto one = imageRow(imageListDrawSnapshot(), "ImgOne");
    doubleClick(ui, center(one.nameMin, one.nameMax));
    ui.frame(); ui.frame();
    auto after = imageListDrawSnapshot();
    assert(app.renameState.index == 2,
        "6040 shared owner: Images began its rename outside main's ItemRenameState");
    assert(renamingRows(after) == 1 && imageRow(after, "ImgOne").renaming,
        "6040 one editor: the Images rename is not on exactly the ImgOne row");
    assert(app.owner.document.layers[1].name == "Beta",
        "6040 Items deactivation renamed Beta without an edit");

    ui.typeText("Q");
    ui.keyDown(cast(int) ImGuiKey.Enter); ui.frame();
    ui.keyUp(cast(int) ImGuiKey.Enter); ui.frame(); ui.frame();
    assert(app.owner.document.layers[2].name == "Q"
        && app.owner.document.layers[0].name == "Alpha"
        && app.owner.document.layers[1].name == "Beta"
        && app.owner.document.layers[3].name == "ImgTwo",
        "6040 cross-panel commit: the rename did not change exactly ImgOne: got `"
        ~ app.owner.document.layers[2].name ~ "`");
    assert(app.history.undoEntries()[$ - 1].commandName == "layer.rename"
        && app.records[$ - 1].id == "layer.rename"
        && app.renameState.index == -1,
        "6040 cross-panel commit lost its UI layer.rename record or stayed open");
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6040 census missing source marker " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6040 census found no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "6040 census found unterminated body after " ~ marker);
}

private bool identifierChar(char ch) {
    return ch == '_' || (ch >= '0' && ch <= '9')
        || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z');
}

private size_t identifierCount(string code, string identifier) {
    size_t total, from;
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

unittest { // 6040 census: production binder, call sites, retired EditorApp path
    const rawApp = readText(repoRoot.buildPath("source", "app.d"));
    const rawImages = readText(repoRoot.buildPath("source", "ui", "image_list_panel.d"));
    const app = blankNonCode(rawApp);
    const images = blankNonCode(rawImages);
    const panels = blankNonCode(readText(repoRoot.buildPath("source", "ui", "panels.d")));

    // (1) population floors before any absence claim
    assert(rawImages.length > 15_000,
        "6040 source population: image-list panel source is unexpectedly small");
    // (2) module boundary: no EditorApp, no panels, no Layers roles, no tool/forms
    assert(images.count("EditorApp") == 0 && images.count("editor_app") == 0
        && images.count("ui.panels") == 0 && images.count("with (") == 0,
        "6040 role boundary: image-list panel regained EditorApp/panels coupling");
    assert(images.count("ui.layer_list_panel") == 0
        && identifierCount(images, "FormsPanel") == 0
        && identifierCount(images, "Tool") == 0
        && identifierCount(images, "dispatchInteractiveUi") == 0,
        "6040 narrow roles: Images must not borrow the Layers roles, forms, tool or interactive dispatch");
    // (3) binder
    const binder = bodyAt(images,
        "ImageListPanelRoles bindImageListPanel(Session* owner,");
    assert(identifierCount(binder, "binding") == 2
        && binder.count("&binding.dispatchUi") == 1,
        "6040 binder census: Images must bind exactly binding.dispatchUi, directly");
    // (4) draw body: one owner use, one controller bind, read role only
    const draw = bodyAt(images,
        "void drawImageListPanel(ImageListReadRole read, ImageListActions actions,");
    assert(identifierCount(draw, "itemRenameState") == 1
        && draw.count("auto dispatch = actions.commandDispatch();") == 1
        && draw.count("bindItemRenameController(itemRenameState, dispatch)") == 1
        && identifierCount(draw, "ItemRenameState") == 0,
        "6040 shared rename owner: the draw must bind the passed ItemRenameState and declare no other");
    const rawDraw = bodyAt(rawImages,
        "void drawImageListPanel(ImageListReadRole read, ImageListActions actions,");
    assert(rawDraw.count("dispatch(\"") == 5
        && rawDraw.count("dispatch(\"image.load\", \"{}\")") == 1
        && rawDraw.count("dispatch(\"image.remove\",") == 2
        && rawDraw.count("dispatch(\"layer.select\",") == 2,
        "6040 action set: Images dispatches exactly image.load, image.remove x2, layer.select x2");
    // (5) retired path
    assert(identifierCount(panels, "drawImageListPanel") == 0
        && identifierCount(panels, "ItemRenameState") == 0
        && identifierCount(panels, "bindItemRenameController") == 0
        && panels.count("import ui.item_rename") == 0,
        "6040 retired panel path: ui.panels still defines or feeds the Images rename owner");
    size_t sourceFiles, oldSig;
    foreach (entry; dirEntries(repoRoot.buildPath("source"), "*.d", SpanMode.depth)) {
        ++sourceFiles;
        oldSig += blankNonCode(readText(entry.name)).count("drawImageListPanel(EditorApp");
    }
    assert(sourceFiles > 500 && oldSig == 0,
        "6040 source census: the EditorApp image-list overload survived");
    // (6) app.d identifiers, then spelling, then order
    assert(identifierCount(app, "bindImageListPanel") == 2
        && identifierCount(app, "drawImageListPanel") == 2
        && identifierCount(app, "imageListRoles") == 3,
        "6040 production wiring: app.d must import+call bindImageListPanel once, drawImageListPanel once, and declare one imageListRoles");
    assert(identifierCount(app, "itemRenameState") == 3,
        "6040 production owner: app.d must declare one shared itemRenameState and pass it to both panels");
    const flatApp = collapseWhitespace(app);
    assert(flatApp.count("auto imageListRoles = bindImageListPanel(sessionOwner, commandBinding);") == 1
        && flatApp.count("drawImageListPanel(imageListRoles.read, imageListRoles.actions, itemRenameState);") == 1,
        "6040 production wiring: Images must bind sessionOwner+commandBinding and draw with main's itemRenameState");
    const cbAt = app.indexOf("commandBinding = new ApplicationCommandBinding(");
    const bindAt = app.indexOf("bindImageListPanel(sessionOwner");
    const loopAt = app.indexOf("while (running) {");
    const drawAt = app.indexOf("drawImageListPanel(imageListRoles.read");
    assert(app.count("commandBinding = new ApplicationCommandBinding(") == 1
        && app.count("while (running) {") == 1
        && cbAt >= 0 && cbAt < bindAt && bindAt < loopAt && loopAt < drawAt,
        "6040 production placement: bind after the one commandBinding assignment and before the frame loop; draw inside it");
    enum uiClosure = "uiCommandDelegate = (string id, string paramsJson) {\n"
        ~ "        commandBinding.dispatchUi(id, paramsJson);\n    };";
    assert(rawApp.count(uiClosure) == 1,
        "6040 early-binding equivalence: Images binds commandBinding.dispatchUi directly, so a wrapper added to uiCommandDelegate would not reach Images");
    // (7) chrome/IDs unchanged
    const push = rawImages.indexOf("pushPanelChromeStyle();");
    const pop = rawImages.indexOf("scope(exit) popPanelChromeStyle();");
    const end = rawImages.indexOf("scope(exit) ImGui.End();");
    const begin = rawImages.indexOf("if (ImGui.Begin(\"Images\")) {");
    assert(rawImages.count("pushPanelChromeStyle();") == 1
        && rawImages.count("scope(exit) popPanelChromeStyle();") == 1
        && rawImages.count("scope(exit) ImGui.End();") == 1
        && rawImages.count("if (ImGui.Begin(\"Images\")) {") == 1
        && push >= 0 && push < pop && pop < end && end < begin,
        "6040 panel chrome: extraction changed Begin/End/style ordering");
    foreach (needle; ["\"Load...\"", "\"##rename\"", "\"Cancel\""])
        assert(rawImages.count(needle) == 1, "6040 panel IDs: extraction lost " ~ needle);
    assert(rawImages.count("\"Remove Image?\"") == 2 && rawImages.count("\"Remove\"") == 2,
        "6040 panel IDs: confirm popup or Remove labels changed");
}
