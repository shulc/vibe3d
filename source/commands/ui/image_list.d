module commands.ui.image_list;

import std.string : strip, toLower;

import command;
import mesh;
import view;
import editmode;

// ---------------------------------------------------------------------------
// g_imageListShown — test-mode visibility flag for the Images window
// (task 0616 Ph4).
//
// In a normal (non-test) run the Images window is always rendered; this flag
// is ignored. In --test mode the window is HIDDEN by default and only
// rendered when this flag is set true, so that synthetic mouse drags over the
// viewport are not captured by a panel whose position varies between parallel
// workers.
//
// This mirrors g_layerListShown (commands.ui.layer_list) exactly, and for a
// reason that is not cosmetic: shipping a SECOND floating window that draws
// unconditionally in --test would put a new obstacle in front of every
// existing viewport-drag test, and the failures would look like drag
// regressions rather than like a new panel. Every floating panel in this
// codebase carries this opt-in for that reason.
//
// __gshared so the render loop (app.d) and the command apply (background HTTP
// thread) read/write the same flag.
// ---------------------------------------------------------------------------
__gshared bool g_imageListShown = false;

// ---------------------------------------------------------------------------
// UiImageListCommand — `ui.imageList <show|hide>`
//
// Test-only. Flips g_imageListShown, which the Images panel render guard in
// app.d reads while in --test mode. Gated behind g_testMode (set by --test),
// so it is inert and rejects itself in a normal build/run — the panel is
// unconditionally visible there and this command has no purpose.
//
// Wire format: one positional arg, "show" or "hide".
// ---------------------------------------------------------------------------
class UiImageListCommand : Command {
    private bool show_ = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.imageList"; }
    override string label() const { return "Show/Hide Images (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    // Positional arg: "show" | "hide".
    void setVisible(string arg) {
        auto a = arg.strip.toLower;
        switch (a) {
            case "show": show_ = true;  break;
            case "hide": show_ = false; break;
            default:
                throw new Exception(
                    "ui.imageList: expected 'show' or 'hide', got '"
                    ~ arg ~ "'");
        }
    }

    protected override bool applyImpl() {
        if (!g_testMode)
            throw new Exception(
                "ui.imageList: only available in --test mode");
        g_imageListShown = show_;
        return true;
    }
}
