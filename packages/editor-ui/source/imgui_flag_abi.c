#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"

/* Task 5930: compile the used integer flags from the linked package's own
 * header. D consumes only int accessors: importing this C module directly
 * breaks the full link, and crossing mirrored struct layouts is unsupported. */
int vibe3d_imgui_popup_any(void) { return ImGuiPopupFlags_AnyPopup; }
int vibe3d_imgui_popup_context_window_over_empty_space(void) { return ImGuiPopupFlags_MouseButtonRight | ImGuiPopupFlags_NoOpenOverItems; }
int vibe3d_imgui_popup_context_item(void) { return ImGuiPopupFlags_MouseButtonRight; }
int vibe3d_imgui_input_text_enter_returns_true(void) { return ImGuiInputTextFlags_EnterReturnsTrue; }
