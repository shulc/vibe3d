module viewport_command_registration;

import command : Command;
import commands.viewport.display : ViewportDisplayStyle, ViewportWireAlpha,
    ViewportWireOverlay;
import commands.viewport.fit : Fit;
import commands.viewport.fit_selected : FitSelected;
import commands.viewport.grid_steps : ViewportGridSteps;
import commands.viewport.independence : ViewportIndepAxis, ViewportIndependence;
import commands.viewport.layout_preset : ViewportLayoutPreset;
import commands.viewport.master : ViewportMaster;
import commands.viewport.view_preset : ViewportViewPreset;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;
import viewport : ViewportManager;

/// Viewport factories resolve the Session mesh, live View/Mode, and active
/// cell when each command is created; fit writes the active cell's focus/scale
/// owner cameras. The manager is a class reference published once before
/// registration (task 6010; evidence: viewport_command_registration_test).
void registerViewportCommands(ref Registry reg, LiveSessionRole owner,
                              LiveViewModeRole live, ViewportManager vpm) {
    assert(vpm !is null, "viewport registration requires a ViewportManager");
    reg.registerCommand("viewport.fit", () => cast(Command)
        new Fit(&owner.activeMesh(), vpm.focusOwnerCamera(vpm.activeId),
                vpm.scaleOwnerCamera(vpm.activeId), live.mode, owner.document()));
    reg.registerCommand("viewport.fit_selected", () => cast(Command)
        new FitSelected(&owner.activeMesh(), vpm.focusOwnerCamera(vpm.activeId),
                        vpm.scaleOwnerCamera(vpm.activeId), live.mode,
                        owner.document()));
    reg.registerCommand("viewport.view", () => cast(Command)
        new ViewportViewPreset(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.layout", () => cast(Command)
        new ViewportLayoutPreset(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.indCenter", () => cast(Command)
        new ViewportIndependence(&owner.activeMesh(), live.view(), live.mode, vpm,
                                 ViewportIndepAxis.Center));
    reg.registerCommand("viewport.indScale", () => cast(Command)
        new ViewportIndependence(&owner.activeMesh(), live.view(), live.mode, vpm,
                                 ViewportIndepAxis.Scale));
    reg.registerCommand("viewport.indRotate", () => cast(Command)
        new ViewportIndependence(&owner.activeMesh(), live.view(), live.mode, vpm,
                                 ViewportIndepAxis.Rotate));
    reg.registerCommand("viewport.displayStyle", () => cast(Command)
        new ViewportDisplayStyle(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.wireOverlay", () => cast(Command)
        new ViewportWireOverlay(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.wireAlpha", () => cast(Command)
        new ViewportWireAlpha(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.gridSteps", () => cast(Command)
        new ViewportGridSteps(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.master", () => cast(Command)
        new ViewportMaster(&owner.activeMesh(), live.view(), live.mode, vpm));
}
