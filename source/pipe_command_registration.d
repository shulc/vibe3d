/// Workplane, action-centre and falloff factories resolve the Session mesh,
/// live View/Mode and ToolHost when each command is created. The ToolHost
/// pointer follows the shared F §6 interface; this family reads only
/// `.session`, which is bound before registration. Value-parameter helpers
/// keep each dynamic row distinct (task 5990; evidence:
/// pipe_command_registration_test).
module pipe_command_registration;

import command : Command;
import commands.actr : ActrPresetCommand;
import commands.falloff : FalloffPresetCommand, FalloffAddCommand,
                          FalloffRemoveCommand, FalloffClearCommand,
                          FalloffAutoSizeCommand, FalloffReverseCommand;
import commands.tool.host : ToolHost;
import commands.workplane : WorkplaneResetCommand, WorkplaneEditCommand,
                            WorkplaneRotateCommand, WorkplaneOffsetCommand,
                            WorkplaneAlignToSelectionCommand;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : CommandFactory, Registry;

void registerPipeStageCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, ToolHost* host) {
    assert(host !is null, "pipe command registration requires a ToolHost");

    // workplane.* commands target the singleton WorkplaneStage.
    reg.commandFactories["workplane.reset"] = () => cast(Command)
        new WorkplaneResetCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["workplane.edit"] = () => cast(Command)
        new WorkplaneEditCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["workplane.rotate"] = () => cast(Command)
        new WorkplaneRotateCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["workplane.offset"] = () => cast(Command)
        new WorkplaneOffsetCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["workplane.alignToSelection"] = () => cast(Command)
        new WorkplaneAlignToSelectionCommand(
            &owner.activeMesh(), live.view(), live.mode);

    // actr.<mode> presets update ACEN and AXIS atomically.
    static struct Preset { string name; string acen; string axis; }
    immutable Preset[] presets = [
        Preset("auto",       "auto",       "auto"),
        Preset("select",     "select",     "select"),
        Preset("selectauto", "selectauto", "selectauto"),
        Preset("element",    "element",    "element"),
        Preset("local",      "local",      "local"),
        Preset("origin",     "origin",     "world"),
        Preset("screen",     "screen",     "screen"),
        Preset("border",     "border",     "select"),
        Preset("none",       "none",       "none"),
        Preset("pivot",      "pivot",      "pivot"),
        Preset("parent",     "parent",     "parent"),
    ];
    CommandFactory makeFactory(string nm, string a, string x) {
        return () => cast(Command)
            new ActrPresetCommand(&owner.activeMesh(), live.view(), live.mode,
                                  nm, a, x);
    }
    foreach (p; presets) {
        reg.commandFactories["actr." ~ p.name] =
            makeFactory(p.name, p.acen, p.axis);
    }

    // falloff.<type> updates the primary WGHT stage; the remaining verbs
    // manage stacked falloffs and the form actions.
    CommandFactory makeFalloffFactory(string ty) {
        return () => cast(Command)
            new FalloffPresetCommand(&owner.activeMesh(), live.view(),
                                     live.mode, *host, ty);
    }
    static immutable string[] falloffTypes =
        ["linear", "radial", "cylinder", "screen", "lasso", "vertexMap"];
    foreach (ty; falloffTypes)
        reg.commandFactories["falloff." ~ ty] = makeFalloffFactory(ty);

    reg.commandFactories["falloff.add"] = () => cast(Command)
        new FalloffAddCommand(
            &owner.activeMesh(), live.view(), live.mode, *host);
    reg.commandFactories["falloff.remove"] = () => cast(Command)
        new FalloffRemoveCommand(
            &owner.activeMesh(), live.view(), live.mode, *host);
    reg.commandFactories["falloff.clear"] = () => cast(Command)
        new FalloffClearCommand(
            &owner.activeMesh(), live.view(), live.mode, *host);
    reg.commandFactories["falloff.autosize"] = () => cast(Command)
        new FalloffAutoSizeCommand(
            &owner.activeMesh(), live.view(), live.mode, *host);
    reg.commandFactories["falloff.reverse"] = () => cast(Command)
        new FalloffReverseCommand(
            &owner.activeMesh(), live.view(), live.mode, *host);
}
