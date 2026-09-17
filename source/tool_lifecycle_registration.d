module tool_lifecycle_registration;

import command : Command;
import commands.tool.attr : ToolAttrCommand;
import commands.tool.begin_session : ToolBeginSessionCommand,
    ToolClearSoftPinForTestCommand;
import commands.tool.do_apply : ToolDoApplyCommand;
import commands.tool.host : ToolHostReadView;
import commands.tool.panel_edit : ToolPanelEditCommand;
import commands.tool.pipe : ToolPipeAttrCommand;
import commands.tool.reset : ToolResetCommand;
import commands.tool.set : ToolReleaseCommand, ToolSetCommand;
import commands.ui.about : UiAboutCommand;
import commands.ui.channels : UiChannelsCommand;
import commands.ui.image_list : UiImageListCommand;
import commands.ui.layer_list : UiLayerListCommand;
import commands.ui.pie : UiPieCommand;
import commands.ui.statistics : UiStatisticsCommand, UiStatisticsExpandCommand;
import commands.ui.tool_properties : UiToolPropertiesCommand;
import commands.ui.viewport_props : UiViewportPropsCommand;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;

/// Tool-lifecycle factories resolve primary/View/Mode and read ToolHostReadView
/// when each command is created; resetActiveTool is bound after registration
/// (tasks 5980, 6350; evidence:
/// tool_lifecycle_registration_test).
void registerToolLifecycleCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, ToolHostReadView host) {

    reg.commandFactories["tool.set"] = () => cast(Command)
        new ToolSetCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    reg.commandFactories["tool.release"] = () => cast(Command)
        new ToolReleaseCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    reg.commandFactories["tool.attr"] = () => cast(Command)
        new ToolAttrCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    reg.commandFactories["tool.doApply"] = () => cast(Command)
        new ToolDoApplyCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    reg.commandFactories["tool.reset"] = () => cast(Command)
        new ToolResetCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    reg.commandFactories["tool.pipe.attr"] = () => cast(Command)
        new ToolPipeAttrCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    // Test-only hooks reject themselves unless the process is in test mode.
    reg.commandFactories["tool.beginSession"] = () => cast(Command)
        new ToolBeginSessionCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    reg.commandFactories["tool.clearSoftPinForTest"] = () => cast(Command)
        new ToolClearSoftPinForTestCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    reg.commandFactories["tool.panelEdit"] = () => cast(Command)
        new ToolPanelEditCommand(&owner.activeMesh(), live.view(), live.mode, host.read());
    reg.commandFactories["ui.toolProperties"] = () => cast(Command)
        new UiToolPropertiesCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["ui.layerList"] = () => cast(Command)
        new UiLayerListCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["ui.imageList"] = () => cast(Command)
        new UiImageListCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["ui.channels"] = () => cast(Command)
        new UiChannelsCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["ui.statistics"] = () => cast(Command)
        new UiStatisticsCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["ui.statistics.expand"] = () => cast(Command)
        new UiStatisticsExpandCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["ui.viewportProps"] = () => cast(Command)
        new UiViewportPropsCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["ui.about"] = () => cast(Command)
        new UiAboutCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["ui.pie"] = () => cast(Command)
        new UiPieCommand(&owner.activeMesh(), live.view(), live.mode);
}
