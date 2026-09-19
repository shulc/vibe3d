module tests.unit.commands.layer.item_command_registration_test;

import std.algorithm : count;
import std.array : array;
import std.exception : assertThrown;
import std.format : format;
import std.json : parseJSON;

import ai3d.job_controller : Ai3dJobController;
import ai3d_command_registration : registerAi3dCommands;
import command : Command;
import command_args : bindArgs;
import core.exception : AssertError;
import document : Document, ImageData, Layer;
import editmode : EditMode;
import item_command_registration : ItemLifecycleDoors, registerItemCommands;
import item_kinds : ItemKind;
import mesh : makeCube;
import seltype : currentSelType, SelMode, SelType;
import std.file : readText;
import std.regex : ctRegex, matchAll;
import tests.unit.census_symbols : blankNonCode;
import tests.unit.live_registration_rig : LiveRegistrationRig;

private immutable string[15] kItemIds = [
    "layer.add", "layer.duplicate", "layer.delete", "layer.reorder",
    "layer.select", "layer.rename", "layer.setVisible", "layer.attr",
    "layer.parent", "image.load", "image.replace", "image.reload",
    "image.remove", "imagePlane.add", "imagePlane.setImage",
];

private immutable string[5] kAi3dIds = [
    "ai3d.importResult", "ai3d.generate", "ai3d.generate.start",
    "ai3d.generate.cancel", "ai3d.generate.open",
];

private void registerFamilies(LiveRegistrationRig rig,
        void delegate(size_t, size_t) hook, void delegate() promote) {
    registerItemCommands(rig.registry, rig.liveSession(), rig.liveViewMode(),
        ItemLifecycleDoors(hook, promote));
    registerAi3dCommands(rig.registry, rig.liveSession(), rig.liveViewMode(),
        hook, new Ai3dJobController, (string path) {});
}

private void registerFamilies(LiveRegistrationRig rig) {
    registerFamilies(rig, (size_t previous, size_t next) {}, () {});
}

private void registerFamilies(LiveRegistrationRig rig,
        void delegate(size_t, size_t) hook) {
    registerFamilies(rig, hook, () {});
}

private Command commandFor(LiveRegistrationRig rig, string id,
                           string args = null) {
    auto command = rig.registry.makeCommand(id);
    if (args.length) bindArgs(command, args);
    return command;
}

unittest { // C0: the witness drives production instead of rebuilding it
    immutable self = blankNonCode(readText(__FILE_FULL_PATH__));
    assert(self.length > 3_000,
        "6355 self-census floor: the test file is missing or truncated");
    assert(self.count("registerItemCommands(") >= 1
        && self.count("registerAi3dCommands(") >= 1,
        "6355 self-census: the production registrars are not driven");
    foreach (constructed; ["new LayerAdd(", "new ImagePlaneAdd(",
                           "new Ai3dImportResult("])
        assert(self.count(constructed) == 0,
            "6355 self-census: the test constructs its own collaborator: "
            ~ constructed);
    assert(self.matchAll(ctRegex!(`reg\s*\.\s*registerCommand\s*\(`)).empty,
        "6355 self-census: the test writes a stand-in production registry");
}

unittest { // C1: exact population and key-to-class identity
    auto rig = new LiveRegistrationRig;
    assert(rig.registry.commandIds().length == 0,
        "6355 population floor: the rig registry must begin empty");
    registerItemCommands(rig.registry, rig.liveSession(), rig.liveViewMode(),
        ItemLifecycleDoors((size_t previous, size_t next) {}, () {}));
    static assert(kItemIds.length == 15);
    assert(rig.registry.commandIds().length == 15,
        format("6355 item population: expected 15 ids, got %d",
               rig.registry.commandIds().length));
    registerAi3dCommands(rig.registry, rig.liveSession(), rig.liveViewMode(),
        (size_t previous, size_t next) {}, new Ai3dJobController,
        (string path) {});
    static assert(kAi3dIds.length == 5);
    assert(rig.registry.commandIds().length == 20,
        format("6355 total population: expected 20 ids, got %d",
               rig.registry.commandIds().length));
    size_t visited;
    foreach (id; kItemIds[] ~ kAi3dIds[]) {
        auto command = rig.registry.makeCommand(id);
        assert(command !is null, "6355 population: missing " ~ id);
        assert(command.name() == id,
            id ~ " built the wrong command class: " ~ command.name());
        ++visited;
    }
    assert(visited == 20, "6355 identity witness visited fewer than 20 ids");
}

