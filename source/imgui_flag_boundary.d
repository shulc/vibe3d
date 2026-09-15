/// One ABI boundary for the UI flags Vibe3D passes to the linked library.
/// Task 5930; the accessors are compiled from that package's own C header, and
/// tests/unit/imgui_flag_boundary_census_test.d closes the consumer surface.
module imgui_flag_boundary;

import ImGui = d_imgui;

private extern(C) nothrow @nogc {
    int vibe3d_imgui_popup_any();
    int vibe3d_imgui_popup_context_window_over_empty_space();
    int vibe3d_imgui_popup_context_item();
    int vibe3d_imgui_input_text_enter_returns_true();
    bool igIsPopupOpen_Str(const(char)* strId, int flags);
}

bool beginPanelContextMenu(string id) {
    return ImGui.BeginPopupContextWindow(
        id, vibe3d_imgui_popup_context_window_over_empty_space());
}

bool beginItemContextMenu(string id) {
    return ImGui.BeginPopupContextItem(
        id, vibe3d_imgui_popup_context_item());
}

bool anyPopupOpen() nothrow @nogc {
    return igIsPopupOpen_Str(null, vibe3d_imgui_popup_any());
}

bool inputTextSubmitOnEnter(string label, char[] buffer) {
    return ImGui.InputText(
        label, buffer, vibe3d_imgui_input_text_enter_returns_true());
}
