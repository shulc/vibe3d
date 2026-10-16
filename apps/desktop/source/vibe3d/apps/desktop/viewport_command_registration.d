module vibe3d.apps.desktop.viewport_command_registration;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.apps.desktop.commands.viewport.display : ViewportBackdropStyle, ViewportDisplayStyle,
    ViewportPointSize, ViewportRetopology, ViewportRetopologyPreset,
    ViewportShowVertices, ViewportSmooth, ViewportCavity, ViewportCavityParams,
    ViewportCompositeTestGain, ViewportReflectionSource,
    ViewportWireAlpha, ViewportWireOverlay;
import vibe3d.apps.desktop.commands.viewport.fit : Fit;
import vibe3d.apps.desktop.commands.viewport.fit_selected : FitSelected;
import vibe3d.apps.desktop.commands.viewport.grid_steps : ViewportGridSteps;
import vibe3d.apps.desktop.commands.viewport.independence : ViewportIndepAxis, ViewportIndependence;
import vibe3d.apps.desktop.commands.viewport.layout_preset : ViewportLayoutPreset;
import vibe3d.apps.desktop.commands.viewport.master : ViewportMaster;
import vibe3d.apps.desktop.commands.viewport.view_preset : ViewportViewPreset;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.editing.tools.interactive.registry : Registry;
import vibe3d.viewport.host.viewport : ViewportManager;

/// Viewport factories resolve the Session mesh, live View/Mode, and active
/// cell when each command is created; fit writes the active cell's focus/scale
/// owner cameras. The manager is a class reference published once before
/// registration (task 6010; evidence: viewport_command_registration_test).
void registerViewportCommands(ref Registry reg, LiveSessionRole owner,
                              LiveViewModeRole live, ViewportManager vpm) {
    assert(vpm !is null, "viewport registration requires a ViewportManager");
    reg.registerCommand("viewport.fit", () => cast(Command)
        new Fit(&owner.activeMesh(), vpm.focusOwnerCamera(vpm.activeId),
                vpm.scaleOwnerCamera(vpm.activeId), live.mode, owner.document(), vpm.activeCamera()));
    reg.registerCommand("viewport.fit_selected", () => cast(Command)
        new FitSelected(&owner.activeMesh(), vpm.focusOwnerCamera(vpm.activeId),
                        vpm.scaleOwnerCamera(vpm.activeId), live.mode,
                        owner.document(), vpm.activeCamera()));
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
    reg.registerCommand("viewport.backdropStyle", () => cast(Command)
        new ViewportBackdropStyle(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.retopology", () => cast(Command)
        new ViewportRetopology(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.retopologyPreset", () => cast(Command)
        new ViewportRetopologyPreset(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.showVertices", () => cast(Command)
        new ViewportShowVertices(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.pointSize", () => cast(Command)
        new ViewportPointSize(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.smooth", () => cast(Command)
        new ViewportSmooth(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.cavity", () => cast(Command)
        new ViewportCavity(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.cavityParams", () => cast(Command)
        new ViewportCavityParams(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.reflectionSource", () => cast(Command)
        new ViewportReflectionSource(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.compositeTestGain", () => cast(Command)
        new ViewportCompositeTestGain(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.gridSteps", () => cast(Command)
        new ViewportGridSteps(&owner.activeMesh(), live.view(), live.mode, vpm));
    reg.registerCommand("viewport.master", () => cast(Command)
        new ViewportMaster(&owner.activeMesh(), live.view(), live.mode, vpm));
}
