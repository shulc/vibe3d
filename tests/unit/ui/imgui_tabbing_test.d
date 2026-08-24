// The PREMISE behind task 1850, verified by ACTION rather than by quoting the
// dependency's source: a Tab key event that reaches ImGui moves the keyboard
// focus, and it does so whether or not `NavEnableKeyboard` is set — the flag
// only decides WHICH widgets the walk is allowed to stop on.
//
// Both halves are load-bearing for the fix that ships:
//
//   * If Tab did not move focus at all, there would be nothing to suppress and
//     the task would close as a non-bug.
//   * If dropping `ImGuiConfigFlags.NavEnableKeyboard` (source/app.d, ImGui
//     init) had stopped the walk, the one-line config change would have been
//     the right fix and the per-event gate would be over-engineering. It does
//     not: tabbing is gated on `ConfigNavEnableTabbing`, a context field the
//     binding does not expose, and imgui's own comment at that site says the
//     tabbing request is ALWAYS ENABLED whatever the keyboard-nav config flag
//     is set to (imgui.cpp:14869; the gate itself is `!g.ConfigNavEnableTabbing`
//     at imgui.cpp:14861).
//   * And the SECOND block is what killed the first draft of the fix, which
//     forwarded Tab to ImGui whenever `io.WantTextInput` was true (so that Tab
//     could still walk between text fields). With the flag set — which is how
//     the editor runs — the walk stops on EVERY item, not only inputable ones
//     (imgui.cpp:14203-14208). So one Tab out of a focused text field lands on
//     a button or a checkbox, `WantTextInput` goes false, and the NEXT Tab
//     would have been suppressed from ImGui while the app's own
//     `io.WantTextInput` gate no longer swallowed it — i.e. it would have
//     reached the subpatch toggle mid-navigation. The carve-out was dropped
//     because of what this block measures.
//
// No window, no GL context and no display server: `ui/headless_panel.d` gives a
// real ImGui context an input queue directly, exactly as the SDL2 backend fills
// it. The one process-global here is the ImGui context itself, hence the
// mandatory `scope (exit) ui.close();` in every block.
module tests.unit.ui.imgui_tabbing_test;

import ImGui = d_imgui;
import d_imgui.imgui_h;
import tests.unit.ui.headless_panel : HeadlessPanel, openPanel;

// The same cimgui entry point `headless_panel.d` declares for its own use: the
// input QUEUE has no D wrapper in the shim because the SDL2 backend normally
// fills it. Re-declared here rather than widening the harness, which task 1850
// touches only to make `keyDown`/`keyUp` callable.
private extern (C) nothrow @nogc void ImGuiIO_AddInputCharacter(void* self, uint c);

private enum int KEY_TAB = cast(int) ImGuiKey.Tab;   // 512, == ImGuiKey_Tab

/// One Button followed by one InputText. The ORDER is the whole point: a
/// fixture with only a text field reads identically in both configurations,
/// because the walk has exactly one place it can stop either way. With a
/// non-inputable widget in front of it, the two configurations disagree about
/// where a single Tab lands — which is the difference being measured.
private struct TabProbe {
    char[64] buf = '\0';
    bool     clicked;

    void submit() {
        if (ImGui.Button("Go")) clicked = true;
        ImGui.InputText("##field", buf[]);
    }
}

unittest {
    // П1 — WITHOUT NavEnableKeyboard. The walk visits inputable items only, so
    // Tab skips the button and activates the text field. That it happens AT
    // ALL with the flag off is the fact that rules out "just drop the flag".
    TabProbe probe;
    auto ui = openPanel(() { probe.submit(); }, "Tab probe (no nav flag)");
    scope (exit) ui.close();

    ui.frame();
    assert(!ImGui.IsAnyItemActive(),
           "premise setup: nothing may be active before Tab is sent");

    ui.keyDown(KEY_TAB);
    ui.frame();
    ui.frame();
    ui.keyUp(KEY_TAB);
    ui.frame();

    assert(ImGui.IsAnyItemActive(),
           "Tab must have moved focus into the text field: with the "
           ~ "NavEnableKeyboard flag OFF the walk still runs and still stops "
           ~ "on inputable items, so removing that flag is NOT a fix");

    // …and prove WHICH item took it, not merely that something did: a
    // character typed now must land in the field's own buffer.
    ImGuiIO_AddInputCharacter(cast(void*) &ImGui.GetIO(), cast(uint) 'X');
    ui.frame();
    assert(probe.buf[0] == 'X',
           "the item Tab activated must be the InputText — a typed character "
           ~ "did not reach its buffer");
    assert(!probe.clicked,
           "with the nav flag OFF the walk must SKIP the non-inputable button");
}

unittest {
    // П2 — WITH NavEnableKeyboard, i.e. the configuration the editor actually
    // runs (source/app.d sets it at ImGui init). Same fixture, DIFFERENT
    // itinerary: the walk may now stop on any item, so the single Tab parks on
    // the button instead of reaching the field.
    //
    // Read positively, not as an absence: after the Tab, the nav-activate key
    // fires the button. A block that only asserted "the field is not active"
    // would also pass if Tab had done nothing whatsoever.
    TabProbe probe;
    auto ui = openPanel(() { probe.submit(); }, "Tab probe (nav flag on)");
    scope (exit) ui.close();

    ImGui.GetIO().ConfigFlags |= ImGuiConfigFlags.NavEnableKeyboard;

    ui.frame();
    ui.keyDown(KEY_TAB);
    ui.frame();
    ui.frame();
    ui.keyUp(KEY_TAB);
    ui.frame();

    ImGuiIO_AddInputCharacter(cast(void*) &ImGui.GetIO(), cast(uint) 'X');
    ui.frame();
    assert(probe.buf[0] == '\0',
           "the text field must NOT have taken the focus in this "
           ~ "configuration — a typed character reached its buffer");

    ui.keyDown(cast(int) ImGuiKey.Space);
    ui.frame();
    ui.keyUp(cast(int) ImGuiKey.Space);
    ui.frame();

    assert(probe.clicked,
           "with NavEnableKeyboard the Tab walk stops on EVERY item, so one "
           ~ "Tab must have parked the focus on the non-inputable button "
           ~ "(imgui.cpp:14203-14208) — this is why a WantTextInput carve-out "
           ~ "could not have held: one Tab leaves the text field");
}
