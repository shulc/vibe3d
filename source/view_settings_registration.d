module view_settings_registration;

import command : Command;
import commands.constrain.toggle : ConstrainToggleCommand;
import commands.path.define : PathDefineCommand;
import commands.prefs.coord_rounding : CoordRoundingCommand;
import commands.prefs.trackball : TrackballPrefCommand;
import commands.snap.mode : SnapModeCommand;
import commands.snap.toggle : SnapToggleCommand;
import commands.snap.toggle_type : SnapToggleTypeCommand;
import commands.symmetry.toggle : SymmetryToggleCommand;
import live_registration_roles : LiveSessionRole, LiveViewModeRole;
import registry : Registry;

/// Registers the snap/constrain/preferences/path/symmetry command family.
/// Task 6354: inputs stay live at factory invocation without a broad app capture.
void registerViewSettingsCommands(ref Registry reg, LiveSessionRole owner,
                                  LiveViewModeRole live) {
    reg.commandFactories["snap.toggle"] = () => cast(Command)
        new SnapToggleCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["constrain.toggle"] = () => cast(Command)
        new ConstrainToggleCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["snap.toggleType"] = () => cast(Command)
        new SnapToggleTypeCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["snap.mode"] = () => cast(Command)
        new SnapModeCommand(&owner.activeMesh(), live.view(), live.mode);
    // Coordinate rounding is the step used to round a gizmo drag's scalar.
    reg.commandFactories["pref.coordRounding"] = () => cast(Command)
        new CoordRoundingCommand(&owner.activeMesh(), live.view(), live.mode);
    // Trackball navigation (task 0573) writes the active cell's camera, so
    // the live View is resolved when the factory fires rather than here.
    reg.commandFactories["pref.trackball"] = () => cast(Command)
        new TrackballPrefCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["path.define"] = () => cast(Command)
        new PathDefineCommand(&owner.activeMesh(), live.view(), live.mode);
    reg.commandFactories["symmetry.toggle"] = () => cast(Command)
        new SymmetryToggleCommand(&owner.activeMesh(), live.view(), live.mode);
}
