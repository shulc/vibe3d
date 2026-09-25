module tests.unit.held_gesture_buttons_test;

// Slice M1a (doc/tool_session_model_plan_2026-09-24.md, R4.4): no key is
// dispatched while any mouse button is held. The set itself (u1, u2), and the
// router's ORDER (u3), which no scenario log can witness: the viewport swallow
// gate is off under --test, so a release it would have eaten never is there.

import std.algorithm.searching : canFind, startsWith;
import std.file : readText;
import std.string : indexOf, strip;
import held_gesture_buttons : HeldGestureButtons, g_heldGestureButtons;
import tests.unit.census_symbols : blankNonCode;

unittest { // u1: per-button release — the set empties only when every button is up
    HeldGestureButtons h;
    assert(!h.any, "M1a u1: a fresh set holds a button");
    h.press(1);                                   // LMB
    h.press(2);                                   // MMB
    assert(h.any && h.bits == 0b011, "M1a u1: LMB+MMB did not set bits 0 and 1");
    h.release(2);
    assert(h.any && h.bits == 0b001, "M1a u1: MMB up did not leave exactly LMB held");
    h.release(1);
    assert(!h.any && h.bits == 0, "M1a u1: LMB up did not clear its bit");
    h.press(3);                                   // RMB: any button counts
    assert(h.any && h.bits == 0b100, "M1a u1: RMB did not set bit 2");
    h.press(5);
    h.clear();
    assert(!h.any, "M1a u1: clear left a button held");
}

unittest { // u2: button numbers outside 1..5 neither lock nor unlock
    HeldGestureButtons h;
    h.press(7);
    h.press(0);
    assert(!h.any, "M1a u2: button 7 or 0 set a bit");
    h.press(1);
    h.release(7);
    h.release(0);
    assert(h.bits == 0b001, "M1a u2: releasing button 7 or 0 cleared LMB");
}

/// `{ ... }` body of the first declaration introduced by `marker`.
private string bodyAt(string code, string marker) {
    const at = code.indexOf(marker);
    assert(at >= 0, "M1a census: marker moved: " ~ marker);
    size_t i = cast(size_t) at;
    while (i < code.length && code[i] != '{') ++i;
    assert(i < code.length, "M1a census: no body after " ~ marker);
    const begin = i;
    size_t depth;
    for (; i < code.length; ++i) {
        if (code[i] == '{') ++depth;
        else if (code[i] == '}' && --depth == 0) return code[begin .. i + 1];
    }
    assert(false, "M1a census: unbalanced body after " ~ marker);
}

/// Offset of `needle` in `hay`, asserting it is there exactly once.
private size_t once(string hay, string needle, string where) {
    const a = hay.indexOf(needle);
    assert(a >= 0, "M1a census: " ~ where ~ " lost `" ~ needle ~ "`");
    assert(hay[a + needle.length .. $].indexOf(needle) < 0,
           "M1a census: " ~ where ~ " has `" ~ needle ~ "` twice");
    return cast(size_t) a;
}

/// The body's statements after its opening brace, `version (web)` line skipped.
private string firstStatement(string body_) {
    auto rest = body_[1 .. $].strip;
    if (rest.startsWith("version (web)")) {
        const semi = rest.indexOf(';');
        rest = rest[semi + 1 .. $].strip;
    }
    return rest;
}

unittest { // u3: the router's order and its gates, read from production text
    // Deliberately a SOURCE-TEXT check: under --test the viewport swallow gate
    // is bypassed (`!app.testMode`), so no scenario log can witness that the
    // release clears its bit above it. This cell is the only witness of X1.
    auto code = blankNonCode(readText("source/input_router.d"));

    // The release clears its bit ABOVE everything that may swallow it.
    auto pe = bodyAt(code, "bool processEvent(");
    const rel = once(pe, "held_.release(ev.button.button)", "processEvent");
    assert(pe.canFind("if (ev.type == SDL_MOUSEBUTTONUP) held_.release(ev.button.button);"),
           "M1a u3: the release is not keyed on SDL_MOUSEBUTTONUP alone");
    foreach (later; ["if (g_pie.swallowRemainder)", "if (g_pie.open)", "feedImGui(ev)",
                     "viewportInputAllowed()", "handleMouseButtonUp(ev.button);"])
        assert(pe.indexOf(later) >= 0 && rel < cast(size_t) pe.indexOf(later),
               "M1a u3: `held_.release(` is not above `" ~ later ~ "` in processEvent");
    // ... and nowhere else: the old place, below the gates, is the defect.
    assert(once(code, "held_.release(", "input_router.d") == code.indexOf("held_.release("),
           "M1a u3: a second release site");

    // The press sets its bit for the press the router delivers.
    const press = once(pe, "held_.press(ev.button.button);", "processEvent");
    const down = once(pe, "handleMouseButtonDown(ev.button);", "processEvent");
    assert(press < down
           && pe[press + "held_.press(ev.button.button);".length .. down].strip.length == 0,
           "M1a u3: the press bit is not set right before handleMouseButtonDown");

    // Both key handlers START with the gate: above Escape and onKeyDown/Up.
    foreach (h; ["void handleKeyDown(", "void handleKeyUp("])
        assert(firstStatement(bodyAt(code, h)).startsWith("if (held_.any) return;"),
               "M1a u3: " ~ h ~ " does not start with the held-button gate");

    // Focus loss clears the whole set.
    assert(bodyAt(code, "void handleWindowEvent(")
               .canFind("if (we.event == SDL_WINDOWEVENT_FOCUS_LOST) held_.clear();"),
           "M1a u3: focus loss does not clear the held buttons");
    assert(code.canFind("alias held_ = g_heldGestureButtons;"),
           "M1a u3: the router's held set is not the one the automation reset clears");
}

