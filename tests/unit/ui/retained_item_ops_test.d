module tests.unit.ui.retained_item_ops_test;

// Retained item operations (task 6359): an open rename and a pending remove
// confirmation hold their item by identity and resolve its document index at
// dispatch. Every cell drives the production Items/Images draws over the
// production guarded command binding; `records` is that binding's own
// observation port, so "no dispatch" is witnessed, not inferred from history.

import std.algorithm : canFind, count;
import std.file : readText;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf;

import bindbc.sdl : KMOD_NONE, SDL_SetModState, loadSDL, sdlSupport;
import application_command_binding : ApplicationCommandBinding;
import command : Command, g_testMode;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.image.commands : ImageRemove;
import commands.image_plane.commands : ImagePlaneAdd, ImagePlaneSetImage;
import commands.layer.commands : LayerDelete, LayerRename, LayerSelect;
import document : Document, ImageData, ImagePlaneData, ItemKind, Layer;
import edit_session : EditSession;
import forms_render : FormsPanel;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import mesh : makeCube;
import registry : Registry;
import session_owner : Session;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import ui.discard_guard : GuardRecord;
import ui.image_list_panel : ImageListDrawSnapshot, ImageListPanelRoles,
    ImageListPanelState, bindImageListPanel, drawImageListPanel,
    imageListConfirmView, imageListDrawSnapshot, resetImageListDrawSnapshot;
import ui.item_rename : ItemRenameController, ItemRenameState;
import ui.layer_list_panel : LayerListDrawSnapshot, LayerListPanelRoles,
    bindLayerListPanel, drawLayerListPanel, layerListDrawSnapshot,
    resetLayerListDrawSnapshot;
import view : View;
import ImGui = d_imgui;
import d_imgui.imgui_h : ImGuiKey, ImVec2;

static assert(__traits(compiles, {
    ImageListPanelRoles roles = void;
    ImageListPanelState s = roles.state;
}) && !__traits(compiles, new ImageListPanelState()),
    "6359 state ownership: only bindImageListPanel may create the Images panel state");
static assert(!__traits(hasMember, ItemRenameState, "index")
    && !__traits(compiles, (ItemRenameController c) => c.activeFor(size_t(1)))
    && !__traits(compiles, (ItemRenameController c) => c.begin(size_t(1), "x")),
    "6359 identity: the rename state regained a click-time index");

private enum repoRoot = buildNormalizedPath(dirName(__FILE_FULL_PATH__),
                                             "..", "..", "..");

private Layer meshLayer(string name) {
    auto l = new Layer; l.name = name; l.meshRef() = makeCube(); return l;
}
private Layer imageLayer(string name) {
    auto l = new Layer; l.kind = ItemKind.Image; l.name = name;
    l.imageRef() = new ImageData; return l;
}
private Layer imagePlaneLayer(string name) {
    auto l = new Layer; l.kind = ItemKind.ImagePlane; l.name = name;
    l.imagePlaneRef() = new ImagePlaneData; return l;
}

// [0] Alpha [1] Beta [2] Gamma (meshes)  [3] ImgOne [4] ImgTwo  [5] Consumer -> ImgOne
private Document retainedDocument() {
    Document d = Document.bootstrap(makeCube());
    d.layers[0].name = "Alpha";
    d.layers ~= meshLayer("Beta");
    d.layers ~= meshLayer("Gamma");
    auto one = imageLayer("ImgOne");
    d.layers ~= one;
    d.layers ~= imageLayer("ImgTwo");
    auto consumer = imagePlaneLayer("Consumer");
    d.layers ~= consumer;
    consumer.setLink("image", one);
    d.setActive(0);
    return d;
}

private final class RetainedHarness {
    Session* owner;
    View view;
    Registry registry;
    CommandHistory history;
    CommandExecutor executor;
    EditSession editSession;
    GuardRecord[] records;
    GuardedActionController guard;
    ApplicationCommandBinding binding;
    Tool activeTool;
    ItemRenameState renameState;
    FormsPanel forms;
    LayerListPanelRoles layerRoles;
    ImageListPanelRoles imageRoles;
    Layer alpha, beta, gamma, imgOne, imgTwo, consumer;

