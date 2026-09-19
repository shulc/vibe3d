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
import commands.image.commands : ImageLoad, ImageRemove, ImageRemoveWarning;
import commands.layer.commands : LayerDelete, LayerRename, LayerReorder,
    LayerSelect;
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
    ImageListPanelRoles, ImageListReadRole, bindImageListPanel, drawImageListPanel,
    imageListDrawSnapshot, resetImageListDrawSnapshot;
import ui.image_rows : ImageRemoveConfirm, ImageRemoveTarget, ImageRow;
import ui.item_rename : ItemRenameState;
import ui.layer_list_panel : LayerListDrawnRow, LayerListPanelRoles,
    bindLayerListPanel, drawLayerListPanel, layerListDrawSnapshot,
    resetLayerListDrawSnapshot;
import ui.retained_item : RetainedItem;
import view : View;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiKey, ImVec2;

private template memberTypes(T) {
    private string[] collect() {
        string[] result;
        foreach (name; __traits(allMembers, T)) {
            static if (__traits(compiles, __traits(getOverloads, T, name))
                       && __traits(getOverloads, T, name).length > 0) {
                string joined;
                foreach (i, overload; __traits(getOverloads, T, name)) {
                    if (i) joined ~= " | ";
                    joined ~= typeof(overload).stringof;
                }
                result ~= name ~ ": " ~ joined;
            } else static if (__traits(compiles,
                                       typeof(__traits(getMember, T, name)))) {
                result ~= name ~ ": "
                    ~ typeof(__traits(getMember, T, name)).stringof;
            } else {
                result ~= name ~ ": <no type>";
            }
        }
        return result;
    }
    enum memberTypes = collect();
}

static assert(!__traits(compiles, (ImageListPanelRoles roles) {
        Document* doc = roles.read.document();
    }),
    "6530 N1 document: the Images read role hands out a mutable Document*");
static assert(__traits(compiles, (ImageListPanelRoles roles) {
        const(Document)* doc = roles.read.document();
    }),
    "6530 N1 control: the same role expression must compile through const");
static assert(!__traits(compiles, (ImageListPanelRoles roles) {
        auto doc = roles.read.document();
        doc.layers[0].name = "x";
    }),
    "6530 N1w document: the Images read role permits a document write");
static assert(!__traits(compiles, (ImageRow row) {
        Layer l = row.layer;
    }),
    "6530 N2 row.layer: a row hands out a mutable Layer");
static assert(__traits(compiles, (ImageRow row) {
        const(Layer) l = row.layer;
    }),
    "6530 N2 control: the same row expression must compile through const");
static assert(!__traits(compiles, (ImageRow row) {
        row.layer.name = "x";
    }),
    "6530 N2w row.layer: a row permits a document-item write");
static assert(!__traits(compiles, (ImageRemoveConfirm c) {
        Layer l = c.referrers[0];
    }),
    "6530 N3 confirm.referrers: the confirmation hands out mutable referrers");
static assert(__traits(compiles, (ImageRemoveConfirm c) {
        const(Layer) l = c.referrers[0];
    }),
    "6530 N3 control: the same confirmation expression must compile through const");
static assert(!__traits(compiles, (RetainedItem t) {
        Layer l = t.item;
    }),
    "6530 N4 token.item: the retained token hands out a mutable Layer");
static assert(__traits(compiles, (RetainedItem t) {
        const(Layer) l = t.item;
    }),
    "6530 N4 control: the same retained identity must compile through const");
static assert(__traits(compiles, (RetainedItem t) {
        const(Object) o = t.item;
    }),
    "6530 N4 control: retained identity must remain usable as a const Object");
static assert(!__traits(compiles, (ImageRemoveTarget t) {
        Layer l = t.layer;
    }),
    "6530 N5 target.layer: the Remove target hands out a mutable Layer");
static assert(__traits(compiles, (ImageRemoveTarget t) {
        const(Layer) l = t.layer;
    }),
    "6530 N5 control: the same Remove-target expression must compile through const");
