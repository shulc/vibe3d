module commands.ui.channels;

import std.string : strip, toLower;

import command;
import mesh;
import view;
import editmode;

// ---------------------------------------------------------------------------
// g_channelsShown — test-mode visibility flag for the Channels window
// (task 0637).
//
// In a normal (non-test) run the Channels window is always rendered; this flag
// is ignored. In --test mode the window is HIDDEN by default and only rendered
// when this flag is set true, so that synthetic mouse drags over the viewport
// are not captured by a panel whose position varies between parallel workers.
// Tests that genuinely need to drive the panel turn it on via
// `ui.channels show`.
//
// This mirrors g_layerListShown / g_imageListShown exactly — the Channels panel
// is another floating, dockable window and must obey the same imgui-determinism
// rule (no panel may swallow a viewport drag in tests).
//
// __gshared so the render loop (app.d) and the command apply (background HTTP
// thread) read/write the same flag.
// ---------------------------------------------------------------------------
__gshared bool g_channelsShown = false;

// ---------------------------------------------------------------------------
// UiChannelsCommand — `ui.channels <show|hide>`
//
// Test-only. Flips g_channelsShown, which the Channels panel render guard in
// app.d reads while in --test mode. Gated behind g_testMode (set by --test), so
// it is inert and rejects itself in a normal build/run — the panel is
// unconditionally visible there and this command has no purpose.
//
// Wire format: one positional arg, "show" or "hide".
// ---------------------------------------------------------------------------
class UiChannelsCommand : Command {
    private bool show_ = true;

    this(Mesh* mesh, ref View view, EditMode editMode) {
        super(mesh, view, editMode);
    }

    override string name()  const { return "ui.channels"; }
    override string label() const { return "Show/Hide Channels (test)"; }

    override CmdFlags cmdFlags() const { return CmdFlags.SideEffect; }

    // Positional arg: "show" | "hide".
    void setVisible(string arg) {
        auto a = arg.strip.toLower;
        switch (a) {
            case "show": show_ = true;  break;
            case "hide": show_ = false; break;
            default:
                throw new Exception(
                    "ui.channels: expected 'show' or 'hide', got '"
                    ~ arg ~ "'");
        }
    }

    protected override bool applyImpl() {
        if (!g_testMode)
            throw new Exception(
                "ui.channels: only available in --test mode");
        g_channelsShown = show_;
        return true;
    }
}
