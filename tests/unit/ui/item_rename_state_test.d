module tests.unit.ui.item_rename_state_test;

import application_command_binding : ApplicationCommandBinding;
import command : Command;
import command_executor : CommandExecutor;
import command_history : CommandHistory, RecordMode;
import commands.layer.commands : LayerRename;
import document : ImageData, ItemKind, Layer;
import edit_session : EditSession;
import guarded_action_controller : GuardObservationPorts,
    GuardedActionController, GuardedActionPorts;
import mesh : makeCube;
import registry : Registry;
import session_owner : Session;
import tool : Tool;
import tool_activation_ownership : ToolTransition;
import ui.discard_guard : GuardRecord;
import ui.item_rename : ItemRenameCapacity, ItemRenameController,
    ItemRenameExit, ItemRenameState, bindItemRenameController;
import view : View;

private final class RenameApplicationHarness {
    Session* owner;
    View view;
    Registry registry;
    CommandHistory history;
    CommandExecutor executor;
    EditSession editSession;
    GuardedActionController guard;
    ApplicationCommandBinding binding;
    Tool activeTool;
    ItemRenameState renameState;
    GuardRecord[] records;

    this() {
        owner = Session.bootstrap(makeCube());
        view = new View(0, 0, 800, 600);

        auto image = new Layer;
        image.kind = ItemKind.Image;
        image.name = "Image seed";
        image.imageRef() = new ImageData;
        owner.document.layers ~= image;

        history = new CommandHistory;
        executor = new CommandExecutor(history,
            () => activeTool !is null,
            (ToolTransition) { activeTool = null; });
        editSession = new EditSession(
            () => activeTool, history, () { activeTool = null; });
        guard = new GuardedActionController(GuardedActionPorts(
            (Command command, RecordMode mode) =>
                executor.applyOrRefire(command, mode, null),
            () => false,
            () => true,
            (Command) {},
            GuardObservationPorts(
                (record) { records ~= record; }, (answer, performed) {}, (pending) {})));
        binding = new ApplicationCommandBinding(
            registry, executor, editSession, history, guard,
            (Command) {}, (string) {});

        registry.registerCommand("layer.rename", () => cast(Command)
            new LayerRename(owner.document.activeMesh(), view,
                owner.editMode, owner.documentPtr(), null));
    }

    ItemRenameController layersPanel() {
        return bindItemRenameController(renameState, owner.documentPtr(),
            (string id, string args) => binding.dispatchUi(id, args));
    }

    ItemRenameController imagesPanel() {
        return bindItemRenameController(renameState, owner.documentPtr(),
            (string id, string args) => binding.dispatchUi(id, args));
    }
}

unittest { // Layers begins; Images observes and commits through the real action
    auto app = new RenameApplicationHarness;
    auto layers = app.layersPanel();
    auto images = app.imagesPanel();

    auto image = app.owner.document.layers[1];
    layers.begin(image, image.name);
    assert(app.renameState.open && app.renameState.activeFor(image)
        && app.renameState.text == "Image seed",
        "5880 floor: the Layers action did not actually start item rename");
    assert(images.activeFor(image) && images.text == "Image seed",
        "5880 cross-panel: Images did not observe the rename started in Layers");
    assert(!images.activeFor(app.owner.document.layers[0]) && !images.activeFor(null),
        "5880 index identity: Images reported rename active for unrelated layer rows");

    layers.begin(image, "Background");
    layers.begin(image, "Hat");
    assert(images.text == "Hat",
        "5880 buffer reset: shorter seed retained bytes from the previous item name");

    immutable editedName = "100% готово — 東京";
    images.setText(editedName);
    assert(images.text == editedName,
        "5880 edit: percent/non-ASCII text did not survive the shared buffer");
    assert(app.owner.document.layers[1].name == "Image seed"
        && app.history.undoEntries().length == 0,
        "5880 commit floor: rename changed the model or history before commit");

    images.finish(ItemRenameExit.commit);
    assert(app.owner.document.layers[1].name == editedName,
        "5880 commit: the real layer.rename action did not change the visible item name");
    assert(app.history.undoEntries().length == 1
        && app.history.undoEntries()[0].commandName == "layer.rename",
        "5880 commit: layer.rename did not create exactly one history entry");
    assert(!app.renameState.open,
        "5880 commit: the shared editor remained active after commit");
}

unittest { // cancel and plain deactivation are distinct non-command exits
    auto app = new RenameApplicationHarness;
    auto layers = app.layersPanel();
    auto images = app.imagesPanel();

    auto image = app.owner.document.layers[1];
    layers.begin(image, "Image seed");
    assert(images.activeFor(image),
        "5880 cancel floor: rename was not active before cancel");
    images.setText("cancelled");
    images.finish(ItemRenameExit.cancel);
    assert(!app.renameState.open
        && app.owner.document.layers[1].name == "Image seed"
        && app.history.undoEntries().length == 0,
        "5880 cancel: Escape must close without changing name/history");

    layers.begin(image, "Image seed");
    assert(images.activeFor(image),
        "5880 deactivate floor: rename was not active before deactivation");
    images.setText("deactivated");
    images.finish(ItemRenameExit.deactivate);
    assert(!app.renameState.open
        && app.owner.document.layers[1].name == "Image seed"
        && app.history.undoEntries().length == 0,
        "5880 deactivate: untouched focus loss must close without a command");

    layers.begin(image, "x");
    images.setText("");
    images.finish(ItemRenameExit.commit);
    assert(app.owner.document.layers[1].name == "Image seed"
        && app.history.undoEntries().length == 0,
        "5880 empty commit: blank rename changed the visible name or created history");
}

