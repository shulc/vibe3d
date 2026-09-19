module selection_command_registration;

import command : Command;
import commands.select.between : SelectBetween;
import commands.select.boundary : SelectBoundary;
import commands.select.by_stat : SelectByStatEdge, SelectByStatPolygon,
    SelectByStatVertex;
import commands.select.by_tag : SelectByTag;
import commands.select.connect : SelectConnect;
import commands.select.contract : SelectionContract;
import commands.select.convert : SelectConvertCommand;
import commands.select.drop : SelectDropCommand;
import commands.select.element : SelectElementCommand;
import commands.select.expand : SelectionExpand;
import commands.select.fill : SelectFillHoles, SelectFillInsideLoop;
import commands.select.invert : SelectInvert;
import commands.select.less : SelectLess;
import commands.select.loop : SelectLoop;
import commands.select.more : SelectMore;
import commands.select.ring : SelectRing;
import commands.select.sets : SelectSetApply, SelectSetDelete, SelectSetEdit,
    SelectSetRename, SelectSetStore;
import commands.select.type_from : SelectTypeFromCommand;
import editmode : EditMode;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;

/// The stable EditMode cell and three selection-type doors reached by this
/// family. The promotion door does not drop the active tool; Model commands
/// lose it earlier in the executor. Deliberate type switches drop on a front flip.
/// These inputs are assigned once before registration (task 6000; evidence:
/// selection_command_registration_test).
struct SelectionTypeDoors {
private:
    EditMode*               editMode_;
    void delegate(EditMode) promoteGeometry_;
    void delegate(EditMode) switchGeometry_;
    void delegate()         switchItem_;

public:
    @disable this();

    this(EditMode* editMode, void delegate(EditMode) promoteGeometry,
         void delegate(EditMode) switchGeometry, void delegate() switchItem) {
        assert(editMode !is null && promoteGeometry !is null
            && switchGeometry !is null && switchItem !is null,
            "selection registration requires the mode cell and all three type doors");
        editMode_ = editMode;
        promoteGeometry_ = promoteGeometry;
        switchGeometry_ = switchGeometry;
        switchItem_ = switchItem;
    }
}

/// Selection factories resolve primary, View and mode when each command is
/// created.
void registerSelectionCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, SelectionTypeDoors doors) {
    reg.registerCommand("select.expand", () => cast(Command)
        new SelectionExpand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.contract", () => cast(Command)
        new SelectionContract(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.more", () => cast(Command)
        new SelectMore(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.less", () => cast(Command)
        new SelectLess(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.loop", () => cast(Command)
        new SelectLoop(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.ring", () => cast(Command)
        new SelectRing(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.invert", () => cast(Command)
        new SelectInvert(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.connect", () => cast(Command)
        new SelectConnect(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.between", () => cast(Command)
        new SelectBetween(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.fill.holes", () => cast(Command)
        new SelectFillHoles(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.fill.insideLoop", () => cast(Command)
        (new SelectFillInsideLoop(&owner.activeMesh(), live.view(), live.mode,
                                  doors.editMode_))
            .setPromoteHook(doors.promoteGeometry_));
    reg.registerCommand("select.boundary", () => cast(Command)
        (new SelectBoundary(&owner.activeMesh(), live.view(), live.mode,
                            doors.editMode_))
            .setPromoteHook(doors.promoteGeometry_));
    reg.registerCommand("select.typeFrom", () => cast(Command)
        (new SelectTypeFromCommand(&owner.activeMesh(), live.view(), live.mode,
                                   doors.editMode_, doors.switchGeometry_))
            .setItemHook(doors.switchItem_));
    reg.registerCommand("select.vertex", () => cast(Command)
        (new SelectTypeFromCommand(&owner.activeMesh(), live.view(), live.mode,
                                   doors.editMode_, "vertex",
                                   doors.switchGeometry_))
            .setItemHook(doors.switchItem_));
    reg.registerCommand("select.edge", () => cast(Command)
        (new SelectTypeFromCommand(&owner.activeMesh(), live.view(), live.mode,
                                   doors.editMode_, "edge",
                                   doors.switchGeometry_))
            .setItemHook(doors.switchItem_));
    reg.registerCommand("select.polygon", () => cast(Command)
        (new SelectTypeFromCommand(&owner.activeMesh(), live.view(), live.mode,
                                   doors.editMode_, "polygon",
                                   doors.switchGeometry_))
            .setItemHook(doors.switchItem_));
    reg.registerCommand("select.item", () => cast(Command)
        (new SelectTypeFromCommand(&owner.activeMesh(), live.view(), live.mode,
                                   doors.editMode_, "item",
                                   doors.switchGeometry_))
            .setItemHook(doors.switchItem_));
    reg.registerCommand("select.byTag", () => cast(Command)
        new SelectByTag(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.byStat.vertex", () => cast(Command)
        (new SelectByStatVertex(&owner.activeMesh(), live.view(), live.mode,
                                doors.editMode_))
            .setPromoteHook(doors.promoteGeometry_));
    reg.registerCommand("select.byStat.edge", () => cast(Command)
        (new SelectByStatEdge(&owner.activeMesh(), live.view(), live.mode,
                              doors.editMode_))
            .setPromoteHook(doors.promoteGeometry_));
    reg.registerCommand("select.byStat.polygon", () => cast(Command)
        (new SelectByStatPolygon(&owner.activeMesh(), live.view(), live.mode,
                                 doors.editMode_))
            .setPromoteHook(doors.promoteGeometry_));
    reg.registerCommand("select.drop", () => cast(Command)
        new SelectDropCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.element", () => cast(Command)
        new SelectElementCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.convert", () => cast(Command)
        (new SelectConvertCommand(&owner.activeMesh(), live.view(), live.mode,
                                  doors.editMode_))
            .setPromoteHook(doors.promoteGeometry_));
    // select.set.apply is the one multi-layer row: it walks foreground
    // layers through the whole Document; the other four stay primary-only.
    reg.registerCommand("select.set.store", () => cast(Command)
        new SelectSetStore(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.set.edit", () => cast(Command)
        new SelectSetEdit(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.set.apply", () => cast(Command)
        new SelectSetApply(&owner.activeMesh(), live.view(), live.mode,
                           owner.document()));
    reg.registerCommand("select.set.rename", () => cast(Command)
        new SelectSetRename(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("select.set.delete", () => cast(Command)
        new SelectSetDelete(&owner.activeMesh(), live.view(), live.mode));
}
