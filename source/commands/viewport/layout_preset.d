module commands.viewport.layout_preset;

import command;
import commands.viewport.command_base : ViewportCommand;
import mesh;
import editmode;
import view;
import viewport : ViewportManager;
import params : Param, wireArgs;

/// `viewport.layout <preset>` — switch layout (Single/SplitH/SplitV/Quad).
/// APPLICATION-WIDE, not per-cell — unlike displayStyle/wireOverlay/
/// wireAlpha below. Registered as a command (task 0761).
final class ViewportLayoutPreset : ViewportCommand {
    private string preset_ = "";

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.layout"; }

    override Param[] params() {
        return wireArgs(
            Param.string_("preset", "Preset", &preset_, "")
        );
    }

    void setPreset(string preset) { preset_ = preset; }

    protected override bool applyImpl() {
        import viewport : LayoutPreset;
        import prefs    : g_prefs;

        LayoutPreset lp = LayoutPreset.Single;
        switch (preset_) {
            case "SplitH": lp = LayoutPreset.SplitH; break;
            case "SplitV": lp = LayoutPreset.SplitV; break;
            case "Quad":   lp = LayoutPreset.Quad;   break;
            default:       lp = LayoutPreset.Single;  break;
        }
        vpm.applyLayout(lp);
        // Mirrors the recentFiles/lastDir/toolDefaults precedent: just
        // update g_prefs in-memory here, no per-command file write — it
        // flushes to disk once at clean shutdown (persistPrefsOnExit, gated
        // on prefsActive). Harmless no-op in --test (never saved).
        g_prefs.viewportLayout = lp;
        return true;
    }
}