unittest { // C3: every factory resolves Mesh, View and EditMode at fire time
    auto rig = new LiveRegistrationRig;
    registerFamilies(rig);
    auto meshA = &rig.layerA.meshRef();
    auto viewA = rig.liveView();
    size_t controls;
    foreach (id; kItemIds[] ~ kAi3dIds[]) {
        auto command = rig.registry.makeCommand(id);
        assert(command.meshPtr() is meshA,
            "6355 live input control: " ~ id ~ " did not take layer A");
        assert(command.viewRef() is viewA,
            "6355 live input control: " ~ id ~ " did not take cell 0");
        assert(command.editModeVal() == EditMode.Vertices,
            "6355 live input control: " ~ id ~ " did not take Vertices");
        ++controls;
    }
    assert(controls == 20, "6355 live input control visited fewer than 20 ids");

    rig.switchToB();
    assert(&rig.layerB.meshRef() !is meshA && rig.liveView() !is viewA
        && rig.session.editMode == EditMode.Polygons,
        "6355 live input fixture did not change all three inputs");
    size_t targets;
    foreach (id; kItemIds[] ~ kAi3dIds[]) {
        auto command = rig.registry.makeCommand(id);
        assert(command.meshPtr() is &rig.layerB.meshRef(),
            "6355 live Mesh target: " ~ id
            ~ " retained the registration-time mesh");
        assert(command.viewRef() is rig.liveView(),
            "6355 live View target: " ~ id
            ~ " retained the registration-time View");
        assert(command.editModeVal() == EditMode.Polygons,
            "6355 live mode target: " ~ id
            ~ " retained the registration-time mode");
        ++targets;
    }
    assert(targets == 20, "6355 live input target visited fewer than 20 ids");
}

unittest { // C5: both item lifecycle doors are mandatory
    assertThrown!AssertError(ItemLifecycleDoors(null, () {}));
    assertThrown!AssertError(ItemLifecycleDoors(
        (size_t previous, size_t next) {}, null));
    static assert(!__traits(compiles, ItemLifecycleDoors()));
}

unittest { // C5b: all three AI-3D doors are mandatory
    auto rig = new LiveRegistrationRig;
    auto controller = new Ai3dJobController;
    void delegate(size_t, size_t) hook = (size_t previous, size_t next) {};
    void delegate(string) openGenerate = (string path) {};
    assertThrown!AssertError(registerAi3dCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), null,
        controller, openGenerate));
    assertThrown!AssertError(registerAi3dCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), hook,
        null, openGenerate));
    assertThrown!AssertError(registerAi3dCommands(
        rig.registry, rig.liveSession(), rig.liveViewMode(), hook,
        controller, null));
    registerAi3dCommands(rig.registry, rig.liveSession(), rig.liveViewMode(),
        hook, controller, openGenerate);
    assert(rig.registry.commandIds().length == 5,
        "6355 AI door floor: live doors did not register exactly five ids");
}

unittest { // C6: layer.rename writes the live in-place replacement
    auto rig = new LiveRegistrationRig;
    registerFamilies(rig);
    rig.layerA.name = "old A";
    rig.layerB.name = "old B";
    auto oldLayers = rig.session.document.layers.dup;
    const oldNameA = oldLayers[0].name;
    const oldNameB = oldLayers[1].name;
    assert(oldLayers.length == 2 && oldNameA.length && oldNameB.length,
        "6355 rename floor: old document population is incomplete");

    *rig.session.documentPtr() = Document.bootstrap(makeCube());
    assert(rig.session.document.layers.length == 1
        && rig.session.document.layers[0] !is oldLayers[0],
        "6355 rename fixture: document was not replaced in place");
    auto command = commandFor(rig, "layer.rename",
                              `{"index":0,"name":"live"}`);
    assert(command.apply(), "6355 live rename unexpectedly refused");
    assert(rig.session.document.layers[0].name == "live",
        "6355 live document was not renamed");
    assert(oldLayers[0].name == oldNameA && oldLayers[1].name == oldNameB,
        "6355 stale document was renamed through a by-value snapshot");
}

