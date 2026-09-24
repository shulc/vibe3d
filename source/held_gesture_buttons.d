module held_gesture_buttons;

// The input rule "no key dispatches while a mouse button is held": the
// router's set of held buttons. ONE rule for every tool and for no tool at all
// (captured: any button, orbit and lasso included; a key press is dropped, not
// queued, and a key release during the hold is never delivered). The router
// sets a bit for every press it delivers, clears it for every release at the
// very top of `InputRouter.processEvent` (before any gate that could swallow
// the release), and drops keys while `any`. Slice M1a of
// doc/tool_session_model_plan_2026-09-24.md (R4.4); evidence
// toolcards/tool_session_model (M0, M0b, M0c: C-H9-*, C-O5-*).

/// Held mouse buttons as a bit set: SDL buttons 1..5 map to bits 0..4; any
/// other button number is ignored (it can neither lock nor unlock the keys).
struct HeldGestureButtons {
    ubyte bits;

    private static ubyte bitOf(ubyte button) pure nothrow @safe @nogc {
        return (button >= 1 && button <= 5) ? cast(ubyte)(1u << (button - 1)) : 0;
    }

    void press(ubyte button) pure nothrow @safe @nogc { bits |= bitOf(button); }
    void release(ubyte button) pure nothrow @safe @nogc { bits &= cast(ubyte)~bitOf(button); }
    void clear() pure nothrow @safe @nogc { bits = 0; }
    bool any() const pure nothrow @safe @nogc { return bits != 0; }
}

/// The editor's one instance, main thread only (the event router and the
/// automation reset both run there). Global for the same reason `g_pie` is:
/// the automation reset hook is a plain function pointer.
__gshared HeldGestureButtons g_heldGestureButtons;

/// `AutomationResetContext.clearHeldGestureButtons`: a test that leaves a
/// press without its release must not lock the keyboard of the next test.
void clearHeldGestureButtonsForAutomation() {
    g_heldGestureButtons.clear();
}