unittest { // a commit whose item left the document dispatches nothing
    auto app = new RenameApplicationHarness;
    auto images = app.imagesPanel();
    auto image = app.owner.document.layers[1];
    images.begin(image, "Image seed");
    images.setText("Renamed");
    assert(app.renameState.activeFor(image) && app.records.length == 0,
        "6359 detached floor: rename was not open on the image before its removal");

    app.owner.document.layers = app.owner.document.layers[0 .. 1];
    images.finish(ItemRenameExit.commit);
    assert(app.records.length == 0 && app.history.undoEntries().length == 0
        && image.name == "Image seed",
        "6359 detached commit: the controller dispatched a rename for an item outside the document");
    assert(!app.renameState.open,
        "6359 detached commit: the editor stayed open after the commit was dropped");
}

unittest { // fixed capacity/terminator and per-application ownership
    auto a = new RenameApplicationHarness;
    auto b = new RenameApplicationHarness;
    assert(a.renameState.buffer.ptr !is b.renameState.buffer.ptr,
        "5880 instances: two applications share one rename backing buffer");

    char[] oversized;
    oversized.length = ItemRenameCapacity + 23;
    oversized[] = 'x';
    a.layersPanel().begin(a.owner.document.layers[1], cast(string)oversized);
    assert(a.renameState.activeFor(a.owner.document.layers[1]),
        "5880 capacity floor: oversized rename did not actually start");
    assert(a.renameState.buffer.length == ItemRenameCapacity
        && a.renameState.buffer[$ - 1] == 0
        && a.renameState.text.length == ItemRenameCapacity - 1,
        "5880 capacity: buffer lost its fixed size, terminator, or length-1 cap");
    assert(!b.renameState.open && b.renameState.text.length == 0,
        "5880 instances: editing application A changed application B's owner");
}

private string repositoryRoot() {
    import std.path : dirName;

    return __FILE_FULL_PATH__.dirName.dirName.dirName.dirName;
}

private string bodyAt(string code, string marker) {
    import std.exception : enforce;
    import std.string : indexOf;

    const at = code.indexOf(marker);
    enforce(at >= 0, "missing source marker `" ~ marker ~ "`");
    size_t i = cast(size_t)at;
    while (i < code.length && code[i] != '{') ++i;
    enforce(i < code.length, "no body after source marker `" ~ marker ~ "`");
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0)
            return code[begin .. i + 1];
    }
    enforce(false, "unterminated body after source marker `" ~ marker ~ "`");
    return null;
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

unittest { // production passes one owner and both panel writers consume it
    import std.algorithm : count;
    import std.algorithm.searching : canFind;
    import std.file : readText;
    import std.path : buildPath;
    import tests.unit.census_symbols : blankNonCode;

    const root = repositoryRoot();
    const app = blankNonCode(readText(root.buildPath("source", "app.d")));
    const editor = blankNonCode(readText(root.buildPath("source", "editor_app.d")));
    const layerPanel = blankNonCode(readText(root.buildPath(
        "source", "ui", "layer_list_panel.d")));
    const imagePanel = blankNonCode(readText(root.buildPath(
        "source", "ui", "image_list_panel.d")));
    const state = blankNonCode(readText(root.buildPath("source", "ui", "item_rename.d")));

    assert(app.count("ItemRenameState itemRenameState;") == 1,
        "5880 production owner: app must construct exactly one ItemRenameState");
    const mainBody = bodyAt(app, "void main(string[] args)");
    assert(mainBody.count("ItemRenameState itemRenameState;") == 1,
        "5880 application ownership: ItemRenameState escaped main into process-global storage");
    const flatApp = collapseWhitespace(app);
    assert(flatApp.count(
        "drawLayerListPanel(layerListRoles.read, layerListRoles.actions, layerListRoles.state, itemRenameState);") == 1,
        "5880 Layers wiring: Layers no longer receives main's itemRenameState owner");
    assert(flatApp.count(
        "drawImageListPanel(imageListRoles.read, imageListRoles.actions, imageListRoles.state, itemRenameState);") == 1,
        "5880 cross-panel wiring: Images no longer receives the same ItemRenameState owner");

    const layersBody = bodyAt(layerPanel,
        "void drawLayerListPanel(LayerListReadRole read, LayerListActions actions,");
    const imagesBody = bodyAt(imagePanel,
        "void drawImageListPanel(ImageListReadRole read, ImageListActions actions,");
    assert(collapseWhitespace(layersBody).canFind(
            "bindItemRenameController(itemRenameState, read.document(), actions.commandDispatch())")
        && layersBody.canFind("rename.begin(r.layer, r.renameSeed);")
        && layersBody.canFind("rename.finish(exit);"),
        "5880 Layers writer: rename open/exit stopped using the shared owner");
    assert(collapseWhitespace(imagesBody).canFind(
            "bindItemRenameController(itemRenameState, read.document(), dispatch)")
        && imagesBody.canFind("rename.begin(r.layer, r.renameSeed);")
        && imagesBody.canFind("rename.finish(exit);"),
        "5880 Images writer: rename open/exit stopped using the shared owner, so its visible name cannot change");

    foreach (retired; ["layerRenameIndexPtr", "layerRenameBufPtr",
             "layerRenameIndex", "layerRenameBuf"])
        assert(!app.canFind(retired) && !editor.canFind(retired),
            "5880 retired pointer storage returned: " ~ retired);
    assert(!state.canFind("EditorApp") && !state.canFind("editor_app"),
        "5880 owner/controller regained an EditorApp dependency");
}
