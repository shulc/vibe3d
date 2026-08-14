module commands.ui.about;

import std.string : strip, toLower;

import command;
import mesh;
import view;
import editmode;

// ---------------------------------------------------------------------------
// g_aboutShown — visibility flag for the About window (task 0641).
//
// Unlike g_channelsShown / g_layerListShown, this one is honoured in EVERY
// mode, not just --test: About is an on-demand window (opened from File →
// About), so "hidden until asked for" is its normal behaviour rather than a
// test-determinism concession. That it also starts hidden under --test — and so
// can never swallow a synthetic viewport drag — falls out for free.
//
// __gshared so the render loop (app.d) and the command apply (which may run on
// the background HTTP thread) read and write the same flag.
// ---------------------------------------------------------------------------
__gshared bool g_aboutShown = false;

// ---------------------------------------------------------------------------
// UiAboutCommand — `ui.about <show|hide|toggle>`
//
// Flips g_aboutShown. NOT test-gated: this is the real UI action behind the
// File → About… item, and tests drive the same command the menu does.
//
// Wire format: one positional arg, "show" | "hide" | "toggle". Absent argument
// means "show" (what the menu item wants).
// ---------------------------------------------------------------------------
class UiAboutCommand : Command {
    private enum Mode { show, hide, toggle }
    private Mode mode_ = Mode.show;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.about"; }
    override string label() const { return "About vibe3d"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    // Positional arg: "show" | "hide" | "toggle".
    void setVisible(string arg) {
        auto a = arg.strip.toLower;
        switch (a) {
            case "show":   mode_ = Mode.show;   break;
            case "hide":   mode_ = Mode.hide;   break;
            case "toggle": mode_ = Mode.toggle; break;
            default:
                throw new Exception(
                    "ui.about: expected 'show', 'hide' or 'toggle', got '"
                    ~ arg ~ "'");
        }
    }

    override bool apply() {
        final switch (mode_) {
            case Mode.show:   g_aboutShown = true;            break;
            case Mode.hide:   g_aboutShown = false;           break;
            case Mode.toggle: g_aboutShown = !g_aboutShown;   break;
        }
        return true;
    }
}
