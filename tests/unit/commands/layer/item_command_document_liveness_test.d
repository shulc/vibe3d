module tests.unit.commands.layer.item_command_document_liveness_test;

import command : Command;
import command_args : bindArgs;
import document : Document, ImageData, Layer;
import item_command_registration : ItemLifecycleDoors, registerItemCommands;
import item_kinds : ItemKind;
import mesh : makeCube;
import tests.unit.live_registration_rig : LiveRegistrationRig;

private Command commandFor(LiveRegistrationRig rig, string id,
                           string args = null) {
    auto command = rig.registry.makeCommand(id);
    if (args.length) bindArgs(command, args);
    return command;
}

private void registerItems(LiveRegistrationRig rig) {
    registerItemCommands(rig.registry, rig.liveSession(), rig.liveViewMode(),
        ItemLifecycleDoors((size_t previous, size_t next) {}, () {}));
}

unittest { // C7-isolated: image.remove and imagePlane.add use the live Document
    auto control = new LiveRegistrationRig;
    auto clip = new Layer;
    clip.name = "clip";
    clip.kind = ItemKind.Image;
    clip.imageRef() = new ImageData;
    control.session.document.layers ~= clip;
    registerItems(control);
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
    registerItems(rig);
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
