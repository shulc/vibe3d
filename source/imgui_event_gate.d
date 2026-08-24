/// The single door from SDL's event queue into ImGui's SDL2 backend, and the
/// one rule that door enforces (task 1850).
///
/// THE RULE, in one sentence: a `SDL_KEYDOWN` for `SDLK_TAB` is handed to ImGui
/// only when ImGui would NOT turn it into a keyboard-focus move — that is, only
/// with Ctrl or Alt held; every other Tab press stops here and belongs to the
/// editor alone, while `SDL_KEYUP` is ALWAYS handed over.
///
/// WHY. Tab is the editor's subpatch toggle. ImGui's focus walk consumes it too,
/// so one press did two things at once: it toggled the subpatch flag AND crept
/// the keyboard focus one widget along inside whatever panel had nav focus.
/// The owner asked for the second half to go away.
///
/// WHY NOT A CONFIG FLAG. `ImGuiConfigFlags.NavEnableKeyboard` is not the
/// switch: imgui's comment at its own compute site says the tabbing request is
/// ALWAYS ENABLED whatever that flag is set to, and the flag only widens WHICH
/// widgets the walk may stop on. The real switch is a context field the binding
/// does not expose. Measured rather than taken on trust:
/// `tests/unit/ui/imgui_tabbing_test.d` drives a headless ImGui context with
/// the flag both ways and watches Tab move the focus in both.
///
/// WHY THE CTRL/ALT CARVE-OUT IS EXACTLY THE RIGHT SIZE. ImGui's tabbing
/// request is raised only when neither Ctrl nor Alt is down; with Ctrl held the
/// very same key is a DIFFERENT consumer — the docked-window switcher, which is
/// live here because docking is enabled. So this predicate suppresses precisely
/// the presses that would move the focus and nothing else: Ctrl+Tab keeps
/// switching windows exactly as it does today.
///
/// WHY THERE IS NO `WantTextInput` CARVE-OUT, although "let Tab through while a
/// text field is being edited, so it can walk to the next field" is the obvious
/// refinement. It reopens the reported bug one keypress later. With
/// `NavEnableKeyboard` the walk stops on EVERY item, not only inputable ones, so
/// the first Tab out of a focused field parks on the button or checkbox next to
/// it and `io.WantTextInput` goes false; the SECOND Tab would then be suppressed
/// from ImGui while the `io.WantTextInput` gate below (`keyBelongsToEditor`,
/// consulted from the same dispatcher) no longer swallowed it
/// — and it would reach the subpatch toggle while the user is navigating a
/// panel. Nothing is lost in the typing case: that gate (which sits BELOW this
/// door and does not depend on it) already keeps every key away from the editor
/// while a field is being edited, so Tab inside a text field is simply inert —
/// and that gate is `keyBelongsToEditor` at the bottom of this module, tabled
/// alongside this rule.
///
/// WHY `SDL_KEYUP` IS UNCONDITIONAL. A gate that suppressed the release too
/// would leave ImGui believing Tab is still held; `IsKeyPressed(Tab, …Repeat…)`
/// would then keep firing and the focus would walk on its own, with no user
/// touching the keyboard. Forwarding a release ImGui never saw a press for is
/// free — ImGui filters a key event that does not change the key's state.
///
/// ONE SIDE EFFECT, RECORDED SO IT IS NOT REDISCOVERED THE HARD WAY: the SDL2
/// backend refreshes `io.KeyCtrl` / `KeyShift` / `KeyAlt` from `keysym.mod`
/// inside the same branch that handles the key itself, so a suppressed Tab press
/// also skips that refresh. Harmless in practice — every modifier press and
/// release carries its own event, and the Tab release is always forwarded — but
/// a session whose first event after regaining focus is a bare Tab sees ImGui's
/// modifier state one event stale.
module imgui_event_gate;

import bindbc.sdl;
import imgui_impl_sdl2 : ImGui_ImplSDL2_ProcessEvent;

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