static assert(!__traits(compiles, (ImageRemoveWarning w) {
        Layer l = w.referrers[0];
    }),
    "6530 N6 warning.referrers: the remove predicate hands out mutable referrers");
static assert(__traits(compiles, (ImageRemoveWarning w) {
        const(Layer) l = w.referrers[0];
    }),
    "6530 N6 control: the same warning expression must compile through const");

static assert([__traits(allMembers, ImageListReadRole)] ==
        ["owner_", "__ctor", "document"],
    "6530 F1 fence (names): the Images read role's member set changed — a "
    ~ "capability cannot be added here without naming it");
static assert(memberTypes!ImageListReadRole ==
        ["owner_: Session*",
         "__ctor: ref ImageListReadRole() | ref ImageListReadRole(Session* owner)",
         "document: const(Document)*()"],
    "6530 F1 fence (types): a member of ImageListReadRole changed its TYPE or "
    ~ "SIGNATURE — regenerate with the pragma probe, read the diff, and argue "
    ~ "the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, ImageRow)] ==
        ["index", "layer", "name", "renameSeed", "pathText", "pathTooltip",
         "dimensions", "pixelFormat", "missing", "selected", "focused",
         "opAssign"],
    "6530 F2 fence (names): ImageRow's member set changed — a capability "
    ~ "cannot be added here without naming it");
static assert(memberTypes!ImageRow ==
        ["index: ulong", "layer: Rebindable!(const(Layer))", "name: string",
         "renameSeed: string", "pathText: string", "pathTooltip: string",
         "dimensions: string", "pixelFormat: string", "missing: bool",
         "selected: bool", "focused: bool",
         "opAssign: pure nothrow @nogc ref @trusted ImageRow(ImageRow p) return"],
    "6530 F2 fence (types): a member of ImageRow changed its TYPE or SIGNATURE "
    ~ "— regenerate with the pragma probe, read the diff, and argue the change; "
    ~ "do not paste the actual list over the expected one");
static assert([__traits(allMembers, ImageRemoveTarget)] ==
        ["index", "layer", "enabled", "opAssign"],
    "6530 F3 fence (names): ImageRemoveTarget's member set changed — a "
    ~ "capability cannot be added here without naming it");
static assert(memberTypes!ImageRemoveTarget ==
        ["index: ulong", "layer: Rebindable!(const(Layer))", "enabled: bool",
         "opAssign: pure nothrow @nogc ref @trusted ImageRemoveTarget(ImageRemoveTarget p) return"],
    "6530 F3 fence (types): a member of ImageRemoveTarget changed its TYPE or "
    ~ "SIGNATURE — regenerate with the pragma probe, read the diff, and argue "
    ~ "the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, ImageRemoveConfirm)] ==
        ["text", "referrers"],
    "6530 F4 fence (names): ImageRemoveConfirm's member set changed — a "
    ~ "capability cannot be added here without naming it");
static assert(memberTypes!ImageRemoveConfirm ==
        ["text: string", "referrers: const(Layer)[]"],
    "6530 F4 fence (types): a member of ImageRemoveConfirm changed its TYPE or "
    ~ "SIGNATURE — regenerate with the pragma probe, read the diff, and argue "
    ~ "the change; do not paste the actual list over the expected one");
static assert([__traits(allMembers, RetainedItem)] ==
        ["item_", "hold", "release", "held", "item", "holds", "resolve",
         "opAssign"],
    "6530 F5 fence (names): RetainedItem's member set changed — a capability "
    ~ "cannot be added here without naming it");
static assert(memberTypes!RetainedItem ==
        ["item_: Rebindable!(const(Layer))", "hold: void(const(Layer) item)",
         "release: void()", "held: bool", "item: const(Layer)",
         "holds: const bool(const(Layer) item)",
         "resolve: const bool(ref const(Document) document, out ulong index)",
         "opAssign: pure nothrow @nogc ref @trusted RetainedItem(RetainedItem p) return"],
    "6530 F5 fence (types): a member of RetainedItem changed its TYPE or "
    ~ "SIGNATURE. A capability escapes only by NAMING a new member (the names "
    ~ "pin) or by widening an existing member's type (this pin). Regenerate "
    ~ "with the pragma probe, read the diff, and argue the change — do not "
    ~ "paste the actual list over the expected one.");
