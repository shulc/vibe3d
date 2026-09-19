/// Workplane, action-centre and falloff factories resolve the Session mesh,
/// live View/Mode and read ToolHostReadView at command creation, like the
/// lifecycle family. Value-parameter helpers keep each dynamic row distinct
/// (tasks 5990, 6350; evidence:
/// pipe_command_registration_test).
module pipe_command_registration;

import command : Command;
import commands.actr : ActrPresetCommand;
import commands.falloff : FalloffPresetCommand, FalloffAddCommand,
                          FalloffRemoveCommand, FalloffClearCommand,
                          FalloffAutoSizeCommand, FalloffReverseCommand;
import commands.tool.host : ToolHostReadView;
import commands.workplane : WorkplaneResetCommand, WorkplaneEditCommand,
                            WorkplaneRotateCommand, WorkplaneOffsetCommand,
                            WorkplaneAlignToSelectionCommand;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : CommandFactory, Registry;

void registerPipeStageCommands(ref Registry reg, LiveSessionRole owner,
        LiveViewModeRole live, ToolHostReadView host) {

    // workplane.* commands target the singleton WorkplaneStage.
    reg.registerCommand("workplane.reset", () => cast(Command)
        new WorkplaneResetCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("workplane.edit", () => cast(Command)
        new WorkplaneEditCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("workplane.rotate", () => cast(Command)
        new WorkplaneRotateCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("workplane.offset", () => cast(Command)
        new WorkplaneOffsetCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("workplane.alignToSelection", () => cast(Command)
        new WorkplaneAlignToSelectionCommand(
            &owner.activeMesh(), live.view(), live.mode));

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
        reg.registerCommand("actr." ~ p.name, makeFactory(p.name, p.acen, p.axis));
    }

    // falloff.<type> updates the primary WGHT stage; the remaining verbs
    // manage stacked falloffs and the form actions.
    CommandFactory makeFalloffFactory(string ty) {
        return () => cast(Command)
            new FalloffPresetCommand(&owner.activeMesh(), live.view(),
                                     live.mode, host.read(), ty);
    }
    static immutable string[] falloffTypes =
        ["linear", "radial", "cylinder", "screen", "lasso", "vertexMap"];
    foreach (ty; falloffTypes)
        reg.registerCommand("falloff." ~ ty, makeFalloffFactory(ty));

    reg.registerCommand("falloff.add", () => cast(Command)
        new FalloffAddCommand(
            &owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("falloff.remove", () => cast(Command)
        new FalloffRemoveCommand(
            &owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("falloff.clear", () => cast(Command)
        new FalloffClearCommand(
            &owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("falloff.autosize", () => cast(Command)
        new FalloffAutoSizeCommand(
            &owner.activeMesh(), live.view(), live.mode, host.read()));
    reg.registerCommand("falloff.reverse", () => cast(Command)
        new FalloffReverseCommand(
            &owner.activeMesh(), live.view(), live.mode, host.read()));
}
