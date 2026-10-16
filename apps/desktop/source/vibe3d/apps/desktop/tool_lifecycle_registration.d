module vibe3d.apps.desktop.tool_lifecycle_registration;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.editing.tools.interactive.commands.tool.attr : ToolAttrCommand;
import vibe3d.editing.tools.interactive.commands.tool.begin_session : ToolBeginSessionCommand,
    ToolClearSoftPinForTestCommand;
import vibe3d.editing.tools.interactive.commands.tool.do_apply : ToolDoApplyCommand;
import vibe3d.editing.tools.interactive.commands.tool.host : ToolHostReadView;
import vibe3d.editing.tools.interactive.commands.tool.panel_edit : ToolPanelEditCommand;
import vibe3d.editing.tools.interactive.commands.tool.pipe : ToolPipeAttrCommand;
import vibe3d.editing.tools.interactive.commands.tool.reset : ToolResetCommand;
import vibe3d.editing.tools.interactive.commands.tool.set : ToolReleaseCommand, ToolSetCommand;
import vibe3d.apps.desktop.commands.ui.about : UiAboutCommand;
import vibe3d.apps.desktop.commands.ui.channels : UiChannelsCommand;
import vibe3d.apps.desktop.commands.ui.image_list : UiImageListCommand;
import vibe3d.apps.desktop.commands.ui.layer_list : UiLayerListCommand;
import vibe3d.apps.desktop.commands.ui.pie : UiPieCommand;
import vibe3d.apps.desktop.commands.ui.statistics : UiStatisticsCommand, UiStatisticsExpandCommand;
import vibe3d.apps.desktop.commands.ui.tool_properties : UiToolPropertiesCommand;
import vibe3d.apps.desktop.commands.ui.viewport_props : UiViewportPropsCommand;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.editing.tools.interactive.registry : Registry;

/// Tool-lifecycle factories resolve primary/View/Mode and read ToolHostReadView
/// when each command is created; resetActiveTool is bound after registration
/// (tasks 5980, 6350; evidence:
/// tool_lifecycle_registration_test).
void registerToolLifecycleCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, ToolHostReadView host) {

    reg.registerCommand("tool.set", () => cast(Command)
        new ToolSetCommand(&owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("tool.release", () => cast(Command)
        new ToolReleaseCommand(&owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("tool.attr", () => cast(Command)
        new ToolAttrCommand(&owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("tool.doApply", () => cast(Command)
        new ToolDoApplyCommand(&owner.activeMesh(), live.view(), live.mode, host.read(), owner.document()));
    reg.registerCommand("tool.reset", () => cast(Command)
        new ToolResetCommand(&owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("tool.pipe.attr", () => cast(Command)
        new ToolPipeAttrCommand(&owner.activeMesh(), live.view(), live.mode, host.read()));
    // Test-only hooks reject themselves unless the process is in test mode.
    reg.registerCommand("tool.beginSession", () => cast(Command)
        new ToolBeginSessionCommand(&owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("tool.clearSoftPinForTest", () => cast(Command)
        new ToolClearSoftPinForTestCommand(&owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("tool.panelEdit", () => cast(Command)
        new ToolPanelEditCommand(&owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("ui.toolProperties", () => cast(Command)
        new UiToolPropertiesCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("ui.layerList", () => cast(Command)
        new UiLayerListCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("ui.imageList", () => cast(Command)
        new UiImageListCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("ui.channels", () => cast(Command)
        new UiChannelsCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("ui.statistics", () => cast(Command)
        new UiStatisticsCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("ui.statistics.expand", () => cast(Command)
        new UiStatisticsExpandCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("ui.viewportProps", () => cast(Command)
        new UiViewportPropsCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("ui.about", () => cast(Command)
        new UiAboutCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("ui.pie", () => cast(Command)
        new UiPieCommand(&owner.activeMesh(), live.view(), live.mode));
}