static assert([__traits(allMembers, ImageRemoveWarning)] ==
        ["inUse", "referrers"],
    "6530 F6 fence (names): ImageRemoveWarning's member set changed — a "
    ~ "capability cannot be added here without naming it");
static assert(memberTypes!ImageRemoveWarning ==
        ["inUse: bool", "referrers: const(Layer)[]"],
    "6530 F6 fence (types): a member of ImageRemoveWarning changed its TYPE "
    ~ "or SIGNATURE — regenerate with the pragma probe, read the diff, and "
    ~ "argue the change; do not paste the actual list over the expected one");

static assert(ImageListReadRole.tupleof.length == 1,
    "6530 read role fence: the Images read role no longer has exactly one field");
static assert(is(typeof(ImageListReadRole.tupleof[0]) == Session*),
    "6530 read role fence: the Images read role's sole field is no longer Session*");

static assert(__traits(compiles, (ImageRow row) {
        auto bypass = __traits(getMember, row.layer, "stripped");
    }),
    "6530 N8 (recorded remnant, NOT a guard): the private-field bypass compiles "
    ~ "by construction, so the TYPE cannot refuse it. If this FAILS, check the "
    ~ "ordinary cause FIRST: a stored identity was made mutable again (then "
    ~ "N1-N6 above are the real message). Only if those hold did the language "
    ~ "close the hole.");

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
        registry.registerCommand("layer.select", () => cast(Command)
            new LayerSelect(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null));
        registry.registerCommand("layer.rename", () => cast(Command)
            new LayerRename(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null));
        registry.registerCommand("layer.delete", () => cast(Command)
            new LayerDelete(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null));
        registry.registerCommand("layer.reorder", () => cast(Command)
            new LayerReorder(owner.document.activeMesh(), view, owner.editMode,
                             owner.documentPtr(), null));
        registry.registerCommand("image.load", () => cast(Command)
            new ImageLoad(owner.document.activeMesh(), view, owner.editMode,
                          owner.documentPtr(), null));
        registry.registerCommand("image.remove", () => cast(Command)
            new ImageRemove(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null));
        imageRoles = bindImageListPanel(owner, binding);
        assert(imageRoles.state !is null,
            "6359 state floor: bindImageListPanel returned no ImageListPanelState");
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
            drawImageListPanel(imageRoles.read, imageRoles.actions, imageRoles.state, renameState);
        }, "Images host");
    }

    HeadlessPanel openBoth() {
        resetImageListDrawSnapshot();
        resetLayerListDrawSnapshot();
        return openPanel(() {
            ImGui.SetNextWindowPos(ImVec2(380, 0));
            ImGui.SetNextWindowSize(ImVec2(380, 480));
            drawLayerListPanel(layerRoles.read, layerRoles.actions,
                               layerRoles.state, renameState);
            ImGui.SetNextWindowPos(ImVec2(780, 0));
            ImGui.SetNextWindowSize(ImVec2(420, 480));
            drawImageListPanel(imageRoles.read, imageRoles.actions, imageRoles.state, renameState);
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

unittest { // B6: Items and Images share main's identity-bound ItemRenameState
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
        && !app.renameState.open,
        "6040 cross-panel floor: two Images rows and no editor");

    doubleClick(ui, center(beta.nameMin, beta.nameMax));
    ui.frame(); ui.frame();
    assert(app.renameState.activeFor(app.owner.document.layers[1]),
        "6040 cross-panel floor: the Items double-click did not start renaming Beta");
    assert(renamingRows(imageListDrawSnapshot()) == 0,
        "6040 cross-panel index: an Items rename opened an editor on an Images row");

    auto one = imageRow(imageListDrawSnapshot(), "ImgOne");
    doubleClick(ui, center(one.nameMin, one.nameMax));
    ui.frame(); ui.frame();
    auto after = imageListDrawSnapshot();
    assert(app.renameState.activeFor(app.owner.document.layers[2]),
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
        && !app.renameState.open,
        "6040 cross-panel commit lost its UI layer.rename record or stayed open");
}

unittest { // B7: a pending confirm resolves its target after a reorder
    auto prior = g_testMode; g_testMode = true;
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto app = new ImagePanelHarness;
    auto imgOne = app.owner.document.layers[2];
    auto imgTwo = app.owner.document.layers[3];
    app.binding.dispatchUi("layer.select", `{"index":2,"mode":"set"}`);
    app.clearRecords();
    auto ui = app.openImages();
    scope (exit) ui.close();
    ui.frame();
    auto s = imageListDrawSnapshot();
    assert(s.rows.length == 2 && s.removeEnabled && s.removeIndex == 2,
        "6530 reorder floor: two image rows and ImgOne targeted at index 2");

    ui.pressAt(center(s.removeMin, s.removeMax));
    ui.release();
    ui.frame();
    s = imageListDrawSnapshot();
    assert(s.confirmDrawn && s.confirmIndex == 2 && s.confirmTarget is imgOne
        && s.confirmText == "\"ImgOne\" is still used by 1 item(s): Consumer",
        "6530 reorder floor: the in-use ImgOne confirm did not open at index 2");
    const shownText = s.confirmText;

    app.binding.dispatchUi("layer.reorder", `{"from":2,"to":4}`);
    assert(app.owner.document.layers[4] is imgOne
        && app.owner.document.layers[2] is imgTwo,
        "6530 reorder floor: the document did not move ImgOne from 2 to 4");
    ui.frame();
    s = imageListDrawSnapshot();
    assert(s.confirmDrawn && s.confirmIndex == 4 && s.confirmTarget is imgOne
        && s.confirmText == shownText,
        "6530 reorder identity: the pending confirm did not follow ImgOne to 4");

    ui.pressAt(center(s.confirmMin, s.confirmMax));
    ui.release();
    ui.frame();
    assert(!app.owner.document.isMember(imgOne)
        && app.owner.document.isMember(imgTwo),
        "6530 reorder target: the confirm removed an item other than ImgOne");
    assert(app.history.undoEntries()[$ - 1].commandName == "image.remove"
        && app.history.undoEntries()[$ - 1].args == "index:4",
        "6530 reorder target: the confirm dispatched the index from before the reorder; got "
        ~ app.history.undoEntries()[$ - 1].commandName ~ " "
        ~ app.history.undoEntries()[$ - 1].args);
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

private struct StripSignalRow {
    string path;
    size_t casts, traits, tupleofs, mixins, unions;
}

private enum StripSignalRow[] kStripSignalLedger = [
    StripSignalRow("source/ui/image_rows.d", 0, 0, 0, 0, 0),
    StripSignalRow("source/ui/image_list_panel.d", 3, 0, 0, 0, 0),
    StripSignalRow("source/ui/retained_item.d", 0, 0, 0, 0, 0),
    StripSignalRow("source/ui/item_rename.d", 0, 0, 0, 0, 0),
    StripSignalRow("source/commands/image/commands.d", 14, 0, 0, 0, 0),
    StripSignalRow("source/document.d", 4, 0, 0, 1, 0),
    StripSignalRow("source/document_selection.d", 5, 0, 0, 1, 0),
];

private enum kStripSignalTokens =
    ["cast", "__traits", "tupleof", "mixin", "union"];
static assert(kStripSignalTokens ==
        ["cast", "__traits", "tupleof", "mixin", "union"],
    "6530 strip signal token roster changed — every measured column must "
    ~ "remain in the exact scan below");

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
        && collapseWhitespace(draw).count("bindItemRenameController(itemRenameState, read.document(), dispatch)") == 1
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
        && identifierCount(app, "imageListRoles") == 4,
        "6040 production wiring: app.d must import+call bindImageListPanel once, drawImageListPanel once, and declare one imageListRoles");
    assert(identifierCount(app, "itemRenameState") == 3,
        "6040 production owner: app.d must declare one shared itemRenameState and pass it to both panels");
    const flatApp = collapseWhitespace(app);
    assert(flatApp.count("auto imageListRoles = bindImageListPanel(sessionOwner, commandBinding);") == 1
        && flatApp.count("drawImageListPanel(imageListRoles.read, imageListRoles.actions, imageListRoles.state, itemRenameState);") == 1,
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

unittest { // 6530: read-role fence and strip-token signal
    import std.conv : to;

    const rawImages = readText(repoRoot.buildPath("source", "ui",
                                                  "image_list_panel.d"));
    const rawRows = readText(repoRoot.buildPath("source", "ui",
                                                "image_rows.d"));
    assert(rawImages.length > 15_000 && rawRows.length > 30_000,
        "6530 source population: Images role/row sources are unexpectedly small");

    const images = blankNonCode(rawImages);
    const draw = bodyAt(images,
        "void drawImageListPanel(ImageListReadRole read, ImageListActions actions,");
    assert(identifierCount(draw, "owner_") == 0,
        "6530 read role fence: the Images draw body names the role's private member");
    assert(identifierCount(images, "owner_") == 3,
        "6530 read role fence: owner_ is named "
        ~ identifierCount(images, "owner_").to!string ~ " times (recorded 3)");

    immutable expectedPaths = [
        "source/ui/image_rows.d",
        "source/ui/image_list_panel.d",
        "source/ui/retained_item.d",
        "source/ui/item_rename.d",
        "source/commands/image/commands.d",
        "source/document.d",
        "source/document_selection.d",
    ];
    string[] rawSources;
    size_t sourceBytes;
    foreach (row; kStripSignalLedger) {
        auto raw = readText(repoRoot.buildPath(row.path));
        sourceBytes += raw.length;
        rawSources ~= raw;
    }
    assert(kStripSignalLedger.length == 7 && sourceBytes > 200_000,
        "6530 strip signal population: expected seven populated production files");

    foreach (path; expectedPaths) {
        size_t appearances;
        foreach (row; kStripSignalLedger) if (row.path == path) ++appearances;
        assert(appearances == 1,
            "6530 strip signal ledger: the rows do not name the seven files "
            ~ "exactly once (" ~ path ~ " appears " ~ appearances.to!string
            ~ " times)");
    }
    foreach (row; kStripSignalLedger) {
        size_t appearances;
        foreach (path; expectedPaths) if (row.path == path) ++appearances;
        assert(appearances == 1,
            "6530 strip signal ledger: unexpected path " ~ row.path);
    }

    size_t casts, traits, tupleofs, mixins, unions;
    foreach (row; kStripSignalLedger) {
        casts += row.casts;
        traits += row.traits;
        tupleofs += row.tupleofs;
        mixins += row.mixins;
        unions += row.unions;
    }
    assert(casts == 26 && traits == 0 && tupleofs == 0
        && mixins == 2 && unions == 0,
        "6530 strip signal ledger: recorded totals changed (cast="
        ~ casts.to!string ~ ", __traits=" ~ traits.to!string ~ ", tupleof="
        ~ tupleofs.to!string ~ ", mixin=" ~ mixins.to!string ~ ", union="
        ~ unions.to!string ~ ")");

    foreach (i, row; kStripSignalLedger) {
        const code = blankNonCode(rawSources[i]);
        immutable recorded =
            [row.casts, row.traits, row.tupleofs, row.mixins, row.unions];
        assert(recorded.length == kStripSignalTokens.length,
            "6530 strip signal token roster and recorded columns diverged");
        foreach (column, token; kStripSignalTokens) {
            const actual = identifierCount(code, token);
            assert(actual == recorded[column],
                "6530 strip signal: " ~ row.path ~ " " ~ token ~ " = "
                ~ actual.to!string ~ ", recorded "
                ~ recorded[column].to!string
                ~ " — a row may only FALL; if the strip left, lower the row "
                ~ "in this commit");
        }
    }
}
