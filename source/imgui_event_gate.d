/// Owns the SDL-to-ImGui key gates: bare Tab presses stay editor-side while
/// releases and Ctrl/Alt chords reach ImGui; focused text fields retain key
/// events; the popup query exposes the previous rendered frame to the Esc
/// ladder. Tasks 1850/5911; tests/unit/imgui_event_gate_test.d.
module imgui_event_gate;

import bindbc.sdl;
import d_imgui.imgui_cimgui : igGetIO_Nil;
import imgui_impl_sdl2 : ImGui_ImplSDL2_ProcessEvent;
import imgui_flag_boundary : anyPopupOpen;

// The linked cimgui archive exports this stock ImGuiIO method even though the
// curated D wrapper does not declare it. Test automation must start from a
// released keyboard just as a newly focused editor does (task 6208).
extern(C) nothrow @nogc void ImGuiIO_ClearInputKeys(void* self);

void clearImGuiInputKeysForAutomation() nothrow @nogc
{
    ImGuiIO_ClearInputKeys(igGetIO_Nil());
}

/// Requires a current ImGui context and a between-frames call (after Render,
/// before NewFrame); it reads the popup stack retained from the last frame.
/// Task 5911; imgui_event_gate_test.d group H.
bool imguiPopupOpen() nothrow @nogc {
    return anyPopupOpen();
}

bool escapeReachesEditor(bool popupOpen) pure nothrow @nogc {
    return !popupOpen;
}

/// Should this SDL event be handed to ImGui's SDL2 backend?
///
/// Pure and free of ImGui state on purpose: the whole rule is a property of the
/// event, so it is decidable in a unit test with no context, no window and no
/// GL — `tests/unit/imgui_event_gate_test.d` is the table. Modifiers are read
/// only on the press: on a release `keysym.mod` depends on which half of the
/// chord the user let go of first, which would make the predicate asymmetric
/// inside one press/release pair — hence the unconditional release above.
bool goesToImGui(const(SDL_Event)* ev) pure nothrow @nogc
{
    if (ev.type != SDL_KEYDOWN)        return true;
    if (ev.key.keysym.sym != SDLK_TAB) return true;
    // Ctrl+Tab / Alt+Tab are not focus moves — ImGui itself excludes them from
    // the tabbing request — so they still belong to ImGui.
    return (ev.key.keysym.mod & (KMOD_CTRL | KMOD_ALT)) != 0;
}

/// Hand one SDL event to ImGui, subject to the rule above. THE ONLY CALLER of
/// the SDL2 backend's event entry point in the whole tree; a unittest in
/// `tests/unit/imgui_event_gate_test.d` scans `source/` and fails if a second
/// one appears, because every assertion about the rule stays green when the
/// call is simply made somewhere else.
///
/// Returns what the backend returned, or `false` for an event the rule held
/// back — no caller reads it today, and "ImGui did not consume it" is the
/// truthful answer for an event ImGui never saw.
bool feedImGui(const(SDL_Event)* ev) nothrow @nogc
{
    if (!goesToImGui(ev)) return false;
    return ImGui_ImplSDL2_ProcessEvent(ev);
}

/// May this event go on to the EDITOR's own key dispatch, or does a focused
/// text field own it? `false` ⇒ the caller must swallow the event.
///
/// This is the OTHER half of the shipped contract, and the fix above promoted
/// it: with the bare Tab press now held back from ImGui, the focus can no
/// longer leave a text field by itself, so this predicate is the ONLY thing
/// standing between a Tab pressed mid-typing and `mesh.setSubpatch`. Before the
/// fix it was not: one Tab moved the focus off the field, `WantTextInput` went
/// false, and the SECOND Tab walked straight past it into the subpatch toggle
/// (measured — see the task file, П3). It is factored out here, rather than
/// left inline in `app.d`, exactly because that promotion made it load-bearing
/// and nothing in either lane could see it.
///
/// The rule is deliberately narrow and byte-identical to the inline gate it
/// replaces: ONLY `SDL_KEYDOWN` / `SDL_KEYUP` are withheld, and only while
/// `io.WantTextInput` is set. `SDL_TEXTINPUT` keeps flowing (the app records it
/// and the field consumes it through ImGui), and no mouse or window event is
/// ever swallowed — a focused filter box must not freeze the camera or eat the
/// window's close button.
///
/// `wantTextInput` is passed IN rather than read here so the predicate stays
/// pure and context-free: `tests/unit/imgui_event_gate_test.d` tables it with
/// no ImGui context, no window and no GL.
bool keyBelongsToEditor(uint evType, bool wantTextInput) pure nothrow @nogc
{
    if (!wantTextInput) return true;
    return evType != SDL_KEYDOWN && evType != SDL_KEYUP;
}
