module vibe3d.apps.desktop.selection_command_registration;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.editing.commands.editor.commands.select.between : SelectBetween;
import vibe3d.editing.commands.editor.commands.select.boundary : SelectBoundary;
import vibe3d.editing.commands.editor.commands.select.by_stat : SelectByStatEdge, SelectByStatPolygon,
    SelectByStatVertex;
import vibe3d.editing.commands.editor.commands.select.by_tag : SelectByTag;
import vibe3d.editing.commands.editor.commands.select.connect : SelectConnect;
import vibe3d.editing.commands.editor.commands.select.contract : SelectionContract;
import vibe3d.editing.commands.editor.commands.select.convert : SelectConvertCommand;
import vibe3d.editing.commands.runtime.commands.select.drop : SelectDropCommand;
import vibe3d.editing.commands.runtime.commands.select.element : SelectElementCommand;
import vibe3d.editing.commands.editor.commands.select.expand : SelectionExpand;
import vibe3d.editing.commands.editor.commands.select.fill : SelectFillHoles, SelectFillInsideLoop;
import vibe3d.editing.commands.runtime.commands.select.invert : SelectInvert;
import vibe3d.editing.commands.editor.commands.select.less : SelectLess;
import vibe3d.editing.commands.editor.commands.select.loop : SelectLoop;
import vibe3d.editing.commands.editor.commands.select.more : SelectMore;
import vibe3d.editing.commands.editor.commands.select.ring : SelectRing;
import vibe3d.editing.commands.editor.commands.select.sets : SelectSetApply, SelectSetDelete, SelectSetEdit,
    SelectSetRename, SelectSetStore;
import vibe3d.editing.commands.editor.commands.select.type_from : SelectTypeFromCommand;
import vibe3d.editing.contracts.editmode : EditMode;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.editing.tools.interactive.registry : Registry;
import vibe3d.mesh.core.mesh : Mesh;
import vibe3d.viewport.camera.view : View;
import vibe3d.runtime.application_core.pilot_command_registration : PilotCommandDeps, registerElementSelectionCommand,
    registerDropSelectionCommand, registerInvertSelectionCommand;

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
    PilotCommandDeps deps;
    ref Mesh liveMesh() { return owner.activeMesh(); }
    ref View liveView() { return live.view(); }
    deps.activeMesh = &liveMesh;
    deps.view = &liveView;
    deps.mode = live.modeCell();
    deps.promoteGeometryType = doors.promoteGeometry_;
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
    registerInvertSelectionCommand(reg, deps);
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
    registerDropSelectionCommand(reg, deps);
    registerElementSelectionCommand(reg, deps);
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
