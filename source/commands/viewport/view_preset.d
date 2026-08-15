module commands.viewport.view_preset;

import command;
import commands.viewport.command_base : ViewportCommand;
import mesh;
import editmode;
import view;
import viewport : ViewportManager;

/// `viewport.view <preset>` — camera-only preset switch (task 0215),
/// registered as a command (task 0761; previously intercepted ahead of the
/// registry — see `doc/tasks/done/0761-*`). Sets the ACTIVE viewport's
/// projection kind and axis preset. Axis presets (Top/Bottom/Front/Back/
/// Right/Left) → `ProjKind.Ortho`; Perspective/Camera → `ProjKind.Perspective`.
///
/// Argument: a single string, in whichever spelling the caller used — bare
/// JSON string body, first `_positional` entry, or a named `preset` key.
/// Extraction is `http_providers.d`'s `oneStringArg` (task 0720), called by
/// the registry-side injector before `apply()` — this class only stores the
/// already-extracted string.
final class ViewportViewPreset : ViewportCommand {
    private string preset_ = "";

    this(Mesh* mesh, ref View view, EditMode editMode, ViewportManager vpm) {
        super(mesh, view, editMode, vpm);
    }

    override string name() const { return "viewport.view"; }

    void setPreset(string preset) { preset_ = preset; }

    override bool apply() {
        import view     : ProjKind, ViewPreset;
        import viewport : applyCellViewPreset;

        // projKind is derived from the preset by the shared helper
        // (Perspective/Camera → Perspective, every axis preset → Ortho) —
        // same mapping the original interception hardcoded per-case.
        ViewPreset vp3preset = ViewPreset.Perspective;
        switch (preset_) {
            case "Top":         vp3preset = ViewPreset.Top;         break;
            case "Bottom":      vp3preset = ViewPreset.Bottom;      break;
            case "Front":       vp3preset = ViewPreset.Front;       break;
            case "Back":        vp3preset = ViewPreset.Back;        break;
            case "Right":       vp3preset = ViewPreset.Right;       break;
            case "Left":        vp3preset = ViewPreset.Left;        break;
            case "Camera":      vp3preset = ViewPreset.Camera;      break;
            default:            vp3preset = ViewPreset.Perspective; break;
        }
        // Hardwired to the ACTIVE cell (viewport.view does not do
        // ?viewport=N resolution — that's the separate camera-set handler
        // registered via setCameraSetHandler; adding it here would be scope
        // creep for task 0215, exactly as the original interception noted).
        applyCellViewPreset(vpm.views[vpm.activeId], vp3preset);
        return true;
    }
}
