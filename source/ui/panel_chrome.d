module ui.panel_chrome;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import input_zones : publishZone;

// The editor's panel chrome: grey bg, black border, beige/blue button
// palette, black text, flat frames. Call BEFORE `ImGui.Begin` and pair with
// popPanelChromeStyle() AFTER `ImGui.End`.
void pushPanelChromeStyle() {
    ImVec4 winBg   = ImVec4(0.561f, 0.561f, 0.561f, 1.0f);   // (143,143,143)
    ImVec4 border  = ImVec4(0.0f,   0.0f,   0.0f,   1.0f);
    ImVec4 btnBg   = ImVec4(0.710f, 0.710f, 0.655f, 1.0f);   // tool beige
    ImVec4 btnHov  = ImVec4(0.773f, 0.773f, 0.718f, 1.0f);
    ImVec4 btnAct  = ImVec4(1.0f,   1.0f,   1.0f,   1.0f);
    ImVec4 black   = ImVec4(0.0f,   0.0f,   0.0f,   1.0f);
    ImVec4 grabLo  = ImVec4(0.45f,  0.45f,  0.45f,  1.0f);
    ImVec4 grabHi  = ImVec4(0.20f,  0.20f,  0.20f,  1.0f);

    ImGui.PushStyleColor(ImGuiCol.WindowBg,         winBg);
    ImGui.PushStyleColor(ImGuiCol.Border,           border);
    ImGui.PushStyleColor(ImGuiCol.TitleBg,          winBg);
    ImGui.PushStyleColor(ImGuiCol.TitleBgActive,    winBg);
    ImGui.PushStyleColor(ImGuiCol.TitleBgCollapsed, winBg);
    ImGui.PushStyleColor(ImGuiCol.Text,             black);
    ImGui.PushStyleColor(ImGuiCol.Button,           btnBg);
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered,    btnHov);
    ImGui.PushStyleColor(ImGuiCol.ButtonActive,     btnAct);
    ImGui.PushStyleColor(ImGuiCol.FrameBg,          btnBg);
    ImGui.PushStyleColor(ImGuiCol.FrameBgHovered,   btnHov);
    ImGui.PushStyleColor(ImGuiCol.FrameBgActive,    btnAct);
    ImGui.PushStyleColor(ImGuiCol.SliderGrab,       grabLo);
    ImGui.PushStyleColor(ImGuiCol.SliderGrabActive, grabHi);
    ImGui.PushStyleColor(ImGuiCol.CheckMark,        black);
    // Dropdown / combo popups open INSIDE this chrome inherit its black Text,
    // but PopupBg defaults to the dark StyleColorsDark value → black-on-dark,
    // unreadable. Match PopupBg to the field background (btnBg) so an open
    // combo reads the same as its closed state. Only popup WINDOWS use
    // PopupBg, so CollapsingHeader section styling is unaffected.
    ImGui.PushStyleColor(ImGuiCol.PopupBg,          btnBg);

    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding,    ImVec2(3, 3));
    ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 1.0f);
    ImGui.PushStyleVar(ImGuiStyleVar.FrameRounding,    0.0f);
}

void popPanelChromeStyle() {
    ImGui.PopStyleVar(3);
    ImGui.PopStyleColor(16);
}

// Task 1810 — publish this panel's screen rectangle so the keyboard router can
// name the zone the cursor is in. Called right after a successful `Begin`,
// where ImGui's cursor sits at the content origin and `GetContentRegionAvail`
// is the content extent. Those two are what this binding exposes; it has no
// `GetWindowPos`/`GetWindowSize`, and no `IsWindowHovered` to ask instead —
// see source/input_zones.d for why that shapes the whole design.
//
// The rect is the CONTENT box, not the window frame: title bar and padding are
// chrome the user does not aim a chord at.
void publishPanelZone(string name) {
    auto o = ImGui.GetCursorScreenPos();
    auto a = ImGui.GetContentRegionAvail();
    publishZone(name, o.x, o.y, a.x, a.y);
}
