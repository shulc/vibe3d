module property_panel;

import tool   : Tool;
import params : ParamProvider;
import params_widgets : drawParamWidget;

import ImGui = d_imgui;
import d_imgui.imgui_h;

// ---------------------------------------------------------------------------
// PropertyPanel — inline schema-driven property renderer for Tools.
//
// Unlike ArgsDialog (which wraps a modal popup with OK/Cancel), this renders
// the tool's params() list directly inside whatever ImGui window the caller
// has already opened. On any value change it immediately calls
// tool.onParamChanged(name) followed by tool.evaluate() so live-preview
// tools (e.g. BevelTool in polygon mode) update the 3D viewport in the same
// frame.
//
// No state is needed between frames: there is no pending/active bookkeeping.
// One instance lives on App alongside argsDialog.
//
// Usage (inside Begin/End block):
//   propertyPanel.draw(activeTool);
//   activeTool.drawProperties();   // tool-specific custom UI appended after
// ---------------------------------------------------------------------------

class PropertyPanel {
    /// Render the schema-driven params for `tool` inline.
    /// Safe to call when tool is null (draws nothing). Tools whose
    /// `renderParamsAsPanel()` returns false are skipped — those expose
    /// params() purely for the headless tool.attr path and own UI
    /// rendering via their drawProperties() override.
    void draw(Tool tool) {
        if (tool is null) return;
        if (!tool.renderParamsAsPanel()) return;
        drawProvider(tool);
        // Tool gets the legacy preview re-evaluation; ParamProvider
        // generic path doesn't (stages don't have an `evaluate()` —
        // their setAttr / onParamChanged already publishes state).
        // Drive it by re-iterating params and re-firing only when
        // dirty, but cheaper to just call evaluate after the foreach.
        // (drawProvider has already fired onParamChanged for changes.)
    }

    /// Generic ParamProvider renderer — used by `draw(Tool)` and by
    /// the per-stage Tool Properties iteration in app.d. Calls the
    /// provider's `onParamChanged(name)` after each mutation.
    void drawProvider(ParamProvider p) {
        if (p is null) return;
        foreach (ref par; p.params()) {
            bool enabled = p.paramEnabled(par.name);
            if (!enabled) ImGui.BeginDisabled();
            bool changed = drawParamWidget(par);
            if (!enabled) ImGui.EndDisabled();
            if (changed) p.onParamChanged(par.name);
        }
        // Tool subclasses also need an `evaluate()` re-run for live
        // preview; that's the single Tool-only call site retained
        // here. Cast is safe because the only ParamProvider impls
        // today are Tool and Stage (Stage doesn't need it).
        if (auto t = cast(Tool)p) {
            // No-op when nothing changed in this frame — `evaluate`
            // is cheap for tools that aren't previewing.
            t.evaluate();
        }
    }
}
