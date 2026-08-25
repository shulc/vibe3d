module commands.prefs.trackball;

import command;
import mesh;
import view;
import editmode;

import trackball : TrackballOption, parseTrackballOption,
                   setTrackballGlobal, setTrackballGlobalOverride,
                   setTrackballMouseSpeed, setTrackballTabletSpeed,
                   clampTrackballSpeed, setTrackballSwing;

// ---------------------------------------------------------------------------
// `pref.trackball <subject> <value>` — the trackball navigation setting.
//
// This is a USER SETTING with a persisted value, not a test hook. It exists as
// a command for the same reason the coordinate-rounding one does: the menu, the
// keyboard and the HTTP bridge all want one entry point, and routing it through
// a command is how this editor spells "a setting the user can change".
//
// Wire format (from argstring), two positionals:
//   pref.trackball global   <on|off>       the app-wide setting
//   pref.trackball override <on|off>       make every cell read the global
//   pref.trackball viewport <on|off|default>   THIS cell's override
//   pref.trackball speed    <number>       the mouse speed multiplier
//   pref.trackball tabletSpeed <number>    the tablet multiplier (stored only)
//   pref.trackball swing <on|off>      settling spin (off) vs swing (on)
//
// One command with a subject positional rather than a family of sibling
// commands: the values are one feature with one persistence block and one
// reset, and splitting them buys nothing but registration sites to keep in
// sync.
//
// An unrecognised subject or value is an ERROR, not a silent fallback. Landing
// on "off" by accident looks exactly like the gesture was never ported, which
// is the single most expensive way for this to fail.
// ---------------------------------------------------------------------------
class TrackballPrefCommand : Command {
    private string subject_;
    private string value_;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "pref.trackball"; }
    override string label() const { return "Set Trackball Navigation"; }

    // A preference change is UI/session state, not a mesh edit.
    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    void setSubject(string s) { subject_ = s; }
    void setValue(string v)   { value_   = v; }

    protected override bool applyImpl() {
        if (subject_.length == 0)
            throw new Exception("pref.trackball: subject required "
                ~ "(global|override|viewport|speed|tabletSpeed|swing)");
        if (value_.length == 0)
            throw new Exception("pref.trackball: value required for subject '"
                ~ subject_ ~ "'");

        switch (subject_) {
            case "global":
                setTrackballGlobal(parseOnOff());
                return true;
            case "override":
                setTrackballGlobalOverride(parseOnOff());
                return true;
            case "viewport":
                TrackballOption o;
                if (!parseTrackballOption(value_, o))
                    throw new Exception("pref.trackball viewport: unknown value '"
                        ~ value_ ~ "' (want on|off|default)");
                view.trackballOption = o;
                return true;
            case "speed":
                setTrackballMouseSpeed(parseSpeed());
                return true;
            case "tabletSpeed":
                setTrackballTabletSpeed(parseSpeed());
                return true;
            case "swing":
                // Which curve a release arms. NOT "spin on/off": the spin is
                // armed whenever the gesture is, and this chooses between the
                // four-second coast and the endless 1.6-second oscillation.
                setTrackballSwing(parseOnOff());
                return true;
            default:
                throw new Exception("pref.trackball: unknown subject '"
                    ~ subject_
                    ~ "' (want global|override|viewport|speed|tabletSpeed|swing)");
        }
    }

    private bool parseOnOff() {
        if (value_ == "on"  || value_ == "true"  || value_ == "1") return true;
        if (value_ == "off" || value_ == "false" || value_ == "0") return false;
        throw new Exception("pref.trackball " ~ subject_ ~ ": unknown value '"
            ~ value_ ~ "' (want on|off)");
    }

    private float parseSpeed() {
        import std.conv : to, ConvException;
        float v;
        try {
            v = value_.to!float;
        } catch (ConvException) {
            throw new Exception("pref.trackball " ~ subject_
                ~ ": '" ~ value_ ~ "' is not a number");
        }
        // The clamp lives in the setter; calling it here too makes the REJECTED
        // input visible as an error instead of silently becoming the default.
        import std.math : isFinite;
        if (!isFinite(v))
            throw new Exception("pref.trackball " ~ subject_
                ~ ": speed must be finite");
        return clampTrackballSpeed(v);
    }
}
