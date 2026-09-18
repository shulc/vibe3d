module item_command_registration;

import command : Command;
import commands.image.commands : ImageLoad, ImageReload, ImageRemove, ImageReplace;
import commands.image_plane.commands : ImagePlaneAdd, ImagePlaneSetImage;
import commands.layer.commands : LayerAdd, LayerAttr, LayerDelete, LayerDuplicate,
    LayerParent, LayerRename, LayerReorder, LayerSelect, LayerSetVisible;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;

/// The two application lifecycle doors used by item commands. Both are wired
/// before command registration; a missing delegate is a composition error.
struct ItemLifecycleDoors {
private:
    void delegate(size_t, size_t) onActiveLayerChanged_;
    void delegate() promoteItemType_;

public:
    @disable this();

    this(void delegate(size_t, size_t) onActiveLayerChanged,
         void delegate() promoteItemType) {
        assert(onActiveLayerChanged !is null && promoteItemType !is null,
            "item registration requires the active-layer hook and the item-type door");
        onActiveLayerChanged_ = onActiveLayerChanged;
        promoteItemType_ = promoteItemType;
    }

    void delegate(size_t, size_t) onActiveLayerChanged() {
        return onActiveLayerChanged_;
    }

    void delegate() promoteItemType() {
        return promoteItemType_;
    }
}

/// Registers layer, image and image-plane commands. Mesh, View, mode and
/// Document are resolved when a factory fires (task 6355; evidence:
/// item_command_registration_test).
void registerItemCommands(ref Registry reg, LiveSessionRole owner,
                          LiveViewModeRole live, ItemLifecycleDoors doors) {
    reg.commandFactories["layer.add"] = () => cast(Command)
        new LayerAdd(&owner.activeMesh(), live.view(), live.mode,
                     owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["layer.duplicate"] = () => cast(Command)
        new LayerDuplicate(&owner.activeMesh(), live.view(), live.mode,
                           owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["layer.delete"] = () => cast(Command)
        new LayerDelete(&owner.activeMesh(), live.view(), live.mode,
                        owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["layer.reorder"] = () => cast(Command)
        new LayerReorder(&owner.activeMesh(), live.view(), live.mode,
                         owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["layer.select"] = () => cast(Command)
        (new LayerSelect(&owner.activeMesh(), live.view(), live.mode,
                         owner.document(), doors.onActiveLayerChanged()))
            .setItemSelectHook(doors.promoteItemType());
    reg.commandFactories["layer.rename"] = () => cast(Command)
        new LayerRename(&owner.activeMesh(), live.view(), live.mode,
                        owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["layer.setVisible"] = () => cast(Command)
        new LayerSetVisible(&owner.activeMesh(), live.view(), live.mode,
                            owner.document(), doors.onActiveLayerChanged());
    // A property edit cannot move the edit target; the hook is retained only
    // because the layer command constructors deliberately share one recipe.
    reg.commandFactories["layer.attr"] = () => cast(Command)
        new LayerAttr(&owner.activeMesh(), live.view(), live.mode,
                      owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["layer.parent"] = () => cast(Command)
        new LayerParent(&owner.activeMesh(), live.view(), live.mode,
                        owner.document(), doors.onActiveLayerChanged());

    // Image commands mutate the same Document. ImageRemove composes
    // LayerDelete, so all four retain the active-layer hook even though an
    // image itself can never be the mesh edit target.
    reg.commandFactories["image.load"] = () => cast(Command)
        new ImageLoad(&owner.activeMesh(), live.view(), live.mode,
                      owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["image.replace"] = () => cast(Command)
        new ImageReplace(&owner.activeMesh(), live.view(), live.mode,
                         owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["image.reload"] = () => cast(Command)
        new ImageReload(&owner.activeMesh(), live.view(), live.mode,
                        owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["image.remove"] = () => cast(Command)
        new ImageRemove(&owner.activeMesh(), live.view(), live.mode,
                        owner.document(), doors.onActiveLayerChanged());

    // Task 0668 amended by 0671/6355: imagePlane.add fires the hook only when
    // the primary object changes. A single-mesh document stays on that mesh;
    // the two-mesh seat-order witness is pinned by test_item_switch_hook_effects.
    reg.commandFactories["imagePlane.add"] = () => cast(Command)
        new ImagePlaneAdd(&owner.activeMesh(), live.view(), live.mode,
                          owner.document(), doors.onActiveLayerChanged());
    reg.commandFactories["imagePlane.setImage"] = () => cast(Command)
        new ImagePlaneSetImage(&owner.activeMesh(), live.view(), live.mode,
                               owner.document());
}