    this() {
        owner = Session.create(retainedDocument());
        alpha = owner.document.layers[0];
        beta = owner.document.layers[1];
        gamma = owner.document.layers[2];
        imgOne = owner.document.layers[3];
        imgTwo = owner.document.layers[4];
        consumer = owner.document.layers[5];
        assert(owner.document.layers.length == 6 && beta.name == "Beta"
            && imgOne.hasImage && imgTwo.hasImage && consumer.linksTo(imgOne),
            "6359 fixture floor: three meshes, two images and one consumer");
        view = new View(0, 0, 800, 600);
        history = new CommandHistory;
        executor = new CommandExecutor(history, () => activeTool !is null,
            (ToolTransition) { activeTool = null; });
        editSession = new EditSession(() => activeTool, history,
            () { activeTool = null; });
        guard = new GuardedActionController(GuardedActionPorts(
            (Command c, RecordMode m) => executor.applyOrRefire(c, m, null),
            () => false, () => true, (Command) {},
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
        registry.registerCommand("image.remove", () => cast(Command)
            new ImageRemove(owner.document.activeMesh(), view, owner.editMode,
                            owner.documentPtr(), null));
        registry.registerCommand("imagePlane.add", () => cast(Command)
            new ImagePlaneAdd(owner.document.activeMesh(), view, owner.editMode,
                              owner.documentPtr(), null));
        registry.registerCommand("imagePlane.setImage", () => cast(Command)
            new ImagePlaneSetImage(owner.document.activeMesh(), view, owner.editMode,
                                   owner.documentPtr()));
        forms = new FormsPanel;
        layerRoles = bindLayerListPanel(owner, binding, forms, () => activeTool);
        imageRoles = bindImageListPanel(owner, binding);
        assert(imageRoles.state !is null,
            "6359 state floor: bindImageListPanel returned no ImageListPanelState");
    }

    void drawBoth() {
        ImGui.SetNextWindowPos(ImVec2(380, 0));
        ImGui.SetNextWindowSize(ImVec2(380, 600));
        drawLayerListPanel(layerRoles.read, layerRoles.actions,
                           layerRoles.state, renameState);
        ImGui.SetNextWindowPos(ImVec2(780, 0));
        ImGui.SetNextWindowSize(ImVec2(420, 600));
        drawImageListPanel(imageRoles.read, imageRoles.actions,
                           imageRoles.state, renameState);
    }

    HeadlessPanel openBoth() {
        resetLayerListDrawSnapshot();
        resetImageListDrawSnapshot();
        return openPanel(() { drawBoth(); }, "Retained host", 1280, 1000);
    }

    string names() {
        string s;
        foreach (i, l; owner.document.layers) s ~= (i ? "," : "") ~ l.name;
        return s;
    }

    size_t renameRecords() {
        size_t n;
        foreach (r; records) if (r.id == "layer.rename") ++n;
        return n;
    }
    size_t removeRecords() {
        size_t n;
        foreach (r; records) if (r.id == "image.remove") ++n;
        return n;
    }
}

private void enterTestMode(ref bool prior) {
    prior = g_testMode;
    g_testMode = true;
    assert(loadSDL() == sdlSupport, "6359 SDL population: binding did not load");
    SDL_SetModState(KMOD_NONE);
}

private ImVec2 center(ImVec2 lo, ImVec2 hi) {
    assert(hi.x > lo.x && hi.y > lo.y, "6359 widget rectangle is empty");
    return ImVec2((lo.x + hi.x) * 0.5f, (lo.y + hi.y) * 0.5f);
}

/// Double-click the Items row named `name` and settle two frames.
private void beginRename(RetainedHarness h, ref HeadlessPanel ui, string name) {
    auto rows = layerListDrawSnapshot().rows;
    assert(rows.length > 0, "6359 row population: Items recorded no rows");
    foreach (r; rows) if (r.name == name) {
        const p = center(r.nameMin, r.nameMax);
        ui.pressAt(p); ui.release();
        ui.pressAt(p); ui.release();
        settle(ui);
        return;
    }
    assert(false, "6359 row population: missing Items row " ~ name);
}

/// Frames after a document change: one to draw the changed rows, one for the
/// dead widget id to clear, two for a re-created editor to take keyboard focus.
private void settle(ref HeadlessPanel ui) {
    ui.frame(); ui.frame(); ui.frame(); ui.frame();
}

/// Type into whatever holds keyboard focus and press Enter, then settle.
private void typeAndEnter(ref HeadlessPanel ui, string text) {
    ui.typeText(text);
    ui.keyDown(cast(int) ImGuiKey.Enter); ui.frame();
    ui.keyUp(cast(int) ImGuiKey.Enter); ui.frame(); ui.frame();
}

private void openRemoveConfirm(RetainedHarness h, ref HeadlessPanel ui,
                               Layer image) {
    h.binding.dispatchUi("layer.select",
        `{"index":` ~ (cast(int) h.owner.document.indexOf(image)).stringOf ~ `,"mode":"set"}`);
    ui.frame();
    auto s = imageListDrawSnapshot();
    assert(s.removeEnabled, "6359 confirm floor: Remove is not enabled for " ~ image.name);
    ui.pressAt(center(s.removeMin, s.removeMax));
    ui.release();
    ui.frame();
    const view = imageListConfirmView(h.imageRoles.state);
    assert(view.held && view.target is image,
        "6359 confirm floor: this binding's state does not hold the clicked image after Remove");
    assert(view.referrers.length == 1 && view.referrers[0] is h.consumer,
        "6359 referrer floor: the confirmation did not keep Consumer by identity");
}

private string stringOf(int v) {
    import std.conv : to;
    return to!string(v);
}

private void releaseConfirm(ref HeadlessPanel ui) {
    auto s = imageListDrawSnapshot();
    assert(s.confirmDrawn, "6359 confirm press floor: no confirmation is drawn");
    ui.pressAt(center(s.confirmMin, s.confirmMax));
    ui.release();
}

private void pressConfirm(ref HeadlessPanel ui) {
    releaseConfirm(ui);
    ui.frame();
}

unittest { // J1: rename addresses its item after an earlier item is deleted
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.beginRename(ui, "Beta");
    assert(h.renameState.activeFor(h.beta),
        "6359 rename floor: the Items double-click did not open Beta's editor");

    h.binding.dispatchUi("layer.delete", `{"index":0}`);
    settle(ui);
    assert(h.owner.document.indexOf(h.beta) == 0
        && h.owner.document.indexOf(h.gamma) == 1,
        "6359 shift floor: Alpha's delete did not move Beta to 0 and Gamma to 1");
    const renames = h.renameRecords();
    typeAndEnter(ui, "Z");
    assert(h.beta.name == "Z" && h.gamma.name == "Gamma",
        "6359 old index: the rename went to the item now at the click-time index: "
        ~ h.names());
    assert(h.renameRecords() == renames + 1
        && h.history.undoEntries()[$ - 1].commandName == "layer.rename"
        && !h.renameState.open,
        "6359 rename commit: not exactly one layer.rename, or the editor stayed open");
}

unittest { // J2: a rename whose item left the document ends with no command
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.beginRename(ui, "Beta");
    assert(h.renameState.activeFor(h.beta),
        "6359 rename floor: the Items double-click did not open Beta's editor");

    // Control: removed and restored between two frames, the token stays open.
    h.binding.dispatchUi("layer.delete", `{"index":1}`);
    assert(h.history.undo(), "6359 undo floor: the delete could not be undone");
    settle(ui);
    assert(h.owner.document.indexOf(h.beta) == 1 && h.renameState.activeFor(h.beta),
        "6359 same identity: a delete undone before the next frame closed Beta's rename");

    // Target: removed across a frame, the rename ends and nothing dispatches.
    h.binding.dispatchUi("layer.delete", `{"index":1}`);
    settle(ui);
    assert(!h.owner.document.isMember(h.beta) && h.owner.document.indexOf(h.gamma) == 1,
        "6359 detach floor: Beta is not deleted or Gamma did not take index 1");
    auto depth = h.history.undoEntries().length;
    auto records = h.records.length;
    typeAndEnter(ui, "Z");
    assert(h.gamma.name == "Gamma" && h.records.length == records
        && h.history.undoEntries().length == depth,
        "6359 detached rename: a commit after the item left dispatched: "
        ~ h.names());

    assert(h.history.undo() && h.owner.document.indexOf(h.beta) == 1,
        "6359 restore floor: undo did not bring Beta back at index 1");
    settle(ui);
    depth = h.history.undoEntries().length;
    records = h.records.length;
    typeAndEnter(ui, "Z");
    assert(h.beta.name == "Beta" && h.records.length == records
        && h.history.undoEntries().length == depth,
        "6359 cancelled rename: the editor came back with the restored item: "
        ~ h.names());
    assert(!h.renameState.open,
        "6359 cancelled rename: the shared state still holds a detached item");
}

unittest { // J3: an item renamed to the target's name is not the target
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.beginRename(ui, "Beta");
    assert(h.renameState.activeFor(h.beta),
        "6359 rename floor: the Items double-click did not open Beta's editor");

    h.binding.dispatchUi("layer.rename", `{"index":2,"name":"Beta"}`);
    h.binding.dispatchUi("layer.delete", `{"index":1}`);
    settle(ui);
    assert(h.gamma.name == "Beta" && !h.owner.document.isMember(h.beta),
        "6359 twin floor: Gamma is not named Beta or Beta was not deleted");
    const depth = h.history.undoEntries().length;
    const records = h.records.length;
    typeAndEnter(ui, "Z");
    assert(h.gamma.name == "Beta" && h.records.length == records
        && h.history.undoEntries().length == depth,
        "6359 name match: the rename moved to a different item with the same name: "
        ~ h.names());
}

unittest { // J4: a replaced document with the same index is not the target
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.beginRename(ui, "Beta");
    assert(h.renameState.activeFor(h.beta),
        "6359 rename floor: the Items double-click did not open Beta's editor");

    Document next = Document.bootstrap(makeCube());
    next.layers[0].name = "Delta";
    next.layers ~= meshLayer("Epsilon");
    next.layers ~= meshLayer("Zeta");
    next.setActive(0);
    *h.owner.documentPtr() = next;
    settle(ui);
    assert(h.names() == "Delta,Epsilon,Zeta",
        "6359 replace floor: the replacement document has no item at index 1");
    const depth = h.history.undoEntries().length;
    const records = h.records.length;
    typeAndEnter(ui, "Z");
    assert(h.names() == "Delta,Epsilon,Zeta" && h.records.length == records
        && h.history.undoEntries().length == depth,
        "6359 replaced document: the rename landed on the new document's item: "
        ~ h.names());
}

unittest { // C1: Confirm removes its item after an earlier item is deleted
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.openRemoveConfirm(ui, h.imgOne);
    auto s = imageListDrawSnapshot();
    assert(s.confirmDrawn && s.confirmTarget is h.imgOne && h.removeRecords() == 0,
        "6359 confirm floor: ImgOne's confirmation is not open, or it dispatched");

    h.binding.dispatchUi("layer.delete", `{"index":1}`);
    ui.frame();
    assert(h.owner.document.indexOf(h.imgOne) == 2
        && h.owner.document.indexOf(h.imgTwo) == 3,
        "6359 shift floor: Beta's delete did not move ImgOne to 2 and ImgTwo to 3");
    releaseConfirm(ui);
    const view = imageListConfirmView(h.imageRoles.state);
    assert(!view.held && view.referrers.length == 0,
        "6359 successful cleanup: the binding retained the removed image or its referrers");
    ui.frame();
    assert(!h.owner.document.isMember(h.imgOne) && h.owner.document.isMember(h.imgTwo),
        "6359 old index: Confirm removed the item now at the click-time index: "
        ~ h.names());
    assert(h.removeRecords() == 1
        && h.history.undoEntries()[$ - 1].commandName == "image.remove"
        && h.history.undoEntries()[$ - 1].args == "index:2"
        && !imageListDrawSnapshot().confirmDrawn,
        "6359 confirm dispatch: not exactly one image.remove at the live index");
}

unittest { // C2: a confirmation whose item left the document closes, no command
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.openRemoveConfirm(ui, h.imgOne);
    assert(imageListDrawSnapshot().confirmDrawn,
        "6359 confirm floor: ImgOne's confirmation is not open");

    h.binding.dispatchUi("layer.delete", `{"index":3}`);
    assert(h.history.undo(), "6359 undo floor: the delete could not be undone");
    ui.frame();
    auto s = imageListDrawSnapshot();
    assert(s.confirmDrawn && s.confirmTarget is h.imgOne && s.confirmIndex == 3,
        "6359 same identity: a delete undone before the next frame closed the confirmation");

    h.binding.dispatchUi("layer.delete", `{"index":3}`);
    const depth = h.history.undoEntries().length;
    const records = h.records.length;
    ui.frame();
    assert(!imageListDrawSnapshot().confirmDrawn,
        "6359 detached confirmation: the popup outlived its item");
    assert(!imageListConfirmView(h.imageRoles.state).held
        && h.records.length == records && h.history.undoEntries().length == depth
        && h.owner.document.isMember(h.imgTwo),
        "6359 detached confirmation: closing dispatched or kept the item: " ~ h.names());
    bool sawTwo;
    ImVec2 twoMarker;
    foreach (r; imageListDrawSnapshot().rows)
        if (r.name == "ImgTwo") { sawTwo = true; twoMarker = center(r.markerMin, r.markerMax); }
    assert(sawTwo, "6359 release floor: the Images rows lost ImgTwo");
    assert(ui.anyItemHoveredAt(twoMarker),
        "6359 modal release: the closed confirmation still blocks the Images rows");

    assert(h.history.undo() && h.owner.document.indexOf(h.imgOne) == 3,
        "6359 restore floor: undo did not bring ImgOne back at index 3");
    settle(ui);
    assert(!imageListDrawSnapshot().confirmDrawn,
        "6359 cancelled confirmation: the popup came back with the restored item");
}

unittest { // C3: a changed referrer sentence needs a second Confirm
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.openRemoveConfirm(ui, h.imgOne);
    enum before = "\"ImgOne\" is still used by 1 item(s): Consumer";
    enum after = "\"ImgOne\" is still used by 2 item(s): Consumer, Second";
    assert(imageListDrawSnapshot().confirmText == before,
        "6359 sentence floor: the confirmation did not name one referrer");

    h.binding.dispatchUi("imagePlane.add", `{"name":"Second","image":3}`);
    auto second = h.owner.document.layers[$ - 1];
    assert(second.name == "Second" && second.linksTo(h.imgOne),
        "6359 second-referrer floor: imagePlane.add did not create the linked plane");
    ui.frame();
    assert(imageListDrawSnapshot().confirmText == before,
        "6359 draw sweep: the frame recomputed referrers outside a click");

    pressConfirm(ui);
    auto s = imageListDrawSnapshot();
    assert(h.owner.document.isMember(h.imgOne) && h.removeRecords() == 0,
        "6359 stale sentence: Confirm removed an item whose referrers changed");
    assert(s.confirmDrawn && s.confirmText == after,
        "6359 refreshed sentence: the confirmation did not stay open with the new referrers: "
        ~ s.confirmText);

    pressConfirm(ui);
    assert(!h.owner.document.isMember(h.imgOne) && h.removeRecords() == 1
        && !imageListDrawSnapshot().confirmDrawn,
        "6359 second Confirm: the re-read sentence did not remove ImgOne once");
}

unittest { // C3b: a referrer replaced by a same-named item needs a second Confirm
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.openRemoveConfirm(ui, h.imgOne);
    enum sentence = "\"ImgOne\" is still used by 1 item(s): Consumer";
    assert(imageListDrawSnapshot().confirmText == sentence,
        "6359 sentence floor: the confirmation did not name one referrer");

    // Replace Consumer through the public command surface. The new plane has
    // the same display name and link, so only its Layer identity changes.
    h.binding.dispatchUi("imagePlane.add", `{"name":"Consumer","image":3}`);
    auto twin = h.owner.document.layers[$ - 1];
    h.binding.dispatchUi("layer.delete", `{"index":5}`);
    ui.frame();
    assert(!h.owner.document.isMember(h.consumer) && twin !is h.consumer
        && imageListDrawSnapshot().confirmText == sentence,
        "6359 namesake floor: Consumer was not replaced, or the drawn sentence changed");

    pressConfirm(ui);
    assert(h.owner.document.isMember(h.imgOne) && h.removeRecords() == 0,
        "6359 namesake referrer: Confirm removed an item whose referrers were replaced under an equal sentence");
    const view = imageListConfirmView(h.imageRoles.state);
    assert(imageListDrawSnapshot().confirmDrawn && view.referrers.length == 1
        && view.referrers[0] is twin && view.text == sentence,
        "6359 refreshed referrers: the confirmation did not stay open holding the new referrer");

    pressConfirm(ui);
    assert(!h.owner.document.isMember(h.imgOne) && h.removeRecords() == 1
        && !imageListDrawSnapshot().confirmDrawn,
        "6359 second Confirm: the refreshed referrers did not remove ImgOne once");
}

unittest { // C3c: a renamed referrer, then no referrer at all, each need one more Confirm
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.openRemoveConfirm(ui, h.imgOne);

    h.binding.dispatchUi("layer.rename", `{"index":5,"name":"Renamed"}`);
    ui.frame();
    assert(h.consumer.name == "Renamed" && imageListDrawSnapshot().confirmText
            == "\"ImgOne\" is still used by 1 item(s): Consumer",
        "6359 renamed floor: Consumer was not renamed, or the frame re-read the sentence");
    pressConfirm(ui);
    assert(h.owner.document.isMember(h.imgOne) && h.removeRecords() == 0,
        "6359 renamed referrer: Confirm removed an item whose sentence changed under the same referrers");
    assert(imageListDrawSnapshot().confirmText == "\"ImgOne\" is still used by 1 item(s): Renamed",
        "6359 refreshed sentence: the confirmation does not show the renamed referrer: "
        ~ imageListDrawSnapshot().confirmText);

    h.binding.dispatchUi("imagePlane.setImage", `{"index":5,"image":-1}`);
    ui.frame();
    pressConfirm(ui);
    assert(h.owner.document.isMember(h.imgOne) && h.removeRecords() == 0
        && imageListDrawSnapshot().confirmDrawn
        && imageListDrawSnapshot().confirmText.length == 0,
        "6359 emptied referrers: Confirm removed at once when the last referrer went away");
    pressConfirm(ui);
    assert(!h.owner.document.isMember(h.imgOne) && h.removeRecords() == 1
        && !imageListDrawSnapshot().confirmDrawn,
        "6359 no dead end: a confirmation with no referrers left did not remove on the next Confirm");
}

unittest { // C4: two bindings do not share a confirmation
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto a = new RetainedHarness;
    auto b = new RetainedHarness;
    RetainedHarness current = a;
    resetImageListDrawSnapshot();
    auto ui = openPanel(() {
        ImGui.SetNextWindowPos(ImVec2(380, 0));
        ImGui.SetNextWindowSize(ImVec2(420, 600));
        drawImageListPanel(current.imageRoles.read, current.imageRoles.actions,
                           current.imageRoles.state, current.renameState);
    }, "Two bindings host", 1280, 1000);
    scope (exit) ui.close();
    ui.frame();
    a.openRemoveConfirm(ui, a.imgOne);
    auto s = imageListDrawSnapshot();
    assert(s.confirmDrawn && s.confirmTarget is a.imgOne,
        "6359 binding floor: A's confirmation did not open");

    current = b;
    settle(ui);
    s = imageListDrawSnapshot();
    assert(s.drawn && !s.confirmDrawn && !imageListConfirmView(b.imageRoles.state).held,
        "6359 binding control: B's frames did not draw, or B drew a confirmation");
    assert(imageListConfirmView(a.imageRoles.state).held
        && imageListConfirmView(a.imageRoles.state).target is a.imgOne,
        "6359 singleton state: drawing B cancelled A's pending confirmation");
}

unittest { // C4b: an ImGui-closed modal releases its retained state
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    bool shown = true;
    resetImageListDrawSnapshot();
    auto ui = openPanel(() {
        if (!shown) return;
        ImGui.SetNextWindowPos(ImVec2(380, 0));
        ImGui.SetNextWindowSize(ImVec2(420, 600));
        drawImageListPanel(h.imageRoles.read, h.imageRoles.actions,
                           h.imageRoles.state, h.renameState);
    }, "Hidden Images host", 1280, 1000);
    scope (exit) ui.close();
    ui.frame();
    h.openRemoveConfirm(ui, h.imgOne);
    assert(imageListDrawSnapshot().confirmDrawn,
        "6359 hidden-panel floor: the confirmation did not open");
    const records = h.records.length;

    shown = false;
    ui.frame();
    ui.frame();
    shown = true;
    ui.frame();
    ui.frame();

    const view = imageListConfirmView(h.imageRoles.state);
    assert(!imageListDrawSnapshot().confirmDrawn,
        "6359 hidden-panel route: the modal survived two unsubmitted frames");
    assert(!view.held && view.referrers.length == 0,
        "6359 hidden-panel cleanup: an ImGui-closed modal retained its image or referrers");
    assert(h.records.length == records && h.owner.document.isMember(h.imgOne),
        "6359 hidden-panel cleanup: closing the modal dispatched image.remove");
}

unittest { // C5: an image renamed to the target's name is not the target
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.openRemoveConfirm(ui, h.imgOne);
    assert(imageListDrawSnapshot().confirmDrawn,
        "6359 confirm floor: ImgOne's confirmation is not open");
    h.binding.dispatchUi("layer.rename", `{"index":4,"name":"ImgOne"}`);
    h.binding.dispatchUi("layer.delete", `{"index":3}`);
    const records = h.records.length;
    ui.frame();
    auto s = imageListDrawSnapshot();
    if (s.confirmDrawn) pressConfirm(ui);
    assert(h.owner.document.isMember(h.imgTwo) && h.records.length == records,
        "6359 name match: the confirmation moved to a different image with the same name: "
        ~ h.names());
}

unittest { // J6: an index shift re-creates the editor, whose re-focus selects the kept text
    // KNOWN LIMIT pinned as it is (follow-up card: key the Items/Images editor
    // id by identity). The buffer survives; the re-created field selects it on
    // focus, so the next key replaces it. That follow-up turns "a2" into "Beta2".
    bool prior; enterTestMode(prior);
    scope (exit) { g_testMode = prior; SDL_SetModState(KMOD_NONE); }
    auto h = new RetainedHarness;
    auto ui = h.openBoth();
    scope (exit) ui.close();
    ui.frame();
    h.beginRename(ui, "Beta");
    ui.typeText("Bet");
    ui.frame();
    assert(h.renameState.activeFor(h.beta) && h.renameState.text == "Bet",
        "6359 typing floor: Beta's editor did not take the typed text");

    h.binding.dispatchUi("layer.delete", `{"index":0}`);
    settle(ui);
    assert(h.renameState.activeFor(h.beta) && h.renameState.text == "Bet",
        "6359 kept buffer: the index shift closed Beta's rename or lost its text");
    typeAndEnter(ui, "a2");
    assert(h.beta.name == "a2" && h.gamma.name == "Gamma",
        "6359 re-focus: the re-created editor no longer selects its kept text (update with the identity-id follow-up): "
        ~ h.names());
}

private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "6359 census missing source marker " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "6359 census found no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    assert(false, "6359 census found an unterminated body after " ~ marker);
}

private size_t identifierCount(string code, string identifier) {
    static bool ch(char c) {
        return c == '_' || (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z')
            || (c >= 'a' && c <= 'z');
    }
    size_t total, from;
    while (from < code.length) {
        const hit = code.indexOf(identifier, from);
        if (hit < 0) break;
        const pos = cast(size_t) hit;
        const end = pos + identifier.length;
        if ((pos == 0 || !ch(code[pos - 1])) && (end == code.length || !ch(code[end])))
            ++total;
        from = end;
    }
    return total;
}

private string collapseWhitespace(string text) {
    string result;
    bool spacing;
    foreach (c; text) {
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
            spacing = result.length > 0;
            continue;
        }
        if (spacing) result ~= ' ';
        result ~= c;
        spacing = false;
    }
    return result;
}

unittest { // J5 census: one resolve contract, one state per binding, no statics
    const images = blankNonCode(readText(repoRoot.buildPath("source", "ui", "image_list_panel.d")));
    const rename = blankNonCode(readText(repoRoot.buildPath("source", "ui", "item_rename.d")));
    assert(images.length > 10_000 && rename.length > 1_000,
        "6359 census population: panel or rename source is unexpectedly small");
    const draw = bodyAt(images,
        "void drawImageListPanel(ImageListReadRole read, ImageListActions actions,");
    assert(identifierCount(draw, "static") == 0,
        "6359 state census: the Images draw declares function-static state again");
    assert(draw.count("assert(state !is null,") == 1,
        "6359 state census: the Images draw no longer checks its binding-owned state");
    const binder = bodyAt(images, "ImageListPanelRoles bindImageListPanel(Session* owner,");
    assert(images.count("new ImageListPanelState") == 1
        && binder.count("new ImageListPanelState") == 1,
        "6359 state census: the Images panel state is created outside its binder");
    assert(draw.count("state.confirmTarget_.resolve(*read.document(), confirmIndex)") == 1
        && draw.count("imageRemoveConfirm(") == 2
        && draw.count("state.confirmUnchanged(current)") == 1,
        "6359 confirm census: the confirmation no longer resolves once per frame or re-reads at Confirm");
    assert(draw.count("imageRowsInto(read.document(), currentDocPath(), state.rows_)") == 1
        && draw.count("auto rows = state.rows_") == 1,
        "6359 row-buffer ownership: the Images draw no longer uses its binding's buffer");
    const layers = blankNonCode(readText(repoRoot.buildPath("source", "ui", "layer_list_panel.d")));
    const items = bodyAt(layers, "void drawLayerListPanel(LayerListReadRole read, LayerListActions actions,");
    foreach (panel; [[draw, "Images"], [items, "Items"]]) {
        const bindAt = panel[0].indexOf("bindItemRenameController(");
        const beginAt = panel[0].indexOf("ImGui.Begin(");
        assert(panel[0].count("bindItemRenameController(") == 1
            && panel[0].count("ImGui.Begin(") == 1,
            "6359 bind census population: expected one rename bind and one window in " ~ panel[1]);
        assert(bindAt < beginAt,
            "6359 bind census: the panel binds its rename inside its window, so a hidden tab keeps a detached rename: "
            ~ panel[1]);
    }
    const bind = bodyAt(rename, "ItemRenameController bindItemRenameController(");
    assert(bind.count("rename.cancelDetached();") == 1,
        "6359 rename census: binding a draw no longer cancels a detached rename");
    assert(collapseWhitespace(rename).count(
            "state_.target_.resolve(*document_, index)") == 2,
        "6359 rename census: the rename no longer resolves its item at cancel and at commit");
}

unittest { // R0: an empty token holds nothing, not even the null item
    import ui.retained_item : RetainedItem;
    RetainedItem token;
    Document document;
    document.layers = [new Layer];
    size_t index;
    assert(!token.held && !token.holds(null) && !token.resolve(document, index),
        "6359 empty token: a released item still matches the null row");
    auto item = new Layer;
    token.hold(item);
    assert(token.held && token.holds(item) && !token.holds(null)
        && !token.resolve(document, index),
        "6359 held token: the held item does not match itself, matches null, or resolves outside the document");
    document.layers ~= item;
    assert(token.resolve(document, index) && index == 1,
        "6359 held token: a member item does not resolve to its live index");
    token.release();
    assert(!token.held && !token.holds(item) && !token.holds(null),
        "6359 released token: release kept the item or matches null");
}