unittest { // u4: the automation reset clears the SAME set, wired in production
    auto adapter = blankNonCode(readText("source/http_command_adapter.d"));
    auto app = blankNonCode(readText("source/app.d"));
    auto mod = blankNonCode(readText("source/held_gesture_buttons.d"));
    assert(bodyAt(adapter, "void resetAutomationAfter(")
               .canFind("automation_.clearHeldGestureButtons();"),
           "M1a u4: resetAutomationAfter stopped clearing the held gesture buttons");
    assert(app.canFind("&clearHeldGestureButtonsForAutomation"),
           "M1a u4: app.d no longer wires the held-button clear into the automation reset");
    assert(bodyAt(mod, "void clearHeldGestureButtonsForAutomation(")
               .canFind("g_heldGestureButtons.clear();"),
           "M1a u4: the automation hook does not clear the router's set");
}

unittest { // u5: the history chokepoint refuses while a button is held
    // Every non-key door (panel Undo/Redo, History rows) reaches the same
    // EditSession.navigate as the keyboard; a left click on the panel during
    // a middle-button drag must not cancel the live edit under the drag.
    import command_history : CommandHistory;
    import command : Command;
    import edit_session : EditSession;
    import tool : Tool;
    final class LiveEditTool : Tool {
        size_t cancels;
        override bool hasUncommittedEdit() const { return cancels == 0; }
        override void cancelUncommittedEdit() { ++cancels; }
    }
    // One undone record, so a redo that reaches the history has a step to
    // take (slice M4: the redo positive control reads the history, the
    // former SessionLiveRedo stand-in left with the interface).
    final class RedoCmd : Command {
        import editmode : EditMode;
        import view : View;
        size_t* redos;
        View view_;
        this(size_t* r) {
            view_ = new View(0, 0, 1, 1);
            super(null, view_, EditMode.Vertices);
            redos = r;
        }
        protected override bool applyImpl() { ++*redos; noteUndoRecorded(); return true; }
        protected override void revertImpl() {}
    }
    size_t redoCount;
    auto history = new CommandHistory();
    {
        auto c = new RedoCmd(&redoCount);
        assert(c.apply());
        history.record(c);
        assert(history.undo(), "M1a u5 rig: the seeded record did not undo");
        redoCount = 0;
    }
    auto live = new LiveEditTool();
    Tool held = live;
    auto es = new EditSession(() => held, history, () {});
    scope (exit) g_heldGestureButtons.clear();

    g_heldGestureButtons.clear();
    g_heldGestureButtons.press(2);                // middle button held
    assert(g_heldGestureButtons.any, "M1a u5 floor: the middle button did not register");
    assert(!es.navigate(true) && live.cancels == 0,
           "M1a u5: navigate(undo) cancelled the live edit while a button was held");
    assert(!es.navigate(false) && redoCount == 0,
           "M1a u5: navigate(redo) acted while a button was held");
    g_heldGestureButtons.release(2);
    assert(es.navigate(false) && redoCount == 1,
           "M1a u5 positive control: navigate(redo) after the release did not reach the history");
    assert(es.navigate(true) && live.cancels == 1,
           "M1a u5 positive control: navigate(undo) after the release did not cancel the edit");

    // The doors: the panel rows and the keyboard all reach this navigate.
    auto app = blankNonCode(readText("source/app.d"));
    assert(bodyAt(app, "bool navHistory(bool isUndo)").canFind("session.navigate(isUndo)"),
           "M1a u5: app.d navHistory no longer ends at EditSession.navigate");
    auto menu = readText("source/ui/action_menu.d");   // string literals matter here
    assert(menu.canFind(`if (id == "history.undo") { nav_(true); return; }`)
           && menu.canFind(`if (id == "history.redo") { nav_(false); return; }`),
           "M1a u5: the panel Undo/Redo rows no longer route through the navigator");
    auto es_ = blankNonCode(readText("source/edit_session.d"));
    assert(bodyAt(es_, "bool navigate(bool isUndo)").strip[1 .. $].strip
               .startsWith("if (g_heldGestureButtons.any) return false;"),
           "M1a u5: navigate does not start with the held-button refusal");
}