unittest { // C7: image.remove and imagePlane.add address the live Document
    auto control = new LiveRegistrationRig;
    auto clip = new Layer;
    clip.name = "clip";
    clip.kind = ItemKind.Image;
    clip.imageRef() = new ImageData;
    control.session.document.layers ~= clip;
    registerFamilies(control);
    auto removeControl = commandFor(control, "image.remove", `{"index":2}`);
    assert(removeControl.apply(),
        "6355 image.remove floor: a real image in the old document was not removable");

    auto rig = new LiveRegistrationRig;
    auto oldClip = new Layer;
    oldClip.name = "old clip";
    oldClip.kind = ItemKind.Image;
    oldClip.imageRef() = new ImageData;
    rig.session.document.layers ~= oldClip;
    auto oldLayers = rig.session.document.layers.dup;
    assert(oldLayers.length == 3 && oldLayers[$ - 1].hasImage,
        "6355 live document floor: old image item is missing");
    registerFamilies(rig);
    *rig.session.documentPtr() = Document.bootstrap(makeCube());
    assert(rig.session.document.layers.length == 1,
        "6355 image fixture: live replacement has the wrong population");

    auto remove = commandFor(rig, "image.remove", `{"index":0}`);
    assert(!remove.apply() && remove.refusalReason().length,
        "6355 image.remove must refuse when the live document has no image");
    assert(oldLayers[$ - 1].hasImage,
        "6355 image.remove touched the stale document");
    const beforeLive = rig.session.document.layers.length;
    const beforeOld = oldLayers.length;
    auto addPlane = commandFor(rig, "imagePlane.add");
    assert(addPlane.apply(), "6355 live imagePlane.add unexpectedly refused");
    assert(rig.session.document.layers.length == beforeLive + 1,
        "6355 imagePlane.add did not append to the live document");
    assert(oldLayers.length == beforeOld,
        "6355 imagePlane.add appended to the stale document");
}

unittest { // C8: layer.select reaches the item-type promotion door
    auto rig = new LiveRegistrationRig;
    registerFamilies(rig, (size_t previous, size_t next) {},
        () { rig.session.promoteItemType(); });
    assert(currentSelType(rig.session.selTypeOrder) != SelType.Item,
        "6355 promotion floor: Item was already the current selection type");
    auto command = commandFor(rig, "layer.select", `{"index":1,"mode":"set"}`);
    assert(command.apply(), "6355 layer.select promotion fixture refused");
    assert(currentSelType(rig.session.selTypeOrder) == SelType.Item,
        "6355 layer.select did not promote the item selection type");
}

unittest { // C9: hook reaches the commands that can move primary
    size_t[2][] pairs;
    auto rig = new LiveRegistrationRig;
    registerFamilies(rig, (size_t previous, size_t next) {
        pairs ~= [previous, next];
    });
    assert(rig.session.document.primary is rig.layerA,
        "6355 hook floor: layer A must begin primary");
    auto select = commandFor(rig, "layer.select", `{"index":1,"mode":"set"}`);
    assert(select.apply() && rig.session.document.primary is rig.layerB,
        "6355 hook fixture: layer.select did not move primary to B");
    assert(pairs.length == 1,
        "6355 layer.select did not call the active-layer hook exactly once");

    pairs.length = 0;
    rig.session.document.selectItem(rig.layerA, SelMode.Set);
    rig.session.document.selectItem(rig.layerB, SelMode.Add);
    rig.session.document.selectItem(rig.layerA, SelMode.Remove);
    assert(rig.session.document.primary is rig.layerB,
        "6355 plane hook floor: the seat-order rig did not leave B primary");
    auto addPlane = commandFor(rig, "imagePlane.add");
    assert(addPlane.apply() && rig.session.document.primary is rig.layerA,
        "6355 plane hook fixture: imagePlane.add did not restore A primary");
    assert(pairs.length == 1,
        "6355 imagePlane.add did not call the active-layer hook exactly once");

    size_t singleCalls;
    auto single = new LiveRegistrationRig;
    *single.session.documentPtr() = Document.bootstrap(makeCube());
    registerFamilies(single, (size_t previous, size_t next) { ++singleCalls; });
    auto initial = single.session.document.primary;
    auto singlePlane = commandFor(single, "imagePlane.add");
    assert(singlePlane.apply(), "6355 single-mesh imagePlane.add refused");
    assert(single.session.document.primary is initial && singleCalls == 0,
        "6355 single-mesh imagePlane.add called the hook without moving primary");
}
