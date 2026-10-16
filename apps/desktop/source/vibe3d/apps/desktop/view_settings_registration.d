module vibe3d.apps.desktop.view_settings_registration;

import vibe3d.editing.commands.runtime.command : Command;
import vibe3d.apps.desktop.commands.constrain.toggle : ConstrainToggleCommand;
import vibe3d.apps.desktop.commands.path.define : PathDefineCommand;
import vibe3d.apps.desktop.commands.prefs.coord_rounding : CoordRoundingCommand;
import vibe3d.apps.desktop.commands.prefs.trackball : TrackballPrefCommand;
import vibe3d.apps.desktop.commands.snap.mode : SnapModeCommand;
import vibe3d.apps.desktop.commands.snap.toggle : SnapToggleCommand;
import vibe3d.apps.desktop.commands.snap.toggle_type : SnapToggleTypeCommand;
import vibe3d.apps.desktop.commands.symmetry.toggle : SymmetryToggleCommand;
import vibe3d.runtime.application_core.live_registration_roles : LiveSessionRole, LiveViewModeRole;
import vibe3d.editing.tools.interactive.registry : Registry;

/// Registers the snap/constrain/preferences/path/symmetry command family.
/// Task 6354: inputs stay live at factory invocation without a broad app capture.
void registerViewSettingsCommands(ref Registry reg, LiveSessionRole owner,
                                  LiveViewModeRole live) {
    reg.registerCommand("snap.toggle", () => cast(Command)
        new SnapToggleCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("constrain.toggle", () => cast(Command)
        new ConstrainToggleCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("snap.toggleType", () => cast(Command)
        new SnapToggleTypeCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("snap.mode", () => cast(Command)
        new SnapModeCommand(&owner.activeMesh(), live.view(), live.mode));
    // The Coordinate Rounding setting lives beside snapping because that
    // is what it is: the step a gizmo drag's scalar is rounded to.
    reg.registerCommand("pref.coordRounding", () => cast(Command)
        new CoordRoundingCommand(&owner.activeMesh(), live.view(), live.mode));
    // Trackball navigation (task 0573) — a viewport-navigation setting, so
    // its `viewport` subject writes THIS factory's camera, which is the
    // active cell's — `live.view()`, resolved at fire time.
    reg.registerCommand("pref.trackball", () => cast(Command)
        new TrackballPrefCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("path.define", () => cast(Command)
        new PathDefineCommand(&owner.activeMesh(), live.view(), live.mode));
    reg.registerCommand("symmetry.toggle", () => cast(Command)
        new SymmetryToggleCommand(&owner.activeMesh(), live.view(), live.mode));
}
