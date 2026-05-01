module property_panel;

import tool : Tool;
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
    /// Safe to call when tool is null (draws nothing).
    /// Tools whose `renderParamsAsPanel()` returns false are skipped — those
    /// expose params() purely for the headless tool.attr path and own UI
    /// rendering via their drawProperties() override.
    void draw(Tool tool) {
        if (tool is null) return;
        if (!tool.renderParamsAsPanel()) return;
        foreach (ref p; tool.params()) {
            bool enabled = tool.paramEnabled(p.name);
            if (!enabled) ImGui.BeginDisabled();
            bool changed = drawParamWidget(p);
            if (!enabled) ImGui.EndDisabled();
            if (changed) {
                tool.onParamChanged(p.name);
                tool.evaluate();
            }
        }
    }
}
