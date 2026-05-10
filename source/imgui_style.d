module imgui_style;

// ---------------------------------------------------------------------------
// Shared ImGui style helpers — re-skin ImGui's defaults to vibe3d's
// LightWave-style chrome (panel grey + beige hover + flat black border).
// Originally lived as private methods on App; extracted here so non-app
// code (notably toolpipe.stages.* drawProperties() implementations) can
// re-use the SAME visual without each stage hand-rolling the colour /
// padding pushes.
//
// All helpers are Push/Pop pairs — call before BeginPopup / Begin and
// pair after EndPopup / End regardless of whether the inner block ran
// (Push/Pop must balance every frame).
// ---------------------------------------------------------------------------

import ImGui = d_imgui;
import d_imgui.imgui_h;

// Status-bar / Tool Properties popup chrome — grey bg, beige hover,
// flat 1-px black border, generous padding so each MenuItem reads as
// a button row.
void pushPopupStyle() {
    ImVec4 popupBg  = ImVec4(0.561f, 0.561f, 0.561f, 1.0f);  // (143,143,143)
    ImVec4 hov      = ImVec4(0.773f, 0.773f, 0.718f, 1.0f);  // (197,197,183)
    ImVec4 active   = ImVec4(1.0f,   1.0f,   1.0f,   1.0f);
    ImVec4 sep      = ImVec4(0.0f,   0.0f,   0.0f,   1.0f);
    ImVec4 disabled = ImVec4(0.235f, 0.235f, 0.235f, 1.0f);

    ImGui.PushStyleColor(ImGuiCol.PopupBg,       popupBg);
    ImGui.PushStyleColor(ImGuiCol.HeaderHovered, hov);
    ImGui.PushStyleColor(ImGuiCol.Header,        active);
    ImGui.PushStyleColor(ImGuiCol.HeaderActive,  active);
    ImGui.PushStyleColor(ImGuiCol.Separator,     sep);
    ImGui.PushStyleColor(ImGuiCol.TextDisabled,  disabled);

    ImGui.PushStyleVar(ImGuiStyleVar.PopupRounding,   0.0f);
    ImGui.PushStyleVar(ImGuiStyleVar.PopupBorderSize, 1.0f);
    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding,   ImVec2(6, 6));
    ImGui.PushStyleVar(ImGuiStyleVar.ItemSpacing,     ImVec2(0, 8));
    ImGui.PushStyleVar(ImGuiStyleVar.FramePadding,    ImVec2(12, 8));
}

void popPopupStyle() {
    ImGui.PopStyleVar(5);
    ImGui.PopStyleColor(6);
}
