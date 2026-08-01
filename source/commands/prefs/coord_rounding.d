module commands.prefs.coord_rounding;

import command;
import mesh;
import view;
import editmode;

import coord_rounding : CoordinateRounding, parseCoordRounding,
                        setCoordRounding, coordRounding, coordRoundingName;

// ---------------------------------------------------------------------------
// `pref.coordRounding <none|normal|fine|fixed|forcedFixed>` — select the
// Coordinate Rounding law that a gizmo axis drag rounds its scalar to.
//
// This is a USER SETTING with a menu entry (the snapping popover) and a
// persisted value, not a test hook. It exists as a command for the same
// reason `snap.mode` does: the popover, the keyboard and the HTTP bridge all
// want one entry point, and routing it through a command is how this editor
// spells "a setting the user can change".
//
// Wire format (from argstring):
//   positional[0] = mode name — the wire names in `coord_rounding.d`.
//
// An unrecognized name is an ERROR, not a silent fallback: landing on `none`
// by accident switches the rounding off and looks exactly like the term was
// never ported.
// ---------------------------------------------------------------------------
class CoordRoundingCommand : Command {
    private string modeName_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "pref.coordRounding"; }
    override string label() const { return "Set Coordinate Rounding"; }

    // A preference change is UI/session state, not a mesh edit.
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    void setModeName(string n) { modeName_ = n; }

    override bool apply() {
        if (modeName_.length == 0)
            throw new Exception("pref.coordRounding: mode name required "
                ~ "(none|normal|fine|fixed|forcedFixed)");
        CoordinateRounding m;
        if (!parseCoordRounding(modeName_, m))
            throw new Exception("pref.coordRounding: unknown mode '"
                ~ modeName_ ~ "' (want none|normal|fine|fixed|forcedFixed)");
        setCoordRounding(m);
        return true;
    }

    override bool revert() { return false; }
}
